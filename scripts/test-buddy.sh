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
    NotchBuddy/Sources/CoucouKit/MochiWardrobe.swift \
    NotchBuddy/Sources/App/BuddyLogic.swift \
    NotchBuddy/Sources/App/BuddyWardrobe.swift \
    NotchBuddy/Sources/App/BuddySettings.swift \
    NotchBuddy/Sources/App/BuddyShortcuts.swift \
    NotchBuddy/Sources/App/BuddyRoutines.swift \
    NotchBuddy/Sources/App/BuddyRoutineSettings.swift \
    NotchBuddy/Sources/App/BuddyTools.swift \
    NotchBuddy/Sources/App/BuddySlash.swift \
    NotchBuddy/Sources/App/AppLog.swift \
    tests/BuddyWardrobeTests.swift \
    tests/BuddyRoutinesTests.swift \
    tests/BuddyTests.swift -o "$TEST_DIR/buddy-tests"
"$TEST_DIR/buddy-tests"
