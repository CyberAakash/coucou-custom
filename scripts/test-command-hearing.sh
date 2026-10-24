#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-hearing.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/Voice/WakePhrase.swift NotchBuddy/Sources/App/Voice/HearingCorrection.swift \
    tests/HearingCorrectionTests.swift -o "$TEST_DIR/hearing-tests"
"$TEST_DIR/hearing-tests"
