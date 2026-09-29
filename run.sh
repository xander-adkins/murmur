#!/bin/zsh
# Builds (incrementally) and runs Murmur in the foreground as a command-line tool (no menu bar),
# logging to stdout and ~/Library/Logs/Murmur.log. Ctrl-C stops it. Environment variables
# configure it; see README.md. Keystrokes are only posted with MURMUR_TERMINAL=1.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
swift build --package-path "$ROOT_DIR" -c release --product murmur
exec "$ROOT_DIR/.build/release/murmur"
