import AppKit
import CoreImage
import CoreText
import Vision

/// Extracts text from a screenshot: QR code contents if there are any, otherwise OCR.
///
/// Vision compiles its OCR model into our caches folder on first use, which takes about half a minute,
/// and macOS may purge it at any time. A process that had loaded the model then fails every OCR, but
/// picks the model up again once a fresh process recompiles it, so a helper run of this executable does that.
enum TextRecognition {
    /// Launching with this argument compiles the model and exits instead (see `main.swift`).
    static let compileArgument = "--compile-text-model"

    private static var compiling: Task<Void, Never>?
    private static var helperExited = Date.distantPast

    /// `onCompile` runs before waiting for the model to be compiled, which takes about half a minute.
    @concurrent
    static func recognize(_ image: CGImage, onCompile: @MainActor () -> Void = {}) async throws -> String {
        if let codes = qrCodes(in: image) { return codes }
        // Wait for the helper rather than compile the same model again in this process.
        if let compile = await compiling {
            await onCompile()
            await compile.value
        }
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

    /// Compiles a missing or purged model in the helper at launch and right after a purge, so captures
    /// needn't wait for it. When the model is already compiled the helper takes well under a second,
    /// and this process doesn't load the model until the first capture.
    static func keepModelReady() {
        Task { await compileInHelper() }
        watchForPurges()
    }

    /// Recompiles once files disappear from our caches folder, which is what a purge looks like.
    /// A compile deletes temporary files there too, so removals reported during a helper run or just after
    /// it are ignored. That also keeps a failing compile from retrying forever: the next capture compiles
    /// the model, in this process if it hasn't loaded it yet.
    private static func watchForPurges() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let caches = URL.cachesDirectory.appending(path: id)
        let callback: FSEventStreamCallback = { _, _, count, _, flags, _ in
            let purge = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagMustScanSubDirs)
            guard (0..<count).contains(where: { flags[$0] & purge != 0 }),
                  TextRecognition.compiling == nil,
                  Date.now.timeIntervalSince(TextRecognition.helperExited) > 10
            else { return }
            Task { await TextRecognition.compileInHelper() }
        }
        guard let stream = FSEventStreamCreate(nil, callback, nil, [caches.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 5,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents))
        else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
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
        helperExited = .now
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
