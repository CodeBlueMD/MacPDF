import Compression
import Foundation
import PDFKit

/// Removes specific drawing commands from a page while leaving every other byte of its content
/// untouched. PDFium can also delete objects, but it then regenerates the whole page, losing
/// details such as character spacing and ICC colors on text that was never edited.
///
/// Works on a one-page copy written by PDFKit: finds the page's content streams, deletes the
/// chosen commands, and appends the new streams as a standard PDF incremental update.
enum ContentSurgery {
    /// Text-showing commands whose starting point lies inside `region` are removed. Also returns
    /// where each removed run started (its baseline), so replacement text can sit exactly there.
    static func removingText(in region: CGRect, from page: PDFPage) -> (page: PDFPage, origins: [CGPoint])? {
        var origins: [CGPoint] = []
        let result = edit(page) { ops in
            let hits = ops.filter { $0.isTextShow && region.contains($0.textOrigin) }
            origins = hits.map(\.textOrigin)
            return hits.map { ($0, $0.replacementForRemovedText) }
        }
        return result.map { ($0, origins) }
    }

    /// Runs `choose` over the page's commands; it returns the commands to replace (with "" to delete).
    static func edit(_ page: PDFPage, choose: ([Operation]) -> [(Operation, String)]) -> PDFPage? {
        let single = PDFDocument()
        guard let copy = page.copy() as? PDFPage else { return nil }
        single.insert(copy, at: 0)
        guard let data = single.dataRepresentation(), let file = PDFFile(data: data),
              let streams = file.pageContentStreams(), !streams.isEmpty else { return nil }

        var parsed: [(ref: Int, gen: Int, bytes: Data, ops: [Operation])] = []
        var state = GraphicsState()
        for stream in streams {
            guard let bytes = file.decodedStream(stream.ref) else { return nil }
            let ops = ContentParser(bytes).operations(state: &state)
            parsed.append((stream.ref, stream.gen, bytes, ops))
        }
        let changes = choose(parsed.flatMap(\.ops))
        guard !changes.isEmpty else { return nil }

        var updates: [(ref: Int, gen: Int, bytes: Data)] = []
        for stream in parsed {
            let mine = changes.filter { change in stream.ops.contains { $0.range == change.0.range && $0.streamID == change.0.streamID } }
            guard !mine.isEmpty else { continue }
            var bytes = stream.bytes
            for (op, replacement) in mine.sorted(by: { $0.0.range.lowerBound > $1.0.range.lowerBound }) {
                bytes.replaceSubrange(op.range, with: Data((" " + replacement + " ").utf8))
            }
            updates.append((stream.ref, stream.gen, bytes))
        }
        guard let updated = file.appendingStreams(updates),
              let newPage = PDFDocument(data: updated)?.page(at: 0)?.copy() as? PDFPage else { return nil }
        return newPage
    }

    // MARK: Content stream parsing

    struct GraphicsState {
        var ctm = CGAffineTransform.identity
        var stack: [CGAffineTransform] = []
        var textMatrix = CGAffineTransform.identity
        var lineMatrix = CGAffineTransform.identity
        var leading: CGFloat = 0
        var streamID = 0
    }

    struct Operation {
        let op: String
        let operands: [Token]
        /// Byte range of the operands and operator in the decoded stream.
        let range: Range<Int>
        let streamID: Int
        /// For text-showing commands: where the text starts, in page coordinates.
        let textOrigin: CGPoint
        /// For image/form drawing (`Do`): the transform from the unit square to the page.
        let ctm: CGAffineTransform

        var isTextShow: Bool { ["Tj", "TJ", "'", "\""].contains(op) }

        /// `'` and `"` also move to the next line (and `"` sets spacing); keep that part so text
        /// after the removed line stays where it was.
        var replacementForRemovedText: String {
            switch op {
            case "'": return "T*"
            case "\"" where operands.count >= 2: return "\(operands[0].text) Tw \(operands[1].text) Tc T*"
            default: return ""
            }
        }
    }

    struct Token {
        let text: String
        var number: CGFloat? { Double(text).map { CGFloat($0) } }
    }

