#!/usr/bin/env bash
# coucou-custom fork: the streamed tool calls' parsing (ChatToolStream), without the app.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-chat-tools.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library -D APPSTORE \
    NotchBuddy/Sources/App/ChatToolStream.swift \
    NotchBuddy/Sources/App/LocalChat.swift \
    NotchBuddy/Sources/App/BuddyTools.swift \
    NotchBuddy/Sources/App/BuddyRoutines.swift \
    tests/ChatToolStreamTests.swift -o "$TEST_DIR/chat-tools-tests"
"$TEST_DIR/chat-tools-tests"
