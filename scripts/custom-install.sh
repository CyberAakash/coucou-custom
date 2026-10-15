#!/bin/bash
# Builds Coucou (GitHub variant) from this checkout and installs it as /Applications/Coucou Custom.app.
#   scripts/custom-install.sh                  build + install + launch
#   scripts/custom-install.sh --check-appstore also build the CoucouAppStore scheme first
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Coucou Custom.app"
DEST="/Applications/$APP_NAME"
BUILD="$ROOT/NotchBuddy/build"

command -v xcodegen >/dev/null || { echo "xcodegen missing: brew install xcodegen" >&2; exit 1; }

cd "$ROOT/NotchBuddy"
# The project file is generated; restore the committed one however the build ends.
trap 'git -C "$ROOT" checkout -- NotchBuddy/NotchBuddy.xcodeproj/project.pbxproj' EXIT
xcodegen -q

build() {
  local log="$BUILD/$2.log"
  mkdir -p "$BUILD"
  if xcodebuild -scheme "$1" -configuration Debug -destination 'platform=macOS' \
       -derivedDataPath "$BUILD/$2" build CODE_SIGNING_ALLOWED=NO >"$log" 2>&1; then
    echo "$1: build succeeded"
  else
    grep -E "error:" "$log" | head -20 >&2
    echo "$1: build failed (full log: $log)" >&2; exit 1
  fi
}

if [ "${1:-}" = "--check-appstore" ]; then build CoucouAppStore appstore; fi
build NotchBuddy github

APP="$BUILD/github/Build/Products/Debug/Coucou.app"
# Ad-hoc signature with the app's own entitlements (microphone, Apple Events); the official
# Developer ID certificate belongs to the upstream author.
codesign --force --deep -s - --entitlements Resources/Coucou.entitlements "$APP"

if pgrep -f "$DEST/Contents/MacOS/Coucou" >/dev/null; then
  osascript -e "tell application \"$DEST\" to quit" || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "$DEST/Contents/MacOS/Coucou" >/dev/null || break; sleep 0.5; done
fi
rm -rf "$DEST"
cp -R "$APP" "$DEST"
codesign --verify "$DEST"
open "$DEST"
echo "Installed $DEST ($(git -C "$ROOT" rev-parse --abbrev-ref HEAD) @ $(git -C "$ROOT" rev-parse --short HEAD))"
