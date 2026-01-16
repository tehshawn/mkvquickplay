"""MPV process launcher - finds and controls mpv playback."""

import subprocess
import shutil
import sys
import os
import signal
import time
from pathlib import Path
from typing import Optional, Callable


class MPVLauncher:
    """Manages mpv subprocess for video playback."""

    def __init__(self):
        self._process: Optional[subprocess.Popen] = None
        self._current_file: Optional[str] = None
        self._on_close: Optional[Callable[[], None]] = None

    @property
    def on_close(self) -> Optional[Callable[[], None]]:
        """Callback when mpv closes."""
        return self._on_close

    @on_close.setter
    def on_close(self, callback: Optional[Callable[[], None]]):
        self._on_close = callback

    @property
    def current_file(self) -> Optional[str]:
        """Currently playing file path."""
        return self._current_file

    @property
    def is_playing(self) -> bool:
        """Check if mpv is currently running."""
        if self._process is None:
            return False
        return self._process.poll() is None

    def find_mpv(self) -> Optional[str]:
        """Find mpv executable on the system."""
        # Platform-specific search paths
        if sys.platform == 'win32':
            search_paths = [
                Path(os.environ.get('LOCALAPPDATA', '')) / 'Programs' / 'mpv' / 'mpv.exe',
                Path(os.environ.get('PROGRAMFILES', '')) / 'mpv' / 'mpv.exe',
                Path(os.environ.get('PROGRAMFILES(X86)', '')) / 'mpv' / 'mpv.exe',
                Path('C:/Program Files/mpv/mpv.exe'),
                Path('C:/Program Files (x86)/mpv/mpv.exe'),
            ]
        else:  # Linux
            search_paths = [
                Path('/usr/bin/mpv'),
                Path('/usr/local/bin/mpv'),
                Path.home() / '.local' / 'bin' / 'mpv',
            ]

        # Check explicit paths first
        for path in search_paths:
            if path.exists():
                return str(path)

        # Fallback to PATH search
        return shutil.which('mpv')

    def play(self, filepath: str) -> bool:
        """Play a video file with mpv."""
        # Stop any existing playback
        self.stop()

        mpv_path = self.find_mpv()
        if not mpv_path:
            return False

        self._current_file = filepath

        # Build mpv arguments
        args = [
            mpv_path,
            '--hwdec=auto',
            '--keep-open=yes',
            '--osc=yes',
            '--osd-level=1',
            '--autofit=80%',
            '--auto-window-resize=yes',
            f'--title={Path(filepath).name}',
            '--force-window=immediate',
            '--input-default-bindings=no',
            '--input-vo-keyboard=no',
            filepath
        ]

        try:
            # Start mpv process
            if sys.platform == 'win32':
                # On Windows, use CREATE_NO_WINDOW to hide console
                startupinfo = subprocess.STARTUPINFO()
                startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
                self._process = subprocess.Popen(
                    args,
                    startupinfo=startupinfo,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL
                )
            else:
                self._process = subprocess.Popen(
                    args,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL
                )

            # Start monitoring thread for process exit
            import threading
            threading.Thread(target=self._monitor_process, daemon=True).start()

            return True

        except Exception as e:
            print(f"Failed to launch mpv: {e}")
            self._current_file = None
            return False

    def _monitor_process(self):
        """Monitor mpv process and call on_close when it exits."""
        if self._process is None:
            return

        process = self._process
        process.wait()

        # Only trigger callback if this is still our process
        if self._process is process:
            self._process = None
            self._current_file = None
            if self._on_close:
                self._on_close()

    def stop(self):
        """Stop mpv playback."""
        if self._process is None:
            return

        process = self._process
        self._process = None
        self._current_file = None

        if process.poll() is not None:
            return  # Already exited

        # Try graceful termination
        try:
            if sys.platform == 'win32':
                process.terminate()
            else:
                process.send_signal(signal.SIGTERM)

            # Wait briefly for graceful exit
            try:
                process.wait(timeout=0.5)
            except subprocess.TimeoutExpired:
                # Force kill if still running
                if sys.platform == 'win32':
                    process.kill()
                else:
                    process.send_signal(signal.SIGKILL)

        except Exception:
            pass  # Process may have already exited


# Singleton instance
_launcher: Optional[MPVLauncher] = None


def get_launcher() -> MPVLauncher:
    """Get the singleton MPVLauncher instance."""
    global _launcher
    if _launcher is None:
        _launcher = MPVLauncher()
    return _launcher
