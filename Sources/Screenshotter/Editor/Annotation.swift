import AppKit

enum Tool: Int, CaseIterable {
    case select, arrow, rectangle, ellipse, pen, highlight, text, pixelate, crop

    var title: String {
        switch self {
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .pen: "Pen"
        case .highlight: "Highlight"
        case .text: "Text"
        case .pixelate: "Pixelate"
        case .select: "Select"
        case .crop: "Crop"
        }
    }

    var symbolName: String {
        switch self {
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .pen: "scribble"
        case .highlight: "highlighter"
        case .text: "textformat"
        case .pixelate: "checkerboard.rectangle"
        case .select: "cursorarrow"
        case .crop: "crop"
        }
    }

    /// Single-key shortcut used while the canvas has focus.
    var key: Character {
        switch self {
        case .arrow: "a"
        case .rectangle: "r"
        case .ellipse: "o"
        case .pen: "p"
        case .highlight: "h"
        case .text: "t"
        case .pixelate: "b"
        case .select: "v"
        case .crop: "c"
        }
    }
}

/// A single mark on the screenshot. Coordinates are in image points, top-left origin.
struct Annotation {
    enum Shape {
        case arrow(from: CGPoint, to: CGPoint)
        case rectangle(CGRect)
        case ellipse(CGRect)
        case pen([CGPoint])
        case highlight([CGPoint])
        case text(String, origin: CGPoint, fontSize: CGFloat)
        /// A pre-rendered image covering `rect` (pixelate).
        case patch(CGRect, NSImage)
    }

    var shape: Shape
    var color: NSColor
    var lineWidth: CGFloat

    static func font(size: CGFloat) -> NSFont {
        .systemFont(ofSize: size, weight: .semibold)
    }

    /// Whether the shape is big enough to keep (filters out accidental clicks).
    var isMeaningful: Bool {
        switch shape {
        case let .arrow(from, to): hypot(to.x - from.x, to.y - from.y) > 4
        case let .rectangle(r), let .ellipse(r): r.width > 2 && r.height > 2
        case let .pen(points): points.count > 1
        case let .highlight(points): !points.isEmpty
        case let .text(string, _, _): !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .patch: true
        }
    }

