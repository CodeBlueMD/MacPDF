import PDFKit
import SwiftUI

/// One difference between this document and an older version of it.
struct VersionChange: Identifiable {
    enum Kind { case added, removed, pageAdded, pageRemoved }
    let id = UUID()
    let kind: Kind
    let pageIndex: Int
    let text: String
    /// Where the added text is in this document (nil for removals).
    let selection: PDFSelection?
}

extension DocumentModel {
    /// Compares this document with an older version, page by page and word by word. Added text is
    /// highlighted on the page; additions and removals are listed in the sidebar.
    func compareWithOlderVersion() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.message = "Choose the older version to compare against"
        guard panel.runModal() == .OK, let url = panel.url, let older = PDFDocument(url: url) else { return }
        progress = TaskProgress(title: "Comparing", fraction: 0.3)
        Task { @MainActor in
            await Task.yield()
            let changes = Self.changes(from: older, to: pdf)
            progress = nil
            comparison = changes
            comparedWith = url.deletingPathExtension().lastPathComponent
            pdfView.highlightedSelections = changes.compactMap(\.selection)
            sidebarMode = .compare
            if changes.isEmpty { message = "No text differences from “\(comparedWith ?? "the other file")”." }
        }
    }

    func clearComparison() {
        comparison = nil
        comparedWith = nil
        pdfView.highlightedSelections = nil
    }

    static func changes(from older: PDFDocument, to newer: PDFDocument) -> [VersionChange] {
        var result: [VersionChange] = []
        for i in 0..<max(older.pageCount, newer.pageCount) {
            guard i < newer.pageCount else {
                result.append(VersionChange(kind: .pageRemoved, pageIndex: i, text: snippet(older.page(at: i)?.string ?? ""), selection: nil))
                continue
            }
            guard let newPage = newer.page(at: i) else { continue }
            guard i < older.pageCount else {
                result.append(VersionChange(kind: .pageAdded, pageIndex: i, text: snippet(newPage.string ?? ""), selection: nil))
                continue
            }
            result += pageChanges(old: older.page(at: i)?.string ?? "", new: newPage, index: i)
        }
        return result
    }

    private static func words(_ text: String) -> [(word: String, range: NSRange)] {
        var out: [(String, NSRange)] = []
        let ns = text as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { word, range, _, _ in
            if let word { out.append((word, range)) }
        }
        return out
    }

    private static func pageChanges(old: String, new page: PDFPage, index: Int) -> [VersionChange] {
        let newText = page.string ?? ""
        let oldWords = words(old), newWords = words(newText)
        let diff = newWords.map(\.word).difference(from: oldWords.map(\.word))
        var changes: [VersionChange] = []

        // Consecutive inserted words become one highlighted change.
        let inserted = diff.insertions.compactMap { if case let .insert(offset, _, _) = $0 { offset } else { nil } }.sorted()
        for run in runs(inserted) {
            let first = newWords[run.lowerBound].range, last = newWords[run.upperBound].range
            let range = NSRange(location: first.location, length: last.location + last.length - first.location)
            let selection = page.selection(for: range)
            selection?.color = NSColor.systemGreen.withAlphaComponent(0.5)
            changes.append(VersionChange(kind: .added, pageIndex: index,
                                         text: (newText as NSString).substring(with: range), selection: selection))
        }
        let removed = diff.removals.compactMap { if case let .remove(offset, _, _) = $0 { offset } else { nil } }.sorted()
        for run in runs(removed) {
            let text = oldWords[run].map(\.word).joined(separator: " ")
            changes.append(VersionChange(kind: .removed, pageIndex: index, text: text, selection: nil))
        }
        return changes
    }

    private static func runs(_ offsets: [Int]) -> [ClosedRange<Int>] {
        var result: [ClosedRange<Int>] = []
        for offset in offsets {
            if let last = result.last, last.upperBound + 1 == offset {
                result[result.count - 1] = last.lowerBound...offset
            } else {
                result.append(offset...offset)
            }
        }
        return result
    }

    private static func snippet(_ text: String) -> String {
        String(text.replacingOccurrences(of: "\n", with: " ").prefix(120))
    }
}

/// Sidebar → Compare.
struct CompareList: View {
    @ObservedObject var model: DocumentModel

    var body: some View {
        VStack(spacing: 0) {
            if let changes = model.comparison {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Compared with").font(.caption2).foregroundStyle(.secondary)
                        Text(model.comparedWith ?? "").font(.caption).lineLimit(1)
                    }
                    Spacer()
                    Button("Clear") { model.clearComparison() }.controlSize(.small)
                }
                .padding(8)
                Text("\(changes.filter { $0.kind == .added }.count) added · \(changes.filter { $0.kind == .removed }.count) removed")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                List(changes) { change in
                    Button {
                        if let selection = change.selection {
                            model.pdfView.go(to: selection)
                        } else {
                            model.go(toPage: min(change.pageIndex, model.pdf.pageCount - 1))
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Circle().fill(color(change.kind)).frame(width: 7, height: 7)
                                Text(label(change.kind)).font(.caption2.weight(.semibold)).foregroundStyle(color(change.kind))
                                Spacer()
                                Text("p. \(change.pageIndex + 1)").font(.caption2).foregroundStyle(.tertiary)
                            }
                            Text(change.text).font(.caption).lineLimit(3)
                                .strikethrough(change.kind == .removed || change.kind == .pageRemoved)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.sidebar)
            } else {
                VStack(spacing: 10) {
                    Text("Compare this PDF with an older version to see what changed.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Choose Older Version…") { model.compareWithOlderVersion() }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func label(_ kind: VersionChange.Kind) -> String {
        switch kind {
        case .added: "Added"
        case .removed: "Removed"
        case .pageAdded: "New page"
        case .pageRemoved: "Page removed"
        }
    }

    private func color(_ kind: VersionChange.Kind) -> Color {
        kind == .added || kind == .pageAdded ? .green : .red
    }
}
