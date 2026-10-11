import AppKit
import ScreenCaptureKit

/// Records a display, or part of one, straight to an MP4 file.
@available(macOS 15, *)
final class ScreenRecorder: NSObject {
    let url: URL
    /// Called once when the file is finished, whether `stop()` or macOS (the menu bar's
    /// screen-sharing indicator) ended the recording.
    var onFinish: ((Result<URL, Error>) -> Void)?
    private var stream: SCStream?
    private var isStopping = false
    private var isFinished = false

    init(url: URL) {
        self.url = url
    }

    /// A picked window is recorded on its own, whatever covers it.
    func start(_ selection: AreaSelection, showsClicks: Bool) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let filter: SCContentFilter
        var source: CGRect?
        switch selection {
        case .area(let screen, let rect, _):
            guard let displayFilter = ScreenCapture.filter(for: screen, in: content) else {
                throw SCStreamError(.noDisplayList)
            }
            filter = displayFilter
            source = rect ?? CGRect(origin: .zero, size: displayFilter.contentRect.size)
        case .window(let windowID):
            // Through its display rather than a desktop-independent window filter, which draws
            // click highlights at the wrong place. The recorded area doesn't follow the window.
            guard let window = content.windows.first(where: { $0.windowID == windowID }),
                  let display = content.displays.first(where: {
                      $0.frame.contains(CGPoint(x: window.frame.midX, y: window.frame.midY))
                  })
            else { throw SCStreamError(.noWindowList) }
            filter = SCContentFilter(display: display, including: [window])
            let frame = window.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            source = frame.intersection(CGRect(origin: .zero, size: display.frame.size))
        }
        let size = source?.size ?? filter.contentRect.size
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        // H.264 needs even dimensions; shrink the source to match so nothing is rescaled.
        config.width = max(2, Int(size.width * scale) / 2 * 2)
        config.height = max(2, Int(size.height * scale) / 2 * 2)
        if let source {
            config.sourceRect = CGRect(origin: source.origin, size: CGSize(width: CGFloat(config.width) / scale,
                                                                           height: CGFloat(config.height) / scale))
        }
        config.captureResolution = .best
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = true
        config.showMouseClicks = showsClicks
        config.pixelFormat = kCVPixelFormatType_32BGRA  // click highlighting needs BGRA

        let output = SCRecordingOutputConfiguration()
        output.outputURL = url
        output.outputFileType = .mp4
        output.videoCodecType = .h264

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addRecordingOutput(SCRecordingOutput(configuration: output, delegate: self))
        try await stream.startCapture()
        self.stream = stream
        if isStopping || isFinished { stopCapture(stream) }
    }

    /// Ends the recording, also one still starting; `onFinish` follows once the file is written.
    func stop() {
        guard !isStopping, !isFinished else { return }
        isStopping = true
        if let stream { stopCapture(stream) }
    }

    /// The stream stays referenced until `finish`, so its recording output can report.
    private func stopCapture(_ stream: SCStream) {
        Task {
            do {
                try await stream.stopCapture()
            } catch {
                finish(.failure(error))
            }
        }
    }

    private func streamStopped(with error: Error) {
        isStopping = true
        // Stopped from the menu bar or the recorded window closed: the recording output
        // still reports the finished file. Fail only if it stays silent.
        Task {
            try? await Task.sleep(for: .seconds(3))
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !isFinished else { return }
        isFinished = true
        // A failure (of the recording output or the stream) can leave capture running and
        // macOS's menu-bar indicator stuck; stopping an already stopped stream just throws.
        isStopping = true
        if let stream { Task { try? await stream.stopCapture() } }
        stream = nil
        onFinish?(result)
    }
}

// ScreenCaptureKit calls these on its own queues.
@available(macOS 15, *)
extension ScreenRecorder: SCStreamDelegate, SCRecordingOutputDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in streamStopped(with: error) }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in finish(.success(url)) }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in finish(.failure(error)) }
    }
}
