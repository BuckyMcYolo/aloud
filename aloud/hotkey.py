"""Global hotkey handling.

pynput gives us a system-wide listener without a Carbon bridge. The one
wrinkle is that the modifiers are still physically held when the callback
fires, so anything that synthesises a keystroke afterwards has to wait a
beat and set its own flags explicitly.
"""

from __future__ import annotations

import threading
from typing import Callable

from pynput import keyboard

DEFAULT_COMBO = "<alt>+<shift>+s"

# Shown in the menu bar; pynput's syntax is not something to put in front of
# a person who just wants to know which keys to press.
PRETTY = {
    "<cmd>": "⌘",
    "<ctrl>": "⌃",
    "<alt>": "⌥",
    "<shift>": "⇧",
    "+": "",
}


def pretty(combo: str) -> str:
    out = combo
    for token, glyph in PRETTY.items():
        out = out.replace(token, glyph)
    return out.upper()


class HotkeyListener:
    def __init__(self):
        self._listener: keyboard.GlobalHotKeys | None = None
        self._lock = threading.Lock()

    def bind(self, mapping: dict[str, Callable[[], None]]):
        """Replace all bindings. Keys are pynput combo strings."""
        with self._lock:
            self.stop()
            self._listener = keyboard.GlobalHotKeys(mapping)
            self._listener.daemon = True
            self._listener.start()

    def stop(self):
        if self._listener is not None:
            try:
                self._listener.stop()
            except Exception:
                pass
            self._listener = None