    struct ContentParser {
        let bytes: [UInt8]
        init(_ data: Data) { bytes = [UInt8](data) }

        func operations(state: inout GraphicsState) -> [Operation] {
            var ops: [Operation] = []
            var operands: [Token] = []
            var operandStart: Int?
            var i = 0
            state.streamID += 1
            while i < bytes.count {
                let c = bytes[i]
                if isWhite(c) { i += 1; continue }
                if c == 0x25 { while i < bytes.count, bytes[i] != 0x0A, bytes[i] != 0x0D { i += 1 }; continue } // %
                let start = i
                let token: String
                switch c {
                case 0x28: i = skipString(i); token = "(string)"                 // (
                case 0x3C where i + 1 < bytes.count && bytes[i + 1] == 0x3C:   // <<
                    i = skipDict(i); token = "<<dict>>"
                case 0x3C: while i < bytes.count, bytes[i] != 0x3E { i += 1 }; i += 1; token = "<hex>"
                case 0x5B: i = skipArray(i); token = "[array]"                 // [
                case 0x2F:                                                     // /name
                    i += 1
                    while i < bytes.count, !isWhite(bytes[i]), !isDelimiter(bytes[i]) { i += 1 }
                    token = String(decoding: bytes[start..<i], as: UTF8.self)
                default:
                    while i < bytes.count, !isWhite(bytes[i]), !isDelimiter(bytes[i]) { i += 1 }
                    if i == start { i += 1 }
                    token = String(decoding: bytes[start..<i], as: UTF8.self)
                }
                let isOperand = c == 0x28 || c == 0x3C || c == 0x5B || c == 0x2F || Double(token) != nil
                    || token == "true" || token == "false" || token == "null"
                if isOperand {
                    if operandStart == nil { operandStart = start }
                    operands.append(Token(text: token))
                    continue
                }
                if token == "BI" { i = skipInlineImage(i) }
                let range = (operandStart ?? start)..<i
                let origin = CGPoint.zero.applying(state.textMatrix.concatenating(state.ctm))
                apply(token, operands, to: &state)
                ops.append(Operation(op: token, operands: operands, range: range, streamID: state.streamID,
                                     textOrigin: token == "'" || token == "\""
                                        ? CGPoint.zero.applying(state.textMatrix.concatenating(state.ctm)) : origin,
                                     ctm: state.ctm))
                operands = []
                operandStart = nil
            }
            return ops
        }

