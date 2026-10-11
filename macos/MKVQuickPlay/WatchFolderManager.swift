import Cocoa
import CoreServices

/// Watches user-designated folders for newly arrived videos and offers them
/// for review once a batch has settled.
///
/// Mechanics (the design constraints live in CLAUDE.md):
/// - **One FSEventStream per folder** (file-level events, 2 s latency,
///   `sinceNow`) delivered on a private queue; everything hops to the main
///   thread before touching state. No DispatchSource anywhere — an open fd
///   per directory would block ejecting the external SSDs these folders
///   usually live on.
/// - **A reconcile scan** (shallow enumerate + diff against a persisted
///   seen-set) is the recovery path for everything FSEvents can miss: it runs
///   on arm, volume mount, wake, any anomalous event flag
///   (MustScanSubDirs/Dropped/RootChanged), and on a 30 s timer for non-local
///   volumes, where FSEvents cannot see remote writers.
/// - **A settle gate** admits a file only after its size+mtime held stable
///   across polls *and* its events went quiet — Finder makes a copied file
///   visible (and openable) the moment the copy *starts*, and this feature
///   feeds a workflow whose Delete key destroys files.
/// - Arrivals are offered as **one batch** after the folder goes quiet, and
///   are marked seen when offered. Adding a folder seeds the seen-set
///   silently: the 500 videos already there are not "new".
/// - Folders are persisted as **bookmarks**, so a renamed folder or a volume
///   that remounts under a new path re-resolves; an unresolvable folder goes
///   dormant and re-arms on the next mount/wake.
final class WatchFolderManager {

    // MARK: Tunables

    private enum Timing {
        /// FSEvents coalescing latency.
        static let eventLatency: CFTimeInterval = 2.0
        /// Candidate poll cadence while anything is settling.
        static let settlePoll: TimeInterval = 2.0
        /// Consecutive polls with an unchanged size+mtime to count as stable.
        static let stablePolls = 2
        /// Additionally: no FSEvents activity on the file for this long.
        static let eventQuiet: TimeInterval = 3.0
        /// The whole folder must be quiet this long before the batch is offered.
        static let batchQuiet: TimeInterval = 5.0
        /// Reconcile cadence for volumes FSEvents can't fully observe.
        static let remotePoll: TimeInterval = 30.0
    }

    /// Names that are never arrivals: partial downloads and metadata litter.
    private static let ignoredExtensions: Set<String> = ["part", "tmp", "crdownload", "download"]

    // MARK: Persistence types

    private struct FolderConfig: Codable {
        var bookmark: Data
        /// Last known path, for display while the volume is unmounted.
        var displayPath: String
    }

    private struct FileStamp: Codable, Equatable {
        var size: Int
        var mtime: TimeInterval
    }

    // MARK: Runtime state (main-thread confined)

    private final class ActiveWatch {
        let folderURL: URL
        var stream: FSEventStreamRef?
        var isLocalVolume = true
        /// path → stamp of every file already offered (or seeded).
        var seen: [String: FileStamp] = [:]

        struct Candidate {
            var lastStamp: FileStamp
            var stablePolls = 0
            var lastEventAt: Date
        }
        /// Files noticed but not yet settled.
        var candidates: [String: Candidate] = [:]

        init(folderURL: URL) { self.folderURL = folderURL }
    }

    private var configs: [FolderConfig] = []
    /// Keyed by resolved folder path. A config with no entry here is dormant
    /// (volume unmounted / folder missing).
    private var watches: [String: ActiveWatch] = [:]
    private var pendingReview: [URL] = []

    private var settleTimer: Timer?
    private var batchTimer: Timer?
    private var remoteTimer: Timer?

    private let eventQueue = DispatchQueue(label: "com.mkvquickplay.watchfolders")
    private let configKey = "mkvqp.watchFolders"

    /// Decides what counts as a video (shared with the preview pipeline).
    private let isVideoFile: (URL) -> Bool

    /// Fired on main whenever the pending-review count changes.
    var onPendingChanged: ((Int) -> Void)?
    /// Fired on main when a settled batch is ready to offer (count = total pending).
    var onBatchReady: ((Int) -> Void)?

    // MARK: - Lifecycle

