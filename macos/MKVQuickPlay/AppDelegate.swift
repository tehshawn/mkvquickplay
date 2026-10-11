import Cocoa
import KeyboardShortcuts
import Sparkle
import UserNotifications

extension KeyboardShortcuts.Name {
    /// Global hotkey to preview the current Finder selection. User-recordable
    /// via the menu; works even when the Services shortcut is flaky.
    static let previewSelectedVideo = Self("previewSelectedVideo", initial: .init(.v, modifiers: [.command, .shift]))

    /// The user's current shortcut as macOS shows it ("⇧⌘V"), or nil once
    /// the user cleared it with the recorder's ✕. Never falls back to the
    /// hardcoded default: `init(_:initial:)` persists that on first launch,
    /// so a nil here really means nothing is bound.
    @MainActor var displayString: String? {
        KeyboardShortcuts.getShortcut(for: self)?.description
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {

    /// How long Finder needs to finish activating before focus returns to mpv
    /// (fallback path only — see `followInFinder`).
    private static let finderRefocusDelay: TimeInterval = 0.15

    /// A reveal that fails later than this (Finder's `with timeout`, an
    /// unanswered Automation prompt, the 30 s osascript kill) must not
    /// activate Finder and re-activate mpv long after the keypress — the
    /// user may have moved to another app by then.
    private static let finderFallbackMaxDelay: TimeInterval = 2.0

    // UI Controllers
    private var statusBarController: StatusBarController!
    private var finderSelectionManager: FinderSelectionManager!

    /// Watches user-chosen folders for newly arrived videos (menu-configured).
    private var watchFolderManager: WatchFolderManager!

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

    /// Bumped on every same-session playlist mutation (trash, undo), so the
    /// async Finder-sort refinement — whose snapshot predates the mutation —
    /// is discarded instead of resurrecting a trashed file or clobbering an
    /// undo re-insert. `sessionID` alone can't catch these: it only changes
    /// when a session starts or ends.
    private var playlistEpoch = 0

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

    /// URLs from application(_:open:) that arrived before launch finished —
    /// on a cold launch-by-open AppKit delivers them *before*
    /// applicationDidFinishLaunching, when the controllers are still nil.
    private var pendingOpenURLs: [URL] = []
    private var didFinishLaunching = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize components
        statusBarController = StatusBarController()
        statusBarController.refreshHotkeyText()
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

        // Watch folders: menu wiring + arrival notifications.
        watchFolderManager = WatchFolderManager(isVideoFile: { [weak self] url in
            self?.finderSelectionManager.isVideoFile(url) ?? false
        })
        statusBarController.watchFolderListProvider = { [weak self] in
            self?.watchFolderManager.folders ?? []
        }
        statusBarController.onAddWatchFolder = { [weak self] in
            self?.addWatchFolderViaPanel()
        }
        statusBarController.onRemoveWatchFolder = { [weak self] path in
            self?.watchFolderManager.removeFolder(path: path)
        }
        statusBarController.onReviewNewVideos = { [weak self] in
            self?.reviewPendingNewVideos()
        }
        watchFolderManager.onPendingChanged = { [weak self] count in
            self?.statusBarController.setPendingReviewCount(count)
        }
        watchFolderManager.onBatchReady = { [weak self] count in
            self?.statusBarController.setPendingReviewCount(count)
            self?.postNewVideosNotification(count: count)
        }
        statusBarController.setPendingReviewCount(watchFolderManager.pendingCount)

        // Notification plumbing for the "N new videos" banner. Authorization
        // is requested only when the user adds their first watch folder.
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = self
        let reviewAction = UNNotificationAction(identifier: Self.reviewActionID,
                                                title: "Review", options: [])
        notificationCenter.setNotificationCategories([
            UNNotificationCategory(identifier: Self.newVideosCategoryID,
                                   actions: [reviewAction], intentIdentifiers: []),
        ])

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

        // Handle the Trash key from mpv. The Delete-key safety gate lives
        // here, not in trashCurrentAndAdvance(): the explicit Trash *intent*
        // bypasses it on purpose (invoking "move to the Trash" by name is
        // not an accidental keypress).
        MPVLauncher.shared.onTrash = { [weak self] in
            guard let self = self, self.statusBarController.isTrashEnabled else { return }
            self.trashCurrentAndAdvance()
        }

        // Handle the Undo (Cmd+Z) key from mpv.
        MPVLauncher.shared.onUndo = { [weak self] in
            self?.undoLastTrash()
        }

        // Handle the tag key (P) from mpv.
        MPVLauncher.shared.onTagToggle = { [weak self] in
            self?.togglePurpleTag()
        }

        didFinishLaunching = true
        // Replay any launch-by-open URLs buffered by application(_:open:) —
        // everything above (controllers, mpv callbacks) is only now wired.
        if !pendingOpenURLs.isEmpty {
            let urls = pendingOpenURLs
            pendingOpenURLs = []
            handleServiceInvocation(with: urls, allowToggle: false)
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
    private var selectionFetchFailedHintShown = false

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
                } else if !denied && !self.selectionFetchFailedHintShown {
                    // A transient failure used to stay quiet forever — the
                    // hotkey just looked dead. Explain once per run.
                    self.selectionFetchFailedHintShown = true
                    self.showSelectionFetchFailedHint()
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
        if alert.runModalInFront() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showSelectionFetchFailedHint() {
        let alert = NSAlert()
        alert.messageText = "Couldn't Read the Finder Selection"
        alert.informativeText = """
        Finder didn't answer in time. Try the shortcut again, or use right-click > Services > Preview with MKVQuickPlay, which works without querying Finder.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModalInFront()
    }

    // MARK: - Service Handling

    private func handleServiceInvocation(with urls: [URL], allowToggle: Bool = true,
                                         forceNewSession: Bool = false) {
        // Selected videos, in pasteboard order.
        let selected = urls.filter { finderSelectionManager.isVideoFile($0) }
        guard let invoked = selected.first else { return }

        let selectionKeys = Set(selected.map { finderSelectionManager.normalizedPath($0) })

        // Re-triggering the shortcut on the same selection — or on just the
        // file currently playing — toggles the preview closed. A different
        // selection (even one containing the current file) starts a new session.
        if !forceNewSession, MPVLauncher.shared.isPlaying, let current = currentPreviewURL {
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

        // A new session: drop symlink resolutions cached for the previous one.
        finderSelectionManager.resetPathCache()

        // Start playback immediately with a provisional (alphabetical) playlist…
        let provisional: [URL]
        let startURL: URL
        if selected.count > 1 {
            provisional = finderSelectionManager.sortedVideoFiles(from: selected)
            startURL = provisional.first ?? invoked
        } else {
            // A hidden or symlinked video is excluded from its own folder
            // listing — without it in the playlist, navigation finds no
            // index for the playing file (arrows dead) and trash-advance
            // sees no successor (Delete closes the whole preview).
            var siblings = finderSelectionManager.getSiblingVideoFiles(for: invoked)
            if finderSelectionManager.index(of: invoked, in: siblings) == nil {
                let name = invoked.lastPathComponent
                let at = siblings.firstIndex {
                    $0.lastPathComponent.localizedStandardCompare(name) == .orderedDescending
                } ?? siblings.count
                siblings.insert(invoked, at: at)
            }
            provisional = siblings
            startURL = invoked
        }

        // Invalidate player keypresses read before this switch — see
        // MPVLauncher.inputEpoch (the IPC generation can't see same-window
        // loadfile-replace switches).
        MPVLauncher.shared.bumpInputEpoch()
        sessionID += 1
        let session = sessionID
        navigationPlaylist = provisional
        currentSelectionKeys = selectionKeys
        playVideo(url: startURL)
        guard currentPreviewURL != nil else { return } // launch failed

        // …then refine to Finder's displayed sort order off the main thread,
        // so a slow Finder query (or the one-time Automation consent prompt)
        // never delays the video or stalls keyboard navigation.
        let epoch = playlistEpoch
        finderSelectionManager.orderedVideoFiles(inFolderOf: invoked) { [weak self] folderOrder in
            guard let self = self, self.sessionID == session else { return }
            // The playlist mutated since this refinement was captured (a
            // trash or an undo) — applying the pre-mutation snapshot would
            // resurrect the trashed file or wipe out the undo re-insert.
            guard self.playlistEpoch == epoch else { return }
            guard let folderOrder = folderOrder, !folderOrder.isEmpty else { return }
            let key = self.finderSelectionManager.normalizedPath
            if selected.count > 1 {
                // The folder order only covers the invoked file's folder; a
                // selection spanning folders (search results, a tag view)
                // keeps its provisional order rather than shrinking to the
                // subset that happens to live there.
                let invokedDir = key(invoked.deletingLastPathComponent())
                guard selected.allSatisfy({ key($0.deletingLastPathComponent()) == invokedDir }) else { return }
                let scoped = folderOrder.filter { selectionKeys.contains(key($0)) }
                // Hidden files and symlinks aren't in the folder listing;
                // keep them (provisional order) rather than dropping them —
                // one of them may be the file that is playing.
                let covered = Set(scoped.map(key))
                self.navigationPlaylist = scoped + provisional.filter { !covered.contains(key($0)) }
            } else if folderOrder.contains(where: { key($0) == key(invoked) }) {
                self.navigationPlaylist = folderOrder
            } else {
                // Same hidden/symlink guard as the provisional list above.
                self.navigationPlaylist = folderOrder + [invoked]
            }
        }
    }

    /// The ordered list of videos navigation should move through.
    private func currentPlaylist(for url: URL) -> [URL] {
        return navigationPlaylist ?? finderSelectionManager.getSiblingVideoFiles(for: url)
    }

    // MARK: - Navigation

    /// Returns whether the preview moved (false at the end of the playlist
    /// or with no live player) — the keyboard path ignores it; intents don't.
    @discardableResult
    private func navigateToNextVideo() -> Bool {
        guard let currentURL = currentPreviewURL else { return false }
        let playlist = currentPlaylist(for: currentURL)
        guard let nextURL = finderSelectionManager.nextFile(after: currentURL, in: playlist) else {
            // Already at the last video — stay put (QuickLook-style), no wrap.
            return false
        }
        return navigate(to: nextURL, in: playlist)
    }

    @discardableResult
    private func navigateToPreviousVideo() -> Bool {
        guard let currentURL = currentPreviewURL else { return false }
        let playlist = currentPlaylist(for: currentURL)
        guard let prevURL = finderSelectionManager.previousFile(before: currentURL, in: playlist) else {
            // Already at the first video — stay put, no wrap.
            return false
        }
        return navigate(to: prevURL, in: playlist)
    }

    /// Step the existing mpv window to another file. Never relaunches mpv:
    /// if the player is gone (user closed it a beat ago), the request is
    /// dropped and the termination handler cleans up state.
    @discardableResult
    private func navigate(to url: URL, in playlist: [URL]) -> Bool {
        guard MPVLauncher.shared.load(url: url) else { return false }
        currentPreviewURL = url
        // The invoking selection no longer describes what's playing, so it
        // must not match a later re-invocation as a "toggle closed".
        currentSelectionKeys = nil
        statusBarController.setCurrentFile(url)
        followInFinder(url)
        showPositionOSD(for: url, in: playlist)
        return true
    }

    /// Move the Finder highlight to follow the playing video.
    ///
    /// Finder is asked to `reveal` the file over the Automation channel with
    /// no `activate`, so the mpv window never loses keyboard focus. The old
    /// approach — activate Finder via NSWorkspace, then ask macOS to hand
    /// focus back to mpv 150 ms later — depends on an activation request
    /// that a Dock-less background app can't guarantee under macOS 14+ (and
    /// that macOS 26/27 declines more often); when it was declined, every
    /// following arrow key went to Finder instead of the player. That path
    /// is kept only as the fallback for when Finder can't be scripted.
    private func followInFinder(_ url: URL) {
        let requested = Date()
        finderSelectionManager.revealInFinder(url) { [weak self] revealed in
            guard let self = self, !revealed else { return }
            // Fallback — only if the answer is fresh and this file is still
            // the one playing.
            guard Date().timeIntervalSince(requested) < Self.finderFallbackMaxDelay,
                  let current = self.currentPreviewURL,
                  self.finderSelectionManager.normalizedPath(current) == self.finderSelectionManager.normalizedPath(url)
            else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.finderRefocusDelay) {
                MPVLauncher.shared.activateWindow()
            }
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
        MPVLauncher.shared.bumpInputEpoch()
        statusBarController.setActive(false)
        statusBarController.setCurrentFile(nil)
    }

    // MARK: - Trash & Reveal

    /// Moves the playing file to the Trash and advances. The Delete-key
    /// safety gate lives at the key-callback site; this core is ungated so
    /// the explicit Trash intent can call it. Returns whether the file was
    /// actually trashed.
    @discardableResult
    private func trashCurrentAndAdvance() -> Bool {
        guard let current = currentPreviewURL else { return false }

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
            return false
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
        playlistEpoch += 1 // invalidate any in-flight sort refinement

        if let successor,
           finderSelectionManager.normalizedPath(successor) != finderSelectionManager.normalizedPath(current),
           MPVLauncher.shared.load(url: successor) {
            currentPreviewURL = successor
            currentSelectionKeys = nil // playing file diverged from the invoking selection
            statusBarController.setCurrentFile(successor)
            followInFinder(successor)
            MPVLauncher.shared.showText("Moved to Trash\n\(current.lastPathComponent)")
        } else {
            // No successor, or the player is already gone — close the preview.
            closePreview()
        }
        return true
    }

    /// Feedback for an explicit user action: on the mpv OSD while a player
    /// is open, otherwise (menu action with no preview) an alert — an OSD
    /// command with no player is silently dropped.
    private func notifyUser(_ text: String) {
        if MPVLauncher.shared.isPlaying {
            MPVLauncher.shared.showText(text)
        } else {
            let alert = NSAlert()
            alert.messageText = "Undo Move to Trash"
            alert.informativeText = text.replacingOccurrences(of: "\n", with: " ")
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModalInFront()
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
            notifyUser("Undo unavailable — file is no longer in the Trash")
            return
        }

        // Likewise if the folder it came from is gone (renamed, deleted, or
        // on a volume that was ejected): nothing can ever restore it there,
        // and keeping the entry would block every older undo behind it.
        let originalFolder = entry.original.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: originalFolder.path) else {
            undoStack.removeLast()
            statusBarController.setLastTrashedName(undoStack.last?.original.lastPathComponent)
            notifyUser("Undo unavailable — original folder is gone (file left in Trash)")
            NSLog("[MKVQuickPlay] Undo skipped: \(originalFolder.path) no longer exists")
            return
        }

        do {
            try FileManager.default.moveItem(at: entry.trashed, to: entry.original)
        } catch {
            // Destination occupied or volume error — keep the entry so the
            // user can resolve the conflict and retry.
            notifyUser("Couldn't restore file")
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

        playlistEpoch += 1 // invalidate any in-flight sort refinement

        // Reopen the restored file (relaunching mpv here is intentional —
        // undo should work even after the preview was closed). The OSD is
        // queued until the player's control channel is up if it had to relaunch.
        playVideo(url: entry.original, revealInFinder: true)
        // The restored file replaced whatever the invoking selection
        // described — a later re-invocation on that unchanged selection
        // must not read as a "toggle closed" (same invariant as
        // navigate(to:) and trashCurrentAndAdvance()).
        currentSelectionKeys = nil
        MPVLauncher.shared.showText("Restored\n\(entry.original.lastPathComponent)")
    }

    /// Menu action: the user explicitly wants to see the file in Finder, so
    /// here activating Finder is the point.
    private func revealCurrentInFinder() {
        guard let current = currentPreviewURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([current])
    }

    // MARK: - Tagging

    /// Toggle the Purple Finder tag on the playing video — mark keepers
    /// during a culling pass without interrupting playback. Other tags on
    /// the file are preserved.
    /// Returns whether the file is now tagged, or nil when the toggle failed.
    @discardableResult
    private func togglePurpleTag() -> Bool? {
        guard let url = currentPreviewURL else { return nil }

        do {
            let existing = (try url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
            let newTags: [String]
            let confirmation: String
            let nowTagged: Bool
            if existing.contains("Purple") {
                newTags = existing.filter { $0 != "Purple" }
                confirmation = "Purple tag removed"
                nowTagged = false
            } else {
                newTags = existing + ["Purple"]
                confirmation = "Tagged Purple"
                nowTagged = true
            }
            // NSURL API: the Swift URLResourceValues.tagNames *setter* is
            // annotated macOS 26+, but this equivalent has existed since 10.9.
            try (url as NSURL).setResourceValue(newTags as NSArray, forKey: .tagNamesKey)
            MPVLauncher.shared.showText(confirmation)
            return nowTagged
        } catch {
            MPVLauncher.shared.showText("Couldn't change tag")
            NSLog("[MKVQuickPlay] Tag toggle failed for \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    private func showServiceHint() {
        // KeyboardShortcuts' API is MainActor-isolated; this runs from the
        // status menu, i.e. on the main thread.
        let shortcut = MainActor.assumeIsolated { KeyboardShortcuts.Name.previewSelectedVideo.displayString }
        let hotkeyLine = shortcut.map { "Press \($0), or" }
            ?? "Set a shortcut with \"Set Keyboard Shortcut…\" in this menu, or"
        let alert = NSAlert()
        alert.messageText = "How to Preview Videos"
        alert.informativeText = """
        Select a video file in Finder, then:

        \u{2022} \(hotkeyLine)
        \u{2022} Use Finder > Services > Preview with MKVQuickPlay

        While previewing:
        \u{2022} Down arrow: Next video
        \u{2022} Up arrow: Previous video
        \u{2022} P: Toggle Purple tag
        \u{2022} Delete: Move to Trash (when enabled in the menu)
        \u{2022} Cmd+Z: Undo Move to Trash
        \u{2022} Escape or Q: Close preview
        \u{2022} Space: Pause/Resume
        \u{2022} Left/Right: Seek
        \u{2022} M: Mute/unmute
        \u{2022} F: Toggle full screen

        To change the shortcut, use "Set Keyboard Shortcut…" in this menu.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModalInFront()
    }

    // MARK: - Watch Folders

    static let newVideosCategoryID = "mkvqp.newvideos"
    static let reviewActionID = "mkvqp.review"

    private func addWatchFolderViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Watch"
        panel.message = "New videos arriving in the chosen folders will be offered for review."
        // Same dance as NSAlert.runModalInFront(): a Dock-less app must ask
        // for activation or the panel opens behind everything.
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        panel.level = .floating
        let response = panel.runModal()
        if MPVLauncher.shared.isPlaying { MPVLauncher.shared.activateWindow() }
        guard response == .OK else { return }
        for url in panel.urls { watchFolderManager.addFolder(url) }
        requestNotificationAuthorizationOnce()
    }

    private func requestNotificationAuthorizationOnce() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if !granted {
                NSLog("[MKVQuickPlay] Notifications declined — new-video batches appear in the menu bar only")
            }
        }
    }

