import Cocoa

/// Manages the menu bar status item
class StatusBarController {

    private var statusItem: NSStatusItem?

    var onPreviewSelected: (() -> Void)?

    init() {
        setupStatusItem()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            if let image = NSImage(systemSymbolName: "play.rectangle.fill", accessibilityDescription: "MKV QuickPlay") {
                image.isTemplate = true
                button.image = image
            }
            button.toolTip = "MKV QuickPlay - Control+Space to preview"
        }

        statusItem?.menu = createMenu()
    }

    private func createMenu() -> NSMenu {
        let menu = NSMenu()

        let hotkeyItem = NSMenuItem(title: "Control+Space to preview video", action: nil, keyEquivalent: "")
        hotkeyItem.isEnabled = false
        menu.addItem(hotkeyItem)

        let navItem = NSMenuItem(title: "Up/Down arrows to navigate", action: nil, keyEquivalent: "")
        navItem.isEnabled = false
        menu.addItem(navItem)

        menu.addItem(NSMenuItem.separator())

        let previewItem = NSMenuItem(title: "Preview Selected Video", action: #selector(previewSelectedAction), keyEquivalent: " ")
        previewItem.keyEquivalentModifierMask = .control
        previewItem.target = self
        menu.addItem(previewItem)

        menu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(title: "About MKV QuickPlay", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func previewSelectedAction() {
        onPreviewSelected?()
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "MKV QuickPlay"
        alert.informativeText = """
        Quick video preview for macOS.

        Control+Space: Preview selected video
        Up/Down arrows: Navigate videos
        Escape: Close preview

        Requires mpv: brew install mpv
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    func setActive(_ active: Bool) {
        statusItem?.button?.contentTintColor = active ? .systemBlue : nil
    }
}
