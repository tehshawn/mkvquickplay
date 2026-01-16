"""Global hotkey manager using pynput."""

from typing import Optional, Callable
from pynput import keyboard
from pynput.keyboard import Key, KeyCode
import threading


class HotkeyManager:
    """Manages global hotkey detection for Ctrl+Space and navigation keys."""

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

    def _on_key_press(self, key):
        """Handle key press events."""
        # Track Ctrl key state
        if key == Key.ctrl_l or key == Key.ctrl_r:
            self._ctrl_pressed = True
            return

        # Ctrl+Space hotkey
        if key == Key.space and self._ctrl_pressed:
            if self._on_hotkey:
                # Run callback in separate thread to avoid blocking
                threading.Thread(target=self._on_hotkey, daemon=True).start()
            return

        # Navigation keys only work when preview is active
        if self._is_preview_active:
            if key == Key.up:
                if self._on_up_arrow:
                    threading.Thread(target=self._on_up_arrow, daemon=True).start()
                return

            if key == Key.down:
                if self._on_down_arrow:
                    threading.Thread(target=self._on_down_arrow, daemon=True).start()
                return

            if key == Key.esc:
                if self._on_escape:
                    threading.Thread(target=self._on_escape, daemon=True).start()
                return

    def _on_key_release(self, key):
        """Handle key release events."""
        if key == Key.ctrl_l or key == Key.ctrl_r:
            self._ctrl_pressed = False
