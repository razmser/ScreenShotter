import AppKit

/// A small, template-rendered version of the app icon’s monitor and dotted crosshair.
enum StatusIcon {
    /// `badged` adds a dot in the lower-right corner to flag a problem.
    static func makeImage(badged: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            CaptureGlyph.drawMonitor(in: NSRect(x: 0, y: 0, width: 18, height: 18), color: .black)
            NSColor.black.setFill()

            if badged {
                // Cut a gap around the dot so it reads separately from the monitor.
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: NSRect(x: 12, y: -1, width: 7, height: 7)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSBezierPath(ovalIn: NSRect(x: 13.5, y: 0.5, width: 4, height: 4)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = badged ? "ScreenShotter, some shortcuts unavailable" : "ScreenShotter"
        return image
    }
}
