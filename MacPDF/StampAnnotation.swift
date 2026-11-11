import AppKit
import PDFKit

/// Vector-drawn Stamp Annotation rendered with high-DPI clarity matching PDF Expert.
final class StampAnnotation: PDFAnnotation {
    var stampItem: StampItem

    init(item: StampItem, center: CGPoint) {
        self.stampItem = item
        let bounds = Self.computeBounds(for: item, at: center)
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        self.contents = item.title
        self.tag = .stamp
    }

    required init?(coder: NSCoder) {
        self.stampItem = StampCatalog.standardStamps[0]
        super.init(coder: coder)
    }

    private static func computeBounds(for item: StampItem, at point: CGPoint) -> CGRect {
        switch item.style {
        case .boxed:
            let fontSize: CGFloat
            if item.title.count <= 6 {
                fontSize = 34
            } else if item.title.count <= 10 {
                fontSize = 28
            } else if item.title.count <= 15 {
                fontSize = 22
            } else {
                fontSize = 18
            }
            let font = NSFont.systemFont(ofSize: fontSize, weight: .black)
            let str = NSAttributedString(string: item.title, attributes: [.font: font, .kern: 2.2])
            let size = str.size()
            let w = max(size.width + 48, 200)
            let h: CGFloat = item.title.count <= 10 ? 68 : 58
            return CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h)

        case .tagArrow:
            let font = NSFont.systemFont(ofSize: 15, weight: .black)
            let size = (item.title as NSString).size(withAttributes: [.font: font])
            let w = max(size.width + 48, 150)
            let h: CGFloat = 42
            return CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h)

