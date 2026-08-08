# Aloud

Read any selected text out loud on macOS, in a voice that doesn't sound like 2011.

Runs [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) locally — no API key,
no network, no per-character billing. Select text anywhere, press `⌥⇧S`, and a
floating panel reads it back while showing you the waveform of what you're hearing.

## Why this exists

macOS has Speak Selection built in (Accessibility › Read & Speak). Two problems:

1. The voices sound synthetic, even the premium downloads.
2. It only works in apps built on native text views — it silently does nothing
   in VS Code, Cursor, Slack, Discord, or anything else built on Electron.

Aloud fixes both. It uses a modern neural voice, and it captures the selection
through a clipboard round-trip instead of macOS Services, so it works everywhere.

## Install

```bash
git clone https://github.com/YOURNAME/aloud.git
cd aloud
./install.sh
```

Then open **System Settings › Privacy & Security › Accessibility** and enable
Aloud. It needs this to read your selection — that's the whole reason for the
permission, and nothing leaves your machine.

First run downloads the model once (~350 MB) into `~/.aloud/models`.

## Use

| | |
|---|---|
| `⌥⇧S` | Read the selection |
| `⌥⇧S` again | Stop |
| Menu bar `◍` | Voice, speed, preview |

Voice and speed are in the menu bar icon. Settings live in `~/.aloud/config.json`
if you'd rather edit them directly:

```json
{
  "voice": "af_heart",
  "speed": 1.0,
  "hotkey": "<alt>+<shift>+s",
  "restore_clipboard": true
}
```

Hotkey syntax is [pynput's](https://pynput.readthedocs.io/en/latest/keyboard.html#global-hotkeys):
`<cmd>`, `<ctrl>`, `<alt>`, `<shift>` joined with `+`.

## How it works

```
hotkey ─▶ synthesise ⌘C ─▶ read pasteboard ─▶ restore pasteboard
                                  │
                                  ▼
                        split into sentences
                                  │
                     ┌────────────┴────────────┐
                     ▼                         ▼
             synthesise chunk n+1        play chunk n
                     └────────────┬────────────┘
                                  ▼
                          HUD waveform + text
```

Synthesis runs one chunk ahead of playback, so audio starts within a beat of the
keypress even on a long selection, and stopping is immediate rather than waiting
for a whole paragraph to finish rendering.

The clipboard is saved and restored around the copy. If the app under the cursor
doesn't answer the Copy within 600 ms, Aloud assumes nothing was selected and
says so instead of reading your last clipboard entry by accident.

## Layout

| File | Role |
|---|---|
| `aloud/engine.py` | Kokoro wrapper, sentence chunking, interruptible playback |
| `aloud/selection.py` | Clipboard round-trip that works in Electron apps |
| `aloud/hud.py` | The floating panel — waveform, text, stop |
| `aloud/hotkey.py` | Global hotkey binding |
| `aloud/app.py` | Menu bar app and settings |

## Voices

Kokoro ships 50+ across 8 languages. The menu surfaces seven English ones; to use
any other, put its ID in `config.json`. Prefix tells you the accent and gender —
`af_` American female, `am_` American male, `bf_`/`bm_` British.

## Known limits

- Apple Silicon only in practice. It runs on Intel through onnxruntime's CPU
  provider, but slower than real time on older chips.
- No voice cloning. Kokoro is preset voices only — that's the tradeoff for
  being 82M parameters and fast.
- Password fields and other secure inputs won't yield a selection, by design.

## License

MIT. Kokoro-82M is Apache 2.0, so commercial use is fine on both counts.
