"""Abstract base class for platform-specific file manager integration."""

from abc import ABC, abstractmethod
from typing import Optional, List


class SelectionManager(ABC):
    """Abstract base for file manager selection detection."""

    @abstractmethod
    def is_file_manager_active(self) -> bool:
        """Check if the native file manager is the active window."""
        pass

    @abstractmethod
    def get_selected_file(self) -> Optional[str]:
        """Get the currently selected video file in the file manager.

        Returns the path of the first selected video file, or None if
        no video file is selected.
        """
        pass

    @abstractmethod
    def get_selected_files(self) -> List[str]:
        """Get all selected files in the file manager."""
        pass
