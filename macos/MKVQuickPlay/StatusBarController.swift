import Cocoa
import KeyboardShortcuts
import ServiceManagement

/// Manages the menu bar status item
class StatusBarController: NSObject, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    private var nowPlayingItem: NSMenuItem?
    private var revealItem: NSMenuItem?
    private var trashItem: NSMenuItem?
    private var loginItem: NSMenuItem?

    private var undoItem: NSMenuItem?
    private var updateAvailableItem: NSMenuItem?

    var onHelpRequested: (() -> Void)?
    var onRevealRequested: (() -> Void)?
    var onUndoRequested: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?

    private let trashEnabledKey = "mkvqp.trashEnabled"

    /// Whether the Delete key should move the playing file to the Trash.
    var isTrashEnabled: Bool {
        UserDefaults.standard.bool(forKey: trashEnabledKey)
    }

    override init() {
        super.init()
        setupStatusItem()
    }

    /// Refresh stateful items each time the menu opens — Launch at Login can
    /// be toggled behind our back in System Settings, and the checkmark must
    /// reflect reality or the toggle acts opposite to its label.
    func menuWillOpen(_ menu: NSMenu) {
        loginItem?.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        trashItem?.state = isTrashEnabled ? .on : .off
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = Self.makeMenuBarIcon()
            button.toolTip = "MKV QuickPlay - Cmd+Shift+V to preview"
        }

        statusItem?.menu = createMenu()
    }

    /// Template-image version of the app's "stack" icon: a back card peeking
    /// above a front card with a play triangle. Drawn at runtime so it stays
    /// crisp at any scale and matches the app icon without shipping assets.
    private static func makeMenuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            // Back card, clipped so only its top peeks above the front card.
            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 18, height: 5.0)).addClip()
            let stub = NSBezierPath(roundedRect: NSRect(x: 3.75, y: 2, width: 10.5, height: 8),
                                    xRadius: 2, yRadius: 2)
            stub.lineWidth = 1.5
            stub.stroke()
            NSGraphicsContext.current?.restoreGraphicsState()

            // Front card.
            let card = NSBezierPath(roundedRect: NSRect(x: 2, y: 5.5, width: 14, height: 11),
                                    xRadius: 2.5, yRadius: 2.5)
            card.lineWidth = 1.5
            card.stroke()

            // Play triangle.
            let tri = NSBezierPath()
            tri.move(to: NSPoint(x: 7.5, y: 8.5))
            tri.line(to: NSPoint(x: 7.5, y: 13.5))
            tri.line(to: NSPoint(x: 12, y: 11))
            tri.close()
            tri.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MKV QuickPlay"
        return image
    }

    private func createMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        // Hidden until Sparkle finds a scheduled update (gentle reminder for
        // a Dock-less app whose update alerts would otherwise appear unseen).
        let updateAvail = NSMenuItem(title: "Update Available…", action: #selector(checkForUpdatesAction), keyEquivalent: "")
        updateAvail.target = self
        updateAvail.isHidden = true
        menu.addItem(updateAvail)
        updateAvailableItem = updateAvail

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

        // No keyEquivalent: a status-menu shortcut only fires while the menu
        // is open, so showing "⌘Z" would falsely advertise a global shortcut.
        // (Cmd+Z works inside the mpv window via the input.conf binding.)
        let undo = NSMenuItem(title: "Undo Move to Trash", action: #selector(undoAction), keyEquivalent: "")
        undo.target = self
        undo.isEnabled = false
        menu.addItem(undo)
        undoItem = undo

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLoginAction), keyEquivalent: "")
        login.target = self
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)
        loginItem = login

        let shortcutItem = NSMenuItem(title: "Set Keyboard Shortcut…", action: #selector(setShortcutAction), keyEquivalent: "")
        shortcutItem.target = self
        menu.addItem(shortcutItem)

        menu.addItem(NSMenuItem.separator())

        let updatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdatesAction), keyEquivalent: "")
        updatesItem.target = self
        menu.addItem(updatesItem)

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

    @objc private func checkForUpdatesAction() {
        onCheckForUpdates?()
    }

    /// Lightweight shortcut recorder: an alert hosting the KeyboardShortcuts
    /// recorder field — no settings window needed for a one-setting app.
    @objc private func setShortcutAction() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        let recorder = KeyboardShortcuts.RecorderCocoa(for: .previewSelectedVideo)
        recorder.frame = NSRect(x: 0, y: 0, width: 180, height: 26)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 32))
        recorder.setFrameOrigin(NSPoint(x: 20, y: 3))
        container.addSubview(recorder)

        let alert = NSAlert()
        alert.messageText = "Preview Shortcut"
        alert.informativeText = "Press the key combination to use for previewing the selected Finder video. Click the ✕ in the field to clear it."
        alert.accessoryView = container
        alert.addButton(withTitle: "Done")
        alert.window.level = .floating

        // Don't let the still-armed global hotkey fire mid-dialog, and give
        // the recorder key focus. The focus hop must be async: RecorderCocoa
        // blocks becoming key until the next main-queue turn.
        KeyboardShortcuts.disable(.previewSelectedVideo)
        DispatchQueue.main.async { [weak alert] in
            alert?.window.makeFirstResponder(recorder)
        }
        alert.runModal()
        KeyboardShortcuts.enable(.previewSelectedVideo)
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
        P: Toggle Purple tag
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

    /// Show/hide the gentle "Update Available…" reminder in the menu.
    func setUpdateAvailable(_ version: String?) {
        if let version = version {
            updateAvailableItem?.title = "Update Available (\(version))…"
            updateAvailableItem?.isHidden = false
        } else {
            updateAvailableItem?.isHidden = true
        }
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
