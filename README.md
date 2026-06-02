# MKV QuickPlay

A lightweight macOS menu bar app for quick video preview using mpv. Select a video file in Finder and press **Cmd+Shift+V** to instantly preview it — then step through the folder, cull files to the Trash, and undo, all from the keyboard, QuickLook-style.

## Features

- **Instant Preview**: Press `Cmd+Shift+V` to preview the selected video in Finder
- **Native Resolution**: Videos open at their original dimensions (only large videos are scaled down to fit the screen)
- **Quick Navigation**: Use `Up/Down` arrow keys to step through videos in the same order Finder displays them (any sort — Name, Kind, Date, Size, or manual) — the Finder selection follows along, and navigation stops at the first/last file (QuickLook-style, no wrap-around)
- **Selection-Scoped**: Select several videos in Finder and the arrows cycle only that selection; select one and they walk the whole folder. A `N / total` indicator shows your position.
- **Cull Quickly**: Optionally enable *Move to Trash with Delete Key* in the menu to weed through footage — `Delete` trashes the current video and jumps to the next.
- **Remembers Volume**: Your last volume and mute setting carry over between videos and launches.
- **Toggle Playback**: Press the shortcut again to close, or press `Escape`
- **Minimal Permissions**: Uses macOS Services for previewing — no permissions needed. The first time you navigate a folder, macOS asks for permission to control Finder (used only to read the current sort order); decline it and navigation falls back to alphabetical order.
- **Minimal UI**: Runs quietly in the menu bar with no Dock icon; optional *Launch at Login*
- **Native Performance**: Uses mpv for fast, high-quality video playback
- **Open With Support**: Right-click any video file > Open With > MKV QuickPlay

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

**Requirements**: Xcode (free from App Store) and Command Line Tools

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
| `Delete` | Move to Trash and advance (when enabled in menu) |
| `Space` | Pause/Resume |
| `Left/Right Arrow` | Seek backward/forward |
| `Escape` or `Q` | Close preview |
| `M` | Toggle mute |
| `F` | Toggle fullscreen |

### Customizing the Shortcut

You can change the keyboard shortcut in:
System Settings > Keyboard > Keyboard Shortcuts > Services

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

## License

MIT License - feel free to use, modify, and distribute.

## Credits

- Uses [mpv](https://mpv.io/) for video playback