    private func postNewVideosNotification(count: Int) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = count == 1 ? "1 new video to review" : "\(count) new videos to review"
            content.body = "Click to step through the new arrivals, or use the menu bar icon."
            content.categoryIdentifier = Self.newVideosCategoryID
            // A fixed identifier coalesces: a growing batch replaces the one
            // notification instead of stacking a new banner per settle.
            center.add(UNNotificationRequest(identifier: Self.newVideosCategoryID,
                                             content: content, trigger: nil))
        }
    }

    /// Start a review session over everything the watch folders collected.
    private func reviewPendingNewVideos() {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [Self.newVideosCategoryID])
        let batch = watchFolderManager.takePendingReview()
        guard !batch.isEmpty else { return }
        if !startBatchReview(batch) {
            // mpv failed to start, or every file vanished — don't burn the
            // batch; put it back so the badge and a later click still work.
            watchFolderManager.restorePending(batch)
        }
    }

    /// A session over an explicit list of files (watch-folder arrivals).
    /// The batch is the authority on membership, so the Finder-sort
    /// refinement deliberately does not run. Returns whether playback started.
    @discardableResult
    private func startBatchReview(_ urls: [URL]) -> Bool {
        let videos = urls
            .filter { finderSelectionManager.isVideoFile($0) && FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard let first = videos.first else { return false }
        finderSelectionManager.resetPathCache()
        MPVLauncher.shared.bumpInputEpoch()
        sessionID += 1
        playlistEpoch += 1
        navigationPlaylist = videos
        currentSelectionKeys = nil
        playVideo(url: first, revealInFinder: true)
        guard currentPreviewURL != nil else { return false }
        if videos.count > 1 {
            showPositionOSD(for: first, in: videos)
        }
        return true
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
        //
        // On a cold launch-by-open this arrives *before*
        // applicationDidFinishLaunching (documented AppKit ordering), when
        // the controllers are still nil and the mpv callbacks unwired —
        // buffer the URLs and let applicationDidFinishLaunching replay them.
        guard didFinishLaunching else {
            pendingOpenURLs.append(contentsOf: urls)
            return
        }
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
            followInFinder(url)
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

// MARK: - Watch-folder notifications

extension AppDelegate: UNUserNotificationCenterDelegate {

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.content.categoryIdentifier == Self.newVideosCategoryID {
            DispatchQueue.main.async { self.reviewPendingNewVideos() }
        }
        completionHandler()
    }

    /// Menu-bar apps are rarely "active", but show banners regardless —
    /// there is no app window the user could be looking at instead.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}

// MARK: - Intent facade

/// The programmatic surface the App Intents call into
/// (MKVQuickPlayIntents.swift). Main-thread only by contract — every intent
/// `perform()` is @MainActor. Intents never toggle-close a preview: every
/// path here passes `allowToggle: false`.
extension AppDelegate {

    enum IntentNavigation {
        case moved(String)
        case atEnd
        case atStart
    }

    private var hasActiveSession: Bool {
        currentPreviewURL != nil && MPVLauncher.shared.isPlaying
    }

    /// The current Finder selection, over the same Apple Events channel as
    /// the global hotkey (requires the Automation permission).
    func intentFinderSelection() async throws -> [URL] {
        try await withCheckedThrowingContinuation { continuation in
            finderSelectionManager.fetchFinderSelection { urls, denied in
                if let urls = urls {
                    continuation.resume(returning: urls)
                } else {
                    continuation.resume(throwing: denied ? MKVQPIntentError.automationDenied
                                                         : MKVQPIntentError.selectionUnavailable)
                }
            }
        }
    }

    /// Preview `urls` (non-videos are filtered out). Returns the video count.
    func intentPreview(urls: [URL]) throws -> Int {
        let videos = urls.filter { finderSelectionManager.isVideoFile($0) }
        guard !videos.isEmpty else { throw MKVQPIntentError.noVideosSelected }
        handleServiceInvocation(with: videos, allowToggle: false)
        guard currentPreviewURL != nil else { throw MKVQPIntentError.launchFailed }
        return videos.count
    }

    func intentNavigate(forward: Bool) throws -> IntentNavigation {
        guard hasActiveSession, let current = currentPreviewURL else {
            throw MKVQPIntentError.noActiveSession
        }
        // Distinguish "at the boundary" from "player not commandable" —
        // reporting at-end for a dead control channel would be a lie.
        let playlist = currentPlaylist(for: current)
        let target = forward ? finderSelectionManager.nextFile(after: current, in: playlist)
                             : finderSelectionManager.previousFile(before: current, in: playlist)
        guard let target = target else { return forward ? .atEnd : .atStart }
        guard navigate(to: target, in: playlist), let now = currentPreviewURL else {
            throw MKVQPIntentError.noActiveSession
        }
        return .moved(now.lastPathComponent)
    }

    /// Trash the playing file (bypasses the Delete-key safety on purpose —
    /// see the onTrash wiring). Returns the trashed file's name.
    func intentTrashCurrent() throws -> String {
        guard hasActiveSession, let current = currentPreviewURL else {
            throw MKVQPIntentError.noActiveSession
        }
        let name = current.lastPathComponent
        guard trashCurrentAndAdvance() else { throw MKVQPIntentError.trashFailed }
        return name
    }

    /// Returns whether the playing file is now tagged Purple.
    func intentTogglePurpleTag() throws -> Bool {
        guard hasActiveSession else { throw MKVQPIntentError.noActiveSession }
        guard let tagged = togglePurpleTag() else { throw MKVQPIntentError.tagFailed }
        return tagged
    }

    /// Returns whether a preview was open (and is now closed).
    func intentStopPreview() -> Bool {
        guard MPVLauncher.shared.isPlaying else { return false }
        closePreview()
        return true
    }

    /// Review every video in `folder`, in Finder's displayed order when a
    /// window shows it (the whole single-file session pipeline is reused:
    /// provisional alphabetical playlist + async Finder-sort refinement).
    /// Returns the video count.
    func intentReviewFolder(_ folder: URL) throws -> Int {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw MKVQPIntentError.notAFolder }
        let videos = finderSelectionManager.videoFiles(inDirectory: folder)
        guard let first = videos.first else { throw MKVQPIntentError.noVideosInFolder }
        // forceNewSession: if the folder's first video happens to be the one
        // already playing, the same-selection branch would just surface the
        // window, keep the OLD playlist, and this intent would claim a
        // review it never started.
        handleServiceInvocation(with: [first], allowToggle: false, forceNewSession: true)
        guard currentPreviewURL != nil else { throw MKVQPIntentError.launchFailed }
        return videos.count
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
