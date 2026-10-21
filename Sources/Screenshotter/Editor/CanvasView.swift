import AppKit
import Carbon.HIToolbox

/// Displays the screenshot with its annotations and handles drawing input.
/// Coordinates: the view is flipped and sized to the current crop; document
/// coordinates are image points relative to the uncropped image.
final class CanvasView: NSView, NSTextFieldDelegate, NSMenuItemValidation {
    /// Toolbar settings for new marks. They follow the selected mark, and changing
    /// them edits it.
    struct Style: Equatable {
        var color: NSColor = .systemRed
        var lineWidth: CGFloat = 4
        var markerWidth: CGFloat = 28
        var fontSize: CGFloat = 26
    }

    var onStyleChange: (() -> Void)?
    var onCropChange: (() -> Void)?

    private let document: CanvasDocument
    private(set) var style = Style()
    private var drawingColor: NSColor = .systemRed
    private var highlightColor: NSColor = .yellow

    var tool: Tool = .arrow {
        willSet { commitText() }
        didSet {
            selectedIndex = nil
            style.color = tool == .highlight ? highlightColor : drawingColor
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
            onStyleChange?()
        }
    }
    var color: NSColor {
        get { style.color }
        set { restyle { $0.color = newValue } }
    }
    var lineWidth: CGFloat {
        get { style.lineWidth }
        set { restyle { $0.lineWidth = newValue } }
    }
    var markerWidth: CGFloat {
        get { style.markerWidth }
        set { restyle { $0.markerWidth = newValue } }
    }
    var textFontSize: CGFloat {
        get { style.fontSize }
        set { restyle { $0.fontSize = newValue } }
    }

    var annotations: [Annotation] { document.annotations }
    var crop: CGRect { document.crop }
    /// Bumped on every edit, undo and redo, so callers can tell whether the image
    /// changed since they last exported it.
    var changeCount: Int { document.changeCount }

    private(set) var selectedIndex: Int?
    /// The mark being moved or resized; `moved` is nil until the pointer moves.
    private var manipulation: (index: Int, original: Annotation, handle: Int?, moved: Annotation?)?
    private var editingTextIndex: Int?

    private var dragStart: CGPoint?
    private var draft: Annotation?
    private var marquee: CGRect?

    private var textField: NSTextField?

