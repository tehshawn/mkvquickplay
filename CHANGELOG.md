# Changelog

All notable changes to MKV QuickPlay are documented here.

## [2.3.0]

### Added
- **Undo Move to Trash** — restore the file you just trashed and reopen it,
  via `Cmd+Z` in the player window or the "Undo Move to Trash" menu item
  (multi-level; the menu item works even after the preview has closed).

## [2.2.1]

### Changed
- Folder navigation now follows Finder's **displayed sort order** by reading the
  window's sort column + direction (List view) or arrangement (Icon view) and
  replicating it — Name, Kind, Date Modified, Date Created, or Size, ascending or
  descending. Falls back to alphabetical when Finder can't be queried.
- "About" now shows the version and last-updated date.

### Known limitation
- macOS does not expose **Column view** (or the transient right-click "Sort By")
  ordering to any app, so those can't be matched — use List or Icon view.

## [2.2.0]

### Added
- Reads the active Finder window to match its sort order (requires a one-time
  Automation→Finder permission; declining falls back to alphabetical).

## [2.1.0]

### Added
- **Selection-scoped navigation** — select several videos in Finder and the arrows
  cycle just that subset; select one and they walk the whole folder.
- **Position indicator** — a brief `N / total` overlay while navigating.
- **Move to Trash with Delete key** (opt-in via the menu) — trashes the current
  video and advances to the next.
- **Launch at Login** toggle (via `SMAppService`).
- **Volume / mute memory** across videos and launches.
- **Now-playing** line and **Reveal in Finder** in the menu.

### Changed
- mpv now runs as a single **persistent window** driven over its JSON IPC socket;
  navigating loads each file in place instead of relaunching mpv (QuickLook-style).
- **Native-resolution playback** — videos open at their original dimensions; only
  oversized videos are scaled down to fit the screen (previously everything was
  scaled to ~80% of the screen).
- The Finder selection now follows the playing video during navigation.
- Navigation **stops at the first/last file** instead of wrapping around.

### Fixed
- Only supported video files are played (the Service no longer launches mpv on
  arbitrary file types).
- Robust sibling matching via normalized paths (fixes silent navigation failures
  from symlink / file-reference URL differences).
- Directory listing now ignores folders that look like video files.
- `stop()` no longer blocks the main thread while terminating mpv.

### Removed
- The cross-platform (Windows/Linux) Python version; the project is now macOS-only.

## [2.0.0]

### Changed
- Rewritten to use macOS Services (`Cmd+Shift+V`) — no Accessibility or Automation
  permissions required.
