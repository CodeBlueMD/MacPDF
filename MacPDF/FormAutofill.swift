import PDFKit
import SwiftUI

/// The details MacPDF can fill into forms. Stored only on this Mac.
enum ProfileField: String, CaseIterable, Identifiable, Codable {
    case fullName, firstName, lastName, credentials, specialty, npi, dea, license, licenseState,
         email, phone, fax, address, city, state, zip, organization, dateOfBirth, today

    var id: Self { self }

    var title: String {
        switch self {
        case .fullName: "Full name"
        case .firstName: "First name"
        case .lastName: "Last name"
        case .credentials: "Credentials (e.g. MD)"
        case .specialty: "Specialty"
        case .npi: "NPI"
        case .dea: "DEA number"
        case .license: "Medical license number"
        case .licenseState: "License state"
        case .email: "Email"
        case .phone: "Phone"
        case .fax: "Fax"
        case .address: "Street address"
        case .city: "City"
        case .state: "State"
        case .zip: "ZIP"
        case .organization: "Practice / hospital"
        case .dateOfBirth: "Date of birth"
        case .today: "Today's date"
        }
    }

    /// Form labels that ask for this field, most specific first.
    var labels: [String] {
        switch self {
        case .fullName: ["physician name", "provider name", "applicant name", "practitioner name", "full name", "print name", "name"]
        case .firstName: ["first name", "given name"]
        case .lastName: ["last name", "surname", "family name"]
        case .credentials: ["credentials", "degree", "title"]
        case .specialty: ["primary specialty", "specialty"]
        case .npi: ["individual npi", "npi number", "npi #", "npi"]
        case .dea: ["dea registration", "dea number", "dea #", "dea"]
        case .license: ["medical license number", "state license number", "license number", "license #", "license no"]
        case .licenseState: ["license state", "state of licensure"]
        case .email: ["e-mail address", "email address", "e-mail", "email"]
        case .phone: ["telephone", "phone number", "cell phone", "mobile", "phone"]
        case .fax: ["fax number", "fax"]
        case .address: ["mailing address", "street address", "home address", "address"]
        case .city: ["city"]
        case .state: ["state"]
        case .zip: ["zip code", "postal code", "zip"]
        case .organization: ["practice name", "organization", "hospital", "facility", "employer"]
        case .dateOfBirth: ["date of birth", "birth date", "dob"]
        case .today: ["today's date", "date signed", "date"]
        }
    }

    /// The value to fill, or nil if the profile doesn't have it.
    func value(in profile: [ProfileField: String]) -> String? {
        if self == .today { return Date.now.formatted(date: .numeric, time: .omitted) }
        if self == .fullName, (profile[.fullName] ?? "").isEmpty {
            let parts = [profile[.firstName], profile[.lastName], profile[.credentials].map { ", \($0)" }].compactMap { $0 }
            let joined = parts.joined(separator: " ").replacingOccurrences(of: " ,", with: ",").trimmingCharacters(in: .whitespaces)
            return joined.isEmpty ? nil : joined
        }
        let value = profile[self]?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? nil : value
    }
}

enum Profile {
    private static let key = "MacPDF.profile"

    static var saved: [ProfileField: String] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
            return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in ProfileField(rawValue: k).map { ($0, v) } })
        }
        set {
            let raw = Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.rawValue, $0.value) })
            UserDefaults.standard.set(try? JSONEncoder().encode(raw), forKey: key)
        }
    }
}

/// One proposed entry: where on the page, and what to write.
struct FormFill: Identifiable {
    let id = UUID()
    let field: ProfileField
    let label: String
    var value: String
    let pageIndex: Int
    /// Baseline start for flat forms; nil when filling a real form field.
    let origin: CGPoint?
    let fontSize: CGFloat
    weak var widget: PDFAnnotation?
    var include = true
}

enum FormAutofill {
    static func proposals(for pdf: PDFDocument, pages: [Int], profile: [ProfileField: String]) async -> [FormFill] {
        var fills: [FormFill] = []
        for i in pages {
            guard let page = pdf.page(at: i) else { continue }
            let widgets = page.annotations.filter { ($0.type ?? "").contains("Widget") && $0.widgetFieldType == .text }
            if !widgets.isEmpty {
                fills += widgetFills(widgets, pageIndex: i, profile: profile)
            } else if !OCR.needsText(page) {
                fills += textFills(page, pageIndex: i, profile: profile)
            } else if let image = OCR.render(page), let lines = await OCR.recognize(image) {
                fills += scannedFills(lines, page: page, pageIndex: i, profile: profile)
            }
        }
        return fills
    }

    // MARK: Real form fields

