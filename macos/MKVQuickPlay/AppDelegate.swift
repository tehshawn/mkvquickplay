import Cocoa
import KeyboardShortcuts
import Sparkle

extension KeyboardShortcuts.Name {
    /// Global hotkey to preview the current Finder selection. User-recordable
    /// via the menu; works even when the Services shortcut is flaky.
    static let previewSelectedVideo = Self("previewSelectedVideo", default: .init(.v, modifiers: [.command, .shift]))
}

class AppDelegate: NSObject, NSApplicationDelegate {

    /// How long Finder needs to finish activating before focus returns to mpv.
    private static let finderRefocusDelay: TimeInterval = 0.15

    // UI Controllers
    private var statusBarController: StatusBarController!
    private var finderSelectionManager: FinderSelectionManager!

    /// Sparkle auto-updater (checks the appcast on GitHub Pages).
    private var updaterController: SPUStandardUpdaterController!

    // Preview state
    private var currentPreviewURL: URL?

    /// The ordered list of videos navigation steps through, captured when the
    /// preview is invoked. For a single-file selection this is the whole folder
    /// in Finder's displayed order; for a multi-file selection it's that subset.
    private var navigationPlaylist: [URL]?

    /// Normalized paths of the Finder selection that started the current
    /// session — re-invoking the shortcut on the same selection toggles closed.
    private var currentSelectionKeys: Set<String>?

    /// Monotonic id so async Finder-sort results never apply to a newer session.
    private var sessionID = 0

    /// A file moved to the Trash, remembered so it can be restored with Undo.
    private struct TrashedItem {
        let original: URL
        let trashed: URL
        let playlistIndex: Int?
        /// Session the file was trashed in — an undo re-inserts into the
        /// playlist only while that same session is still live.
        let sessionID: Int
    }
    private var undoStack: [TrashedItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize components
        statusBarController = StatusBarController()
        finderSelectionManager = FinderSelectionManager()
        updaterController = SPUStandardUpdaterController(startingUpdater: true,
                                                         updaterDelegate: nil,
                                                         userDriverDelegate: self)

        // Register as the service provider for Finder > Services
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        // Global hotkey (default Cmd+Shift+V, recordable from the menu) —
        // more reliable than the Services shortcut, which stays as a
        // zero-permission fallback in Finder's right-click menu.
        KeyboardShortcuts.onKeyUp(for: .previewSelectedVideo) { [weak self] in
            self?.previewCurrentFinderSelection()
        }

        // Setup status bar callbacks
        statusBarController.onHelpRequested = { [weak self] in
            self?.showServiceHint()
        }
        statusBarController.onRevealRequested = { [weak self] in
            self?.revealCurrentInFinder()
        }
        statusBarController.onUndoRequested = { [weak self] in
            self?.undoLastTrash()
        }
        statusBarController.onCheckForUpdates = { [weak self] in
            self?.updaterController.checkForUpdates(nil)
        }

        // Update app state when mpv exits (window closed, Esc, or Q).
        MPVLauncher.shared.onClose = { [weak self] in
            self?.clearPreviewState()
        }

        // Handle arrow-key navigation requests from mpv.
        MPVLauncher.shared.onNavigate = { [weak self] delta in
            if delta > 0 {
                self?.navigateToNextVideo()
            } else {
                self?.navigateToPreviousVideo()
            }
        }

        // Handle the Trash key from mpv.
        MPVLauncher.shared.onTrash = { [weak self] in
            self?.trashCurrentAndAdvance()
        }

        // Handle the Undo (Cmd+Z) key from mpv.
        MPVLauncher.shared.onUndo = { [weak self] in
            self?.undoLastTrash()
        }

        // Handle the tag key (P) from mpv.
        MPVLauncher.shared.onTagToggle = { [weak self] in
            self?.togglePurpleTag()
        }

        NSLog("[MKVQuickPlay] Ready - use Finder > Services > Preview with MKVQuickPlay (Cmd+Shift+V)")
    }

