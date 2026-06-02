import Cocoa

/// Launches and controls a single, persistent mpv window via its JSON IPC socket.
///
/// The window stays open for the whole preview session: navigating between
/// videos loads the next file into the same window (`loadfile … replace`)
/// instead of relaunching mpv. Arrow-key navigation is delivered back to the
/// app as `client-message` IPC events, so we decide whether a next/previous
/// file exists rather than letting mpv wrap around.
final class MPVLauncher {

    static let shared = MPVLauncher()

    private var mpvProcess: Process?
    private var inputConfPath: String?

    private let socketPath = "/tmp/mkvquickplay.sock"
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var readBuffer = Data()
    private let ioQueue = DispatchQueue(label: "com.mkvquickplay.ipc")

    /// Called on the main thread when mpv fully exits (window closed / quit).
    var onClose: (() -> Void)?

    /// Called on the main thread when the user requests navigation while a
    /// video is playing. `delta` is +1 for next, -1 for previous.
    var onNavigate: ((Int) -> Void)?

    /// Called on the main thread when the user presses the Trash key.
    var onTrash: (() -> Void)?

    /// Called on the main thread when the user presses Undo (Cmd+Z).
    var onUndo: (() -> Void)?

    // Persisted playback preferences.
    private let volumeKey = "mkvqp.volume"
    private let muteKey = "mkvqp.mute"

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

