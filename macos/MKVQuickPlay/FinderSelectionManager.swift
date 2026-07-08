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
    private var pathCache: [String: String] = [:]

    /// Serial queue for Finder sort queries: the Apple Event round-trip (and
    /// the first-run Automation consent prompt) must never block the main
    /// thread, where mpv's navigation callbacks are delivered.
    private let queryQueue = DispatchQueue(label: "com.mkvquickplay.findersort", qos: .userInitiated)

    /// Whether the user has denied the Automation permission this session —
    /// skip further Finder queries instead of re-prompting the TCC machinery.
    /// Confined to queryQueue.
    private var automationDenied = false

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

    /// Ask Finder for its current selection (used by the global hotkey, which
    /// arrives with no pasteboard, unlike a Service invocation). Runs off-main;
    /// completes on the main thread. `urls` is nil when the query itself
    /// failed (never conflate that with an empty selection); `automationDenied`
    /// reports whether the failure was a declined Automation permission.
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
            let output = self.runAppleScript(source)
            let denied = self.automationDenied
            let urls = output.map { text in
                text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            }
            DispatchQueue.main.async { completion(urls, denied) }
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

    /// Ask Finder for the active window's sort column/arrangement and direction.
    /// Returns nil if Finder can't be queried (no window, permission denied).
    private func finderSortSettings(forFolderOf url: URL) -> (SortKey, reversed: Bool)? {
        // Permission was denied earlier this session — don't keep asking.
        guard !automationDenied else { return nil }

        let folderPath = url.deletingLastPathComponent().path
        let escaped = folderPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

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
                if theWindow is missing value then
                    if (count of Finder windows) > 0 then set theWindow to front Finder window
                end if
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

        guard let output = runAppleScript(source) else { return nil }
        let parts = output.split(separator: "|").map(String.init)
        guard parts.count == 2, let key = SortKey(rawValue: parts[0]) else { return nil }
        return (key, reversed: parts[1] == "reversed")
    }

    /// Run an AppleScript via an osascript subprocess and return its stdout.
    /// A subprocess (rather than NSAppleScript, which is main-thread bound and
    /// blocks unboundedly on the TCC consent prompt) keeps the query fully
    /// isolated: it runs on queryQueue and a wedged Finder gets hard-killed.
    /// Apple Events sent by the child are attributed to this app (responsible
    /// process), so the existing Automation grant applies. queryQueue-confined.
    private func runAppleScript(_ source: String) -> String? {
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
            return nil
        }

        // The in-script `with timeout` bounds Finder's reply; this bounds a
        // wedged osascript itself. 30s leaves room for the one-time Automation
        // consent prompt, which blocks the child until the user answers.
        let killer = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30, execute: killer)
        process.waitUntilExit()
        killer.cancel()

        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let message = String(data: errData, encoding: .utf8) ?? ""
            // -1743 = errAEEventNotPermitted: the user declined Automation
            // access. Remember it so we stop querying for this session.
            if message.contains("-1743") {
                automationDenied = true
                NSLog("[FinderSelectionManager] Automation permission denied — using alphabetical order this session")
            } else {
                NSLog("[FinderSelectionManager] Finder sort query failed: \(message)")
            }
            return nil
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: outData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sort video URLs to mirror Finder's chosen column/arrangement.
    private func sortedVideos(_ urls: [URL], by key: SortKey, reversed: Bool) -> [URL] {
        func name(_ u: URL) -> String { u.lastPathComponent }
        func kind(_ u: URL) -> String {
            (try? u.resourceValues(forKeys: [.localizedTypeDescriptionKey]).localizedTypeDescription) ?? ""
        }
        func date(_ u: URL, _ rk: URLResourceKey) -> Date {
            let v = try? u.resourceValues(forKeys: [rk])
            switch rk {
            case .creationDateKey: return v?.creationDate ?? .distantPast
            default: return v?.contentModificationDate ?? .distantPast
            }
        }
        func size(_ u: URL) -> Int {
            (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }

        // Apply the direction to the primary key only — Finder tie-breaks equal
        // primary keys by name ascending regardless of the sort direction, so
        // reversing the whole array (tiebreaker included) would flip an
        // all-same-kind folder into exact reverse-alphabetical order.
        return urls.sorted { lhs, rhs in
            let order: ComparisonResult
            switch key {
            case .name:
                order = name(lhs).localizedStandardCompare(name(rhs))
            case .kind:
                order = kind(lhs).localizedStandardCompare(kind(rhs))
            case .modified:
                order = date(lhs, .contentModificationDateKey).compare(date(rhs, .contentModificationDateKey))
            case .created:
                order = date(lhs, .creationDateKey).compare(date(rhs, .creationDateKey))
            case .size:
                let l = size(lhs), r = size(rhs)
                order = l == r ? .orderedSame : (l < r ? .orderedAscending : .orderedDescending)
            }
            if order == .orderedSame {
                return name(lhs).localizedStandardCompare(name(rhs)) == .orderedAscending
            }
            return reversed ? order == .orderedDescending : order == .orderedAscending
        }
    }
}
