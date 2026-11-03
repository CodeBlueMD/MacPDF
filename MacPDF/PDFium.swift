import AppKit
import PDFKit

/// Rewrites a page's content (its text and image objects) with PDFium, which PDFKit can't do.
/// Each edit runs on a one-page copy and returns a new page to swap in, so PDFKit stays the
/// document model and undo is a page swap like every other page-level change.
enum PDFium {
    private static let initialized: Void = FPDF_InitLibrary()

    /// FPDF_SaveAsCopy streams its output through a C callback; PDFium is only used on the main thread.
    private static var output = Data()

    /// Opens a one-page copy of `page`, runs `body`, and returns the rewritten page with its
    /// annotations, crop box and rotation intact. Returns nil if `body` returns false or PDFium fails.
    static func edit(_ page: PDFPage, _ body: (PageEditor) -> Bool) -> PDFPage? {
        withPage(page) { editor in
            guard body(editor) else { return nil }
            if editor.changedExistingObjects { editor.pinColors() }
            guard FPDFPage_GenerateContent(editor.page) != 0,
                  let data = save(editor.doc) else { return nil }
            return PDFDocument(data: data)?.page(at: 0)?.copy() as? PDFPage
        }
    }

    /// Read-only access to the page's objects.
    static func read<T>(_ page: PDFPage, _ body: (PageEditor) -> T?) -> T? {
        withPage(page, body)
    }

    private static func withPage<T>(_ page: PDFPage, _ body: (PageEditor) -> T?) -> T? {
        _ = initialized
        let single = PDFDocument()
        guard let copy = page.copy() as? PDFPage else { return nil }
        single.insert(copy, at: 0)
        guard let input = single.dataRepresentation() else { return nil }
        return input.withUnsafeBytes { raw -> T? in
            guard let doc = FPDF_LoadMemDocument64(raw.baseAddress, raw.count, nil) else { return nil }
            defer { FPDF_CloseDocument(doc) }
            guard let fpage = FPDF_LoadPage(doc, 0) else { return nil }
            defer { FPDF_ClosePage(fpage) }
            let editor = PageEditor(doc: doc, page: fpage)
            defer { editor.closeFonts() }
            return body(editor)
        }
    }

    /// Deletes every embedded attachment from a whole document; pages are saved as they are.
    static func removingAttachments(from data: Data) -> (data: Data, count: Int)? {
        _ = initialized
        return data.withUnsafeBytes { raw -> (Data, Int)? in
            guard let doc = FPDF_LoadMemDocument64(raw.baseAddress, raw.count, nil) else { return nil }
            defer { FPDF_CloseDocument(doc) }
            let count = Int(FPDFDoc_GetAttachmentCount(doc))
            guard count > 0 else { return (data, 0) }
            for i in stride(from: count - 1, through: 0, by: -1) { FPDFDoc_DeleteAttachment(doc, Int32(i)) }
            return save(doc).map { ($0, count) }
        }
    }

    private static func save(_ doc: FPDF_DOCUMENT) -> Data? {
        output = Data()
        var writer = FPDF_FILEWRITE()
        writer.version = 1
        writer.WriteBlock = { _, bytes, size in
            if let bytes { PDFium.output.append(bytes.assumingMemoryBound(to: UInt8.self), count: Int(size)) }
            return 1
        }
        guard FPDF_SaveAsCopy(doc, &writer, FPDF_DWORD(FPDF_NO_INCREMENTAL)) != 0 else { return nil }
        defer { output = Data() }
        return output
    }
}

final class PageEditor {
    let doc: FPDF_DOCUMENT
    let page: FPDF_PAGE
    private var fonts: [FPDF_FONT] = []
    /// Removing or moving an existing object makes PDFium regenerate the whole content stream;
    /// only adding objects leaves the original content untouched.
    private(set) var changedExistingObjects = false

    init(doc: FPDF_DOCUMENT, page: FPDF_PAGE) {
        self.doc = doc
        self.page = page
    }

    struct Object {
        let handle: FPDF_PAGEOBJECT
        let index: Int
        let type: Int32
        /// In page (PDF user space) coordinates, same as PDFKit's.
        let bounds: CGRect
    }

    var objects: [Object] {
        (0..<Int(FPDFPage_CountObjects(page))).compactMap { i in
            guard let handle = FPDFPage_GetObject(page, Int32(i)) else { return nil }
            var l: Float = 0, b: Float = 0, r: Float = 0, t: Float = 0
            guard FPDFPageObj_GetBounds(handle, &l, &b, &r, &t) != 0 else { return nil }
            return Object(handle: handle, index: i, type: FPDFPageObj_GetType(handle),
                          bounds: CGRect(x: CGFloat(l), y: CGFloat(b), width: CGFloat(r - l), height: CGFloat(t - b)))
        }
    }

