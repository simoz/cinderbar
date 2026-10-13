#!/bin/sh
# Builds "dist/Cinder Bar.app" from the Swift package. Needs only the Command Line Tools.
set -eu
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"
swift build -c release --product CinderBar
APP="dist/Cinder Bar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/CinderBar" "$APP/Contents/MacOS/CinderBar"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Cinder Bar</string>
  <key>CFBundleDisplayName</key><string>Cinder Bar</string>
  <key>CFBundleIdentifier</key><string>dev.cinderbar.CinderBar</string>
  <key>CFBundleExecutable</key><string>CinderBar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License. Cinder Bar by Simone Merli, a macOS port of Burn Bar by nixfred.</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "built $APP"

# A zip for GitHub Releases. ditto keeps the bundle's symlinks and attributes.
if [ "${ZIP:-0}" = "1" ]; then
  ZIPFILE="dist/Cinder-Bar-${VERSION}.zip"
  rm -f "$ZIPFILE"
  ditto -c -k --keepParent "$APP" "$ZIPFILE"
  echo "zipped $ZIPFILE"
fi

# INSTALL=1: replace /Applications/Cinder Bar.app with this build and open it.
if [ "${INSTALL:-0}" = "1" ]; then
  pkill -x CinderBar 2>/dev/null || true
  rm -rf "/Applications/Cinder Bar.app"
  ditto "$APP" "/Applications/Cinder Bar.app"
  open "/Applications/Cinder Bar.app"
  echo "installed /Applications/Cinder Bar.app"
fi
