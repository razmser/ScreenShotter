import AppKit

/// Compile alongside CaptureGlyph.swift so shipped artwork uses the same geometry as the cursor.
@main
enum GenerateIcon {
    static func render(size: Int, to path: String, draw: () -> Void) throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                      bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))
        draw()
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }

    static func drawIcon(in rect: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scale(by: rect.width / 1024)
        transform.concat()
        // A quiet macOS tile, with transparent margins for Finder and the Dock.
        let tile = NSBezierPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                                xRadius: 180, yRadius: 180)
        NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
        tile.fill()
        NSColor(calibratedWhite: 0.85, alpha: 1).setStroke()
        tile.lineWidth = 2
        tile.stroke()
        CaptureGlyph.drawMonitor(in: CGRect(x: 176, y: 176, width: 672, height: 672),
                                 color: NSColor(calibratedWhite: 0.08, alpha: 1))
    }

    static func main() throws {
        try render(size: 1024, to: "Resources/AppIcon.png") {
            drawIcon(in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
        }
        try FileManager.default.createDirectory(atPath: "build", withIntermediateDirectories: true)
        try render(size: 800, to: "build/branding-preview.png") {
            NSColor(calibratedWhite: 0.91, alpha: 1).setFill()
            CGRect(x: 0, y: 0, width: 800, height: 800).fill()
            let title: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: NSColor.black,
            ]
            ("ScreenShotter" as NSString).draw(at: CGPoint(x: 295, y: 744), withAttributes: title)
            drawIcon(in: CGRect(x: 170, y: 255, width: 460, height: 460))
            let caption: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 17), .foregroundColor: NSColor.darkGray,
            ]
            ("Area-selection pointer · actual size + enlarged" as NSString)
                .draw(at: CGPoint(x: 215, y: 239), withAttributes: caption)
            for (x, background) in [(CGFloat(120), NSColor.white), (CGFloat(420), NSColor.black)] {
                background.setFill()
                NSBezierPath(roundedRect: CGRect(x: x, y: 65, width: 260, height: 145),
                             xRadius: 16, yRadius: 16).fill()
                CaptureGlyph.drawCrosshair(at: CGPoint(x: x + 65, y: 137), radius: 12,
                                           color: .black, outline: true)
                NSGraphicsContext.saveGraphicsState()
                let transform = NSAffineTransform()
                transform.translateX(by: x + 170, yBy: 137)
                transform.scale(by: 3)
                transform.concat()
                CaptureGlyph.drawCrosshair(at: .zero, radius: 12, color: .black, outline: true)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }
}
