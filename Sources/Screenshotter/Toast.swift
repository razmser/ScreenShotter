import AppKit

/// A small, non-interactive HUD that fades out on its own.
enum Toast {
    private static var panel: NSPanel?

    static func show(_ text: String) {
        panel?.orderOut(nil)

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: background.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -10),
        ])

        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.canHide = false // stay visible when the app hides itself to return focus
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = background

        let size = background.fittingSize
        let visible = (NSScreen.underMouse ?? NSScreen.main)?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.minY + 80,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        self.panel = panel

        Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard self.panel === panel else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                panel.animator().alphaValue = 0
            }
            panel.orderOut(nil)
            if self.panel === panel { self.panel = nil }
        }
    }
}
