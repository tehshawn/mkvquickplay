import Foundation
import Combine

// MARK: - ScanEngine

/// Orchestrates directory scanning, hashing, and duplicate detection.
/// All published properties are safe to observe from SwiftUI on the main actor.
@MainActor
final class ScanEngine: ObservableObject {

    // MARK: - Published State

    @Published var scanDirectories: [URL] = []
    @Published var threshold: Double = 0.85
    @Published var isScanning: Bool = false
    @Published var progress: Double = 0.0
    @Published var statusMessage: String = ""
    @Published var duplicateGroups: [DuplicateGroup] = []
    @Published var errorMessage: String? = nil

    // MARK: - Scan

    private var scanTask: Task<Void, Never>?

    /// Start a full scan: enumerate → hash → detect.
    func startScan() {
        guard !isScanning else { return }
        scanTask?.cancel()
        isScanning = true
        progress = 0
        statusMessage = "Enumerating files…"
        duplicateGroups = []
        errorMessage = nil

        let directories = scanDirectories
        let threshold = self.threshold

        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                // 1. Enumerate video files
                let urls = Self.enumerateVideoFiles(in: directories)
                let total = urls.count

                await MainActor.run { self?.statusMessage = "Found \(total) video files" }

                guard total > 0 else {
                    await MainActor.run {
                        self?.statusMessage = "No video files found in selected directories."
                        self?.isScanning = false
                    }
                    return
                }

                // 2. Hash each file
                var entries: [FileEntry] = []
                entries.reserveCapacity(total)

                for (idx, url) in urls.enumerated() {
                    try Task.checkCancellation()

                    await MainActor.run {
                        self?.progress = Double(idx) / Double(total) * 0.85
                        self?.statusMessage = "Hashing \(idx + 1) / \(total): \(url.lastPathComponent)"
                    }

                    do {
                        let info = try await VideoHasher.hash(url: url)
                        let entry = FileEntry(
                            url: url,
                            fileSize: info.fileSize,
                            duration: info.duration,
                            pixelWidth: info.pixelWidth,
                            pixelHeight: info.pixelHeight,
                            frameHashes: info.frameHashes
                        )
                        entries.append(entry)
                    } catch {
                        // Skip files that can't be hashed (corrupt, DRM, etc.)
                        continue
                    }
                }

                await MainActor.run {
                    self?.progress = 0.9
                    self?.statusMessage = "Detecting duplicates…"
                }

                // 3. Detect duplicates
                let groups = DuplicateDetector.detect(entries: entries, threshold: threshold)

                await MainActor.run {
                    self?.duplicateGroups = groups
                    self?.progress = 1.0
                    self?.isScanning = false
                    if groups.isEmpty {
                        self?.statusMessage = "No duplicates found among \(entries.count) videos."
                    } else {
                        let fileCount = groups.reduce(0) { $0 + $1.entries.count }
                        self?.statusMessage = "Found \(groups.count) duplicate groups (\(fileCount) files)."
                    }
                }

            } catch is CancellationError {
                await MainActor.run {
                    self?.isScanning = false
                    self?.statusMessage = "Scan cancelled."
                }
            } catch {
                await MainActor.run {
                    self?.isScanning = false
                    self?.errorMessage = error.localizedDescription
                    self?.statusMessage = "Scan failed."
                }
            }
        }
    }

    /// Cancel an in-progress scan.
    func cancelScan() {
        scanTask?.cancel()
    }

    // MARK: - Deletion

    /// Move all marked files to the system Trash.
    func deleteMarked() async {
        let markedURLs: [(groupIdx: Int, entryIdx: Int, url: URL)] = duplicateGroups
            .enumerated()
            .flatMap { (gi, group) in
                group.entries.enumerated().compactMap { (ei, entry) in
                    entry.markedForDeletion ? (gi, ei, entry.url) : nil
                }
            }

        guard !markedURLs.isEmpty else { return }

        var failedPaths: [String] = []

        for item in markedURLs {
            do {
                var trashURL: NSURL?
                try FileManager.default.trashItem(at: item.url, resultingItemURL: &trashURL)
            } catch {
                failedPaths.append(item.url.lastPathComponent)
            }
        }

        // Remove deleted entries from groups; drop singleton groups
        var updatedGroups: [DuplicateGroup] = []
        for group in duplicateGroups {
            var updated = group
            updated.entries = updated.entries.filter { entry in
                // Keep if: not marked, or was marked but trash failed
                !entry.markedForDeletion || failedPaths.contains(entry.url.lastPathComponent)
            }
            if updated.entries.count >= 2 {
                updatedGroups.append(updated)
            }
        }
        duplicateGroups = updatedGroups

        if failedPaths.isEmpty {
            statusMessage = "Moved \(markedURLs.count) file(s) to Trash."
        } else {
            errorMessage = "Failed to trash: \(failedPaths.joined(separator: ", "))"
        }
    }

    // MARK: - Auto-mark

    /// For every group, mark all entries except the highest-resolution one.
    func autoMarkAllGroups() {
        for i in duplicateGroups.indices {
            guard let best = duplicateGroups[i].bestEntry else { continue }
            for j in duplicateGroups[i].entries.indices {
                duplicateGroups[i].entries[j].markedForDeletion =
                    duplicateGroups[i].entries[j].id != best.id
            }
        }
    }

    // MARK: - Computed

    var totalMarkedCount: Int {
        duplicateGroups.reduce(0) { $0 + $1.markedCount }
    }

    var totalReclaimableBytes: Int64 {
        duplicateGroups.reduce(0) { $0 + $1.reclaimableBytes }
    }

    // MARK: - File Enumeration

    private static let videoExtensions: Set<String> = [
        "mkv", "mp4", "mov", "avi", "m4v", "webm", "wmv", "flv", "ts", "m2ts", "mts", "mpg", "mpeg"
    ]

    private static func enumerateVideoFiles(in directories: [URL]) -> [URL] {
        var result: [URL] = []
        let fm = FileManager.default
        for dir in directories {
            guard let enumerator = fm.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let ext = url.pathExtension.lowercased()
                if videoExtensions.contains(ext) {
                    result.append(url)
                }
            }
        }
        return result
    }
}
