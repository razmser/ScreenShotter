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
        var result: [(screen: NSScreen, image: CGImage)] = []
        for screen in screens {
            guard let filter = filter(for: screen, in: content) else { continue }
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

    /// Captures one window on its own at native resolution, even where others cover it.
    static func capture(windowID: CGWindowID) async throws -> Screenshot {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let filter = try filter(forWindow: windowID, in: content)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return Screenshot(image: image, scale: scale)
    }

    /// The window alone, wherever it is and whatever covers it.
    static func filter(forWindow windowID: CGWindowID, in content: SCShareableContent) throws -> SCContentFilter {
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw SCStreamError(.noWindowList)
        }
        return SCContentFilter(desktopIndependentWindow: window)
    }

    /// On-screen normal windows, front to back, skipping menus, the Dock, invisible
    /// helper windows, and overlays such as the area selection. Bounds use a top-left origin on the primary display.
    static func normalWindows() -> [(id: CGWindowID, bounds: CGRect)] {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[CFString: Any]] ?? []
        return windows.compactMap { info in
            guard info[kCGWindowLayer] as? Int == 0,
                  (info[kCGWindowAlpha] as? Double ?? 1) > 0,
                  let id = info[kCGWindowNumber] as? CGWindowID,
                  let bounds = info[kCGWindowBounds].flatMap({ CGRect(dictionaryRepresentation: $0 as! CFDictionary) })
            else { return nil }
            return (id, bounds)
        }
    }

    /// The frontmost of `windows` at `point` (global AppKit coordinates).
    static func windowID(at point: NSPoint, in windows: [(id: CGWindowID, bounds: CGRect)]) -> CGWindowID? {
        guard let primary = NSScreen.screens.first else { return nil }
        let location = CGPoint(x: point.x, y: primary.frame.maxY - point.y)
        return windows.first { $0.bounds.contains(location) }?.id
    }

    /// The display showing `screen`, minus this app's floating windows.
    static func filter(for screen: NSScreen, in content: SCShareableContent) -> SCContentFilter? {
        guard let id = screen.displayID,
              let display = content.displays.first(where: { $0.displayID == id })
        else { return nil }
        let pid = ProcessInfo.processInfo.processIdentifier
        let hidden = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer != 0 }
        return SCContentFilter(display: display, excludingWindows: hidden)
    }
}
