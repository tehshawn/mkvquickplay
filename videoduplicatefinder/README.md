# Video Duplicate Finder

A fast, native macOS app for finding visually similar and duplicate video files. Inspired by the open-source [videoduplicatefinder](https://github.com/0x90d/videoduplicatefinder) project, rebuilt from scratch in Swift + SwiftUI with zero external dependencies.

## Features

- **Perceptual hashing** — finds duplicates even if re-encoded at different quality, resolution, or bitrate
- **Partial clip detection** — sliding-window frame alignment catches shorter clips of longer videos
- **Side-by-side preview** — inline AVPlayer comparison in a three-pane layout
- **Smart auto-mark** — one click marks all lower-resolution copies across every group
- **Safe deletion** — moves files to macOS Trash (recoverable), never permanent delete
- **No external dependencies** — pure Swift + AVFoundation + Accelerate

## Requirements

- macOS 13.0 (Ventura) or later
- Xcode 15 or later (to build from source)

## How It Works

1. **Add folders** in the left sidebar — the app scans recursively for video files (`.mkv`, `.mp4`, `.mov`, `.avi`, `.m4v`, `.webm`, `.wmv`, `.flv`, `.ts`, `.m2ts`, `.mts`, `.mpg`, `.mpeg`)
2. **Set similarity threshold** — default 85% catches most re-encodes; raise to 99% for near-identical-only
3. **Start Scan** — the engine extracts 8 evenly-spaced frames per video, computes a 64-bit perceptual hash (pHash) for each frame, then does pairwise Hamming distance comparison
4. **Review groups** — the middle list shows duplicate groups sorted by similarity; click a group to see side-by-side video cards with file metadata
5. **Mark and delete** — toggle "Mark for Deletion" per file, or use "Auto-mark Best" to automatically keep the highest-resolution copy; then "Move Marked to Trash"

## Perceptual Hash Algorithm

For each sampled frame:
1. Resize to 32×32 grayscale
2. Apply 2D DCT (via Accelerate's `vDSP.DCT`)
3. Take the top-left 8×8 block (64 low-frequency coefficients, excluding the DC term)
4. Threshold each coefficient against the mean → 64-bit hash

Two videos are duplicates if the average per-frame Hamming similarity exceeds the threshold.

## Build

```bash
# Clone
git clone https://github.com/tehshawn/videoduplicatefinder.git
cd videoduplicatefinder

# Open in Xcode
open VideoFuzzyDuplicate.xcodeproj
```

Then build with ⌘B and run with ⌘R. No package dependencies to fetch.

## Project Structure

```
VideoFuzzyDuplicate/
├── VideoFuzzyDuplicateApp.swift   — App entry point (@main)
├── ContentView.swift              — NavigationSplitView root
├── ScanSetupView.swift            — Sidebar: directories + settings
├── ResultsView.swift              — Duplicate group list
├── DuplicateGroupView.swift       — Side-by-side video cards
├── VideoPlayerView.swift          — AVPlayerView + thumbnail
├── ScanEngine.swift               — Scan orchestrator (ObservableObject)
├── VideoHasher.swift              — AVFoundation frame extraction + pHash
├── DuplicateDetector.swift        — Hamming comparison + union-find grouping
└── FileEntry.swift                — Data models
```

## License

MIT