        case .mark:
            let size: CGFloat = 56
            return CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)

        case .dateTime:
            let w: CGFloat = 190
            let h: CGFloat = 64
            return CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h)

        case .plainText:
            let font = NSFont.systemFont(ofSize: 22, weight: .bold)
            let size = (item.title as NSString).size(withAttributes: [.font: font])
            let w = size.width + 24
            let h = size.height + 12
            return CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h)
        }
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.setShouldSmoothFonts(true)
        context.setAllowsFontSmoothing(true)
        context.interpolationQuality = .high

        NSGraphicsContext.saveGraphicsState()
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current = nsContext

        let rect = bounds

        switch stampItem.style {
        case .boxed:
            drawBoxedStamp(in: rect)
        case .tagArrow:
            drawTagArrowStamp(in: rect)
        case .mark:
            drawMarkStamp(in: rect)
        case .dateTime:
            drawDateTimeStamp(in: rect)
        case .plainText:
            drawPlainTextStamp(in: rect)
        }

        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }

    private func drawBoxedStamp(in rect: CGRect) {
        let insetRect = rect.insetBy(dx: 2.0, dy: 2.0)
        let cornerRadius: CGFloat = 13.0
        let path = NSBezierPath(roundedRect: insetRect, xRadius: cornerRadius, yRadius: cornerRadius)

        // Solid smooth background fill matching PDF Expert
        stampItem.backgroundColor.setFill()
        path.fill()

        // Authoritative outer border (3.5pt)
        stampItem.primaryColor.setStroke()
        path.lineWidth = 3.5
        path.stroke()

        // Font calculation: scale font based on title length
        let fontSize: CGFloat
        if stampItem.title.count <= 6 {
            fontSize = 34
        } else if stampItem.title.count <= 10 {
            fontSize = 28
        } else if stampItem.title.count <= 15 {
            fontSize = 22
        } else {
            fontSize = 18
        }

        let font = NSFont.systemFont(ofSize: fontSize, weight: .black)
        let style = NSMutableParagraphStyle()
        style.alignment = .center

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: stampItem.primaryColor,
            .kern: 2.2,
            .paragraphStyle: style
        ]

        let str = NSAttributedString(string: stampItem.title, attributes: attrs)
        let strSize = str.size()
        let textRect = CGRect(
            x: rect.midX - strSize.width / 2,
            y: rect.midY - strSize.height / 2 + 1,
            width: strSize.width,
            height: strSize.height
        )
        str.draw(in: textRect)
    }

    private func drawTagArrowStamp(in rect: CGRect) {
        let arrowWidth: CGFloat = 16
        let insetRect = rect.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath()

        // Arrow shape pointing right
        path.move(to: CGPoint(x: insetRect.minX, y: insetRect.minY))
        path.line(to: CGPoint(x: insetRect.maxX - arrowWidth, y: insetRect.minY))
        path.line(to: CGPoint(x: insetRect.maxX, y: insetRect.midY))
        path.line(to: CGPoint(x: insetRect.maxX - arrowWidth, y: insetRect.maxY))
        path.line(to: CGPoint(x: insetRect.minX, y: insetRect.maxY))
        path.close()

        stampItem.backgroundColor.setFill()
        path.fill()

        NSColor.black.withAlphaComponent(0.25).setStroke()
        path.lineWidth = 1.2
        path.stroke()

        let font = NSFont.systemFont(ofSize: 15, weight: .black)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: stampItem.primaryColor,
            .kern: 1.2
        ]
        let textSize = (stampItem.title as NSString).size(withAttributes: attrs)
        let textRect = CGRect(
            x: insetRect.minX + (insetRect.width - arrowWidth - textSize.width) / 2,
            y: insetRect.midY - textSize.height / 2 + 0.5,
            width: textSize.width,
            height: textSize.height
        )
        (stampItem.title as NSString).draw(in: textRect, withAttributes: attrs)
    }

    private func drawMarkStamp(in rect: CGRect) {
        let font = NSFont.systemFont(ofSize: rect.height * 0.85, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: stampItem.primaryColor
        ]
        let textSize = (stampItem.title as NSString).size(withAttributes: attrs)
        let textRect = CGRect(
            x: rect.midX - textSize.width / 2,
            y: rect.midY - textSize.height / 2,
            width: textSize.width,
            height: textSize.height
        )
        (stampItem.title as NSString).draw(in: textRect, withAttributes: attrs)
    }

    private func drawDateTimeStamp(in rect: CGRect) {
        let insetRect = rect.insetBy(dx: 2.0, dy: 2.0)
        let path = NSBezierPath(roundedRect: insetRect, xRadius: 12, yRadius: 12)

        stampItem.backgroundColor.setFill()
        path.fill()

        stampItem.primaryColor.setStroke()
        path.lineWidth = 3.0
        path.stroke()

        let titleFont = NSFont.systemFont(ofSize: 22, weight: .black)
        let style = NSMutableParagraphStyle()
        style.alignment = .center

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: stampItem.primaryColor,
            .kern: 1.8,
            .paragraphStyle: style
        ]
        let titleStr = NSAttributedString(string: stampItem.title, attributes: titleAttrs)
        let titleSize = titleStr.size()
        let titleRect = CGRect(
            x: rect.midX - titleSize.width / 2,
            y: rect.midY + 1,
            width: titleSize.width,
            height: titleSize.height
        )
        titleStr.draw(in: titleRect)

        let subtitle = stampItem.subtitle ?? StampCatalog.dynamicDateString()
        let subFont = NSFont.systemFont(ofSize: 11, weight: .bold)
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: subFont,
            .foregroundColor: stampItem.primaryColor,
            .paragraphStyle: style
        ]
        let subStr = NSAttributedString(string: subtitle, attributes: subAttrs)
        let subSize = subStr.size()
        let subRect = CGRect(
            x: rect.midX - subSize.width / 2,
            y: rect.midY - subSize.height - 2,
            width: subSize.width,
            height: subSize.height
        )
        subStr.draw(in: subRect)
    }

    private func drawPlainTextStamp(in rect: CGRect) {
        let font = NSFont.systemFont(ofSize: 20, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: stampItem.primaryColor
        ]
        let textSize = (stampItem.title as NSString).size(withAttributes: attrs)
        let textRect = CGRect(
            x: rect.midX - textSize.width / 2,
            y: rect.midY - textSize.height / 2,
            width: textSize.width,
            height: textSize.height
        )
        (stampItem.title as NSString).draw(in: textRect, withAttributes: attrs)
    }
}

/// Vector-drawn fill text annotation for Date, Checkmark, and Cross tool marks,
/// rendered with full antialiasing and font smoothing so it is completely crisp.
final class VectorFillAnnotation: PDFAnnotation {
    var text: String
    var textColor: NSColor
    var isDate: Bool

    init(text: String, textColor: NSColor, at point: CGPoint, isDate: Bool) {
        self.text = text
        self.textColor = textColor
        self.isDate = isDate
        let font = NSFont.systemFont(ofSize: isDate ? 15 : 24, weight: isDate ? .bold : .bold)
        let size = (text as NSString).size(withAttributes: [.font: font])
        let bounds = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width + 6, height: size.height + 6)
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        self.contents = text
    }

    required init?(coder: NSCoder) {
        self.text = ""
        self.textColor = .black
        self.isDate = false
        super.init(coder: coder)
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.setShouldSmoothFonts(true)
        context.setAllowsFontSmoothing(true)
        context.interpolationQuality = .high

        NSGraphicsContext.saveGraphicsState()
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current = nsContext

        let font = NSFont.systemFont(ofSize: isDate ? 15 : 24, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let rect = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                          width: size.width, height: size.height)
        (text as NSString).draw(in: rect, withAttributes: attrs)

        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }
}
