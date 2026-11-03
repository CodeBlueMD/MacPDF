import PDFKit

/// PDFView that routes mouse input to the active tool.
final class MacPDFView: PDFView, NSTextFieldDelegate, NSTextViewDelegate {
    weak var model: DocumentModel?

    private let inkWidth: CGFloat = 3
    private var inkPath: NSBezierPath?
    private var dragPage: PDFPage?
    private var dragStart: CGPoint?
    /// Edit → Text press on a paragraph: becomes a move if dragged, an edit if just clicked.
    private var textPress: (start: CGPoint, viewStart: CGPoint, page: PDFPage, block: TextBlock, moved: Bool)?

    /// Edit → Image drag on a selected image: moving it, or resizing from a corner (0–3).
    private var imageDrag: (start: CGPoint, original: CGRect, corner: Int?, current: CGRect)?

    /// Redact tool started on text, so PDFView's own text selection is running.
    private var redactingSelection = false

    private var inlineField: NSTextField?
    private var inlineCommit: ((String?) -> Void)?
    private var inlineHidden: PDFAnnotation?

    private var commitObservers: [NSObjectProtocol] = []
    private var saveKeyMonitor: Any?

    /// Commits an open text edit before anything that might save: ⌘S, opening a menu (File ▸ Save,
    /// Export…), or leaving the window. The save itself may run in the background, too late to do it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopCommitObservers()
        guard let window else { return }
        let center = NotificationCenter.default
        commitObservers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                self?.endInlineEdit()
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.endInlineEdit()
            },
        ]
        saveKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "s",
               let self, event.window === self.window {
                self.endInlineEdit()
            }
            return event
        }
    }

    private func stopCommitObservers() {
        commitObservers.forEach(NotificationCenter.default.removeObserver)
        commitObservers = []
        if let saveKeyMonitor { NSEvent.removeMonitor(saveKeyMonitor) }
        saveKeyMonitor = nil
    }

    deinit { stopCommitObservers() }

    /// Multi-line editor for Edit → Text (rewriting the page's own paragraphs).
    private var blockEditor: NSTextView?
    private var blockCommit: ((String?) -> Void)?
    private var blockEdit: (page: PDFPage, block: TextBlock)?

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
        let wasEditing = blockEditor != nil || inlineField != nil
        endInlineEdit()
        // Clicking away from an open text box just finishes it, like PDF Expert.
        if wasEditing, model?.tool == .editText || model?.tool == .textBox { return }
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
                // Text added by the older cover-style editing is still an annotation.
                model.editTextAnnotation(hit)
            } else if let block = TextBlock.at(point, on: page) {
                model.selectedImage = nil
                textPress = (point, convert(event.locationInWindow, from: nil), page, block, false)
            } else if !beginImagePress(at: point, on: page, model: model) {
                model.beginBlockEdit(at: point, on: page) // empty space: new text
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
        case .image where model.pendingImage == nil:
            if !beginImagePress(at: point, on: page, model: model) { model.selectedImage = nil }
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

    /// Selects the image under `point` (or grabs a corner of the selected one) to drag. False if none.
    private func beginImagePress(at point: CGPoint, on page: PDFPage, model: DocumentModel) -> Bool {
        if let selection = model.selectedImage, selection.page === page,
           let corner = corner(near: point, of: selection.rect) {
            imageDrag = (point, selection.rect, corner, selection.rect)
            return true
        }
        guard let hit = model.image(at: point, on: page) else { return false }
        model.selectedImage = hit
        imageDrag = (point, hit.rect, nil, hit.rect)
        return true
    }

    override func mouseDragged(with event: NSEvent) {
        if var press = textPress {
            let viewPoint = convert(event.locationInWindow, from: nil)
            if !press.moved, hypot(viewPoint.x - press.viewStart.x, viewPoint.y - press.viewStart.y) < 4 { return }
            press.moved = true
            textPress = press
            let point = convert(viewPoint, to: press.page)
            let moved = press.block.rect.offsetBy(dx: point.x - press.start.x, dy: point.y - press.start.y)
            overlay.show(NSBezierPath(rect: overlayRect(moved, on: press.page)), stroke: .controlAccentColor, width: 1.5, dashed: true)
            return
        }
        if var drag = imageDrag, let selection = model?.selectedImage {
            let point = convert(convert(event.locationInWindow, from: nil), to: selection.page)
            drag.current = Self.dragged(drag.original, corner: drag.corner, from: drag.start, to: point)
            imageDrag = drag
            overlay.show(NSBezierPath(rect: overlayRect(drag.current, on: selection.page)),
                         stroke: .controlAccentColor, width: 1.5, dashed: true)
            return
        }
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

        if let press = textPress {
            textPress = nil
            clearPreview()
            let point = convert(convert(event.locationInWindow, from: nil), to: press.page)
            if press.moved {
                model.moveBlock(press.block, by: CGPoint(x: point.x - press.start.x, y: point.y - press.start.y), on: press.page)
            } else {
                model.beginBlockEdit(press.block, on: press.page)
                placeCaret(at: press.start, on: press.page)
            }
            return
        }

        if let drag = imageDrag {
            imageDrag = nil
            clearPreview()
            let moved = abs(drag.current.minX - drag.original.minX) + abs(drag.current.minY - drag.original.minY)
                + abs(drag.current.width - drag.original.width) + abs(drag.current.height - drag.original.height)
            if moved > 1 { model.moveSelectedImage(to: drag.current) }
            return
        }

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

    // MARK: Image selection

    /// Dashed outline and corner handles around the selected image; lives in the document view so
    /// it scrolls with the page.
    private lazy var selectionBox: SelectionBox = {
        let box = SelectionBox(frame: .zero)
        box.isHidden = true
        return box
    }()

    func updateImageSelection() {
        guard let selection = model?.selectedImage, selection.page.document != nil, let documentView else {
            selectionBox.isHidden = true
            return
        }
        if selectionBox.superview !== documentView { documentView.addSubview(selectionBox) }
        let rect = documentView.convert(convert(selection.rect, from: selection.page), from: self)
        selectionBox.frame = rect.insetBy(dx: -SelectionBox.handle, dy: -SelectionBox.handle)
        selectionBox.isHidden = false
        selectionBox.needsDisplay = true
    }

    /// Which corner of `rect` (0 bottom-left, 1 bottom-right, 2 top-right, 3 top-left) is under `point`.
    private func corner(near point: CGPoint, of rect: CGRect) -> Int? {
        let tolerance = 8 / max(scaleFactor, 0.1)
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        return corners.firstIndex { hypot($0.x - point.x, $0.y - point.y) <= tolerance }
    }

    /// Moves the rect, or resizes it from a corner keeping its proportions (the opposite corner stays put).
    private static func dragged(_ rect: CGRect, corner: Int?, from start: CGPoint, to point: CGPoint) -> CGRect {
        guard let corner else { return rect.offsetBy(dx: point.x - start.x, dy: point.y - start.y) }
        let anchors = [CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
                       CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY)]
        let anchor = anchors[corner]
        let width = max(abs(point.x - anchor.x), 8)
        let height = width * rect.height / max(rect.width, 1)
        let x = point.x < anchor.x ? anchor.x - width : anchor.x
        let y = (corner == 0 || corner == 1) ? anchor.y - height : anchor.y
        return CGRect(x: x, y: y, width: width, height: height)
    }

    override func keyDown(with event: NSEvent) {
        // Delete / forward delete removes the selected image.
        if model?.selectedImage != nil, event.keyCode == 51 || event.keyCode == 117 {
            model?.deleteSelectedImage()
            return
        }
        super.keyDown(with: event)
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
        field.font = NSFont(descriptor: font.fontDescriptor, size: max(font.pointSize * documentScale(for: page), 4))
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
        endBlockEdit(cancel: cancel)
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

    /// How many document-view units one page point takes. The document view is usually magnified
    /// by the scroll view rather than resized, so this is often 1 even when zoomed in.
    private func documentScale(for page: PDFPage) -> CGFloat {
        guard let documentView else { return scaleFactor }
        let unit = documentView.convert(convert(CGRect(x: 0, y: 0, width: 100, height: 100), from: page), from: self)
        return unit.width / 100
    }

    // MARK: Paragraph editing

    /// Opens an editor over `block`, styled from `model.textStyle` and wrapping like the page.
    func beginBlockEdit(_ block: TextBlock, on page: PDFPage, commit: @escaping (String?) -> Void) {
        endInlineEdit()
        guard let documentView else { return }
        let editor = NSTextView(frame: .zero)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.drawsBackground = true
        editor.backgroundColor = .white
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.isVerticallyResizable = false
        editor.isHorizontallyResizable = false
        editor.textContainer?.widthTracksTextView = block.wraps
        if !block.wraps {
            editor.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                         height: CGFloat.greatestFiniteMagnitude)
        }
        editor.wantsLayer = true
        editor.layer?.borderColor = NSColor.controlAccentColor.cgColor
        editor.layer?.borderWidth = 1
        editor.string = block.text
        editor.delegate = self

        blockEditor = editor
        blockCommit = commit
        blockEdit = (page, block)
        documentView.addSubview(editor)
        applyEditorStyle()
        window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (block.text as NSString).length, length: 0))
    }

    /// Puts the caret where the paragraph was clicked, as in a word processor.
    private func placeCaret(at point: CGPoint, on page: PDFPage) {
        guard let editor = blockEditor, let documentView else { return }
        let inDocument = documentView.convert(convert(point, from: page), from: self)
        let index = editor.characterIndexForInsertion(at: editor.convert(inDocument, from: documentView))
        editor.setSelectedRange(NSRange(location: index, length: 0))
    }

    /// Re-applies the font, size, color and alignment from the Edit → Text panel.
    func applyEditorStyle() {
        guard let editor = blockEditor, let style = model?.textStyle, let (page, _) = blockEdit else { return }
        let scale = documentScale(for: page)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style.alignment
        paragraph.minimumLineHeight = style.lineHeight * scale
        paragraph.maximumLineHeight = style.lineHeight * scale
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(descriptor: style.font.fontDescriptor, size: style.size * scale) ?? style.font,
            .foregroundColor: style.color,
            .paragraphStyle: paragraph,
        ]
        editor.textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: editor.textStorage?.length ?? 0))
        editor.typingAttributes = attributes
        resizeBlockEditor()
    }

    /// Keeps the editor's top edge fixed and grows it to fit the text.
    private func resizeBlockEditor() {
        guard let editor = blockEditor, let (page, block) = blockEdit, let documentView,
              let layout = editor.layoutManager, let container = editor.textContainer else { return }
        var frame = documentView.convert(convert(block.rect.insetBy(dx: -2, dy: -1), from: page), from: self)
        if block.wraps { container.containerSize = NSSize(width: frame.width, height: .greatestFiniteMagnitude) }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let width = block.wraps ? frame.width : max(frame.width, used.width + 8)
        let height = max(frame.height, used.height + 2)
        if !block.wraps, editor.alignment == .center { frame.origin.x = frame.midX - width / 2 }
        if !documentView.isFlipped { frame.origin.y = frame.maxY - height }
        frame.size = CGSize(width: width, height: height)
        editor.frame = frame
    }

    private func endBlockEdit(cancel: Bool) {
        guard let editor = blockEditor else { return }
        let commit = blockCommit
        blockEditor = nil
        blockCommit = nil
        blockEdit = nil
        let text = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        editor.delegate = nil
        editor.removeFromSuperview()
        window?.makeFirstResponder(self)
        commit?(cancel ? nil : text)
    }

    func textDidChange(_ notification: Notification) {
        if notification.object as? NSTextView === blockEditor { resizeBlockEditor() }
    }

    func textDidEndEditing(_ notification: Notification) {
        if notification.object as? NSTextView === blockEditor { endBlockEdit(cancel: false) }
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard textView === blockEditor, selector == #selector(cancelOperation(_:)) else { return false }
        endBlockEdit(cancel: true)
        return true
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

/// Outline with corner handles for the selected image. Click-through; drawing only.
private final class SelectionBox: NSView {
    static let handle: CGFloat = 5

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let inner = bounds.insetBy(dx: Self.handle, dy: Self.handle)
        let outline = NSBezierPath(rect: inner)
        outline.lineWidth = 1
        outline.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        outline.stroke()
        for corner in [CGPoint(x: inner.minX, y: inner.minY), CGPoint(x: inner.maxX, y: inner.minY),
                       CGPoint(x: inner.maxX, y: inner.maxY), CGPoint(x: inner.minX, y: inner.maxY)] {
            let dot = NSBezierPath(ovalIn: CGRect(x: corner.x - Self.handle + 1, y: corner.y - Self.handle + 1,
                                                  width: 2 * Self.handle - 2, height: 2 * Self.handle - 2))
            NSColor.white.setFill()
            dot.fill()
            NSColor.controlAccentColor.setStroke()
            dot.lineWidth = 1.5
            dot.stroke()
        }
    }
}
