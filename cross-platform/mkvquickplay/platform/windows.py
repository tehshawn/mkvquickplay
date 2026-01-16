"""Windows Explorer integration for file selection detection."""

import sys
from typing import Optional, List

from .base import SelectionManager
from ..core.video_utils import is_video_file

# Only import Windows-specific modules on Windows
if sys.platform == 'win32':
    try:
        import win32gui
        import win32process
        import psutil
        HAS_WIN32 = True
    except ImportError:
        HAS_WIN32 = False

    try:
        from pywinselect import get_selected
        HAS_PYWINSELECT = True
    except ImportError:
        HAS_PYWINSELECT = False
else:
    HAS_WIN32 = False
    HAS_PYWINSELECT = False


class WindowsSelectionManager(SelectionManager):
    """Windows Explorer file selection manager."""

    def __init__(self):
        if not HAS_WIN32:
            print("Warning: pywin32 not installed. Install with: pip install pywin32")
        if not HAS_PYWINSELECT:
            print("Warning: pywinselect not installed. Install with: pip install pywinselect")

    def is_file_manager_active(self) -> bool:
        """Check if Windows Explorer is the active window."""
        if not HAS_WIN32:
            return False

        try:
            hwnd = win32gui.GetForegroundWindow()
            _, pid = win32process.GetWindowThreadProcessId(hwnd)

            proc = psutil.Process(pid)
            proc_name = proc.name().lower()

            # Explorer.exe is both the file manager and the desktop shell
            return proc_name == 'explorer.exe'

        except Exception:
            return False

    def get_selected_files(self) -> List[str]:
        """Get all selected files from Windows Explorer."""
        if not HAS_PYWINSELECT:
            return []

        try:
            # pywinselect.get_selected returns list of selected file paths
            selected = get_selected(filter_type="files")
            return list(selected) if selected else []

        except Exception as e:
            print(f"Error getting Explorer selection: {e}")
            return []

    def get_selected_file(self) -> Optional[str]:
        """Get the first selected video file from Windows Explorer."""
        if not self.is_file_manager_active():
            return None

        selected_files = self.get_selected_files()

        # Find first video file in selection
        for filepath in selected_files:
            if is_video_file(filepath):
                return filepath

        return None


def get_selection_manager() -> SelectionManager:
    """Get the Windows selection manager instance."""
    return WindowsSelectionManager()
