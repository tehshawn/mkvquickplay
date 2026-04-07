import Foundation

// MARK: - FileEntry

/// Represents a single video file and its perceptual hash fingerprint.
struct FileEntry: Identifiable, Hashable {
    let id: UUID
    let url: URL

    /// File size in bytes.
    var fileSize: Int64
    /// Duration in seconds.
    var duration: Double
    /// Native pixel width.
    var pixelWidth: Int
    /// Native pixel height.
    var pixelHeight: Int

    /// 8 pHash values sampled evenly across the video's timeline.
    var frameHashes: [UInt64]

    /// Whether the user has marked this file for deletion.
    var markedForDeletion: Bool

    init(url: URL, fileSize: Int64, duration: Double,
         pixelWidth: Int, pixelHeight: Int, frameHashes: [UInt64]) {
        self.id = UUID()
        self.url = url
        self.fileSize = fileSize
        self.duration = duration
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.frameHashes = frameHashes
        self.markedForDeletion = false
    }

    // MARK: Computed helpers

    var filename: String { url.lastPathComponent }
    var fileSizeFormatted: String { ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file) }
    var durationFormatted: String {
        let m = Int(duration) / 60
        let s = Int(duration) % 60
        return String(format: "%d:%02d", m, s)
    }
    var resolutionFormatted: String { "\(pixelWidth)×\(pixelHeight)" }
    var pixelCount: Int { pixelWidth * pixelHeight }

    // Hashable & Equatable via id
    static func == (lhs: FileEntry, rhs: FileEntry) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - DuplicateGroup

/// A set of two or more videos that are visually similar to each other.
struct DuplicateGroup: Identifiable {
    let id: UUID
    /// All entries in this group (≥ 2).
    var entries: [FileEntry]
    /// Average similarity across the best-matching frame pairs (0.0–1.0).
    var similarity: Double

    init(entries: [FileEntry], similarity: Double) {
        self.id = UUID()
        self.entries = entries
        self.similarity = similarity
    }

    // MARK: Computed helpers

    var markedCount: Int { entries.filter(\.markedForDeletion).count }

    /// Total space that could be reclaimed by deleting every marked entry.
    var reclaimableBytes: Int64 { entries.filter(\.markedForDeletion).reduce(0) { $0 + $1.fileSize } }

    /// The entry with the highest pixel count (suggested "keep" copy).
    var bestEntry: FileEntry? { entries.max(by: { $0.pixelCount < $1.pixelCount }) }

    var similarityFormatted: String { String(format: "%.0f%%", similarity * 100) }
}
