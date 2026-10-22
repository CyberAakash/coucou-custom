#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-notch-alerts.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library \
    NotchBuddy/Sources/App/NotchAlertRules.swift \
    NotchBuddy/Sources/App/SessionTracker.swift \
    tests/NotchAlertRulesTests.swift -o "$TEST_DIR/notch-alert-tests"
"$TEST_DIR/notch-alert-tests"
