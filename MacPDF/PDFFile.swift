import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// A PDF on disk. Edits happen directly on `pdf`; saving writes its current state.
final class PDFFile: ReferenceFileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }

    let pdf: PDFDocument

    /// File > New creates a single blank US Letter page.
    init() {
        pdf = PDFDocument()
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 612, height: 792), for: .mediaBox)
        pdf.insert(page, at: 0)
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let pdf = PDFDocument(data: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.pdf = pdf
    }

    func snapshot(contentType: UTType) throws -> Data {
        guard let data = pdf.dataRepresentation() else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)
    }
}
