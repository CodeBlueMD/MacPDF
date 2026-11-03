import CoreImage
import CoreText
import PDFKit
import Vision

extension DocumentModel {
    /// Runs OCR on every page that has no real text and replaces each with a copy that looks
    /// identical but carries an invisible, searchable text layer. One undo step for the whole run.
    func recognizeText() {
        let pages = (0..<pdf.pageCount).compactMap(pdf.page(at:)).filter(OCR.needsText)
        guard !pages.isEmpty else {
            message = "Every page already has selectable text."
            return
        }
        processPages(pages, title: "Recognizing text", actionName: "Recognize Text") { page in
            await OCR.searchable(page)
        } done: { [weak self] changed in
            self?.message = changed == 0
                ? "No text was found on the scanned pages."
                : "Recognized text on \(changed) of \(pages.count) scanned page(s). You can now search, select and copy it."
        }
    }

    /// Runs `transform` on each page with a progress bar, then swaps in all results as one undo step.
    func processPages(_ pages: [PDFPage], title: String, actionName: String,
                      transform: @escaping (PDFPage) async -> PDFPage?,
                      done: ((Int) -> Void)? = nil) {
        guard progress == nil, !pages.isEmpty else { return }
        progress = TaskProgress(title: title, fraction: 0)
        Task { @MainActor in
            var replacements: [(PDFPage, PDFPage)] = []
            for (i, page) in pages.enumerated() {
                if let new = await transform(page) { replacements.append((page, new)) }
                progress?.fraction = Double(i + 1) / Double(pages.count)
            }
            grouped(actionName) {
                for (old, new) in replacements { replace(old, with: new) }
            }
            progress = nil
            done?(replacements.count)
        }
    }
}

enum OCR {
    typealias Line = (text: String, box: CGRect)
    typealias Fill = (rect: CGRect, color: NSColor)

