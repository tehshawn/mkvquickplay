import SwiftUI

// MARK: - ScanSetupView

/// Left sidebar: directory list, similarity threshold slider, and scan controls.
struct ScanSetupView: View {
    @ObservedObject var engine: ScanEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // MARK: Directories
            Text("Scan Directories")
                .font(.headline)
                .padding([.top, .horizontal])

            if engine.scanDirectories.isEmpty {
                Text("No directories added.\nClick + to add a folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding()
            } else {
                List {
                    ForEach(engine.scanDirectories, id: \.self) { dir in
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(.accent)
                            Text(dir.lastPathComponent)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                engine.scanDirectories.removeAll { $0 == dir }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        .help(dir.path)
                    }
                }
                .listStyle(.sidebar)
                .frame(minHeight: 80, maxHeight: 200)
            }

            Button {
                addDirectory()
            } label: {
                Label("Add Folder", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding([.horizontal, .bottom])

            Divider()

            // MARK: Threshold
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Similarity Threshold")
                        .font(.headline)
                    Spacer()
                    Text(engine.threshold, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $engine.threshold, in: 0.70...1.00, step: 0.01)
                Text("Higher values require closer matches. 85% works well for most re-encodes.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            // MARK: Actions
            VStack(spacing: 8) {
                if engine.isScanning {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: engine.progress)
                        Text(engine.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Button("Cancel Scan", role: .cancel) {
                        engine.cancelScan()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Button {
                        Task { engine.startScan() }
                    } label: {
                        Label("Start Scan", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(engine.scanDirectories.isEmpty)

                    if !engine.statusMessage.isEmpty {
                        Text(engine.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if engine.totalMarkedCount > 0 {
                    Divider()

                    VStack(spacing: 6) {
                        Text("Marked for deletion: \(engine.totalMarkedCount) file(s)")
                            .font(.caption)
                        Text("Reclaimable: \(ByteCountFormatter.string(fromByteCount: engine.totalReclaimableBytes, countStyle: .file))")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button(role: .destructive) {
                            Task { await engine.deleteMarked() }
                        } label: {
                            Label("Move Marked to Trash", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding()

            if let error = engine.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Spacer()
        }
        .frame(minWidth: 220, idealWidth: 240)
    }

    // MARK: - Open Panel

    private func addDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders to scan for duplicate videos"

        if panel.runModal() == .OK {
            for url in panel.urls where !engine.scanDirectories.contains(url) {
                engine.scanDirectories.append(url)
            }
        }
    }
}
