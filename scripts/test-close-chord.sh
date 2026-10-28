#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-close-chord.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/IslandCloseChord.swift tests/IslandCloseChordTests.swift -o "$TEST_DIR/close-chord-tests"
"$TEST_DIR/close-chord-tests"
