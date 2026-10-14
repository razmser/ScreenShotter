import AppKit

/// Editor window: a toolbar of annotation tools above a zoomable canvas.
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    var onClose: ((EditorWindowController) -> Void)?

    private let canvas: CanvasView
    private let scrollView = NSScrollView()
    private var toolControl: NSSegmentedControl!
    private let colorWell = NSColorWell(style: .minimal)
    private var strokeSizes: NSSegmentedControl!
    private var textSizes: NSSegmentedControl!
    private let fontSizes: [CGFloat] = [18, 26, 42]
    private var zoomObservation: NSKeyValueObservation?
    private let markerWidths: [CGFloat] = [16, 28, 44]
    private let lineWidths: [CGFloat] = [2, 4, 8]
    /// The canvas's change count when the image was last copied or saved, or nil
    /// if it never was.
    private var exportedChangeCount: Int?

    /// Whether closing would lose the screenshot as it is now, i.e. it hasn't been
    /// copied or saved since the last change. Commits a pending text label first,
    /// since typing doesn't bump the change count until the label is committed.
    func hasUnexportedChanges() -> Bool {
        canvas.commitText()
        return canvas.changeCount != exportedChangeCount
    }

    init(screenshot: Screenshot) {
        canvas = CanvasView(screenshot: screenshot)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Screenshot"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 720, height: 300)
        super.init(window: window)
        window.delegate = self

        canvas.onStyleChange = { [weak self] in self?.updateToolbar() }
        canvas.onCropChange = { [weak self] in self?.zoomToFit() }

        buildLayout(in: window)
        sizeWindow(for: screenshot)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeFirstResponder(canvas)
    }

    // MARK: Layout

    private func buildLayout(in window: NSWindow) {
        let toolbar = makeToolbar()
        let separator = NSBox()
        separator.boxType = .separator

        let clipView = CenteringClipView()
        scrollView.contentView = clipView
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 8
        zoomObservation = scrollView.observe(\.magnification, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.window?.invalidateCursorRects(for: self.canvas)
            }
        }
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.drawsBackground = true

        let content = NSView()
        for view in [toolbar, separator, scrollView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            separator.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
    }

    private func makeToolbar() -> NSView {
        let images = Tool.allCases.map {
            NSImage(systemSymbolName: $0.symbolName, accessibilityDescription: $0.title) ?? NSImage()
        }
        toolControl = NSSegmentedControl(images: images, trackingMode: .selectOne,
                                         target: self, action: #selector(toolChanged(_:)))
        for tool in Tool.allCases {
            toolControl.setToolTip("\(tool.title) (\(tool.key.uppercased()))", forSegment: tool.rawValue)
        }
        toolControl.selectedSegment = canvas.tool.rawValue

        colorWell.color = canvas.color
        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))
        colorWell.toolTip = "Color"

        let sizes = NSSegmentedControl(labels: ["S", "M", "L"], trackingMode: .selectOne,
                                       target: self, action: #selector(sizeChanged(_:)))
        sizes.selectedSegment = lineWidths.firstIndex(of: canvas.lineWidth) ?? 1
        sizes.toolTip = "Line width"
        strokeSizes = sizes
        textSizes = NSSegmentedControl(labels: ["18", "26", "42"], trackingMode: .selectOne,
                                       target: self, action: #selector(textSizeChanged(_:)))
        textSizes.toolTip = "Text size"
        textSizes.setAccessibilityLabel("Text size")
        sizes.setAccessibilityLabel("Line width")

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let save = NSButton(title: "Save", target: self, action: #selector(saveImage(_:)))
        save.toolTip = "Save to \(Settings.shared.saveFolder.path) (⌘S)"
        let copy = NSButton(title: "Copy", target: self, action: #selector(copy(_:)))
        copy.toolTip = "Copy to clipboard (⌘C)"
        let done = NSButton(title: "Done", target: self, action: #selector(done(_:)))
        done.bezelColor = .controlAccentColor
        done.toolTip = "\(Settings.shared.editorDoneAction.title) and close (Return)"

        let stack = NSStackView(views: [toolControl, colorWell, sizes, textSizes, spacer, save, copy, done])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        updateToolbar()
        return stack
    }

    private func updateToolbar() {
        guard toolControl != nil, textSizes != nil else { return }
        toolControl.selectedSegment = canvas.tool.rawValue
        let propertiesTool = canvas.propertiesTool
        colorWell.color = canvas.color
        textSizes.isHidden = propertiesTool != .text
        textSizes.selectedSegment = fontSizes.firstIndex(of: canvas.textFontSize) ?? -1
        strokeSizes.isHidden = ![Tool.arrow, .rectangle, .ellipse, .pen, .highlight].contains(propertiesTool)
        strokeSizes.toolTip = propertiesTool == .highlight ? "Marker width" : "Line width"
        strokeSizes.setAccessibilityLabel(strokeSizes.toolTip)
        strokeSizes.selectedSegment = propertiesTool == .highlight
            ? markerWidths.firstIndex(of: canvas.markerWidth) ?? -1
            : lineWidths.firstIndex(of: canvas.lineWidth) ?? -1
        colorWell.isHidden = [.select, .crop, .pixelate].contains(propertiesTool)
    }

    @objc private func textSizeChanged(_ sender: NSSegmentedControl) {
        guard fontSizes.indices.contains(sender.selectedSegment) else { return }
        canvas.textFontSize = fontSizes[sender.selectedSegment]
        canvas.focus()
    }

    private func sizeWindow(for screenshot: Screenshot) {
        guard let window, let screen = NSScreen.underMouse else { return }
        let visible = screen.visibleFrame
        let chrome = window.frameRect(forContentRect: .zero).height + 46 // title bar + toolbar
        let available = NSSize(width: visible.width * 0.9, height: visible.height * 0.9 - chrome)
        let size = screenshot.pointSize
        let magnification = min(1, available.width / size.width, available.height / size.height)
        let contentSize = NSSize(width: max(size.width * magnification + 2, window.contentMinSize.width),
                                 height: max(size.height * magnification + 46, window.contentMinSize.height))
        window.setContentSize(contentSize)
        scrollView.magnification = magnification
        let frame = window.frame
        window.setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2))
    }

    private func zoomToFit() {
        let available = scrollView.contentSize
        let size = canvas.frame.size
        guard size.width > 0, size.height > 0 else { return }
        scrollView.magnification = min(1, available.width / size.width, available.height / size.height)
    }

    // MARK: Actions

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        if let tool = Tool(rawValue: sender.selectedSegment) { canvas.tool = tool }
        window?.makeFirstResponder(canvas)
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        canvas.color = sender.color
    }

    @objc private func sizeChanged(_ sender: NSSegmentedControl) {
        guard lineWidths.indices.contains(sender.selectedSegment) else { return }
        if canvas.propertiesTool == .highlight { canvas.markerWidth = markerWidths[sender.selectedSegment] }
        else { canvas.lineWidth = lineWidths[sender.selectedSegment] }
        window?.makeFirstResponder(canvas)
    }

    /// The Copy button and ⌘C, which reaches here from the canvas via the responder chain.
    @objc func copy(_ sender: Any?) {
        Output.export(canvas.renderScreenshot(), copy: true, save: false)
        exportedChangeCount = canvas.changeCount
        window?.makeFirstResponder(canvas)
    }

    @objc func saveImage(_ sender: Any?) {
        if Output.export(canvas.renderScreenshot(), copy: false, save: true) {
            exportedChangeCount = canvas.changeCount
        }
        window?.makeFirstResponder(canvas)
    }

    @objc func saveImageAs(_ sender: Any?) {
        guard let window else { return }
        let shot = canvas.renderScreenshot()
        let changeCount = canvas.changeCount
        let settings = Settings.shared
        let format = settings.imageFormat
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.directoryURL = settings.saveFolder
        panel.nameFieldStringValue = "Screenshot.\(format.fileExtension)"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Output.write(shot, to: url, format: format)
                self?.exportedChangeCount = changeCount
                Toast.show("Saved \(url.lastPathComponent)")
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    @objc func done(_ sender: Any?) {
        let action = Settings.shared.editorDoneAction
        let succeeded = Output.export(canvas.renderScreenshot(), copy: action.copies, save: action.saves)
        // Copying still happened if only saving failed.
        if succeeded || action.copies { exportedChangeCount = canvas.changeCount }
        if succeeded { close() }
    }

    /// Esc, ⌘W and the close button come here; Done exports first and closes directly.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender.attachedSheet == nil else { return false }
        guard Settings.shared.confirmBeforeClosing, hasUnexportedChanges() else { return true }
        let alert = Self.makeCloseAlert(screenshots: 1)
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            if alert.suppressionButton?.state == .on { Settings.shared.confirmBeforeClosing = false }
            self?.close()
        }
        return false
    }

    /// Asks whether to close editors whose screenshot hasn't been copied or saved.
    /// The first button closes; the suppression checkbox means "Don't ask again".
    static func makeCloseAlert(screenshots: Int) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = screenshots == 1 ? "Close this screenshot?" : "Close \(screenshots) screenshots?"
        alert.informativeText = (screenshots == 1 ? "It hasn't" : "They haven't")
            + " been copied or saved and will be lost. You can turn this confirmation back on in Settings."
        let close = alert.addButton(withTitle: "Close")
        close.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        return alert
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }
}

/// Keeps the document centered when it is smaller than the visible area.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let size = documentView.frame.size
        if rect.width > size.width { rect.origin.x = (size.width - rect.width) / 2 }
        if rect.height > size.height { rect.origin.y = (size.height - rect.height) / 2 }
        return rect
    }
}
