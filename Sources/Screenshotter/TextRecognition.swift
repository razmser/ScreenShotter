import CoreImage
import Vision

/// Extracts text from a screenshot: QR code contents if there are any, otherwise OCR.
enum TextRecognition {
    @concurrent
    static func recognize(_ image: CGImage) async throws -> String {
        if let codes = qrCodes(in: image) { return codes }
        return try ocr(image)
    }

    private nonisolated static func qrCodes(in image: CGImage) -> String? {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let messages = (detector?.features(in: CIImage(cgImage: image)) ?? [])
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    private nonisolated static func ocr(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
