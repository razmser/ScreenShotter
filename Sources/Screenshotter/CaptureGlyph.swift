import AppKit

/// Shared geometry for the app icon, menu-bar icon, and area-selection pointer.
enum CaptureGlyph {
    static func drawCrosshair(at center: CGPoint, radius: CGFloat, color: NSColor,
                              outline: Bool = false, smallSize: Bool = false) {
        let arms = NSBezierPath()
        arms.lineCapStyle = .butt
        for direction in [CGPoint(x: -1, y: 0), CGPoint(x: 1, y: 0),
                          CGPoint(x: 0, y: -1), CGPoint(x: 0, y: 1)] {
            arms.move(to: CGPoint(x: center.x + direction.x * radius * 0.42,
                                 y: center.y + direction.y * radius * 0.42))
            arms.line(to: CGPoint(x: center.x + direction.x * radius,
                                 y: center.y + direction.y * radius))
        }
        let width = max(0.8, radius * (smallSize ? 0.28 : 0.14))
        let dotRadius = max(0.45, radius * (smallSize ? 0.18 : 0.10))
        let dot = NSBezierPath(ovalIn: CGRect(x: center.x - dotRadius, y: center.y - dotRadius,
                                            width: dotRadius * 2, height: dotRadius * 2))
        if outline {
            NSColor.white.setStroke()
            arms.lineCapStyle = .square
            arms.lineWidth = width + 2
            arms.stroke()
            dot.lineWidth = 2
            dot.stroke()
        }
        color.setStroke()
        color.setFill()
        arms.lineCapStyle = .butt
        arms.lineWidth = width
        arms.stroke()
        dot.fill()
    }

    /// Draw in a 100 × 100 coordinate space, with the cross at the screen's center.
    static func drawMonitor(in rect: CGRect, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scaleX(by: rect.width / 100, yBy: rect.height / 100)
        transform.concat()

        color.setStroke()
        let monitor = NSBezierPath(rect: CGRect(x: 10, y: 32, width: 80, height: 50))
        let smallSize = rect.width < 32
        monitor.lineWidth = smallSize ? 6 : 4
        monitor.lineJoinStyle = .miter
        monitor.stroke()
        let stand = NSBezierPath()
        stand.lineWidth = monitor.lineWidth
        stand.move(to: CGPoint(x: 50, y: 32))
        stand.line(to: CGPoint(x: 50, y: 18))
        stand.move(to: CGPoint(x: 34, y: 18))
        stand.line(to: CGPoint(x: 66, y: 18))
        stand.stroke()
        drawCrosshair(at: CGPoint(x: 50, y: 57), radius: 16, color: color, smallSize: smallSize)
    }

    static let selectionCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { _ in
            drawCrosshair(at: CGPoint(x: 16, y: 16), radius: 12, color: .black, outline: true)
            return true
        }
        image.accessibilityDescription = "Area selection crosshair"
        return NSCursor(image: image, hotSpot: NSPoint(x: 16, y: 16))
    }()
}
