import Foundation

/// Names of System Settings panes as macOS shows them in the user's language, so
/// instructions match what the user sees. Falls back to English if a lookup fails.
enum SystemSettingsNames {
    static var systemSettings: String {
        lookup("/System/Applications/System Settings.app", table: "InfoPlist", key: "CFBundleName")
            ?? "System Settings"
    }

    static var keyboard: String {
        lookup(keyboardPane, table: "InfoPlist", key: "CFBundleDisplayName") ?? "Keyboard"
    }

    static var keyboardShortcuts: String {
        lookup(keyboardPane, table: "Localizable", key: "Keyboard Shortcuts…")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "…⋯").union(.whitespaces)) }
            ?? "Keyboard Shortcuts"
    }

    static var screenshots: String {
        lookup(keyboardPane, table: "DefaultShortcutsTable", key: "Screenshots") ?? "Screenshots"
    }

    private static let keyboardPane = "/System/Library/ExtensionKit/Extensions/KeyboardSettings.appex"

    /// Reads `key` from the bundle's `.loctable` (all languages in one plist) directly:
    /// Bundle's own lookup would follow this app's language, which is English only.
    private static func lookup(_ bundlePath: String, table: String, key: String) -> String? {
        let url = URL(fileURLWithPath: bundlePath).appending(path: "Contents/Resources/\(table).loctable")
        guard let languages = NSDictionary(contentsOf: url) as? [String: Any],
              let language = Bundle.preferredLocalizations(from: Array(languages.keys),
                                                           forPreferences: Locale.preferredLanguages).first,
              let value = (languages[language] as? [String: Any])?[key] as? String
        else { return nil }
        // Some names carry soft hyphens for wrapping, e.g. German "System­einstellungen".
        return value.replacingOccurrences(of: "\u{AD}", with: "")
    }
}
