import Foundation
import NaturalLanguage
import PDFKit

/// A piece of possibly identifying information found in the document.
struct PatientInfoMatch: Identifiable {
    enum Kind: String, CaseIterable, Identifiable {
        case name = "Names"
        case birthDate = "Dates of birth"
        case date = "Other dates"
        case recordNumber = "Record & account numbers"
        case ssn = "Social Security numbers"
        case phone = "Phone & fax"
        case email = "Email"
        case address = "Addresses"
        var id: Self { self }
    }

    let id = UUID()
    let kind: Kind
    let text: String
    let pageIndex: Int
    let range: NSRange
    var include = true
}

/// Finds HIPAA-style identifiers: names (on-device language model), dates (dates of birth called
/// out separately), record/account numbers, SSNs, phone and fax numbers, emails and addresses.
enum PatientInfoScanner {
    static func scan(_ pdf: PDFDocument) -> [PatientInfoMatch] {
        var matches: [PatientInfoMatch] = []
        for i in 0..<pdf.pageCount {
            guard let text = pdf.page(at: i)?.string, !text.isEmpty else { continue }
            matches += scan(text, pageIndex: i)
        }
        return matches
    }

    static func scan(_ text: String, pageIndex: Int) -> [PatientInfoMatch] {
        let ns = text as NSString
        var found: [PatientInfoMatch] = []
        var taken = IndexSet()

        func add(_ kind: PatientInfoMatch.Kind, _ range: NSRange) {
            guard range.length > 1, !taken.intersects(integersIn: range.location..<range.location + range.length) else { return }
            let value = ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            taken.insert(integersIn: range.location..<range.location + range.length)
            found.append(PatientInfoMatch(kind: kind, text: value, pageIndex: pageIndex, range: range))
        }

        func regex(_ pattern: String, _ kind: PatientInfoMatch.Kind, group: Int = 0) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                add(kind, m.range(at: group))
            }
        }

        // Most specific first, so a labelled date of birth isn't also listed as a plain date.
        regex(#"\b\d{3}-\d{2}-\d{4}\b"#, .ssn)
        regex(#"\b(?:DOB|D\.O\.B\.?|date of birth|birth ?date|born)\s*[:#]?\s*(\d{1,2}[/.-]\d{1,2}[/.-]\d{2,4}|[A-Z][a-z]{2,8}\.? \d{1,2},? \d{4})"#, .birthDate, group: 1)
        regex(#"\b(?:MRN|med(?:ical)? ?rec(?:ord)?(?: ?(?:no|number|#))?|acct|account(?: ?(?:no|number|#))?|patient ?id|member ?id|ID ?#|chart ?#?)\s*[:#]?\s*([A-Z]{0,3}\d[\d-]{4,14})"#, .recordNumber, group: 1)
        regex(#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, .email)

        let types: NSTextCheckingResult.CheckingType = [.phoneNumber, .address, .date]
        if let detector = try? NSDataDetector(types: types.rawValue) {
            for m in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                switch m.resultType {
                case .phoneNumber: add(.phone, m.range)
                case .address: add(.address, m.range)
                case .date:
                    // Only calendar dates (a year or day/month numbers), not "today" or "in 2 weeks".
                    let value = ns.substring(with: m.range)
                    if value.range(of: #"\d{1,2}[/.-]\d{1,2}|\b(19|20)\d{2}\b"#, options: .regularExpression) != nil {
                        add(.date, m.range)
                    }
                default: break
                }
            }
        }

        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if tag == .personalName, let name = personName(NSRange(range, in: text), in: ns) { add(.name, name) }
            return true
        }
        return found.sorted { ($0.pageIndex, $0.range.location) < ($1.pageIndex, $1.range.location) }
    }

    private static let titles = try! NSRegularExpression(
        pattern: #"(?:\b(?:Dr|Mr|Mrs|Ms|Miss|Prof)\.?|\b(?:Patient|Name|Pt)\s*:?)\s*$"#, options: [.caseInsensitive])

    /// Tidies a name the language model found, or rejects it: stops at a column gap or line break,
    /// drops trailing ALL-CAPS labels (DOB, MRN), and keeps single words only after a title such as
    /// "Dr." so terms like "Hemoglobin" aren't flagged.
    private static func personName(_ range: NSRange, in text: NSString) -> NSRange? {
        var value = text.substring(with: range)
        if let gap = value.range(of: #"\s{2,}|\n"#, options: .regularExpression) { value = String(value[..<gap.lowerBound]) }
        var words = value.split(separator: " ").map(String.init)
        while let last = words.last, words.count > 1, last.count <= 4, last == last.uppercased(), last.rangeOfCharacter(from: .letters) != nil {
            words.removeLast()
        }
        guard !words.isEmpty else { return nil }
        let trimmed = words.joined(separator: " ")
        let capitalised = words.filter { $0.first?.isUppercase == true }.count
        let before = text.substring(with: NSRange(location: max(0, range.location - 12), length: min(12, range.location)))
        let titled = titles.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) != nil
            || trimmed.range(of: #"^(Dr|Mr|Mrs|Ms|Miss|Prof)\.?\s"#, options: .regularExpression) != nil
        guard capitalised >= 2 || titled else { return nil }
        return NSRange(location: range.location, length: (trimmed as NSString).length)
    }
}

extension DocumentModel {
    func scanForPatientInfo() {
        guard progress == nil else { return }
        progress = TaskProgress(title: "Looking for patient information", fraction: 0.3)
        let pdf = self.pdf
        Task { @MainActor in
            await Task.yield()
            let matches = PatientInfoScanner.scan(pdf)
            progress = nil
            if matches.isEmpty {
                message = "No names, dates, record numbers, SSNs, phone numbers, emails or addresses were found."
            } else {
                patientInfoMatches = matches
            }
        }
    }

    /// Redacts the chosen matches, burning each page in once.
    func redactPatientInfo(_ matches: [PatientInfoMatch]) {
        var count = 0
        for match in matches where match.include {
            guard let page = pdf.page(at: match.pageIndex), let selection = page.selection(for: match.range) else { continue }
            redact(selection)
            count += 1
        }
        patientInfoMatches = nil
        showToast("Redacting \(count) item\(count == 1 ? "" : "s")")
    }
}
