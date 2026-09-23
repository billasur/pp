#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -parse-as-library Sources/PpDesktop/HotKey.swift Sources/PpDesktop/SpeechInput.swift Sources/PpDesktop/EnergyEOU.swift Sources/PpCore/AudioRingBuffer.swift Sources/PpCore/WakeSession.swift Sources/PpCore/WakeMatcher.swift Sources/PpCore/SpeechVocabulary.swift Sources/PpCore/AppAliases.swift Sources/PpCore/RecognitionSettings.swift Sources/PpCore/SiteTable.swift Sources/PpCore/WebIntent.swift Sources/PpCore/Preferences.swift Sources/PpCore/WakePhrase.swift Sources/PpCore/DismissalPhrase.swift Sources/PpCore/DirectIntent.swift Sources/PpCore/Planner.swift Sources/PpCore/GrammarPlanner.swift Sources/PpCore/SafetyCritic.swift Sources/PpCore/PreemptionPolicy.swift Tests/DesktopChecks/main.swift -o "$CHECK_DIR/check-desktop"
"$CHECK_DIR/check-desktop"
