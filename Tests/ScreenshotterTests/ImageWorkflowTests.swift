import AppKit
import CoreImage
import XCTest
@testable import Screenshotter

@MainActor
final class ImageWorkflowTests: XCTestCase {
    private func fixture(width: Int = 80, height: Int = 60) -> CGImage {
        var buffer = PixelBuffer(width: width, height: height,
                                 colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        for y in 0..<height {
            for x in 0..<width {
                let offset = buffer.offset(x, y)
                let inside = (20..<50).contains(x) && (10..<40).contains(y)
                buffer.data.replaceSubrange(offset..<offset + 4,
                                           with: inside ? [255, 0, 0, 255] : [255, 255, 255, 255])
            }
        }
        return buffer.makeImage()!
    }

    func testImageRoundTripPreservesOrientationAndTrimBounds() throws {
        let buffer = try XCTUnwrap(PixelBuffer(fixture()))
        XCTAssertEqual(buffer.contentBounds(), CGRect(x: 20, y: 10, width: 30, height: 30))
        XCTAssertEqual(Array(buffer.data[buffer.offset(25, 15)..<buffer.offset(25, 15) + 4]), [255, 0, 0, 255])
    }

    func testUniformImageDoesNotTrimToEmpty() {
        var buffer = PixelBuffer(width: 10, height: 10,
                                 colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        buffer.data = Array(repeating: 255, count: 400)
        XCTAssertNil(buffer.contentBounds())
    }

    func testCanvasPreviewDoesNotDrawOutsideItsBounds() throws {
        let canvas = CanvasView(screenshot: Screenshot(image: fixture(), scale: 1))
        canvas.setFrameSize(CGSize(width: 30, height: 20))
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 60,
                                            bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: 60)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        canvas.draw(canvas.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let pixels = try XCTUnwrap(PixelBuffer(try XCTUnwrap(context.makeImage())))
        XCTAssertEqual(pixels.data[pixels.offset(5, 5) + 3], 255)
        XCTAssertEqual(pixels.data[pixels.offset(40, 5) + 3], 0, "Preview spills past the right crop edge")
        XCTAssertEqual(pixels.data[pixels.offset(5, 30) + 3], 0, "Preview spills past the bottom crop edge")
    }

    func testRetinaPNGAndJPEGExportPreserveDimensionsAndDPI() throws {
        let shot = Screenshot(image: fixture(), scale: 2)
        for format in [ImageFormat.png, .jpeg] {
            let data = try XCTUnwrap(Output.encode(shot, as: format))
            let decoded = try XCTUnwrap(NSBitmapImageRep(data: data))
            XCTAssertEqual(decoded.pixelsWide, 80)
            XCTAssertEqual(decoded.pixelsHigh, 60)
            XCTAssertEqual(decoded.size.width, 40, accuracy: 0.1)
            XCTAssertEqual(decoded.size.height, 30, accuracy: 0.1)
        }
    }

    func testConcealClipsToImageAtRetinaScale() throws {
        let image = fixture()
        let annotation = Annotation.pixelate(CGRect(x: -5, y: -5, width: 20, height: 20), of: image, scale: 2)
        guard case let .patch(rect, patch) = try XCTUnwrap(annotation).shape else { return XCTFail("Expected patch") }
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 15, height: 15))
        let cgImage = try XCTUnwrap(patch.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(cgImage.width, 30)
        XCTAssertEqual(cgImage.height, 30)
    }

    func testConcealOutsideImageIsIgnored() {
        let outside = CGRect(x: 100, y: 100, width: 20, height: 20)
        XCTAssertNil(Annotation.pixelate(outside, of: fixture(), scale: 1))
    }

    func testSavedImageHasScreenCaptureMetadata() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try Output.write(Screenshot(image: fixture(), scale: 2), to: url, format: .png)
        let name = "com.apple.metadata:kMDItemIsScreenCapture"
        let count = getxattr(url.path, name, nil, 0, 0, 0)
        XCTAssertGreaterThan(count, 0)
        guard count > 0 else { return }
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, count, 0, 0) }
        XCTAssertEqual(try PropertyListSerialization.propertyList(from: data, format: nil) as? Bool, true)
    }

    func testQRCodeContentsAreRecognized() async throws {
        let generator = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        generator.setValue(Data("Screenshotter QA 12345".utf8), forKey: "inputMessage")
        let code = try XCTUnwrap(generator.outputImage).transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let image = try XCTUnwrap(CIContext().createCGImage(code, from: code.extent))
        let recognized = try await TextRecognition.recognize(image)
        XCTAssertEqual(recognized, "Screenshotter QA 12345")
    }

    func testOCRRecognizesRenderedText() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 120,
                                            bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 120))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        ("Screenshot quality check 12345" as NSString).draw(at: CGPoint(x: 20, y: 40), withAttributes: [
            .font: NSFont.systemFont(ofSize: 36), .foregroundColor: NSColor.black,
        ])
        NSGraphicsContext.restoreGraphicsState()
        let recognized = try await TextRecognition.recognize(try XCTUnwrap(context.makeImage()))
        XCTAssertEqual(recognized, "Screenshot quality check 12345")
    }
}
