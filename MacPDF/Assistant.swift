import FoundationModels
import NaturalLanguage
import PDFKit
import SwiftUI

/// Questions and summaries about the open PDF, answered by Apple's on-device model. Nothing leaves
/// the Mac. Long documents are searched first and only the most relevant passages are sent.
@MainActor
final class Assistant: ObservableObject {
    struct Message: Identifiable {
        enum Role { case user, assistant, note }
        let id = UUID()
        let role: Role
        var text: String
    }

    @Published var messages: [Message] = []
    @Published var busy = false
    @Published var progress: Double?
    /// True while the document is being indexed for search.
    @Published var preparing = false

    private weak var document: DocumentModel?
    private var index: [Chunk] = []
    private var indexedVersion = -1
    private var task: Task<Void, Never>?

    nonisolated init(document: DocumentModel) { self.document = document }

    var unavailableReason: String? {
        guard #available(macOS 26.0, *) else { return "Needs macOS 26 or later with Apple Intelligence." }
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in System Settings to use the assistant."
        case .unavailable(.modelNotReady): return "Apple Intelligence is still downloading. Try again in a few minutes."
        case .unavailable(.deviceNotEligible): return "This Mac doesn't support Apple Intelligence."
        case .unavailable: return "Apple Intelligence isn't available right now."
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        busy = false
        progress = nil
    }

    // MARK: Ask

    func ask(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !busy, let document else { return }
        messages.append(Message(role: .user, text: question))
        busy = true
        task = Task {
            defer { busy = false }
            await ensureIndex(document)
            guard !index.isEmpty else {
                messages.append(Message(role: .note, text: "This PDF has no text to search. Run Scan & OCR → Recognize Text first."))
                return
            }
            let excerpts = relevantChunks(for: question, limit: 8)
            let context = excerpts.map { "[p. \($0.page + 1)] \($0.text)" }.joined(separator: "\n\n")
            let prompt = """
            Excerpts from the document:

            \(context)

            Question: \(question)
            """
            await respond(instructions: """
                You answer questions about a PDF document using only the excerpts provided. \
                After each fact, cite the page it came from like [p. 12]. Be concise and specific. \
                If the excerpts don't answer the question, say you couldn't find it in the document.
                """, prompt: prompt)
        }
    }

    // MARK: Summaries

