import PDFKit

/// PDFView that routes mouse input to the active tool.
final class MacPDFView: PDFView, NSTextFieldDelegate {
    weak var model: DocumentModel?

    private let inkWidth: CGFloat = 3
    private var inkPath: NSBezierPath?
    private var dragPage: PDFPage?
    private var dragStart: CGPoint?
    /// Redact tool started on text, so PDFView's own text selection is running.
    private var redactingSelection = false

    private var inlineField: NSTextField?
    private var inlineCommit: ((String?) -> Void)?
    private var inlineHidden: PDFAnnotation?

    private func pagePoint(_ event: NSEvent) -> (PDFPage, CGPoint)? {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: true) else { return nil }
        return (page, convert(viewPoint, to: page))
    }

    /// Anywhere on a line of text (including the gaps between words) counts, so a drag there
    /// selects text; only empty areas start a box.
    private func isOverText(_ point: CGPoint, on page: PDFPage) -> Bool {
        guard let line = page.selectionForLine(at: point),
              !(line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return line.bounds(for: page).insetBy(dx: -4, dy: -3).contains(point)
    }

    override func mouseDown(with event: NSEvent) {
        endInlineEdit()
        guard let model, model.tool != .select, model.tool.markupSubtype == nil,
              let (page, point) = pagePoint(event) else {
            super.mouseDown(with: event)
            finishTextGestureIfReleased()
            return
        }
        let hit = page.annotation(at: point)
        switch model.tool {
        case .note:
            model.addNote(at: point, on: page)
        case .eraser:
            if let hit, hit.isUserAnnotation { model.remove(hit) }
        case .editText:
            if let hit, hit.isFreeText {
                model.editTextAnnotation(hit)
            } else if let line = page.selectionForLine(at: point),
                      line.bounds(for: page).insetBy(dx: -2, dy: -2).contains(point) {
                model.beginLineEdit(line, on: page)
            } else {
                NSSound.beep()
            }
        case .textBox:
            if let hit, hit.isFreeText {
                model.editTextAnnotation(hit)
            } else {
                model.addTextBox(at: point, on: page)
            }
        case .signature:
            model.placeSignature(at: point, on: page)
        case .stamp:
            model.addStamp(at: point, on: page)
        case .date, .checkmark, .cross:
            model.addFillText(model.tool, at: point, on: page)
        case .redact where isOverText(point, on: page):
            redactingSelection = true
            super.mouseDown(with: event)
            finishTextGestureIfReleased()
        case .pen:
            let path = NSBezierPath()
            path.move(to: point)
            inkPath = path
            dragPage = page
            updateInkPreview()
        default:
            // Everything else is drawn as a drag: shapes, boxes, lines.
            dragStart = point
            dragPage = page
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !redactingSelection, let page = dragPage, let model else {
            super.mouseDragged(with: event)
            return
        }
        let point = convert(convert(event.locationInWindow, from: nil), to: page)
        if model.tool == .pen {
            inkPath?.line(to: point)
            updateInkPreview()
        } else if let start = dragStart {
            updateDragPreview(from: start, to: point, on: page)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let model else { return super.mouseUp(with: event) }

        if redactingSelection || model.tool.markupSubtype != nil {
            super.mouseUp(with: event)
            completeTextGesture()
            return
        }

        if let page = dragPage {
            clearPreview()
            dragPage = nil
            if let path = inkPath {
                if path.elementCount > 1 { model.addInk(path, lineWidth: inkWidth, on: page) }
            } else if let start = dragStart {
                let end = convert(convert(event.locationInWindow, from: nil), to: page)
                finishDrag(from: start, to: end, on: page, model: model)
            }
            inkPath = nil
            dragStart = nil
            return
        }

        super.mouseUp(with: event)
    }

    /// PDFView runs its own tracking loop for text selection: `super.mouseDown` only returns once the
    /// button is released, and the mouse-up never reaches `mouseUp(with:)`. So finish the gesture here
    /// when that happened; otherwise `mouseUp` finishes it.
    private func finishTextGestureIfReleased() {
        guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
        completeTextGesture()
    }

    /// Turns the text just selected into a redaction or markup, for the active tool.
    private func completeTextGesture() {
        guard let model else { return }
        let wasRedacting = redactingSelection
        redactingSelection = false
        guard let selection = currentSelection, !(selection.string ?? "").isEmpty else { return }
        if wasRedacting {
            model.redact(selection)
            clearSelection()
        } else if let subtype = model.tool.markupSubtype {
            model.applyMarkup(subtype, to: selection)
            clearSelection()
        }
    }

    private func finishDrag(from start: CGPoint, to end: CGPoint, on page: PDFPage, model: DocumentModel) {
        let rect = CGRect(from: start, to: end)
        switch model.tool {
        case .shape: model.addShape(from: start, to: end, on: page)
        case .redact:
            // A flat sideways drag is someone selecting a line of text, not drawing a box: redact the
            // text it crossed instead of a sliver.
            if rect.height < 6, let text = page.selection(from: start, to: end),
               !(text.string ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                model.redact(text)
            } else if rect.height >= 6 {
                model.addRedaction(rect, on: page)
            }
        case .snapshot: model.copyArea(rect, on: page)
        case .image: model.placeImage(in: rect, on: page)
        case .link: model.addLink(in: rect, on: page)
        case .crop: model.crop(to: rect, on: page)
        case .distance: model.addDistance(from: start, to: end, on: page)
        case .area: model.addArea(rect, on: page)
        default: break
        }
    }

    // MARK: Drag previews
    // Drawn in a lightweight overlay view rather than as temporary annotations: changing a page's
    // annotations on every mouse move forces PDFKit (and the sidebar thumbnails) to re-render the page.

    private lazy var overlay: DragOverlay = {
        let view = DragOverlay(frame: bounds)
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        return view
    }()

    private func overlayPoint(_ point: CGPoint, on page: PDFPage) -> CGPoint {
        overlay.convert(convert(point, from: page), from: self)
    }

    private func overlayRect(_ rect: CGRect, on page: PDFPage) -> CGRect {
        overlay.convert(convert(rect, from: page), from: self)
    }

    private func clearPreview() {
        overlay.path = nil
        overlay.needsDisplay = true
    }

    private func updateInkPreview() {
        guard let path = inkPath, let page = dragPage, let model else { return }
        let viewPath = NSBezierPath()
        var points = [CGPoint](repeating: .zero, count: 3)
        for i in 0..<path.elementCount {
            let kind = path.element(at: i, associatedPoints: &points)
            let point = overlayPoint(points[0], on: page)
            if kind == .moveTo { viewPath.move(to: point) } else { viewPath.line(to: point) }
        }
        overlay.show(viewPath, stroke: model.nsColor, width: inkWidth * scaleFactor)
    }

    private func updateDragPreview(from start: CGPoint, to end: CGPoint, on page: PDFPage) {
        guard let model else { return }
        let rect = overlayRect(CGRect(from: start, to: end), on: page)
        let a = overlayPoint(start, on: page), b = overlayPoint(end, on: page)
        let line = NSBezierPath()
        line.move(to: a)
        line.line(to: b)

        switch model.tool {
        case .shape:
            switch model.shapeKind {
            case .rectangle: overlay.show(NSBezierPath(rect: rect), stroke: model.nsColor, width: 2 * scaleFactor)
            case .oval: overlay.show(NSBezierPath(ovalIn: rect), stroke: model.nsColor, width: 2 * scaleFactor)
            case .line, .arrow: overlay.show(line, stroke: model.nsColor, width: 2 * scaleFactor)
            }
        case .distance:
            overlay.show(line, stroke: model.nsColor, width: 1.5 * scaleFactor)
        case .redact:
            overlay.show(NSBezierPath(rect: rect), fill: model.redactionColor)
        default:
            overlay.show(NSBezierPath(rect: rect),
                         stroke: model.tool == .area ? model.nsColor : .controlAccentColor, width: 1.5, dashed: true)
        }
    }

    // MARK: Inline text editing

    /// Shows a text field over `pageRect`. `commit` gets the final text, or nil if cancelled with Esc.
    func beginInlineEdit(pageRect: CGRect, on page: PDFPage, text: String, font: NSFont,
                         hiding annotation: PDFAnnotation? = nil, commit: @escaping (String?) -> Void) {
        endInlineEdit()
        guard let documentView else { return }

        let field = NSTextField(string: text)
        field.font = NSFont(descriptor: font.fontDescriptor, size: max(font.pointSize * scaleFactor, 9))
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = .white
        field.textColor = .black
        field.focusRingType = .exterior
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self

        var frame = documentView.convert(convert(pageRect, from: page), from: self)
        frame.size.width = max(frame.width + 60, 160)
        let height = max(frame.height, field.intrinsicContentSize.height)
        frame.origin.y -= (height - frame.height) / 2
        frame.size.height = height
        field.frame = frame

        annotation?.shouldDisplay = false
        if let annotation { annotationsChanged(on: page) }
        inlineHidden = annotation
        inlineCommit = commit
        inlineField = field
        documentView.addSubview(field)
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func endInlineEdit(cancel: Bool = false) {
        guard let field = inlineField else { return }
        let commit = inlineCommit
        inlineField = nil
        inlineCommit = nil
        if let hidden = inlineHidden {
            hidden.shouldDisplay = true
            if let page = hidden.page { annotationsChanged(on: page) }
        }
        inlineHidden = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.delegate = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        commit?(cancel ? nil : text)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        endInlineEdit()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(cancelOperation(_:)) {
            endInlineEdit(cancel: true)
            return true
        }
        return false
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        switch model?.tool {
        case .select, .highlight, .underline, .strikeOut, .none: break
        case .editText, .textBox, .redact: addCursorRect(visibleRect, cursor: .iBeam)
        case .eraser: addCursorRect(visibleRect, cursor: .disappearingItem)
        default: addCursorRect(visibleRect, cursor: .crosshair)
        }
    }
}

/// Transparent, click-through view that draws the shape being dragged.
private final class DragOverlay: NSView {
    var path: NSBezierPath?
    private var stroke: NSColor?
    private var fill: NSColor?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ path: NSBezierPath, stroke: NSColor? = nil, width: CGFloat = 1, dashed: Bool = false, fill: NSColor? = nil) {
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        if dashed { path.setLineDash([5, 4], count: 2, phase: 0) }
        self.path = path
        self.stroke = stroke
        self.fill = fill
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let path else { return }
        if let fill { fill.setFill(); path.fill() }
        if let stroke { stroke.setStroke(); path.stroke() }
    }
}
