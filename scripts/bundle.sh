#!/bin/bash
# Assemble tingle.app from a SwiftPM release build.
#
# Usage: scripts/bundle.sh [output-dir]        (default: ./dist)
# Signing: ad-hoc by default; set CODESIGN_IDENTITY="Developer ID
# Application: ..." for a real signature (required for distribution —
# TCC grants only survive updates with a stable identity, and Homebrew
# requires notarization for casks).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
OUT="${1:-dist}"
APP="$OUT/tingle.app"
IDENTITY="${CODESIGN_IDENTITY:--}"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/tingle "$APP/Contents/MacOS/tingle"
# SwiftPM resource bundle (device payload); Bundle.module resolves it via
# Bundle.main.resourceURL inside an .app.
cp -R .build/release/*.bundle "$APP/Contents/Resources/"

# Sparkle: embed the framework and point the binary's rpath at it.
mkdir -p "$APP/Contents/Frameworks"
cp -R .build/release/Sparkle.framework "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/tingle" 2>/dev/null || true

# App icon: .icns from the checked-in 1024px render of docs/images/icon.svg
# (regenerate with: qlmanage -t -s 1024 -o /tmp docs/images/icon.svg
#  && mv /tmp/icon.svg.png packaging/icon_1024.png).
ICONSET="$(mktemp -d)/tingle.iconset"
mkdir -p "$ICONSET"
for S in 16 32 128 256 512; do
    sips -z "$S" "$S" packaging/icon_1024.png --out "$ICONSET/icon_${S}x${S}.png" > /dev/null
    D=$((S * 2))
    sips -z "$D" "$D" packaging/icon_1024.png --out "$ICONSET/icon_${S}x${S}@2x.png" > /dev/null
done
iconutil -c icns -o "$APP/Contents/Resources/tingle.icns" "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.tutorintelligence.tingle</string>
    <key>CFBundleName</key>
    <string>tingle</string>
    <key>CFBundleDisplayName</key>
    <string>tingle</string>
    <key>CFBundleExecutable</key>
    <string>tingle</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>tingle</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>SUFeedURL</key>
    <string>https://tutorintelligence.github.io/tingle/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>3BlTef+CpeHVRaFJfuvpqt1XGbVZe1HDPo3C127U70E=</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>tingle's summon-agent button brings your coding app to the front.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>tingle listens to your line-in to detect the ting's ultrasonic signals and to transcribe dictation from its microphone.</string>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 Tutor Intelligence, Inc. MIT License.</string>
</dict>
</plist>
PLIST

# Hardened runtime + secure timestamps are REQUIRED for notarization; the
# entitlements re-grant mic capture and Apple Events under the hardened
# runtime. Sparkle's nested executables are signed inside-out per its
# distribution docs (the bare Autoupdate binary is the one every first
# attempt misses — notarization rejects the whole app over it).
if [ "$IDENTITY" != "-" ]; then
  SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
  SIGN=(codesign --force --options runtime --timestamp --sign "$IDENTITY")
  "${SIGN[@]}" "$SPARKLE/Versions/B/Autoupdate"
  "${SIGN[@]}" "$SPARKLE/Versions/B/Updater.app"
  find "$SPARKLE" -name "*.xpc" -maxdepth 5 | while read -r NESTED; do
    "${SIGN[@]}" "$NESTED"
  done
  "${SIGN[@]}" "$SPARKLE"
  codesign --force --options runtime --timestamp \
      --entitlements packaging/entitlements.plist \
      --sign "$IDENTITY" "$APP"
else
  codesign --force --deep --sign "$IDENTITY" "$APP"
fi
echo "built $APP (version $VERSION, signed: $IDENTITY)"