    init(isVideoFile: @escaping (URL) -> Bool) {
        self.isVideoFile = isVideoFile
        loadConfigs()
        loadSeenSets()
        armAll()

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(volumesChanged),
                              name: NSWorkspace.didMountNotification, object: nil)
        workspace.addObserver(self, selector: #selector(volumesChanged),
                              name: NSWorkspace.didUnmountNotification, object: nil)
        workspace.addObserver(self, selector: #selector(volumesChanged),
                              name: NSWorkspace.didWakeNotification, object: nil)
    }

    // The manager lives for the whole app lifetime (owned by AppDelegate);
    // the FSEvents contexts hold an unretained self on that basis.

    // MARK: - Public API (main thread)

    var folders: [(name: String, path: String, active: Bool)] {
        configs.map { config in
            let url = resolve(config)
            let path = url?.path ?? config.displayPath
            return ((path as NSString).lastPathComponent, path, url != nil && watches[path] != nil)
        }
    }

    var pendingCount: Int { pendingReview.count }

    func addFolder(_ url: URL) {
        guard let bookmark = try? url.bookmarkData() else {
            NSLog("[WatchFolders] Could not bookmark \(url.path)")
            return
        }
        // Replace an existing entry for the same folder rather than duplicating.
        removeFolder(path: url.path, persist: false)
        configs.append(FolderConfig(bookmark: bookmark, displayPath: url.path))
        saveConfigs()
        arm(configs[configs.count - 1], seedSilently: true)
    }

    func removeFolder(path: String, persist: Bool = true) {
        if let watch = watches.removeValue(forKey: path) {
            stopStream(of: watch)
            let prefix = path.hasSuffix("/") ? path : path + "/"
            pendingReview.removeAll { $0.path.hasPrefix(prefix) }
            onPendingChanged?(pendingReview.count)
        }
        configs.removeAll { $0.displayPath == path || resolve($0)?.path == path }
        if persist { saveConfigs() }
        saveSeenSets()
        refreshRemoteTimer()
    }

    /// Hand over everything pending and clear it (the caller starts the session).
    func takePendingReview() -> [URL] {
        let batch = pendingReview
        pendingReview = []
        onPendingChanged?(0)
        return batch
    }

    // MARK: - Arming

    private func resolve(_ config: FolderConfig) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: config.bookmark,
                                 bookmarkDataIsStale: &stale) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return url
    }

    private func armAll() {
        for config in configs { arm(config, seedSilently: false) }
        refreshRemoteTimer()
    }

    private func arm(_ config: FolderConfig, seedSilently: Bool) {
        guard let url = resolve(config) else { return } // dormant until mount
        let path = url.path
        guard watches[path] == nil else { return }

        // Keep the stored bookmark/display path current across renames.
        if config.displayPath != path,
           let index = configs.firstIndex(where: { $0.bookmark == config.bookmark }) {
            configs[index].displayPath = path
            if let fresh = try? url.bookmarkData() { configs[index].bookmark = fresh }
            saveConfigs()
        }

        let watch = ActiveWatch(folderURL: url)
        watch.isLocalVolume = (try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal ?? true
        watch.seen = seenSets[path] ?? [:]
        watches[path] = watch
        watch.stream = makeStream(for: url)

        if seedSilently {
            // Pre-existing files are not arrivals.
            watch.seen = currentStamps(in: url)
            seenSets[path] = watch.seen
            saveSeenSets()
        } else {
            reconcile(watch)
        }
        refreshRemoteTimer()
    }

    @objc private func volumesChanged() {
        // Tear down watches whose folder vanished; re-arm dormant configs.
        for (path, watch) in watches {
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) || !isDirectory.boolValue {
                stopStream(of: watch)
                watches.removeValue(forKey: path)
            }
        }
        for config in configs where resolve(config).map({ watches[$0.path] == nil }) ?? false {
            arm(config, seedSilently: false)
        }
        // Wake/mount are exactly when FSEvents may have missed things.
        for watch in watches.values { reconcile(watch) }
        refreshRemoteTimer()
    }

    // MARK: - FSEvents

    private func makeStream(for folder: URL) -> FSEventStreamRef? {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, eventFlags, _ in
            guard let info = info else { return }
            let manager = Unmanaged<WatchFolderManager>.fromOpaque(info).takeUnretainedValue()
            guard let paths = unsafeBitCast(eventPaths, to: CFArray.self) as? [String] else { return }
            var pairs: [(String, FSEventStreamEventFlags)] = []
            pairs.reserveCapacity(eventCount)
            for i in 0..<min(eventCount, paths.count) { pairs.append((paths[i], eventFlags[i])) }
            DispatchQueue.main.async { manager.handleEvents(pairs) }
        }

        let flags = UInt32(kFSEventStreamCreateFlagFileEvents)
            | UInt32(kFSEventStreamCreateFlagWatchRoot)
            | UInt32(kFSEventStreamCreateFlagUseCFTypes)
            | UInt32(kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [folder.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Timing.eventLatency, flags) else {
            NSLog("[WatchFolders] FSEventStreamCreate failed for \(folder.path)")
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, eventQueue)
        FSEventStreamStart(stream)
        return stream
    }

    private func stopStream(of watch: ActiveWatch) {
        guard let stream = watch.stream else { return }
        // Ordered teardown: stop → invalidate → release, or a late callback
        // fires into a dead context.
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        watch.stream = nil
    }

    /// Main thread. Routes each event to its watch.
    private func handleEvents(_ pairs: [(String, FSEventStreamEventFlags)]) {
        let anomaly = UInt32(kFSEventStreamEventFlagMustScanSubDirs)
            | UInt32(kFSEventStreamEventFlagKernelDropped)
            | UInt32(kFSEventStreamEventFlagUserDropped)
            | UInt32(kFSEventStreamEventFlagRootChanged)
            | UInt32(kFSEventStreamEventFlagEventIdsWrapped)
            | UInt32(kFSEventStreamEventFlagMount)
            | UInt32(kFSEventStreamEventFlagUnmount)

        var reconcileSet: Set<String> = []
        for (path, flags) in pairs {
            guard let (watchPath, watch) = watchCovering(path) else { continue }
            if flags & anomaly != 0 {
                reconcileSet.insert(watchPath)
                continue
            }
            // Shallow scope: only direct children count as arrivals.
            let fileURL = URL(fileURLWithPath: path)
            guard fileURL.deletingLastPathComponent().path == watchPath else { continue }
            touch(fileURL, in: watch)
        }
        for path in reconcileSet {
            if let watch = watches[path] { reconcile(watch) }
            else { volumesChanged() } // root moved/unmounted — re-resolve
        }
    }

    private func watchCovering(_ path: String) -> (String, ActiveWatch)? {
        for (watchPath, watch) in watches {
            if path == watchPath || path.hasPrefix(watchPath.hasSuffix("/") ? watchPath : watchPath + "/") {
                return (watchPath, watch)
            }
        }
        return nil
    }

    // MARK: - Candidates & settle gate

    private func passesPreFilter(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard !name.hasPrefix("."), !name.hasPrefix("._") else { return false }
        guard !Self.ignoredExtensions.contains(url.pathExtension.lowercased()) else { return false }
        return isVideoFile(url)
    }

    private func stamp(of url: URL) -> FileStamp? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        return FileStamp(size: values.fileSize ?? 0,
                         mtime: values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)
    }

    private func currentStamps(in folder: URL) -> [String: FileStamp] {
        var result: [String: FileStamp] = [:]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles])) ?? []
        for url in contents where passesPreFilter(url) {
            if let stamp = stamp(of: url) { result[url.path] = stamp }
        }
        return result
    }

    /// A file changed (or was noticed by a reconcile): make/refresh a candidate.
    private func touch(_ url: URL, in watch: ActiveWatch) {
        let path = url.path
        guard passesPreFilter(url) else { return }
        guard let current = stamp(of: url) else {
            // Deleted or replaced by a non-file: forget it everywhere.
            watch.candidates.removeValue(forKey: path)
            if watch.seen.removeValue(forKey: path) != nil { saveSeenSets() }
            if pendingReview.contains(where: { $0.path == path }) {
                pendingReview.removeAll { $0.path == path }
                onPendingChanged?(pendingReview.count)
            }
            return
        }
        if watch.seen[path] == current { return } // already offered, unchanged
        if var candidate = watch.candidates[path] {
            candidate.lastEventAt = Date()
            if candidate.lastStamp != current {
                candidate.lastStamp = current
                candidate.stablePolls = 0
            }
            watch.candidates[path] = candidate
        } else {
            watch.candidates[path] = .init(lastStamp: current, stablePolls: 0, lastEventAt: Date())
        }
        startSettleTimerIfNeeded()
    }

    private func reconcile(_ watch: ActiveWatch) {
        let now = currentStamps(in: watch.folderURL)
        for (path, _) in now where watch.seen[path] != now[path] {
            touch(URL(fileURLWithPath: path), in: watch)
        }
        // Prune seen entries (and pendings) for files that are gone.
        let gone = watch.seen.keys.filter { now[$0] == nil }
        if !gone.isEmpty {
            for path in gone { watch.seen.removeValue(forKey: path) }
            saveSeenSets()
        }
        let before = pendingReview.count
        pendingReview.removeAll { url in
            url.deletingLastPathComponent().path == watch.folderURL.path && now[url.path] == nil
        }
        if pendingReview.count != before { onPendingChanged?(pendingReview.count) }
    }

    private func startSettleTimerIfNeeded() {
        guard settleTimer == nil else { return }
        settleTimer = Timer.scheduledTimer(withTimeInterval: Timing.settlePoll, repeats: true) { [weak self] _ in
            self?.pollCandidates()
        }
    }

    private func pollCandidates() {
        var anyLeft = false
        var settledAny = false
        for watch in watches.values {
            for (path, var candidate) in watch.candidates {
                let url = URL(fileURLWithPath: path)
                guard let current = stamp(of: url) else {
                    watch.candidates.removeValue(forKey: path)
                    continue
                }
                if current == candidate.lastStamp {
                    candidate.stablePolls += 1
                } else {
                    candidate.lastStamp = current
                    candidate.stablePolls = 0
                    candidate.lastEventAt = Date()
                }
                let quiet = Date().timeIntervalSince(candidate.lastEventAt) >= Timing.eventQuiet
                if candidate.stablePolls >= Timing.stablePolls && quiet && current.size > 0 {
                    // Settled: offer it.
                    watch.candidates.removeValue(forKey: path)
                    watch.seen[path] = current
                    if !pendingReview.contains(where: { $0.path == path }) {
                        pendingReview.append(url)
                    }
                    settledAny = true
                } else {
                    watch.candidates[path] = candidate
                    anyLeft = true
                }
            }
        }
        if settledAny {
            saveSeenSets()
            onPendingChanged?(pendingReview.count)
            scheduleBatchOffer()
        }
        if !anyLeft {
            settleTimer?.invalidate()
            settleTimer = nil
        }
    }

    private func scheduleBatchOffer() {
        batchTimer?.invalidate()
        batchTimer = Timer.scheduledTimer(withTimeInterval: Timing.batchQuiet, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.batchTimer = nil
            guard !self.pendingReview.isEmpty else { return }
            // Something still settling? Its own settle will re-schedule us.
            guard self.watches.values.allSatisfy({ $0.candidates.isEmpty }) else { return }
            self.onBatchReady?(self.pendingReview.count)
        }
    }

    private func refreshRemoteTimer() {
        let hasRemote = watches.values.contains { !$0.isLocalVolume }
        if hasRemote, remoteTimer == nil {
            remoteTimer = Timer.scheduledTimer(withTimeInterval: Timing.remotePoll, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                for watch in self.watches.values where !watch.isLocalVolume {
                    self.reconcile(watch)
                }
            }
        } else if !hasRemote {
            remoteTimer?.invalidate()
            remoteTimer = nil
        }
    }

    // MARK: - Persistence

    private var seenSets: [String: [String: FileStamp]] = [:]

    private func supportFile(_ name: String) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("MKVQuickPlay", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    private func loadConfigs() {
        guard let data = UserDefaults.standard.data(forKey: configKey),
              let decoded = try? JSONDecoder().decode([FolderConfig].self, from: data) else { return }
        configs = decoded
    }

    private func saveConfigs() {
        if let data = try? JSONEncoder().encode(configs) {
            UserDefaults.standard.set(data, forKey: configKey)
        }
    }

    private func loadSeenSets() {
        guard let url = supportFile("watch-seen.json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: [String: FileStamp]].self, from: data) else { return }
        seenSets = decoded
    }

    private func saveSeenSets() {
        for (path, watch) in watches { seenSets[path] = watch.seen }
        // Drop seen-sets for folders no longer watched.
        let known = Set(configs.compactMap { resolve($0)?.path ?? $0.displayPath })
        seenSets = seenSets.filter { known.contains($0.key) }
        guard let url = supportFile("watch-seen.json"),
              let data = try? JSONEncoder().encode(seenSets) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
