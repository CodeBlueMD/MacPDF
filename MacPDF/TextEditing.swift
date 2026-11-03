import AppKit
import PDFKit

/// Font, size, color and alignment of the paragraph being edited; the Edit → Text panel binds to it.
struct TextStyle: Equatable {
    var font: NSFont
    var color: NSColor
    var alignment: NSTextAlignment
    /// Distance between baselines, in points.
    var lineHeight: CGFloat

    var size: CGFloat {
        get { font.pointSize }
        set { font = NSFont(descriptor: font.fontDescriptor, size: max(newValue, 4)) ?? font }
    }

    var isBold: Bool { NSFontManager.shared.traits(of: font).contains(.boldFontMask) }
    var isItalic: Bool { NSFontManager.shared.traits(of: font).contains(.italicFontMask) }

    mutating func toggle(_ trait: NSFontTraitMask) {
        let manager = NSFontManager.shared
        font = manager.traits(of: font).contains(trait)
            ? manager.convert(font, toNotHaveTrait: trait)
            : manager.convert(font, toHaveTrait: trait)
    }

    mutating func setFamily(_ family: String) {
        let manager = NSFontManager.shared
        font = manager.font(withFamily: family, traits: manager.traits(of: font), weight: 5, size: size)
            ?? NSFont(name: family, size: size) ?? font
    }
}

/// A paragraph of the page's own text: neighbouring lines with the same font size and spacing.
struct TextBlock {
    var rect: CGRect
    var text: String
    var style: TextStyle
    /// Single lines (headings, labels) grow sideways while typing instead of wrapping.
    var wraps: Bool
    /// False for a new text box, which has nothing to remove when it's written.
    var replacesText = true

    static func at(_ point: CGPoint, on page: PDFPage) -> TextBlock? {
        guard let all = page.selection(for: page.bounds(for: .mediaBox))?.selectionsByLine() else { return nil }
        let lines = all.compactMap { Line($0, page: page) }
        guard let hit = lines.firstIndex(where: { $0.bounds.insetBy(dx: -3, dy: -2).contains(point) }) else { return nil }

        var first = hit, last = hit
        while first > 0, lines[first - 1].continues(into: lines[first]) { first -= 1 }
        while last < lines.count - 1, lines[last].continues(into: lines[last + 1]) { last += 1 }
        let group = Array(lines[first...last])

        var text = ""
        for line in group {
            if text.isEmpty || text.hasSuffix("-") { text += line.text } else { text += " " + line.text }
        }
        let rect = group.dropFirst().reduce(group[0].bounds) { $0.union($1.bounds) }
        let font = FontData.installed(matching: group[0].font, size: group[0].font.pointSize)
        let lineHeight = group.count > 1
            ? (group.first!.bounds.maxY - group.last!.bounds.maxY) / CGFloat(group.count - 1)
            : group[0].bounds.height
        return TextBlock(rect: rect, text: text,
                         style: TextStyle(font: font, color: group[0].color,
                                          alignment: alignment(of: group, on: page), lineHeight: lineHeight),
                         wraps: group.count > 1)
    }

    private static func alignment(of lines: [Line], on page: PDFPage) -> NSTextAlignment {
        guard lines.count > 1 else {
            // A lone line centred on the page (a title) stays centred when its length changes.
            let pageMid = page.bounds(for: .cropBox).midX
            return abs(lines[0].bounds.midX - pageMid) < 6 ? .center : .left
        }
        let lefts = lines.map(\.bounds.minX), mids = lines.map(\.bounds.midX)
        if (lefts.max()! - lefts.min()!) < 2 { return .left }
        if (mids.max()! - mids.min()!) < 2 { return .center }
        return .right
    }

    struct Line {
        let bounds: CGRect
        let text: String
        let font: NSFont
        let color: NSColor

        /// PDFKit reports each image as a one-character "line" holding U+FFFC (object replacement).
        private static let notText = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FFFC}"))

        init?(_ selection: PDFSelection, page: PDFPage) {
            let text = (selection.string ?? "").trimmingCharacters(in: .newlines)
            let bounds = selection.bounds(for: page)
            guard !text.trimmingCharacters(in: Self.notText).isEmpty, bounds.height > 0,
                  let attributed = selection.attributedString, attributed.length > 0 else { return nil }
            let attributes = attributed.attributes(at: 0, effectiveRange: nil)
            self.bounds = bounds
            self.text = text
            self.font = (attributes[.font] as? NSFont) ?? .systemFont(ofSize: bounds.height * 0.8)
            self.color = (attributes[.foregroundColor] as? NSColor) ?? .black
        }

        /// Whether `next` (the following line in reading order) belongs to the same paragraph.
        func continues(into next: Line) -> Bool {
            let gap = bounds.minY - next.bounds.maxY
            let overlap = min(bounds.maxX, next.bounds.maxX) - max(bounds.minX, next.bounds.minX)
            return abs(font.pointSize - next.font.pointSize) < 0.75
                && next.bounds.midY < bounds.midY
                && gap > -bounds.height * 0.3 && gap < bounds.height * 0.9
                && overlap > min(bounds.width, next.bounds.width) * 0.3
        }
    }
}

