import AppKit
import Foundation
import PDFKit

let fixturesDir = URL(fileURLWithPath: "/Users/suthak/Projects/MacPDF/MacPDFTests/Fixtures")
try? FileManager.default.createDirectory(at: fixturesDir, withIntermediateDirectories: true)

func makeCleanPDF(objects: [(id: Int, body: String)], catalogId: Int) -> Data {
    var out = Data("%PDF-1.4\n".utf8)
    var offsets: [Int: Int] = [:]
    for obj in objects {
        offsets[obj.id] = out.count
        let header = "\(obj.id) 0 obj\n"
        out.append(Data(header.utf8))
        out.append(Data(obj.body.utf8))
        out.append(Data("\nendobj\n".utf8))
    }
    let xrefPos = out.count
    let maxId = offsets.keys.max() ?? 0
    var xref = "xref\n0 \(maxId + 1)\n0000000000 65535 f \n"
    for i in 1...maxId {
        if let off = offsets[i] {
            xref += String(format: "%010d 00000 n \n", off)
        } else {
            xref += "0000000000 00000 f \n"
        }
    }
    xref += "trailer\n<< /Size \(maxId + 1) /Root \(catalogId) 0 R >>\nstartxref\n\(xrefPos)\n%%EOF\n"
    out.append(Data(xref.utf8))
    return out
}

