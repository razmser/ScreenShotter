import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut stored as a virtual key code plus Carbon modifier mask.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Builds a shortcut from a key event. Requires ⌘, ⌥ or ⌃ unless the key is a function key.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let hasModifier = !flags.intersection([.command, .option, .control]).isEmpty
        guard hasModifier || Self.functionKeys[Int(event.keyCode)] != nil else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: Self.carbonModifiers(flags))
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods = 0
        if flags.contains(.command) { mods |= cmdKey }
        if flags.contains(.option) { mods |= optionKey }
        if flags.contains(.control) { mods |= controlKey }
        if flags.contains(.shift) { mods |= shiftKey }
        return UInt32(mods)
    }

    var cocoaModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    var displayString: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + keyName
    }

    /// Key equivalent usable in an NSMenuItem, or "" for keys that have no character form.
    var menuKeyEquivalent: String {
        guard Self.specialKeys[Int(keyCode)] == nil, Self.functionKeys[Int(keyCode)] == nil else { return "" }
        return keyName.lowercased()
    }

    var keyName: String {
        let code = Int(keyCode)
        if let name = Self.specialKeys[code] ?? Self.functionKeys[code] { return name }
        return Self.translate(keyCode: UInt16(keyCode)) ?? "#\(keyCode)"
    }

    /// Maps a key code to its character using the ASCII-capable layout, so shortcuts
    /// read as Latin letters even when a non-Latin input source is active.
    private static func translate(keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(rawData).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState,
                                  chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }

    private static let specialKeys: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_Escape: "⎋",
        kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑",
        kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]
}
