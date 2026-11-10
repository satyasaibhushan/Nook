#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
test_build=$(mktemp -d)
trap 'rm -rf "$test_build"' EXIT
swiftc -swift-version 5 -emit-module -emit-library -module-name NookWeb \
  scripts/tests/find-manager/PageSession.swift -o "$test_build/libNookWeb.dylib" \
  -emit-module-path "$test_build/NookWeb.swiftmodule"
swiftc -swift-version 5 -parse-as-library -I "$test_build" -L "$test_build" -lNookWeb \
  -Xlinker -rpath -Xlinker "$test_build" \
  Nook/Managers/FindManager/FindManager.swift scripts/tests/find-manager/Checks.swift \
  -o "$test_build/find-checks"
"$test_build/find-checks"
