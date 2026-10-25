#!/bin/bash
# Builds build/SpeakToMe.app (a real app bundle, which macOS needs to grant mic access).
# Usage: scripts/build-app.sh [--install]   (--install copies it to /Applications)
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/SpeakToMe.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SpeakToMe "$APP/Contents/MacOS/"
cp -R .build/release/*.bundle "$APP/Contents/Resources/"
[[ -f Resources/AppIcon.icns ]] || scripts/make-icns.sh
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Speak to Me</string>
    <key>CFBundleDisplayName</key><string>Speak to Me</string>
    <key>CFBundleIdentifier</key><string>local.speaktome.app</string>
    <key>CFBundleExecutable</key><string>SpeakToMe</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Speak to Me listens so you can talk to your local AI. Audio never leaves this Mac.</string>
</dict>
</plist>
PLIST

# Sign with a stable identity when one exists, so macOS remembers the microphone
# permission across rebuilds (ad-hoc signatures look like a new app every build).
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')
codesign --force --deep --sign "${IDENTITY:--}" "$APP"
echo "Signed with: ${IDENTITY:-ad-hoc}"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf "/Applications/SpeakToMe.app"
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/SpeakToMe.app"
fi
