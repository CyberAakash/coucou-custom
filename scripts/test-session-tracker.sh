#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-session-tracker.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc \
    NotchBuddy/Sources/App/SessionTracker.swift \
    tests/SessionTrackerTests.swift -o "$TEST_DIR/session-tracker-tests"
"$TEST_DIR/session-tracker-tests"
