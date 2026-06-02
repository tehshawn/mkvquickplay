import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {

    // UI Controllers
    private var statusBarController: StatusBarController!
    private var finderSelectionManager: FinderSelectionManager!

    // Preview state
    private var currentPreviewURL: URL?

    /// The ordered list of videos navigation steps through, captured when the
    /// preview is invoked. For a single-file selection this is the whole folder
    /// in Finder's displayed order; for a multi-file selection it's that subset.
    private var navigationPlaylist: [URL]?

    /// A file moved to the Trash, remembered so it can be restored with Undo.
    private struct TrashedItem {
        let original: URL
        let trashed: URL
        let playlistIndex: Int?
    }
    private var undoStack: [TrashedItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize components
        statusBarController = StatusBarController()
        finderSelectionManager = FinderSelectionManager()

        // Register as the service provider for Finder > Services
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

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

    // MARK: - Service Handling

    private func handleServiceInvocation(with urls: [URL]) {
        // Selected videos, in pasteboard order (used for the toggle check).
        let selected = urls.filter { finderSelectionManager.isVideoFile($0) }
        guard let invoked = selected.first else { return }

        // Re-triggering on a file (or selection) we're already previewing
        // toggles it closed.
        if MPVLauncher.shared.isPlaying,
           let current = currentPreviewURL,
           finderSelectionManager.index(of: current, in: selected) != nil {
            closePreview()
            return
        }

        // Try to capture the folder's videos in Finder's displayed sort order;
        // fall back to alphabetical if Finder can't be queried.
        let folderOrder = finderSelectionManager.orderedVideoFiles(inFolderOf: invoked)

        let playlist: [URL]
        let startURL: URL
        if selected.count > 1 {
            // Multi-file selection: cycle just that subset, in Finder order if known.
            if let folderOrder = folderOrder {
                let selectedPaths = Set(selected.map { finderSelectionManager.normalizedPath($0) })
                playlist = folderOrder.filter { selectedPaths.contains(finderSelectionManager.normalizedPath($0)) }
            } else {
                playlist = finderSelectionManager.sortedVideoFiles(from: selected)
            }
            startURL = playlist.first ?? invoked
        } else {
            // Single selection: walk the whole folder.
            startURL = invoked
            playlist = (folderOrder?.isEmpty == false ? folderOrder! : finderSelectionManager.getSiblingVideoFiles(for: invoked))
        }

        navigationPlaylist = playlist
        playVideo(url: startURL)
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
        playVideo(url: nextURL, revealInFinder: true)
        showPositionOSD(for: nextURL, in: playlist)
    }

    private func navigateToPreviousVideo() {
        guard let currentURL = currentPreviewURL else { return }
        let playlist = currentPlaylist(for: currentURL)
        guard let prevURL = finderSelectionManager.previousFile(before: currentURL, in: playlist) else {
            // Already at the first video — stay put, no wrap.
            return
        }
        playVideo(url: prevURL, revealInFinder: true)
        showPositionOSD(for: prevURL, in: playlist)
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
            undoStack.append(TrashedItem(original: current, trashed: trashed, playlistIndex: removalIndex))
            statusBarController.setLastTrashedName(current.lastPathComponent)
        }

        // Drop the trashed file from the cached playlist.
        if var playlist = navigationPlaylist {
            let trashed = finderSelectionManager.normalizedPath(current)
            playlist.removeAll { finderSelectionManager.normalizedPath($0) == trashed }
            navigationPlaylist = playlist.isEmpty ? nil : playlist
        }

        if let successor, finderSelectionManager.normalizedPath(successor) != finderSelectionManager.normalizedPath(current) {
            playVideo(url: successor, revealInFinder: true)
            MPVLauncher.shared.showText("Moved to Trash\n\(current.lastPathComponent)")
        } else {
            // Was the only remaining video — close the preview.
            closePreview()
        }
    }

    /// Restore the most recently trashed file and reopen it.
    private func undoLastTrash() {
        guard let entry = undoStack.last else { return }

        do {
            try FileManager.default.moveItem(at: entry.trashed, to: entry.original)
        } catch {
            MPVLauncher.shared.showText("Couldn't restore file")
            NSLog("[MKVQuickPlay] Undo restore failed for \(entry.original.lastPathComponent): \(error)")
            return
        }

        undoStack.removeLast()
        statusBarController.setLastTrashedName(undoStack.last?.original.lastPathComponent)

        // Put the file back into the playlist at its original position.
        var playlist = navigationPlaylist ?? []
        let insertAt = min(max(entry.playlistIndex ?? playlist.count, 0), playlist.count)
        if finderSelectionManager.index(of: entry.original, in: playlist) == nil {
            playlist.insert(entry.original, at: insertAt)
        }
        navigationPlaylist = playlist

        // Reopen the restored file (relaunches mpv if the preview had closed).
        playVideo(url: entry.original, revealInFinder: true)
        MPVLauncher.shared.showText("Restored\n\(entry.original.lastPathComponent)")
    }

    private func revealCurrentInFinder() {
        guard let current = currentPreviewURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([current])
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
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - File Opening ("Open With" support)

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        playVideo(url: URL(fileURLWithPath: filename))
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if let filename = filenames.first {
            playVideo(url: URL(fileURLWithPath: filename))
            NSApp.reply(toOpenOrPrint: .success)
        } else {
            NSApp.reply(toOpenOrPrint: .failure)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first {
            playVideo(url: url)
        }
    }

    private func playVideo(url: URL, revealInFinder: Bool = false) {
        guard finderSelectionManager.isVideoFile(url) else {
            NSLog("[MKVQuickPlay] Ignoring unsupported file: \(url.lastPathComponent)")
            return
        }

        currentPreviewURL = url
        MPVLauncher.shared.play(url: url)
        statusBarController.setActive(true)
        statusBarController.setCurrentFile(url)

        if revealInFinder {
            // Move the Finder highlight to follow the playing video, then
            // return focus to mpv so keyboard navigation keeps working.
            NSWorkspace.shared.activateFileViewerSelecting([url])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                MPVLauncher.shared.activateWindow()
            }
        }
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
