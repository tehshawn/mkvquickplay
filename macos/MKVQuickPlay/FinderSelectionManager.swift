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

    /// Normalized path for reliable comparison across URL representations
    /// (file-reference URLs, symlinks, /private prefixes, trailing slashes).
    func normalizedPath(_ url: URL) -> String {
        return url.resolvingSymlinksInPath().standardizedFileURL.path
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

    /// Ask Finder for the videos in the file's folder, in the order Finder
    /// currently displays them (any sort: Name, Kind, Date, Size, or manual).
    /// Returns nil if Finder can't be queried (no matching window, permission
    /// denied) so the caller can fall back to alphabetical ordering.
    func orderedVideoFiles(inFolderOf url: URL) -> [URL]? {
        guard let (key, reversed) = finderSortSettings(forFolderOf: url) else { return nil }
        let videos = getSiblingVideoFiles(for: url)
        guard !videos.isEmpty else { return nil }
        return sortedVideos(videos, by: key, reversed: reversed)
    }

    private enum SortKey: String {
        case name, kind, modified, created, size
    }

    /// Ask Finder for the active window's sort column/arrangement and direction.
    /// Returns nil if Finder can't be queried (no window, permission denied).
    private func finderSortSettings(forFolderOf url: URL) -> (SortKey, reversed: Bool)? {
        let folderPath = url.deletingLastPathComponent().path
        let escaped = folderPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let source = """
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
                set sc to sort column of list view options of theWindow
                set cn to name of sc
                if cn is name column then
                    set sortKey to "name"
                else if cn is kind column then
                    set sortKey to "kind"
                else if cn is modification date column then
                    set sortKey to "modified"
                else if cn is creation date column then
                    set sortKey to "created"
                else if cn is size column then
                    set sortKey to "size"
                end if
                if (sort direction of sc) is reversed then set sortDir to "reversed"
            else if theView is icon view then
                set arr to arrangement of icon view options of theWindow
                if arr is arranged by name then
                    set sortKey to "name"
                else if arr is arranged by kind then
                    set sortKey to "kind"
                else if arr is arranged by modification date then
                    set sortKey to "modified"
                else if arr is arranged by creation date then
                    set sortKey to "created"
                else if arr is arranged by size then
                    set sortKey to "size"
                end if
            end if
            return sortKey & "|" & sortDir
        end tell
        """

        guard let script = NSAppleScript(source: source) else { return nil }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo = errorInfo {
            NSLog("[FinderSelectionManager] Finder sort query failed: \(errorInfo)")
            return nil
        }
        guard let output = result.stringValue else { return nil }
        let parts = output.split(separator: "|").map(String.init)
        guard parts.count == 2, let key = SortKey(rawValue: parts[0]) else { return nil }
        return (key, reversed: parts[1] == "reversed")
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

        // Sort ascending with filename as a stable tiebreaker, then flip if reversed.
        let ascending = urls.sorted { lhs, rhs in
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
            return order == .orderedAscending
        }
        return reversed ? ascending.reversed() : ascending
    }

    /// Get the next video file in the directory, or nil if already at the last.
    func getNextVideoFile(after currentURL: URL) -> URL? {
        return nextFile(after: currentURL, in: getSiblingVideoFiles(for: currentURL))
    }

    /// Get the previous video file in the directory, or nil if already at the first.
    func getPreviousVideoFile(before currentURL: URL) -> URL? {
        return previousFile(before: currentURL, in: getSiblingVideoFiles(for: currentURL))
    }
}
