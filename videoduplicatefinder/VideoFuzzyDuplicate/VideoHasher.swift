import AVFoundation
import CoreGraphics
import Accelerate

// MARK: - VideoHasher

/// Extracts perceptual hashes and metadata from a video file using AVFoundation.
/// No external dependencies — uses only system frameworks (AVFoundation + Accelerate).
enum VideoHasher {

    /// Number of frames sampled per video.
    static let frameCount = 8
    /// Side length of the thumbnail used for hashing (32×32 pixels).
    static let thumbSize = 32
    /// Number of DCT coefficients used per hash (8×8 top-left block, excluding DC term).
    static let hashBits = 64

    // MARK: - Public API

    struct VideoInfo {
        var fileSize: Int64
        var duration: Double
        var pixelWidth: Int
        var pixelHeight: Int
        var frameHashes: [UInt64]
    }

    /// Compute pHash fingerprint + metadata for the given video URL.
    /// Throws if the asset cannot be loaded or has no video tracks.
    static func hash(url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url)

        // Load duration and video track info
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)

        guard let videoTrack = tracks.first else {
            throw HashError.noVideoTrack
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let durationSeconds = duration.seconds

        // File size from filesystem
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0

        // Generate frame times spread evenly across the video
        let times = sampleTimes(duration: durationSeconds, count: frameCount)

        // Extract frames
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: thumbSize, height: thumbSize)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter  = CMTime(seconds: 1, preferredTimescale: 600)

        let cmTimes = times.map { CMTime(seconds: $0, preferredTimescale: 600) }
        var hashes: [UInt64] = []

        for time in cmTimes {
            if let image = try? generator.copyCGImage(at: time, actualTime: nil) {
                hashes.append(phash(image: image))
            }
        }

        // Need at least one hash
        guard !hashes.isEmpty else { throw HashError.noFrames }

        // Pad to frameCount if some frames failed
        while hashes.count < frameCount {
            hashes.append(hashes[hashes.count % hashes.count])
        }

        return VideoInfo(
            fileSize: fileSize,
            duration: durationSeconds,
            pixelWidth: Int(naturalSize.width),
            pixelHeight: Int(naturalSize.height),
            frameHashes: hashes
        )
    }

    // MARK: - Perceptual Hash

    /// Compute a 64-bit pHash for a single CGImage.
    ///
    /// Steps:
    /// 1. Convert to 32×32 grayscale
    /// 2. Compute 2D DCT via Accelerate's vDSP
    /// 3. Take top-left 8×8 block (64 values), skipping DC term
    /// 4. Threshold each value against the mean → bit
    static func phash(image: CGImage) -> UInt64 {
        let size = thumbSize  // 32
        var pixels = [Float](repeating: 0, count: size * size)

        // Render image into grayscale float buffer
        guard let context = CGContext(
            data: &pixels,
            width: size, height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * MemoryLayout<Float>.stride,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo.floatComponents.rawValue |
                        CGImageAlphaInfo.none.rawValue
        ) else {
            return 0
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))

        // Row-wise DCT (32-point on each row)
        let dctSetup = vDSP.DCT(count: size, transformType: .II)!
        var dct2D = [Float](repeating: 0, count: size * size)
        for row in 0..<size {
            let rowIn  = Array(pixels[row * size ..< (row + 1) * size])
            var rowOut = [Float](repeating: 0, count: size)
            dctSetup.transform(rowIn, result: &rowOut)
            dct2D[row * size ..< (row + 1) * size] = rowOut[...]
        }

        // Column-wise DCT
        var dctFinal = [Float](repeating: 0, count: size * size)
        for col in 0..<size {
            var colIn = [Float](repeating: 0, count: size)
            for row in 0..<size { colIn[row] = dct2D[row * size + col] }
            var colOut = [Float](repeating: 0, count: size)
            dctSetup.transform(colIn, result: &colOut)
            for row in 0..<size { dctFinal[row * size + col] = colOut[row] }
        }

        // Extract 8×8 top-left block (indices [0..7][0..7]), skipping DC [0][0]
        let blockSize = 8
        var block = [Float]()
        block.reserveCapacity(hashBits)
        for row in 0..<blockSize {
            for col in 0..<blockSize {
                if row == 0 && col == 0 { continue }  // skip DC term
                block.append(dctFinal[row * size + col])
            }
        }
        // Mean
        var mean: Float = 0
        vDSP_meanv(block, 1, &mean, vDSP_Length(block.count))

        // Build hash: bit = 1 if coefficient > mean
        var hash: UInt64 = 0
        for (i, val) in block.enumerated() {
            if val > mean {
                hash |= (1 << i)
            }
        }
        return hash
    }

    // MARK: - Helpers

    private static func sampleTimes(duration: Double, count: Int) -> [Double] {
        guard duration > 0 else { return [] }
        // Start at 5% and end at 95% to avoid black frames at edges
        let start = duration * 0.05
        let end   = duration * 0.95
        if count == 1 { return [(start + end) / 2] }
        let step = (end - start) / Double(count - 1)
        return (0..<count).map { start + Double($0) * step }
    }

    // MARK: - Errors

    enum HashError: Error, LocalizedError {
        case noVideoTrack
        case noFrames

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "File has no video track"
            case .noFrames:     return "Could not extract any frames"
            }
        }
    }
}