    /// Custom mpv key bindings. Navigation keys emit `script-message` events
    /// that reach us over IPC; everything else is handled by mpv directly.
    private func createInputConf() -> String {
        let tempDir = NSTemporaryDirectory()
        let path = (tempDir as NSString).appendingPathComponent("mkvquickplay-input.conf")

        let config = """
        DOWN script-message mkvqp-next
        UP script-message mkvqp-prev
        BS script-message mkvqp-trash
        DEL script-message mkvqp-trash
        Meta+z script-message mkvqp-undo
        ESC quit
        q quit
        SPACE cycle pause
        LEFT seek -5
        RIGHT seek 5
        m cycle mute
        f cycle fullscreen
        """

        try? config.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    var isPlaying: Bool {
        mpvProcess?.isRunning ?? false
    }

    /// Preview a video: load it into the running window, or launch mpv if idle.
    func play(url: URL) {
        if isPlaying {
            sendCommand(["loadfile", url.path, "replace"])
        } else {
            launch(url: url)
        }
    }

    private func launch(url: URL) {
        guard let mpvPath = findMPV() else {
            showMPVNotFoundAlert()
            return
        }

        // Clear any stale socket from a previous (crashed) session.
        unlink(socketPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: mpvPath)

        var args = [
            "--hwdec=auto",
            "--keep-open=yes",
            "--osc=yes",
            "--osd-level=1",
            // Play at the video's native pixel dimensions; only shrink the
            // window if the video is larger than 90% of the screen.
            "--autofit-larger=90%x90%",
            "--auto-window-resize=yes",
            // Window title follows whichever file is currently loaded.
            "--title=${filename}",
            "--force-window=immediate",
            "--no-input-default-bindings",
            "--input-vo-keyboard=yes",
            "--input-ipc-server=\(socketPath)",
        ]

        // Restore the last-used volume / mute state.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: volumeKey) != nil {
            let volume = defaults.double(forKey: volumeKey)
            args.append("--volume=\(Int(volume.rounded()))")
        }
        if defaults.bool(forKey: muteKey) {
            args.append("--mute=yes")
        }

        if let confPath = inputConfPath {
            args.append("--input-conf=\(confPath)")
        }

        args.append(url.path)
        process.arguments = args

        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Ignore the stale handler if a newer process has taken over.
                if self.mpvProcess?.processIdentifier == proc.processIdentifier {
                    self.teardownSocket()
                    self.mpvProcess = nil
                    self.onClose?()
                }
            }
        }

        do {
            try process.run()
            mpvProcess = process
            connectSocket()
        } catch {
            showLaunchErrorAlert(error: error)
        }
    }

    func stop() {
        guard let process = mpvProcess else { return }

        mpvProcess = nil
        teardownSocket()

        if process.isRunning {
            process.terminate()
            // Escalate to SIGKILL if it doesn't exit promptly, without
            // blocking the main thread.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.1) {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
    }

    /// Bring the mpv window to the front so it keeps receiving keyboard input.
    func activateWindow() {
        guard let pid = mpvProcess?.processIdentifier else { return }
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps])
    }

    // MARK: - IPC

    private func connectSocket() {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            // mpv needs a moment to create the socket after launch; retry briefly.
            for _ in 0..<60 {
                if let fd = self.makeConnectedSocket() {
                    self.socketFD = fd
                    self.startReading(fd: fd)
                    // Track volume / mute so we can persist them for next time.
                    self.sendCommand(["observe_property", 1, "volume"])
                    self.sendCommand(["observe_property", 2, "mute"])
                    return
                }
                usleep(50_000) // 50ms × 60 ≈ 3s
            }
            NSLog("[MKVQuickPlay] Could not connect to mpv IPC socket; navigation disabled this session")
        }
    }

    private func makeConnectedSocket() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = socketPath.utf8CString // includes trailing NUL
        if pathBytes.count > maxLen {
            close(fd)
            return nil
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dst in
                pathBytes.withUnsafeBufferPointer { src in
                    dst.update(from: src.baseAddress!, count: src.count)
                }
            }
        }

        let connResult = withUnsafePointer(to: &addr) { aptr -> Int32 in
            aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                connect(fd, sptr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connResult != 0 {
            close(fd)
            return nil
        }
        return fd
    }

    private func startReading(fd: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &buf, buf.count)
            if n <= 0 {
                // EOF or error — mpv closed the socket. Process termination
                // handler is responsible for the onClose callback.
                self.teardownSocket()
                return
            }
            self.readBuffer.append(contentsOf: buf[0..<n])
            self.processBuffer()
        }
        source.setCancelHandler {
            close(fd)
        }
        readSource = source
        source.resume()
    }

    /// Parse newline-delimited JSON IPC messages and dispatch navigation events.
    private func processBuffer() {
        while let newlineIndex = readBuffer.firstIndex(of: 0x0A) {
            let lineData = readBuffer.subdata(in: readBuffer.startIndex..<newlineIndex)
            readBuffer.removeSubrange(readBuffer.startIndex...newlineIndex)
            if lineData.isEmpty { continue }

            guard
                let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                let event = obj["event"] as? String
            else { continue }

            switch event {
            case "client-message":
                guard let name = (obj["args"] as? [String])?.first else { continue }
                if name == "mkvqp-next" {
                    DispatchQueue.main.async { [weak self] in self?.onNavigate?(1) }
                } else if name == "mkvqp-prev" {
                    DispatchQueue.main.async { [weak self] in self?.onNavigate?(-1) }
                } else if name == "mkvqp-trash" {
                    DispatchQueue.main.async { [weak self] in self?.onTrash?() }
                } else if name == "mkvqp-undo" {
                    DispatchQueue.main.async { [weak self] in self?.onUndo?() }
                }
            case "property-change":
                handlePropertyChange(obj)
            default:
                continue
            }
        }
    }

    private func handlePropertyChange(_ obj: [String: Any]) {
        guard let name = obj["name"] as? String else { return }
        let defaults = UserDefaults.standard
        if name == "volume", let volume = obj["data"] as? Double {
            defaults.set(volume, forKey: volumeKey)
        } else if name == "mute", let muted = obj["data"] as? Bool {
            defaults.set(muted, forKey: muteKey)
        }
    }

    /// Show a brief on-screen message in the mpv window.
    func showText(_ text: String, durationMs: Int = 1500) {
        sendCommand(["show-text", text, durationMs])
    }

    private func sendCommand(_ command: [Any]) {
        ioQueue.async { [weak self] in
            guard let self = self, self.socketFD >= 0 else { return }
            guard var data = try? JSONSerialization.data(withJSONObject: ["command": command]) else { return }
            data.append(0x0A)
            data.withUnsafeBytes { raw in
                _ = write(self.socketFD, raw.baseAddress, raw.count)
            }
        }
    }

    private func teardownSocket() {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            self.readSource?.cancel() // cancel handler closes the fd
            self.readSource = nil
            self.socketFD = -1
            self.readBuffer.removeAll()
        }
    }

    // MARK: - Alerts

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
