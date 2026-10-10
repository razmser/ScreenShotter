import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var editors: [EditorWindowController] = []
    private var areaSelection: AreaSelectionController?
    private var isCapturing = false
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        setupStatusItem()

        HotKeyManager.shared.onHotKey = { [weak self] action in self?.capture(action) }
        settings.$shortcuts
            .sink { shortcuts in
                for action in CaptureAction.allCases {
                    HotKeyManager.shared.set(action, shortcut: shortcuts[action])
                }
            }
            .store(in: &cancellables)
        settings.$showInMenuBar
            .sink { [weak self] visible in self?.statusItem.isVisible = visible }
            .store(in: &cancellables)
        HotKeyManager.shared.$conflicts
            .sink { [weak self] conflicts in self?.updateStatusIcon(hasFailedShortcuts: !conflicts.isEmpty) }
            .store(in: &cancellables)

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        if !launchedAsLoginItem() { openSettings() }
    }

    /// Starting at login should stay in the menu bar; any other launch is the user opening the app.
    private func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    // MARK: Capture

    func capture(_ action: CaptureAction) {
        switch action {
        case .screen: captureScreen()
        case .area: captureArea()
        case .text: captureText()
        }
    }

    @objc private func captureFromMenu(_ sender: NSMenuItem) {
        if let action = sender.representedObject as? CaptureAction { capture(action) }
    }

    private func captureScreen() {
        guard !isCapturing, areaSelection == nil, let screen = NSScreen.underMouse else { return }
        isCapturing = true
        Task {
            defer { isCapturing = false }
            do {
                guard let capture = try await ScreenCapture.capture([screen]).first else { return }
                let scale = CGFloat(capture.image.width) / capture.screen.frame.width
                deliver(Screenshot(image: capture.image, scale: scale))
            } catch {
                presentCaptureError(error)
            }
        }
    }

    private func captureArea() {
        selectArea { [weak self] shot in self?.deliver(shot) }
    }

    /// Copies the text (or QR code contents) of a selected area.
    private func captureText() {
        selectArea { shot in
            Task {
                do {
                    let text = try await TextRecognition.recognize(shot.image)
                    guard !text.isEmpty else {
                        Toast.show("No text found")
                        return
                    }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    let lines = text.split(whereSeparator: \.isNewline).count
                    Toast.show(lines == 1 ? "Copied text" : "Copied \(lines) lines of text")
                } catch {
                    Toast.show("Text recognition failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func selectArea(then handle: @escaping (Screenshot) -> Void) {
        guard !isCapturing, areaSelection == nil else { return }
        isCapturing = true
        Task {
            defer { isCapturing = false }
            do {
                let captures = try await ScreenCapture.capture(NSScreen.screens)
                guard !captures.isEmpty else { return }
                let selection = AreaSelectionController(captures: captures) { [weak self] shot in
                    self?.areaSelection = nil
                    if let shot { handle(shot) }
                    self?.returnFocusIfIdle()
                }
                areaSelection = selection
                selection.begin()
            } catch {
                presentCaptureError(error)
            }
        }
    }

    private func deliver(_ shot: Screenshot) {
        switch settings.afterCapture {
        case .openEditor: openEditor(with: shot)
        case .copy: Output.export(shot, copy: true, save: false)
        case .save: Output.export(shot, copy: false, save: true)
        case .copyAndSave: Output.export(shot, copy: true, save: true)
        }
    }

    func openEditor(with shot: Screenshot) {
        let editor = EditorWindowController(screenshot: shot)
        editor.onClose = { [weak self] closed in
            DispatchQueue.main.async {
                self?.editors.removeAll { $0 === closed }
                self?.returnFocusIfIdle()
                self?.updateDockPresence()
            }
        }
        editors.append(editor)
        updateDockPresence()
        NSApp.activate()
        editor.showWindow(nil)
        editor.window?.makeKeyAndOrderFront(nil)
    }

    /// Keep open editors discoverable, including while minimized or behind other apps.
    /// Settings and capture overlays alone should not add an icon to the Dock.
    private func updateDockPresence() {
        let policy: NSApplication.ActivationPolicy = editors.isEmpty ? .accessory : .regular
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The overlay sits above modal alerts and would hide the confirmation.
        areaSelection?.cancel()
        let unsaved = editors.filter { $0.hasUnexportedChanges() }
        guard settings.confirmBeforeClosing, !unsaved.isEmpty else { return .terminateNow }
        NSApp.activate()
        let alert = EditorWindowController.makeCloseAlert(screenshots: unsaved.count)
        alert.buttons.first?.title = "Quit"
        guard alert.runModal() == .alertFirstButtonReturn else {
            unsaved.last?.window?.makeKeyAndOrderFront(nil)
            return .terminateCancel
        }
        if alert.suppressionButton?.state == .on { settings.confirmBeforeClosing = false }
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let editorWindows = editors.compactMap(\.window)
        let frontEditor = sender.orderedWindows.first { window in
            editorWindows.contains { $0 === window }
        }
        guard let window = frontEditor ?? editorWindows.last else {
            openSettings()
            return false
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        return false
    }

    /// Hands focus back to the previously active app once no ScreenShotter window
    /// needs it, so e.g. ⌘V pastes there right after a capture.
    private func returnFocusIfIdle() {
        guard NSApp.isActive, editors.isEmpty, settingsWindow?.isVisible != true else { return }
        NSApp.hide(nil)
    }

    private func presentCaptureError(_ error: Error) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Screen capture failed"
        alert.informativeText = """
            \(error.localizedDescription)

            Make sure ScreenShotter is allowed in System Settings → Privacy & Security → \
            Screen & System Audio Recording, then relaunch the app.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Menus

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon(hasFailedShortcuts: !HotKeyManager.shared.conflicts.isEmpty)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Badges the menu-bar icon while any global shortcut couldn't be registered.
    private func updateStatusIcon(hasFailedShortcuts: Bool) {
        guard let button = statusItem?.button else { return }
        button.image = StatusIcon.makeImage(badged: hasFailedShortcuts)
        button.toolTip = hasFailedShortcuts ? "Some shortcuts are unavailable" : nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        menu.removeAllItems()
        HotKeyManager.shared.refreshConflicts()
        let conflicts = HotKeyManager.shared.conflicts
        if conflicts.values.contains(.system) {
            // Menu items can't hold real links, so the whole item opens System Settings.
            let title = NSMutableAttributedString(string: "Unassign system shortcuts in ")
            typealias Names = SystemSettingsNames
            title.append(NSAttributedString(string: "\(Names.systemSettings) → \(Names.keyboard)", attributes: [
                .foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]))
            title.append(NSAttributedString(string: " →\n\(Names.keyboardShortcuts) → \(Names.screenshots) to avoid conflicts."))
            title.addAttribute(.font, value: NSFont.menuFont(ofSize: 0), range: NSRange(location: 0, length: title.length))
            let warning = item(title.string, #selector(openKeyboardSettings), nil)
            warning.attributedTitle = title
            warning.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                    accessibilityDescription: "Warning")
            menu.addItem(warning)
        }
        for action in CaptureAction.allCases {
            guard conflicts[action] == .otherApp, let shortcut = settings.shortcuts[action] else { continue }
            let warning = item("\(shortcut.displayString) for \(action.title) is used by another app…",
                               #selector(openSettings), nil)
            warning.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                    accessibilityDescription: "Warning")
            menu.addItem(warning)
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        for action in CaptureAction.allCases {
            let capture = item(action.title, #selector(captureFromMenu(_:)),
                               conflicts[action] == nil ? settings.shortcuts[action] : nil)
            capture.representedObject = action
            menu.addItem(capture)
        }
        menu.addItem(.separator())
        menu.addItem(item("Open Screenshots Folder", #selector(openSaveFolder), nil))
        menu.addItem(item("Settings…", #selector(openSettings), nil))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ScreenShotter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector, _ shortcut: Shortcut?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: shortcut?.menuKeyEquivalent ?? "")
        item.keyEquivalentModifierMask = shortcut?.cocoaModifiers ?? []
        item.target = self
        return item
    }

    /// Visible while an editor is open; also routes key equivalents in accessory mode.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide ScreenShotter", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit ScreenShotter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Save", action: #selector(EditorWindowController.saveImage(_:)), keyEquivalent: "s")
        let saveAs = fileMenu.addItem(withTitle: "Save As…", action: #selector(EditorWindowController.saveImageAs(_:)), keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        NSApp.windowsMenu = windowMenu

        for (title, submenu) in [("ScreenShotter", appMenu), ("File", fileMenu), ("Edit", editMenu), ("Window", windowMenu)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            main.addItem(item)
        }
        return main
    }

    @objc func openSaveFolder() {
        try? FileManager.default.createDirectory(at: settings.saveFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(settings.saveFolder)
    }

    @objc private func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(settings: settings)))
            window.title = "ScreenShotter Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