    private static func widgetFills(_ widgets: [PDFAnnotation], pageIndex: Int, profile: [ProfileField: String]) -> [FormFill] {
        widgets.compactMap { widget in
            guard (widget.widgetStringValue ?? "").isEmpty else { return nil }
            let name = [widget.fieldName, widget.userName].compactMap { $0 }.joined(separator: " ")
                .replacingOccurrences(of: #"([a-z])([A-Z])"#, with: "$1 $2", options: .regularExpression)
                .replacingOccurrences(of: "_", with: " ")
            guard let (field, label) = match(name, wholeLabel: false), let value = field.value(in: profile) else { return nil }
            return FormFill(field: field, label: label, value: value, pageIndex: pageIndex, origin: nil,
                            fontSize: 0, widget: widget)
        }
    }

    // MARK: Flat forms with real text

    private static func textFills(_ page: PDFPage, pageIndex: Int, profile: [ProfileField: String]) -> [FormFill] {
        guard let text = page.string else { return [] }
        let ns = text as NSString
        var fills: [FormFill] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byLines) { line, lineRange, _, _ in
            guard let line else { return }
            for hit in labels(in: line) {
                guard let value = hit.field.value(in: profile) else { continue }
                // Write on the blank (after the colon, or on the underscores).
                let startIndex = lineRange.location + hit.valueStart
                // Measure the whole label; single characters like ":" can report zero height.
                guard let anchor = page.selection(for: NSRange(location: lineRange.location + hit.labelStart,
                                                               length: hit.labelEnd - hit.labelStart))?.bounds(for: page),
                      anchor.height > 0 else { continue }
                // Character positions inside runs of underscores are unreliable, so start just past
                // the label; the blank (or its underline) begins right there.
                _ = startIndex
                let x = anchor.maxX + 6
                let size = min(11, max(anchor.height * 0.85, 7))
                fills.append(FormFill(field: hit.field, label: hit.label, value: value, pageIndex: pageIndex,
                                      origin: CGPoint(x: x, y: anchor.minY + anchor.height * 0.2), fontSize: size))
            }
        }
        return fills
    }

    // MARK: Scanned forms (OCR lines)

    private static func scannedFills(_ lines: [OCR.Line], page: PDFPage, pageIndex: Int,
                                     profile: [ProfileField: String]) -> [FormFill] {
        let box = page.bounds(for: .mediaBox)
        var fills: [FormFill] = []
        for line in lines {
            let rect = OCR.pageRect(line.box, in: box)
            let count = max(CGFloat((line.text as NSString).length), 1)
            for hit in labels(in: line.text) {
                guard let value = hit.field.value(in: profile) else { continue }
                let fraction = CGFloat(hit.hasUnderscores ? hit.valueStart : hit.labelEnd) / count
                fills.append(FormFill(field: hit.field, label: hit.label, value: value, pageIndex: pageIndex,
                                      origin: CGPoint(x: rect.minX + rect.width * fraction + 5, y: rect.minY + rect.height * 0.2),
                                      fontSize: min(11, max(rect.height * 0.75, 7))))
            }
        }
        return fills
    }

    // MARK: Label matching

    struct LabelHit {
        let field: ProfileField
        let label: String
        /// Offsets within the line: start and end of the label (incl. colon), start of the blank.
        let labelStart: Int
        let labelEnd: Int
        let valueStart: Int
        let hasUnderscores: Bool
    }

    /// Labels in a line that are followed by a blank (nothing, spaces or underscores up to the next
    /// label), skipping anything about a patient or already filled in.
    static func labels(in line: String) -> [LabelHit] {
        let ns = line as NSString
        let lower = line.lowercased() as NSString
        var hits: [LabelHit] = []
        var used = IndexSet()
        // A longer label that turned out to be filled in rules out shorter labels inside it
        // ("email address: jane@…" must not then match "email").
        var rejected = IndexSet()
        let all = ProfileField.allCases.flatMap { f in f.labels.map { (f, $0) } }.sorted { $0.1.count > $1.1.count }
        for (field, label) in all {
            var search = NSRange(location: 0, length: lower.length)
            while true {
                let r = lower.range(of: label, options: [], range: search)
                guard r.location != NSNotFound else { break }
                search = NSRange(location: r.location + r.length, length: lower.length - r.location - r.length)
                let before = r.location == 0 ? " " : lower.substring(with: NSRange(location: r.location - 1, length: 1))
                guard before.rangeOfCharacter(from: .letters) == nil,
                      !used.intersects(integersIn: r.location..<r.location + r.length),
                      !rejected.intersects(integersIn: r.location..<r.location + r.length) else { continue }
                let prefix = lower.substring(to: r.location)
                if prefix.hasSuffix("patient ") || prefix.hasSuffix("patient's ") { continue }
                // After the label: optional colon/#, then the blank.
                var end = r.location + r.length
                while end < ns.length, ":#.".contains(ns.substring(with: NSRange(location: end, length: 1))) { end += 1 }
                guard end == ns.length || ns.substring(with: NSRange(location: end, length: 1)).rangeOfCharacter(from: .letters) == nil else { continue }
                var valueStart = end
                while valueStart < ns.length, ns.substring(with: NSRange(location: valueStart, length: 1)) == " " { valueStart += 1 }
                let rest = ns.substring(from: valueStart)
                let blank = rest.prefix { $0 == "_" || $0 == " " || $0 == "\t" }
                let hasUnderscores = blank.contains("_")
                // The blank must run to the end of the line or to another label.
                let after = rest.dropFirst(blank.count)
                let nextIsLabel = all.contains { after.lowercased().hasPrefix($0.1) }
                guard after.isEmpty || nextIsLabel || blank.count >= 3 else {
                    rejected.insert(integersIn: r.location..<r.location + r.length)
                    continue
                }
                used.insert(integersIn: r.location..<end)
                hits.append(LabelHit(field: field, label: ns.substring(with: r), labelStart: r.location, labelEnd: end,
                                     valueStart: valueStart, hasUnderscores: hasUnderscores))
            }
        }
        return hits.sorted { $0.labelEnd < $1.labelEnd }
    }

