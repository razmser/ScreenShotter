import AppKit

/// A vertical rounded marker nib swept along a freehand gesture.
/// All impressions belong to one filled path, so a stroke has uniform opacity
/// even where its samples or loops overlap.
enum MarkerStroke {
    static func nibSize(height: CGFloat) -> CGSize {
        CGSize(width: height * 0.45, height: height)
    }

    static func path(points: [CGPoint], height: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let size = nibSize(height: height)
        let radius = size.width / 2
        func stamp(_ point: CGPoint) {
            path.addRoundedRect(in: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                           width: size.width, height: size.height),
                                cornerWidth: radius, cornerHeight: radius)
        }
        guard let first = points.first else { return path }
        stamp(first)
        // Close spacing keeps the rounded edge smooth even for sparse mouse events.
        let spacing = max(0.5, size.width / 6)
        for (a, b) in zip(points, points.dropFirst()) {
            let steps = max(1, Int(ceil(hypot(b.x - a.x, b.y - a.y) / spacing)))
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                stamp(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        return path
    }

    static func cursor(height: CGFloat, zoom: CGFloat) -> NSCursor {
        let nib = nibSize(height: height * zoom)
        let size = CGSize(width: nib.width + 4, height: nib.height + 4)
        let image = NSImage(size: size, flipped: true) { _ in
            let outline = NSBezierPath(roundedRect: CGRect(x: 2, y: 2, width: nib.width, height: nib.height),
                                       xRadius: nib.width / 2, yRadius: nib.width / 2)
            NSColor.black.withAlphaComponent(0.65).setStroke()
            outline.lineWidth = 2.5
            outline.stroke()
            NSColor.white.withAlphaComponent(0.9).setStroke()
            outline.lineWidth = 1
            outline.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: size.width / 2, y: size.height / 2))
    }
}
