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
    <key>NSMicrophoneUsageDescription</key>
    <string>tingle listens to your line-in to detect the ting's ultrasonic signals and to transcribe dictation from its microphone.</string>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 Tutor Intelligence, Inc. MIT License.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign "$IDENTITY" "$APP"
echo "built $APP (version $VERSION, signed: $IDENTITY)"
