import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Screenshotter

@MainActor
final class EditorChangeTrackingTests: XCTestCase {
    func testChangesAreCountedThroughUndoAndRedo() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 60,
                                             bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let canvas = CanvasView(screenshot: Screenshot(image: try XCTUnwrap(context.makeImage()), scale: 1))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        defer { window.close() }

        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1))
        }

        XCTAssertEqual(canvas.changeCount, 0)
        canvas.tool = .rectangle
        canvas.mouseDown(with: try mouse(.leftMouseDown, CGPoint(x: 10, y: 10)))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, CGPoint(x: 40, y: 40)))
        canvas.mouseUp(with: try mouse(.leftMouseUp, CGPoint(x: 40, y: 40)))
        let afterDraw = canvas.changeCount
        XCTAssertGreaterThan(afterDraw, 0)

        canvas.undo(nil)
        XCTAssertGreaterThan(canvas.changeCount, afterDraw, "Undo is a change too")
        canvas.redo(nil)
        XCTAssertNotEqual(canvas.changeCount, afterDraw, "Redo is a change since the last export")
    }

    func testFailedHotKeyRegistrationIsReportedAndRetried() {
        let manager = HotKeyManager.shared
        let (owner, contender): (CaptureAction, CaptureAction) = (.screen, .area)
        let shortcut = Shortcut(keyCode: UInt32(kVK_F19), modifiers: UInt32(controlKey | optionKey | shiftKey))
        defer {
            manager.set(owner, shortcut: nil)
            manager.set(contender, shortcut: nil)
        }

        XCTAssertTrue(manager.set(owner, shortcut: shortcut))
        XCTAssertFalse(manager.set(contender, shortcut: shortcut), "The combo is already registered")
        XCTAssertEqual(manager.conflicts[contender], .otherApp)
        XCTAssertNil(manager.conflicts[owner])

        manager.set(owner, shortcut: nil)
        manager.refreshConflicts()
        XCTAssertNil(manager.conflicts[contender], "Retry succeeds once the combo is free")
    }

    func testEnabledMacOSShortcutIsReportedAsConflict() throws {
        var array: Unmanaged<CFArray>?
        try XCTSkipUnless(CopySymbolicHotKeys(&array) == noErr)
        let hotKeys = try XCTUnwrap(array?.takeRetainedValue() as? [[String: Any]])
        let mask = cmdKey | shiftKey | optionKey | controlKey
        let candidate = hotKeys.first { hotKey in
            hotKey[kHISymbolicHotKeyEnabled] as? Bool == true
                && (hotKey[kHISymbolicHotKeyModifiers] as? Int).map { $0 & mask != 0 } == true
                && (hotKey[kHISymbolicHotKeyCode] as? Int).map { $0 < 0xFFFF } == true
        }
        try XCTSkipUnless(candidate != nil, "No enabled macOS shortcut to test against")
        let enabled = try XCTUnwrap(candidate)
        let shortcut = Shortcut(keyCode: UInt32(try XCTUnwrap(enabled[kHISymbolicHotKeyCode] as? Int)),
                                modifiers: UInt32(try XCTUnwrap(enabled[kHISymbolicHotKeyModifiers] as? Int) & mask))
        let manager = HotKeyManager.shared
        let id = CaptureAction.text
        defer { manager.set(id, shortcut: nil) }

        XCTAssertTrue(HotKeyManager.isSystemShortcut(shortcut))
        XCTAssertFalse(manager.set(id, shortcut: shortcut))
        XCTAssertEqual(manager.conflicts[id], .system(SystemShortcut.enabled(matching: shortcut)))
    }

    func testMacOSShortcutIsNamed() throws {
        // ⌃↑ is Mission Control by default; macOS also stores the fn flag with it.
        let shortcut = Shortcut(keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(controlKey))
        try XCTSkipUnless(HotKeyManager.isSystemShortcut(shortcut), "⌃↑ isn't a macOS shortcut here")
        let systemShortcut = try XCTUnwrap(SystemShortcut.enabled(matching: shortcut))
        XCTAssertFalse(systemShortcut.name.isEmpty)
        XCTAssertFalse(systemShortcut.name.contains("DO_NOT_LOCALIZE"))
    }
}