    var textObjects: [Object] { objects.filter { $0.type == FPDF_PAGEOBJ_TEXT } }
    var imageObjects: [Object] { objects.filter { $0.type == FPDF_PAGEOBJ_IMAGE } }

    /// Regenerating the page rewrites every object, and PDFium writes colors in ICC or other
    /// non-device color spaces (what Apple's PDF writer uses) as black. Re-setting each object's
    /// current color as plain RGB first keeps the rest of the page looking exactly the same.
    func pinColors() {
        for object in objects where object.type == FPDF_PAGEOBJ_TEXT || object.type == FPDF_PAGEOBJ_PATH {
            var r: UInt32 = 0, g: UInt32 = 0, b: UInt32 = 0, a: UInt32 = 0
            if FPDFPageObj_GetFillColor(object.handle, &r, &g, &b, &a) != 0 {
                FPDFPageObj_SetFillColor(object.handle, r, g, b, a)
            }
            if FPDFPageObj_GetStrokeColor(object.handle, &r, &g, &b, &a) != 0 {
                FPDFPageObj_SetStrokeColor(object.handle, r, g, b, a)
            }
        }
    }

    func remove(_ object: Object) {
        changedExistingObjects = true
        if FPDFPage_RemoveObject(page, object.handle) != 0 { FPDFPageObj_Destroy(object.handle) }
    }

    /// Embeds `font` (its full system copy, so any typed character has a glyph). Falls back to the
    /// closest of the 14 standard PDF fonts if the font can't be embedded.
    func load(_ font: NSFont) -> FPDF_FONT? {
        var handle: FPDF_FONT?
        if let data = FontData.sfnt(for: font) {
            handle = data.withUnsafeBytes { raw in
                FPDFText_LoadFont(doc, raw.bindMemory(to: UInt8.self).baseAddress, UInt32(raw.count),
                                  Int32(FPDF_FONT_TRUETYPE), 1)
            }
        }
        if handle == nil { handle = FPDFText_LoadStandardFont(doc, FontData.standardName(for: font)) }
        if let handle { fonts.append(handle) }
        return handle
    }

    /// Places one line of text with its baseline starting at `origin`.
    @discardableResult
    func addText(_ text: String, font: FPDF_FONT, size: CGFloat, color: NSColor, at origin: CGPoint) -> Bool {
        guard !text.isEmpty, let object = FPDFPageObj_CreateTextObj(doc, font, Float(size)) else { return false }
        var utf16 = Array(text.utf16) + [0]
        guard FPDFText_SetText(object, &utf16) != 0 else {
            FPDFPageObj_Destroy(object)
            return false
        }
        let c = color.usingColorSpace(.sRGB) ?? .black
        FPDFPageObj_SetFillColor(object, UInt32(c.redComponent * 255), UInt32(c.greenComponent * 255),
                                 UInt32(c.blueComponent * 255), UInt32(c.alphaComponent * 255))
        FPDFPageObj_Transform(object, 1, 0, 0, 1, Double(origin.x), Double(origin.y))
        FPDFPage_InsertObject(page, object)
        return true
    }

    /// Where a text object starts drawing: its baseline origin, in page coordinates.
    func origin(of object: Object) -> CGPoint? {
        var m = FS_MATRIX()
        guard FPDFPageObj_GetMatrix(object.handle, &m) != 0 else { return nil }
        return CGPoint(x: CGFloat(m.e), y: CGFloat(m.f))
    }

    /// Applies `transform` (in page coordinates) on top of the object's current placement.
    func transform(_ object: Object, by t: CGAffineTransform) {
        changedExistingObjects = true
        FPDFPageObj_Transform(object.handle, Double(t.a), Double(t.b), Double(t.c), Double(t.d), Double(t.tx), Double(t.ty))
    }

    func image(of object: Object) -> CGImage? {
        guard let bitmap = FPDFImageObj_GetRenderedBitmap(doc, page, object.handle) else { return nil }
        defer { FPDFBitmap_Destroy(bitmap) }
        return Self.cgImage(from: bitmap)
    }

    func replaceImage(of object: Object, with image: CGImage) -> Bool {
        changedExistingObjects = true
        guard let bitmap = Self.bitmap(from: image) else { return false }
        defer { FPDFBitmap_Destroy(bitmap) }
        var pages: FPDF_PAGE? = page
        return FPDFImageObj_SetBitmap(&pages, 1, object.handle, bitmap) != 0
    }

    func closeFonts() {
        fonts.forEach(FPDFFont_Close)
        fonts = []
    }

