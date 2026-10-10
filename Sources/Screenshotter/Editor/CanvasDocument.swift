import AppKit

/// The screenshot being edited: its annotations and crop, with undo history and
/// rendering. Coordinates are image points relative to the uncropped image.
final class CanvasDocument {
    struct State {
        var annotations: [Annotation] = []
        var crop: CGRect
    }

    let fullRect: CGRect
    private let base: CGImage
    private let scale: CGFloat
    private let baseImage: NSImage

    private var state: State
    var annotations: [Annotation] { state.annotations }
    var crop: CGRect { state.crop }
    /// Bumped on every edit, undo and redo, so callers can tell whether the image
    /// changed since they last exported it.
    private(set) var changeCount = 0
    private var undoStack: [State] = []
    private var redoStack: [State] = []

    /// Called after every edit, undo and redo.
    var onChange: ((_ cropChanged: Bool) -> Void)?

    init(screenshot: Screenshot) {
        base = screenshot.image
        scale = screenshot.scale
        fullRect = CGRect(origin: .zero, size: screenshot.pointSize)
        baseImage = NSImage(cgImage: screenshot.image, size: screenshot.pointSize)
        state = State(crop: fullRect)
    }

    // MARK: Undo

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Makes an undoable change.
    func apply(_ change: (inout State) -> Void) {
        undoStack.append(state)
        redoStack.removeAll()
        update(to: state, with: change)
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(state)
        update(to: previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        update(to: next)
    }

    private func update(to newState: State, with change: (inout State) -> Void = { _ in }) {
        let oldCrop = crop
        state = newState
        change(&state)
        changeCount += 1
        onChange?(crop != oldCrop)
    }

    // MARK: Rendering

    /// Draws the screenshot and `annotations` (by default the document's own) into
    /// the current flipped graphics context, leaving out the one at `skipping`.
    func draw(_ annotations: [Annotation]? = nil, skipping: Int? = nil) {
        baseImage.draw(in: fullRect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        for (index, annotation) in (annotations ?? self.annotations).enumerated() where index != skipping {
            annotation.draw()
        }
    }

    /// Flattens annotations and crop into a full-resolution image.
    func renderScreenshot() -> Screenshot {
        if annotations.isEmpty && crop == fullRect {
            return Screenshot(image: base, scale: scale)
        }
        return Screenshot(image: render(crop) ?? base, scale: scale)
    }

    /// The screenshot with `annotations` within `rect`, at full resolution.
    private func render(_ rect: CGRect, annotations: [Annotation]? = nil) -> CGImage? {
        let width = Int((rect.width * scale).rounded())
        let height = Int((rect.height * scale).rounded())
        let colorSpace = base.colorSpace.flatMap { $0.supportsOutput ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        context.interpolationQuality = .high
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -rect.minX, y: -rect.minY)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw(annotations)
        NSGraphicsContext.restoreGraphicsState()

        return context.makeImage()
    }

    /// Pixelates `rect` as it looks within the crop, drawn with the annotations
    /// below `index` (all of them by default).
    func pixelate(_ rect: CGRect, below index: Int? = nil) -> Annotation? {
        let rect = rect.intersection(crop)
        guard rect.width > 2, rect.height > 2,
              let visible = render(crop, annotations: index.map { Array(annotations.prefix($0)) }),
              var annotation = Annotation.pixelate(rect.offsetBy(dx: -crop.minX, dy: -crop.minY),
                                                   of: visible, scale: scale),
              case let .patch(local, image) = annotation.shape else { return nil }
        annotation.shape = .patch(local.offsetBy(dx: crop.minX, dy: crop.minY), image)
        return annotation
    }
}
