import AppKit
import PDFKit
import UniformTypeIdentifiers

/// An image that's part of the page's content, selected with Edit → Image.
struct ImageSelection: Equatable {
    let page: PDFPage
    /// Where the image currently sits, in page coordinates.
    var rect: CGRect
    /// Position among the page's top-level objects (PDFium's numbering).
    let index: Int

    static func == (a: ImageSelection, b: ImageSelection) -> Bool {
        a.page === b.page && a.rect == b.rect && a.index == b.index
    }
}

extension DocumentModel {
    private final class ImageRects {
        let items: [(index: Int, rect: CGRect)]
        init(_ items: [(index: Int, rect: CGRect)]) { self.items = items }
    }
    private static let imageRectCache = NSMapTable<PDFPage, ImageRects>.weakToStrongObjects()

    /// The page's images and where they are. Cached per page; every edit produces a new page.
    func imageRects(on page: PDFPage) -> [(index: Int, rect: CGRect)] {
        if let cached = Self.imageRectCache.object(forKey: page) { return cached.items }
        let found = PDFium.read(page) { editor in editor.imageObjects.map { (index: $0.index, rect: $0.bounds) } } ?? []
        Self.imageRectCache.setObject(ImageRects(found), forKey: page)
        return found
    }

    func image(at point: CGPoint, on page: PDFPage) -> ImageSelection? {
        imageRects(on: page).last { $0.rect.contains(point) }.map { ImageSelection(page: page, rect: $0.rect, index: $0.index) }
    }

    /// Moves/resizes the selected image so it fills `rect`.
    func moveSelectedImage(to rect: CGRect) {
        guard let selection = selectedImage, rect.width > 2, rect.height > 2, rect != selection.rect else { return }
        let old = selection.rect
        let t = CGAffineTransform(translationX: -old.minX, y: -old.minY)
            .concatenating(CGAffineTransform(scaleX: rect.width / old.width, y: rect.height / old.height))
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY))
        transformSelectedImage(by: t, actionName: "Move Image")
    }

    func rotateSelectedImage(by degrees: CGFloat) {
        guard let selection = selectedImage else { return }
        let c = CGPoint(x: selection.rect.midX, y: selection.rect.midY)
        let t = CGAffineTransform(translationX: -c.x, y: -c.y)
            .concatenating(CGAffineTransform(rotationAngle: degrees * .pi / 180))
            .concatenating(CGAffineTransform(translationX: c.x, y: c.y))
        transformSelectedImage(by: t, actionName: "Rotate Image")
    }

    /// Applies `t` (page coordinates) to the image. Done by wrapping its drawing command in an extra
    /// transform, so the rest of the page content is untouched; PDFium is the fallback.
    private func transformSelectedImage(by t: CGAffineTransform, actionName: String) {
        guard let selection = selectedImage else { return }
        let page = selection.page
        let edited = ContentSurgery.edit(page) { ops in
            guard let op = Self.drawCommand(for: selection, in: ops), let name = op.operands.first?.text else { return [] }
            // The image draws with CTM C; we want C·T. An `X cm` just before `Do` gives X·C, so X = C·T·C⁻¹.
            let x = op.ctm.concatenating(t).concatenating(op.ctm.inverted())
            // PDF numbers can't use exponents (a 90° turn gives values like 6e-17).
            let m = [x.a, x.b, x.c, x.d, x.tx, x.ty].map { String(format: "%.6f", abs($0) < 1e-9 ? 0 : $0) }.joined(separator: " ")
            return [(op, "q \(m) cm \(name) Do Q")]
        } ?? PDFium.edit(page) { editor in
            guard let object = editor.objects.first(where: { $0.index == selection.index }) else { return false }
            editor.transform(object, by: t)
            return true
        }
        guard let edited else { return }
        replace(page, with: edited, actionName: actionName)
        selectedImage = ImageSelection(page: edited, rect: selection.rect.applying(t), index: selection.index)
    }

    func deleteSelectedImage() {
        guard let selection = selectedImage else { return }
        let page = selection.page
        let edited = ContentSurgery.edit(page) { ops in
            Self.drawCommand(for: selection, in: ops).map { [($0, "")] } ?? []
        } ?? PDFium.edit(page) { editor in
            guard let object = editor.objects.first(where: { $0.index == selection.index }) else { return false }
            editor.remove(object)
            return true
        }
        guard let edited else { return }
        replace(page, with: edited, actionName: "Delete Image")
        selectedImage = nil
    }

    /// The `Do` command that draws the selected image: the one whose placement matches its bounds.
    private static func drawCommand(for selection: ImageSelection, in ops: [ContentSurgery.Operation]) -> ContentSurgery.Operation? {
        ops.filter { $0.op == "Do" }.min { a, b in
            distance(CGRect(x: 0, y: 0, width: 1, height: 1).applying(a.ctm), selection.rect)
                < distance(CGRect(x: 0, y: 0, width: 1, height: 1).applying(b.ctm), selection.rect)
        }.flatMap { op in
            distance(CGRect(x: 0, y: 0, width: 1, height: 1).applying(op.ctm), selection.rect) < 2 ? op : nil
        }
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.maxX - b.maxX) + abs(a.maxY - b.maxY)
    }

    func exportSelectedImage() {
        guard let selection = selectedImage,
              let image = PDFium.read(selection.page, { editor in
                  editor.objects.first { $0.index == selection.index }.flatMap(editor.image(of:))
              }),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(fileName) image.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try png.write(to: url)
            showToast("Image exported")
        } catch {
            message = "Couldn't export the image: \(error.localizedDescription)"
        }
    }

    /// Swaps the picture for another file, keeping its size and position.
    func replaceSelectedImage() {
        guard let selection = selectedImage else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url,
              let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        guard let edited = PDFium.edit(selection.page, { editor in
            guard let object = editor.objects.first(where: { $0.index == selection.index }) else { return false }
            return editor.replaceImage(of: object, with: image)
        }) else {
            message = "Couldn't replace this image."
            return
        }
        replace(selection.page, with: edited, actionName: "Replace Image")
        selectedImage = ImageSelection(page: edited, rect: selection.rect, index: selection.index)
    }
}
