"""Main application controller for MKV QuickPlay."""

import sys
import threading
from typing import Optional

from .core.hotkey_manager import HotkeyManager
from .core.tray_controller import TrayController
from .core.mpv_launcher import get_launcher, MPVLauncher
from .core.video_utils import get_next_video, get_previous_video, is_video_file
from .platform.base import SelectionManager


class MKVQuickPlayApp:
    """Main application controller."""

    def __init__(self):
        self._hotkey_manager = HotkeyManager()
        self._tray_controller = TrayController()
        self._mpv_launcher = get_launcher()
        self._selection_manager: Optional[SelectionManager] = None

        self._current_file: Optional[str] = None
        self._just_closed = False

        self._setup_selection_manager()
        self._setup_callbacks()

    def _setup_selection_manager(self):
        """Set up the platform-specific selection manager."""
        if sys.platform == 'win32':
            from .platform.windows import get_selection_manager
            self._selection_manager = get_selection_manager()
        elif sys.platform == 'linux':
            from .platform.linux import get_selection_manager
            self._selection_manager = get_selection_manager()
        else:
            print(f"Unsupported platform: {sys.platform}")
            print("This app is designed for Windows and Linux.")
            print("For macOS, use the native Swift version.")

    def _setup_callbacks(self):
        """Set up all callback connections."""
        # Tray controller callbacks
        self._tray_controller.on_preview = self._preview_selected_video
        self._tray_controller.on_quit = self._quit

        # Hotkey manager callbacks
        self._hotkey_manager.on_hotkey = self._on_hotkey_pressed
        self._hotkey_manager.on_up_arrow = self._navigate_previous
        self._hotkey_manager.on_down_arrow = self._navigate_next
        self._hotkey_manager.on_escape = self._close_preview

        # MPV launcher callbacks
        self._mpv_launcher.on_close = self._on_mpv_closed

    def _on_hotkey_pressed(self):
        """Handle Ctrl+Space hotkey - toggle preview."""
        if self._mpv_launcher.is_playing:
            self._close_preview()
        else:
            self._preview_selected_video()

    def _preview_selected_video(self):
        """Preview the currently selected video file."""
        if self._just_closed:
            return

        if self._selection_manager is None:
            return

        video_file = self._selection_manager.get_selected_file()
        if video_file:
            self._play_video(video_file)

    def _play_video(self, filepath: str):
        """Play a video file."""
        if not is_video_file(filepath):
            return

        # Check if mpv is available
        if not self._mpv_launcher.find_mpv():
            print("Error: mpv not found!")
            print("Please install mpv:")
            if sys.platform == 'win32':
                print("  Download from: https://mpv.io/installation/")
            else:
                print("  sudo apt install mpv  (Debian/Ubuntu)")
                print("  sudo dnf install mpv  (Fedora)")
                print("  sudo pacman -S mpv    (Arch)")
            return

        self._current_file = filepath
        success = self._mpv_launcher.play(filepath)

        if success:
            self._tray_controller.set_active(True)
            self._hotkey_manager.is_preview_active = True
            print(f"Playing: {filepath}")

    def _navigate_next(self):
        """Navigate to the next video in the folder."""
        if not self._current_file:
            return

        next_file = get_next_video(self._current_file)
        if next_file and next_file != self._current_file:
            self._play_video(next_file)

    def _navigate_previous(self):
        """Navigate to the previous video in the folder."""
        if not self._current_file:
            return

        prev_file = get_previous_video(self._current_file)
        if prev_file and prev_file != self._current_file:
            self._play_video(prev_file)

    def _close_preview(self):
        """Close the current preview."""
        self._just_closed = True
        self._mpv_launcher.stop()
        self._current_file = None
        self._tray_controller.set_active(False)
        self._hotkey_manager.is_preview_active = False

        # Clear the just_closed flag after a short delay
        def clear_flag():
            import time
            time.sleep(0.5)
            self._just_closed = False

        threading.Thread(target=clear_flag, daemon=True).start()

    def _on_mpv_closed(self):
        """Handle mpv process closing (user closed the window)."""
        self._current_file = None
        self._tray_controller.set_active(False)
        self._hotkey_manager.is_preview_active = False

    def _quit(self):
        """Quit the application."""
        self._mpv_launcher.stop()
        self._hotkey_manager.stop()
        # Tray controller stop is called by its own quit handler

    def run(self):
        """Run the application."""
        print("MKV QuickPlay started")
        print("Ctrl+Space to preview selected video")
        print("Up/Down arrows to navigate")
        print("Escape to close preview")
        print("")

        # Start hotkey manager
        self._hotkey_manager.start()

        # Start tray icon (this blocks)
        # The tray controller runs the main event loop
        self._tray_controller.start()

        # Cleanup when tray exits
        self._hotkey_manager.stop()
        self._mpv_launcher.stop()


def main():
    """Main entry point."""
    app = MKVQuickPlayApp()
    app.run()
