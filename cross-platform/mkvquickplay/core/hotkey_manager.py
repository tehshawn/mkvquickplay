"""Global hotkey manager using pynput."""

import sys
import threading
from typing import Optional, Callable

from pynput import keyboard
from pynput.keyboard import Key, KeyCode


class HotkeyManager:
    """Manages global hotkey detection.

    Supported hotkeys:
    - Ctrl+Space (Windows) or Ctrl+` (Linux) - Toggle preview
    - Up/Down arrows - Navigate videos (when preview active)
    - Escape - Close preview
    """

    def __init__(self):
        self._listener: Optional[keyboard.Listener] = None
        self._is_preview_active = False
        self._ctrl_pressed = False

        # Callbacks
        self._on_hotkey: Optional[Callable[[], None]] = None
        self._on_up_arrow: Optional[Callable[[], None]] = None
        self._on_down_arrow: Optional[Callable[[], None]] = None
        self._on_escape: Optional[Callable[[], None]] = None

    @property
    def is_preview_active(self) -> bool:
        return self._is_preview_active

    @is_preview_active.setter
    def is_preview_active(self, value: bool):
        self._is_preview_active = value

    @property
    def on_hotkey(self) -> Optional[Callable[[], None]]:
        return self._on_hotkey

    @on_hotkey.setter
    def on_hotkey(self, callback: Optional[Callable[[], None]]):
        self._on_hotkey = callback

    @property
    def on_up_arrow(self) -> Optional[Callable[[], None]]:
        return self._on_up_arrow

    @on_up_arrow.setter
    def on_up_arrow(self, callback: Optional[Callable[[], None]]):
        self._on_up_arrow = callback

    @property
    def on_down_arrow(self) -> Optional[Callable[[], None]]:
        return self._on_down_arrow

    @on_down_arrow.setter
    def on_down_arrow(self, callback: Optional[Callable[[], None]]):
        self._on_down_arrow = callback

    @property
    def on_escape(self) -> Optional[Callable[[], None]]:
        return self._on_escape

    @on_escape.setter
    def on_escape(self, callback: Optional[Callable[[], None]]):
        self._on_escape = callback

    def start(self):
        """Start listening for hotkeys."""
        if self._listener is not None:
            return

        self._listener = keyboard.Listener(
            on_press=self._on_key_press,
            on_release=self._on_key_release,
            suppress=False
        )
        self._listener.start()

    def stop(self):
        """Stop listening for hotkeys."""
        if self._listener is not None:
            self._listener.stop()
            self._listener = None

    def _is_hotkey_pressed(self, key) -> bool:
        """Check if the main hotkey combination is pressed.

        Supports:
        - Ctrl+Space (works on Windows, may conflict with IBus on Linux)
        - Ctrl+` (backtick) - alternative for Linux/Windows
        """
        if not self._ctrl_pressed:
            return False

        # Ctrl+Space
        if key == Key.space:
            return True

        # Windows: Space with Ctrl held may report as vk=32 (space virtual key code)
        if isinstance(key, KeyCode) and hasattr(key, 'vk') and key.vk == 32:
            return True

        # Ctrl+` (backtick/grave)
        # Check by character (works on Linux)
        if isinstance(key, KeyCode) and key.char == '`':
            return True

        # Check by virtual key code (works on Windows where char is None when Ctrl held)
        # vk=192 is backtick/grave on US keyboards, vk=220 may appear on some systems
        if isinstance(key, KeyCode) and hasattr(key, 'vk') and key.vk in (192, 220):
            return True

        return False

    def _on_key_press(self, key):
        """Handle key press events."""
        # Track Ctrl key state (handle both specific and generic ctrl keys)
        if key in (Key.ctrl_l, Key.ctrl_r, Key.ctrl):
            self._ctrl_pressed = True
            return

        # Check for main hotkey (Ctrl+Space or Ctrl+`)
        if self._is_hotkey_pressed(key):
            if self._on_hotkey:
                threading.Thread(target=self._on_hotkey, daemon=True).start()
            return

        # Navigation keys only work when preview is active
        if self._is_preview_active:
            if key == Key.up and self._on_up_arrow:
                threading.Thread(target=self._on_up_arrow, daemon=True).start()
            elif key == Key.down and self._on_down_arrow:
                threading.Thread(target=self._on_down_arrow, daemon=True).start()
            elif key == Key.esc and self._on_escape:
                threading.Thread(target=self._on_escape, daemon=True).start()

    def _on_key_release(self, key):
        """Handle key release events."""
        if key in (Key.ctrl_l, Key.ctrl_r, Key.ctrl):
            self._ctrl_pressed = False
