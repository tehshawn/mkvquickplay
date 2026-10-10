# Changelog

All notable changes to MKV QuickPlay are documented here.

## [2.5.1]

### Fixed
- **Navigation keys went dead after the app had been running for a few
  days** — the arrows, `Delete`, `P`, `Esc`, `Q` and `Space` all stopped
  working in the player until MKV QuickPlay was quit and reopened. The custom
  key bindings mpv needs were written once, at app launch, into the system's
  temporary folder, which macOS quietly sweeps of files older than three days.
  After that, every player window started with no key bindings at all (and
  mpv's complaint went to `/dev/null`). The bindings now live in
  `~/Library/Application Support/MKVQuickPlay/`, are rewritten before every
  player launch, and are additionally installed over the control channel once
  it connects — so a session can never be left keyless again. mpv's warnings
  and errors are now forwarded to the system log (Console.app, search for
  `[mpv]`) so a recurrence of this class of problem leaves evidence.
- **Finder's selection now follows the playing video without stealing focus
  from the player.** Previously Finder was activated to move the highlight and
  macOS was then asked to hand focus back to mpv — a request a background app
  can't guarantee under the macOS 14+ cooperative-activation rules, and one
  macOS 26/27 declines more often, after which every arrow key went to Finder
  instead of the player. Finder is now told to reveal the file over the
  existing Automation channel with no activation; the old activate-and-refocus
  dance remains only as a fallback when Finder can't be scripted.
- The player window is checked for keyboard focus once its control channel
  opens, and activation is requested on its behalf if macOS declined mpv's
  own request; a refusal is now logged instead of failing silently.
- **Set Keyboard Shortcut… works again on macOS 26/27**: the shortcut recorder
  (from the KeyboardShortcuts library) didn't capture key presses and its ✕
  button did nothing on Tahoe and Golden Gate; updated to KeyboardShortcuts
  3.1.0, which fixes this.
- A large Finder selection (hundreds of files) could deadlock the hotkey for
  30 seconds: the selection query's output is now drained while the script
  runs instead of after it exits, and a script that ignores termination is
  force-killed so it can never wedge the hotkey for the rest of the session.
- Declining the Automation permission used to disable Finder-order navigation
  until relaunch even after re-enabling it in System Settings; it now recovers
  on the next successful query.
- A multi-file selection spanning several folders (search results, a tag view)
  no longer shrinks to the files in the first file's folder once Finder's sort
  order is applied.
- The sort query no longer borrows the front Finder window's sort when no
  window shows the video's folder; it falls back to alphabetical as documented.
- Undo Move to Trash no longer wedges on a file whose original folder is gone
  (renamed, deleted, ejected volume) — the entry is dropped with an explanation
  so older undos stay reachable.
- A second instance of the app no longer deletes a running instance's live
  control socket on startup.
- Re-invoking the preview while the player was still starting up used to kill
  and relaunch it; commands are now queued and delivered once the control
  channel opens (this also makes the "Restored" message after an undo appear
  when the player had to be relaunched).
- Alerts from the menu ("How to Use…", "About") now request activation before
  appearing so they can't open behind other windows.
- Updated Sparkle to 2.10.0 (security hardening in 2.9.5/2.9.6 and macOS 27
  fixes).

### Changed
- The app keeps itself out of App Nap only while a player window is open, so
  its timers aren't coalesced mid-session.
- Help text now lists `Cmd+Z` and points to "Set Keyboard Shortcut…" in the
  menu instead of the Services pane of System Settings.
- Building from source now requires Xcode 26 or later (KeyboardShortcuts 3.x
  is a Swift 6.2 package).

## [2.5.0]

### Changed
- **Liquid Glass app icon** for macOS 26 Tahoe and macOS 27 Golden Gate: the
  stack icon is now a native layered icon with dynamic lighting and dark,
  clear, and tinted appearance variants — no more legacy gray-squircle boxing
  on modern systems. Older macOS versions keep the classic icon automatically.
  (The layered source lives at `macos/MKVQuickPlay/AppIcon.icon` and can be
  edited in Apple's Icon Composer.)
- **More reliable player focus on macOS 26/27**: handing focus to the video
  window now uses the modern cooperative-activation hand-off, preventing the
  preview from occasionally opening behind other windows under the new
  focus-stealing protections.

## [2.4.2]

### Fixed
- The navigation arrows, `Delete`, and the `P` tag key could go permanently
  dead for an entire preview session if the app missed its single 3-second
  window to attach to mpv's control channel (for example after a slow cold
  start of mpv), or if the channel dropped mid-session. The connection now
  keeps retrying for up to two minutes, self-heals within half a second if it
  ever drops while the player is running, tolerates transient interruptions,
  and uses a unique socket per session so overlapping player instances can't
  interfere. Diagnostic logging added so any recurrence leaves evidence.

## [2.4.1]

### Changed
- **New app icon** — a stack of video cards with a play triangle, reflecting
  what the app is for: flying through a folder, not just playing a file. The
  icon is generated code (`scripts/icongen.swift`), with a simplified variant
  at small sizes for crisp Finder lists.
- **Matching menu bar icon** — the status item now shows a miniature of the
  stack motif as a proper template image (adapts to light/dark and tinting).

## [2.4.0]

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
