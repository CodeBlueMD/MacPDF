import Combine
import PDFKit
import SwiftUI

struct OutlineItem: Identifiable {
    let id = UUID()
    let title: String
    let destination: PDFDestination?
    let children: [OutlineItem]?
}

/// Lets a PDFAnnotation drive `.sheet(item:)`.
struct NoteEdit: Identifiable {
    let annotation: PDFAnnotation
    var id: ObjectIdentifier { ObjectIdentifier(annotation) }
}

struct TaskProgress {
    var title: String
    var fraction: Double
}

final class DocumentModel: ObservableObject {
    let pdf: PDFDocument
    let pdfView = MacPDFView()
    weak var undoManager: UndoManager?
    var fileName = "Document"

    @Published var mode: Mode = .annotate {
        didSet { if oldValue != mode { tool = mode == .edit ? .editText : .select } }
    }
    @Published var tool: Tool = .select
    @Published var toolColors: [Tool: Color] = [:]
    @Published var shapeKind: ShapeKind = .rectangle
    @Published var stampKind: StampKind = .approved
    /// Image chosen for the Image tool, placed on the next click or drag.
    @Published var pendingImage: NSImage?
    /// Image on the page selected with Edit → Image.
    @Published var selectedImage: ImageSelection? {
        didSet { pdfView.updateImageSelection() }
    }

    @Published var sidebarMode: SidebarMode = .thumbnails
    @Published var currentPageIndex = 0
    @Published var pageCount = 0
    @Published var scale: CGFloat = 1
    @Published var noteEdit: NoteEdit?
    @Published var showSignaturePad = false
    /// Style of the paragraph open in the Edit → Text editor; nil when nothing is being edited.
    @Published var textStyle: TextStyle?
    /// Styles already used on the page being edited, for "match the text around it".
    @Published var pageTextStyles: [(label: String, style: TextStyle)] = []
    @Published var showClearMargins = false
    @Published var showHeaderFooter = false
    @Published var showCleanCopy = false
    @Published var showProfile = false
    /// Proposed Auto-Fill entries waiting for review; nil when the sheet is closed.
    @Published var formFills: [FormFill]?
    /// Results of Edit → Patient Info, shown for review; nil when the sheet is closed.
    @Published var patientInfoMatches: [PatientInfoMatch]?
    /// Long-running page work (OCR, enhance, …); nil when idle.
    @Published var progress: TaskProgress?
    @Published var message: String?
    @Published var toast: String?
    /// Bumped on every annotation change so lists refresh.
    @Published var annotationsVersion = 0
    /// Bumped when pages are swapped for new versions, so the thumbnails rebuild.
    @Published var pagesVersion = 0

    @Published var searchText = "" {
        didSet { scheduleSearch() }
    }
    @Published var results: [PDFSelection] = []
    @Published var resultIndex = 0

    /// Ask-and-summarize, on-device; created when the Assistant tab is first opened.
    private(set) lazy var assistant = Assistant(document: self)

    var burnTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    var burnTokens: [ObjectIdentifier: BurnToken] = [:]
    private var searchTask: Task<Void, Never>?
    /// Matches found since the last UI update; flushed in batches so long searches stay smooth.
    private var foundBuffer: [PDFSelection] = []
    private var observers: [NSObjectProtocol] = []

