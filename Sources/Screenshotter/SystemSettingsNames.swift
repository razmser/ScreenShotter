import Foundation

/// Names from System Settings as macOS shows them in the user's language, so
/// messages match what the user sees. Falls back to English if a lookup fails.
enum SystemSettingsNames {
    /// A shortcut's name as Keyboard Shortcuts lists it, from its English name. Reads the
    /// Keyboard pane's `.loctable` (all languages in one plist) directly: Bundle's own
    /// lookup would follow this app's language, which is English only.
    static func shortcut(_ englishName: String) -> String {
        let url = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions/KeyboardSettings.appex")
            .appending(path: "Contents/Resources/DefaultShortcutsTable.loctable")
        guard let languages = NSDictionary(contentsOf: url) as? [String: Any],
              let language = Bundle.preferredLocalizations(from: Array(languages.keys),
                                                           forPreferences: Locale.preferredLanguages).first,
              let value = (languages[language] as? [String: Any])?[englishName] as? String
        else { return englishName }
        // Some names carry soft hyphens for wrapping, e.g. Danish "Præsentations­overligger".
        return value.replacingOccurrences(of: "\u{AD}", with: "")
    }
}
