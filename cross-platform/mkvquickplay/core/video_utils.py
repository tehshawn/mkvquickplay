"""Video file utilities - extension filtering and sibling navigation."""

from pathlib import Path
from typing import List, Optional

# Supported video extensions
SUPPORTED_EXTENSIONS = {
    '.mkv', '.avi', '.webm', '.mp4', '.m4v', '.mov',
    '.wmv', '.flv', '.ts', '.mts', '.m2ts'
}


def is_video_file(path: str) -> bool:
    """Check if a file is a supported video format."""
    return Path(path).suffix.lower() in SUPPORTED_EXTENSIONS


def get_video_files_in_directory(directory: str) -> List[str]:
    """Get all video files in a directory, sorted by name."""
    dir_path = Path(directory)
    if not dir_path.is_dir():
        return []

    videos = []
    for f in dir_path.iterdir():
        if f.is_file() and f.suffix.lower() in SUPPORTED_EXTENSIONS:
            videos.append(str(f))

    return sorted(videos, key=lambda x: x.lower())


def get_sibling_videos(current_file: str) -> List[str]:
    """Get all video files in the same directory as the current file."""
    file_path = Path(current_file)
    if not file_path.exists():
        return []

    return get_video_files_in_directory(str(file_path.parent))


def get_next_video(current_file: str) -> Optional[str]:
    """Get the next video file in the directory (with wraparound)."""
    siblings = get_sibling_videos(current_file)
    if not siblings:
        return None

    try:
        current_index = siblings.index(current_file)
        next_index = (current_index + 1) % len(siblings)
        return siblings[next_index]
    except ValueError:
        return siblings[0] if siblings else None


def get_previous_video(current_file: str) -> Optional[str]:
    """Get the previous video file in the directory (with wraparound)."""
    siblings = get_sibling_videos(current_file)
    if not siblings:
        return None

    try:
        current_index = siblings.index(current_file)
        prev_index = (current_index - 1) % len(siblings)
        return siblings[prev_index]
    except ValueError:
        return siblings[-1] if siblings else None
