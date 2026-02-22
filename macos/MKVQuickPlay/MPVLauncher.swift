import Cocoa

/// Launches mpv for video playback
class MPVLauncher {

    static let shared = MPVLauncher()

    private var mpvProcess: Process?
    private var currentFile: URL?
    private var inputConfPath: String?

    /// Callback when mpv closes. Exit code: 0 = normal close, 2 = next video, 3 = previous video
    var onClose: ((Int32) -> Void)?

    private init() {
        inputConfPath = createInputConf()
    }

    private func findMPV() -> String? {
        let paths = [
            "/opt/homebrew/bin/mpv",
            "/usr/local/bin/mpv",
            "/Applications/mpv.app/Contents/MacOS/mpv",
        ]

        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Create a custom mpv input.conf for navigation via exit codes
    private func createInputConf() -> String {
        let tempDir = NSTemporaryDirectory()
        let path = (tempDir as NSString).appendingPathComponent("mkvquickplay-input.conf")

        let config = """
        DOWN quit 2
        UP quit 3
        ESC quit 0
        q quit 0
        SPACE cycle pause
        LEFT seek -5
        RIGHT seek 5
        m cycle mute
        f cycle fullscreen
        """

        try? config.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func play(url: URL) {
        stop()

        guard let mpvPath = findMPV() else {
            showMPVNotFoundAlert()
            return
        }

        currentFile = url

        let process = Process()
        process.executableURL = URL(fileURLWithPath: mpvPath)

        var args = [
            "--hwdec=auto",
            "--keep-open=yes",
            "--osc=yes",
            "--osd-level=1",
            "--autofit=80%",
            "--auto-window-resize=yes",
            "--title=\(url.lastPathComponent)",
            "--force-window=immediate",
            "--no-input-default-bindings",
            "--input-vo-keyboard=yes",
        ]

        if let confPath = inputConfPath {
            args.append("--input-conf=\(confPath)")
        }

        args.append(url.path)
        process.arguments = args

        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                if self?.mpvProcess?.processIdentifier == proc.processIdentifier {
                    let exitCode = proc.terminationStatus
                    self?.mpvProcess = nil
                    self?.currentFile = nil
                    self?.onClose?(exitCode)
                }
            }
        }

        do {
            try process.run()
            mpvProcess = process
        } catch {
            showLaunchErrorAlert(error: error)
        }
    }

    func stop() {
        guard let process = mpvProcess else { return }

        mpvProcess = nil
        currentFile = nil

        if process.isRunning {
            process.terminate()
            usleep(100_000)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    var isPlaying: Bool {
        mpvProcess?.isRunning ?? false
    }

    private func showMPVNotFoundAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "mpv Not Found"
            alert.informativeText = "MKV QuickPlay requires mpv to play videos.\n\nInstall using Homebrew:\nbrew install mpv"
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func showLaunchErrorAlert(error: Error) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Failed to Launch mpv"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