    func summarizePage() {
        guard !busy, let document, let page = document.pdfView.currentPage else { return }
        let number = document.pdf.index(for: page) + 1
        let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            messages.append(Message(role: .note, text: "Page \(number) has no text. Run Scan & OCR → Recognize Text first."))
            return
        }
        messages.append(Message(role: .user, text: "Summarize page \(number)"))
        busy = true
        task = Task {
            defer { busy = false }
            await respond(instructions: "Summarize the page as 3–6 short bullet points. Keep numbers, doses and names exact.",
                          prompt: "Page \(number):\n\n" + String(text.prefix(12_000)))
        }
    }

    /// Summarizes the whole document section by section, then pulls the sections together.
    func summarizeDocument() {
        guard !busy, let document else { return }
        messages.append(Message(role: .user, text: "Summarize this document"))
        busy = true
        task = Task {
            defer { busy = false; progress = nil }
            let pages = (0..<document.pdf.pageCount).map { (page: $0, text: document.pdf.page(at: $0)?.string ?? "") }
            // Batches of pages that fit comfortably in one request.
            var batches: [(range: ClosedRange<Int>, text: String)] = []
            var current = "", first = 0
            for (i, text) in pages where !text.isEmpty {
                if current.count + text.count > 9_000, !current.isEmpty {
                    batches.append((first...(i - 1), current))
                    current = ""
                    first = i
                }
                if current.isEmpty { first = i }
                current += "\n[p. \(i + 1)]\n" + String(text.prefix(9_000))
            }
            if !current.isEmpty { batches.append((first...pages.count - 1, current)) }
            guard !batches.isEmpty else {
                messages.append(Message(role: .note, text: "This PDF has no text to summarize. Run Scan & OCR → Recognize Text first."))
                return
            }
            if batches.count == 1 {
                await respond(instructions: "Summarize the document in 5–8 bullet points, citing pages like [p. 3].",
                              prompt: batches[0].text)
                return
            }
            var partials: [String] = []
            for (n, batch) in batches.enumerated() {
                if Task.isCancelled { return }
                progress = Double(n) / Double(batches.count)
                let pagesLabel = "pages \(batch.range.lowerBound + 1)–\(batch.range.upperBound + 1)"
                if let summary = await generate(instructions: "Summarize these pages in 2–3 bullet points. Cite pages like [p. 3]. Keep key numbers exact.",
                                                prompt: batch.text) {
                    partials.append("Section (\(pagesLabel)):\n\(summary)")
                }
            }
            progress = nil
            await respond(instructions: """
                Combine these section summaries of one document into an overview: a one-sentence description, \
                then 6–10 bullet points of the most important content. Keep the page citations.
                """, prompt: String(partials.joined(separator: "\n\n").prefix(14_000)))
        }
    }

    // MARK: Model calls

    /// Streams an answer into a new assistant message.
    private func respond(instructions: String, prompt: String) async {
        guard #available(macOS 26.0, *) else { return }
        messages.append(Message(role: .assistant, text: ""))
        let slot = messages.count - 1
        do {
            let session = LanguageModelSession(instructions: instructions)
            for try await partial in session.streamResponse(to: prompt) {
                if Task.isCancelled { return }
                messages[slot].text = partial.content
            }
        } catch {
            messages[slot] = Message(role: .note, text: Self.describe(error))
        }
    }

    private func generate(instructions: String, prompt: String) async -> String? {
        guard #available(macOS 26.0, *) else { return nil }
        return try? await LanguageModelSession(instructions: instructions).respond(to: prompt).content
    }

    private static func describe(_ error: Error) -> String {
        if #available(macOS 26.0, *), let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: return "That was too much text for the on-device model. Try a narrower question or a single page."
            case .guardrailViolation: return "The on-device model declined to answer this. Try rephrasing the question."
            default: break
            }
        }
        return "The assistant couldn't answer: \(error.localizedDescription)"
    }

    // MARK: Search

    struct Chunk: Sendable {
        let page: Int
        let text: String
        let terms: [String: Int]
        let vector: [Double]?
    }

    nonisolated(unsafe) static let embedding = NLEmbedding.sentenceEmbedding(for: .english)

    /// Starts indexing in the background (when the tab opens) so the first question is quick.
    func prepare() {
        guard let document else { return }
        Task { await ensureIndex(document) }
    }

    /// Builds the index once per document version; concurrent callers share the same build.
    private func ensureIndex(_ document: DocumentModel) async {
        let version = Self.version(of: document)
        if indexedVersion == version { return }
        if let indexTask { await indexTask.value; if indexedVersion == version { return } }
        let task = Task { await buildIndex(document, version: version) }
        indexTask = task
        await task.value
        indexTask = nil
    }
    private var indexTask: Task<Void, Never>?

    private static func version(of document: DocumentModel) -> Int { document.pagesVersion &* 31 &+ document.pdf.pageCount }

    /// Splits the document into ~800-character passages per page, with word counts and a sentence
    /// embedding for each. Text is read here; the heavy work runs in the background. Rebuilt when pages change.
    private func buildIndex(_ document: DocumentModel, version: Int) async {
        preparing = true
        defer { preparing = false }
        var pieces: [(page: Int, text: String)] = []
        for i in 0..<document.pdf.pageCount {
            guard let text = document.pdf.page(at: i)?.string?.replacingOccurrences(of: "\n", with: " "), !text.isEmpty else { continue }
            var start = text.startIndex
            while start < text.endIndex {
                var end = text.index(start, offsetBy: 800, limitedBy: text.endIndex) ?? text.endIndex
                if end < text.endIndex, let space = text[start..<end].lastIndex(of: " ") { end = space }
                let piece = String(text[start..<end]).trimmingCharacters(in: .whitespaces)
                if piece.count > 20 { pieces.append((i, piece)) }
                start = end < text.endIndex ? text.index(after: end) : end
            }
        }
        let built = await Task.detached(priority: .userInitiated) {
            pieces.map { Chunk(page: $0.page, text: $0.text, terms: Assistant.terms($0.text),
                               vector: Assistant.embedding?.vector(for: String($0.text.prefix(500)))) }
        }.value
        index = built
        indexedVersion = version
    }

    /// Keyword (BM25) relevance blended with meaning (embedding) similarity.
    private func relevantChunks(for question: String, limit: Int) -> [Chunk] {
        let queryTerms = Self.terms(question)
        let queryVector = Self.embedding?.vector(for: question)
        let n = Double(index.count)
        let avgLength = index.map { Double($0.terms.values.reduce(0, +)) }.reduce(0, +) / max(n, 1)
        var documentFrequency: [String: Int] = [:]
        for chunk in index { for term in chunk.terms.keys where queryTerms[term] != nil { documentFrequency[term, default: 0] += 1 } }

        let scored = index.map { chunk -> (Chunk, Double) in
            let length = Double(chunk.terms.values.reduce(0, +))
            var bm25 = 0.0
            for term in queryTerms.keys {
                guard let tf = chunk.terms[term].map(Double.init), let df = documentFrequency[term] else { continue }
                let idf = log(1 + (n - Double(df) + 0.5) / (Double(df) + 0.5))
                bm25 += idf * tf * 2.2 / (tf + 1.2 * (0.25 + 0.75 * length / max(avgLength, 1)))
            }
            var cosine = 0.0
            if let q = queryVector, let v = chunk.vector {
                let dot = zip(q, v).map(*).reduce(0, +)
                let norms = sqrt(q.map { $0 * $0 }.reduce(0, +)) * sqrt(v.map { $0 * $0 }.reduce(0, +))
                cosine = norms > 0 ? dot / norms : 0
            }
            return (chunk, bm25 + 4 * cosine)
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0).sorted { $0.page < $1.page }
    }

    nonisolated private static let stopwords: Set<String> = ["the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "is", "are",
                                                 "what", "how", "when", "which", "who", "with", "be", "it", "this", "that",
                                                 "does", "do", "should", "can", "i", "we", "you", "at", "by", "as", "from"]

    nonisolated static func terms(_ text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = text[range].lowercased()
            if word.count > 1, !stopwords.contains(word) { counts[word, default: 0] += 1 }
            return true
        }
        return counts
    }
}

