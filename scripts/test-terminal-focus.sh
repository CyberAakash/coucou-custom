#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-terminal-focus.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library \
    NotchBuddy/Sources/App/TerminalFocus.swift \
    NotchBuddy/Sources/App/TerminalInput.swift \
    NotchBuddy/Sources/App/SessionTracker.swift \
    tests/TerminalFocusTests.swift -o "$TEST_DIR/terminal-focus-tests"
"$TEST_DIR/terminal-focus-tests"
