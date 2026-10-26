#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-mochi-pacing.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc \
    NotchBuddy/Sources/App/MochiPacing.swift \
    tests/MochiPacingTests.swift -o "$TEST_DIR/mochi-pacing-tests"
"$TEST_DIR/mochi-pacing-tests"
