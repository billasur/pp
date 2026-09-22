#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -parse-as-library Sources/PpDesktop/HotKey.swift Sources/PpDesktop/SpeechInput.swift Sources/PpDesktop/EnergyEOU.swift Sources/PpCore/WakePhrase.swift Sources/PpCore/DirectIntent.swift Tests/DesktopChecks/main.swift -o "$CHECK_DIR/check-desktop"
"$CHECK_DIR/check-desktop"
