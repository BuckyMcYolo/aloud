#!/usr/bin/env bash
# Build Aloud.app from the Swift package.
#
# xcodebuild (not `swift build`) is required: MLX's Metal shaders can only be
# compiled into their resource bundle by Xcode's build system.
set -euo pipefail

cd "$(dirname "$0")"

SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
DERIVED=.xcbuild
APP=build/Aloud.app

echo "▸ building (xcodebuild, Release)"
xcodebuild -scheme Aloud -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" build 2>&1 | tail -2

PRODUCTS="$DERIVED/Build/Products/Release"
[[ -f "$PRODUCTS/Aloud" ]] || { echo "build product missing"; exit 1; }

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$PRODUCTS/Aloud" "$APP/Contents/MacOS/Aloud"
cp Icon/Aloud.icns "$APP/Contents/Resources/"
# MLX looks for its compiled Metal kernels in this bundle at runtime.
for bundle in "$PRODUCTS"/*.bundle; do
  cp -R "$bundle" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Aloud</string>
  <key>CFBundleDisplayName</key><string>Aloud</string>
  <key>CFBundleIdentifier</key><string>house.aloud</string>
  <key>CFBundleVersion</key><string>0.2.1</string>
  <key>CFBundleShortVersionString</key><string>0.2.1</string>
  <key>CFBundleExecutable</key><string>Aloud</string>
  <key>CFBundleIconFile</key><string>Aloud</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT</string>
</dict>
</plist>
PLIST

echo "▸ signing"
codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --verbose=1 "$APP"

echo "▸ done: $APP"
