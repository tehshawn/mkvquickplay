import Cocoa

/// Manages video file identification and directory navigation
class FinderSelectionManager {

    /// Supported video file extensions
    static let supportedExtensions = ["mkv", "avi", "webm", "mp4", "m4v", "mov", "wmv", "flv", "ts", "mts", "m2ts"]

    /// Check if a URL is a supported video file
    func isVideoFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return Self.supportedExtensions.contains(ext)
    }

    /// Cache for normalizedPath: symlink resolution stats every path component,
    /// and playlist lookups run it per element per keypress. Main-thread only.
    /// Scoped to one preview session (see `resetPathCache`) so a retargeted
    /// symlink or remounted volume can't leave stale resolutions behind.
    private var pathCache: [String: String] = [:]

    /// Serial queue for Finder sort queries: the Apple Event round-trip (and
    /// the first-run Automation consent prompt) must never block the main
    /// thread, where mpv's navigation callbacks are delivered.
    private let queryQueue = DispatchQueue(label: "com.mkvquickplay.findersort", qos: .userInitiated)

    /// Separate serial queue for "reveal in Finder" requests, so following
    /// the playing file never waits behind a slow sort query.
    private let revealQueue = DispatchQueue(label: "com.mkvquickplay.finderreveal", qos: .userInitiated)

    /// Monotonic id of the latest reveal request: rapid navigation only ever
    /// reveals the file the user ended up on, not every intermediate one.
    private var revealSerial = 0

    /// Whether the user has denied the Automation permission — skip further
    /// Finder queries instead of re-prompting the TCC machinery. Cleared again
    /// by any later successful query, so flipping the switch back on in
    /// System Settings takes effect without relaunching. Guarded by stateLock.
    private var automationDenied = false
    private let stateLock = NSLock()

    private var isAutomationDenied: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return automationDenied
    }

    private func setAutomationDenied(_ denied: Bool) {
        stateLock.lock()
        automationDenied = denied
        stateLock.unlock()
    }

    /// Normalized path for reliable comparison across URL representations
    /// (file-reference URLs, symlinks, /private prefixes, trailing slashes).
    func normalizedPath(_ url: URL) -> String {
        let key = url.path
        if let cached = pathCache[key] { return cached }
        let value = url.resolvingSymlinksInPath().standardizedFileURL.path
        if pathCache.count > 8192 { pathCache.removeAll(keepingCapacity: true) }
        pathCache[key] = value
        return value
    }

    /// Forget cached symlink resolutions — call at the start of each preview
    /// session. The cache only exists to make per-keypress playlist lookups
    /// cheap within one playlist, so a per-session lifetime loses nothing.
    func resetPathCache() {
        pathCache.removeAll(keepingCapacity: true)
    }

    /// Filter a set of URLs down to supported video files, sorted by name
    /// (the order QuickLook uses for a multi-file selection).
    func sortedVideoFiles(from urls: [URL]) -> [URL] {
        return urls
            .filter { isVideoFile($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Index of a URL within a list, matched by normalized path.
    func index(of url: URL, in files: [URL]) -> Int? {
        let target = normalizedPath(url)
        return files.firstIndex { normalizedPath($0) == target }
    }

    /// Next file after `current` within `files`, or nil if already at the end.
    func nextFile(after current: URL, in files: [URL]) -> URL? {
        guard let idx = index(of: current, in: files) else { return nil }
        let next = idx + 1
        return next < files.count ? files[next] : nil
    }

    /// Previous file before `current` within `files`, or nil if at the start.
    func previousFile(before current: URL, in files: [URL]) -> URL? {
        guard let idx = index(of: current, in: files) else { return nil }
        let prev = idx - 1
        return prev >= 0 ? files[prev] : nil
    }

    /// Get sibling video files in the same directory, sorted by name
    func getSiblingVideoFiles(for url: URL) -> [URL] {
        let directory = url.deletingLastPathComponent()

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )

            let videoFiles = contents
                .filter { isVideoFile($0) }
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

            return videoFiles
        } catch {
            NSLog("[FinderSelectionManager] Error reading directory: \(error)")
            return []
        }
    }

    // MARK: - Finder queries

    /// Ask Finder for its current selection (used by the global hotkey, which
    /// arrives with no pasteboard, unlike a Service invocation). Runs off-main;
    /// completes on the main thread. `urls` is nil when the query itself
    /// failed (never conflate that with an empty selection); `automationDenied`
    /// reports whether *this* query failed because Automation was declined.
    func fetchFinderSelection(completion: @escaping (_ urls: [URL]?, _ automationDenied: Bool) -> Void) {
        let source = """
        with timeout of 3 seconds
            tell application "Finder"
                set out to ""
                repeat with itm in (get selection)
                    try
                        set out to out & (POSIX path of (itm as alias)) & linefeed
                    end try
                end repeat
                return out
            end tell
        end timeout
        """
        queryQueue.async { [weak self] in
            guard let self = self else { return }
            let urls: [URL]?
            let denied: Bool
            switch self.runAppleScript(source) {
            case .output(let text):
                urls = text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
                denied = false
            case .denied:
                urls = nil
                denied = true
            case .failed:
                urls = nil
                denied = false
            }
            DispatchQueue.main.async { completion(urls, denied) }
        }
    }

    /// Move Finder's selection to `url` *without* activating Finder, so the
    /// mpv window keeps keyboard focus — `reveal` scrolls the file into view
    /// in an existing window for its folder (or opens one, behind the player).
    /// Completes on the main thread with `false` when Finder could not be
    /// scripted (permission declined, timeout), so the caller can fall back
    /// to NSWorkspace, which does activate Finder. Superseded requests (the
    /// user kept navigating) complete with `true` and do nothing.
    func revealInFinder(_ url: URL, completion: @escaping (_ revealed: Bool) -> Void) {
        guard !isAutomationDenied else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        stateLock.lock()
        revealSerial += 1
        let serial = revealSerial
        stateLock.unlock()

        let escaped = Self.escapedForAppleScript(url.path)
        let source = """
        with timeout of 3 seconds
            tell application "Finder"
                reveal ((POSIX file "\(escaped)") as alias)
            end tell
        end timeout
        """
        revealQueue.async { [weak self] in
            guard let self = self else { return }
            self.stateLock.lock()
            let superseded = (serial != self.revealSerial)
            self.stateLock.unlock()
            if superseded {
                DispatchQueue.main.async { completion(true) }
                return
            }
            let revealed: Bool
            if case .output = self.runAppleScript(source) {
                revealed = true
            } else {
                revealed = false
            }
            DispatchQueue.main.async { completion(revealed) }
        }
    }

    /// Ask Finder for the videos in the file's folder, in the order Finder
    /// currently displays them (List/Icon sorts: Name, Kind, Date, Size).
    /// Runs entirely off the main thread; completes on the main thread with
    /// nil when Finder can't be queried (no matching window, unmapped sort
    /// column, permission denied) so the caller keeps the alphabetical order.
    func orderedVideoFiles(inFolderOf url: URL, completion: @escaping ([URL]?) -> Void) {
        queryQueue.async { [weak self] in
            var result: [URL]? = nil
            if let self = self,
               let (key, reversed) = self.finderSortSettings(forFolderOf: url) {
                let videos = self.getSiblingVideoFiles(for: url)
                if !videos.isEmpty {
                    result = self.sortedVideos(videos, by: key, reversed: reversed)
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private enum SortKey: String {
        case name, kind, modified, created, size
    }

    private static func escapedForAppleScript(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Ask Finder for the sort column/arrangement and direction of the window
    /// showing the file's folder. Returns nil if Finder can't be queried
    /// (permission denied), no window shows that folder, or the view's sort
    /// can't be mapped — the caller then keeps the honest alphabetical order
    /// rather than borrowing some other window's sort.
    private func finderSortSettings(forFolderOf url: URL) -> (SortKey, reversed: Bool)? {
        // Permission was denied earlier — don't keep asking.
        guard !isAutomationDenied else { return nil }

        let escaped = Self.escapedForAppleScript(url.deletingLastPathComponent().path)

        // `with timeout` bounds the Apple Event reply wait so a busy Finder
        // degrades to the alphabetical fallback instead of hanging the app.
        // Sort columns we can't map (Date Added, Tags, …) return "" — taking
        // the honest fallback rather than misapplying the column's direction
        // to an alphabetical list.
        let source = """
        with timeout of 3 seconds
            tell application "Finder"
                try
                    set targetFolder to (POSIX file "\(escaped)") as alias
                on error
                    return ""
                end try
                set theWindow to missing value
                repeat with w in (Finder windows)
                    try
                        if (target of w as alias) is targetFolder then
                            set theWindow to w
                            exit repeat
                        end if
                    end try
                end repeat
                if theWindow is missing value then return ""
                set theView to current view of theWindow
                set sortKey to "name"
                set sortDir to "normal"
                if theView is list view then
                    set known to false
                    set sc to sort column of list view options of theWindow
                    set cn to name of sc
                    if cn is name column then
                        set sortKey to "name"
                        set known to true
                    else if cn is kind column then
                        set sortKey to "kind"
                        set known to true
                    else if cn is modification date column then
                        set sortKey to "modified"
                        set known to true
                    else if cn is creation date column then
                        set sortKey to "created"
                        set known to true
                    else if cn is size column then
                        set sortKey to "size"
                        set known to true
                    end if
                    if not known then return ""
                    if (sort direction of sc) is reversed then set sortDir to "reversed"
                else if theView is icon view then
                    set known to false
                    set arr to arrangement of icon view options of theWindow
                    if arr is arranged by name then
                        set sortKey to "name"
                        set known to true
                    else if arr is arranged by kind then
                        set sortKey to "kind"
                        set known to true
                    else if arr is arranged by modification date then
                        set sortKey to "modified"
                        set known to true
                    else if arr is arranged by creation date then
                        set sortKey to "created"
                        set known to true
                    else if arr is arranged by size then
                        set sortKey to "size"
                        set known to true
                    end if
                    if not known then return ""
                end if
                return sortKey & "|" & sortDir
            end tell
        end timeout
        """

        guard case .output(let output) = runAppleScript(source) else { return nil }
        let parts = output.split(separator: "|").map(String.init)
        guard parts.count == 2, let key = SortKey(rawValue: parts[0]) else { return nil }
        return (key, reversed: parts[1] == "reversed")
    }

    /// Reads a pipe to EOF on a background queue from the moment it is
    /// created, so the child can never block on a full pipe buffer.
    private final class PipeDrain {
        private var collected = Data()
        private let done = DispatchGroup()

        init(_ pipe: Pipe) {
            done.enter()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                self.collected = pipe.fileHandleForReading.readDataToEndOfFile()
                self.done.leave()
            }
        }

        /// Blocks until the writer closes the pipe (i.e. the child exited).
        func data() -> Data {
            done.wait()
            return collected
        }
    }

    private enum ScriptResult {
        case output(String)
        /// The user declined the Automation permission (-1743).
        case denied
        /// Anything else: timeout, no Finder window, osascript killed.
        case failed
    }

    /// Run an AppleScript via an osascript subprocess and return its stdout.
    /// A subprocess (rather than NSAppleScript, which is main-thread bound and
    /// blocks unboundedly on the TCC consent prompt) keeps the query fully
    /// isolated: it runs on a background queue and a wedged Finder gets
    /// hard-killed. Apple Events sent by the child are attributed to this app
    /// (responsible process), so the existing Automation grant applies.
    /// Thread-safe; callers serialize on their own queues.
    private func runAppleScript(_ source: String) -> ScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            NSLog("[FinderSelectionManager] Could not run osascript: \(error)")
            return .failed
        }

        // The in-script `with timeout` bounds Finder's reply; this bounds a
        // wedged osascript itself. 30s leaves room for the one-time Automation
        // consent prompt, which blocks the child until the user answers.
        // Escalate to SIGKILL so a child that ignores SIGTERM can't wedge the
        // queue (and with it the hotkey) for the rest of the session.
        let killer = DispatchWorkItem {
            if process.isRunning { process.terminate() }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30, execute: killer)

        // Drain both pipes *before* waiting: a pipe holds 64 KB, and a large
        // Finder selection prints more than that, which would otherwise leave
        // osascript blocked on write() until the killer fires.
        let out = PipeDrain(stdout)
        let err = PipeDrain(stderr)
        process.waitUntilExit()
        killer.cancel()
        let outData = out.data()
        let errData = err.data()

        if process.terminationStatus != 0 {
            let message = String(data: errData, encoding: .utf8) ?? ""
            // -1743 = errAEEventNotPermitted: the user declined Automation
            // access. Remember it so we stop querying until a query succeeds.
            if message.contains("-1743") {
                setAutomationDenied(true)
                NSLog("[FinderSelectionManager] Automation permission denied — using alphabetical order")
                return .denied
            }
            NSLog("[FinderSelectionManager] Finder query failed: \(message)")
            return .failed
        }

        setAutomationDenied(false)
        let text = String(data: outData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .output(text)
    }

    /// Sort video URLs to mirror Finder's chosen column/arrangement.
    private func sortedVideos(_ urls: [URL], by key: SortKey, reversed: Bool) -> [URL] {
        // Fetch each file's sort key once up front (decorate-sort-undecorate)
        // rather than inside the comparator: a Kind sort of a 500-video folder
        // would otherwise make thousands of LaunchServices/stat calls, which
        // on a network volume keeps the query queue busy for seconds.
        struct Entry {
            let url: URL
            let name: String
            let kind: String
            let date: Date
            let size: Int
        }
        let entries: [Entry] = urls.map { url in
            let values = try? url.resourceValues(forKeys: [
                .localizedTypeDescriptionKey, .contentModificationDateKey, .creationDateKey, .fileSizeKey,
            ])
            let date: Date
            switch key {
            case .created: date = values?.creationDate ?? .distantPast
            default: date = values?.contentModificationDate ?? .distantPast
            }
            return Entry(url: url,
                         name: url.lastPathComponent,
                         kind: values?.localizedTypeDescription ?? "",
                         date: date,
                         size: values?.fileSize ?? 0)
        }

        // Apply the direction to the primary key only — Finder tie-breaks equal
        // primary keys by name ascending regardless of the sort direction, so
        // reversing the whole array (tiebreaker included) would flip an
        // all-same-kind folder into exact reverse-alphabetical order.
        return entries.sorted { lhs, rhs in
            let order: ComparisonResult
            switch key {
            case .name:
                order = lhs.name.localizedStandardCompare(rhs.name)
            case .kind:
                order = lhs.kind.localizedStandardCompare(rhs.kind)
            case .modified, .created:
                order = lhs.date.compare(rhs.date)
            case .size:
                order = lhs.size == rhs.size ? .orderedSame : (lhs.size < rhs.size ? .orderedAscending : .orderedDescending)
            }
            if order == .orderedSame {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return reversed ? order == .orderedDescending : order == .orderedAscending
        }.map { $0.url }
    }
}
