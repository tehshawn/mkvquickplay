# MKV QuickPlay

A lightweight macOS menu bar app for quick video preview using mpv. Select a video file in Finder and press **Cmd+Shift+V** to instantly preview it.

## Features

- **Instant Preview**: Press `Cmd+Shift+V` to preview the selected video in Finder
- **Quick Navigation**: Use `Up/Down` arrow keys to jump between videos in the same folder
- **Toggle Playback**: Press the shortcut again to close, or press `Escape`
- **Zero Permissions**: Uses macOS Services — no Accessibility or Automation permissions needed
- **Minimal UI**: Runs quietly in the menu bar with no Dock icon
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
| `Down Arrow` | Next video in folder |
| `Up Arrow` | Previous video in folder |
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
