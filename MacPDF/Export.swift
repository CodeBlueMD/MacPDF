import PDFKit
import UniformTypeIdentifiers

extension DocumentModel {
    func export(_ kind: ExportKind) {
        switch kind {
        case .word: exportWord()
        case .excel: exportExcel()
        case .text: exportText()
        case .image: exportImages()
        }
    }

    private var pages: [PDFPage] { (0..<pdf.pageCount).compactMap(pdf.page(at:)) }

    private func savePanel(_ ext: String, _ type: UTType?) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(fileName).\(ext)"
        if let type { panel.allowedContentTypes = [type] }
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func write(_ data: Data?, to url: URL, what: String) {
        do {
            guard let data else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url)
            showToast("Exported \(what)")
        } catch {
            message = "Couldn't export: \(error.localizedDescription)"
        }
    }

    /// Text with its fonts and styles, one page per Word page.
    private func exportWord() {
        guard warnIfNoText(), let url = savePanel("docx", UTType(filenameExtension: "docx")) else { return }
        let output = NSMutableAttributedString()
        for (i, page) in pages.enumerated() {
            if let text = page.attributedString { output.append(text) }
            if i < pages.count - 1 { output.append(NSAttributedString(string: "\u{0C}")) }
        }
        let data = try? output.data(from: NSRange(location: 0, length: output.length),
                                    documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        write(data, to: url, what: "Word document")
    }

    /// One spreadsheet row per line; columns split where the PDF has wide gaps or tabs (table layouts).
    private func exportExcel() {
        guard warnIfNoText(), let url = savePanel("csv", .commaSeparatedText) else { return }
        let gap = try! NSRegularExpression(pattern: "\\t| {2,}")
        var rows: [String] = []
        for page in pages {
            for line in (page.string ?? "").components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                let range = NSRange(line.startIndex..., in: line)
                let cells = gap.stringByReplacingMatches(in: line, range: range, withTemplate: "\u{1F}")
                    .components(separatedBy: "\u{1F}")
                    .map { "\"" + $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                rows.append(cells.joined(separator: ","))
            }
        }
        write(Data(("\u{FEFF}" + rows.joined(separator: "\r\n")).utf8), to: url, what: "spreadsheet")
    }

    private func exportText() {
        guard warnIfNoText(), let url = savePanel("txt", .plainText) else { return }
        let text = pages.map { $0.string ?? "" }.joined(separator: "\n\n\u{0C}")
        write(Data(text.utf8), to: url, what: "text")
    }

    /// One PNG per page, including annotations.
    private func exportImages() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for the page images"
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        var count = 0
        for (i, page) in pages.enumerated() {
            guard let image = OCR.render(page, dpi: 200, region: page.bounds(for: .cropBox), includeAnnotations: true),
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { continue }
            let url = folder.appendingPathComponent("\(fileName) - page \(i + 1).png")
            if (try? data.write(to: url)) != nil { count += 1 }
        }
        showToast("Exported \(count) page image(s)")
    }

    private func warnIfNoText() -> Bool {
        guard pages.allSatisfy(OCR.needsText) else { return true }
        message = "This PDF has no text to export yet. Run Scan & OCR → Recognize Text first."
        return false
    }
}
