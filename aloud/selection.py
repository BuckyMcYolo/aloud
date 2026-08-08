"""Read the current selection from whatever app has focus.

macOS Services only reach apps built on native text views, which is why
Quick Actions silently do nothing in VS Code, Cursor, Slack, Discord and
every other Electron app. Synthesising a Copy keystroke works everywhere,
so that is what we do — then we put the user's clipboard back.
"""

from __future__ import annotations

import time

from AppKit import NSPasteboard, NSPasteboardTypeString
from Quartz import (
    CGEventCreateKeyboardEvent,
    CGEventPost,
    CGEventSetFlags,
    kCGHIDEventTap,
    kCGEventFlagMaskCommand,
)

KEY_C = 8
COPY_TIMEOUT = 0.6


def _press_copy():
    down = CGEventCreateKeyboardEvent(None, KEY_C, True)
    up = CGEventCreateKeyboardEvent(None, KEY_C, False)
    CGEventSetFlags(down, kCGEventFlagMaskCommand)
    CGEventSetFlags(up, kCGEventFlagMaskCommand)
    CGEventPost(kCGHIDEventTap, down)
    CGEventPost(kCGHIDEventTap, up)


def read_clipboard() -> str:
    pb = NSPasteboard.generalPasteboard()
    value = pb.stringForType_(NSPasteboardTypeString)
    return value or ""


def capture_selection(restore: bool = True) -> str:
    """Copy the focused selection and return it.

    Returns an empty string if nothing was selected — the clipboard change
    count tells us whether the app actually answered the Copy.
    """
    pb = NSPasteboard.generalPasteboard()
    previous = pb.stringForType_(NSPasteboardTypeString)
    before = pb.changeCount()

    _press_copy()

    deadline = time.time() + COPY_TIMEOUT
    while time.time() < deadline:
        if pb.changeCount() != before:
            break
        time.sleep(0.02)
    else:
        # Nothing was selected, or the app ignored the keystroke.
        return ""

    text = pb.stringForType_(NSPasteboardTypeString) or ""

    if restore and previous is not None:
        # Give the app a beat to finish writing before we overwrite it.
        time.sleep(0.05)
        pb.clearContents()
        pb.setString_forType_(previous, NSPasteboardTypeString)

    return text.strip()
