"""System tray icon and menu controller using pystray."""

import sys
from typing import Optional, Callable
from pathlib import Path

import pystray
from PIL import Image, ImageDraw


class TrayController:
    """Manages the system tray icon and menu."""

    def __init__(self):
        self._icon: Optional[pystray.Icon] = None
        self._is_active = False

        # Callbacks
        self._on_preview: Optional[Callable[[], None]] = None
        self._on_quit: Optional[Callable[[], None]] = None

    @property
    def on_preview(self) -> Optional[Callable[[], None]]:
        return self._on_preview

    @on_preview.setter
    def on_preview(self, callback: Optional[Callable[[], None]]):
        self._on_preview = callback

    @property
    def on_quit(self) -> Optional[Callable[[], None]]:
        return self._on_quit

    @on_quit.setter
    def on_quit(self, callback: Optional[Callable[[], None]]):
        self._on_quit = callback

    def _create_icon_image(self, active: bool = False) -> Image.Image:
        """Create the tray icon image programmatically."""
        size = 64
        img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
        draw = ImageDraw.Draw(img)

        # Colors
        if active:
            bg_color = (50, 120, 200)  # Blue when active
        else:
            bg_color = (30, 30, 30)    # Dark gray when inactive
        play_color = (255, 140, 0)     # Orange play button

        # Draw rounded rectangle background
        padding = 4
        radius = 10
        x1, y1 = padding, padding
        x2, y2 = size - padding, size - padding

        # Simple rectangle (pystray icons are small, rounded corners less visible)
        draw.rectangle([x1, y1, x2, y2], fill=bg_color)

        # Draw play triangle
        cx, cy = size // 2, size // 2
        play_size = size * 0.4
        offset = size * 0.03

        points = [
            (cx - play_size * 0.35 + offset, cy - play_size * 0.5),
            (cx - play_size * 0.35 + offset, cy + play_size * 0.5),
            (cx + play_size * 0.5 + offset, cy)
        ]
        draw.polygon(points, fill=play_color)

        return img

    def _load_icon_from_file(self) -> Optional[Image.Image]:
        """Try to load icon from resources directory."""
        # Look for icon file relative to this module
        module_dir = Path(__file__).parent.parent
        resources_dir = module_dir.parent / 'resources'

        if sys.platform == 'win32':
            icon_file = resources_dir / 'icon.ico'
        else:
            icon_file = resources_dir / 'icon.png'

        if icon_file.exists():
            try:
                return Image.open(icon_file)
            except Exception:
                pass

        return None

    def _get_icon_image(self, active: bool = False) -> Image.Image:
        """Get the icon image, preferring file over generated."""
        # For now, always use generated icon for consistency
        # File-based icon doesn't support active state easily
        return self._create_icon_image(active)

    def _create_menu(self) -> pystray.Menu:
        """Create the tray menu."""
        return pystray.Menu(
            pystray.MenuItem(
                "Ctrl+Space to preview video",
                None,
                enabled=False
            ),
            pystray.MenuItem(
                "Up/Down arrows to navigate",
                None,
                enabled=False
            ),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem(
                "Preview Selected Video",
                self._handle_preview
            ),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem(
                "About MKV QuickPlay",
                self._handle_about
            ),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem(
                "Quit",
                self._handle_quit
            )
        )

    def _handle_preview(self, icon, item):
        """Handle preview menu item click."""
        if self._on_preview:
            self._on_preview()

    def _handle_about(self, icon, item):
        """Handle about menu item click."""
        # Show a simple message (platform-specific dialogs would be more complex)
        print("MKV QuickPlay v1.0.0")
        print("Quick video preview for Windows and Linux")
        print("")
        print("Ctrl+Space: Preview selected video")
        print("Up/Down arrows: Navigate videos")
        print("Escape: Close preview")
        print("")
        print("Requires mpv: https://mpv.io")

    def _handle_quit(self, icon, item):
        """Handle quit menu item click."""
        if self._on_quit:
            self._on_quit()
        self.stop()

    def set_active(self, active: bool):
        """Set the active state (changes icon color)."""
        self._is_active = active
        if self._icon:
            self._icon.icon = self._get_icon_image(active)

    def start(self):
        """Start the tray icon (blocking call - run in thread)."""
        self._icon = pystray.Icon(
            "MKVQuickPlay",
            self._get_icon_image(self._is_active),
            "MKV QuickPlay - Ctrl+Space to preview",
            menu=self._create_menu()
        )
        self._icon.run()

    def stop(self):
        """Stop the tray icon."""
        if self._icon:
            self._icon.stop()
            self._icon = None
