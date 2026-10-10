import AppKit

/// Shows the frozen screen contents on every display and lets the user drag out a
/// region. A click without dragging captures the whole display; holding ⌥ on
/// release trims uniform margins from the selection; Esc cancels.
final class AreaSelectionController {
    private var windows: [NSWindow] = []
    private var completion: ((Screenshot?) -> Void)?

    init(captures: [(screen: NSScreen, image: CGImage)], completion: @escaping (Screenshot?) -> Void) {
        self.completion = completion
        for capture in captures {
            let view = SelectionView(frame: NSRect(origin: .zero, size: capture.screen.frame.size), image: capture.image)
            view.onFinish = { [weak self] shot in self?.finish(shot) }

            let window = OverlayWindow(contentRect: capture.screen.frame, styleMask: .borderless,
                                       backing: .buffered, defer: false)
            window.setFrame(capture.screen.frame, display: false)
            window.level = .screenSaver
            window.isOpaque = true
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            // The default open/close zoom would make the frozen screen visibly jump.
            window.animationBehavior = .none
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.contentView = view
            windows.append(window)
        }
    }

    func begin() {
        let mouseScreen = NSScreen.underMouse
        for window in windows {
            window.orderFrontRegardless()
        }
        // Activate only once the frozen image covers the screen, so the previous app's
        // deactivation isn't visible. Activation is still needed to own the cursor.
        NSApp.activate()
        let key = windows.first { $0.screen == mouseScreen } ?? windows.first
        key?.makeKey()
        key?.makeFirstResponder(key?.contentView)
    }

    /// Dismisses the overlay as if the user pressed Esc.
    func cancel() {
        finish(nil)
    }

    private func finish(_ shot: Screenshot?) {
        guard let completion else { return }
        self.completion = nil
        windows.forEach { $0.orderOut(nil) }
        windows = []
        completion(shot)
    }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class SelectionView: NSView {
    var onFinish: ((Screenshot?) -> Void)?

    private let image: CGImage
    private let nsImage: NSImage
    private var start: CGPoint?
    private var current: CGPoint?
    private var mouse: CGPoint?

    private var scale: CGFloat { CGFloat(image.width) / bounds.width }

    init(frame: NSRect, image: CGImage) {
        self.image = image
        self.nsImage = NSImage(cgImage: image, size: frame.size)
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: CaptureGlyph.selectionCursor)
    }

    private var selection: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(start.x - current.x), height: abs(start.y - current.y))
            .intersection(bounds)
    }

    override func draw(_ dirtyRect: NSRect) {
        nsImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)

        if let selection, selection.width > 0, selection.height > 0 {
            let dim = NSBezierPath(rect: bounds)
            dim.append(NSBezierPath(rect: selection))
            dim.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.4).setFill()
            dim.fill()

            let border = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1
            NSColor.white.setStroke()
            border.stroke()

            drawSizeLabel(for: selection)
        } else {
            NSColor.black.withAlphaComponent(0.15).setFill()
            bounds.fill(using: .sourceOver)
            if let mouse { drawCrosshair(at: mouse) }
        }
    }

    private func drawCrosshair(at point: CGPoint) {
        let path = NSBezierPath()
        let x = point.x.rounded() + 0.5
        let y = point.y.rounded() + 0.5
        let gap: CGFloat = 16
        path.move(to: CGPoint(x: bounds.minX, y: y))
        path.line(to: CGPoint(x: max(bounds.minX, x - gap), y: y))
        path.move(to: CGPoint(x: min(bounds.maxX, x + gap), y: y))
        path.line(to: CGPoint(x: bounds.maxX, y: y))
        path.move(to: CGPoint(x: x, y: bounds.minY))
        path.line(to: CGPoint(x: x, y: max(bounds.minY, y - gap)))
        path.move(to: CGPoint(x: x, y: min(bounds.maxY, y + gap)))
        path.line(to: CGPoint(x: x, y: bounds.maxY))
        path.lineWidth = 1
        NSColor.white.withAlphaComponent(0.5).setStroke()
        path.stroke()
    }

    private func drawSizeLabel(for rect: CGRect) {
        let text = "\(Int((rect.width * scale).rounded())) × \(Int((rect.height * scale).rounded()))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        let padding = CGSize(width: 6, height: 3)
        var box = CGRect(x: rect.maxX - size.width - padding.width * 2, y: rect.maxY + 6,
                         width: size.width + padding.width * 2, height: size.height + padding.height * 2)
        if box.maxY > bounds.maxY { box.origin.y = rect.maxY - box.height - 6 }
        box.origin.x = max(bounds.minX + 4, box.origin.x)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        text.draw(at: CGPoint(x: box.minX + padding.width, y: box.minY + padding.height), withAttributes: attributes)
    }

    private func point(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseEntered(with event: NSEvent) {
        CaptureGlyph.selectionCursor.set()
        mouse = point(event)
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        CaptureGlyph.selectionCursor.set()
        mouse = point(event)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        mouse = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        CaptureGlyph.selectionCursor.set()
        start = point(event)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        CaptureGlyph.selectionCursor.set()
        current = point(event)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = point(event)
        guard let selection, selection.width >= 3 || selection.height >= 3 else {
            // A click (no real drag) captures the whole display.
            onFinish?(Screenshot(image: image, scale: scale))
            return
        }
        guard selection.width >= 3, selection.height >= 3 else {
            onFinish?(nil)
            return
        }
        var pixelRect = CGRect(x: selection.minX * scale, y: selection.minY * scale,
                               width: selection.width * scale, height: selection.height * scale).integral
        if event.modifierFlags.contains(.option) {
            pixelRect = trimmedToContent(pixelRect)
        }
        guard let cropped = image.cropping(to: pixelRect) else {
            onFinish?(nil)
            return
        }
        onFinish?(Screenshot(image: cropped, scale: scale))
    }

    /// Shrinks a pixel rect past uniform margins (e.g. window background around a
    /// dialog), so a rough selection snaps to the content inside it.
    private func trimmedToContent(_ pixelRect: CGRect) -> CGRect {
        guard let cropped = image.cropping(to: pixelRect),
              let content = PixelBuffer(cropped)?.contentBounds()
        else { return pixelRect }
        return content.offsetBy(dx: pixelRect.minX, dy: pixelRect.minY)
    }

    override func rightMouseDown(with event: NSEvent) {
        onFinish?(nil)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onFinish?(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}
