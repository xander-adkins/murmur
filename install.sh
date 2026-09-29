#!/bin/zsh
# Build, copy Murmur into ~/Applications, and launch it from there so
# Launch at Login and the privacy permissions point at a stable location.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_DIR="$HOME/Applications"
TARGET="$TARGET_DIR/Murmur.app"

"$ROOT_DIR/build.sh"

osascript -e 'tell application "Murmur" to quit' >/dev/null 2>&1 || true
pkill -x murmur 2>/dev/null || true

mkdir -p "$TARGET_DIR"
rm -rf "$TARGET"
cp -R "$ROOT_DIR/Murmur.app" "$TARGET"

echo "Installed $TARGET"
open "$TARGET"
echo
echo "On first launch grant Murmur: Input Monitoring, Accessibility, Microphone."
echo "System Settings > Privacy & Security. If a permission was granted to an older build, remove and re-add it."
