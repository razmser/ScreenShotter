import AppKit

/// A macOS shortcut listed in System Settings → Keyboard → Keyboard Shortcuts, by its
/// symbolic hotkey ID. Reading and toggling one by ID takes private WindowServer calls;
/// they're looked up at runtime so a macOS without them only loses the name.
struct SystemShortcut: Equatable {
    let id: Int32
    /// As System Settings shows it, e.g. “Save picture of selected area as a file”.
    let name: String

    /// The enabled shortcut System Settings lists for `shortcut`'s combo, if any.
    static func enabled(matching shortcut: Shortcut) -> SystemShortcut? {
        guard let isEnabled else { return nil }
        let modifierMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        return all.first { candidate in
            guard let combo = candidate.combo, isEnabled(candidate.id) else { return false }
            return combo.keyCode == Int(shortcut.keyCode)
                && combo.modifiers.intersection(modifierMask) == shortcut.cocoaModifiers
                && (!combo.modifiers.contains(.function) || shortcut.impliesFn)
        }.map { SystemShortcut(id: $0.id, name: SystemSettingsNames.shortcut($0.name)) }
    }

    /// Turns the shortcut off right away and in macOS's preferences, which System
    /// Settings shows and WindowServer reads at login. Only `enabled` is written, as
    /// System Settings does, so the saved combo stays as it was.
    func disable() {
        _ = Self.setEnabled?(id, false)
        let domain = "com.apple.symbolichotkeys" as CFString, key = "AppleSymbolicHotKeys" as CFString
        var hotKeys = CFPreferencesCopyAppValue(key, domain) as? [String: Any] ?? [:]
        var entry = hotKeys[String(id)] as? [String: Any] ?? [:]
        entry["enabled"] = false
        hotKeys[String(id)] = entry
        CFPreferencesSetAppValue(key, hotKeys as CFDictionary, domain)
        CFPreferencesAppSynchronize(domain)
    }

    /// The current combo as WindowServer reports it, with `.function` added for keys
    /// where `Shortcut.impliesFn`.
    private var combo: (keyCode: Int, modifiers: NSEvent.ModifierFlags)? {
        var character: UniChar = 0, keyCode: UniChar = 0
        // Zeroed, so it reads right whether the call writes 32 or 64 bits.
        var modifiers: UInt64 = 0
        guard let getValue = Self.getValue, getValue(id, &character, &keyCode, &modifiers) == 0 else { return nil }
        return (Int(keyCode), NSEvent.ModifierFlags(rawValue: UInt(modifiers)))
    }

    /// Every shortcut System Settings lists, read from its own tables so they match the
    /// running macOS. Names are English here; `enabled(matching:)` localizes the match.
    private static let all: [SystemShortcut] = {
        guard let bundle = Bundle(path: "/System/Library/ExtensionKit/Extensions/KeyboardSettings.appex") else { return [] }
        var shortcuts: [SystemShortcut] = []
        func collect(_ node: Any) {
            if let nodes = node as? [Any] { nodes.forEach(collect) }
            guard let entry = node as? [String: Any] else { return }
            // Sic: the tables misspell the key.
            if let id = entry["sybmolichotkey"] as? Int, let name = entry["name"] as? String {
                shortcuts.append(SystemShortcut(id: Int32(id), name: name.replacing("DO_NOT_LOCALIZE: ", with: "")))
            }
            if let elements = entry["elements"] { collect(elements) }
        }
        for table in ["DefaultShortcutsTable", "DefaultSpacesShortcuts"] {
            guard let url = bundle.url(forResource: table, withExtension: "xml"),
                  let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
            else { continue }
            collect(plist)
        }
        return shortcuts
    }()

    private typealias GetValue = @convention(c) (Int32, UnsafeMutablePointer<UniChar>,
                                                 UnsafeMutablePointer<UniChar>, UnsafeMutablePointer<UInt64>) -> Int32
    private typealias IsEnabled = @convention(c) (Int32) -> Bool
    private typealias SetEnabled = @convention(c) (Int32, Bool) -> Int32

    private static let getValue = symbol("CGSGetSymbolicHotKeyValue", as: GetValue.self)
    private static let isEnabled = symbol("CGSIsSymbolicHotKeyEnabled", as: IsEnabled.self)
    private static let setEnabled = symbol("CGSSetSymbolicHotKeyEnabled", as: SetEnabled.self)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        // RTLD_DEFAULT, which Swift doesn't import.
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: type) }
    }
}