        private func apply(_ op: String, _ operands: [Token], to s: inout GraphicsState) {
            let n = operands.compactMap(\.number)
            switch op {
            case "q": s.stack.append(s.ctm)
            case "Q": s.ctm = s.stack.popLast() ?? s.ctm
            case "cm" where n.count == 6:
                s.ctm = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5]).concatenating(s.ctm)
            case "BT": s.textMatrix = .identity; s.lineMatrix = .identity
            case "Tm" where n.count == 6:
                s.lineMatrix = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
                s.textMatrix = s.lineMatrix
            case "Td" where n.count == 2:
                s.lineMatrix = CGAffineTransform(translationX: n[0], y: n[1]).concatenating(s.lineMatrix)
                s.textMatrix = s.lineMatrix
            case "TD" where n.count == 2:
                s.leading = -n[1]
                s.lineMatrix = CGAffineTransform(translationX: n[0], y: n[1]).concatenating(s.lineMatrix)
                s.textMatrix = s.lineMatrix
            case "TL" where n.count == 1: s.leading = n[0]
            case "T*", "'", "\"":
                s.lineMatrix = CGAffineTransform(translationX: 0, y: -s.leading).concatenating(s.lineMatrix)
                s.textMatrix = s.lineMatrix
            default: break
            }
        }

        private func isWhite(_ c: UInt8) -> Bool { c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0C || c == 0x00 }
        private func isDelimiter(_ c: UInt8) -> Bool { [0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25].contains(c) }

        private func skipString(_ start: Int) -> Int {
            var i = start + 1, depth = 1
            while i < bytes.count, depth > 0 {
                switch bytes[i] {
                case 0x5C: i += 1                 // backslash escape
                case 0x28: depth += 1
                case 0x29: depth -= 1
                default: break
                }
                i += 1
            }
            return i
        }

        private func skipArray(_ start: Int) -> Int {
            var i = start + 1
            while i < bytes.count, bytes[i] != 0x5D {
                if bytes[i] == 0x28 { i = skipString(i) } else if bytes[i] == 0x5B { i = skipArray(i) } else { i += 1 }
            }
            return i + 1
        }

        private func skipDict(_ start: Int) -> Int {
            var i = start + 2, depth = 1
            while i + 1 < bytes.count, depth > 0 {
                if bytes[i] == 0x28 { i = skipString(i); continue }
                if bytes[i] == 0x3C, bytes[i + 1] == 0x3C { depth += 1; i += 2; continue }
                if bytes[i] == 0x3E, bytes[i + 1] == 0x3E { depth -= 1; i += 2; continue }
                i += 1
            }
            return i
        }

        /// Skips `BI … ID <binary> EI`.
        private func skipInlineImage(_ start: Int) -> Int {
            var i = start
            while i + 2 < bytes.count, !(bytes[i] == 0x49 && bytes[i + 1] == 0x44 && isWhite(bytes[i + 2])) { i += 1 }
            i += 3
            while i + 2 < bytes.count, !(isWhite(bytes[i]) && bytes[i + 1] == 0x45 && bytes[i + 2] == 0x49
                                          && (i + 3 >= bytes.count || isWhite(bytes[i + 3]) || isDelimiter(bytes[i + 3]))) { i += 1 }
            return min(i + 3, bytes.count)
        }
    }

    /// Drops the catalog's XMP /Metadata stream and the trailer's /Info dictionary (both can hold
    /// author names, software and edit history), via an incremental update.
    static func removingCatalogMetadata(from data: Data) -> (data: Data, removed: Bool)? {
        guard let file = PDFFile(data: data), let rootRef = file.value(of: "Root", in: file.trailer),
              let root = Int(rootRef.split(separator: " ").first ?? ""), let catalog = file.dictionary(of: root) else { return nil }
        let hadMetadata = catalog.range(of: "/Metadata") != nil
        let cleaned = catalog.replacingOccurrences(of: #"/Metadata\s+\d+\s+\d+\s+R"#, with: "", options: .regularExpression)
        guard let updated = file.appendingObjects([(root, 0, cleaned.trimmingCharacters(in: .whitespacesAndNewlines))], dropInfo: true) else { return nil }
        return (updated, hadMetadata)
    }

    // MARK: Minimal PDF file access (classic xref table, as PDFKit writes)

    struct PDFFile {
        var data: Data
        let bytes: [UInt8]
        var offsets: [Int: Int] = [:]
        var trailer = ""
        var xrefOffset = 0
        var size = 0

        init?(data: Data) {
            self.data = data
            bytes = [UInt8](data)
            let tail = String(decoding: bytes.suffix(1024), as: UTF8.self)
            guard let sx = tail.range(of: "startxref", options: .backwards),
                  let offset = Int(tail[sx.upperBound...].split(whereSeparator: \.isWhitespace).first ?? "") else { return nil }
            xrefOffset = offset
            guard let table = parseXref(at: offset) else { return nil }
            offsets = table
        }

        private mutating func parseXref(at offset: Int) -> [Int: Int]? {
            // Read up to the end of the trailer, however long the table is (big documents have
            // tens of thousands of entries).
            guard offset < bytes.count,
                  let trailerAt = find(Array("startxref".utf8), from: offset),
                  let text = String(bytes: bytes[offset..<min(bytes.count, trailerAt + 9)], encoding: .isoLatin1),
                  text.hasPrefix("xref") else { return nil }
            var table: [Int: Int] = [:]
            let lines = text.components(separatedBy: CharacterSet(charactersIn: "\r\n")).filter { !$0.isEmpty }
            var i = 1
            while i < lines.count, !lines[i].hasPrefix("trailer") {
                let header = lines[i].split(separator: " ")
                guard header.count == 2, let first = Int(header[0]), let count = Int(header[1]) else { return nil }
                for k in 0..<count where i + 1 + k < lines.count {
                    let entry = lines[i + 1 + k].split(separator: " ")
                    if entry.count >= 3, entry[2].hasPrefix("n"), let off = Int(entry[0]) { table[first + k] = off }
                }
                i += 1 + count
            }
            guard let t = text.range(of: "trailer"), let end = text.range(of: "startxref", range: t.upperBound..<text.endIndex) else { return nil }
            trailer = String(text[t.upperBound..<end.lowerBound])
            size = Int(value(of: "Size", in: trailer) ?? "") ?? 0
            return text.contains("/Prev") && trailer.contains("/Prev") ? nil : table
        }

        /// The dictionary text of object `ref` (between `obj` and `stream`/`endobj`).
        func dictionary(of ref: Int) -> String? {
            guard let offset = offsets[ref], offset < bytes.count else { return nil }
            let chunk = String(decoding: bytes[offset..<min(bytes.count, offset + 4096)], as: UTF8.self)
            guard let obj = chunk.range(of: "obj") else { return nil }
            let rest = chunk[obj.upperBound...]
            let end = [rest.range(of: "stream")?.lowerBound, rest.range(of: "endobj")?.lowerBound].compactMap { $0 }.min() ?? rest.endIndex
            return String(rest[..<end])
        }

        func value(of key: String, in dict: String) -> String? {
            guard let r = dict.range(of: "/\(key)") else { return nil }
            let after = dict[r.upperBound...]
            guard let next = after.first, next == " " || next == "[" || next == "/" || next == "<" || next.isNumber else { return nil }
            let trimmed = after.drop { $0 == " " }
            if trimmed.hasPrefix("[") { return String(trimmed[...(trimmed.firstIndex(of: "]") ?? trimmed.endIndex)]) }
            let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "/" || $0 == ">" }).prefix(3)
            if parts.count == 3, parts[2] == "R" { return parts.joined(separator: " ") }
            return parts.first.map(String.init)
        }

        private func refs(in value: String) -> [(Int, Int)] {
            let parts = value.replacingOccurrences(of: "[", with: " ").replacingOccurrences(of: "]", with: " ")
                .split(separator: " ")
            var out: [(Int, Int)] = []
            var i = 0
            while i + 2 < parts.count {
                if parts[i + 2] == "R", let n = Int(parts[i]), let g = Int(parts[i + 1]) { out.append((n, g)); i += 3 } else { i += 1 }
            }
            return out
        }

        /// Content stream object numbers of the document's first page.
        func pageContentStreams() -> [(ref: Int, gen: Int)]? {
            guard let root = value(of: "Root", in: trailer).flatMap({ refs(in: $0).first?.0 }),
                  let catalog = dictionary(of: root),
                  var node = value(of: "Pages", in: catalog).flatMap({ refs(in: $0).first?.0 }) else { return nil }
            // Walk down /Kids to the first leaf page.
            for _ in 0..<16 {
                guard let dict = dictionary(of: node) else { return nil }
                if let kids = value(of: "Kids", in: dict), let first = refs(in: kids).first {
                    node = first.0
                    continue
                }
                guard let contents = value(of: "Contents", in: dict) else { return nil }
                return refs(in: contents).map { (ref: $0.0, gen: $0.1) }
            }
            return nil
        }

        func decodedStream(_ ref: Int) -> Data? {
            guard let offset = offsets[ref], let dict = dictionary(of: ref) else { return nil }
            var length = Int(value(of: "Length", in: dict) ?? "") ?? -1
            if length < 0, let lengthRef = value(of: "Length", in: dict).flatMap({ refs(in: $0).first?.0 }),
               let lengthObj = dictionary(of: lengthRef) {
                length = Int(lengthObj.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
            }
            let filter = value(of: "Filter", in: dict) ?? ""
            guard length >= 0, filter.isEmpty || filter.contains("FlateDecode"),
                  !filter.contains(" "), dict.range(of: "/DecodeParms") == nil else { return nil }
            // Find "stream" followed by EOL after the object header.
            guard let s = find(Array("stream".utf8), from: offset) else { return nil }
            var start = s + 6
            if start < bytes.count, bytes[start] == 0x0D { start += 1 }
            if start < bytes.count, bytes[start] == 0x0A { start += 1 }
            guard start + length <= bytes.count else { return nil }
            let raw = Data(bytes[start..<start + length])
            return filter.isEmpty ? raw : inflate(raw)
        }

        private func find(_ pattern: [UInt8], from: Int) -> Int? {
            var i = from
            while i + pattern.count <= bytes.count {
                if bytes[i] == pattern[0], Array(bytes[i..<i + pattern.count]) == pattern { return i }
                i += 1
            }
            return nil
        }

        /// Zlib-wrapped deflate (PDF FlateDecode) → bytes.
        private func inflate(_ data: Data) -> Data? {
            guard data.count > 6 else { return nil }
            let body = data.dropFirst(2) // zlib header; Compression's ZLIB is raw deflate
            var output = Data()
            let bufferSize = 1 << 16
            let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
            defer { stream.deallocate() }
            guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
            defer { compression_stream_destroy(stream) }
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { dst.deallocate() }
            return body.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
                stream.pointee.src_ptr = src.bindMemory(to: UInt8.self).baseAddress!
                stream.pointee.src_size = src.count
                while true {
                    stream.pointee.dst_ptr = dst
                    stream.pointee.dst_size = bufferSize
                    let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    output.append(dst, count: bufferSize - stream.pointee.dst_size)
                    if status == COMPRESSION_STATUS_END { return output }
                    if status == COMPRESSION_STATUS_ERROR { return output.isEmpty ? nil : output }
                    if stream.pointee.src_size == 0 && stream.pointee.dst_size == bufferSize { return output }
                }
            }
        }

        /// Appends replacement streams (uncompressed) as an incremental update.
        func appendingStreams(_ streams: [(ref: Int, gen: Int, bytes: Data)]) -> Data? {
            var bodies: [(Int, Int, Data)] = []
            for stream in streams {
                var body = Data("<< /Length \(stream.bytes.count) >>\nstream\n".utf8)
                body.append(stream.bytes)
                body.append(Data("\nendstream".utf8))
                bodies.append((stream.ref, stream.gen, body))
            }
            return appending(bodies, dropInfo: false)
        }

        /// Appends replacement objects (given as their dictionary text) as an incremental update.
        func appendingObjects(_ objects: [(ref: Int, gen: Int, text: String)], dropInfo: Bool) -> Data? {
            appending(objects.map { ($0.ref, $0.gen, Data($0.text.utf8)) }, dropInfo: dropInfo)
        }

        private func appending(_ objects: [(Int, Int, Data)], dropInfo: Bool) -> Data? {
            guard let root = value(of: "Root", in: trailer) else { return nil }
            var out = data
            if out.last != 0x0A { out.append(0x0A) }
            var entries: [(Int, Int, Int)] = []
            for (ref, gen, body) in objects {
                entries.append((ref, gen, out.count))
                out.append(Data("\(ref) \(gen) obj\n".utf8))
                out.append(body)
                out.append(Data("\nendobj\n".utf8))
            }
            let xref = out.count
            var table = "xref\n"
            for (ref, gen, offset) in entries.sorted(by: { $0.0 < $1.0 }) {
                table += "\(ref) 1\n" + String(format: "%010d %05d n \n", offset, gen)
            }
            var trailerDict = "/Size \(size) /Root \(root) /Prev \(xrefOffset)"
            if !dropInfo, let info = value(of: "Info", in: trailer) { trailerDict += " /Info \(info)" }
            if let id = trailer.range(of: "/ID"), let close = trailer[id.upperBound...].firstIndex(of: "]") {
                trailerDict += " " + trailer[id.lowerBound...close]
            }
            table += "trailer\n<< \(trailerDict) >>\nstartxref\n\(xref)\n%%EOF\n"
            out.append(Data(table.utf8))
            return out
        }
    }
}
