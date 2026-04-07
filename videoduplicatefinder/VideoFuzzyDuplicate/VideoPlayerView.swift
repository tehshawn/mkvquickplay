import SwiftUI
import AVKit

// MARK: - VideoPlayerView

/// A SwiftUI-compatible inline video player backed by AVPlayerView (AppKit).
/// Plays automatically when the URL is set; replaces the player when URL changes.
struct VideoPlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .floating
        playerView.showsTimecodes = false
        playerView.player = AVPlayer(url: url)
        playerView.player?.isMuted = true  // muted by default in comparison mode
        return playerView
    }

    func updateNSView(_ playerView: AVPlayerView, context: Context) {
        // Swap the player only when the URL actually changes
        if let currentItem = playerView.player?.currentItem,
           let currentURL = (currentItem.asset as? AVURLAsset)?.url,
           currentURL == url {
            return
        }
        let player = AVPlayer(url: url)
        player.isMuted = true
        playerView.player = player
    }

    static func dismantleNSView(_ playerView: AVPlayerView, coordinator: ()) {
        playerView.player?.pause()
        playerView.player = nil
    }
}

// MARK: - ThumbnailView

/// Shows a static thumbnail image for a video file using AVAssetImageGenerator.
struct ThumbnailView: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
                    .overlay(ProgressView().scaleEffect(0.6))
            }
        }
        .task(id: url) { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 180)

        guard let duration = try? await asset.load(.duration) else { return }
        let midpoint = CMTime(seconds: duration.seconds * 0.25, preferredTimescale: 600)

        if let cgImage = try? generator.copyCGImage(at: midpoint, actualTime: nil) {
            let nsImage = NSImage(cgImage: cgImage, size: .zero)
            await MainActor.run { self.image = nsImage }
        }
    }
}
