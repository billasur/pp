#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
echo "Starting pp with --hear flag (press Ctrl-C to stop)..."
swift run PpDesktop --hear
