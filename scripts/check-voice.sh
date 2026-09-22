#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -parse-as-library \
  Sources/PpCore/WakePhrase.swift \
  Sources/PpCore/DismissalPhrase.swift \
  Sources/PpCore/DirectIntent.swift \
  Sources/PpCore/Planner.swift \
  Sources/PpCore/GrammarPlanner.swift \
  Sources/PpCore/SafetyCritic.swift \
  Sources/PpCore/PreemptionPolicy.swift \
  Sources/PpCore/SystemAction.swift \
  Sources/PpCore/ScriptGates.swift \
  Tests/VoiceChecks/main.swift \
  -o "$CHECK_DIR/check-voice"
"$CHECK_DIR/check-voice"
