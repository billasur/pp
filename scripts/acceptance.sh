#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=================================================="
echo "          pp v3 Acceptance Verification"
echo "=================================================="

TOTAL_PASS=0
TOTAL_FAIL=0

run_check() {
    local name="$1"
    local cmd="$2"
    printf "%-35s " "$name..."
    if output=$(eval "$cmd" 2>&1); then
        printf "\033[0;32m[PASS]\033[0m\n"
        TOTAL_PASS=$((TOTAL_PASS + 1))
    else
        printf "\033[0;31m[FAIL]\033[0m\n"
        echo "$output" | sed 's/^/    /'
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi
}

run_check "Router Acceptance Battery" "swift test --filter AcceptanceTests"
run_check "Voice & Preemption Checks" "bash scripts/check-voice.sh"
run_check "Desktop Simulation Checks" "bash scripts/check-desktop.sh"
run_check "Core & State Machine Tests" "swift test --filter 'WakeSessionTests|WakeMatcherTests|AppAliasTests|WebIntentTests'"

echo "=================================================="
printf "Results: %d Passed, %d Failed\n" "$TOTAL_PASS" "$TOTAL_FAIL"
echo "=================================================="

if [ "$TOTAL_FAIL" -ne 0 ]; then
    exit 1
fi