/// Sidebar → Assistant.
struct AssistantView: View {
    @ObservedObject var model: DocumentModel
    @ObservedObject var assistant: Assistant
    @State private var question = ""

    var body: some View {
        VStack(spacing: 0) {
            if let reason = assistant.unavailableReason {
                Text(reason)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if assistant.preparing {
                    ProgressView { Text("Preparing this document for questions…").font(.caption) }
                        .controlSize(.small)
                        .padding(.top, 8)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if assistant.messages.isEmpty {
                                Text("Ask about this PDF, or summarize it. Answers cite pages you can click. Runs entirely on this Mac.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            ForEach(assistant.messages) { message in
                                MessageBubble(message: message, model: model).id(message.id)
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: assistant.messages.last?.text) { _, _ in
                        if let last = assistant.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                Divider()
                VStack(spacing: 6) {
                    if let progress = assistant.progress {
                        ProgressView(value: progress) { Text("Reading the document…").font(.caption) }
                    }
                    HStack {
                        Button("Summarize Page") { assistant.summarizePage() }.disabled(assistant.busy)
                        Button("Whole Document") { assistant.summarizeDocument() }.disabled(assistant.busy)
                        Spacer()
                        if assistant.busy { Button("Stop") { assistant.cancel() } }
                    }
                    .controlSize(.small)
                    TextField("Ask a question…", text: $question)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            assistant.ask(question)
                            question = ""
                        }
                        .disabled(assistant.busy)
                }
                .padding(8)
            }
        }
        .onAppear { assistant.prepare() }
    }
}

private struct MessageBubble: View {
    let message: Assistant.Message
    @ObservedObject var model: DocumentModel

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 24) }
            Text(linked(message.text.isEmpty ? "…" : message.text))
                .textSelection(.enabled)
                .font(message.role == .note ? .callout : .body)
                .foregroundStyle(message.role == .note ? .secondary : .primary)
                .padding(8)
                .background(message.role == .user ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 8))
                .environment(\.openURL, OpenURLAction { url in
                    if url.scheme == "macpdf-page", let n = Int(url.host ?? "") { model.go(toPage: n - 1) }
                    return .handled
                })
            if message.role != .user { Spacer(minLength: 24) }
        }
    }

    /// Turns citations like [p. 12] or [pp. 3–5] into links that jump to the page.
    private func linked(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let regex = try? NSRegularExpression(pattern: #"\[pp?\.\s*(\d+)[^\]]*\]"#) else { return result }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            guard let range = Range(match.range, in: text), let attrRange = Range(range, in: result),
                  let page = Int(ns.substring(with: match.range(at: 1))) else { continue }
            result[attrRange].link = URL(string: "macpdf-page://\(page)")
            result[attrRange].foregroundColor = .accentColor
        }
        return result
    }
}
