#!/bin/zsh
# Runs `swift test` with the swift-testing macros served by the toolchain's out-of-process
# plugin server. SwiftPM's default for Command Line Tools is the in-process server, which fails
# intermittently with "plugin for module 'TestingMacros' not found". Extra arguments pass through.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="$(xcrun --find swift-plugin-server 2>/dev/null || true)"
TOOLCHAIN="${SERVER%/bin/swift-plugin-server}"
PLUGINS="$TOOLCHAIN/lib/swift/host/plugins/testing"

FLAGS=()
if [[ -x "$SERVER" && -d "$PLUGINS" ]]; then
  FLAGS=(-Xswiftc -external-plugin-path -Xswiftc "$PLUGINS#$SERVER")
fi

exec swift test --package-path "$ROOT_DIR" "${FLAGS[@]}" "$@"
