import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {

    // UI Controllers
    private var statusBarController: StatusBarController!
    private var finderSelectionManager: FinderSelectionManager!

    // Preview state
    private var currentPreviewURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize components
        statusBarController = StatusBarController()
        finderSelectionManager = FinderSelectionManager()

        // Register as the service provider for Finder > Services
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        // Setup status bar callback
        statusBarController.onHelpRequested = { [weak self] in
            self?.showServiceHint()
        }

        // Setup mpv close callback with exit code
        MPVLauncher.shared.onClose = { [weak self] exitCode in
            self?.handleMPVClose(exitCode: exitCode)
        }

        NSLog("[MKVQuickPlay] Ready - use Finder > Services > Preview with MKVQuickPlay (Cmd+Shift+V)")
    }

    // MARK: - NSServices Handler

    @objc(previewVideo:userData:error:)
    func previewVideo(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        // Read file URLs from pasteboard
        if let urls = pboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], let url = urls.first {
            DispatchQueue.main.async { [weak self] in
                self?.handleServiceInvocation(with: url)
            }
        } else if let filenames = pboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String],
                  let first = filenames.first {
            // Legacy fallback
            let url = URL(fileURLWithPath: first)
            DispatchQueue.main.async { [weak self] in
                self?.handleServiceInvocation(with: url)
            }
        } else {
            error.pointee = "No files found in selection." as NSString
        }
    }

    // MARK: - Service Handling

    private func handleServiceInvocation(with url: URL) {
        if MPVLauncher.shared.isPlaying {
            if url == currentPreviewURL {
                closePreview()
            } else {
                playVideo(url: url)
            }
        } else {
            playVideo(url: url)
        }
    }

    // MARK: - MPV Exit Code Handling

    private func handleMPVClose(exitCode: Int32) {
        switch exitCode {
        case 2:
            navigateToNextVideo()
        case 3:
            navigateToPreviousVideo()
        default:
            currentPreviewURL = nil
            statusBarController.setActive(false)
        }
    }

    // MARK: - Navigation

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
        MPVLauncher.shared.stop()
        currentPreviewURL = nil
        statusBarController.setActive(false)
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

    private func playVideo(url: URL) {
        currentPreviewURL = url
        MPVLauncher.shared.play(url: url)
        statusBarController.setActive(true)
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