/// Lays text out the way the editor shows it and returns each line with its baseline origin on the page.
enum TextLayout {
    static func lines(_ text: String, style: TextStyle, in rect: CGRect, wraps: Bool) -> [(String, CGPoint)] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style.alignment
        paragraph.minimumLineHeight = style.lineHeight
        paragraph.maximumLineHeight = style.lineHeight
        let attributed = NSAttributedString(string: text, attributes: [.font: style.font, .paragraphStyle: paragraph])

        let width = wraps ? rect.width : max(rect.width, ceil(attributed.size().width) + 2)
        let height: CGFloat = 100_000
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil), nil)
        let ctLines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: ctLines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        // A non-wrapping centred line keeps its centre; otherwise the box keeps its left edge.
        let left = (!wraps && style.alignment == .center) ? rect.midX - width / 2 : rect.minX
        // Estimated from the font; writeBlock snaps it to the original text's real baseline.
        let firstBaseline = rect.maxY - style.font.ascender
        let topOrigin = origins.first?.y ?? height
        let nsText = text as NSString
        return zip(ctLines, origins).compactMap { line, origin in
            let range = CTLineGetStringRange(line)
            let string = nsText.substring(with: NSRange(location: range.location, length: range.length))
                .trimmingCharacters(in: .newlines)
            guard !string.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let trimmed = string.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            return (trimmed, CGPoint(x: left + origin.x, y: firstBaseline - (topOrigin - origin.y)))
        }
    }
}

extension DocumentModel {
    /// Edit → Text on the page's own text: click a paragraph, retype it, and it's rewritten in place.
    func beginBlockEdit(at point: CGPoint, on page: PDFPage) {
        beginBlockEdit(TextBlock.at(point, on: page) ?? newBlock(at: point, on: page), on: page)
    }

    func beginBlockEdit(_ block: TextBlock, on page: PDFPage) {
        textStyle = block.style
        pdfView.beginBlockEdit(block, on: page) { [weak self] text in
            guard let self, let text else {
                self?.textStyle = nil
                return
            }
            let style = self.textStyle ?? block.style
            self.textStyle = nil
            guard text != block.text || style != block.style else { return }
            self.writeBlock(block, text: text, style: style, on: page)
        }
    }

    private func newBlock(at point: CGPoint, on page: PDFPage) -> TextBlock {
        let font = NSFont(name: "Helvetica", size: 12) ?? .systemFont(ofSize: 12)
        let style = TextStyle(font: font, color: .black, alignment: .left, lineHeight: 14.4)
        let rect = CGRect(x: point.x, y: point.y - 7, width: 200, height: 14.4)
        return TextBlock(rect: rect, text: "", style: style, wraps: false, replacesText: false)
    }

    /// Removes the paragraph's original text and writes the new lines in the chosen font.
    /// The old text is cut out of the page's drawing commands directly, so nothing else on the page
    /// changes; PDFium then only adds the new text.
    /// Drag-to-move for a paragraph: rewrites the same text `offset` points away.
    func moveBlock(_ block: TextBlock, by offset: CGPoint, on page: PDFPage) {
        writeBlock(block, text: block.text, style: block.style, on: page, offset: offset, actionName: "Move Text")
    }

    func writeBlock(_ block: TextBlock, text: String, style: TextStyle, on page: PDFPage,
                    offset: CGPoint = .zero, actionName: String = "Edit Text") {
        let lines = TextLayout.lines(text, style: style, in: block.rect, wraps: block.wraps)
        var base = page
        var shift = CGPoint.zero
        var removeWithPDFium = false

        if block.replacesText {
            let region = block.rect.insetBy(dx: -2, dy: -1)
            if let (cleaned, origins) = ContentSurgery.removingText(in: region, from: page), !origins.isEmpty {
                base = cleaned
                // Sit the new text on the original first baseline (and left edge when left-aligned).
                if let top = origins.map(\.y).max(), let first = lines.first {
                    shift.y = top - first.1.y
                    if style.alignment == .left, let left = origins.map(\.x).min() { shift.x = left - first.1.x }
                }
            } else {
                removeWithPDFium = true // e.g. compressed in a way the direct path doesn't read
            }
        }

        let target = block.rect.insetBy(dx: -1, dy: -style.lineHeight * 0.25)
        let edited = PDFium.edit(base) { editor in
            if removeWithPDFium {
                let originals = editor.textObjects.filter { target.contains(CGPoint(x: $0.bounds.midX, y: $0.bounds.midY)) }
                if let first = originals.max(by: { $0.bounds.maxY < $1.bounds.maxY }),
                   let baseline = editor.origin(of: first), let firstLine = lines.first {
                    shift.y = baseline.y - firstLine.1.y
                    if style.alignment == .left, let leftmost = originals.compactMap(editor.origin(of:)).map(\.x).min() {
                        shift.x = leftmost - firstLine.1.x
                    }
                }
                // Nothing to replace means the click wasn't really on text; don't add a copy.
                guard !originals.isEmpty else { return false }
                originals.forEach(editor.remove)
            }
            guard !lines.isEmpty else { return true }
            guard let font = editor.load(style.font) else { return false }
            for (line, origin) in lines {
                editor.addText(line, font: font, size: style.size, color: style.color,
                               at: CGPoint(x: origin.x + shift.x + offset.x, y: origin.y + shift.y + offset.y))
            }
            return true
        }
        guard let edited else {
            message = "Couldn't rewrite this text. The PDF's text may be stored in a way MacPDF can't edit yet."
            return
        }
        replace(page, with: edited, actionName: actionName)
    }
}
