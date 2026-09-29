#!/bin/zsh
# Builds the release binary and packages Murmur.app next to this script.
#
#   BUNDLE_ID=...          override the bundle identifier (default com.alexanderadkins.Murmur)
#   VERSION=...            CFBundleShortVersionString (default 1.0.0)
#   CODESIGN_IDENTITY=...  sign with a specific identity; otherwise "Murmur Signing" if it
#                          exists (see scripts/make-signing-identity.sh), else ad-hoc. A custom
#                          identity name from that script must be passed here explicitly.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_ID="${BUNDLE_ID:-com.alexanderadkins.Murmur}"
VERSION="${VERSION:-1.0.0}"

swift build \
  --package-path "$ROOT_DIR" \
  -c release \
  --product murmur

echo "Built $ROOT_DIR/.build/release/murmur"

APP_DIR="$ROOT_DIR/Murmur.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$ROOT_DIR/.build/release/murmur" "$MACOS_DIR/murmur"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>murmur</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Murmur</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Murmur records from the selected Mac microphone while the Siri button is held for push-to-talk dictation.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Murmur uses speech recognition to turn push-to-talk audio into text.</string>
</dict>
</plist>
PLIST

# A stable identity keeps macOS privacy grants across rebuilds; scripts/make-signing-identity.sh creates one.
SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -q '"Murmur Signing"'; then
  SIGN_IDENTITY="Murmur Signing"
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP_DIR" >/dev/null
  echo "Signed with \"$SIGN_IDENTITY\""
else
  codesign --force --sign - "$APP_DIR" >/dev/null
  echo "Signed ad-hoc (run scripts/make-signing-identity.sh to keep permissions across rebuilds)"
fi

echo "Packaged $APP_DIR"
