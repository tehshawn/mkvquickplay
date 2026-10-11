<div align="center">

<img src="docs/icon.png" width="120" alt="MKV QuickPlay icon">

# MKV QuickPlay

**QuickLook-style instant video preview for macOS, powered by mpv.**

[![Latest release](https://img.shields.io/github/v/release/tehshawn/mkvquickplay)](https://github.com/tehshawn/mkvquickplay/releases/latest)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Developer ID notarized](https://img.shields.io/badge/Developer%20ID-notarized-success)
[![License: MIT](https://img.shields.io/github/license/tehshawn/mkvquickplay)](LICENSE)

<!-- Add a screen recording at docs/demo.gif to show it off here. -->
<img src="docs/demo.gif" width="700" alt="MKV QuickPlay demo">

</div>

## Why?

macOS QuickLook can't preview **MKV** and many other video formats — and Quick Look plugins only show you one file at a time. MKV QuickPlay is built for the folder: select a video in Finder, press **Cmd+Shift+V**, and it opens instantly in an mpv window. Arrow through the folder in Finder's sort order, send junk clips to the Trash, undo mistakes — all from the keyboard. Nothing else on macOS does keyboard-driven video culling.

It pairs well with [QLVideo](https://github.com/Marginal/QLVideo) — use that for MKV *thumbnails* in Finder, and MKV QuickPlay for flying through and culling the folder.

## Features

- **Instant Preview**: Press `Cmd+Shift+V` to preview the selected video in Finder — a true global shortcut, recordable to any combo via the menu bar (*Set Keyboard Shortcut…*)
- **Auto-Updates**: The app keeps itself current via Sparkle (or use `brew upgrade`)
- **Native Resolution**: Videos open at their original dimensions (only large videos are scaled down to fit the screen)
- **Quick Navigation**: Use `Up/Down` arrow keys to step through videos in the same order Finder displays them (any sort — Name, Kind, Date, Size, or manual) — the Finder selection follows along, and navigation stops at the first/last file (QuickLook-style, no wrap-around)
- **Selection-Scoped**: Select several videos in Finder and the arrows cycle only that selection; select one and they walk the whole folder. A `N / total` indicator shows your position.
- **Cull Quickly**: Optionally enable *Move to Trash with Delete Key* in the menu to weed through footage — `Delete` trashes the current video and jumps to the next.
- **Remembers Volume**: Your last volume and mute setting carry over between videos and launches.
- **Toggle Playback**: Press the shortcut again to close, or press `Escape`
- **Minimal Permissions**: One permission, asked once — the first time you use the shortcut, macOS asks for permission to control Finder (used to read your selection and the current sort order, and to keep the Finder highlight on the playing video). Decline it and the Finder > Services menu entry still works, with alphabetical navigation.
- **Minimal UI**: Runs quietly in the menu bar with no Dock icon; optional *Launch at Login*
- **Native Performance**: Uses mpv for fast, high-quality video playback
- **Open With Support**: Right-click any video file > Open With > MKV QuickPlay
- **Shortcuts, Siri & Spotlight**: Seven automation actions (preview, navigate, trash, tag, review a folder) for the Shortcuts app, Siri phrases, and Spotlight on macOS 26+
- **Watch Folders**: Point the app at your ingest folders and new arrivals are offered for review — a notification plus a count in the menu bar, one click to step through just the new files

## Requirements

- macOS 13.0 (Ventura) or later
- **mpv** media player (required)

### Installing mpv

Install mpv using Homebrew:

```bash
brew install mpv
```

## Installation

### Homebrew (recommended)

```bash
brew install --cask tehshawn/tap/mkvquickplay
```

This installs the notarized app and its `mpv` dependency automatically. Update later with:

```bash
brew upgrade --cask mkvquickplay
```

### Download

Grab the latest **notarized** build from the [Releases page](https://github.com/tehshawn/mkvquickplay/releases/latest):

1. Download `MKVQuickPlay-macOS-vX.Y.Z.zip` and unzip it.
2. Move **MKVQuickPlay.app** to your `/Applications` folder.
3. Open it — because the app is signed with a Developer ID and notarized by Apple, it launches without Gatekeeper warnings.

### Build from Source

**Requirements**: Xcode 26 or later (free from the App Store) and Command Line Tools

```bash
# Clone the repository
git clone https://github.com/tehshawn/mkvquickplay.git
cd mkvquickplay

# Build the app
cd macos
xcodebuild -project MKVQuickPlay.xcodeproj -scheme MKVQuickPlay -configuration Release build

# Copy to Applications
cp -R ~/Library/Developer/Xcode/DerivedData/MKVQuickPlay-*/Build/Products/Release/MKVQuickPlay.app /Applications/

# Launch
open /Applications/MKVQuickPlay.app
```

## Usage

1. Launch **MKV QuickPlay** (it appears in your menu bar)
2. In **Finder**, select a video file
3. Press `Cmd+Shift+V` to preview (or use Finder > Services > Preview with MKVQuickPlay)
4. Use `Up/Down` arrows to navigate to previous/next video
5. Press `Escape` or `Q` to close

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd+Shift+V` | Preview selected video |
| `Down Arrow` | Next video |
| `Up Arrow` | Previous video |
| `P` | Toggle the Purple Finder tag (mark keepers while culling) |
| `Delete` | Move to Trash and advance (when enabled in menu) |
| `Cmd+Z` | Undo Move to Trash (restores the file and reopens it) |
| `Space` | Pause/Resume |
| `Left/Right Arrow` | Seek backward/forward |
| `Escape` or `Q` | Close preview |
| `M` | Toggle mute |
| `F` | Toggle fullscreen |

### Customizing the Shortcut

Click the menu bar icon → **Set Keyboard Shortcut…** and press any combination.

(The Finder Services entry also remains available under Finder > Services > Preview with MKVQuickPlay; its shortcut can be changed in System Settings > Keyboard > Keyboard Shortcuts > Services.)

## Automation (Shortcuts, Siri & Quick Actions)

MKV QuickPlay ships seven Shortcuts actions: **Preview Videos**, **Next
Video**, **Previous Video**, **Move Current Video to Trash**, **Toggle Purple
Tag**, **Stop Preview**, and **Review Folder**. All but Review Folder also
respond to Siri ("Next video in MKV QuickPlay"), and the actions appear in
Spotlight on macOS 26 and later.

Notes:

- **Preview Videos** accepts files piped in from other actions; run it with no
  input and it previews the current Finder selection instead (this uses the
  same Finder Automation permission as the keyboard shortcut).
- **Move Current Video to Trash** works even when the Delete-key safety is
  off — invoking an action named "move to trash" is not an accidental keypress.

### Finder Quick Action (right-click menu)

To put a preview entry in Finder's right-click **Quick Actions** menu:

1. Open **Shortcuts** and create a new shortcut.
2. Add the **Preview Videos** action (from MKV QuickPlay).
3. In the shortcut's details (⌥⌘2): enable **Use as Quick Action** → **Finder**,
   and set *Receive* to **Files** as input, feeding the action's *Videos* field.
4. Right-click any video in Finder → Quick Actions → your shortcut.

(The zero-permission Finder > Services > Preview with MKVQuickPlay entry is
always available without any setup.)

## Watch Folders

Menu bar icon → **Watch Folders** → **Add Folder…** and pick your ingest or
download folders. When new videos land there, a notification appears (and the
menu bar icon shows a count); click it — or use **Review N New Videos…** in
the menu — to step through just the new arrivals with the usual keys
(arrows, `P` to tag, `Delete` to trash when enabled).

- Files still being copied are never offered; arrivals must finish and settle first.
- Videos already in a folder when you add it don't count as new.
- Unplugging and replugging a drive (or sleeping the Mac) is handled — watching
  resumes and anything that arrived meanwhile is picked up.

## Supported Formats

MKV, AVI, WebM, MP4, M4V, MOV, WMV, FLV, TS, MTS, M2TS

## Troubleshooting

### Service not appearing in Finder menu
1. Quit and relaunch MKV QuickPlay
2. Run `/System/Library/CoreServices/pbs -flush` in Terminal, then relaunch the app
3. If still missing, log out and back in to refresh the services cache

### "mpv not found" alert
Install mpv using `brew install mpv`

### No video plays
Make sure a video file is selected (clicked) in Finder before pressing the shortcut

### Keys don't work in the player window
Versions before 2.5.1 could lose their key bindings after the app had been running for a few days (quitting and reopening fixed it). Update to 2.5.1 or later. If it still happens, open Console.app, search for `[mpv]` or `MKVQuickPlay`, and include those lines in a bug report.

## License

MIT License - feel free to use, modify, and distribute.

## Credits

- Uses [mpv](https://mpv.io/) for video playback