    static func match(_ name: String, wholeLabel: Bool) -> (ProfileField, String)? {
        let lower = name.lowercased()
        guard !lower.contains("patient") else { return nil }
        for field in ProfileField.allCases {
            for label in field.labels where lower.range(of: "\\b\(NSRegularExpression.escapedPattern(for: label))\\b", options: .regularExpression) != nil {
                return (field, label)
            }
        }
        return nil
    }
}

extension DocumentModel {
    func autofillForm(allPages: Bool) {
        let profile = Profile.saved
        guard profile.values.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            showProfile = true
            return
        }
        let pages = allPages ? Array(0..<pdf.pageCount) : [currentPageIndex]
        progress = TaskProgress(title: "Finding form fields", fraction: 0.4)
        Task { @MainActor in
            let fills = await FormAutofill.proposals(for: pdf, pages: pages, profile: profile)
            progress = nil
            if fills.isEmpty {
                message = "No fields matching your profile were found on \(allPages ? "this document" : "this page")."
            } else {
                formFills = fills
            }
        }
    }

    func applyFormFills(_ fills: [FormFill]) {
        grouped("Fill Form") {
            for fill in fills where fill.include && !fill.value.isEmpty {
                if let widget = fill.widget {
                    widget.widgetStringValue = fill.value
                    refresh(widget.page)
                    continue
                }
                guard let page = pdf.page(at: fill.pageIndex), let origin = fill.origin else { continue }
                let font = NSFont(name: "Helvetica", size: fill.fontSize) ?? .systemFont(ofSize: fill.fontSize)
                let bounds = Self.fit(CGRect(x: origin.x, y: origin.y + font.descender, width: 0, height: 0),
                                      text: fill.value, font: font)
                let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
                Self.style(annotation, font: font, textColor: .black, background: .clear)
                annotation.contents = fill.value
                add(annotation, to: page)
            }
        }
        formFills = nil
        showToast("Filled \(fills.filter(\.include).count) field\(fills.filter(\.include).count == 1 ? "" : "s")")
    }
}

/// Review list for Fill & Sign → Auto-Fill.
struct FormFillSheet: View {
    @ObservedObject var model: DocumentModel
    @State var fills: [FormFill]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fill from your profile").font(.headline)
            Text("Check what to fill and adjust any value. Filled text can be moved or deleted afterwards like any text box.")
                .font(.callout).foregroundStyle(.secondary)
            List($fills) { $fill in
                HStack {
                    Toggle("", isOn: $fill.include).labelsHidden()
                    VStack(alignment: .leading, spacing: 1) {
                        Text(fill.label.capitalized).font(.caption).foregroundStyle(.secondary)
                        TextField(fill.field.title, text: $fill.value)
                    }
                    Text("p. \(fill.pageIndex + 1)").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .frame(minHeight: 300)
            HStack {
                Button("Edit Profile…") {
                    model.formFills = nil
                    model.showProfile = true
                    dismiss()
                }
                Spacer()
                Button("Cancel") {
                    model.formFills = nil
                    dismiss()
                }
                Button("Fill") {
                    dismiss()
                    model.applyFormFills(fills)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 520, height: 500)
    }
}

/// Fill & Sign → My Profile.
struct ProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var values = Profile.saved

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("My Profile").font(.headline)
            Text("Used to fill forms automatically. Saved only on this Mac.").font(.callout).foregroundStyle(.secondary)
            Form {
                ForEach(ProfileField.allCases.filter { $0 != .today }) { field in
                    TextField(field.title, text: Binding(get: { values[field] ?? "" }, set: { values[field] = $0 }))
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 380)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    Profile.saved = values
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 460, height: 560)
    }
}
