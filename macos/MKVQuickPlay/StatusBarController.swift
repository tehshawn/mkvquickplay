import Cocoa
import ServiceManagement

/// Manages the menu bar status item
class StatusBarController {

    private var statusItem: NSStatusItem?
    private var nowPlayingItem: NSMenuItem?
    private var revealItem: NSMenuItem?
    private var trashItem: NSMenuItem?
    private var loginItem: NSMenuItem?

    private var undoItem: NSMenuItem?

    var onHelpRequested: (() -> Void)?
    var onRevealRequested: (() -> Void)?
    var onUndoRequested: (() -> Void)?

    private let trashEnabledKey = "mkvqp.trashEnabled"

    /// Whether the Delete key should move the playing file to the Trash.
    var isTrashEnabled: Bool {
        UserDefaults.standard.bool(forKey: trashEnabledKey)
    }

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
            button.toolTip = "MKV QuickPlay - Cmd+Shift+V to preview"
        }

        statusItem?.menu = createMenu()
    }

    private func createMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let hotkeyItem = NSMenuItem(title: "Select video in Finder, press Cmd+Shift+V", action: nil, keyEquivalent: "")
        hotkeyItem.isEnabled = false
        menu.addItem(hotkeyItem)

        let navItem = NSMenuItem(title: "Up/Down to navigate, Esc to close", action: nil, keyEquivalent: "")
        navItem.isEnabled = false
        menu.addItem(navItem)

        menu.addItem(NSMenuItem.separator())

        let nowPlaying = NSMenuItem(title: "Not playing", action: nil, keyEquivalent: "")
        nowPlaying.isEnabled = false
        menu.addItem(nowPlaying)
        nowPlayingItem = nowPlaying

        let reveal = NSMenuItem(title: "Reveal in Finder", action: #selector(revealAction), keyEquivalent: "")
        reveal.target = self
        reveal.isEnabled = false
        menu.addItem(reveal)
        revealItem = reveal

        menu.addItem(NSMenuItem.separator())

        let trash = NSMenuItem(title: "Move to Trash with Delete Key", action: #selector(toggleTrashAction), keyEquivalent: "")
        trash.target = self
        trash.state = isTrashEnabled ? .on : .off
        menu.addItem(trash)
        trashItem = trash

        let undo = NSMenuItem(title: "Undo Move to Trash", action: #selector(undoAction), keyEquivalent: "z")
        undo.keyEquivalentModifierMask = [.command]
        undo.target = self
        undo.isEnabled = false
        menu.addItem(undo)
        undoItem = undo

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLoginAction), keyEquivalent: "")
        login.target = self
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)
        loginItem = login

        menu.addItem(NSMenuItem.separator())

        let helpItem = NSMenuItem(title: "How to Use...", action: #selector(showHelpAction), keyEquivalent: "")
        helpItem.target = self
        menu.addItem(helpItem)

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

    @objc private func revealAction() {
        onRevealRequested?()
    }

    @objc private func undoAction() {
        onUndoRequested?()
    }

    /// Enable/label the Undo item based on the most recently trashed file.
    func setLastTrashedName(_ name: String?) {
        if let name = name {
            undoItem?.title = "Undo Move to Trash (\(name))"
            undoItem?.isEnabled = true
        } else {
            undoItem?.title = "Undo Move to Trash"
            undoItem?.isEnabled = false
        }
    }

    @objc private func toggleTrashAction() {
        let newValue = !isTrashEnabled
        UserDefaults.standard.set(newValue, forKey: trashEnabledKey)
        trashItem?.state = newValue ? .on : .off
    }

    @objc private func toggleLoginAction() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("[MKVQuickPlay] Launch at Login toggle failed: \(error)")
        }
        loginItem?.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    @objc private func showHelpAction() {
        onHelpRequested?()
    }

    @objc private func showAbout() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"

        var updatedLine = ""
        if let execURL = Bundle.main.executableURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: execURL.path),
           let modified = attrs[.modificationDate] as? Date {
            let formatter = DateFormatter()
            formatter.dateStyle = .long
            formatter.timeStyle = .none
            updatedLine = "\nLast updated: \(formatter.string(from: modified))"
        }

        let alert = NSAlert()
        alert.messageText = "MKV QuickPlay"
        alert.informativeText = """
        Version \(version) (build \(build))\(updatedLine)

        Quick video preview for macOS.

        Cmd+Shift+V: Preview selected video
        Up/Down arrows: Navigate videos
        Delete: Move to Trash (when enabled)
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

    /// Update the "now playing" line and enable/disable "Reveal in Finder".
    func setCurrentFile(_ url: URL?) {
        if let url = url {
            nowPlayingItem?.title = "▶ \(url.lastPathComponent)"
            revealItem?.isEnabled = true
        } else {
            nowPlayingItem?.title = "Not playing"
            revealItem?.isEnabled = false
        }
    }
}
