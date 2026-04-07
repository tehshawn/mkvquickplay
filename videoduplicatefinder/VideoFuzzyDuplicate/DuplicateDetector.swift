import Foundation

// MARK: - DuplicateDetector

/// Compares perceptual hashes between video files and groups duplicates
/// using a union-find algorithm for transitive closure.
enum DuplicateDetector {

    // MARK: - Public API

    /// Find all groups of duplicate videos among `entries`.
    /// - Parameter entries: All scanned file entries with their pHash fingerprints.
    /// - Parameter threshold: Minimum similarity (0.0–1.0) to consider two files duplicates.
    /// - Returns: Array of duplicate groups (each group has ≥ 2 entries).
    static func detect(entries: [FileEntry], threshold: Double) -> [DuplicateGroup] {
        let n = entries.count
        guard n >= 2 else { return [] }

        // Union-find parent array
        var parent = Array(0..<n)

        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }

        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        // Track best similarity for each pair that gets merged
        var groupSimilarity = [Int: Double]()  // representative index → best similarity

        // O(n²) pairwise comparison
        for i in 0..<n {
            for j in (i + 1)..<n {
                let sim = frameSetSimilarity(entries[i].frameHashes, entries[j].frameHashes)
                if sim >= threshold {
                    let ri = find(i)
                    // Merge and track max similarity
                    union(i, j)
                    let newRoot = find(i)
                    let prev = groupSimilarity[newRoot] ?? 0
                    groupSimilarity[newRoot] = max(prev, sim)
                }
            }
        }

        // Collect groups by root
        var rootToIndices = [Int: [Int]]()
        for i in 0..<n {
            let root = find(i)
            rootToIndices[root, default: []].append(i)
        }

        // Build DuplicateGroup for every group with ≥ 2 members
        var groups: [DuplicateGroup] = []
        for (root, indices) in rootToIndices where indices.count >= 2 {
            let groupEntries = indices.map { entries[$0] }
            let sim = groupSimilarity[root] ?? threshold
            groups.append(DuplicateGroup(entries: groupEntries, similarity: sim))
        }

        // Sort by most similar first, then by largest wasted space
        groups.sort {
            if abs($0.similarity - $1.similarity) > 0.005 { return $0.similarity > $1.similarity }
            let waste0 = $0.entries.sorted(by: { $0.fileSize > $1.fileSize }).dropFirst().reduce(0) { $0 + $1.fileSize }
            let waste1 = $1.entries.sorted(by: { $0.fileSize > $1.fileSize }).dropFirst().reduce(0) { $0 + $1.fileSize }
            return waste0 > waste1
        }

        return groups
    }

    // MARK: - Similarity

    /// Compute the average per-frame Hamming similarity between two sets of frame hashes.
    /// Uses a best-window alignment so partial clips are also matched correctly.
    static func frameSetSimilarity(_ a: [UInt64], _ b: [UInt64]) -> Double {
        guard !a.isEmpty && !b.isEmpty else { return 0 }

        // If both are the same length: direct frame-by-frame comparison
        if a.count == b.count {
            let total = a.indices.reduce(0.0) { $0 + hammingSimilarity(a[$1], b[$1]) }
            return total / Double(a.count)
        }

        // Sliding window: align shorter sequence against longer, pick best window
        let (shorter, longer) = a.count <= b.count ? (a, b) : (b, a)
        var bestScore = 0.0
        let windowCount = longer.count - shorter.count + 1
        for offset in 0..<windowCount {
            var score = 0.0
            for i in 0..<shorter.count {
                score += hammingSimilarity(shorter[i], longer[offset + i])
            }
            score /= Double(shorter.count)
            bestScore = max(bestScore, score)
        }
        return bestScore
    }

    // MARK: - Hamming

    /// Hamming distance between two 64-bit hashes (number of differing bits).
    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    /// Similarity as a fraction: 1 - (hammingDistance / 64).
    static func hammingSimilarity(_ a: UInt64, _ b: UInt64) -> Double {
        1.0 - Double(hammingDistance(a, b)) / 64.0
    }
}
