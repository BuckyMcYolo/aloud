#!/usr/bin/env bash
# Aloud installer. Sets up an isolated environment and a launch agent.
set -euo pipefail

BLUE=$'\033[38;5;141m'; DIM=$'\033[2m'; OFF=$'\033[0m'
say() { printf "%s◍%s %s\n" "$BLUE" "$OFF" "$1"; }
note() { printf "  %s%s%s\n" "$DIM" "$1" "$OFF"; }

[[ "$(uname -s)" == "Darwin" ]] || { echo "Aloud is macOS only."; exit 1; }

say "Checking dependencies"

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required: https://brew.sh"
  exit 1
fi

if ! command -v espeak-ng >/dev/null 2>&1; then
  note "installing espeak-ng (phoneme fallback)"
  brew install espeak-ng
fi

if ! command -v uv >/dev/null 2>&1; then
  note "installing uv"
  brew install uv
fi

PREFIX="$HOME/.aloud"
mkdir -p "$PREFIX"

say "Installing Aloud"
uv venv "$PREFIX/venv" --python 3.12 >/dev/null
# shellcheck disable=SC1091
source "$PREFIX/venv/bin/activate"
uv pip install --quiet "$(cd "$(dirname "$0")" && pwd)"

BIN="$PREFIX/venv/bin/aloud"

say "Setting up login item"
PLIST="$HOME/Library/LaunchAgents/house.aloud.agent.plist"
mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>house.aloud.agent</string>
  <key>ProgramArguments</key>
  <array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLISTEOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo
say "Installed."
note "Aloud is running in your menu bar — look for ◍"
note "Select text anywhere and press ⌥⇧S"
echo
say "One more step"
note "macOS needs to let Aloud read your selection."
note "Open System Settings › Privacy & Security › Accessibility"
note "and turn on the entry for Aloud (or your terminal, if it asks)."
echo
note "Uninstall:  launchctl unload $PLIST && rm -rf ~/.aloud \"$PLIST\""
