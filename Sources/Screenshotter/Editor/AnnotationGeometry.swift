import AppKit

extension Annotation {
    var tool: Tool {
        switch shape {
        case .arrow: .arrow
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .pen: .pen
        case .highlight: .highlight
        case .text: .text
        case .patch: .pixelate
        }
    }

    var bounds: CGRect {
        switch shape {
        case let .arrow(a, b):
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        case let .rectangle(r), let .ellipse(r), let .patch(r, _): return r
        case let .text(string, origin, size):
            return CGRect(origin: origin, size: (string as NSString).size(withAttributes: [.font: Self.font(size: size)]))
        case let .highlight(points):
            guard !points.isEmpty else { return .zero }
            let nib = MarkerStroke.nibSize(height: lineWidth)
            return Annotation(shape: .pen(points), color: color, lineWidth: 0).bounds
                .insetBy(dx: -nib.width / 2, dy: -nib.height / 2)
        case let .pen(points):
            guard let first = points.first else { return .zero }
            return points.reduce(CGRect(origin: first, size: .zero)) { r, p in
                CGRect(x: min(r.minX, p.x), y: min(r.minY, p.y),
                       width: max(r.maxX, p.x) - min(r.minX, p.x),
                       height: max(r.maxY, p.y) - min(r.minY, p.y))
            }
        }
    }

    var handles: [CGPoint] {
        if case let .arrow(a, b) = shape { return [a, b] }
        let r = bounds
        return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        let reach = tolerance + lineWidth / 2
        switch shape {
        case let .arrow(a, b): return Self.distance(point, to: a, b) <= max(reach, lineWidth * 2)
        case let .pen(points):
            return zip(points, points.dropFirst()).contains { Self.distance(point, to: $0.0, $0.1) <= reach }
        case let .highlight(points):
            guard bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return false }
            let path = MarkerStroke.path(points: points, height: lineWidth)
            return path.contains(point) || path.copy(strokingWithWidth: tolerance * 2, lineCap: .round,
                                                     lineJoin: .round, miterLimit: 1).contains(point)
        case let .rectangle(r):
            return r.insetBy(dx: -reach, dy: -reach).contains(point)
                && !r.insetBy(dx: reach, dy: reach).contains(point)
        case let .ellipse(r):
            return CGPath(ellipseIn: r, transform: nil)
                .copy(strokingWithWidth: reach * 2, lineCap: .round, lineJoin: .round, miterLimit: 1)
                .contains(point)
        default: return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    private static func distance(_ p: CGPoint, to a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let squared = dx * dx + dy * dy
        let t = squared > 0 ? min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / squared)) : 0
        return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
    }

    func translated(dx: CGFloat, dy: CGFloat) -> Annotation {
        transformed(to: bounds.offsetBy(dx: dx, dy: dy))
    }

    func resized(handle: Int, to point: CGPoint) -> Annotation {
        if case let .arrow(a, b) = shape {
            var result = self
            result.shape = .arrow(from: handle == 0 ? point : a, to: handle == 1 ? point : b)
            return result
        }
        let anchor = handles[(handle + 2) % 4]
        var point = point
        switch shape {
        case .highlight, .text:
            // Scale uniformly, since a marker's nib and a label's font keep their proportions.
            var scale = max(0.1, max(abs(point.x - anchor.x) / bounds.width,
                                     abs(point.y - anchor.y) / bounds.height))
            if case let .text(_, _, size) = shape { scale = max(8, min(300, size * scale)) / size }
            let corner = handles[handle]
            point = CGPoint(x: anchor.x + (corner.x - anchor.x) * scale,
                            y: anchor.y + (corner.y - anchor.y) * scale)
        case .pen:
            // Keep the dragged corner on its side of the anchor, so the opposite end stays put.
            let corner = handles[handle]
            func clamp(_ value: CGFloat, _ corner: CGFloat, _ anchor: CGFloat) -> CGFloat {
                corner > anchor ? max(value, anchor + 2) : corner < anchor ? min(value, anchor - 2) : anchor
            }
            point = CGPoint(x: clamp(point.x, corner.x, anchor.x), y: clamp(point.y, corner.y, anchor.y))
        default:
            break
        }
        let r = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                       width: max(2, abs(point.x - anchor.x)), height: max(2, abs(point.y - anchor.y)))
        return transformed(to: r)
    }

    private func transformed(to rect: CGRect) -> Annotation {
        let old = bounds
        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + (p.x - old.minX) * (old.width > 0 ? rect.width / old.width : 1),
                    y: rect.minY + (p.y - old.minY) * (old.height > 0 ? rect.height / old.height : 1))
        }
        var result = self
        switch shape {
        case let .arrow(a, b): result.shape = .arrow(from: point(a), to: point(b))
        case .rectangle: result.shape = .rectangle(rect)
        case .ellipse: result.shape = .ellipse(rect)
        case let .highlight(points):
            result.shape = .highlight(points.map(point))
            result.lineWidth *= old.height > 0 ? rect.height / old.height : 1
        case let .pen(points): result.shape = .pen(points.map(point))
        case let .text(string, origin, size):
            let ratio = old.height > 0 ? rect.height / old.height : 1
            result.shape = .text(string, origin: point(origin), fontSize: max(8, min(300, size * ratio)))
        case let .patch(_, image): result.shape = .patch(rect, image)
        }
        return result
    }
}