    init(screenshot: Screenshot) {
        document = CanvasDocument(screenshot: screenshot)
        super.init(frame: NSRect(origin: .zero, size: document.crop.size))
        document.onChange = { [weak self] cropChanged in self?.documentDidChange(cropChanged: cropChanged) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch tool {
        case .highlight: cursor = MarkerStroke.cursor(height: markerWidth, zoom: zoom)
        case .select: cursor = .arrow
        case .text: cursor = .iBeam
        default: cursor = .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: Selection and style

    /// Properties belong to the selected object while the pointer tool remains active.
    var propertiesTool: Tool { selectedIndex.map { annotations[$0].tool } ?? tool }

    private var zoom: CGFloat { enclosingScrollView?.magnification ?? 1 }

    private func select(_ index: Int) {
        selectedIndex = index
        let annotation = annotations[index]
        style.color = annotation.color
        switch annotation.shape {
        case .highlight: style.markerWidth = annotation.lineWidth
        case let .text(_, _, size): style.fontSize = size
        default: if annotation.lineWidth > 0 { style.lineWidth = annotation.lineWidth }
        }
        window?.invalidateCursorRects(for: self)
        onStyleChange?()
        needsDisplay = true
    }

    private func deselect() {
        selectedIndex = nil
        onStyleChange?()
        needsDisplay = true
    }

    /// Changes the style from the toolbar and applies it to the label being typed
    /// or the selected mark.
    private func restyle(_ change: (inout Style) -> Void) {
        let old = style
        change(&style)
        guard style != old else { return }
        if style.color != old.color {
            if propertiesTool == .highlight { highlightColor = style.color } else { drawingColor = style.color }
        }
        if style.markerWidth != old.markerWidth { window?.invalidateCursorRects(for: self) }
        if let textField {
            textField.textColor = style.color
            textField.font = Annotation.font(size: style.fontSize)
            resizeTextField()
        } else {
            editSelection { annotation in
                annotation.color = style.color
                switch annotation.shape {
                case .highlight: annotation.lineWidth = style.markerWidth
                case let .text(string, origin, _): annotation.shape = .text(string, origin: origin, fontSize: style.fontSize)
                default: annotation.lineWidth = style.lineWidth
                }
            }
        }
        onStyleChange?()
    }

    private func editSelection(_ edit: (inout Annotation) -> Void) {
        guard let index = selectedIndex, annotations[index].tool != .pixelate else { return }
        var edited = annotations[index]
        edit(&edited)
        let old = annotations[index]
        guard edited.color != old.color || edited.lineWidth != old.lineWidth
                || edited.bounds != old.bounds else { return }
        document.apply { $0.annotations[index] = edited }
    }

    private func drawSelection() {
        guard let index = selectedIndex, editingTextIndex == nil else { return }
        let annotation = shownAnnotations[index]
        let border = NSBezierPath(rect: annotation.bounds.insetBy(dx: -2 / zoom, dy: -2 / zoom))
        border.lineWidth = 1 / zoom
        border.setLineDash([4 / zoom, 3 / zoom], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        border.stroke()
        for point in annotation.handles {
            let handle = NSBezierPath(rect: CGRect(x: point.x - 3 / zoom, y: point.y - 3 / zoom,
                                                   width: 6 / zoom, height: 6 / zoom))
            NSColor.white.setFill()
            handle.fill()
            handle.lineWidth = 1 / zoom
            handle.stroke()
        }
    }

    private func beginEditingText(_ index: Int) {
        guard case let .text(string, origin, _) = annotations[index].shape else { return }
        beginText(at: origin)
        editingTextIndex = index
        guard let field = textField else { return }
        field.stringValue = string
        field.frame.origin.y = origin.y - crop.minY
        resizeTextField()
        field.selectText(nil)
        needsDisplay = true
    }

    // MARK: Drawing

    /// The annotations as shown, including one being moved or resized.
    private var shownAnnotations: [Annotation] {
        var shown = annotations
        if let manipulation, let moved = manipulation.moved { shown[manipulation.index] = moved }
        return shown
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        // AppKit can draw outside a view's bounds. Keep the preview confined to
        // the cropped canvas, including when it is centered in a larger viewport.
        context.clip(to: bounds)
        context.translateBy(x: -crop.minX, y: -crop.minY)
        document.draw(shownAnnotations, skipping: editingTextIndex)
        draft?.draw()

        if let marquee {
            if tool == .crop {
                let dim = NSBezierPath(rect: crop)
                dim.append(NSBezierPath(rect: marquee))
                dim.windingRule = .evenOdd
                NSColor.black.withAlphaComponent(0.5).setFill()
                dim.fill()
            }
            let border = NSBezierPath(rect: marquee)
            border.lineWidth = 1
            border.setLineDash([4, 4], count: 2, phase: 0)
            NSColor.white.setStroke()
            border.stroke()
        }
        drawSelection()
        context.restoreGState()
    }

    /// Flattens annotations and crop into a full-resolution image, or nil if that failed.
    func renderScreenshot() -> Screenshot? {
        commitText()
        finishManipulation()
        return document.renderScreenshot()
    }

    private func documentDidChange(cropChanged: Bool) {
        if cropChanged {
            setFrameSize(crop.size)
            window?.invalidateCursorRects(for: self)
            onCropChange?()
        }
        needsDisplay = true
    }

    // MARK: Undo

    /// Undo manager of the text field being edited, which owns typing undo.
    private var textUndoManager: UndoManager? {
        textField?.currentEditor()?.undoManager
    }

    @objc func undo(_ sender: Any?) {
        if textField != nil {
            textUndoManager?.undo()
            return
        }
        guard manipulation == nil, document.canUndo else { return }
        deselect()
        document.undo()
    }

    @objc func redo(_ sender: Any?) {
        if textField != nil {
            textUndoManager?.redo()
            return
        }
        guard manipulation == nil, document.canRedo else { return }
        deselect()
        document.redo()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)): textField != nil ? textUndoManager?.canUndo == true : document.canUndo
        case #selector(redo(_:)): textField != nil ? textUndoManager?.canRedo == true : document.canRedo
        default: true
        }
    }

    // MARK: Mouse

    private func documentPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x + crop.minX, y: point.y + crop.minY)
    }

    private func rect(from a: CGPoint, to b: CGPoint, square: Bool) -> CGRect {
        var width = b.x - a.x, height = b.y - a.y
        if square {
            let side = max(abs(width), abs(height))
            width = width < 0 ? -side : side
            height = height < 0 ? -side : side
        }
        return CGRect(x: a.x, y: a.y, width: width, height: height).standardized
    }

    override func mouseDown(with event: NSEvent) {
        if textField != nil {
            commitText()
            // Clicking away finishes the label; only Select goes on to pick a mark.
            if tool != .select { return }
        }
        window?.makeFirstResponder(self)
        let point = documentPoint(event)
        dragStart = point
        if tool == .select {
            if event.clickCount == 1, let index = selectedIndex,
               let handle = annotations[index].handles.firstIndex(where: { hypot($0.x - point.x, $0.y - point.y) <= 7 / zoom }) {
                manipulation = (index, annotations[index], handle, nil)
                return
            }
            if let index = annotations.indices.reversed().first(where: { annotations[$0].hitTest(point, tolerance: 5 / zoom) }) {
                select(index)
                if event.clickCount == 2, case .text = annotations[index].shape {
                    beginEditingText(index)
                    dragStart = nil
                } else {
                    manipulation = (index, annotations[index], nil, nil)
                }
                return
            }
        }
        deselect()
        switch tool {
        case .text:
            beginText(at: point)
            dragStart = nil
        case .pen:
            draft = Annotation(shape: .pen([point]), color: color, lineWidth: lineWidth)
        case .highlight:
            draft = Annotation(shape: .highlight([point]), color: color, lineWidth: markerWidth)
        default:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        var point = documentPoint(event)
        if let manipulation {
            guard hypot(point.x - start.x, point.y - start.y) > 0.5 || manipulation.moved != nil else { return }
            self.manipulation?.moved = manipulation.handle
                .map { manipulation.original.resized(handle: $0, to: point) }
                ?? manipulation.original.translated(dx: point.x - start.x, dy: point.y - start.y)
            needsDisplay = true
            return
        }
        let shift = event.modifierFlags.contains(.shift)
        let box = rect(from: start, to: point, square: shift)

        switch tool {
        case .arrow:
            if shift { point = snapped(point, from: start) }
            draft = Annotation(shape: .arrow(from: start, to: point), color: color, lineWidth: lineWidth)
        case .rectangle:
            draft = Annotation(shape: .rectangle(box), color: color, lineWidth: lineWidth)
        case .ellipse:
            draft = Annotation(shape: .ellipse(box), color: color, lineWidth: lineWidth)
        case .highlight:
            if case var .highlight(points) = draft?.shape {
                points.append(point)
                draft?.shape = .highlight(points)
            }
        case .pen:
            if case var .pen(points) = draft?.shape {
                points.append(point)
                draft?.shape = .pen(points)
            }
        case .pixelate:
            marquee = box
        case .crop:
            marquee = box.intersection(crop)
        case .text, .select:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if manipulation == nil, case var .highlight(points) = draft?.shape {
            let point = documentPoint(event)
            if points.last != point { points.append(point) }
            draft?.shape = .highlight(points)
        }
        defer {
            dragStart = nil
            draft = nil
            marquee = nil
            needsDisplay = true
        }
        if manipulation != nil {
            finishManipulation()
            return
        }
        switch tool {
        case .crop:
            if let marquee, marquee.width > 4, marquee.height > 4 {
                document.apply { $0.crop = marquee.integral.intersection(document.fullRect) }
            }
        case .pixelate:
            if let marquee, let annotation = document.pixelate(marquee) {
                document.apply { $0.annotations.append(annotation) }
            }
        default:
            if let draft, draft.isMeaningful {
                document.apply { $0.annotations.append(draft) }
            }
        }
    }

    /// Commits the mark being moved or resized, if any.
    private func finishManipulation() {
        guard let manipulation else { return }
        self.manipulation = nil
        guard var moved = manipulation.moved else { return }
        // Pixelation is a region of the screenshot, not a movable copy of old pixels.
        if case let .patch(rect, _) = moved.shape {
            guard let patch = document.pixelate(rect, below: manipulation.index) else { return }
            moved = patch
        }
        document.apply { $0.annotations[manipulation.index] = moved }
        if let selectedIndex { select(selectedIndex) }
    }

    /// Focuses the label being typed, if any, so toolbar clicks don't end it.
    func focus() {
        window?.makeFirstResponder(textField ?? self)
    }

    /// Snaps the end point to the nearest 45° direction.
    private func snapped(_ point: CGPoint, from start: CGPoint) -> CGPoint {
        let dx = point.x - start.x, dy = point.y - start.y
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let length = hypot(dx, dy)
        return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            if selectedIndex != nil { deselect() } else { window?.performClose(nil) }
        case kVK_Delete, kVK_ForwardDelete:
            if let index = selectedIndex, manipulation == nil {
                deselect()
                document.apply { $0.annotations.remove(at: index) }
            }
        case kVK_Return, kVK_ANSI_KeypadEnter:
            tryToPerform(#selector(EditorWindowController.done(_:)), with: self)
        default:
            let modifiers = event.modifierFlags.intersection([.command, .option, .control])
            if modifiers.isEmpty,
               let character = event.charactersIgnoringModifiers?.lowercased().first,
               let newTool = Tool.allCases.first(where: { $0.key == character }) {
                tool = newTool
            } else {
                super.keyDown(with: event)
            }
        }
    }

    // MARK: Text

    private func beginText(at point: CGPoint) {
        let field = NSTextField(string: "")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Annotation.font(size: textFontSize)
        field.textColor = color
        field.delegate = self
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        let height = ceil(field.intrinsicContentSize.height)
        field.frame = NSRect(x: point.x - crop.minX - 2, y: point.y - crop.minY - height / 2,
                             width: max(textFontSize * 4, 60), height: height)
        addSubview(field)
        textField = field
        window?.makeFirstResponder(field)
    }

    /// Fits the label being typed to its text and font.
    private func resizeTextField() {
        guard let field = textField else { return }
        let width = (field.stringValue as NSString)
            .size(withAttributes: [.font: field.font ?? Annotation.font(size: textFontSize)]).width
        field.frame.size = CGSize(width: max(textFontSize * 4, ceil(width) + textFontSize),
                                  height: ceil(field.intrinsicContentSize.height))
    }

    func controlTextDidChange(_ notification: Notification) {
        resizeTextField()
    }

    /// Esc finishes the label instead of triggering text completion.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        commitText()
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        commitText()
    }

    /// Turns the in-progress text field (if any) into an annotation.
    func commitText() {
        guard let field = textField else { return }
        textField = nil
        let string = field.stringValue
        let fontSize = field.font?.pointSize ?? textFontSize
        // NSTextField insets its text by 2pt horizontally.
        let origin = CGPoint(x: field.frame.minX + 2 + crop.minX, y: field.frame.minY + crop.minY)
        let annotation = Annotation(shape: .text(string, origin: origin, fontSize: fontSize),
                                    color: field.textColor ?? color, lineWidth: lineWidth)
        let editingIndex = editingTextIndex
        editingTextIndex = nil
        field.removeFromSuperview()
        if let index = editingIndex {
            let original = annotations[index]
            if annotation.isMeaningful {
                if case let .text(oldString, _, oldSize) = original.shape,
                   oldString != string || oldSize != fontSize || original.color != annotation.color {
                    document.apply { $0.annotations[index] = annotation }
                }
                select(index)
            } else {
                deselect()
                document.apply { $0.annotations.remove(at: index) }
            }
        } else if annotation.isMeaningful {
            document.apply { $0.annotations.append(annotation) }
        }
        needsDisplay = true
        window?.makeFirstResponder(self)
    }
}
