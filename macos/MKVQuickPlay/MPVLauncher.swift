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

    private enum Timing {
        /// mpv needs a moment to create the IPC socket after launch.
        static let connectRetries = 60
        static let connectRetryInterval: useconds_t = 50_000 // 50ms × 60 ≈ 3s
        /// Grace period after SIGTERM before escalating to SIGKILL — mpv can
        /// take several hundred ms to tear down the video pipeline cleanly.
        static let terminateGrace: TimeInterval = 1.0
        /// Coalesce volume/mute preference writes during slider drags.
        static let prefsFlushDelay: TimeInterval = 0.5
    }

    private var mpvProcess: Process?
    private var inputConfPath: String?

    // Per-user temp dir (not world-readable /tmp): keeps the mpv IPC socket
    // private to this user and avoids collisions between multiple logins.
    private let socketPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("mkvquickplay.sock")

    // IPC state confined to ioQueue.
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var readBuffer = Data()
    private let ioQueue = DispatchQueue(label: "com.mkvquickplay.ipc")

    // Cross-thread session state guarded by stateLock: bumping `generation`
    // invalidates any in-flight connect attempt; `connected` lets main-thread
    // code ask whether commands can currently reach mpv.
    private let stateLock = NSLock()
    private var generation = 0
    private var connected = false

    // Latest observed player values, coalesced into UserDefaults (ioQueue-confined).
    private var pendingVolume: Double?
    private var pendingMute: Bool?
    private var prefsFlushScheduled = false

    /// Called on the main thread when mpv fully exits (window closed / quit).
    var onClose: (() -> Void)?

    /// Called on the main thread when the user requests navigation while a
    /// video is playing. `delta` is +1 for next, -1 for previous.
    var onNavigate: ((Int) -> Void)?

    /// Called on the main thread when the user presses the Trash key.
    var onTrash: (() -> Void)?

    /// Called on the main thread when the user presses Undo (Cmd+Z).
    var onUndo: (() -> Void)?

    /// Called on the main thread when the user presses the tag key (P).
    var onTagToggle: (() -> Void)?

    // Persisted playback preferences.
    private let volumeKey = "mkvqp.volume"
    private let muteKey = "mkvqp.mute"

    private init() {
        // A write() on a peer-closed socket must fail with EPIPE, not deliver
        // SIGPIPE — whose default disposition would kill the whole app when
        // mpv exits while a command is in flight.
        signal(SIGPIPE, SIG_IGN)
        inputConfPath = createInputConf()
    }

    private func findMPV() -> String? {
        let paths = [
            "/opt/homebrew/bin/mpv",          // Homebrew (Apple Silicon)
            "/usr/local/bin/mpv",             // Homebrew (Intel) / manual
            "/opt/local/bin/mpv",             // MacPorts
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
        p script-message mkvqp-tag
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

    /// Whether the IPC channel to mpv is currently usable.
    var isConnected: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return connected
    }

    /// Preview a video: load it into the running window, or (re)launch mpv.
    /// Returns false when mpv can't be found or fails to start.
    @discardableResult
    func play(url: URL) -> Bool {
        if isPlaying {
            if isConnected {
                sendCommand(["loadfile", url.path, "replace"])
                return true
            }
            // mpv is running but the control channel is gone — restart clean
            // rather than leaving an uncontrollable window around.
            stop()
        }
        return launch(url: url)
    }

    /// Load a video into the existing window only — used by navigation and
    /// trash-advance, which must never relaunch a player the user just closed.
    /// Returns false when there is no live, controllable player.
    func load(url: URL) -> Bool {
        guard isPlaying, isConnected else { return false }
        sendCommand(["loadfile", url.path, "replace"])
        return true
    }

    private func launch(url: URL) -> Bool {
        guard let mpvPath = findMPV() else {
            showMPVNotFoundAlert()
            return false
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
            return true
        } catch {
            showLaunchErrorAlert(error: error)
            return false
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
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Timing.terminateGrace) {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
    }

    /// Bring the mpv window to the front so it keeps receiving keyboard input.
    func activateWindow() {
        guard let pid = mpvProcess?.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        // macOS 14+ uses request-based "cooperative" activation; the old
        // .activateIgnoringOtherApps option is deprecated and ignored there.
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    // MARK: - IPC

    private func connectSocket() {
        stateLock.lock()
        generation += 1
        connected = false // a new session must never inherit a predecessor's flag
        let gen = generation
        stateLock.unlock()

        ioQueue.async { [weak self] in
            guard let self = self else { return }
            for _ in 0..<Timing.connectRetries {
                // A newer launch or a teardown supersedes this attempt.
                self.stateLock.lock()
                let stale = (self.generation != gen)
                self.stateLock.unlock()
                if stale { return }

                if let fd = self.makeConnectedSocket() {
                    self.stateLock.lock()
                    let current = (self.generation == gen)
                    if current { self.connected = true }
                    self.stateLock.unlock()
                    if !current {
                        close(fd)
                        return
                    }
                    // Replace any leftover source from a predecessor session
                    // (its cancel handler closes the old fd).
                    self.readSource?.cancel()
                    self.readSource = nil
                    self.socketFD = fd
                    self.startReading(fd: fd, generation: gen)
                    // Track volume / mute so we can persist them for next time.
                    self.sendCommand(["observe_property", 1, "volume"])
                    self.sendCommand(["observe_property", 2, "mute"])
                    return
                }
                usleep(Timing.connectRetryInterval)
            }
            NSLog("[MKVQuickPlay] Could not connect to mpv IPC socket; navigation disabled this session")
        }
    }

    private func makeConnectedSocket() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return nil }

        // Belt and suspenders with the SIGPIPE ignore in init(): make writes
        // to a dead peer report EPIPE on this socket specifically.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

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

    private func startReading(fd: Int32, generation gen: Int) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &buf, buf.count)
            if n <= 0 {
                // EOF or error — mpv closed the socket. Scoped to this source's
                // generation so a stale source can't tear down a successor.
                // The process termination handler owns the onClose callback.
                self.teardownSocket(ifGeneration: gen)
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
                } else if name == "mkvqp-tag" {
                    DispatchQueue.main.async { [weak self] in self?.onTagToggle?() }
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
        // Coalesce into instance vars: a volume-slider drag fires dozens of
        // events per second, and only the latest value matters.
        if name == "volume", let volume = obj["data"] as? Double {
            pendingVolume = volume
            schedulePrefsFlush()
        } else if name == "mute", let muted = obj["data"] as? Bool {
            pendingMute = muted
            schedulePrefsFlush()
        }
    }

    /// ioQueue-confined: batch preference writes instead of one per event.
    private func schedulePrefsFlush() {
        guard !prefsFlushScheduled else { return }
        prefsFlushScheduled = true
        ioQueue.asyncAfter(deadline: .now() + Timing.prefsFlushDelay) { [weak self] in
            guard let self = self else { return }
            self.prefsFlushScheduled = false
            self.flushPendingPrefs()
        }
    }

    /// ioQueue-confined.
    private func flushPendingPrefs() {
        let defaults = UserDefaults.standard
        if let volume = pendingVolume {
            defaults.set(volume, forKey: volumeKey)
            pendingVolume = nil
        }
        if let muted = pendingMute {
            defaults.set(muted, forKey: muteKey)
            pendingMute = nil
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
            let written = data.withUnsafeBytes { raw -> Int in
                write(self.socketFD, raw.baseAddress, raw.count)
            }
            if written < 0 {
                // Peer is gone (EPIPE, SIGPIPE suppressed) — drop the channel
                // so isConnected turns false instead of silently eating commands.
                self.teardownSocket()
            }
        }
    }

    /// Tear down the IPC channel. Pass the generation the caller belongs to so
    /// a stale actor (an old session's read source) silently no-ops instead of
    /// killing a successor session; omit it for unconditional teardown.
    private func teardownSocket(ifGeneration gen: Int? = nil) {
        // Invalidate synchronously so in-flight connect loops and main-thread
        // isConnected checks see the change immediately…
        stateLock.lock()
        if let gen = gen, gen != generation {
            stateLock.unlock()
            return
        }
        generation += 1
        connected = false
        stateLock.unlock()

        // …then release the fd and flush pending prefs on the IPC queue.
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            self.flushPendingPrefs()
            self.readSource?.cancel() // cancel handler closes the fd
            self.readSource = nil
            self.socketFD = -1
            self.readBuffer.removeAll()
        }
    }

    /// Synchronously flush coalesced preferences — for app termination, when
    /// enqueued async flushes would never get to run. Safe to call from the
    /// main thread only (ioQueue never blocks on main).
    func flushPrefsForTermination() {
        ioQueue.sync { [weak self] in
            self?.flushPendingPrefs()
        }
    }

    // MARK: - Alerts

    /// LSUIElement apps are never frontmost, so an unactivated modal alert can
    /// appear behind other windows with no key focus — activate first.
    private func presentAlert(title: String, message: String) {
        DispatchQueue.main.async {
            if #available(macOS 14.0, *) {
                NSApp.activate()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.window.level = .floating
            alert.runModal()
        }
    }

    private func showMPVNotFoundAlert() {
        presentAlert(
            title: "mpv Not Found",
            message: "MKV QuickPlay requires mpv to play videos.\n\nInstall using Homebrew:\nbrew install mpv"
        )
    }

    private func showLaunchErrorAlert(error: Error) {
        presentAlert(title: "Failed to Launch mpv", message: error.localizedDescription)
    }
}
