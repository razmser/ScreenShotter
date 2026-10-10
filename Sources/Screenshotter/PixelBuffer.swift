import CoreGraphics

/// An 8-bit RGBA (premultiplied) copy of an image for per-pixel work.
/// Row 0 is the top of the image.
nonisolated struct PixelBuffer {
    let width: Int
    let height: Int
    let colorSpace: CGColorSpace
    var data: [UInt8]

    init(width: Int, height: Int, colorSpace: CGColorSpace) {
        self.width = width
        self.height = height
        self.colorSpace = colorSpace
        data = [UInt8](repeating: 0, count: width * height * 4)
    }

    init?(_ image: CGImage) {
        let space = image.colorSpace.flatMap { $0.supportsOutput ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        self.init(width: image.width, height: image.height, colorSpace: space)
        let (width, height) = (width, height)
        let drawn = data.withUnsafeMutableBytes { raw -> Bool in
            guard let context = Self.context(raw.baseAddress, width, height, space) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
    }

    private static func context(_ data: UnsafeMutableRawPointer?, _ width: Int, _ height: Int,
                                _ space: CGColorSpace) -> CGContext? {
        CGContext(data: data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    mutating func makeImage() -> CGImage? {
        let (width, height, colorSpace) = (width, height, colorSpace)
        return data.withUnsafeMutableBytes { raw in
            Self.context(raw.baseAddress, width, height, colorSpace)?.makeImage()
        }
    }

    /// Byte offset of the pixel at (x, y).
    func offset(_ x: Int, _ y: Int) -> Int { (y * width + x) * 4 }

    /// Sum of absolute RGB differences between two pixels (alpha ignored), 0…765.
    func distance(_ a: Int, _ b: Int) -> Int {
        abs(Int(data[a]) - Int(data[b])) + abs(Int(data[a + 1]) - Int(data[b + 1]))
            + abs(Int(data[a + 2]) - Int(data[b + 2]))
    }

    /// Number of leading lines (columns if `columns`, else rows) from `start`,
    /// moving by `step`, that share the colour of the first line's first pixel.
    /// The first line may differ by up to 40 per pixel, later lines by up to 20.
    func uniformLines(columns: Bool, start: Int, step: Int) -> Int {
        let lineCount = columns ? width : height
        let lineLength = columns ? height : width
        let reference = columns ? offset(start, 0) : offset(0, start)
        var line = start
        var count = 0
        while line >= 0 && line < lineCount {
            let tolerance = count == 0 ? 40 : 20
            for i in 0..<lineLength {
                let pixel = columns ? offset(line, i) : offset(i, line)
                if distance(pixel, reference) > tolerance { return count }
            }
            count += 1
            line += step
        }
        return count
    }

    /// The bounds left after trimming uniform margins from each side, in pixels
    /// with a top-left origin, or nil if nothing would be left.
    func contentBounds() -> CGRect? {
        let left = uniformLines(columns: true, start: 0, step: 1)
        let right = uniformLines(columns: true, start: width - 1, step: -1)
        let top = uniformLines(columns: false, start: 0, step: 1)
        let bottom = uniformLines(columns: false, start: height - 1, step: -1)
        guard left + right < width, top + bottom < height else { return nil }
        return CGRect(x: left, y: top, width: width - left - right, height: height - top - bottom)
    }
}
