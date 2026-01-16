import Cocoa

/// Manages querying Finder for selected files and navigation
class FinderSelectionManager {

    /// Supported video file extensions
    static let supportedExtensions = ["mkv", "avi", "webm", "mp4", "m4v", "mov", "wmv", "flv", "ts", "mts", "m2ts"]

    /// Get the currently selected file in Finder
    func getSelectedVideoFile() -> URL? {
        let selectedFiles = getFinderSelection()
        return selectedFiles.first { isVideoFile($0) }
    }

    /// Get all selected files in Finder
    func getFinderSelection() -> [URL] {
        let script = """
        tell application "Finder"
            set selectedItems to selection
            set filePaths to ""
            repeat with anItem in selectedItems
                try
                    set filePaths to filePaths & (POSIX path of (anItem as alias)) & linefeed
                end try
            end repeat
            return filePaths
        end tell
        """

        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            NSLog("[FinderSelectionManager] Failed to create AppleScript")
            return []
        }

        let result = appleScript.executeAndReturnError(&error)

        if let error = error {
            NSLog("[FinderSelectionManager] AppleScript error: \(error)")
            return []
        }

        guard let output = result.stringValue else {
            return []
        }

        let paths = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return paths.map { URL(fileURLWithPath: $0) }
    }

    /// Check if a URL is a supported video file
    func isVideoFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return Self.supportedExtensions.contains(ext)
    }

    /// Get sibling video files in the same directory
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
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

            return videoFiles
        } catch {
            NSLog("[FinderSelectionManager] Error reading directory: \(error)")
            return []
        }
    }

    /// Get the next video file in the directory
    func getNextVideoFile(after currentURL: URL) -> URL? {
        let siblings = getSiblingVideoFiles(for: currentURL)
        guard let currentIndex = siblings.firstIndex(of: currentURL) else { return nil }

        let nextIndex = currentIndex + 1
        if nextIndex < siblings.count {
            return siblings[nextIndex]
        }

        // Wrap around to first file
        return siblings.first
    }

    /// Get the previous video file in the directory
    func getPreviousVideoFile(before currentURL: URL) -> URL? {
        let siblings = getSiblingVideoFiles(for: currentURL)
        guard let currentIndex = siblings.firstIndex(of: currentURL) else { return nil }

        let prevIndex = currentIndex - 1
        if prevIndex >= 0 {
            return siblings[prevIndex]
        }

        // Wrap around to last file
        return siblings.last
    }

    /// Check if Finder is the frontmost application
    func isFinderFrontmost() -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
        return frontmost.bundleIdentifier == "com.apple.finder"
    }
}
