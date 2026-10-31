#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-water.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library NotchBuddy/Sources/App/BuddyRoutines.swift tests/WaterNudgeTests.swift -o "$TEST_DIR/water-tests" 2>&1 | grep -v warning || true
"$TEST_DIR/water-tests"
