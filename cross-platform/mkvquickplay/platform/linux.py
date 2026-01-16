"""Linux file manager integration for selection detection.

Supports multiple file managers:
- Nautilus (GNOME Files)
- Dolphin (KDE)
- Thunar (XFCE)
- Nemo (Cinnamon)
- Caja (MATE)
- PCManFM (LXDE)
"""

import subprocess
import os
from typing import Optional, List
from pathlib import Path

from .base import SelectionManager
from ..core.video_utils import is_video_file


# Map of process names to file manager types
FILE_MANAGERS = {
    'nautilus': 'nautilus',
    'org.gnome.nautilus': 'nautilus',
    'dolphin': 'dolphin',
    'thunar': 'thunar',
    'nemo': 'nemo',
    'caja': 'caja',
    'pcmanfm': 'pcmanfm',
    'pcmanfm-qt': 'pcmanfm',
}


class LinuxSelectionManager(SelectionManager):
    """Linux file manager selection manager with multi-backend support."""

    def __init__(self):
        self._last_fm_type: Optional[str] = None

    def _run_command(self, cmd: List[str], timeout: float = 2.0) -> Optional[str]:
        """Run a command and return stdout."""
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=timeout
            )
            return result.stdout.strip() if result.returncode == 0 else None
        except Exception:
            return None

    def _get_active_window_pid(self) -> Optional[int]:
        """Get the PID of the active window using xdotool."""
        output = self._run_command(['xdotool', 'getactivewindow', 'getwindowpid'])
        if output:
            try:
                return int(output)
            except ValueError:
                pass
        return None

    def _get_process_name(self, pid: int) -> Optional[str]:
        """Get the process name for a PID."""
        output = self._run_command(['ps', '-p', str(pid), '-o', 'comm='])
        return output.lower() if output else None

    def _detect_file_manager(self) -> Optional[str]:
        """Detect which file manager is active."""
        pid = self._get_active_window_pid()
        if not pid:
            return None

        proc_name = self._get_process_name(pid)
        if not proc_name:
            return None

        return FILE_MANAGERS.get(proc_name)

    def is_file_manager_active(self) -> bool:
        """Check if a supported file manager is the active window."""
        fm_type = self._detect_file_manager()
        self._last_fm_type = fm_type
        return fm_type is not None

    def _get_nautilus_selection(self) -> List[str]:
        """Get selection from Nautilus using DBus or script method."""
        # Method 1: Try reading from Nautilus script environment
        # This requires a Nautilus script to be set up
        script_selection = os.environ.get('NAUTILUS_SCRIPT_SELECTED_FILE_PATHS', '')
        if script_selection:
            return [p for p in script_selection.split('\n') if p]

        # Method 2: Try xdotool + xclip (copy selection to clipboard)
        # This is less reliable but works as fallback
        return self._get_selection_via_clipboard()

    def _get_dolphin_selection(self) -> List[str]:
        """Get selection from Dolphin."""
        # Dolphin doesn't have great programmatic selection access
        # Use clipboard method as fallback
        return self._get_selection_via_clipboard()

    def _get_thunar_selection(self) -> List[str]:
        """Get selection from Thunar."""
        # Thunar custom actions can write selection to file
        # Use clipboard method as fallback
        return self._get_selection_via_clipboard()

    def _get_selection_via_clipboard(self) -> List[str]:
        """Get file selection by simulating Ctrl+C and reading clipboard.

        This is a fallback method that works with most file managers
        but temporarily modifies the clipboard.
        """
        # Save current clipboard content
        old_clipboard = self._run_command(['xclip', '-selection', 'clipboard', '-o'])

        # Simulate Ctrl+C to copy selection
        self._run_command(['xdotool', 'key', '--clearmodifiers', 'ctrl+c'])

        # Brief delay for clipboard to update
        import time
        time.sleep(0.1)

        # Read new clipboard content
        clipboard = self._run_command(['xclip', '-selection', 'clipboard', '-o'])

        # Restore old clipboard if we had content
        if old_clipboard:
            try:
                proc = subprocess.Popen(
                    ['xclip', '-selection', 'clipboard'],
                    stdin=subprocess.PIPE
                )
                proc.communicate(input=old_clipboard.encode())
            except Exception:
                pass

        if not clipboard:
            return []

        # Parse clipboard - file managers typically copy as file:// URIs or paths
        paths = []
        for line in clipboard.split('\n'):
            line = line.strip()
            if not line:
                continue

            # Handle file:// URIs
            if line.startswith('file://'):
                from urllib.parse import unquote
                path = unquote(line[7:])  # Remove 'file://' prefix
                paths.append(path)
            elif os.path.exists(line):
                paths.append(line)

        return paths

    def get_selected_files(self) -> List[str]:
        """Get all selected files from the active file manager."""
        fm_type = self._last_fm_type or self._detect_file_manager()

        if fm_type == 'nautilus':
            return self._get_nautilus_selection()
        elif fm_type == 'dolphin':
            return self._get_dolphin_selection()
        elif fm_type == 'thunar':
            return self._get_thunar_selection()
        elif fm_type in ('nemo', 'caja', 'pcmanfm'):
            return self._get_selection_via_clipboard()

        return []

    def get_selected_file(self) -> Optional[str]:
        """Get the first selected video file from the file manager."""
        if not self.is_file_manager_active():
            return None

        selected_files = self.get_selected_files()

        # Find first video file in selection
        for filepath in selected_files:
            if is_video_file(filepath):
                return filepath

        return None


def get_selection_manager() -> SelectionManager:
    """Get the Linux selection manager instance."""
    return LinuxSelectionManager()