    /// Draws into the current (flipped) graphics context.
    func draw() {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        switch shape {
        case .highlight, .patch:
            break
        default:
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
        }

        switch shape {
        case let .arrow(from, to):
            drawArrow(from: from, to: to)

        case let .rectangle(rect):
            let path = NSBezierPath(roundedRect: rect, xRadius: lineWidth, yRadius: lineWidth)
            path.lineWidth = lineWidth
            color.setStroke()
            path.stroke()

        case let .ellipse(rect):
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = lineWidth
            color.setStroke()
            path.stroke()

        case let .pen(points):
            guard let first = points.first else { return }
            let path = NSBezierPath()
            path.move(to: first)
            points.dropFirst().forEach(path.line(to:))
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            color.setStroke()
            path.stroke()

        case let .highlight(points):
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.setBlendMode(.multiply)
            context.setFillColor(color.withAlphaComponent(0.45).cgColor)
            context.addPath(MarkerStroke.path(points: points, height: lineWidth))
            context.fillPath()

        case let .text(string, origin, fontSize):
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Self.font(size: fontSize),
                .foregroundColor: color,
            ]
            (string as NSString).draw(at: origin, withAttributes: attributes)

        case let .patch(rect, image):
            image.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true,
                       hints: [.interpolation: NSImageInterpolation.none.rawValue])
        }
    }

    private func drawArrow(from start: CGPoint, to end: CGPoint) {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return }
        let ux = dx / length, uy = dy / length
        let headLength = min(max(lineWidth * 4, 14), length)
        let halfWidth = headLength * 0.5
        let base = CGPoint(x: end.x - ux * headLength, y: end.y - uy * headLength)

        let shaft = NSBezierPath()
        shaft.move(to: start)
        shaft.line(to: CGPoint(x: base.x + ux * 1, y: base.y + uy * 1))
        shaft.lineWidth = lineWidth
        shaft.lineCapStyle = .round
        color.setStroke()
        shaft.stroke()

        let head = NSBezierPath()
        head.move(to: end)
        head.line(to: CGPoint(x: base.x - uy * halfWidth, y: base.y + ux * halfWidth))
        head.line(to: CGPoint(x: base.x + uy * halfWidth, y: base.y - ux * halfWidth))
        head.close()
        color.setFill()
        head.fill()
    }

    /// Pixelates `rect` (in points) of the base image: each block is filled with
    /// its average colour. When the blocks are few and large, most of them take a
    /// neighbouring block's colour so the content can't be reconstructed.
    static func pixelate(_ rect: CGRect, of image: CGImage, scale: CGFloat) -> Annotation? {
        guard let pixels = pixels(in: rect, of: image, scale: scale) else { return nil }
        let (pixelRect, source) = pixels
        let width = source.width, height = source.height
        // About three blocks across the short side, at most 9pt each.
        let block = max(2, Int(min(0.3 * Double(min(width, height)), 9 * scale).rounded()))
        let columns = (width + block - 1) / block
        let rows = (height + block - 1) / block

        var averages = [[UInt8]](repeating: [0, 0, 0, 0], count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                var sum = [0, 0, 0, 0]
                let ys = row * block..<min((row + 1) * block, height)
                let xs = column * block..<min((column + 1) * block, width)
                for y in ys {
                    for x in xs {
                        let o = source.offset(x, y)
                        for c in 0..<4 { sum[c] += Int(source.data[o + c]) }
                    }
                }
                let count = ys.count * xs.count
                averages[row * columns + column] = sum.map { UInt8($0 / count) }
            }
        }

        let scramble = min(width, height) / 7 < block
        var output = PixelBuffer(width: width, height: height, colorSpace: source.colorSpace)
        for row in 0..<rows {
            for column in 0..<columns {
                var (sourceRow, sourceColumn) = (row, column)
                if scramble {
                    switch Int.random(in: 0..<5) {
                    case 0: sourceRow = max(row - 1, 0)
                    case 1: sourceRow = min(row + 1, rows - 1)
                    case 2: sourceColumn = max(column - 1, 0)
                    case 3: sourceColumn = min(column + 1, columns - 1)
                    default: break
                    }
                }
                let color = averages[sourceRow * columns + sourceColumn]
                for y in row * block..<min((row + 1) * block, height) {
                    for x in column * block..<min((column + 1) * block, width) {
                        let o = output.offset(x, y)
                        for c in 0..<4 { output.data[o + c] = color[c] }
                    }
                }
            }
        }
        return patch(&output, at: pixelRect, scale: scale)
    }

    /// The pixels of `rect` (in points), clipped to the image.
    private static func pixels(in rect: CGRect, of image: CGImage, scale: CGFloat) -> (CGRect, PixelBuffer)? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let pixelRect = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                               width: rect.width * scale, height: rect.height * scale)
            .integral.intersection(bounds)
        guard !pixelRect.isEmpty, let cropped = image.cropping(to: pixelRect),
              let buffer = PixelBuffer(cropped)
        else { return nil }
        return (pixelRect, buffer)
    }

    private static func patch(_ buffer: inout PixelBuffer, at pixelRect: CGRect, scale: CGFloat) -> Annotation? {
        guard let image = buffer.makeImage() else { return nil }
        let pointRect = CGRect(x: pixelRect.minX / scale, y: pixelRect.minY / scale,
                               width: pixelRect.width / scale, height: pixelRect.height / scale)
        let nsImage = NSImage(cgImage: image, size: pointRect.size)
        return Annotation(shape: .patch(pointRect, nsImage), color: .clear, lineWidth: 0)
    }
}
