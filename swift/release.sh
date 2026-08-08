#!/usr/bin/env bash
# Build, notarize, staple, and package Aloud.app into a DMG ready for release.
#
# One-time setup (stores an app-specific password in your keychain):
#   xcrun notarytool store-credentials aloud \
#     --apple-id YOUR_APPLE_ID --team-id 3RR5DSQAVQ
set -euo pipefail

cd "$(dirname "$0")"

./make_app.sh

# Read the version AFTER the build so the DMG name matches what's inside.
VERSION=$(defaults read "$(pwd)/build/Aloud.app/Contents/Info.plist" CFBundleShortVersionString)
DMG="build/Aloud-$VERSION.dmg"

echo "▸ notarizing (this waits on Apple, typically 1–5 minutes)"
ditto -c -k --keepParent build/Aloud.app build/Aloud-notarize.zip
xcrun notarytool submit build/Aloud-notarize.zip \
  --keychain-profile aloud --wait
rm build/Aloud-notarize.zip

echo "▸ stapling ticket"
xcrun stapler staple build/Aloud.app

echo "▸ building DMG"
rm -rf build/dmg "$DMG"
mkdir -p build/dmg
cp -R build/Aloud.app build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -volname "Aloud" -srcfolder build/dmg -ov -format UDZO "$DMG" >/dev/null
rm -rf build/dmg

echo "▸ done: $DMG"
echo "  sha256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