// 1. plain-text.pdf
do {
    let url = fixturesDir.appendingPathComponent("plain-text.pdf")
    let content = """
BT
/F1 18 Tf
54 720 Td
(CONFIDENTIAL MEDICAL REPORT) Tj
ET
BT
/F2 12 Tf
54 670 Td
(Patient ID: PT-98234-X) Tj
0 -24 Td
(Subject: Routine post-operative evaluation) Tj
0 -24 Td
(SSN: 000-12-3456) Tj
0 -24 Td
(Date of Birth: January 15, 1980) Tj
0 -24 Td
(Secret Code: ALPHA-OMEGA-99) Tj
0 -24 Td
(Diagnosis: Healing well with no observed complications.) Tj
0 -24 Td
(Recommendations: Continue prescribed physical therapy twice weekly.) Tj
ET
"""
    let objs: [(id: Int, body: String)] = [
        (1, "<< /Type /Catalog /Pages 2 0 R >>"),
        (2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
        (3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R /F2 5 0 R >> >> /Contents 6 0 R >>"),
        (4, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>"),
        (5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"),
        (6, "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream")
    ]
    let data = makeCleanPDF(objects: objs, catalogId: 1)
    try data.write(to: url)
    print("Created plain-text.pdf")
}

// 2. subset-fonts.pdf
do {
    let url = fixturesDir.appendingPathComponent("subset-fonts.pdf")
    let box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let data = NSMutableData()
    let consumer = CGDataConsumer(data: data as CFMutableData)!
    var mediaBox = box
    let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
    ctx.beginPDFPage(nil)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

    let timesFont = NSFont(name: "TimesNewRomanPS-BoldMT", size: 16) ?? NSFont.boldSystemFont(ofSize: 16)
    NSAttributedString(string: "SUBSET FONT SPECIMEN", attributes: [.font: timesFont, .foregroundColor: NSColor.black])
        .draw(at: CGPoint(x: 54, y: 720))

    let courierFont = NSFont(name: "Courier", size: 12) ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    let lines = [
        "Embedded Font Test: ABCDEF+TimesNewRoman",
        "Diagnostic Code: SUBSET-7701",
        "Record Number: REC-88329-Z"
    ]
    var y = 670.0
    for line in lines {
        NSAttributedString(string: line, attributes: [.font: courierFont, .foregroundColor: NSColor.black])
            .draw(at: CGPoint(x: 54, y: y))
        y -= 24.0
    }

    NSGraphicsContext.restoreGraphicsState()
    ctx.endPDFPage()
    ctx.closePDF()
    
    // Post-process to ensure font subset prefix ABCDEF+ exists in font naming
    var pdfBytes = (data as Data)
    if let str = String(data: pdfBytes, encoding: .isoLatin1) {
        let modified = str.replacingOccurrences(of: "/BaseFont /Courier", with: "/BaseFont /ABCDEF+Courier")
            .replacingOccurrences(of: "/BaseFont /TimesNewRoman", with: "/BaseFont /XYZABC+TimesNewRoman")
        if let modData = modified.data(using: .isoLatin1) {
            pdfBytes = modData
        }
    }
    try pdfBytes.write(to: url)
    print("Created subset-fonts.pdf")
}

// 3. two-column.pdf
do {
    let url = fixturesDir.appendingPathComponent("two-column.pdf")
    let box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let data = NSMutableData()
    let consumer = CGDataConsumer(data: data as CFMutableData)!
    var mediaBox = box
    let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
    ctx.beginPDFPage(nil)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

    let font = NSFont(name: "Helvetica", size: 11) ?? NSFont.systemFont(ofSize: 11)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]

    // Column 1 (Left: x = 54..280)
    let col1Lines = [
        "Left Column Overview",
        "This column contains general background information.",
        "Multiple lines of text describe the initial observations.",
        "Experimental controls were maintained throughout.",
        "Final summary for column one."
    ]
    var y1 = 700.0
    for l in col1Lines {
        NSAttributedString(string: l, attributes: attrs).draw(at: CGPoint(x: 54, y: y1))
        y1 -= 20.0
    }

    // Column 2 (Right: x = 338..558)
    let col2Lines = [
        "Right Column Analysis",
        "This second column presents independent findings.",
        "Sensor data demonstrated pressure variations.",
        "Thermal expansion contributed to anomalous readings.",
        "Concluding recommendations outline replacements."
    ]
    var y2 = 700.0
    for l in col2Lines {
        NSAttributedString(string: l, attributes: attrs).draw(at: CGPoint(x: 338, y: y2))
        y2 -= 20.0
    }

    NSGraphicsContext.restoreGraphicsState()
    ctx.endPDFPage()
    ctx.closePDF()
    try (data as Data).write(to: url)
    print("Created two-column.pdf")
}

// 4. rotated-page.pdf
do {
    let url = fixturesDir.appendingPathComponent("rotated-page.pdf")
    let content = """
BT
/F1 18 Tf
100 600 Td
(ROTATED DOCUMENT 90 DEGREES) Tj
ET
BT
/F2 13 Tf
100 560 Td
(Secret Key: ROT-998811) Tj
ET
"""
    let objs: [(id: Int, body: String)] = [
        (1, "<< /Type /Catalog /Pages 2 0 R >>"),
        (2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
        (3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Rotate 90 /Resources << /Font << /F1 4 0 R /F2 5 0 R >> >> /Contents 6 0 R >>"),
        (4, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>"),
        (5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"),
        (6, "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream")
    ]
    let data = makeCleanPDF(objects: objs, catalogId: 1)
    try data.write(to: url)
    print("Created rotated-page.pdf")
}

// 5. form.pdf
do {
    let url = fixturesDir.appendingPathComponent("form.pdf")
    let box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let data = NSMutableData()
    let consumer = CGDataConsumer(data: data as CFMutableData)!
    var mediaBox = box
    let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
    ctx.beginPDFPage(nil)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

    NSAttributedString(string: "PATIENT INTAKE FORM", attributes: [.font: NSFont.boldSystemFont(ofSize: 16)]).draw(at: CGPoint(x: 54, y: 720))
    NSAttributedString(string: "Full Name:", attributes: [.font: NSFont.systemFont(ofSize: 12)]).draw(at: CGPoint(x: 54, y: 660))
    NSAttributedString(string: "DOB:", attributes: [.font: NSFont.systemFont(ofSize: 12)]).draw(at: CGPoint(x: 54, y: 610))
    NSAttributedString(string: "Consent:", attributes: [.font: NSFont.systemFont(ofSize: 12)]).draw(at: CGPoint(x: 54, y: 560))

    NSGraphicsContext.restoreGraphicsState()
    ctx.endPDFPage()
    ctx.closePDF()

    let doc = PDFDocument(data: data as Data)!
    let page = doc.page(at: 0)!

    let nameWidget = PDFAnnotation(bounds: CGRect(x: 150, y: 655, width: 200, height: 22), forType: .widget, withProperties: nil)
    nameWidget.widgetFieldType = .text
    nameWidget.fieldName = "FullName"
    nameWidget.widgetStringValue = "Jane Doe"
    page.addAnnotation(nameWidget)

    let dobWidget = PDFAnnotation(bounds: CGRect(x: 150, y: 605, width: 140, height: 22), forType: .widget, withProperties: nil)
    dobWidget.widgetFieldType = .text
    dobWidget.fieldName = "DOB"
    dobWidget.widgetStringValue = "1990-01-01"
    page.addAnnotation(dobWidget)

    let checkWidget = PDFAnnotation(bounds: CGRect(x: 150, y: 558, width: 18, height: 18), forType: .widget, withProperties: nil)
    checkWidget.widgetFieldType = .button
    checkWidget.widgetControlType = .checkBoxControl
    checkWidget.fieldName = "Consent"
    checkWidget.buttonWidgetState = .onState
    page.addAnnotation(checkWidget)

    doc.write(to: url)
    print("Created form.pdf")
}

// 6. scanned.pdf
do {
    let url = fixturesDir.appendingPathComponent("scanned.pdf")
    let box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let width = 612 * 2
    let height = 792 * 2
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let bitmapCtx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    bitmapCtx.setFillColor(NSColor.white.cgColor)
    bitmapCtx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmapCtx, flipped: false)

    NSAttributedString(string: "SCANNED MEDICAL RECORD", attributes: [
        .font: NSFont.boldSystemFont(ofSize: 32),
        .foregroundColor: NSColor.black
    ]).draw(at: CGPoint(x: 100, y: height - 200))

    NSAttributedString(string: "Account Balance: $450.00", attributes: [
        .font: NSFont.systemFont(ofSize: 22),
        .foregroundColor: NSColor.black
    ]).draw(at: CGPoint(x: 100, y: height - 280))

    NSGraphicsContext.restoreGraphicsState()

    let cgImage = bitmapCtx.makeImage()!

    let data = NSMutableData()
    let consumer = CGDataConsumer(data: data as CFMutableData)!
    var mediaBox = box
    let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
    ctx.beginPDFPage(nil)
    ctx.draw(cgImage, in: box)
    ctx.endPDFPage()
    ctx.closePDF()

    try (data as Data).write(to: url)
    print("Created scanned.pdf")
}