    init(pdf: PDFDocument) {
        self.pdf = pdf
        pdfView.document = pdf
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .windowBackgroundColor
        pdfView.model = self
        pageCount = pdf.pageCount

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            self?.updateCurrentPage()
        })
        observers.append(center.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.scale = self.pdfView.scaleFactor
            self.pdfView.endInlineEdit()
            self.pdfView.updateImageSelection()
        })
        observers.append(center.addObserver(forName: .PDFViewAnnotationHit, object: pdfView, queue: .main) { [weak self] note in
            guard let self, self.tool == .select,
                  let annotation = note.userInfo?["PDFAnnotationHit"] as? PDFAnnotation,
                  annotation.isNote else { return }
            self.noteEdit = NoteEdit(annotation: annotation)
        })

        observers.append(center.addObserver(forName: .PDFDocumentDidFindMatch, object: pdf, queue: .main) { [weak self] note in
            guard let self, let match = note.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection else { return }
            match.color = .systemYellow
            self.foundBuffer.append(match)
            if self.results.isEmpty || self.foundBuffer.count >= 50 { self.flushMatches() }
        })
        observers.append(center.addObserver(forName: .PDFDocumentDidEndFind, object: pdf, queue: .main) { [weak self] _ in
            self?.flushMatches()
        })

        // Redaction marks saved by an older version are burned in as soon as the file opens.
        for i in 0..<pdf.pageCount {
            if let page = pdf.page(at: i), page.annotations.contains(where: { $0.tag == .redaction }) {
                scheduleBurn(page)
            }
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// The current tool's color; each tool remembers its own.
    var color: Color {
        get { toolColors[tool] ?? tool.defaultColor }
        set { toolColors[tool] = newValue }
    }

    var nsColor: NSColor { NSColor(color) }

    func showToast(_ text: String) {
        toast = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if toast == text { toast = nil }
        }
    }

    /// Built once; rebuilding it on every view update gave the list new identities each time.
    private(set) lazy var outline: [OutlineItem] = {
        guard let root = pdf.outlineRoot else { return [] }
        return Self.children(of: root) ?? []
    }()

    private static func children(of node: PDFOutline) -> [OutlineItem]? {
        guard node.numberOfChildren > 0 else { return nil }
        return (0..<node.numberOfChildren).compactMap { i in
            guard let child = node.child(at: i) else { return nil }
            return OutlineItem(title: child.label ?? "Untitled",
                               destination: child.destination,
                               children: children(of: child))
        }
    }

    var userAnnotations: [(page: Int, annotation: PDFAnnotation)] {
        _ = annotationsVersion
        return (0..<pdf.pageCount).flatMap { i -> [(page: Int, annotation: PDFAnnotation)] in
            guard let page = pdf.page(at: i) else { return [] }
            return page.annotations.filter(\.isUserAnnotation).map { (i, $0) }
        }
    }

    func updateCurrentPage() {
        if let page = pdfView.currentPage {
            currentPageIndex = pdf.index(for: page)
        }
        pageCount = pdf.pageCount
    }

    func go(toPage index: Int) {
        guard let page = pdf.page(at: index) else { return }
        pdfView.go(to: page)
    }

    func go(to annotation: PDFAnnotation) {
        guard let page = annotation.page else { return }
        pdfView.go(to: annotation.bounds, on: page)
    }

    func setZoom(_ factor: CGFloat?) {
        if let factor {
            pdfView.autoScales = false
            pdfView.scaleFactor = factor
        } else {
            pdfView.autoScales = true
        }
    }

    // MARK: Annotations (all undoable, which also marks the document as edited)

    /// Makes the main view redraw a page now instead of whenever PDFKit's tile cache catches up.
    func refresh(_ page: PDFPage?) {
        guard let page else { return }
        pdfView.annotationsChanged(on: page)
    }

    func add(_ annotation: PDFAnnotation, to page: PDFPage) {
        page.addAnnotation(annotation)
        refresh(page)
        undoManager?.registerUndo(withTarget: self) { $0.remove(annotation) }
        undoManager?.setActionName("Add \(annotation.displayName)")
        annotationsVersion += 1
    }

    func remove(_ annotation: PDFAnnotation) {
        guard let page = annotation.page else { return }
        page.removeAnnotation(annotation)
        refresh(page)
        undoManager?.registerUndo(withTarget: self) { $0.add(annotation, to: page) }
        undoManager?.setActionName("Delete \(annotation.displayName)")
        annotationsVersion += 1
    }

    func setContents(_ text: String, of annotation: PDFAnnotation) {
        let old = annotation.contents ?? ""
        guard old != text else { return }
        annotation.contents = text
        refresh(annotation.page)
        undoManager?.registerUndo(withTarget: self) { $0.setContents(old, of: annotation) }
        undoManager?.setActionName("Edit Note")
        annotationsVersion += 1
    }

    func grouped(_ name: String, _ body: () -> Void) {
        undoManager?.beginUndoGrouping()
        body()
        undoManager?.endUndoGrouping()
        undoManager?.setActionName(name)
    }

    func applyMarkup(_ subtype: PDFAnnotationSubtype, to selection: PDFSelection) {
        grouped(subtype == .highlight ? "Highlight" : "Markup") {
            for line in selection.selectionsByLine() {
                for page in line.pages {
                    let bounds = line.bounds(for: page)
                    guard bounds.width > 0, bounds.height > 0 else { continue }
                    let annotation = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
                    annotation.color = subtype == .highlight ? nsColor.withAlphaComponent(0.45) : nsColor
                    add(annotation, to: page)
                }
            }
        }
    }

    func addNote(at point: CGPoint, on page: PDFPage) {
        let note = PDFAnnotation(bounds: CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20),
                                 forType: .text, withProperties: nil)
        note.color = nsColor
        note.iconType = .comment
        add(note, to: page)
        noteEdit = NoteEdit(annotation: note)
    }

    /// `path` is in page coordinates; ink paths are stored relative to the annotation's bounds.
    func addInk(_ path: NSBezierPath, lineWidth: CGFloat, on page: PDFPage) {
        let bounds = path.bounds.insetBy(dx: -lineWidth, dy: -lineWidth)
        let local = path.copy() as! NSBezierPath
        local.transform(using: AffineTransform(translationByX: -bounds.minX, byY: -bounds.minY))
        let ink = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        ink.border = Self.border(lineWidth)
        ink.color = nsColor
        ink.add(local)
        add(ink, to: page)
    }

    static func border(_ width: CGFloat, dashed: Bool = false) -> PDFBorder {
        let border = PDFBorder()
        border.lineWidth = width
        if dashed {
            border.style = .dashed
            border.dashPattern = [4, 3]
        }
        return border
    }

    // MARK: Shapes, stamps, fill marks

    /// Builds the current shape between two page points (used for both the drag preview and the result).
    func makeShape(from start: CGPoint, to end: CGPoint) -> PDFAnnotation {
        switch shapeKind {
        case .line, .arrow:
            return Self.line(from: start, to: end, color: nsColor, width: 2,
                             end: shapeKind == .arrow ? .closedArrow : .none)
        case .rectangle, .oval:
            let shape = PDFAnnotation(bounds: CGRect(from: start, to: end),
                                      forType: shapeKind == .oval ? .circle : .square, withProperties: nil)
            shape.color = nsColor
            shape.border = Self.border(2)
            return shape
        }
    }

    static func line(from start: CGPoint, to end: CGPoint, color: NSColor, width: CGFloat,
                     start startStyle: PDFLineStyle = .none, end endStyle: PDFLineStyle) -> PDFAnnotation {
        let bounds = CGRect(from: start, to: end).insetBy(dx: -10, dy: -10)
        let line = PDFAnnotation(bounds: bounds, forType: .line, withProperties: nil)
        line.startPoint = CGPoint(x: start.x - bounds.minX, y: start.y - bounds.minY)
        line.endPoint = CGPoint(x: end.x - bounds.minX, y: end.y - bounds.minY)
        line.startLineStyle = startStyle
        line.endLineStyle = endStyle
        line.color = color
        line.interiorColor = color
        line.border = border(width)
        return line
    }

    func addShape(from start: CGPoint, to end: CGPoint, on page: PDFPage) {
        guard hypot(end.x - start.x, end.y - start.y) > 3 else { return }
        add(makeShape(from: start, to: end), to: page)
    }

    /// A tinted badge with bold colored text. Built from FreeText because PDFKit draws real Stamp
    /// annotations as an empty crossed-out box.
    func addStamp(at point: CGPoint, on page: PDFPage) {
        let text = stampKind.title.uppercased()
        let font = NSFont.systemFont(ofSize: 20, weight: .heavy)
        let size = (text as NSString).size(withAttributes: [.font: font])
        let bounds = CGRect(x: point.x - size.width / 2 - 12, y: point.y - size.height / 2 - 6,
                            width: size.width + 24, height: size.height + 12)
        let stamp = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        Self.style(stamp, font: font, textColor: stampKind.color, background: stampKind.color.blended(withFraction: 0.88, of: .white) ?? .white)
        stamp.alignment = .center
        stamp.contents = text
        stamp.tag = .stamp
        add(stamp, to: page)
    }

    func addFillText(_ tool: Tool, at point: CGPoint, on page: PDFPage) {
        let text: String
        let size: CGFloat
        switch tool {
        case .date:
            text = Date.now.formatted(date: .numeric, time: .omitted)
            size = 14
        case .checkmark:
            text = "✓"
            size = 22
        default:
            text = "✗"
            size = 22
        }
        let font = NSFont.systemFont(ofSize: size, weight: tool == .date ? .regular : .bold)
        let origin = CGRect(x: point.x - size / 3, y: point.y - size / 2, width: 0, height: 0)
        let annotation = PDFAnnotation(bounds: Self.fit(origin, text: text, font: font), forType: .freeText, withProperties: nil)
        Self.style(annotation, font: font, textColor: nsColor, background: .clear)
        annotation.contents = text
        add(annotation, to: page)
    }

    // MARK: Text annotations (Annotate → Text; Edit → Text rewrites page content, see TextEditing.swift)

    func addTextBox(at point: CGPoint, on page: PDFPage) {
        let font = NSFont(name: "Helvetica", size: 14) ?? .systemFont(ofSize: 14)
        let bounds = CGRect(x: point.x, y: point.y - 9, width: 160, height: 20)
        let textColor = nsColor
        pdfView.beginInlineEdit(pageRect: bounds, on: page, text: "", font: font) { [weak self] text in
            guard let self, let text, !text.isEmpty else { return }
            let annotation = PDFAnnotation(bounds: Self.fit(bounds, text: text, font: font),
                                           forType: .freeText, withProperties: nil)
            Self.style(annotation, font: font, textColor: textColor, background: .clear)
            annotation.contents = text
            self.add(annotation, to: page)
        }
    }

    func editTextAnnotation(_ annotation: PDFAnnotation) {
        guard let page = annotation.page else { return }
        let font = annotation.font ?? .systemFont(ofSize: 14)
        pdfView.beginInlineEdit(pageRect: annotation.bounds, on: page, text: annotation.contents ?? "",
                                font: font, hiding: annotation) { [weak self] text in
            guard let self, let text else { return }
            if text.isEmpty && annotation.tag != .textEdit {
                self.remove(annotation)
            } else {
                self.setText(text, of: annotation)
            }
        }
    }

    private func setText(_ text: String, of annotation: PDFAnnotation) {
        let oldText = annotation.contents ?? ""
        let oldBounds = annotation.bounds
        guard oldText != text else { return }
        annotation.contents = text
        annotation.bounds = Self.fit(oldBounds, text: text, font: annotation.font ?? .systemFont(ofSize: 14))
        refresh(annotation.page)
        undoManager?.registerUndo(withTarget: self) { model in
            model.setText(oldText, of: annotation)
            annotation.bounds = oldBounds
        }
        undoManager?.setActionName("Edit Text")
        annotationsVersion += 1
    }

    static func fit(_ bounds: CGRect, text: String, font: NSFont) -> CGRect {
        let size = (text as NSString).size(withAttributes: [.font: font])
        return CGRect(x: bounds.minX - 1, y: bounds.minY - 1,
                      width: max(bounds.width, size.width + 6) + 2,
                      height: max(bounds.height, size.height) + 2)
    }

    static func style(_ annotation: PDFAnnotation, font: NSFont, textColor: NSColor, background: NSColor) {
        annotation.font = font
        annotation.fontColor = textColor
        annotation.color = background
        annotation.alignment = .left
        annotation.border = border(0)
    }

    // MARK: Signature

    func placeSignature(at point: CGPoint, on page: PDFPage) {
        guard let signature = Signature.saved, !signature.strokes.isEmpty else {
            showSignaturePad = true
            return
        }
        let width: CGFloat = 180
        let scale = width / signature.size.width
        let height = signature.size.height * scale
        let bounds = CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)

        let ink = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        ink.border = Self.border(2)
        ink.color = NSColor(red: 0.05, green: 0.1, blue: 0.35, alpha: 1)
        for stroke in signature.strokes where stroke.count > 1 {
            let path = NSBezierPath()
            // Pad strokes are top-left origin; PDF space is bottom-left.
            let points = stroke.map { CGPoint(x: $0.x * scale, y: (signature.size.height - $0.y) * scale) }
            path.move(to: points[0])
            points.dropFirst().forEach { path.line(to: $0) }
            ink.add(path)
        }
        add(ink, to: page)
        tool = .select
    }

    func useSignatureTool() {
        if Signature.saved == nil { showSignaturePad = true } else { tool = .signature }
    }

    // MARK: Pages

    /// Swaps one page for one or more new pages (keeping the reader's place), undoably.
    func replacePage(_ old: PDFPage, with new: [PDFPage], actionName: String? = nil) {
        let index = pdf.index(for: old)
        guard index != NSNotFound, let first = new.first else { return }
        let place = pdfView.currentDestination.map { destination in
            destination.page == old ? PDFDestination(page: first, at: destination.point) : destination
        }
        pdf.removePage(at: index)
        for (offset, page) in new.enumerated() { pdf.insert(page, at: index + offset) }
        undoManager?.registerUndo(withTarget: self) { $0.restorePage(old, replacing: new) }
        if let actionName { undoManager?.setActionName(actionName) }
        reloadViews(at: place)
        updateCurrentPage()
        annotationsVersion += 1
    }

    private func restorePage(_ old: PDFPage, replacing new: [PDFPage]) {
        guard let first = new.first else { return }
        let index = pdf.index(for: first)
        guard index != NSNotFound else { return }
        let place = pdfView.currentDestination.map { destination in
            new.contains { $0 == destination.page } ? PDFDestination(page: old, at: destination.point) : destination
        }
        new.forEach { _ in pdf.removePage(at: index) }
        pdf.insert(old, at: index)
        undoManager?.registerUndo(withTarget: self) { $0.replacePage(old, with: new) }
        reloadViews(at: place)
        updateCurrentPage()
        annotationsVersion += 1
    }

    /// The main view and the thumbnails both cache rendered pages by position, so after a page is
    /// swapped at the same index either can keep showing the old image. Re-attaching the document
    /// makes both rebuild from the current pages; zoom, layout, search highlights and the reading
    /// position are put back so it looks like a normal redraw.
    private func reloadViews(at place: PDFDestination?) {
        let autoScales = pdfView.autoScales
        let scale = pdfView.scaleFactor
        let highlights = pdfView.highlightedSelections
        pdfView.document = nil
        pdfView.document = pdf
        if autoScales { pdfView.autoScales = true } else { pdfView.scaleFactor = scale }
        pdfView.highlightedSelections = highlights
        if let place, place.page?.document === pdf { pdfView.go(to: place) }
        pdfView.updateImageSelection()
        pagesVersion += 1
    }

    func replace(_ old: PDFPage, with new: PDFPage, actionName: String? = nil) {
        replacePage(old, with: [new], actionName: actionName)
    }

    func insertPages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.message = "Choose PDFs to insert after the current page"
        guard panel.runModal() == .OK else { return }

        var index = currentPageIndex + 1
        grouped("Insert Pages") {
            for url in panel.urls {
                guard let other = PDFDocument(url: url) else { continue }
                for i in 0..<other.pageCount {
                    guard let page = other.page(at: i)?.copy() as? PDFPage else { continue }
                    insert(page, at: index)
                    index += 1
                }
            }
        }
    }

    func insertBlankPage() {
        let page = PDFPage()
        let size = pdfView.currentPage?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        page.setBounds(size, for: .mediaBox)
        insert(page, at: currentPageIndex + 1)
        undoManager?.setActionName("Insert Page")
    }

    func rotateCurrentPage(by degrees: Int) {
        guard let page = pdfView.currentPage else { return }
        rotate(page, by: degrees)
    }

    private func rotate(_ page: PDFPage, by degrees: Int) {
        page.rotation = (page.rotation + degrees + 360) % 360
        undoManager?.registerUndo(withTarget: self) { $0.rotate(page, by: -degrees) }
        undoManager?.setActionName("Rotate Page")
        pdfView.layoutDocumentView()
    }

    func deleteCurrentPage() {
        guard pdf.pageCount > 1, let page = pdfView.currentPage else { return }
        let index = pdf.index(for: page)
        pdf.removePage(at: index)
        undoManager?.registerUndo(withTarget: self) { $0.insert(page, at: index) }
        undoManager?.setActionName("Delete Page")
        updateCurrentPage()
        annotationsVersion += 1
    }

    private func insert(_ page: PDFPage, at index: Int) {
        pdf.insert(page, at: index)
        undoManager?.registerUndo(withTarget: self) { model in
            model.pdf.removePage(at: index)
            model.updateCurrentPage()
        }
        updateCurrentPage()
        annotationsVersion += 1
    }

    // MARK: Search

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.runSearch()
        }
    }

    private func runSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            if pdf.isFinding { pdf.cancelFindString() }
            results = []
            pdfView.highlightedSelections = nil
            return
        }
        // Searches in the background; matches arrive through PDFDocumentDidFindMatch.
        if pdf.isFinding { pdf.cancelFindString() }
        foundBuffer = []
        results = []
        resultIndex = 0
        pdfView.highlightedSelections = nil
        sidebarMode = .search
        pdf.beginFindString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
    }

    private func flushMatches() {
        guard !foundBuffer.isEmpty else { return }
        let first = results.isEmpty
        results.append(contentsOf: foundBuffer)
        foundBuffer = []
        pdfView.highlightedSelections = results
        if first { showResult() }
    }

    func showResult(_ index: Int? = nil) {
        guard !results.isEmpty else { return }
        if let index { resultIndex = (index + results.count) % results.count }
        let selection = results[resultIndex]
        pdfView.setCurrentSelection(selection, animate: true)
        pdfView.go(to: selection)
    }

    func print() {
        pdfView.print(with: .shared, autoRotate: true)
    }
}