    /// A page counts as scanned when it has almost no extractable text.
    static func needsText(_ page: PDFPage) -> Bool {
        (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count < 20
    }

    /// Draws the page's own content (no PDFKit annotations, no rotation) in media box coordinates.
    static func drawContent(of page: PDFPage, in ctx: CGContext) {
        if let ref = page.pageRef {
            ctx.drawPDFPage(ref)
        } else {
            let annotations = page.annotations
            annotations.forEach(page.removeAnnotation)
            page.draw(with: .mediaBox, to: ctx)
            annotations.forEach(page.addAnnotation)
        }
    }

    /// Renders the page to a bitmap. `fills` are painted over the content in page coordinates.
    static func render(_ page: PDFPage, dpi: CGFloat = 300, region: CGRect? = nil,
                       fills: [Fill] = [], includeAnnotations: Bool = false) -> CGImage? {
        render(area: region ?? page.bounds(for: .mediaBox), dpi: dpi, fills: fills) { ctx in
            drawContent(of: page, in: ctx)
        } overlay: { ctx in
            guard includeAnnotations else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            page.annotations.filter { $0.shouldDisplay }.forEach { $0.draw(with: .mediaBox, in: ctx) }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Page-free rendering core; safe off the main thread when `content` only draws a CGPDFPage.
    static func render(area: CGRect, dpi: CGFloat, fills: [Fill],
                       content: (CGContext) -> Void, overlay: (CGContext) -> Void = { _ in }) -> CGImage? {
        let scale = dpi / 72
        let width = Int(area.width * scale), height = Int(area.height * scale)
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -area.minX, y: -area.minY)
        content(ctx)
        for fill in fills {
            ctx.setFillColor(fill.color.cgColor)
            ctx.fill(fill.rect)
        }
        overlay(ctx)
        return ctx.makeImage()
    }

    /// Text lines with normalized, bottom-left-origin bounding boxes (the same orientation as PDF space).
    static func recognize(_ image: CGImage) async -> [Line]? {
        await Task.detached(priority: .userInitiated) { recognizeNow(image) }.value
    }

    static func recognizeNow(_ image: CGImage) -> [Line]? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.compactMap { observation -> Line? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return (candidate.string, observation.boundingBox)
        }
    }

    static func pageRect(_ normalized: CGRect, in box: CGRect) -> CGRect {
        CGRect(x: box.minX + normalized.minX * box.width, y: box.minY + normalized.minY * box.height,
               width: normalized.width * box.width, height: normalized.height * box.height)
    }

    /// Builds a new page the size of `page`: `draw` paints its content, then each OCR line is written
    /// in invisible text over the matching spot so it can be searched and selected. Annotations that
    /// pass `keep` are carried over.
    static func makePage(like page: PDFPage, lines: [Line],
                         keep: (PDFAnnotation) -> Bool = { _ in true },
                         draw: (CGContext) -> Void) -> PDFPage? {
        guard let data = pageData(box: page.bounds(for: .mediaBox), lines: lines, draw: draw) else { return nil }
        return finishPage(data, like: page, keep: keep)
    }

    /// One-page PDF with `draw`'s content and invisible OCR text. Uses only Core Graphics, so it can
    /// run off the main thread.
    static func pageData(box mediaBox: CGRect, lines: [Line], draw: (CGContext) -> Void) -> Data? {
        var box = mediaBox
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }

        ctx.beginPDFPage(nil)
        draw(ctx)
        ctx.setTextDrawingMode(.invisible)
        for line in lines {
            let rect = pageRect(line.box, in: box)
            guard rect.width > 1, rect.height > 1 else { continue }
            let font = CTFontCreateWithName("Helvetica" as CFString, rect.height * 0.8, nil)
            let ctLine = CTLineCreateWithAttributedString(
                NSAttributedString(string: line.text, attributes: [.font: font]))
            let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            guard width > 0 else { continue }

            // Stretch horizontally so the invisible line spans the same width as the printed one,
            // which keeps selection highlights lined up with the image.
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: rect.minX, y: rect.minY + rect.height * 0.15)
            ctx.scaleBy(x: rect.width / CGFloat(width), y: 1)
            ctx.textPosition = .zero
            CTLineDraw(ctLine, ctx)
            ctx.restoreGState()
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    /// Wraps `pageData` output as a page matching `page`'s crop, rotation and kept annotations.
    static func finishPage(_ data: Data, like page: PDFPage, keep: (PDFAnnotation) -> Bool) -> PDFPage? {
        guard let document = PDFDocument(data: data),
              let newPage = document.page(at: 0)?.copy() as? PDFPage else { return nil }
        newPage.setBounds(page.bounds(for: .cropBox), for: .cropBox)
        newPage.rotation = page.rotation
        for annotation in page.annotations where keep(annotation) {
            if let copy = annotation.copy() as? PDFAnnotation { newPage.addAnnotation(copy) }
        }
        return newPage
    }

    /// Re-renders the page as a 300 dpi image with `fills` painted in (and an optional image filter),
    /// then restores a searchable text layer with OCR. Text under the fills is gone for good.
    /// Rendering, filtering, OCR and PDF encoding all run in the background; only the final page
    /// swap touches PDFKit on the main thread.
    static func rasterized(_ page: PDFPage, fills: [Fill], filter: ((CIImage) -> CIImage)? = nil,
                           keep: (PDFAnnotation) -> Bool) async -> PDFPage? {
        let box = page.bounds(for: .mediaBox)
        let data: Data?
        if let ref = page.pageRef {
            data = await Task.detached(priority: .userInitiated) {
                rasterData(box: box, fills: fills, filter: filter) { $0.drawPDFPage(ref) }
            }.value
        } else {
            data = rasterData(box: box, fills: fills, filter: filter) { drawContent(of: page, in: $0) }
        }
        return data.flatMap { finishPage($0, like: page, keep: keep) }
    }

    private static func rasterData(box: CGRect, fills: [Fill], filter: ((CIImage) -> CIImage)?,
                                   content: (CGContext) -> Void) -> Data? {
        guard var image = render(area: box, dpi: 300, fills: fills, content: content) else { return nil }
        if let filter {
            let input = CIImage(cgImage: image)
            if let output = CIContext().createCGImage(filter(input), from: input.extent) { image = output }
        }
        let lines = (recognizeNow(image) ?? []).filter { line in
            !fills.contains { $0.rect.intersects(pageRect(line.box, in: box)) }
        }
        return pageData(box: box, lines: lines) { $0.draw(image, in: box) }
    }

    /// Adds an invisible OCR text layer, keeping the page's original (vector) content.
    static func searchable(_ page: PDFPage) async -> PDFPage? {
        let box = page.bounds(for: .mediaBox)
        let work: (@escaping (CGContext) -> Void) -> Data? = { content in
            guard let image = render(area: box, dpi: 300, fills: [], content: content),
                  let lines = recognizeNow(image), !lines.isEmpty else { return nil }
            return pageData(box: box, lines: lines, draw: content)
        }
        let data: Data?
        if let ref = page.pageRef {
            data = await Task.detached(priority: .userInitiated) { work { $0.drawPDFPage(ref) } }.value
        } else {
            data = work { drawContent(of: page, in: $0) }
        }
        return data.flatMap { finishPage($0, like: page) { _ in true } }
    }
}
