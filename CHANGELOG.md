# Changelog

All notable changes to MKV QuickPlay are documented here.

## [Unreleased]

### Added
- **Tag while culling** — press `P` during preview to toggle the Purple Finder
  tag on the playing video (other tags are preserved); an on-screen overlay
  confirms. Mark keepers without stopping playback.
- **Global keyboard shortcut** (default `Cmd+Shift+V`) that works regardless of
  the Services menu's mood — recordable to any combination via the menu bar's
  *Set Keyboard Shortcut…*. The Finder Service remains as a zero-permission
  fallback. The hotkey reads the current Finder selection and previews it
  (pressing it with no video selected closes the open preview).
- **Auto-updates via Sparkle** — the app checks a signed appcast (hosted on the
  project's GitHub Pages) and can install updates in place. *Check for
  Updates…* lives in the menu, and scheduled updates surface as a gentle
  "Update Available…" menu item (a Dock-less app's update alerts would
  otherwise appear behind other windows). The Homebrew cask gains
  `auto_updates` one release later, so pre-Sparkle brew installs still get
  this version via `brew upgrade`.

### Fixed
- Crash fix: a race between mpv exiting and an in-flight IPC command could kill
  the entire app via an unhandled SIGPIPE. Writes now suppress SIGPIPE and a
  failed write tears the channel down cleanly.
- Descending sorts now match Finder exactly: the direction applies to the sort
  key only, keeping Finder's name-ascending tiebreak (a Kind-sorted folder of
  same-type files no longer flips to reverse-alphabetical).
- Unmappable Finder sort columns (Date Added, Tags, …) now fall back to
  alphabetical instead of applying the column's direction to the wrong key.
  The Finder sort query now runs fully off the main thread (isolated
  subprocess, bounded by timeouts) *after* playback starts — a busy Finder or
  the one-time Automation consent prompt can no longer stall the app or delay
  the video. Note: multi-file previews now start at the alphabetically first
  file of the selection; the playlist adopts Finder's order a moment later.
- Arrow-key navigation can no longer relaunch mpv right after the user closed
  it (navigation now only ever loads into the live window).
- Undo Move to Trash: restoring into a different folder no longer traps
  navigation in a one-file playlist; an impossible undo (Trash emptied) is
  dropped instead of wedging the undo stack.
- Re-invoking the shortcut on a *different* selection that happens to include
  the playing file now starts the new preview instead of toggling closed.
- "Open With" now builds a proper navigation playlist (same path as the
  Service) instead of leaving stale navigation state behind.
- The mpv-not-found / launch-failure alerts now activate the app so they can't
  appear behind other windows; menu-bar state is only set once mpv actually
  launched.
- Launch at Login checkmark refreshes when the menu opens (stays correct if
  toggled in System Settings).
- macOS 27 forward-compat: modern cooperative-activation API; IPC socket moved
  to the per-user temp directory; MacPorts mpv path recognized.
- Release tooling: refuses to release from a dirty/unpushed tree, refuses to
  clobber an existing release without --force, tags the exact built commit,
  archives dSYMs with each release, and verifies the Homebrew cask rewrite
  actually took effect.

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
