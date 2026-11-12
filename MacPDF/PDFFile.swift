import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// A PDF on disk. Edits happen directly on `pdf`; saving writes its current state.
final class PDFFile: ReferenceFileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }

    let pdf: PDFDocument
    /// Commits any edit still open in the window before the file is written.
    var willSave: (() -> Void)?

    /// File > New creates a single blank US Letter page.
    init() {
        pdf = PDFDocument()
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 612, height: 792), for: .mediaBox)
        pdf.insert(page, at: 0)
    }

    init(pdf: PDFDocument) {
        self.pdf = pdf
    }

    convenience init(data: Data) throws {
        guard let doc = PDFDocument(data: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.init(pdf: doc)
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let pdf = PDFDocument(data: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.pdf = pdf
    }

    func snapshot(contentType: UTType) throws -> Data {
        // Saves and autosaves can run off the main thread, where touching the editor views crashes.
        // Open edits are committed on the main thread before saving starts (see MacPDFView).
        if Thread.isMainThread {
            willSave?()
        } else if let willSave = self.willSave {
            // Avoid deadlocking with DispatchQueue.main.sync if the main thread is blocked waiting
            // for document saving or app quitting.
            let sema = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                willSave()
                sema.signal()
            }
            _ = sema.wait(timeout: .now() + .milliseconds(500))
        }

        // Fail-closed security check: If any pending redaction annotations remain unburned
        // (e.g. background save while main thread was busy or burn timed out), refuse to write to disk.
        if hasPendingRedactions {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: "Cannot save document: pending redactions have not finished burning."
            ])
        }

        guard let data = pdf.dataRepresentation() else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    var hasPendingRedactions: Bool {
        for i in 0..<pdf.pageCount {
            if let page = pdf.page(at: i), page.annotations.contains(where: { $0.tag == .redaction }) {
                return true
            }
        }
        return false
    }

    func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)
    }
}
