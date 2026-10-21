import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject private var hotKeys = HotKeyManager.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Shortcuts") {
                ForEach(CaptureAction.available, id: \.self) { action in
                    ShortcutRecorder(label: action.label, shortcut: $settings.shortcuts[action],
                                     conflicts: CaptureAction.available.filter { $0 != action }
                                         .compactMap { settings.shortcuts[$0] },
                                     conflict: hotKeys.conflicts[action])
                }
            }

            Section("Workflow") {
                Picker("After capture", selection: $settings.afterCapture) {
                    ForEach(AfterCaptureAction.allCases) { Text($0.title).tag($0) }
                }
                Picker("Editor “Done” (⏎)", selection: $settings.editorDoneAction) {
                    ForEach(ExportAction.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Confirm before closing the editor", isOn: $settings.confirmBeforeClosing)
            }

            Section("Saving") {
                LabeledContent("Folder") {
                    HStack {
                        Text(settings.saveFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Picker("Format", selection: $settings.imageFormat) {
                    ForEach(ImageFormat.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            if #available(macOS 15, *) {
                Section("Recording") {
                    Toggle(isOn: $settings.showRecordingClicks) {
                        Text("Show clicks")
                        Text("Recordings are saved as MP4 to the folder above.")
                    }
                    .accessibilityLabel("Show clicks")
                }
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle(isOn: $settings.showInMenuBar) {
                    Text("Show in menu bar")
                    Text("When hidden, open ScreenShotter again or press ⌘, in an editor.")
                }
            }
        }
        .formStyle(.grouped)
        // Pick up macOS shortcut changes made in System Settings meanwhile.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            hotKeys.refreshConflicts()
        }
        .frame(width: 480)
        .fixedSize()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveFolder
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveFolder = url
        }
    }
}

/// Click to record a new global shortcut; Esc, a click elsewhere or leaving the
/// window cancels. Global hotkeys are paused while recording so the current combo
/// can be re-entered.
struct ShortcutRecorder: View {
    let label: String
    @Binding var shortcut: Shortcut?
    /// The other actions' shortcuts, which may not be reused.
    var conflicts: [Shortcut]
    /// Why pressing the shortcut doesn't trigger the app, if it doesn't.
    var conflict: HotKeyConflict?
    @State private var isRecording = false
    @State private var monitor: Any?

    /// The whole settings row: label and recorder on top, any conflict warning below.
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(label) { recorder }
            if let conflict, !isRecording {
                HStack(alignment: .firstTextBaseline) {
                    // Not a Label: in a Form it leaves a wide gap after the icon.
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        switch conflict {
                        case .system(let systemShortcut?):
                            Text("Used by the macOS shortcut\n“\(systemShortcut.name)”")
                        case .system(nil):
                            Text("Used by a macOS shortcut. Turn it off in [Keyboard Shortcuts](x-apple.systempreferences:com.apple.Keyboard-Settings.extension) or record another.")
                        case .otherApp:
                            Text("Used by another app. Record a different shortcut.")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    if case .system(let systemShortcut?) = conflict {
                        Spacer()
                        HStack(spacing: 4) {
                            Button {
                                systemShortcut.disable()
                                HotKeyManager.shared.refreshConflicts()
                            } label: {
                                Text("Unassign system")
                                    .frame(minWidth: 120)
                            }
                            // Takes the clear button's place so this lines up with the recorder.
                            Image(systemName: "xmark.circle.fill")
                                .hidden()
                        }
                    }
                }
            }
        }
        .onDisappear(perform: stop)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stop() }
    }

    private var recorder: some View {
        HStack(spacing: 4) {
            Button {
                if !isRecording { start() }
            } label: {
                Text(isRecording ? "Press shortcut…" : shortcut?.displayString ?? "Record shortcut")
                    .frame(minWidth: 120)
            }
            .accessibilityLabel("Record \(label.lowercased()) shortcut")
            .accessibilityValue(isRecording ? "Press shortcut"
                : shortcut.map { shortcut in
                    conflict.map { "\(shortcut.displayString), used by \($0.owner)" } ?? shortcut.displayString
                }
                ?? "Not set")
            if shortcut != nil && !isRecording {
                Button {
                    shortcut = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Clear shortcut")
                .accessibilityLabel("Clear \(label.lowercased()) shortcut")
            }
        }
        // Preserve both buttons inside LabeledContent instead of letting its
        // automatic accessibility representation collapse them into static text.
        .accessibilityElement(children: .contain)
    }

    private func start() {
        isRecording = true
        HotKeyManager.shared.pause()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { event in
            if event.type == .leftMouseDown {
                stop()
                return event
            }
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
            } else if let recorded = Shortcut(event: event), !conflicts.contains(recorded),
                      HotKeyManager.shared.isAvailable(recorded) {
                shortcut = recorded
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if isRecording {
            isRecording = false
            HotKeyManager.shared.resume()
        }
    }
}
