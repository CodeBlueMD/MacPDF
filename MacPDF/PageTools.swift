import CoreImage
import PDFKit
import SwiftUI

// MARK: Redaction

/// Undo target for redaction marks that haven't been burned in yet.
final class BurnToken {}

extension DocumentModel {
    var redactionColor: NSColor { NSColor(toolColors[.redact] ?? Tool.redact.defaultColor) }

    func redact(_ selection: PDFSelection) {
        for line in selection.selectionsByLine() {
            for page in line.pages {
                addRedaction(line.bounds(for: page).insetBy(dx: -1, dy: -1), on: page)
            }
        }
    }

    /// Shows a solid box at once, then (a moment later, so several selections batch together)
    /// permanently removes what's underneath. The rest of the page stays selectable via OCR.
    func addRedaction(_ rect: CGRect, on page: PDFPage) {
        guard rect.width > 1, rect.height > 1 else { return }
        let mark = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
        Self.styleRedaction(mark, color: redactionColor)
        page.addAnnotation(mark)
        refresh(page)
        annotationsVersion += 1
        // Undo before the burn finishes just takes the mark back off. Registered on a per-page token
        // so the finished burn can drop these entries and replace them with its own single undo step.
        let token = burnTokens[ObjectIdentifier(page)] ?? BurnToken()
        burnTokens[ObjectIdentifier(page)] = token
        undoManager?.registerUndo(withTarget: token) { [weak self] _ in self?.withdrawRedaction(mark, on: page) }
        undoManager?.setActionName("Redact")
        scheduleBurn(page)
    }

    private func withdrawRedaction(_ mark: PDFAnnotation, on page: PDFPage) {
        page.removeAnnotation(mark)
        refresh(page)
        annotationsVersion += 1
        if page.annotations.contains(where: { $0.tag == .redaction }) {
            scheduleBurn(page)
        } else {
            burnTasks[ObjectIdentifier(page)]?.cancel()
            burnTasks[ObjectIdentifier(page)] = nil
        }
    }

    static func styleRedaction(_ mark: PDFAnnotation, color: NSColor) {
        mark.color = color
        mark.interiorColor = color
        mark.border = border(0)
        mark.tag = .redaction
    }

    func scheduleBurn(_ page: PDFPage) {
        let key = ObjectIdentifier(page)
        burnTasks[key]?.cancel()
        burnTasks[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            await self.burnRedactions(on: page)
            if !Task.isCancelled { self.burnTasks[key] = nil }
        }
    }

    @MainActor
    private func burnRedactions(on page: PDFPage) async {
        let marks = page.annotations.filter { $0.tag == .redaction }
        guard !marks.isEmpty, pdf.index(for: page) != NSNotFound else { return }
        let fills = marks.map { (rect: $0.bounds, color: ($0.interiorColor ?? .black).withAlphaComponent(1)) }
        let flattened = await OCR.rasterized(page, fills: fills) { annotation in
            annotation.tag != .redaction && !fills.contains { $0.rect.intersects(annotation.bounds) }
        }
        // A newer mark on this page restarted the burn; that run will include these marks too.
        guard !Task.isCancelled, let flattened else { return }
        // Swap the per-mark undo entries for one page-level step that brings back the clean original.
        if let token = burnTokens.removeValue(forKey: ObjectIdentifier(page)) {
            undoManager?.removeAllActions(withTarget: token)
        }
        marks.forEach(page.removeAnnotation)
        replace(page, with: flattened, actionName: "Redact")
    }
}

// MARK: Edit tools

extension DocumentModel {
    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose an image, then click or drag on the page to place it"
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        pendingImage = image
        tool = .image
    }

    /// Draws the image into the page itself (the page's text and vectors are kept).
    func placeImage(in rect: CGRect, on page: PDFPage) {
        guard let image = pendingImage,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        var target = rect
        if rect.width < 10 || rect.height < 10 {
            let width = min(200, image.size.width)
            let height = width * image.size.height / max(image.size.width, 1)
            target = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        }
        guard let new = OCR.makePage(like: page, lines: [], draw: { ctx in
            OCR.drawContent(of: page, in: ctx)
            ctx.draw(cgImage, in: target)
        }) else { return }
        replace(page, with: new, actionName: "Insert Image")
        pendingImage = nil
        tool = .select
    }

    func addLink(in rect: CGRect, on page: PDFPage) {
        guard rect.width > 3, rect.height > 3 else { return }
        let alert = NSAlert()
        alert.messageText = "Add Link"
        alert.informativeText = "Web address for this area:"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "https://example.com"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var text = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text) else { return }

        let link = PDFAnnotation(bounds: rect, forType: .link, withProperties: nil)
        link.url = url
        link.border = Self.border(0)
        add(link, to: page)
        showToast("Link added")
    }

    func copyArea(_ rect: CGRect, on page: PDFPage) {
        guard rect.width > 3, rect.height > 3,
              let image = OCR.render(page, dpi: 200, region: rect, includeAnnotations: true) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: rect.size)])
        showToast("Copied to clipboard")
    }
}

// MARK: Scan tools

