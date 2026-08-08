#!/usr/bin/env bash
# Install Aloud: grabs the latest signed release and puts it in /Applications.
set -euo pipefail

[[ "$(uname -s)" == "Darwin" ]] || { echo "Aloud is macOS only."; exit 1; }
[[ "$(uname -m)" == "arm64" ]] || { echo "Aloud requires Apple Silicon."; exit 1; }

if command -v brew >/dev/null 2>&1; then
  echo "Installing with Homebrew"
  brew install --cask BuckyMcYolo/tap/aloud
else
  echo "Downloading the latest release"
  URL=$(curl -fsSL https://api.github.com/repos/BuckyMcYolo/aloud/releases/latest \
    | grep -o 'https://[^"]*\.dmg' | head -1)
  [[ -n "$URL" ]] || { echo "Could not find the latest release."; exit 1; }
  TMP=$(mktemp -d)
  curl -fL --progress-bar "$URL" -o "$TMP/Aloud.dmg"
  MOUNT=$(hdiutil attach "$TMP/Aloud.dmg" -nobrowse | grep -o '/Volumes/.*' | head -1)
  rm -rf /Applications/Aloud.app
  cp -R "$MOUNT/Aloud.app" /Applications/
  hdiutil detach "$MOUNT" >/dev/null
  rm -rf "$TMP"
fi

open /Applications/Aloud.app
echo
echo "Aloud is running in your menu bar."
echo "Select text anywhere and press Option-Shift-S."
echo "macOS will ask you to enable Aloud under Privacy & Security > Accessibility."