    // MARK: - NSServices Handler

    @objc(previewVideo:userData:error:)
    func previewVideo(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        var urls: [URL] = []

        // Read file URLs from pasteboard
        if let objects = pboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL] {
            urls = objects
        } else if let filenames = pboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            // Legacy fallback
            urls = filenames.map { URL(fileURLWithPath: $0) }
        }

        guard !urls.isEmpty else {
            error.pointee = "No files found in selection." as NSString
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.handleServiceInvocation(with: urls)
        }
    }

    // MARK: - Global Hotkey

    /// Coalesce rapid hotkey presses: a queued duplicate completing right
    /// after the first would read as "same selection" and toggle-close the
    /// preview the first press just opened.
    private var selectionFetchInFlight = false
    private var automationDeniedHintShown = false

    /// Hotkey pressed: preview whatever is selected in Finder right now.
    /// Unlike the Service, the hotkey carries no pasteboard, so the selection
    /// is read from Finder over the same Apple Events channel as the sort query.
    private func previewCurrentFinderSelection() {
        guard !selectionFetchInFlight else { return }
        selectionFetchInFlight = true

        finderSelectionManager.fetchFinderSelection { [weak self] urls, denied in
            guard let self = self else { return }
            self.selectionFetchInFlight = false

            guard let urls = urls else {
                // The query failed — that is not "nothing selected", so never
                // toggle-close here. If the Automation permission was denied,
                // tell the user once; otherwise stay quiet (transient error).
                if denied && !self.automationDeniedHintShown {
                    self.automationDeniedHintShown = true
                    self.showAutomationDeniedHint()
                }
                return
            }

            let videos = urls.filter { self.finderSelectionManager.isVideoFile($0) }
            if !videos.isEmpty {
                self.handleServiceInvocation(with: videos)
            } else if MPVLauncher.shared.isPlaying {
                // Genuinely no video selected — treat the hotkey as a toggle.
                self.closePreview()
            }
        }
    }

    private func showAutomationDeniedHint() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        let alert = NSAlert()
        alert.messageText = "Finder Access Needed"
        alert.informativeText = """
        The keyboard shortcut reads your Finder selection, which requires the Automation permission.

        Enable it in System Settings > Privacy & Security > Automation > MKVQuickPlay > Finder.

        (The right-click Finder > Services menu keeps working without it.)
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "OK")
        alert.window.level = .floating
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Service Handling

    private func handleServiceInvocation(with urls: [URL], allowToggle: Bool = true) {
        // Selected videos, in pasteboard order.
        let selected = urls.filter { finderSelectionManager.isVideoFile($0) }
        guard let invoked = selected.first else { return }

        let selectionKeys = Set(selected.map { finderSelectionManager.normalizedPath($0) })

        // Re-triggering the shortcut on the same selection — or on just the
        // file currently playing — toggles the preview closed. A different
        // selection (even one containing the current file) starts a new session.
        if MPVLauncher.shared.isPlaying, let current = currentPreviewURL {
            let currentKey = finderSelectionManager.normalizedPath(current)
            if selectionKeys == currentSelectionKeys
                || (selected.count == 1 && selectionKeys.contains(currentKey)) {
                if allowToggle {
                    closePreview()
                } else {
                    // An explicit "open" of the playing file (Open With,
                    // double-click) should surface the player, never close it.
                    MPVLauncher.shared.activateWindow()
                }
                return
            }
        }

        // Start playback immediately with a provisional (alphabetical) playlist…
        let provisional: [URL]
        let startURL: URL
        if selected.count > 1 {
            provisional = finderSelectionManager.sortedVideoFiles(from: selected)
            startURL = provisional.first ?? invoked
        } else {
            let siblings = finderSelectionManager.getSiblingVideoFiles(for: invoked)
            provisional = siblings.isEmpty ? [invoked] : siblings
            startURL = invoked
        }

        sessionID += 1
        let session = sessionID
        navigationPlaylist = provisional
        currentSelectionKeys = selectionKeys
        playVideo(url: startURL)
        guard currentPreviewURL != nil else { return } // launch failed

        // …then refine to Finder's displayed sort order off the main thread,
        // so a slow Finder query (or the one-time Automation consent prompt)
        // never delays the video or stalls keyboard navigation.
        finderSelectionManager.orderedVideoFiles(inFolderOf: invoked) { [weak self] folderOrder in
            guard let self = self, self.sessionID == session else { return }
            guard let folderOrder = folderOrder, !folderOrder.isEmpty else { return }
            if selected.count > 1 {
                let scoped = folderOrder.filter { selectionKeys.contains(self.finderSelectionManager.normalizedPath($0)) }
                if !scoped.isEmpty { self.navigationPlaylist = scoped }
            } else {
                self.navigationPlaylist = folderOrder
            }
        }
    }

    /// The ordered list of videos navigation should move through.
    private func currentPlaylist(for url: URL) -> [URL] {
        return navigationPlaylist ?? finderSelectionManager.getSiblingVideoFiles(for: url)
    }

    // MARK: - Navigation

    private func navigateToNextVideo() {
        guard let currentURL = currentPreviewURL else { return }
        let playlist = currentPlaylist(for: currentURL)
        guard let nextURL = finderSelectionManager.nextFile(after: currentURL, in: playlist) else {
            // Already at the last video — stay put (QuickLook-style), no wrap.
            return
        }
        navigate(to: nextURL, in: playlist)
    }

    private func navigateToPreviousVideo() {
        guard let currentURL = currentPreviewURL else { return }
        let playlist = currentPlaylist(for: currentURL)
        guard let prevURL = finderSelectionManager.previousFile(before: currentURL, in: playlist) else {
            // Already at the first video — stay put, no wrap.
            return
        }
        navigate(to: prevURL, in: playlist)
    }

    /// Step the existing mpv window to another file. Never relaunches mpv:
    /// if the player is gone (user closed it a beat ago), the request is
    /// dropped and the termination handler cleans up state.
    private func navigate(to url: URL, in playlist: [URL]) {
        guard MPVLauncher.shared.load(url: url) else { return }
        currentPreviewURL = url
        // The invoking selection no longer describes what's playing, so it
        // must not match a later re-invocation as a "toggle closed".
        currentSelectionKeys = nil
        statusBarController.setCurrentFile(url)
        revealAndRefocus(url)
        showPositionOSD(for: url, in: playlist)
    }

    /// Move the Finder highlight to follow the playing video, then return
    /// focus to mpv so keyboard navigation keeps working.
    private func revealAndRefocus(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.finderRefocusDelay) {
            MPVLauncher.shared.activateWindow()
        }
    }

    /// Briefly overlay "filename  N/total" in the mpv window.
    private func showPositionOSD(for url: URL, in playlist: [URL]) {
        guard let idx = finderSelectionManager.index(of: url, in: playlist) else { return }
        MPVLauncher.shared.showText("\(url.lastPathComponent)\n\(idx + 1) / \(playlist.count)")
    }

    private func closePreview() {
        MPVLauncher.shared.stop()
        clearPreviewState()
    }

    private func clearPreviewState() {
        currentPreviewURL = nil
        navigationPlaylist = nil
        currentSelectionKeys = nil
        // Invalidate any in-flight Finder-sort refinement so a late result
        // can't repopulate the playlist after the preview closed.
        sessionID += 1
        statusBarController.setActive(false)
        statusBarController.setCurrentFile(nil)
    }

    // MARK: - Trash & Reveal

    private func trashCurrentAndAdvance() {
        guard statusBarController.isTrashEnabled, let current = currentPreviewURL else { return }

        let playlist = currentPlaylist(for: current)
        // Pick a successor before removing the current file from disk.
        let successor = finderSelectionManager.nextFile(after: current, in: playlist)
            ?? finderSelectionManager.previousFile(before: current, in: playlist)
        let removalIndex = finderSelectionManager.index(of: current, in: navigationPlaylist ?? playlist)

        var trashedNSURL: NSURL?
        do {
            try FileManager.default.trashItem(at: current, resultingItemURL: &trashedNSURL)
        } catch {
            MPVLauncher.shared.showText("Couldn't move to Trash")
            NSLog("[MKVQuickPlay] Trash failed for \(current.lastPathComponent): \(error)")
            return
        }

        // Remember it for Undo (only if we know where it landed in the Trash).
        if let trashed = trashedNSURL as URL? {
            undoStack.append(TrashedItem(original: current, trashed: trashed,
                                         playlistIndex: removalIndex, sessionID: sessionID))
            statusBarController.setLastTrashedName(current.lastPathComponent)
        }

        // Drop the trashed file from the cached playlist.
        if var remaining = navigationPlaylist {
            let trashedKey = finderSelectionManager.normalizedPath(current)
            remaining.removeAll { finderSelectionManager.normalizedPath($0) == trashedKey }
            navigationPlaylist = remaining.isEmpty ? nil : remaining
        }

        if let successor,
           finderSelectionManager.normalizedPath(successor) != finderSelectionManager.normalizedPath(current),
           MPVLauncher.shared.load(url: successor) {
            currentPreviewURL = successor
            currentSelectionKeys = nil // playing file diverged from the invoking selection
            statusBarController.setCurrentFile(successor)
            revealAndRefocus(successor)
            MPVLauncher.shared.showText("Moved to Trash\n\(current.lastPathComponent)")
        } else {
            // No successor, or the player is already gone — close the preview.
            closePreview()
        }
    }

    /// Restore the most recently trashed file and reopen it.
    private func undoLastTrash() {
        guard let entry = undoStack.last else { return }

        // If the trashed copy no longer exists (Trash emptied, volume gone),
        // the undo is impossible — drop the entry instead of wedging the stack.
        guard FileManager.default.fileExists(atPath: entry.trashed.path) else {
            undoStack.removeLast()
            statusBarController.setLastTrashedName(undoStack.last?.original.lastPathComponent)
            MPVLauncher.shared.showText("Undo unavailable — file is no longer in the Trash")
            return
        }

        do {
            try FileManager.default.moveItem(at: entry.trashed, to: entry.original)
        } catch {
            // Destination occupied or volume error — keep the entry so the
            // user can resolve the conflict and retry.
            MPVLauncher.shared.showText("Couldn't restore file")
            NSLog("[MKVQuickPlay] Undo restore failed for \(entry.original.lastPathComponent): \(error)")
            return
        }

        undoStack.removeLast()
        statusBarController.setLastTrashedName(undoStack.last?.original.lastPathComponent)

        // Re-insert only while the session the file was trashed from is still
        // live (same playlist lineage — works for cross-folder multi-selections
        // too); otherwise drop the cached playlist so navigation falls back to
        // the restored file's real siblings.
        if var playlist = navigationPlaylist, entry.sessionID == sessionID {
            if finderSelectionManager.index(of: entry.original, in: playlist) == nil {
                let insertAt = min(max(entry.playlistIndex ?? playlist.count, 0), playlist.count)
                playlist.insert(entry.original, at: insertAt)
            }
            navigationPlaylist = playlist
        } else {
            navigationPlaylist = nil
        }

        // Reopen the restored file (relaunching mpv here is intentional —
        // undo should work even after the preview was closed).
        playVideo(url: entry.original, revealInFinder: true)
        MPVLauncher.shared.showText("Restored\n\(entry.original.lastPathComponent)")
    }

    private func revealCurrentInFinder() {
        guard let current = currentPreviewURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([current])
    }

    // MARK: - Tagging

    /// Toggle the Purple Finder tag on the playing video — mark keepers
    /// during a culling pass without interrupting playback. Other tags on
    /// the file are preserved.
    private func togglePurpleTag() {
        guard let url = currentPreviewURL else { return }

        do {
            let existing = (try url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
            let newTags: [String]
            let confirmation: String
            if existing.contains("Purple") {
                newTags = existing.filter { $0 != "Purple" }
                confirmation = "Purple tag removed"
            } else {
                newTags = existing + ["Purple"]
                confirmation = "Tagged Purple"
            }
            // NSURL API: the Swift URLResourceValues.tagNames *setter* is
            // annotated macOS 26+, but this equivalent has existed since 10.9.
            try (url as NSURL).setResourceValue(newTags as NSArray, forKey: .tagNamesKey)
            MPVLauncher.shared.showText(confirmation)
        } catch {
            MPVLauncher.shared.showText("Couldn't change tag")
            NSLog("[MKVQuickPlay] Tag toggle failed for \(url.lastPathComponent): \(error)")
        }
    }

    private func showServiceHint() {
        let alert = NSAlert()
        alert.messageText = "How to Preview Videos"
        alert.informativeText = """
        Select a video file in Finder, then:

        \u{2022} Press Cmd+Shift+V, or
        \u{2022} Use Finder > Services > Preview with MKVQuickPlay

        While previewing:
        \u{2022} Down arrow: Next video
        \u{2022} Up arrow: Previous video
        \u{2022} P: Toggle Purple tag
        \u{2022} Escape or Q: Close preview
        \u{2022} Space: Pause/Resume
        \u{2022} Left/Right: Seek

        To customize the keyboard shortcut:
        System Settings > Keyboard > Keyboard Shortcuts > Services
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Application Lifecycle

    func applicationWillTerminate(_ notification: Notification) {
        MPVLauncher.shared.stop()
        // Async prefs flushes on the IPC queue never run once the process
        // exits — drain them synchronously so the last volume change sticks.
        MPVLauncher.shared.flushPrefsForTermination()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - File Opening ("Open With" support)

    func application(_ application: NSApplication, open urls: [URL]) {
        // Route through the same path as the Service so Open With gets a
        // proper navigation playlist — but an explicit "open" never toggles
        // the preview closed; it surfaces the player instead.
        handleServiceInvocation(with: urls, allowToggle: false)
    }

    private func playVideo(url: URL, revealInFinder: Bool = false) {
        guard finderSelectionManager.isVideoFile(url) else {
            NSLog("[MKVQuickPlay] Ignoring unsupported file: \(url.lastPathComponent)")
            return
        }

        // Only reflect "playing" in the UI once mpv actually started.
        guard MPVLauncher.shared.play(url: url) else {
            clearPreviewState()
            return
        }

        currentPreviewURL = url
        statusBarController.setActive(true)
        statusBarController.setCurrentFile(url)

        if revealInFinder {
            revealAndRefocus(url)
        }
    }
}

// MARK: - Sparkle Gentle Reminders

/// Dock-less (LSUIElement) apps get scheduled-update alerts shown *behind*
/// other windows, where nobody sees them. Instead, surface scheduled updates
/// as an "Update Available…" item in the status menu; user-initiated checks
/// still show Sparkle's normal UI.
extension AppDelegate: SPUStandardUserDriverDelegate {

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        // Only let Sparkle pop UI for a scheduled check when it would appear
        // in focus; otherwise we surface it gently in the menu bar.
        return immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !handleShowingUpdate {
            statusBarController.setUpdateAvailable(update.displayVersionString)
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        statusBarController.setUpdateAvailable(nil)
    }

    func standardUserDriverWillFinishUpdateSession() {
        statusBarController.setUpdateAvailable(nil)
    }
}

// Main entry point
@main
struct MKVQuickPlayApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
