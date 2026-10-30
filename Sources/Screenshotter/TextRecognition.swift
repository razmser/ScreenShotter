import CoreImage
import CoreText
import Vision

/// Extracts text from a screenshot: QR code contents if there are any, otherwise OCR.
///
/// Vision compiles its OCR model into our caches folder, which macOS may purge while we run.
/// A process that had loaded the model then fails every OCR, but picks the model up again
/// once a fresh process recompiles it, so a helper run of this executable does that.
enum TextRecognition {
    /// Launching with this argument compiles the model and exits instead (see `main.swift`).
    static let compileArgument = "--compile-text-model"

    private static var compiling: Task<Void, Never>?
    private static var checks: NSBackgroundActivityScheduler?

    /// `onCompile` runs before waiting for the model to be recompiled, which takes about half a minute.
    @concurrent
    static func recognize(_ image: CGImage, onCompile: @MainActor () -> Void = {}) async throws -> String {
        if let codes = qrCodes(in: image) { return codes }
        await scheduleChecks()
        do {
            return try ocr(image)
        } catch {
            // If the model works, the image is the problem (e.g. too small) or a compile just finished.
            if !modelWorks() {
                await onCompile()
                await compileInHelper()
            }
            return try ocr(image)
        }
    }

    /// Recognizes sample text, which in a fresh process compiles the model. Also handles `compileArgument`.
    nonisolated static func modelWorks() -> Bool {
        guard let sample = sampleText() else { return false }
        return (try? ocr(sample)) != nil
    }

    /// Hourly while the Mac is awake, recompiles a purged model so the next capture needn't wait.
    /// Starts with the first OCR: until this process loads the model, a purge can't break it.
    private static func scheduleChecks() {
        guard checks == nil else { return }
        let scheduler = NSBackgroundActivityScheduler(identifier: "com.razmser.screenshotter.check-text-model")
        scheduler.interval = 60 * 60
        scheduler.repeats = true
        scheduler.qualityOfService = .utility
        scheduler.schedule { completion in
            guard !modelWorks() else { return completion(.finished) }
            Task {
                await compileInHelper()
                completion(.finished)
            }
        }
        checks = scheduler
    }

    /// Recompiles the model in a fresh process, or waits for the compile that's already running.
    private static func compileInHelper() async {
        if let compiling { return await compiling.value }
        let task = Task {
            await withCheckedContinuation { continuation in
                let process = Process()
                process.executableURL = Bundle.main.executableURL
                process.arguments = [compileArgument]
                process.terminationHandler = { _ in continuation.resume() }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume()
                    return
                }
                // Don't leave captures waiting on a stuck helper.
                DispatchQueue.global().asyncAfter(deadline: .now() + 180) {
                    if process.isRunning { process.terminate() }
                }
            }
        }
        compiling = task
        await task.value
        compiling = nil
    }

    /// A line of text: recognizing it compiles every model a capture uses.
    private nonisolated static func sampleText() -> CGImage? {
        guard let context = CGContext(data: nil, width: 800, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let font = CTFontCreateUIFontForLanguage(.system, 36, nil)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 120))
        let text = NSAttributedString(string: "Text recognition check 12345", attributes: [.font: font])
        context.textPosition = CGPoint(x: 20, y: 40)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        return context.makeImage()
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
