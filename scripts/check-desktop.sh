#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -parse-as-library Sources/PpDesktop/HotKey.swift Sources/PpDesktop/SpeechInput.swift Sources/PpDesktop/WakePhrase.swift Sources/PpDesktop/ParakeetEOU.swift Sources/PpDesktop/KeywordSpotter.swift Tests/DesktopChecks/main.swift -o "$CHECK_DIR/check-desktop"
"$CHECK_DIR/check-desktop"
