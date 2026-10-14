import CoreGraphics
import Foundation
import libwebp

/// Lossless WebP encoding via libwebp (ImageIO can only decode WebP).
nonisolated enum WebP {
    static func encode(_ image: CGImage, scale: CGFloat) -> Data? {
        guard var pixels = PixelBuffer(image), let bitstream = encodeLossless(&pixels) else { return nil }
        return assemble(bitstream, icc: pixels.colorSpace.copyICCData() as Data?, dpi: 72 * scale)
    }

    private static func encodeLossless(_ pixels: inout PixelBuffer) -> Data? {
        // The fastest preset: ~15x quicker than the default, and still about half PNG's size.
        var config = WebPConfig()
        guard WebPConfigInit(&config) != 0, WebPConfigLosslessPreset(&config, 0) != 0 else { return nil }
        var picture = WebPPicture()
        guard WebPPictureInit(&picture) != 0 else { return nil }
        defer { WebPPictureFree(&picture) }
        picture.use_argb = 1
        picture.width = Int32(pixels.width)
        picture.height = Int32(pixels.height)

        // libwebp takes straight alpha; PixelBuffer is premultiplied.
        for i in stride(from: 0, to: pixels.data.count, by: 4) {
            let alpha = Int(pixels.data[i + 3])
            guard alpha > 0, alpha < 255 else { continue }
            for c in i..<i + 3 {
                pixels.data[c] = UInt8(min(255, (Int(pixels.data[c]) * 255 + alpha / 2) / alpha))
            }
        }
        let stride = Int32(pixels.width * 4)
        guard pixels.data.withUnsafeBufferPointer({ WebPPictureImportRGBA(&picture, $0.baseAddress, stride) }) != 0
        else { return nil }

        var writer = WebPMemoryWriter()
        WebPMemoryWriterInit(&writer)
        defer { WebPMemoryWriterClear(&writer) }
        picture.writer = WebPMemoryWrite
        let encoded = withUnsafeMutablePointer(to: &writer) { writerPointer in
            picture.custom_ptr = UnsafeMutableRawPointer(writerPointer)
            return WebPEncode(&config, &picture) != 0
        }
        guard encoded, let mem = writer.mem else { return nil }
        return Data(bytes: mem, count: writer.size)
    }

    /// Wraps the bitstream with the color profile and an EXIF resolution, so a Retina
    /// screenshot keeps its colors and opens at its logical size, like the PNG does.
    private static func assemble(_ bitstream: Data, icc: Data?, dpi: CGFloat) -> Data? {
        guard let mux = WebPMuxNew() else { return nil }
        defer { WebPMuxDelete(mux) }
        func set(_ data: Data, _ apply: (UnsafePointer<WebPData>) -> WebPMuxError) -> Bool {
            data.withUnsafeBytes { raw in
                var chunk = WebPData(bytes: raw.bindMemory(to: UInt8.self).baseAddress, size: raw.count)
                return apply(&chunk) == WEBP_MUX_OK
            }
        }
        guard set(bitstream, { WebPMuxSetImage(mux, $0, 1) }) else { return nil }
        if let icc, !set(icc, { WebPMuxSetChunk(mux, "ICCP", $0, 1) }) { return nil }
        guard set(exifResolution(dpi), { WebPMuxSetChunk(mux, "EXIF", $0, 1) }) else { return nil }

        var output = WebPData()
        guard WebPMuxAssemble(mux, &output) == WEBP_MUX_OK, let bytes = output.bytes else { return nil }
        defer { WebPDataClear(&output) }
        return Data(bytes: bytes, count: output.size)
    }

    /// A big-endian TIFF header with one IFD holding X/YResolution and ResolutionUnit (inches).
    private static func exifResolution(_ dpi: CGFloat) -> Data {
        var data = Data()
        func u16(_ value: UInt16) { data.append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xFF)]) }
        func u32(_ value: UInt32) { u16(UInt16(value >> 16)); u16(UInt16(value & 0xFFFF)) }
        let entries: UInt32 = 3
        let rationalOffset = 8 + 2 + entries * 12 + 4
        data.append(contentsOf: Array("MM".utf8)); u16(42); u32(8)
        u16(UInt16(entries))
        u16(0x011A); u16(5); u32(1); u32(rationalOffset)      // XResolution, RATIONAL
        u16(0x011B); u16(5); u32(1); u32(rationalOffset + 8)  // YResolution, RATIONAL
        u16(0x0128); u16(3); u32(1); u16(2); u16(0)           // ResolutionUnit, SHORT = inch
        u32(0)                                                 // no next IFD
        let numerator = UInt32((dpi * 100).rounded())
        for _ in 0..<2 { u32(numerator); u32(100) }
        return data
    }
}
