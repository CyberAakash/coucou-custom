#!/bin/bash
# Builds Coucou (GitHub variant) from this checkout and installs it as /Applications/Coucou Custom.app.
#   scripts/custom-install.sh                  build (optimized) + install + launch
#   scripts/custom-install.sh --check-appstore also build the CoucouAppStore scheme first
#   scripts/custom-install.sh --debug          install an unoptimized Debug build instead
# The installed app runs all day, so it is built optimized: the same code ran at about twice the
# CPU as a Debug build (56 % against 34 % of a core, idle with agents running, measured). Debug
# keeps the DEBUG-only hooks (FORK.md) and builds faster, for checking a change, not for living with.
set -euo pipefail

CONFIG=Release
CHECK_APPSTORE=0
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG=Debug ;;
    --check-appstore) CHECK_APPSTORE=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Coucou Custom.app"
DEST="/Applications/$APP_NAME"
BUILD="$ROOT/NotchBuddy/build"

command -v xcodegen >/dev/null || { echo "xcodegen missing: brew install xcodegen" >&2; exit 1; }

cd "$ROOT/NotchBuddy"
# The project file is generated; restore the committed one however the build ends.
trap 'git -C "$ROOT" checkout -- NotchBuddy/NotchBuddy.xcodeproj/project.pbxproj' EXIT
xcodegen -q

# build <scheme> <derived data name> <configuration> [build settings...]
build() {
  local log="$BUILD/$2.log"
  local scheme="$1" name="$2" config="$3"
  shift 3
  mkdir -p "$BUILD"
  if xcodebuild -scheme "$scheme" -configuration "$config" -destination 'platform=macOS' \
       -derivedDataPath "$BUILD/$name" build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO "$@" >"$log" 2>&1; then
    echo "$scheme ($config): build succeeded"
  else
    grep -E "error:" "$log" | head -20 >&2
    echo "$scheme ($config): build failed (full log: $log)" >&2; exit 1
  fi
}

if [ "$CHECK_APPSTORE" = 1 ]; then build CoucouAppStore appstore Debug; fi
if [ "$CONFIG" = Release ]; then
  # Release compiles in PHONE_LINK (the iPhone sync, which needs iCloud entitlements this local
  # signature does not carry) and Debug did not: empty conditions keep this the same app, minus
  # the DEBUG hooks. One architecture: the universal build doubled the compile and the bundle.
  build NotchBuddy github-release Release ONLY_ACTIVE_ARCH=YES SWIFT_ACTIVE_COMPILATION_CONDITIONS=
  APP="$BUILD/github-release/Build/Products/Release/Coucou.app"
else
  build NotchBuddy github Debug
  APP="$BUILD/github/Build/Products/Debug/Coucou.app"
fi
# macOS ties Accessibility, microphone and screen-recording grants to the signature. An ad-hoc
# signature is identified by its code hash, which changes every build and silently drops those
# grants, so sign with the stable local identity from custom-signing-cert.sh. (The official
# Developer ID certificate belongs to the upstream author.)
IDENTITY="Coucou Custom Local Signing"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  SIGN="$IDENTITY"
else
  echo "No \"$IDENTITY\" identity: run scripts/custom-signing-cert.sh once. Signing ad-hoc," >&2
  echo "so permissions will need granting again after every build." >&2
  SIGN="-"
fi
codesign --force --deep -s "$SIGN" --entitlements Resources/Coucou.entitlements "$APP"

# Build copies must not count as apps: Launchpad, Spotlight and "Open With" would list each one,
# and launching one runs a second Coucou (the App Store variant has no background mode).
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister
touch "$BUILD/.metadata_never_index"
for copy in "$BUILD"/*/Build/Products/*/Coucou.app; do
  [ -d "$copy" ] && "$LSREGISTER" -u "$copy" >/dev/null 2>&1 || true
done

if pgrep -f "$DEST/Contents/MacOS/Coucou" >/dev/null; then
  # A signal, not an AppleScript quit: with "Run in background" on, Coucou cancels ordinary quits.
  pkill -TERM -f "$DEST/Contents/MacOS/Coucou" || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "$DEST/Contents/MacOS/Coucou" >/dev/null || break; sleep 0.5; done
fi
# Update in place: macOS App Management lets this script replace the bundle's contents but not
# delete the signed bundle folder itself.
mkdir -p "$DEST"
rsync -a --delete "$APP/" "$DEST/"
codesign --verify "$DEST"
"$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true
open "$DEST"
echo "Installed $DEST ($(git -C "$ROOT" rev-parse --abbrev-ref HEAD) @ $(git -C "$ROOT" rev-parse --short HEAD))"
