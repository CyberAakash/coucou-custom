#!/usr/bin/env bash
# The menu-bar Runner's rules (RunnerLogic.swift). Set RUNNER_GALLERY_ZIP to a Runner Gallery
# <name>-frames.zip to also check a real archive.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-runner.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library \
    NotchBuddy/Sources/App/RunnerLogic.swift \
    tests/RunnerTests.swift -o "$TEST_DIR/runner-tests"
"$TEST_DIR/runner-tests"
