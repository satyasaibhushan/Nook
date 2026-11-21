#!/bin/bash
# Release build of this checkout under its own bundle id, copied to the directory given.
#   scripts/perf/build.sh /tmp/variant   ->  /tmp/variant/Nook.app
set -euo pipefail
if [[ ${2:-} != --coordinated ]]; then
  exec python3 "$(dirname "$0")/experiment.py" "${1:?usage: build.sh OUTPUT_DIRECTORY}"
fi
# Resolve the requested directory before moving into the checkout.
validator="$(cd "$(dirname "$0")" && pwd -P)/experiment.py"
python3 "$validator" --check-build-output "$1"
mkdir -p "$1"
output="$(cd "$1" && pwd -P)"
cd "$(dirname "$0")/../.."
mkdir -p build
xcodebuild -scheme Nook -configuration Release -arch arm64 -derivedDataPath build \
  PRODUCT_BUNDLE_IDENTIFIER=com.gstudios.nook.perf \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO >build/perf-build.txt 2>&1 \
  || { grep -E "error:" build/perf-build.txt | sort -u | head -20 >&2; exit 1; }
python3 "$validator" --check-build-output "$output"
rm -rf "$output/Nook.app"
ditto build/Build/Products/Release/Nook.app "$output/Nook.app"
# Keep LaunchServices from routing links to the build product instead of the copy under test.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u build/Build/Products/Release/Nook.app >/dev/null 2>&1 || true
echo "built $1/Nook.app"