    private static func cgImage(from bitmap: FPDF_BITMAP) -> CGImage? {
        let width = Int(FPDFBitmap_GetWidth(bitmap)), height = Int(FPDFBitmap_GetHeight(bitmap))
        let stride = Int(FPDFBitmap_GetStride(bitmap))
        guard width > 0, height > 0, let buffer = FPDFBitmap_GetBuffer(bitmap) else { return nil }
        let data = Data(bytes: buffer, count: stride * height)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        // PDFium bitmaps are BGRA, premultiplied for rendered images.
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func bitmap(from image: CGImage) -> FPDF_BITMAP? {
        let width = image.width, height = image.height
        guard let bitmap = FPDFBitmap_Create(Int32(width), Int32(height), 1),
              let buffer = FPDFBitmap_GetBuffer(bitmap) else { return nil }
        let stride = Int(FPDFBitmap_GetStride(bitmap))
        guard let ctx = CGContext(data: buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: stride,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            FPDFBitmap_Destroy(bitmap)
            return nil
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bitmap
    }
}

enum FontData {
    /// Rebuilds a standalone font file from the font's tables. Works for fonts inside .ttc
    /// collections (like Helvetica), which can't be embedded straight from disk.
    static func sfnt(for font: NSFont) -> Data? {
        let ctFont = font as CTFont
        guard let tagArray = CTFontCopyAvailableTables(ctFont, []) else { return nil }
        let tags = (0..<CFArrayGetCount(tagArray)).map { UInt32(UInt(bitPattern: CFArrayGetValueAtIndex(tagArray, $0))) }
        let tables = tags.sorted().compactMap { tag -> (UInt32, Data)? in
            guard let data = CTFontCopyTable(ctFont, tag, []) as Data? else { return nil }
            return (tag, data)
        }
        let tagCFF: UInt32 = 0x4346_4620 // 'CFF '
        let tagGlyf: UInt32 = 0x676C_7966 // 'glyf'
        guard !tables.isEmpty, tables.contains(where: { $0.0 == tagGlyf || $0.0 == tagCFF }) else { return nil }

        var out = Data()
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { out.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { out.append(contentsOf: $0) } }

        let count = UInt16(tables.count)
        var power: UInt16 = 1, log: UInt16 = 0
        while power * 2 <= count { power *= 2; log += 1 }
        put32(tables.contains { $0.0 == tagCFF } ? 0x4F54_544F /* 'OTTO' */ : 0x0001_0000)
        put16(count)
        put16(power * 16)
        put16(log)
        put16(count * 16 - power * 16)

        var offset = UInt32(12 + 16 * tables.count)
        for (tag, data) in tables {
            put32(tag)
            put32(checksum(data))
            put32(offset)
            put32(UInt32(data.count))
            offset += UInt32((data.count + 3) & ~3)
        }
        for (_, data) in tables {
            out.append(data)
            out.append(contentsOf: [UInt8](repeating: 0, count: ((data.count + 3) & ~3) - data.count))
        }
        return out
    }

    private static func checksum(_ data: Data) -> UInt32 {
        var sum: UInt32 = 0
        let padded = data + Data(count: ((data.count + 3) & ~3) - data.count)
        padded.withUnsafeBytes { raw in
            for i in stride(from: 0, to: raw.count, by: 4) {
                sum &+= UInt32(raw[i]) << 24 | UInt32(raw[i + 1]) << 16 | UInt32(raw[i + 2]) << 8 | UInt32(raw[i + 3])
            }
        }
        return sum
    }

    static func standardName(for font: NSFont) -> String {
        let traits = NSFontManager.shared.traits(of: font)
        let bold = traits.contains(.boldFontMask), italic = traits.contains(.italicFontMask)
        let name = font.fontName.lowercased()
        if name.contains("times") || name.contains("serif") && !name.contains("sans") {
            return bold ? (italic ? "Times-BoldItalic" : "Times-Bold") : (italic ? "Times-Italic" : "Times-Roman")
        }
        if name.contains("courier") || name.contains("mono") {
            return bold ? (italic ? "Courier-BoldOblique" : "Courier-Bold") : (italic ? "Courier-Oblique" : "Courier")
        }
        return bold ? (italic ? "Helvetica-BoldOblique" : "Helvetica-Bold") : (italic ? "Helvetica-Oblique" : "Helvetica")
    }

    /// The installed font matching one read from a PDF. PDFs usually embed only the characters they
    /// use (names like "ABCDEF+Calibri"), so typing new letters needs the full system font.
    static func installed(matching font: NSFont, size: CGFloat) -> NSFont {
        var name = font.fontName
        if let plus = name.firstIndex(of: "+"), name.distance(from: name.startIndex, to: plus) == 6 {
            name = String(name[name.index(after: plus)...])
        }
        if NSFontManager.shared.availableFonts.contains(name), let exact = NSFont(name: name, size: size) {
            return exact
        }
        if let family = font.familyName, let match = NSFontManager.shared.font(
            withFamily: family, traits: NSFontManager.shared.traits(of: font), weight: 5, size: size) {
            return match
        }
        let standard = standardName(for: font)
        return NSFont(name: standard, size: size) ?? .systemFont(ofSize: size)
    }
}
