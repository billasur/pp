#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== Running Voice & Pipeline Benchmarks ==="
bash scripts/check-voice.sh
bash scripts/check-desktop.sh

TIMING_LOG="${HOME}/Library/Application Support/pp/timing.jsonl"
if [ -f "$TIMING_LOG" ]; then
    echo "=== Recent timing.jsonl entries ==="
    tail -n 5 "$TIMING_LOG"
else
    echo "No timing.jsonl found yet at $TIMING_LOG"
fi
