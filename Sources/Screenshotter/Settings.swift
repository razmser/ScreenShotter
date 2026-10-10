import AppKit
import Carbon.HIToolbox
import Combine

/// The ways to capture, each with its own global shortcut.
enum CaptureAction: UInt32, CaseIterable {
    case screen = 1, area, text

    /// Menu title, e.g. "Capture Area".
    var title: String { "Capture \(noun.prefix(1).uppercased())\(noun.dropFirst())" }
    /// Sentence-case label for Settings, e.g. "Capture area".
    var label: String { "Capture \(noun)" }

    private var noun: String {
        switch self {
        case .screen: "screen"
        case .area: "area"
        case .text: "text/QR"
        }
    }

    var defaultShortcut: Shortcut {
        let key = switch self {
        case .screen: kVK_ANSI_3
        case .area: kVK_ANSI_4
        case .text: kVK_ANSI_7
        }
        return Shortcut(keyCode: UInt32(key), modifiers: UInt32(cmdKey | shiftKey))
    }

    fileprivate var defaultsKey: String {
        switch self {
        case .screen: "fullScreenShortcut"
        case .area: "areaShortcut"
        case .text: "textShortcut"
        }
    }
}

enum AfterCaptureAction: String, CaseIterable, Identifiable {
    case openEditor, copy, save, copyAndSave

    var id: String { rawValue }
    var title: String {
        switch self {
        case .openEditor: "Open editor"
        case .copy: "Copy to clipboard"
        case .save: "Save to folder"
        case .copyAndSave: "Copy and save"
        }
    }
}

enum ExportAction: String, CaseIterable, Identifiable {
    case copy, save, copyAndSave

    var id: String { rawValue }
    var title: String {
        switch self {
        case .copy: "Copy to clipboard"
        case .save: "Save to folder"
        case .copyAndSave: "Copy and save"
        }
    }
    var copies: Bool { self != .save }
    var saves: Bool { self != .copy }
}

enum ImageFormat: String, CaseIterable, Identifiable {
    case png, jpeg

    var id: String { rawValue }
    var title: String { self == .png ? "PNG" : "JPEG" }
    var fileExtension: String { self == .png ? "png" : "jpg" }
}

/// User preferences, persisted in UserDefaults.
final class Settings: ObservableObject {
    static let shared = Settings()

    private enum Keys {
        static let afterCapture = "afterCapture"
        static let editorDoneAction = "editorDoneAction"
        static let confirmBeforeClosing = "confirmBeforeClosing"
        static let saveFolder = "saveFolder"
        static let imageFormat = "imageFormat"
        static let showInMenuBar = "showInMenuBar"
    }

    private let defaults = UserDefaults.standard

    /// Global shortcuts; an action without one has been cleared.
    @Published var shortcuts: [CaptureAction: Shortcut] {
        didSet {
            for action in CaptureAction.allCases where shortcuts[action] != oldValue[action] {
                storeShortcut(shortcuts[action], forKey: action.defaultsKey)
            }
        }
    }
    @Published var afterCapture: AfterCaptureAction {
        didSet { defaults.set(afterCapture.rawValue, forKey: Keys.afterCapture) }
    }
    /// What the editor's "Done" button (and Return key) does before closing.
    @Published var editorDoneAction: ExportAction {
        didSet { defaults.set(editorDoneAction.rawValue, forKey: Keys.editorDoneAction) }
    }
    /// Whether closing an editor (or quitting) asks first when its screenshot
    /// hasn't been copied or saved.
    @Published var confirmBeforeClosing: Bool {
        didSet { defaults.set(confirmBeforeClosing, forKey: Keys.confirmBeforeClosing) }
    }
    @Published var saveFolder: URL {
        didSet { defaults.set(saveFolder.path, forKey: Keys.saveFolder) }
    }
    @Published var imageFormat: ImageFormat {
        didSet { defaults.set(imageFormat.rawValue, forKey: Keys.imageFormat) }
    }
    /// When hidden, opening the app again is the way back to Settings.
    @Published var showInMenuBar: Bool {
        didSet { defaults.set(showInMenuBar, forKey: Keys.showInMenuBar) }
    }

    private init() {
        var shortcuts: [CaptureAction: Shortcut] = [:]
        for action in CaptureAction.allCases {
            shortcuts[action] = Self.loadShortcut(defaults, action.defaultsKey, fallback: action.defaultShortcut)
        }
        self.shortcuts = shortcuts
        afterCapture = defaults.string(forKey: Keys.afterCapture).flatMap(AfterCaptureAction.init) ?? .openEditor
        editorDoneAction = defaults.string(forKey: Keys.editorDoneAction).flatMap(ExportAction.init) ?? .copy
        confirmBeforeClosing = defaults.object(forKey: Keys.confirmBeforeClosing) as? Bool ?? true
        imageFormat = defaults.string(forKey: Keys.imageFormat).flatMap(ImageFormat.init) ?? .png
        showInMenuBar = defaults.object(forKey: Keys.showInMenuBar) as? Bool ?? true
        if let path = defaults.string(forKey: Keys.saveFolder) {
            saveFolder = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            saveFolder = URL.documentsDirectory.appending(path: "ScreenShots", directoryHint: .isDirectory)
        }
        // The text shortcut was added later; don't let its default steal an existing one.
        // Set after init so didSet persists the cleared shortcut.
        if let text = shortcuts[.text], text == shortcuts[.screen] || text == shortcuts[.area] {
            self.shortcuts[.text] = nil
        }
    }

    /// A missing key means "never configured" (use the default); empty data means "cleared".
    private static func loadShortcut(_ defaults: UserDefaults, _ key: String, fallback: Shortcut) -> Shortcut? {
        guard let data = defaults.data(forKey: key) else { return fallback }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }

    private func storeShortcut(_ shortcut: Shortcut?, forKey key: String) {
        let data = shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        defaults.set(data, forKey: key)
    }
}
