#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-buddy.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
# The stub's BotState must be the real one, case for case.
real="$(sed -n '/^enum BotState/,/^}/p' NotchBuddy/Sources/CoucouKit/IslandTypes.swift)"
stub="$(sed -n '/^enum BotState/,/^}/p' tests/BuddyStubs.swift)"
if [ "$real" != "$stub" ]; then echo "tests/BuddyStubs.swift BotState differs from IslandTypes.swift" >&2; exit 1; fi
swiftc -parse-as-library \
    tests/BuddyStubs.swift \
    NotchBuddy/Sources/App/BuddyPetFormat.swift \
    NotchBuddy/Sources/App/BuddyAtlas.swift \
    NotchBuddy/Sources/App/BuddySettings.swift \
    NotchBuddy/Sources/App/BuddyPetStore.swift \
    tests/BuddyTests.swift -o "$TEST_DIR/buddy-tests"
"$TEST_DIR/buddy-tests"
