import Cocoa

/// Launches mpv for video playback
class MPVLauncher {

    static let shared = MPVLauncher()

    private var mpvProcess: Process?
    private var currentFile: URL?

    var onClose: (() -> Void)?

    private init() {}

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

    func play(url: URL) {
        stop()

        guard let mpvPath = findMPV() else {
            showMPVNotFoundAlert()
            return
        }

        currentFile = url

        let process = Process()
        process.executableURL = URL(fileURLWithPath: mpvPath)
        process.arguments = [
            "--hwdec=auto",
            "--keep-open=yes",
            "--osc=yes",
            "--osd-level=1",
            "--autofit=80%",
            "--auto-window-resize=yes",
            "--title=\(url.lastPathComponent)",
            "--force-window=immediate",
            "--input-default-bindings=no",
            "--input-vo-keyboard=no",
            url.path
        ]

        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                if self?.mpvProcess?.processIdentifier == proc.processIdentifier {
                    self?.mpvProcess = nil
                    self?.currentFile = nil
                    self?.onClose?()
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
