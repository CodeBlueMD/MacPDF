import PDFKit
import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: DocumentModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("Sidebar", selection: $model.sidebarMode) {
                ForEach(SidebarMode.allCases) { mode in
                    Image(systemName: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            Divider()

            switch model.sidebarMode {
            case .thumbnails:
                ThumbnailView(pdfView: model.pdfView, version: model.pagesVersion)
            case .outline:
                OutlineList(model: model)
            case .annotations:
                AnnotationList(model: model)
            case .search:
                SearchResultsList(model: model)
            case .assistant:
                AssistantView(model: model, assistant: model.assistant)
            case .compare:
                CompareList(model: model)
            }
        }
    }
}

private struct ThumbnailView: NSViewRepresentable {
    let pdfView: PDFView
    let version: Int

    final class Coordinator { var version = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView()
        view.pdfView = pdfView
        view.thumbnailSize = CGSize(width: 130, height: 170)
        view.backgroundColor = .clear
        return view
    }

    /// Re-binding drops the thumbnail cache, which otherwise keeps images of swapped-out pages.
    func updateNSView(_ nsView: PDFThumbnailView, context: Context) {
        guard context.coordinator.version != version else { return }
        context.coordinator.version = version
        nsView.pdfView = nil
        nsView.pdfView = pdfView
    }
}

private struct OutlineList: View {
    @ObservedObject var model: DocumentModel

    var body: some View {
        let items = model.outline
        if items.isEmpty {
            EmptyNote(text: "No table of contents")
        } else {
            List(items, children: \.children) { item in
                Button(item.title) {
                    if let destination = item.destination { model.pdfView.go(to: destination) }
                }
                .buttonStyle(.plain)
                .lineLimit(2)
            }
            .listStyle(.sidebar)
        }
    }
}

private struct AnnotationList: View {
    @ObservedObject var model: DocumentModel

    var body: some View {
        let items = model.userAnnotations
        if items.isEmpty {
            EmptyNote(text: "No annotations yet")
        } else {
            List(items.indices, id: \.self) { i in
                let (page, annotation) = items[i]
                Button { model.go(to: annotation) } label: {
                    HStack(alignment: .top) {
                        Circle()
                            .fill(Color(nsColor: annotation.color.withAlphaComponent(1)))
                            .frame(width: 8, height: 8)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(annotation.displayName).font(.callout.weight(.medium))
                            if let text = annotation.summaryText, !text.isEmpty {
                                Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                            Text("Page \(page + 1)").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Delete", role: .destructive) { model.remove(annotation) }
                }
            }
            .listStyle(.sidebar)
        }
    }
}

private struct SearchResultsList: View {
    @ObservedObject var model: DocumentModel

    var body: some View {
        if model.searchText.isEmpty {
            EmptyNote(text: "Type in the search field")
        } else if model.results.isEmpty {
            EmptyNote(text: "No matches")
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("\(model.resultIndex + 1) of \(model.results.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { model.showResult(model.resultIndex - 1) } label: { Image(systemName: "chevron.up") }
                    Button { model.showResult(model.resultIndex + 1) } label: { Image(systemName: "chevron.down") }
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                List(model.results.indices, id: \.self, selection: Binding(
                    get: { model.resultIndex },
                    set: { if let i = $0 { model.showResult(i) } }
                )) { i in
                    SearchRow(selection: model.results[i], pdf: model.pdf)
                }
                .listStyle(.sidebar)
            }
        }
    }
}

private struct SearchRow: View {
    let selection: PDFSelection
    let pdf: PDFDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(context).font(.caption).lineLimit(2)
            if let page = selection.pages.first {
                Text("Page \(pdf.index(for: page) + 1)").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    /// The match with a few words either side.
    private var context: String {
        guard let extended = selection.copy() as? PDFSelection else { return selection.string ?? "" }
        extended.extend(atStart: 30)
        extended.extend(atEnd: 30)
        return (extended.string ?? "").replacingOccurrences(of: "\n", with: " ")
    }
}

private struct EmptyNote: View {
    let text: String
    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension PDFAnnotation {
    /// Note text, or the document text under a markup annotation.
    var summaryText: String? {
        if let contents, !contents.isEmpty { return contents }
        guard isUserAnnotation, !isNote, let page else { return nil }
        return page.selection(for: bounds)?.string?.replacingOccurrences(of: "\n", with: " ")
    }
}
