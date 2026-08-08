# Aloud

Read any selected text out loud on macOS with a local neural voice. Select text in any app, press the hotkey, and a small floating panel reads it back while showing the waveform of what you're hearing.

Runs [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) on device. No cloud, no API keys, nothing leaves your machine. Works in every app, including Electron ones like VS Code, Cursor, Slack, and Discord, where the built-in macOS Speak Selection silently does nothing.

Requires Apple Silicon and macOS 14 or later.

## Install

Homebrew:

```bash
brew install --cask BuckyMcYolo/tap/aloud
```

curl:

```bash
curl -fsSL https://raw.githubusercontent.com/BuckyMcYolo/aloud/main/install.sh | bash
```

Or download the DMG from [Releases](https://github.com/BuckyMcYolo/aloud/releases) and drag Aloud to Applications. 

After installing, enable Aloud under System Settings > Privacy & Security > Accessibility. It needs this to read your selection, and that is the only permission it asks for. First launch downloads the model once (about 310 MB) with progress shown in the panel.

## Use

| | |
|---|---|
| `⌥⇧S` | Read the selection |
| `⌥⇧S` again | Stop |
| Menu bar icon | Voice, speed, shortcut, preview |

The panel shows the app you're reading from, a live waveform, and transport controls. Click or drag anywhere on the waveform to jump around. Pause, skip 10 seconds either way, or change the speed without leaving the panel.

To change the shortcut, use the Shortcut submenu in the menu bar, or edit `~/.aloud/config.json`.

## Voices

Kokoro ships 54 voices across 8 languages. The menu surfaces seven English ones; to use any other, put its id in `config.json`. The prefix tells you accent and gender: `af_` American female, `am_` American male, `bf_`/`bm_` British.

## Development

The native Swift app lives in `swift/` and builds with `./swift/make_app.sh` (requires Xcode). The original Python implementation lives in `aloud/` and is kept as a reference. See [RELEASING.md](RELEASING.md) for how releases are cut.

## License

MIT. Kokoro-82M is Apache 2.0, so commercial use is fine on both counts.
