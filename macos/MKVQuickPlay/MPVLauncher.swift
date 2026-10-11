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
        /// mpv normally binds its IPC socket within ~100ms, so retry fast at
        /// first — but a cold spawn (dyld cache miss after reboot, a waking
        /// drive) can take far longer, so patrol slowly for up to ~2 minutes
        /// instead of giving up. A missed connect used to permanently strand
        /// the session without navigation/trash/tag keys.
        static let fastRetries = 60
        static let fastRetryInterval: TimeInterval = 0.05  // 60 × 50ms ≈ 3s
        static let slowRetryInterval: TimeInterval = 0.5
        static let maxRetries = 300                        // ≈ 3s fast + 120s slow
        /// Grace period after SIGTERM before escalating to SIGKILL — mpv can
        /// take several hundred ms to tear down the video pipeline cleanly.
        static let terminateGrace: TimeInterval = 1.0
        /// Coalesce volume/mute preference writes during slider drags.
        static let prefsFlushDelay: TimeInterval = 0.5
        /// How long after the IPC channel first opens to check that mpv's
        /// window actually came frontmost — its own activation request can
        /// be declined under the macOS 14+ focus-stealing rules.
        static let focusCheckDelay: TimeInterval = 0.3
        /// Commands issued while the channel is still opening are held and
        /// flushed on connect; beyond this many the oldest is evicted (for
        /// `loadfile … replace` only the latest request matters).
        static let maxPendingCommands = 16
        /// Cap on mpv warning/error lines forwarded to the system log per
        /// player launch, so a broken file can't flood Console.
        static let maxForwardedLogLines = 40
    }

    /// Every key mpv responds to during a preview, as (key, command) in
    /// input.conf syntax. mpv's own default bindings are disabled wholesale
    /// (`--no-input-default-bindings`), so this table is the complete
    /// keyboard surface. Navigation / culling keys emit `script-message`s
    /// that reach us over IPC; the rest are plain player controls.
    ///
    /// The table is written to the bindings file before every launch AND
    /// re-sent with mpv's `keybind` command once the IPC channel opens, so a
    /// missing or stale file can never leave a session without keys again.
    private static let keyBindings: [(key: String, command: String)] = [
        ("DOWN", "script-message mkvqp-next"),
        ("UP", "script-message mkvqp-prev"),
        ("BS", "script-message mkvqp-trash"),
        ("DEL", "script-message mkvqp-trash"),
        ("Meta+z", "script-message mkvqp-undo"),
        ("p", "script-message mkvqp-tag"),
        ("ESC", "quit"),
        ("q", "quit"),
        ("SPACE", "cycle pause"),
        ("LEFT", "seek -5"),
        ("RIGHT", "seek 5"),
        ("m", "cycle mute"),
        ("f", "cycle fullscreen"),
    ]

    private var mpvProcess: Process?

    // Per-user temp dir (not world-readable /tmp): keeps the mpv IPC socket
    // private to this user and avoids collisions between multiple logins.
    // The path is unique per mpv launch so an old, still-dying player can
    // never interfere with the new session's socket. Main-thread confined.
    //
    // Only the *socket* lives here. macOS sweeps this directory of regular
    // files not accessed in 3 days (`dirhelper`, nightly), which is why the
    // key-bindings file must NOT live here — see `writeInputConf()`.
    private let socketDir = NSTemporaryDirectory()
    private var currentSocketPath = ""
    private var launchCounter = 0

    /// Keeps the app out of App Nap while a player is open, so the IPC
    /// retry chain, refocus timers and SIGKILL escalation fire on time
    /// instead of being coalesced. Main-thread confined.
    private var sessionActivity: NSObjectProtocol?

    // IPC state confined to ioQueue.
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var readBuffer = Data()
    private var pendingCommands: [[Any]] = []
    private let ioQueue = DispatchQueue(label: "com.mkvquickplay.ipc")

    // Cross-thread session state guarded by stateLock: bumping `generation`
    // invalidates any in-flight connect attempt; `connected` lets main-thread
    // code ask whether commands can currently reach mpv; `connecting` means a
    // connect chain for the current generation is still patrolling.
    private let stateLock = NSLock()
    private var generation = 0
    private var connected = false
    private var connecting = false
    /// Whether the active connect chain belongs to a fresh launch (as opposed
    /// to a self-heal reconnect). Only meaningful while `connecting`.
    private var launchConnect = false
    /// Session-identity token for input scoping, bumped by the app layer on
    /// every preview-session switch. `generation` cannot see a switch that
    /// reuses the window (`loadfile … replace` — the app's normal mode), so
    /// without this a keypress read just before or during a switch's
    /// main-thread stall would be delivered against the successor session's
    /// file. stateLock-guarded.
    private var inputEpochValue = 0

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

        // Sweep stale sockets left by crashed sessions (paths are per-launch,
        // `mkvquickplay-<pid>-<n>.sock`) — but leave alone any that belong to
        // another instance of the app that is still running.
        if let items = try? FileManager.default.contentsOfDirectory(atPath: socketDir) {
            for item in items where item.hasPrefix("mkvquickplay-") && item.hasSuffix(".sock") {
                let ownerField = item.dropFirst("mkvquickplay-".count).split(separator: "-").first ?? ""
                if let owner = pid_t(ownerField), owner != getpid(),
                   kill(owner, 0) == 0 || errno == EPERM {
                    continue // live process
                }
                unlink((socketDir as NSString).appendingPathComponent(item))
            }
        }

        // Earlier versions kept the bindings file in the temp dir; tidy it.
        unlink((socketDir as NSString).appendingPathComponent("mkvquickplay-input.conf"))
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

    // MARK: - Key bindings file

    /// `~/Library/Application Support/MKVQuickPlay` — Apple's designated home
    /// for support files an app needs in order to run. Nothing purges it.
    /// (Deliberately not named after the bundle identifier: it ends in
    /// `.app`, and a folder with that extension reads as an app bundle.)
    private static func supportDirectory() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("MKVQuickPlay", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            NSLog("[MKVQuickPlay] Could not create Application Support directory: \(error)")
            return nil
        }
    }

    /// (Re)write the custom mpv key bindings and return the file's path.
    ///
    /// Called before *every* mpv launch, not once per app launch. The file
    /// used to be written a single time into NSTemporaryDirectory(), which
    /// macOS cleans of files not accessed for 3 days — so after the app had
    /// sat in the menu bar for a few days, mpv started with `--input-conf`
    /// pointing at nothing and, with default bindings disabled, no keys at
    /// all (arrows, Delete, Esc, Space all dead) until the app was relaunched.
    /// The file is ~300 bytes; rewriting it each time is free and also picks
    /// up binding changes between app versions.
    private func writeInputConf() -> String? {
        let config = Self.keyBindings.map { "\($0.key) \($0.command)" }.joined(separator: "\n") + "\n"
        let dir = Self.supportDirectory() ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = dir.appendingPathComponent("input.conf")
        do {
            try config.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        } catch {
            NSLog("[MKVQuickPlay] Could not write mpv bindings file at \(url.path): \(error)")
            return nil
        }
    }

    // MARK: - Player state

    var isPlaying: Bool {
        mpvProcess?.isRunning ?? false
    }

    /// Whether the IPC channel to mpv is currently usable.
    var isConnected: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return connected
    }

    /// Whether a connect chain is still trying to open the channel to a
    /// player that is (presumably) starting up.
    private var isConnecting: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return connecting
    }

    /// Commands can reach the current player, or be held for one that a
    /// *launch* connect chain is still opening. (A reconnect chain also sets
    /// `connecting`, but in practice that means mpv is quitting — its IPC
    /// server goes away before the process does — so commands must not be
    /// held for it.) Read under one lock acquisition so a connect landing
    /// between two separate reads can't make both look false.
    private var canAcceptCommands: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return connected || (connecting && launchConnect)
    }

    private var currentGeneration: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return generation
    }

    private var inputEpoch: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return inputEpochValue
    }

    /// Called by the app on every preview-session switch (new invocation,
    /// batch review, close) — never on within-session navigation, which must
    /// keep delivering queued keys (held-arrow culling).
    func bumpInputEpoch() {
        stateLock.lock()
        inputEpochValue += 1
        stateLock.unlock()
    }

    /// Preview a video: load it into the running window, or (re)launch mpv.
    /// Returns false when mpv can't be found or fails to start.
    @discardableResult
    func play(url: URL) -> Bool {
        if isPlaying {
            if canAcceptCommands {
                // A command issued while the channel is still opening is
                // held and flushed on connect, so a second invocation during
                // a slow cold start no longer kills and relaunches the player.
                sendCommand(["loadfile", url.path, "replace"])
                return true
            }
            // mpv is running but the control channel is gone (or it is on
            // its way out) — restart clean rather than leaving an
            // uncontrollable window around or losing the request.
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
        // A launch must never inherit a predecessor's IPC state: a relaunch
        // can race the old player's termination handler (isRunning flips
        // before its main-queue hop runs, and that handler then skips cleanup
        // on the pid mismatch), leaving a dead fd, read buffer or held
        // commands behind. Idempotent when a teardown already happened.
        teardownSocket()

        guard let mpvPath = findMPV() else {
            showMPVNotFoundAlert()
            return false
        }

        // Fresh socket path for this session.
        launchCounter += 1
        currentSocketPath = (socketDir as NSString)
            .appendingPathComponent("mkvquickplay-\(ProcessInfo.processInfo.processIdentifier)-\(launchCounter).sock")
        let socketPath = currentSocketPath
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
            // Only warnings and errors on stderr, which we forward to the log.
            "--msg-level=all=warn",
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

        if let confPath = writeInputConf() {
            args.append("--input-conf=\(confPath)")
        } else {
            NSLog("[MKVQuickPlay] Launching mpv without a bindings file — keys will be installed over IPC once connected")
        }

        args.append(url.path)
        process.arguments = args

        // mpv's stderr used to go to /dev/null, which is how a dangling
        // --input-conf ("Error reading input config file") stayed invisible
        // for an entire release. Forward its warnings/errors to the log.
        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        Self.forwardLog(from: stderrPipe)

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Ignore the stale handler if a newer process has taken over.
                if self.mpvProcess?.processIdentifier == proc.processIdentifier {
                    self.teardownSocket()
                    self.mpvProcess = nil
                    self.endSessionActivity()
                    self.onClose?()
                }
            }
        }

        do {
            try process.run()
            mpvProcess = process
            beginSessionActivity()
            connectSocket(path: socketPath, firstConnectOfLaunch: true)
            return true
        } catch {
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            showLaunchErrorAlert(error: error)
            return false
        }
    }

    func stop() {
        guard let process = mpvProcess else { return }

        mpvProcess = nil
        teardownSocket()
        // Detach the activity token so an immediately following launch()
        // begins its own; keep this one alive until the SIGKILL escalation
        // has run so that grace timer isn't coalesced by App Nap.
        let activity = sessionActivity
        sessionActivity = nil

        guard process.isRunning else {
            if let activity = activity { ProcessInfo.processInfo.endActivity(activity) }
            return
        }
        process.terminate()
        // Escalate to SIGKILL if it doesn't exit promptly, without
        // blocking the main thread.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Timing.terminateGrace) {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            if let activity = activity { ProcessInfo.processInfo.endActivity(activity) }
        }
    }

    private func beginSessionActivity() {
        guard sessionActivity == nil else { return }
        sessionActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Video preview session")
    }

    private func endSessionActivity() {
        if let token = sessionActivity {
            ProcessInfo.processInfo.endActivity(token)
            sessionActivity = nil
        }
    }

    /// Bring the mpv window to the front so it keeps receiving keyboard input.
    func activateWindow() {
        guard let pid = mpvProcess?.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        // macOS 14+ uses request-based "cooperative" activation, and macOS 26
        // tightened focus-stealing prevention so a request from a background
        // app can be declined. A yield only counts while *we* are the active
        // app — rare for a Dock-less app, but free and correct when it does
        // apply (right after one of our own alerts). Name ourselves as the
        // source of the request, fall back to a plain request, and log a
        // refusal so it leaves evidence instead of failing silently.
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: app)
            if !app.activate(from: .current, options: []) && !app.activate() {
                NSLog("[MKVQuickPlay] macOS declined to bring the mpv window frontmost")
            }
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    // MARK: - IPC

    private func connectSocket(path: String, firstConnectOfLaunch: Bool) {
        stateLock.lock()
        generation += 1
        connected = false // a new session must never inherit a predecessor's flag
        connecting = true
        launchConnect = firstConnectOfLaunch
        let gen = generation
        stateLock.unlock()

        ioQueue.async { [weak self] in
            self?.attemptConnect(path: path, generation: gen, attempt: 0,
                                 firstConnectOfLaunch: firstConnectOfLaunch)
        }
    }

    /// ioQueue-confined, non-blocking retry chain: never occupies the queue
    /// while waiting, and keeps trying long enough to ride out a slow mpv
    /// cold start instead of stranding the session without keys.
    private func attemptConnect(path: String, generation gen: Int, attempt: Int,
                                firstConnectOfLaunch: Bool) {
        // A newer launch or a teardown supersedes this attempt.
        stateLock.lock()
        let stale = (generation != gen)
        stateLock.unlock()
        if stale { return }

        if let fd = makeConnectedSocket(path: path) {
            stateLock.lock()
            let current = (generation == gen)
            if current {
                connected = true
                connecting = false
            }
            stateLock.unlock()
            if !current {
                close(fd)
                return
            }
            // Replace any leftover source from a predecessor session
            // (its cancel handler closes the old fd).
            readSource?.cancel()
            readSource = nil
            socketFD = fd
            startReading(fd: fd, generation: gen)
            // Scheduled before the setup writes so a write failure below
            // can't skip it; it no-ops if the generation has moved on.
            if firstConnectOfLaunch {
                verifyFrontmost(generation: gen)
            }
            // Install the key bindings over IPC as well as via the file
            // (idempotent: same key, same command), so a session can never
            // end up keyless again whatever happened to the file; track
            // volume / mute so we can persist them; then replay anything the
            // app asked for while the player was still coming up. Written
            // right here, on ioQueue, so nothing the main thread enqueues
            // meanwhile can slip in ahead of (or get re-held behind) them.
            var setup: [[Any]] = Self.keyBindings.map { ["keybind", $0.key, $0.command] }
            setup.append(["observe_property", 1, "volume"])
            setup.append(["observe_property", 2, "mute"])
            setup.append(contentsOf: pendingCommands)
            pendingCommands.removeAll()
            for command in setup {
                if !writeNow(command, generation: gen) { return } // channel torn down
            }
            if attempt >= Timing.fastRetries {
                NSLog("[MKVQuickPlay] mpv IPC connected after slow start (attempt \(attempt))")
            }
            return
        }

        if attempt == Timing.fastRetries {
            NSLog("[MKVQuickPlay] mpv IPC socket slow to appear — still retrying in the background")
        }
        guard attempt < Timing.maxRetries else {
            NSLog("[MKVQuickPlay] Could not connect to mpv IPC socket; navigation keys unavailable this session")
            stateLock.lock()
            if generation == gen { connecting = false }
            stateLock.unlock()
            pendingCommands.removeAll()
            return
        }
        let delay = attempt < Timing.fastRetries ? Timing.fastRetryInterval : Timing.slowRetryInterval
        ioQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.attemptConnect(path: path, generation: gen, attempt: attempt + 1,
                                 firstConnectOfLaunch: firstConnectOfLaunch)
        }
    }

    /// mpv asks to be activated when it creates its window, but under the
    /// macOS 14+ cooperative model that is only a request — and a child of a
    /// background app is outside the sanctioned launch paths. If the window
    /// didn't come frontmost, the arrow keys would go to whatever app is,
    /// so ask once more on the player's behalf.
    private func verifyFrontmost(generation gen: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.focusCheckDelay) { [weak self] in
            guard let self = self, self.currentGeneration == gen,
                  let pid = self.mpvProcess?.processIdentifier else { return }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                NSLog("[MKVQuickPlay] mpv window not frontmost after launch — requesting activation")
                self.activateWindow()
            }
        }
    }

    /// A dropped channel while mpv is still running must self-heal — a
    /// keyless preview session is otherwise stuck until the user happens to
    /// re-invoke the service.
    private func reconnectIfPlayerAlive() {
        DispatchQueue.main.async { [weak self] in
            // Only heal if no newer session took over since the teardown that
            // scheduled us: a launch() in between has already started its own
            // connect chain (connecting == true) or has connected.
            guard let self = self, self.mpvProcess?.isRunning == true,
                  !self.isConnecting, !self.isConnected else { return }
            NSLog("[MKVQuickPlay] IPC channel dropped while mpv is running — reconnecting")
            self.connectSocket(path: self.currentSocketPath, firstConnectOfLaunch: false)
        }
    }

    private func makeConnectedSocket(path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return nil }

        // Belt and suspenders with the SIGPIPE ignore in init(): make writes
        // to a dead peer report EPIPE on this socket specifically.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = path.utf8CString // includes trailing NUL
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
            if n < 0 {
                // A transient interruption must not kill the channel.
                if errno == EINTR || errno == EAGAIN { return }
                // Scoped to this source's generation so a stale source can't
                // tear down (or needlessly reconnect) a successor.
                if self.teardownSocket(ifGeneration: gen) {
                    self.reconnectIfPlayerAlive()
                }
                return
            }
            if n == 0 {
                // EOF — mpv closed the socket. The process termination
                // handler owns the onClose callback; if mpv is somehow still
                // alive, self-heal the channel.
                if self.teardownSocket(ifGeneration: gen) {
                    self.reconnectIfPlayerAlive()
                }
                return
            }
            self.readBuffer.append(contentsOf: buf[0..<n])
            self.processBuffer(generation: gen)
        }
        source.setCancelHandler {
            close(fd)
        }
        readSource = source
        source.resume()
    }

    /// Parse newline-delimited JSON IPC messages and dispatch navigation events.
    /// `gen` is the generation of the channel these bytes arrived on.
    private func processBuffer(generation gen: Int) {
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
                // Two delivery-time checks on main. `gen` catches a stale
                // read source draining bytes after the channel was rebuilt.
                // `inputEpoch` catches what `gen` cannot: a session switch on
                // the SAME channel (`loadfile … replace` — the app's normal
                // mode), where a keypress read before or during the switch's
                // main-thread stall would act on the successor session's
                // file. A late trash would delete the wrong video.
                let epoch = inputEpoch
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.currentGeneration == gen,
                          self.inputEpoch == epoch else { return }
                    switch name {
                    case "mkvqp-next": self.onNavigate?(1)
                    case "mkvqp-prev": self.onNavigate?(-1)
                    case "mkvqp-trash": self.onTrash?()
                    case "mkvqp-undo": self.onUndo?()
                    case "mkvqp-tag": self.onTagToggle?()
                    default: break
                    }
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
        // Remember which session the command belongs to, so a write that
        // fails after a relaunch can't tear down the successor's channel.
        let gen = currentGeneration
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            if self.socketFD < 0 {
                // Player still coming up: hold the command for the connect.
                // Bounded FIFO that evicts the oldest entry — for
                // `loadfile … replace` only the latest request matters.
                if self.isConnecting {
                    if self.pendingCommands.count >= Timing.maxPendingCommands {
                        self.pendingCommands.removeFirst()
                    }
                    self.pendingCommands.append(command)
                }
                return
            }
            self.writeNow(command, generation: gen)
        }
    }

    /// ioQueue-confined. Writes one command to the open socket; returns false
    /// (after tearing the channel down) when the peer is gone.
    @discardableResult
    private func writeNow(_ command: [Any], generation gen: Int) -> Bool {
        guard var data = try? JSONSerialization.data(withJSONObject: ["command": command]) else { return true }
        data.append(0x0A)
        var written = -1
        repeat {
            written = data.withUnsafeBytes { raw -> Int in
                write(self.socketFD, raw.baseAddress, raw.count)
            }
        } while written < 0 && errno == EINTR
        if written < 0 {
            // Peer is gone (EPIPE, SIGPIPE suppressed) — drop the channel
            // so isConnected turns false, and self-heal if mpv is alive.
            if teardownSocket(ifGeneration: gen) {
                reconnectIfPlayerAlive()
            }
            return false
        }
        return true
    }

    /// Tear down the IPC channel. Pass the generation the caller belongs to so
    /// a stale actor (an old session's read source) silently no-ops instead of
    /// killing a successor session; omit it for unconditional teardown.
    /// Returns whether anything was actually torn down.
    @discardableResult
    private func teardownSocket(ifGeneration gen: Int? = nil) -> Bool {
        // Invalidate synchronously so in-flight connect loops and main-thread
        // isConnected checks see the change immediately…
        stateLock.lock()
        if let gen = gen, gen != generation {
            stateLock.unlock()
            return false
        }
        generation += 1
        connected = false
        connecting = false
        stateLock.unlock()

        // …then release the fd and flush pending prefs on the IPC queue.
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            self.flushPendingPrefs()
            self.readSource?.cancel() // cancel handler closes the fd
            self.readSource = nil
            self.socketFD = -1
            self.readBuffer.removeAll()
            self.pendingCommands.removeAll()
        }
        return true
    }

    /// Synchronously flush coalesced preferences — for app termination, when
    /// enqueued async flushes would never get to run. Safe to call from the
    /// main thread only (ioQueue never blocks on main).
    func flushPrefsForTermination() {
        ioQueue.sync { [weak self] in
            self?.flushPendingPrefs()
        }
    }

    // MARK: - Diagnostics

    /// Forward mpv's stderr lines to the system log, bounded per launch, so a
    /// misbehaving player leaves evidence in Console.app. Reading continuously
    /// also keeps mpv from blocking on a full pipe.
    private static func forwardLog(from pipe: Pipe) {
        // State lives in a reference so the handler (which Foundation runs on
        // its own serial queue) mutates a shared object, not captured vars.
        final class LineBuffer {
            var buffer = Data()
            var logged = 0
        }
        let state = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                // EOF — mpv exited.
                handle.readabilityHandler = nil
                return
            }
            state.buffer.append(chunk)
            while let newline = state.buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: state.buffer[state.buffer.startIndex..<newline], as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
                state.buffer.removeSubrange(state.buffer.startIndex...newline)
                guard !line.isEmpty, state.logged < Timing.maxForwardedLogLines else { continue }
                state.logged += 1
                NSLog("[mpv] %@", line)
                if state.logged == Timing.maxForwardedLogLines {
                    NSLog("[mpv] (further output from this player suppressed)")
                }
            }
            if state.buffer.count > 64 * 1024 { state.buffer.removeAll() } // unterminated noise
        }
    }

    // MARK: - Alerts

    private func showMPVNotFoundAlert() {
        presentAlert(
            title: "mpv Not Found",
            message: "MKV QuickPlay requires mpv to play videos.\n\nInstall using Homebrew:\nbrew install mpv"
        )
    }

    private func showLaunchErrorAlert(error: Error) {
        presentAlert(title: "Failed to Launch mpv", message: error.localizedDescription)
    }

    /// Main-thread confined: suppress stacked alerts while one is already on
    /// screen — every re-invocation without mpv installed would otherwise
    /// nest another modal session behind the first.
    private var alertShowing = false

    private func presentAlert(title: String, message: String) {
        DispatchQueue.main.async {
            guard !self.alertShowing else { return }
            self.alertShowing = true
            defer { self.alertShowing = false }
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModalInFront()
        }
    }
}
