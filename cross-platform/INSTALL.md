# MKV QuickPlay Installation Guide (Windows & Linux)

Quick video preview for Windows and Linux.

**Hotkey:** Ctrl+` (backtick, the key above Tab)

*Note: Ctrl+Space may also work but can conflict with input method editors (IBus on Linux, IME on Windows).*

## Requirements

- **Python 3.8+**
- **mpv** media player installed and in PATH

---

## Windows Installation

### 1. Install mpv

Download and install mpv from: https://mpv.io/installation/

Or use Chocolatey:
```powershell
choco install mpv
```

Or Scoop:
```powershell
scoop install mpv
```

### 2. Install MKV QuickPlay

```powershell
cd cross-platform

# Install base package
pip install -e .

# Install Windows-specific dependencies
pip install pywin32
pip install git+https://github.com/offerrall/pywinselect.git
```

### 3. Run

```powershell
python -m mkvquickplay
```

---

## Linux Installation

### 1. Install system dependencies

**Ubuntu/Debian:**
```bash
sudo apt install mpv xdotool xclip python3-pip python3-full gnome-shell-extension-appindicator
```

**Fedora:**
```bash
sudo dnf install mpv xdotool xclip python3-pip gnome-shell-extension-appindicator
```

**Arch Linux:**
```bash
sudo pacman -S mpv xdotool xclip python-pip
# For GNOME: yay -S gnome-shell-extension-appindicator
```

### 2. Install MKV QuickPlay

```bash
# Create virtual environment
python3 -m venv ~/mkvquickplay-venv
source ~/mkvquickplay-venv/bin/activate

# Clone or copy the cross-platform folder, then:
cd cross-platform
pip install -e .
```

### 3. Run

```bash
source ~/mkvquickplay-venv/bin/activate
python -m mkvquickplay
```

### 4. (Optional) Auto-start on login

```bash
mkdir -p ~/.config/autostart
cat > ~/.config/autostart/mkvquickplay.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=MKV QuickPlay
Exec=bash -c "cd ~/mkvquickplay-app && ~/mkvquickplay-venv/bin/python -m mkvquickplay"
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
Comment=Quick video preview with Ctrl+` hotkey
StartupNotify=false
X-GNOME-Autostart-Delay=5
EOF
```

Note: Copy the `cross-platform` folder to `~/mkvquickplay-app` for autostart to work reliably.

---

## Usage

1. **Start MKV QuickPlay** - A system tray icon will appear
2. **Select a video file** in your file manager (Explorer, Nautilus, Dolphin, etc.)
3. **Press Ctrl+`** (backtick key, above Tab)
4. **Use Up/Down arrows** to navigate to next/previous video in folder
5. **Press Escape** to close the preview

---

## Supported File Managers

### Windows
- Windows Explorer

### Linux
- Nautilus (GNOME Files)
- Dolphin (KDE)
- Thunar (XFCE)
- Nemo (Cinnamon)
- Caja (MATE)
- PCManFM (LXDE)

---

## Troubleshooting

### Linux: Ctrl+Space doesn't work

Ctrl+Space is often used by IBus for input method switching. Use **Ctrl+`** (backtick) instead, which is the default hotkey on Linux.

If you want to use Ctrl+Space, disable IBus hotkey:
```bash
gsettings set org.freedesktop.ibus.general.hotkey triggers "[]"
```

### Linux: No tray icon on GNOME

Install the AppIndicator extension:
```bash
sudo apt install gnome-shell-extension-appindicator
```
Then log out and back in.

### Linux: Hotkeys not working at all

1. Make sure you're using X11, not Wayland:
   ```bash
   echo $XDG_SESSION_TYPE
   ```
   If it says `wayland`, log out and select "Ubuntu on Xorg" at the login screen.

2. You may need to add your user to the `input` group:
   ```bash
   sudo usermod -aG input $USER
   ```
   Then log out and back in.

### Windows: pywinselect installation fails

Make sure you have Git installed, then:
```powershell
pip install git+https://github.com/offerrall/pywinselect.git
```

---

## Uninstall

```bash
pip uninstall mkvquickplay
rm ~/.config/autostart/mkvquickplay.desktop  # Linux only
```
