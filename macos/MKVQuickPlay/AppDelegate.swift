import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {

    // UI Controllers
    private var statusBarController: StatusBarController!
    private var hotkeyManager: HotkeyManager!
    private var finderSelectionManager: FinderSelectionManager!

    // Preview state
    private var currentPreviewURL: URL?

    // Flag to prevent selection monitoring from reopening after close
    private var justClosed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[MKVQuickPlay] App launched")

        // Initialize components
        statusBarController = StatusBarController()
        hotkeyManager = HotkeyManager()
        finderSelectionManager = FinderSelectionManager()

        // Setup callbacks
        setupCallbacks()

        // Start hotkey monitoring
        hotkeyManager.start()

        // Setup mpv close callback
        MPVLauncher.shared.onClose = { [weak self] in
            self?.currentPreviewURL = nil
            self?.statusBarController.setActive(false)
            self?.hotkeyManager.isPreviewActive = false
        }

        NSLog("[MKVQuickPlay] Ready - Control+Space to preview")
    }

    private func setupCallbacks() {
        // Status bar preview action
        statusBarController.onPreviewSelected = { [weak self] in
            self?.previewSelectedVideo()
        }

        // Control+Space hotkey - toggle behavior
        hotkeyManager.onHotkeyPressed = { [weak self] in
            if MPVLauncher.shared.isPlaying {
                self?.closePreview()
            } else {
                self?.previewSelectedVideo()
            }
        }

        // Arrow key navigation (Up = previous, Down = next)
        hotkeyManager.onUpArrowPressed = { [weak self] in
            self?.navigateToPreviousVideo()
        }

        hotkeyManager.onDownArrowPressed = { [weak self] in
            self?.navigateToNextVideo()
        }

        // Escape to close preview
        hotkeyManager.onEscapePressed = { [weak self] in
            self?.closePreview()
        }
    }

    // MARK: - Preview Actions

    private func previewSelectedVideo() {
        // Only trigger if Finder is frontmost
        guard finderSelectionManager.isFinderFrontmost() else { return }

        guard let videoURL = finderSelectionManager.getSelectedVideoFile() else {
            return
        }

        playVideo(url: videoURL)
    }

    private func navigateToNextVideo() {
        guard let currentURL = currentPreviewURL else { return }

        if let nextURL = finderSelectionManager.getNextVideoFile(after: currentURL) {
            playVideo(url: nextURL)
        }
    }

    private func navigateToPreviousVideo() {
        guard let currentURL = currentPreviewURL else { return }

        if let prevURL = finderSelectionManager.getPreviousVideoFile(before: currentURL) {
            playVideo(url: prevURL)
        }
    }

    private func closePreview() {
        justClosed = true
        MPVLauncher.shared.stop()
        currentPreviewURL = nil
        statusBarController.setActive(false)
        hotkeyManager.isPreviewActive = false

        // Clear the flag after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.justClosed = false
        }
    }

    // MARK: - Application Lifecycle

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.stop()
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

    private func playVideo(url: URL) {
        currentPreviewURL = url
        MPVLauncher.shared.play(url: url)
        statusBarController.setActive(true)
        hotkeyManager.isPreviewActive = true
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
