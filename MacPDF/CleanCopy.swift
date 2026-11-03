import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Export → Clean Copy: a copy safe to share, without the information people don't see.
struct CleanCopyOptions {
    var documentInfo = true
    var comments = true
    var links = false
    var attachments = true
}

extension DocumentModel {
    func exportCleanCopy(_ options: CleanCopyOptions) {
        pdfView.endInlineEdit()
        guard let (output, removed) = cleanCopy(options) else {
            message = "Couldn't prepare a clean copy."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(fileName) (clean).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try output.write(to: url)
            message = removed.isEmpty
                ? "Saved a clean copy. There was no hidden information to remove."
                : "Saved a clean copy. Removed:\n• " + removed.joined(separator: "\n• ")
        } catch {
            message = "Couldn't save the clean copy: \(error.localizedDescription)"
        }
    }

    /// The cleaned file's bytes and a list of what was removed.
    func cleanCopy(_ options: CleanCopyOptions) -> (Data, [String])? {
        guard let data = pdf.dataRepresentation(), let copy = PDFDocument(data: data) else { return nil }
        var removed: [String] = []

        if options.documentInfo {
            let count = (copy.documentAttributes ?? [:]).count
            copy.documentAttributes = [:]
            if count > 0 { removed.append("\(count) document propert\(count == 1 ? "y" : "ies") (author, title, app used…)") }
        }
        var comments = 0, links = 0
        for i in 0..<copy.pageCount {
            guard let page = copy.page(at: i) else { continue }
            for annotation in page.annotations {
                let type = (annotation.type ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if options.comments, annotation.isUserAnnotation, type != "Widget" {
                    page.removeAnnotation(annotation); comments += 1
                } else if options.links, type == "Link" {
                    page.removeAnnotation(annotation); links += 1
                }
            }
        }
        if comments > 0 { removed.append("\(comments) comment\(comments == 1 ? "" : "s") and markup") }
        if links > 0 { removed.append("\(links) link\(links == 1 ? "" : "s")") }

        guard var output = copy.dataRepresentation() else { return nil }
        if options.documentInfo, let cleaned = ContentSurgery.removingCatalogMetadata(from: output) {
            output = cleaned.data
            if cleaned.removed { removed.append("embedded XMP metadata") }
        }
        if options.attachments, let result = PDFium.removingAttachments(from: output) {
            output = result.data
            if result.count > 0 { removed.append("\(result.count) attached file\(result.count == 1 ? "" : "s")") }
        }

        return (output, removed)
    }
}

struct CleanCopySheet: View {
    @ObservedObject var model: DocumentModel
    @Environment(\.dismiss) private var dismiss
    @State private var options = CleanCopyOptions()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clean Copy").font(.headline)
            Text("Saves a copy that's safe to share, without information people don't see on the page. Your open document isn't changed.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Document properties and metadata (author, title, software, dates)", isOn: $options.documentInfo)
            Toggle("Comments, notes, highlights and other markup", isOn: $options.comments)
            Toggle("Links", isOn: $options.links)
            Toggle("Attached files", isOn: $options.attachments)
            Text("Tip: use Edit → Patient Info first to redact names, dates of birth and record numbers.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save Clean Copy…") {
                    dismiss()
                    model.exportCleanCopy(options)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 440)
    }
}
