import PDFKit

/// PDFView that routes mouse input to the active tool.
final class MacPDFView: PDFView, NSTextFieldDelegate, NSTextViewDelegate {
    weak var model: DocumentModel?

    private let inkWidth: CGFloat = 3
    private var inkPath: NSBezierPath?
    private var dragPage: PDFPage?
    private var dragStart: CGPoint?
    /// Edit → Text press on a paragraph: becomes a move if dragged, an edit if just clicked.
    private var textPress: (start: CGPoint, viewStart: CGPoint, page: PDFPage, block: TextBlock, moved: Bool, snappedOffset: CGPoint)?

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
    private var blockCommit: ((NSAttributedString?, TextBlock) -> Void)?
    /// The paragraph style last applied to the editor, to restyle words without losing their own bold/italic/color.
    private var appliedStyle: TextStyle?
    private var blockEdit: (page: PDFPage, block: TextBlock)?
    /// Where the paragraph will go, in page coordinates; moved and resized with the box's handles.
    private var blockFrame = CGRect.zero
    private var blockWraps = false
    /// Covers the paragraph's original spot while the box is moved away, so it isn't seen twice.
    private let originalMask: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.cgColor
        return view
    }()
    private lazy var editorChrome: EditorChrome = {
        let chrome = EditorChrome(frame: .zero)
        chrome.onDrag = { [weak self] part, delta, phase in self?.dragEditor(part, by: delta, phase: phase) }
        return chrome
    }()

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
                textPress = (point, convert(event.locationInWindow, from: nil), page, block, false, .zero)
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
            let (snapped, guides) = snap(moved, on: press.page, ignoring: press.block.rect)
            press.snappedOffset = CGPoint(x: snapped.minX - press.block.rect.minX, y: snapped.minY - press.block.rect.minY)
            textPress = press
            showGuides(guides, on: press.page, box: snapped)
            return
        }
        if var drag = imageDrag, let selection = model?.selectedImage {
            let point = convert(convert(event.locationInWindow, from: nil), to: selection.page)
            drag.current = Self.dragged(drag.original, corner: drag.corner, from: drag.start, to: point)
            var guides: [(CGPoint, CGPoint)] = []
            if drag.corner == nil { (drag.current, guides) = snap(drag.current, on: selection.page, ignoring: drag.original) }
            imageDrag = drag
            showGuides(guides, on: selection.page, box: drag.current)
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
            if press.moved {
                model.moveBlock(press.block, by: press.snappedOffset, on: press.page)
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
    func beginBlockEdit(_ block: TextBlock, on page: PDFPage, commit: @escaping (NSAttributedString?, TextBlock) -> Void) {
        endInlineEdit()
        guard let documentView else { return }
        let editor = NSTextView(frame: .zero)
        editor.isRichText = true
        editor.importsGraphics = false
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
        editor.string = block.text
        editor.delegate = self
        if #available(macOS 15.0, *) { editor.writingToolsBehavior = .none }

        blockEditor = editor
        blockCommit = commit
        appliedStyle = nil
        blockEdit = (page, block)
        blockFrame = block.rect
        blockWraps = block.wraps
        if block.replacesText {
            originalMask.frame = documentView.convert(convert(block.rect.insetBy(dx: -1, dy: -1), from: page), from: self)
            documentView.addSubview(originalMask)
        }
        documentView.addSubview(editor)
        documentView.addSubview(editorChrome, positioned: .above, relativeTo: editor)
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

    /// Re-applies the paragraph's font, size, color and alignment from the Edit → Text panel. Words
    /// styled on their own keep their bold/italic and color; the family and size follow the paragraph.
    func applyEditorStyle() {
        guard let editor = blockEditor, let storage = editor.textStorage, let style = model?.textStyle,
              let (page, _) = blockEdit else { return }
        let scale = documentScale(for: page)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style.alignment
        paragraph.minimumLineHeight = style.lineHeight * scale
        paragraph.maximumLineHeight = style.lineHeight * scale
        let base = NSFont(descriptor: style.font.fontDescriptor, size: style.size * scale) ?? style.font
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        if let old = appliedStyle {
            let manager = NSFontManager.shared
            let sizeRatio = style.size / max(old.size, 1)
            storage.enumerateAttribute(.font, in: whole) { value, range, _ in
                guard let font = value as? NSFont else { return }
                var updated = font
                if old.font.familyName != style.font.familyName, let family = style.font.familyName {
                    updated = manager.convert(updated, toFamily: family)
                }
                // Paragraph-wide bold/italic changes apply to every word.
                for trait in [NSFontTraitMask.boldFontMask, .italicFontMask]
                where old.font.fontDescriptor.symbolicTraits != style.font.fontDescriptor.symbolicTraits {
                    let had = manager.traits(of: old.font).contains(trait), has = manager.traits(of: style.font).contains(trait)
                    if had != has { updated = has ? manager.convert(updated, toHaveTrait: trait) : manager.convert(updated, toNotHaveTrait: trait) }
                }
                updated = manager.convert(updated, toSize: font.pointSize * sizeRatio)
                storage.addAttribute(.font, value: updated, range: range)
            }
            if old.color != style.color {
                storage.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
                    if (value as? NSColor) == old.color || value == nil { storage.addAttribute(.foregroundColor, value: style.color, range: range) }
                }
            }
        } else {
            storage.setAttributes([.font: base, .foregroundColor: style.color], range: whole)
        }
        storage.addAttribute(.paragraphStyle, value: paragraph, range: whole)
        storage.endEditing()
        var typing = editor.typingAttributes
        typing[.paragraphStyle] = paragraph
        if appliedStyle == nil { typing[.font] = base; typing[.foregroundColor] = style.color }
        editor.typingAttributes = typing
        appliedStyle = style
        resizeBlockEditor()
    }

    /// Applies a font/color change to the selected words only. Returns false when nothing is selected.
    @discardableResult
    func styleSelection(font change: ((NSFont) -> NSFont)? = nil, color: NSColor? = nil) -> Bool {
        guard let editor = blockEditor, let storage = editor.textStorage else { return false }
        let range = editor.selectedRange()
        guard range.length > 0 else { return false }
        storage.beginEditing()
        if let change {
            storage.enumerateAttribute(.font, in: range) { value, sub, _ in
                if let font = value as? NSFont { storage.addAttribute(.font, value: change(font), range: sub) }
            }
        }
        if let color { storage.addAttribute(.foregroundColor, value: color, range: range) }
        storage.endEditing()
        resizeBlockEditor()
        return true
    }

    /// Grows or shrinks the selected words by `points` (page points). False when nothing is selected.
    func resizeSelection(by points: CGFloat) -> Bool {
        guard let (page, _) = blockEdit else { return false }
        let scale = documentScale(for: page)
        return styleSelection(font: { NSFont(descriptor: $0.fontDescriptor, size: max($0.pointSize + points * scale, 4 * scale)) ?? $0 })
    }

    /// Font of the selected words (page points), for showing bold/italic state in the panel.
    var selectionHasText: Bool { (blockEditor?.selectedRange().length ?? 0) > 0 }

    /// Keeps the editor's top edge fixed and grows it to fit the text.
    private func resizeBlockEditor() {
        guard let editor = blockEditor, let (page, _) = blockEdit, let documentView,
              let layout = editor.layoutManager, let container = editor.textContainer else { return }
        var frame = documentView.convert(convert(blockFrame.insetBy(dx: -2, dy: -1), from: page), from: self)
        container.widthTracksTextView = blockWraps
        container.containerSize = NSSize(width: blockWraps ? frame.width : .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let width = blockWraps ? frame.width : max(frame.width, used.width + 8)
        let height = max(frame.height, used.height + 2)
        if !blockWraps, editor.alignment == .center { frame.origin.x = frame.midX - width / 2 }
        if !documentView.isFlipped { frame.origin.y = frame.maxY - height }
        frame.size = CGSize(width: width, height: height)
        editor.frame = frame
        editorChrome.frame = frame.insetBy(dx: -EditorChrome.pad, dy: -EditorChrome.pad)
        editorChrome.needsDisplay = true
    }

    /// Moving the box (handle or border) or changing its width (side handles), with snapping.
    private func dragEditor(_ part: EditorChrome.Part, by delta: CGSize, phase: EditorChrome.Phase) {
        guard let (page, block) = blockEdit else { return }
        if phase == .began { dragOrigin = blockFrame }
        let scale = documentScale(for: page)
        let dx = delta.width / scale
        let dy = (documentView?.isFlipped ?? true) ? -delta.height / scale : delta.height / scale
        var frame = dragOrigin
        switch part {
        case .move:
            frame = frame.offsetBy(dx: dx, dy: dy)
            let (snapped, guides) = snap(frame, on: page, ignoring: block.rect)
            frame = snapped
            showGuides(guides, on: page)
        case .left:
            frame = CGRect(x: frame.minX + dx, y: frame.minY, width: max(frame.width - dx, 24), height: frame.height)
            blockWraps = true
        case .right:
            frame.size.width = max(frame.width + dx, 24)
            blockWraps = true
        }
        if phase == .ended { clearPreview() }
        blockFrame = frame
        resizeBlockEditor()
    }
    private var dragOrigin = CGRect.zero

    // MARK: Snapping

    private final class SnapTargets {
        let rects: [CGRect]
        init(_ rects: [CGRect]) { self.rects = rects }
    }
    private static let snapCache = NSMapTable<PDFPage, SnapTargets>.weakToStrongObjects()

    /// Lines of text and images on the page, for lining things up with.
    private func snapTargets(on page: PDFPage) -> [CGRect] {
        if let cached = Self.snapCache.object(forKey: page) { return cached.rects }
        let lines = (page.selection(for: page.bounds(for: .mediaBox))?.selectionsByLine() ?? [])
            .compactMap { TextBlock.Line($0, page: page)?.bounds }
        let rects = lines + (model?.imageRects(on: page).map(\.rect) ?? [])
        Self.snapCache.setObject(SnapTargets(rects), forKey: page)
        return rects
    }

    /// Nudges `rect` so a left/centre/right edge or its top/bottom lines up with nearby text, images
    /// or the page centre when within a few points. Returns guide lines (page coordinates) to draw.
    func snap(_ rect: CGRect, on page: PDFPage, ignoring: CGRect) -> (CGRect, [(CGPoint, CGPoint)]) {
        let threshold = 6 / max(scaleFactor, 0.1)
        let others = snapTargets(on: page).filter { !$0.intersects(ignoring.insetBy(dx: 1, dy: 1)) }
        let pageMid = page.bounds(for: .cropBox).midX

        var best: (dx: CGFloat, x: CGFloat, target: CGRect?)? = nil
        for (edge, value) in [(0, rect.minX), (1, rect.midX), (2, rect.maxX)] {
            var candidates = others.map { ([$0.minX, $0.midX, $0.maxX][edge], Optional($0)) }
            if edge == 1 { candidates.append((pageMid, nil)) }
            for (x, target) in candidates where abs(x - value) <= threshold && abs(x - value) < abs(best?.dx ?? .infinity) {
                best = (x - value, x, target)
            }
        }
        var bestY: (dy: CGFloat, y: CGFloat, target: CGRect)? = nil
        for value in [rect.maxY, rect.minY] {
            for target in others {
                for y in [target.maxY, target.minY] where abs(y - value) <= threshold && abs(y - value) < abs(bestY?.dy ?? .infinity) {
                    bestY = (y - value, y, target)
                }
            }
        }
        var snapped = rect
        var guides: [(CGPoint, CGPoint)] = []
        if let best {
            snapped.origin.x += best.dx
            let box = page.bounds(for: .cropBox)
            let span = best.target.map { (min($0.minY, snapped.minY), max($0.maxY, snapped.maxY)) } ?? (box.minY, box.maxY)
            guides.append((CGPoint(x: best.x, y: span.0 - 6), CGPoint(x: best.x, y: span.1 + 6)))
        }
        if let bestY {
            snapped.origin.y += bestY.dy
            guides.append((CGPoint(x: min(bestY.target.minX, snapped.minX) - 6, y: bestY.y),
                           CGPoint(x: max(bestY.target.maxX, snapped.maxX) + 6, y: bestY.y)))
        }
        return (snapped, guides)
    }

    private func showGuides(_ guides: [(CGPoint, CGPoint)], on page: PDFPage, box: CGRect? = nil) {
        let path = NSBezierPath()
        for (a, b) in guides {
            path.move(to: overlayPoint(a, on: page))
            path.line(to: overlayPoint(b, on: page))
        }
        if let box {
            overlay.show(NSBezierPath(rect: overlayRect(box, on: page)), stroke: .controlAccentColor, width: 1.5, dashed: true, guides: path)
        } else {
            overlay.show(NSBezierPath(), guides: path)
        }
    }

    private func endBlockEdit(cancel: Bool) {
        guard let editor = blockEditor else { return }
        let commit = blockCommit
        var placed = blockEdit?.block
        placed?.rect = blockFrame
        placed?.wraps = blockWraps
        blockEditor = nil
        blockCommit = nil
        blockEdit = nil
        // Back to page points (the editor shows text at the zoomed size), trimmed like the plain text was.
        let scale = blockEdit.map { documentScale(for: $0.page) } ?? 1
        let content = NSMutableAttributedString(attributedString: editor.attributedString())
        content.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: content.length))
        content.enumerateAttribute(.font, in: NSRange(location: 0, length: content.length)) { value, range, _ in
            if let font = value as? NSFont, let unscaled = NSFont(descriptor: font.fontDescriptor, size: font.pointSize / scale) {
                content.addAttribute(.font, value: unscaled, range: range)
            }
        }
        while let first = content.string.first, first.isWhitespace || first.isNewline { content.deleteCharacters(in: NSRange(location: 0, length: 1)) }
        while let last = content.string.last, last.isWhitespace || last.isNewline {
            content.deleteCharacters(in: NSRange(location: content.length - 1, length: 1))
        }
        editor.delegate = nil
        editor.removeFromSuperview()
        editorChrome.removeFromSuperview()
        originalMask.removeFromSuperview()
        clearPreview()
        window?.makeFirstResponder(self)
        if let placed { commit?(cancel ? nil : content, placed) }
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

    /// Alignment guides, drawn as thin magenta lines on top.
    private var guides: NSBezierPath?

    func show(_ path: NSBezierPath, stroke: NSColor? = nil, width: CGFloat = 1, dashed: Bool = false, fill: NSColor? = nil,
              guides: NSBezierPath? = nil) {
        guides?.lineWidth = 1
        self.guides = guides
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
        if let guides { NSColor.systemPink.setStroke(); guides.stroke() }
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

/// The frame around the paragraph being edited: a move handle at the top-left, a draggable border,
/// and handles on the left and right edges for the width. Clicks inside pass through to the text.
private final class EditorChrome: NSView {
    enum Part { case move, left, right }
    enum Phase { case began, changed, ended }
    static let pad: CGFloat = 7

    var onDrag: ((Part, CGSize, Phase) -> Void)?
    private var dragging: (part: Part, start: NSPoint)?

    private var inner: NSRect { bounds.insetBy(dx: Self.pad, dy: Self.pad) }
    private var moveHandle: NSRect {
        NSRect(x: 0, y: isFlipped ? 0 : bounds.maxY - 2 * Self.pad, width: 2 * Self.pad, height: 2 * Self.pad)
    }
    private func sideHandle(_ part: Part) -> NSRect {
        let x = part == .left ? 0 : bounds.maxX - 2 * Self.pad
        return NSRect(x: x, y: bounds.midY - Self.pad, width: 2 * Self.pad, height: 2 * Self.pad)
    }

    override var isFlipped: Bool { true }

    private func part(at point: NSPoint) -> Part? {
        if moveHandle.contains(point) { return .move }
        if sideHandle(.left).contains(point) { return .left }
        if sideHandle(.right).contains(point) { return .right }
        // The border band moves the box; the inside belongs to the text.
        return inner.insetBy(dx: 3, dy: 3).contains(point) ? nil : .move
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        return bounds.contains(local) && part(at: local) != nil ? self : nil
    }

    override func resetCursorRects() {
        addCursorRect(moveHandle, cursor: .openHand)
        addCursorRect(sideHandle(.left), cursor: .resizeLeftRight)
        addCursorRect(sideHandle(.right), cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let part = part(at: point) else { return }
        dragging = (part, event.locationInWindow)
        onDrag?(part, .zero, .began)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragging, let superview else { return }
        let a = superview.convert(dragging.start, from: nil), b = superview.convert(event.locationInWindow, from: nil)
        onDrag?(dragging.part, CGSize(width: b.x - a.x, height: b.y - a.y), .changed)
    }

    override func mouseUp(with event: NSEvent) {
        guard let dragging, let superview else { return }
        let a = superview.convert(dragging.start, from: nil), b = superview.convert(event.locationInWindow, from: nil)
        onDrag?(dragging.part, CGSize(width: b.x - a.x, height: b.y - a.y), .ended)
        self.dragging = nil
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        let border = NSBezierPath(rect: inner.insetBy(dx: -1, dy: -1))
        border.lineWidth = 1
        border.setLineDash([4, 3], count: 2, phase: 0)
        accent.setStroke()
        border.stroke()
        for rect in [sideHandle(.left), sideHandle(.right)] {
            let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 2.5, dy: 2.5))
            NSColor.white.setFill(); dot.fill()
            accent.setStroke(); dot.lineWidth = 1.5; dot.stroke()
        }
        let handle = NSBezierPath(ovalIn: moveHandle.insetBy(dx: 0.5, dy: 0.5))
        accent.setFill(); handle.fill()
        if let arrows = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right", accessibilityDescription: "Move")?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold)) {
            let tinted = NSImage(size: arrows.size, flipped: false) { r in
                arrows.draw(in: r)
                NSColor.white.set()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: moveHandle.insetBy(dx: 3, dy: 3))
        }
    }
}
