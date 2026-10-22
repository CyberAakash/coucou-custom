#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-question-queue.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
# QuestionQueue.swift's observable model needs Combine only; AskQuestion comes from its own file.
swiftc -parse-as-library \
    NotchBuddy/Sources/App/AskQuestion.swift \
    NotchBuddy/Sources/App/QuestionQueue.swift \
    tests/QuestionQueueTests.swift -o "$TEST_DIR/question-queue-tests"
"$TEST_DIR/question-queue-tests"
