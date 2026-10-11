import AppKit
import Carbon.HIToolbox
import Combine

/// The ways to capture, each with its own global shortcut.
enum CaptureAction: UInt32, CaseIterable {
    // Raw values are hotkey IDs and record the order actions were added (see the
    // shortcut migration); case order is the menu order.
    case screen = 1, area = 2, record = 4, text = 3

    /// The actions this macOS version supports; recording needs macOS 15.
    static var available: [CaptureAction] {
        if #available(macOS 15, *) { return allCases }
        return allCases.filter { $0 != .record }
    }

    /// Menu title, e.g. "Capture Area".
    var title: String { "\(verb) \(noun.prefix(1).uppercased())\(noun.dropFirst())" }
    /// Sentence-case label for Settings, e.g. "Capture area".
    var label: String { "\(verb) \(noun)" }

    private var verb: String { self == .record ? "Record" : "Capture" }

    private var noun: String {
        switch self {
        case .screen, .record: "screen"
        case .area: "area"
        case .text: "text/QR"
        }
    }

    var defaultShortcut: Shortcut {
        let key = switch self {
        case .screen: kVK_ANSI_3
        case .area: kVK_ANSI_4
        case .text: kVK_ANSI_7
        case .record: kVK_ANSI_5
        }
        return Shortcut(keyCode: UInt32(key), modifiers: UInt32(cmdKey | shiftKey))
    }

    fileprivate var defaultsKey: String {
        switch self {
        case .screen: "fullScreenShortcut"
        case .area: "areaShortcut"
        case .text: "textShortcut"
        case .record: "recordShortcut"
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
        static let showRecordingClicks = "showRecordingClicks"
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
    /// Whether screen recordings highlight mouse clicks.
    @Published var showRecordingClicks: Bool {
        didSet { defaults.set(showRecordingClicks, forKey: Keys.showRecordingClicks) }
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
        showRecordingClicks = defaults.object(forKey: Keys.showRecordingClicks) as? Bool ?? true
        if let path = defaults.string(forKey: Keys.saveFolder) {
            saveFolder = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            saveFolder = URL.documentsDirectory.appending(path: "ScreenShots", directoryHint: .isDirectory)
        }
        // The text and record shortcuts were added later; don't let their defaults steal
        // an existing one. Set after init so didSet persists the cleared shortcut.
        for later in [CaptureAction.text, .record] {
            guard let shortcut = self.shortcuts[later] else { continue }
            let earlier = CaptureAction.allCases.filter { $0.rawValue < later.rawValue }
            if earlier.contains(where: { self.shortcuts[$0] == shortcut }) {
                self.shortcuts[later] = nil
            }
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
