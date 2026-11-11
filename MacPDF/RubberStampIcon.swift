import AppKit
import SwiftUI

/// Custom vector Rubber Stamp icon matching classic desktop PDF editors.
struct RubberStampIcon: View {
    var size: CGFloat = 16
    var color: Color = .primary

    var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let scale = min(w, h) / 18.0

            context.translateBy(x: (w - 18 * scale) / 2, y: (h - 18 * scale) / 2)
            context.scaleBy(x: scale, y: scale)

            // Top handle knob
            let knobRect = CGRect(x: 6.5, y: 1.5, width: 5.0, height: 6.5)
            context.fill(Path(ellipseIn: knobRect), with: .color(color))

            // Neck connecting knob to base
            var neck = Path()
            neck.move(to: CGPoint(x: 7.5, y: 7.0))
            neck.addCurve(to: CGPoint(x: 4.5, y: 11.5),
                          control1: CGPoint(x: 7.5, y: 9.5),
                          control2: CGPoint(x: 5.0, y: 10.5))
            neck.addLine(to: CGPoint(x: 13.5, y: 11.5))
            neck.addCurve(to: CGPoint(x: 10.5, y: 7.0),
                          control1: CGPoint(x: 13.0, y: 10.5),
                          control2: CGPoint(x: 10.5, y: 9.5))
            neck.closeSubpath()
            context.fill(neck, with: .color(color))

            // Base mount
            let baseRect = CGRect(x: 2.0, y: 11.0, width: 14.0, height: 3.0)
            context.fill(Path(roundedRect: baseRect, cornerRadius: 1.0), with: .color(color))

            // Bottom rubber pad line
            let padRect = CGRect(x: 2.5, y: 15.0, width: 13.0, height: 1.6)
            context.fill(Path(roundedRect: padRect, cornerRadius: 0.6), with: .color(color))
        }
        .frame(width: size, height: size)
    }
}

extension NSImage {
    /// Vector template NSImage of the rubber stamp.
    static let rubberStamp: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            let ctx = NSGraphicsContext.current?.cgContext
            ctx?.saveGState()

            NSColor.labelColor.setFill()

            // Handle knob
            let knob = NSBezierPath(ovalIn: NSRect(x: 6.5, y: 10.0, width: 5, height: 6.5))
            knob.fill()

            // Neck
            let neck = NSBezierPath()
            neck.move(to: NSPoint(x: 7.5, y: 11.0))
            neck.curve(to: NSPoint(x: 4.5, y: 6.5), controlPoint1: NSPoint(x: 7.5, y: 8.5), controlPoint2: NSPoint(x: 5.0, y: 7.5))
            neck.line(to: NSPoint(x: 13.5, y: 6.5))
            neck.curve(to: NSPoint(x: 10.5, y: 11.0), controlPoint1: NSPoint(x: 13.0, y: 7.5), controlPoint2: NSPoint(x: 10.5, y: 8.5))
            neck.close()
            neck.fill()

            // Base
            let base = NSBezierPath(roundedRect: NSRect(x: 2.0, y: 4.0, width: 14, height: 3), xRadius: 1, yRadius: 1)
            base.fill()

            // Bottom rubber pad
            let pad = NSBezierPath(roundedRect: NSRect(x: 2.5, y: 1.4, width: 13, height: 1.6), xRadius: 0.6, yRadius: 0.6)
            pad.fill()

            ctx?.restoreGState()
            return true
        }
        img.isTemplate = true
        return img
    }()
}
