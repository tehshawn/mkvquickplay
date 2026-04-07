import SwiftUI

// MARK: - ResultsView

/// Middle pane: list of duplicate groups with thumbnail, similarity, and file count.
struct ResultsView: View {
    @ObservedObject var engine: ScanEngine
    @Binding var selectedGroup: DuplicateGroup?

    var body: some View {
        Group {
            if engine.duplicateGroups.isEmpty && !engine.isScanning {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("\(engine.duplicateGroups.count) Duplicate Groups")
        .toolbar {
            if !engine.duplicateGroups.isEmpty {
                ToolbarItem {
                    Button {
                        engine.autoMarkAllGroups()
                    } label: {
                        Label("Auto-mark All", systemImage: "wand.and.stars")
                    }
                    .help("Mark the lowest-quality copy in every group for deletion")
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)
            if engine.isScanning {
                Text("Scanning…")
                    .foregroundStyle(.secondary)
            } else {
                Text("Add folders in the sidebar and click Start Scan.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List

    private var list: some View {
        List(selection: $selectedGroup) {
            ForEach($engine.duplicateGroups) { $group in
                GroupRow(group: group)
                    .tag(group as DuplicateGroup?)
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - GroupRow

private struct GroupRow: View {
    let group: DuplicateGroup

    var body: some View {
        HStack(spacing: 10) {
            // Thumbnail from first entry
            ThumbnailView(url: group.entries[0].url)
                .frame(width: 64, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 3) {
                Text(group.similarityFormatted + " similar")
                    .font(.headline)
                    .foregroundStyle(similarityColor(group.similarity))

                Text("\(group.entries.count) files")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                let wasted = group.entries.sorted(by: { $0.fileSize > $1.fileSize })
                    .dropFirst()
                    .reduce(0) { $0 + $1.fileSize }
                Text(ByteCountFormatter.string(fromByteCount: wasted, countStyle: .file) + " reclaimable")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if group.markedCount > 0 {
                Image(systemName: "trash.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    private func similarityColor(_ sim: Double) -> Color {
        switch sim {
        case 0.99...: return .primary
        case 0.92...: return .orange
        default:      return .secondary
        }
    }
}
