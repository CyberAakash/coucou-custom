#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-custom-wake.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc \
    NotchBuddy/Sources/App/Voice/WakePhrase.swift \
    tests/CustomWakePhraseTests.swift -o "$TEST_DIR/custom-wake-phrase-tests"
"$TEST_DIR/custom-wake-phrase-tests"
