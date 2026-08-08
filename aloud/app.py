"""Aloud — read the selection out loud, in a good voice, with no network.

Menu bar app. One hotkey copies whatever is selected, hands it to Kokoro,
and shows a floating panel while it reads.
"""

from __future__ import annotations

import json
import threading
from pathlib import Path

import rumps
from AppKit import NSWorkspace

from .engine import Engine
from .hotkey import DEFAULT_COMBO, HotkeyListener, pretty
from .hud import ReaderHUD
from .selection import capture_selection

CONFIG = Path.home() / ".aloud" / "config.json"

DEFAULTS = {
    "voice": "af_heart",
    "speed": 1.0,
    "hotkey": DEFAULT_COMBO,
    "restore_clipboard": True,
}

# Kokoro ships 50+ voices; these are the ones worth putting in a menu.
FEATURED_VOICES = [
    ("Heart — warm, female", "af_heart"),
    ("Bella — bright, female", "af_bella"),
    ("Nicole — soft, female", "af_nicole"),
    ("Adam — even, male", "am_adam"),
    ("Michael — low, male", "am_michael"),
    ("Emma — British, female", "bf_emma"),
    ("George — British, male", "bm_george"),
]

SPEEDS = [0.8, 0.9, 1.0, 1.1, 1.25, 1.5]


def load_config() -> dict:
    data = dict(DEFAULTS)
    try:
        data.update(json.loads(CONFIG.read_text()))
    except Exception:
        pass
    return data


def save_config(data: dict):
    CONFIG.parent.mkdir(parents=True, exist_ok=True)
    CONFIG.write_text(json.dumps(data, indent=2))


