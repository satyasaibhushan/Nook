#!/bin/bash
# Builds this checkout in Release, signs it with the local Apple Development certificate and
# replaces /Applications/Nook.app. The app being replaced is kept as a zip, and the tab state
# is copied aside, so one bad build can be undone by unzipping the previous app.
#
#   scripts/install-local.sh            build, sign, swap, relaunch
#   scripts/install-local.sh --build    build and sign only; leaves the installed app alone
set -euo pipefail

cd "$(dirname "$0")/.."
REPO=$PWD
APP=/Applications/Nook.app
BUILT=$REPO/build/Build/Products/Release/Nook.app
STAGED=$REPO/build/staged/Nook.app
BACKUPS=$HOME/Applications/Backups
STATE="$HOME/Library/Application Support/com.gstudios.nook"

# The team id differs from upstream's, so the project's automatic signing cannot be used:
# build unsigned, then sign by hand with the entitlements the release ships with.
IDENTITY=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
[ -n "$IDENTITY" ] || { echo "No Apple Development signing identity in the keychain" >&2; exit 1; }

echo "Building $(git rev-parse --short HEAD)"
xcodebuild -scheme Nook -configuration Release -arch arm64 -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  >build/install-local.log 2>&1 || { grep -E "error:" build/install-local.log | tail -20 >&2; exit 1; }

rm -rf "$REPO/build/staged"
mkdir -p "$REPO/build/staged"
ditto "$BUILT" "$STAGED"

# Nested code first, deepest first, then the app itself with its entitlements.
find "$STAGED/Contents" -depth \
  \( -name "*.xpc" -o -name "*.app" -o -name "*.framework" -o -name "*.dylib" -o -name "*.bundle" -o -name "Autoupdate" \) \
  -exec codesign --force --options runtime --sign "$IDENTITY" {} \; 2>/dev/null
codesign --force --options runtime --entitlements "$REPO/Nook/Nook-CI.entitlements" --sign "$IDENTITY" "$STAGED" 2>/dev/null
codesign --verify --deep --strict "$STAGED"
echo "Signed build at $STAGED"

[ "${1:-}" = "--build" ] && exit 0

# Only the installed app is quit. Other copies (an untouched release, a test build with its own
# state) share the name and bundle id, so the process is found by its path and quit by its pid.
installed_pid() { ps -axo pid=,comm= | awk -v bin="$APP/Contents/MacOS/Nook" '$2 == bin {print $1; exit}'; }
PID=$(installed_pid)
if [ -n "$PID" ]; then
  osascript -l JavaScript -e "ObjC.import('AppKit'); \$.NSRunningApplication.runningApplicationWithProcessIdentifier($PID).terminate" >/dev/null
  for _ in $(seq 1 20); do [ -z "$(installed_pid)" ] && break; /bin/sleep 0.5; done
  [ -n "$(installed_pid)" ] && { echo "Nook did not quit; nothing was replaced" >&2; exit 1; }
fi

mkdir -p "$BACKUPS"
STAMP=$(date +%Y%m%d-%H%M%S)
ditto "$STATE/Tabs" "$BACKUPS/Nook-Tabs-$STAMP"
if [ -d "$APP" ]; then
  ditto -c -k --keepParent "$APP" "$BACKUPS/Nook-app-$STAMP.zip"
  rm -rf "$APP"
fi
ditto "$STAGED" "$APP"
codesign --verify --deep --strict "$APP"

# Keep only the three newest backups of each kind.
ls -dt "$BACKUPS"/Nook-app-*.zip 2>/dev/null | tail -n +4 | while read -r old; do rm -f "$old"; done
ls -dt "$BACKUPS"/Nook-Tabs-2* 2>/dev/null | tail -n +4 | while read -r old; do rm -rf "$old"; done

open "$APP"
echo "Installed $(git rev-parse --short HEAD); previous app saved as $BACKUPS/Nook-app-$STAMP.zip"