extension DocumentModel {
    /// Asks whether to act on the current page or all pages. Nil means cancelled.
    func askScope(_ title: String, detail: String) -> [PDFPage]? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "All Pages")
        alert.addButton(withTitle: "Current Page")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return (0..<pdf.pageCount).compactMap(pdf.page(at:))
        case .alertSecondButtonReturn: return pdfView.currentPage.map { [$0] }
        default: return nil
        }
    }

    func enhanceScans() {
        guard let pages = askScope("Enhance Scan",
                                   detail: "Cleans up the background and sharpens text. Pages become images with searchable text.")
        else { return }
        processPages(pages, title: "Enhancing", actionName: "Enhance Scan") { page in
            await OCR.rasterized(page, fills: [], filter: { image in
                image.applyingFilter("CIDocumentEnhancer", parameters: ["inputAmount": 1.0])
            }, keep: { _ in true })
        }
    }

    /// Paints a white border of `margin` points around each page, hiding dark scan edges.
    func clearMargins(_ margin: CGFloat, allPages: Bool) {
        let pages = allPages ? (0..<pdf.pageCount).compactMap(pdf.page(at:)) : pdfView.currentPage.map { [$0] } ?? []
        processPages(pages, title: "Clearing margins", actionName: "Clear Margins") { page in
            let box = page.bounds(for: .mediaBox)
            let inner = box.insetBy(dx: margin, dy: margin)
            let frame = [
                CGRect(x: box.minX, y: box.minY, width: box.width, height: margin),
                CGRect(x: box.minX, y: inner.maxY, width: box.width, height: margin),
                CGRect(x: box.minX, y: box.minY, width: margin, height: box.height),
                CGRect(x: inner.maxX, y: box.minY, width: margin, height: box.height),
            ].map { (rect: $0, color: NSColor.white) }
            return await OCR.rasterized(page, fills: frame) { annotation in inner.intersects(annotation.bounds) }
        }
    }

    /// Splits two-page book scans into separate left and right pages.
    func splitPages() {
        guard let pages = askScope("Split Pages", detail: "Each page is cut down the middle into a left and a right page.")
        else { return }
        grouped("Split Pages") {
            for page in pages {
                let box = page.bounds(for: .cropBox)
                let halves = [
                    CGRect(x: box.minX, y: box.minY, width: box.width / 2, height: box.height),
                    CGRect(x: box.midX, y: box.minY, width: box.width / 2, height: box.height),
                ]
                let newPages = halves.compactMap { half -> PDFPage? in
                    guard let copy = page.copy() as? PDFPage else { return nil }
                    copy.setBounds(half, for: .cropBox)
                    return copy
                }
                if newPages.count == 2 { replacePage(page, with: newPages) }
            }
        }
    }

    func crop(to rect: CGRect, on page: PDFPage) {
        guard rect.width > 10, rect.height > 10,
              let pages = askScope("Crop Pages", detail: "Hide everything outside the box you drew.") else { return }
        grouped("Crop") {
            for target in pages { setCrop(rect, on: target) }
        }
        tool = .select
    }

    private func setCrop(_ rect: CGRect, on page: PDFPage) {
        let old = page.bounds(for: .cropBox)
        page.setBounds(rect.intersection(page.bounds(for: .mediaBox)), for: .cropBox)
        undoManager?.registerUndo(withTarget: self) { $0.setCrop(old, on: page) }
        pdfView.layoutDocumentView()
    }
}

// MARK: Measure

extension DocumentModel {
    private static func measure(_ points: CGFloat) -> String {
        let inches = points / 72
        return String(format: "%.2f in (%.1f cm)", inches, inches * 2.54)
    }

    private func addLabel(_ text: String, at point: CGPoint, on page: PDFPage) {
        let font = NSFont.systemFont(ofSize: 10, weight: .medium)
        let size = (text as NSString).size(withAttributes: [.font: font])
        let label = PDFAnnotation(bounds: Self.fit(CGRect(x: point.x - size.width / 2, y: point.y, width: 0, height: 0),
                                                   text: text, font: font),
                                  forType: .freeText, withProperties: nil)
        Self.style(label, font: font, textColor: nsColor, background: NSColor.white.withAlphaComponent(0.85))
        label.contents = text
        label.tag = .measurement
        add(label, to: page)
    }

    func addDistance(from start: CGPoint, to end: CGPoint, on page: PDFPage) {
        let length = hypot(end.x - start.x, end.y - start.y)
        guard length > 3 else { return }
        grouped("Measure Distance") {
            let line = Self.line(from: start, to: end, color: nsColor, width: 1.5, start: .openArrow, end: .openArrow)
            line.tag = .measurement
            add(line, to: page)
            addLabel(Self.measure(length), at: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 + 4), on: page)
        }
    }

    func addArea(_ rect: CGRect, on page: PDFPage) {
        guard rect.width > 3, rect.height > 3 else { return }
        let w = rect.width / 72, h = rect.height / 72
        let text = String(format: "%.2f × %.2f in = %.2f in² (%.1f cm²)", w, h, w * h, w * h * 6.4516)
        grouped("Measure Area") {
            let box = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
            box.color = nsColor
            box.border = Self.border(1.5, dashed: true)
            box.tag = .measurement
            add(box, to: page)
            addLabel(text, at: CGPoint(x: rect.midX, y: rect.midY - 6), on: page)
        }
    }
}
