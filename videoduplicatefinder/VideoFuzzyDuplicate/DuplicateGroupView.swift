import SwiftUI
import AVKit

// MARK: - DuplicateGroupView

/// Right detail pane: side-by-side video cards for each entry in a duplicate group.
struct DuplicateGroupView: View {
    @Binding var group: DuplicateGroup
    @ObservedObject var engine: ScanEngine

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Duplicate Group")
                        .font(.title2)
                        .bold()
                    Text("\(group.entries.count) files · \(group.similarityFormatted) similarity")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    autoMark()
                } label: {
                    Label("Auto-mark Best", systemImage: "wand.and.stars")
                }
                .help("Keep the highest-resolution copy; mark all others for deletion")
            }
            .padding()

            Divider()

            // Video cards
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach($group.entries) { $entry in
                        VideoCard(entry: $entry, isBest: entry.id == group.bestEntry?.id)
                    }
                }
                .padding()
            }

            Spacer()
        }
        .navigationTitle("Group Detail")
    }

    // MARK: - Auto-mark

    private func autoMark() {
        guard let best = group.bestEntry else { return }
        for i in group.entries.indices {
            group.entries[i].markedForDeletion = group.entries[i].id != best.id
        }
    }
}

// MARK: - VideoCard

private struct VideoCard: View {
    @Binding var entry: FileEntry
    let isBest: Bool

    @State private var isPlaying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            // Video preview area
            ZStack {
                if isPlaying {
                    VideoPlayerView(url: entry.url)
                        .frame(width: 320, height: 220)
                } else {
                    ThumbnailView(url: entry.url)
                        .frame(width: 320, height: 220)
                        .overlay(
                            Button {
                                isPlaying = true
                            } label: {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 44))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .shadow(radius: 4)
                            }
                            .buttonStyle(.plain)
                        )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(borderColor, lineWidth: isBest ? 2.5 : 1)
            )

            // File info
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.filename)
                    .font(.subheadline)
                    .bold()
                    .lineLimit(2)

                HStack {
                    Label(entry.resolutionFormatted, systemImage: "rectangle.on.rectangle")
                    Label(entry.fileSizeFormatted, systemImage: "doc")
                    Label(entry.durationFormatted, systemImage: "clock")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(entry.url.deletingLastPathComponent().path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(entry.url.path)
            }
            .frame(width: 320, alignment: .leading)

            // Keep / Delete toggle
            HStack {
                if isBest {
                    Label("Best quality", systemImage: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
                Spacer()
                Toggle(isOn: $entry.markedForDeletion) {
                    Text(entry.markedForDeletion ? "Marked for Deletion" : "Keep")
                }
                .toggleStyle(.button)
                .tint(entry.markedForDeletion ? .red : .accentColor)
                .font(.caption)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
    }

    private var borderColor: Color {
        if entry.markedForDeletion { return .red }
        if isBest { return .accentColor }
        return .secondary.opacity(0.3)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(entry.markedForDeletion
                  ? Color.red.opacity(0.06)
                  : Color(nsColor: .controlBackgroundColor))
    }
}