class Aloud(rumps.App):
    def __init__(self):
        super().__init__("Aloud", title="◍", quit_button=None)
        self.config = load_config()
        self.engine = Engine(
            voice=self.config["voice"], speed=float(self.config["speed"])
        )
        self.hud = ReaderHUD(
            engine=self.engine,
            on_stop=self.stop_speaking,
            on_toggle=self.engine.toggle_pause,
            on_seek=self.engine.seek_fraction,
            on_skip=self.engine.seek_seconds,
            on_speed=self._cycle_speed,
            speed_label=f"{float(self.config['speed']):g}×",
        )
        self.hotkeys = HotkeyListener()
        # Guards the capture window, where engine.speaking is still False —
        # without it a quick double press launches two overlapping reads.
        self._read_lock = threading.Lock()
        self._build_menu()
        self._bind_hotkey()
        threading.Thread(target=self._warm_up, daemon=True).start()

    # -- menu ----------------------------------------------------------------

    def _build_menu(self):
        combo = pretty(self.config["hotkey"])

        voices = rumps.MenuItem("Voice")
        for label, value in FEATURED_VOICES:
            item = rumps.MenuItem(label, callback=self._pick_voice)
            item.voice_id = value
            item.state = value == self.config["voice"]
            voices.add(item)
        self._voice_menu = voices

        speeds = rumps.MenuItem("Speed")
        for value in SPEEDS:
            label = f"{value:g}×"
            item = rumps.MenuItem(label, callback=self._pick_speed)
            item.speed_value = value
            item.state = abs(value - float(self.config["speed"])) < 0.01
            speeds.add(item)
        self._speed_menu = speeds

        self.menu = [
            rumps.MenuItem(f"Read selection   {combo}", callback=self.read_selection),
            rumps.MenuItem("Stop", callback=lambda _: self.stop_speaking()),
            None,
            voices,
            speeds,
            None,
            rumps.MenuItem("Preview voice", callback=self._preview),
            rumps.MenuItem("Grant Accessibility access…", callback=self._open_settings),
            None,
            rumps.MenuItem("Quit Aloud", callback=self._quit),
        ]

    def _pick_voice(self, sender):
        for item in self._voice_menu.values():
            item.state = False
        sender.state = True
        self.config["voice"] = sender.voice_id
        self.engine.voice = sender.voice_id
        save_config(self.config)
        self._preview(None)

    def _pick_speed(self, sender):
        for item in self._speed_menu.values():
            item.state = False
        sender.state = True
        self.config["speed"] = sender.speed_value
        self.engine.speed = sender.speed_value
        save_config(self.config)
        self.hud.set_speed_label(f"{sender.speed_value:g}×")

    def _cycle_speed(self) -> str:
        """HUD speed button: advance to the next preset, return its label.

        Kokoro applies speed at synthesis time, so a change takes effect from
        the next sentence synthesised, not the audio already buffered.
        """
        current = float(self.config["speed"])
        idx = min(range(len(SPEEDS)), key=lambda i: abs(SPEEDS[i] - current))
        value = SPEEDS[(idx + 1) % len(SPEEDS)]
        self.config["speed"] = value
        self.engine.speed = value
        save_config(self.config)
        for item in self._speed_menu.values():
            item.state = abs(item.speed_value - value) < 0.01
        return f"{value:g}×"

    def _open_settings(self, _):
        import subprocess

        subprocess.run(
            [
                "open",
                "x-apple.systempreferences:com.apple.preference."
                "security?Privacy_Accessibility",
            ],
            check=False,
        )

    def _quit(self, _):
        self.stop_speaking()
        self.hotkeys.stop()
        rumps.quit_application()

    # -- lifecycle -----------------------------------------------------------

    def _bind_hotkey(self):
        self.hotkeys.bind(
            {
                self.config["hotkey"]: self._hotkey_pressed,
            }
        )

    def _warm_up(self):
        """Load the model in the background so the first read is not a stall."""
        try:
            self.engine.load(progress=lambda msg: None)
        except Exception:
            pass

    # -- actions -------------------------------------------------------------

    def _hotkey_pressed(self):
        # Pressing the hotkey while it is talking means "stop".
        if self.engine.speaking:
            self.stop_speaking()
            return
        threading.Thread(target=self._read_selection_now, daemon=True).start()

    def read_selection(self, _=None):
        threading.Thread(target=self._read_selection_now, daemon=True).start()

    def _read_selection_now(self):
        import time

        if not self._read_lock.acquire(blocking=False):
            return  # a capture is already in flight; one reader is plenty

        try:
            # Note where the text is coming from while that app is still
            # frontmost — the HUD shows its icon and name.
            front = NSWorkspace.sharedWorkspace().frontmostApplication()
            if front is not None:
                self.hud.set_source(front.localizedName(), front.icon())
            else:
                self.hud.set_source("Selection", None)

            # Let the hotkey modifiers lift before we synthesise Command-C.
            time.sleep(0.12)
            try:
                text = capture_selection(restore=self.config["restore_clipboard"])
            except Exception:
                self.hud.set_message(
                    "Aloud needs Accessibility access",
                    "System Settings › Privacy & Security › Accessibility",
                )
                self.hud.show()
                self.hud.hide(delay=4.0)
                return

            if not text:
                self.hud.set_message(
                    "Nothing selected", "Highlight some text and try again"
                )
                self.hud.show()
                self.hud.hide(delay=1.8)
                return

            self.speak(text)
        finally:
            self._read_lock.release()

    def speak(self, text: str):
        self.title = "◉"
        if not self.engine.ready:
            self.hud.set_message("Warming up the voice…", "loading the model")
        self.hud.show()

        self.engine.speak(text, on_done=self._finished, on_error=self._failed)

    def stop_speaking(self):
        self.engine.stop()
        self.title = "◍"
        self.hud.hide(delay=0.0)

    def _finished(self):
        self.title = "◍"
        self.hud.hide(delay=0.7)

    def _failed(self, exc: Exception):
        self.title = "◍"
        self.hud.set_message("Could not read that", str(exc)[:90])
        self.hud.show()
        self.hud.hide(delay=4.0)

    def _preview(self, _):
        self.hud.set_source("Aloud", None)
        self.speak("This is how I sound. Highlight anything and press the hotkey.")


def main():
    Aloud().run()


if __name__ == "__main__":
    main()
