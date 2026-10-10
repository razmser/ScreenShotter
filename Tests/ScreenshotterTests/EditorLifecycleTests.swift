import AppKit
import XCTest
@testable import Screenshotter

@MainActor
final class EditorLifecycleTests: XCTestCase {
    func testDockPresenceFollowsOpenEditorsAndDockReopenRestoresMinimizedEditor() throws {
        let app = NSApplication.shared
        let originalPolicy = app.activationPolicy()
        let delegate = AppDelegate()
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 60,
                                             bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let shot = Screenshot(image: try XCTUnwrap(context.makeImage()), scale: 1)
        let existingWindows = Set(app.windows.map(ObjectIdentifier.init))
        func editorWindows() -> [NSWindow] {
            app.windows.filter { !existingWindows.contains(ObjectIdentifier($0)) && $0.title == "Screenshot" }
        }
        func drainCloseCallbacks() {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        defer {
            editorWindows().forEach { $0.close() }
            app.windows.filter { !existingWindows.contains(ObjectIdentifier($0)) && $0.title == "ScreenShotter Settings" }
                .forEach { $0.close() }
            drainCloseCallbacks()
            app.setActivationPolicy(originalPolicy)
        }

        app.setActivationPolicy(.accessory)
        delegate.openSettings()
        let settingsWindow = try XCTUnwrap(app.windows.first { $0.title == "ScreenShotter Settings" })
        XCTAssertEqual(app.activationPolicy(), .accessory, "Settings alone should not add a Dock icon")
        delegate.openEditor(with: shot)
        let first = try XCTUnwrap(editorWindows().first)
        XCTAssertTrue(first.isVisible)
        XCTAssertEqual(app.activationPolicy(), .regular)

        delegate.openEditor(with: shot)
        let second = try XCTUnwrap(editorWindows().first { $0 !== first })
        first.close()
        drainCloseCallbacks()
        XCTAssertEqual(app.activationPolicy(), .regular, "The remaining editor still needs a Dock icon")

        second.miniaturize(nil)
        let minimizeDeadline = Date(timeIntervalSinceNow: 2)
        while !second.isMiniaturized && Date() < minimizeDeadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        XCTAssertTrue(second.isMiniaturized)
        XCTAssertEqual(app.activationPolicy(), .regular, "A minimized editor must remain discoverable")
        XCTAssertFalse(delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false))
        let restoreDeadline = Date(timeIntervalSinceNow: 2)
        while second.isMiniaturized && Date() < restoreDeadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        XCTAssertFalse(second.isMiniaturized)
        XCTAssertTrue(second.isVisible)

        second.close()
        drainCloseCallbacks()
        XCTAssertEqual(app.activationPolicy(), .accessory, "Closing the last editor removes the Dock icon")
        XCTAssertTrue(settingsWindow.isVisible, "Removing the Dock icon should not close Settings")
    }

    func testCanvasKeyCommandsReachTheEditor() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 60,
                                             bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let editor = EditorWindowController(screenshot: Screenshot(image: try XCTUnwrap(context.makeImage()), scale: 1))
        defer { editor.close() }
        editor.showWindow(nil)
        // Return (Done) and ⌘C (Copy) travel up the responder chain from the canvas.
        let canvas = try XCTUnwrap(editor.window?.firstResponder as? CanvasView)
        let chain = sequence(first: canvas as NSResponder) { $0.nextResponder }
        XCTAssertTrue(chain.contains { $0 === editor })
    }
}
