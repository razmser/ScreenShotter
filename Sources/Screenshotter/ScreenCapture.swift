import AppKit
import ScreenCaptureKit

/// A captured image plus its pixels-per-point ratio (2 on Retina displays).
struct Screenshot {
    let image: CGImage
    let scale: CGFloat

    var pointSize: CGSize {
        CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static var underMouse: NSScreen? {
        let location = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(location, $0.frame, false) } ?? main
    }
}

enum ScreenCapture {
    /// Captures each screen at native resolution. This app's normal windows, such as
    /// Settings and editors, are captured like any other; its floating ones (the
    /// toast, a status menu still fading out) are left out.
    static func capture(_ screens: [NSScreen]) async throws -> [(screen: NSScreen, image: CGImage)] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        let hidden = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer != 0 }

        var result: [(screen: NSScreen, image: CGImage)] = []
        for screen in screens {
            guard let id = screen.displayID,
                  let display = content.displays.first(where: { $0.displayID == id })
            else { continue }
            let filter = SCContentFilter(display: display, excludingWindows: hidden)
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
            config.showsCursor = false
            config.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            result.append((screen, image))
        }
        return result
    }
}
