#!/usr/bin/env bash
# The Daily brief's rules (DailyBriefLogic.swift).
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-daily-brief.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
# The stubs' recap records must be the real ones, field for field.
for type in RecapTurn RecapDecision; do
    real="$(sed -n "/^struct $type/,/^}/p" NotchBuddy/Sources/App/RecapStore.swift)"
    stub="$(sed -n "/^struct $type/,/^}/p" tests/DailyBriefStubs.swift)"
    if [ "$real" != "$stub" ]; then echo "tests/DailyBriefStubs.swift $type differs from RecapStore.swift" >&2; exit 1; fi
done
swiftc -parse-as-library \
    tests/DailyBriefStubs.swift \
    NotchBuddy/Sources/App/DailyBriefLogic.swift \
    NotchBuddy/Sources/App/DailyBriefWeather.swift \
    tests/DailyBriefTests.swift -o "$TEST_DIR/daily-brief-tests"
"$TEST_DIR/daily-brief-tests"
