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
    private var hotkeyItem: NSMenuItem?
    private var reviewNewItem: NSMenuItem?
    private var watchFoldersMenu: NSMenu?

    var onHelpRequested: (() -> Void)?
    var onRevealRequested: (() -> Void)?
    var onUndoRequested: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onReviewNewVideos: (() -> Void)?
    var onAddWatchFolder: (() -> Void)?
    var onRemoveWatchFolder: ((String) -> Void)?
    /// Supplies the watch-folder rows for the submenu rebuild in menuWillOpen.
    var watchFolderListProvider: (() -> [(name: String, path: String, active: Bool)])?

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
        refreshHotkeyText()
        rebuildWatchFoldersMenu()
    }

    /// Show the shortcut the user actually has, not the factory default:
    /// in the menu hint and the status-item tooltip. Main thread only
    /// (KeyboardShortcuts' API is MainActor-isolated).
    func refreshHotkeyText() {
        let shortcut = MainActor.assumeIsolated { KeyboardShortcuts.Name.previewSelectedVideo.displayString }
        hotkeyItem?.title = shortcut.map { "Select video in Finder, press \($0)" }
            ?? "Select video in Finder (no preview shortcut set)"
        statusItem?.button?.toolTip = shortcut.map { "MKV QuickPlay - \($0) to preview" } ?? "MKV QuickPlay"
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = Self.makeMenuBarIcon()
            button.toolTip = "MKV QuickPlay"
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

        // Hidden until watched folders collect new arrivals.
        let reviewNew = NSMenuItem(title: "Review New Videos…", action: #selector(reviewNewAction), keyEquivalent: "")
        reviewNew.target = self
        reviewNew.isHidden = true
        menu.addItem(reviewNew)
        reviewNewItem = reviewNew

        // Hidden until Sparkle finds a scheduled update (gentle reminder for
        // a Dock-less app whose update alerts would otherwise appear unseen).
        let updateAvail = NSMenuItem(title: "Update Available…", action: #selector(checkForUpdatesAction), keyEquivalent: "")
        updateAvail.target = self
        updateAvail.isHidden = true
        menu.addItem(updateAvail)
        updateAvailableItem = updateAvail

        let hotkey = NSMenuItem(title: "Select video in Finder, press the preview shortcut", action: nil, keyEquivalent: "")
        hotkey.isEnabled = false
        menu.addItem(hotkey)
        hotkeyItem = hotkey

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

        let watch = NSMenuItem(title: "Watch Folders", action: nil, keyEquivalent: "")
        let watchMenu = NSMenu()
        watchMenu.autoenablesItems = false
        watch.submenu = watchMenu
        menu.addItem(watch)
        watchFoldersMenu = watchMenu

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
    @MainActor @objc private func setShortcutAction() {
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

        // Don't let the still-armed global hotkey fire mid-dialog, and give
        // the recorder key focus. The focus hop must be async: RecorderCocoa
        // blocks becoming key until the next main-queue turn.
        KeyboardShortcuts.disable(.previewSelectedVideo)
        DispatchQueue.main.async { [weak alert] in
            alert?.window.makeFirstResponder(recorder)
        }
        alert.runModalInFront()
        KeyboardShortcuts.enable(.previewSelectedVideo)
        refreshHotkeyText()
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

    @objc private func reviewNewAction() {
        onReviewNewVideos?()
    }

    @objc private func addWatchFolderAction() {
        onAddWatchFolder?()
    }

    @objc private func removeWatchFolderAction(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? String {
            onRemoveWatchFolder?(path)
        }
    }

    /// The submenu is data-driven and cheap, so it is rebuilt on every open.
    private func rebuildWatchFoldersMenu() {
        guard let menu = watchFoldersMenu else { return }
        menu.removeAllItems()
        let add = NSMenuItem(title: "Add Folder…", action: #selector(addWatchFolderAction), keyEquivalent: "")
        add.target = self
        menu.addItem(add)
        let folders = watchFolderListProvider?() ?? []
        guard !folders.isEmpty else { return }
        menu.addItem(NSMenuItem.separator())
        for folder in folders {
            let item = NSMenuItem(title: folder.active ? folder.name : "\(folder.name) (unavailable)",
                                  action: nil, keyEquivalent: "")
            item.toolTip = folder.path
            let sub = NSMenu()
            sub.autoenablesItems = false
            let remove = NSMenuItem(title: "Stop Watching", action: #selector(removeWatchFolderAction(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = folder.path
            sub.addItem(remove)
            item.submenu = sub
            menu.addItem(item)
        }
    }

    /// Badge the status icon and surface the "Review N New Videos…" item.
    func setPendingReviewCount(_ count: Int) {
        reviewNewItem?.isHidden = (count == 0)
        reviewNewItem?.title = count == 1 ? "Review 1 New Video…" : "Review \(count) New Videos…"
        guard let item = statusItem, let button = item.button else { return }
        if count > 0 {
            item.length = NSStatusItem.variableLength
            button.imagePosition = .imageLeft
            button.title = "\(count)"
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
            item.length = NSStatusItem.squareLength
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
        let shortcut = MainActor.assumeIsolated { KeyboardShortcuts.Name.previewSelectedVideo.displayString } ?? "No shortcut set"
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

        \(shortcut): Preview selected video
        Up/Down arrows: Navigate videos
        P: Toggle Purple tag
        Delete: Move to Trash (when enabled)
        Cmd+Z: Undo Move to Trash
        Escape: Close preview

        Requires mpv: brew install mpv
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModalInFront()
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

// MARK: - Alerts from a Dock-less app

extension NSAlert {
    /// Run the alert from a Dock-less (LSUIElement) app. Such an app is never
    /// frontmost, so a bare `runModal()` can open the panel behind the
    /// frontmost app's windows with no key focus — request activation first
    /// and keep the panel floating. Activation is only a request on macOS
    /// 14+, so the floating level is what keeps the alert visible if it is
    /// declined.
    @discardableResult
    func runModalInFront() -> NSApplication.ModalResponse {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.level = .floating
        let response = runModal()
        // Activating ourselves to host the alert took key focus away from
        // the mpv window — and a Dock-less app with zero windows would keep
        // it, swallowing every subsequent player key until the user clicks
        // the player. Hand focus back while we are still the active app
        // (the one situation where yieldActivation is guaranteed to count).
        if MPVLauncher.shared.isPlaying {
            MPVLauncher.shared.activateWindow()
        }
        return response
    }
}
