import AppKit
import Carbon.HIToolbox

/// Why a shortcut won't trigger the app.
enum HotKeyConflict {
    /// An enabled macOS shortcut (Keyboard Shortcuts settings) uses the combo and
    /// takes precedence; registration doesn't report these.
    case system
    /// Registration was refused because another app holds the combo.
    case otherApp

    var owner: String { self == .system ? "a macOS shortcut" : "another app" }
}

/// Registers system-wide hotkeys via Carbon. Unlike event taps this needs no
/// Accessibility permission.
final class HotKeyManager: ObservableObject {
    static let shared = HotKeyManager()

    private struct Entry {
        var shortcut: Shortcut?
        var ref: EventHotKeyRef?
    }

    /// Called when a registered shortcut is pressed.
    var onHotKey: ((CaptureAction) -> Void)?
    private var entries: [CaptureAction: Entry] = [:]
    /// Actions whose shortcut won't trigger the app, and why.
    @Published private(set) var conflicts: [CaptureAction: HotKeyConflict] = [:]
    private var eventHandler: EventHandlerRef?
    private var pauseCount = 0
    private let signature: OSType = 0x5353_4854 // 'SSHT'
    private let probeID: UInt32 = .max

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            // Carbon delivers hotkey events on the main run loop.
            MainActor.assumeIsolated {
                if let action = CaptureAction(rawValue: hotKeyID.id) { HotKeyManager.shared.onHotKey?(action) }
            }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }

    /// Sets (or clears, with `nil`) the shortcut for `action`. Returns false if it
    /// conflicts with a macOS shortcut or another app's.
    @discardableResult
    func set(_ action: CaptureAction, shortcut: Shortcut?) -> Bool {
        guard entries[action]?.shortcut != shortcut else { return conflicts[action] == nil }
        unregister(action)
        entries[action] = Entry(shortcut: shortcut)
        conflicts[action] = nil
        return pauseCount > 0 || register(action)
    }

    /// Re-checks every shortcut, e.g. after the user changed macOS shortcuts or the
    /// app holding one quit. Shortcuts that failed to register are retried.
    func refreshConflicts() {
        guard pauseCount == 0 else { return }
        for action in Array(entries.keys) { register(action) }
    }

    /// Whether `shortcut` can be registered, i.e. no other app holds it exclusively.
    /// Call while paused so this app's own shortcuts don't count as taken.
    func isAvailable(_ shortcut: Shortcut) -> Bool {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                         EventHotKeyID(signature: signature, id: probeID),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        if let ref { UnregisterEventHotKey(ref) }
        return status == noErr
    }

    /// Temporarily disables all hotkeys, e.g. while the user records a new one.
    func pause() {
        pauseCount += 1
        if pauseCount == 1 { for action in Array(entries.keys) { unregister(action) } }
    }

    func resume() {
        guard pauseCount > 0 else { return }
        pauseCount -= 1
        if pauseCount == 0 { for action in Array(entries.keys) { register(action) } }
    }

    /// Registers `action` unless it already is, then records any conflict. A shortcut
    /// that clashes with a macOS one stays registered, so it starts working as soon
    /// as the user turns the macOS shortcut off.
    @discardableResult
    private func register(_ action: CaptureAction) -> Bool {
        guard let shortcut = entries[action]?.shortcut else {
            conflicts[action] = nil
            return true
        }
        var status = noErr
        if entries[action]?.ref == nil {
            var ref: EventHotKeyRef?
            status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                         EventHotKeyID(signature: signature, id: action.rawValue),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
            entries[action]?.ref = ref
            if status != noErr { NSLog("ScreenShotter: failed to register hotkey \(shortcut.displayString): \(status)") }
        }
        // An enabled macOS shortcut wins over any app's, so it's the conflict to report.
        let conflict: HotKeyConflict? = Self.isSystemShortcut(shortcut) ? .system : status != noErr ? .otherApp : nil
        if conflicts[action] != conflict { conflicts[action] = conflict }
        return conflict == nil
    }

    /// Whether an enabled macOS shortcut, e.g. ⇧⌘4 for screenshots, uses this combo.
    static func isSystemShortcut(_ shortcut: Shortcut) -> Bool {
        var array: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&array) == noErr,
              let hotKeys = array?.takeRetainedValue() as? [[String: Any]]
        else { return false }
        let modifierMask = cmdKey | shiftKey | optionKey | controlKey
        return hotKeys.contains { hotKey in
            hotKey[kHISymbolicHotKeyEnabled] as? Bool == true
                && hotKey[kHISymbolicHotKeyCode] as? Int == Int(shortcut.keyCode)
                && (hotKey[kHISymbolicHotKeyModifiers] as? Int).map { $0 & modifierMask } == Int(shortcut.modifiers)
        }
    }

    private func unregister(_ action: CaptureAction) {
        guard let ref = entries[action]?.ref else { return }
        UnregisterEventHotKey(ref)
        entries[action]?.ref = nil
    }
}