/// The saved handwritten signature, stored as strokes so it can be placed as a vector ink annotation.
struct Signature: Codable {
    var strokes: [[CGPoint]]
    var size: CGSize

    private static let key = "MacPDF.signature"

    static var saved: Signature? {
        get {
            UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Signature.self, from: $0) }
        }
        set {
            UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
        }
    }
}

/// MacPDF's own annotation kinds, recorded in the standard /NM (name) entry so they survive saving.
enum AnnotationTag: String {
    case redaction = "MacPDF.redaction"
    case textEdit = "MacPDF.textEdit"
    case measurement = "MacPDF.measurement"
    case stamp = "MacPDF.stamp"
}

extension PDFAnnotation {
    var tag: AnnotationTag? {
        get { (value(forAnnotationKey: .name) as? String).flatMap(AnnotationTag.init(rawValue:)) }
        set { _ = setValue(newValue?.rawValue ?? "", forAnnotationKey: .name) }
    }

    var isFreeText: Bool { subtypeName == "FreeText" }

    private var subtypeName: String {
        (type ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Links, form widgets and popups belong to the file, not to the reader's markup.
    var isUserAnnotation: Bool {
        !["Link", "Widget", "Popup"].contains(subtypeName)
    }

    var isNote: Bool { subtypeName == "Text" }

    var displayName: String {
        switch tag {
        case .redaction: return "Redaction"
        case .textEdit: return "Text Edit"
        case .measurement: return "Measurement"
        case .stamp: return "Stamp"
        case nil: break
        }
        return switch subtypeName {
        case "FreeText": "Text"
        case "Text": "Note"
        case "Ink": "Drawing"
        case "StrikeOut": "Strikethrough"
        case "Square": "Rectangle"
        case "Circle": "Oval"
        default: subtypeName.isEmpty ? "Annotation" : subtypeName
        }
    }
}

extension CGRect {
    init(from a: CGPoint, to b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
