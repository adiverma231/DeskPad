#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/DeskPadTests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc -swift-version 5 DeskPad/Helpers/DisplayGeometry.swift Tests/DisplayGeometryTests.swift -o "$test_dir/GeometryTests"
"$test_dir/GeometryTests"

if [ "${1:-}" = "--integration" ]; then
    xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx13.0" -import-objc-header DeskPad/DeskPad-Bridging-Header.h \
        DeskPad/AppDelegate.swift DeskPad/Helpers/*.swift DeskPad/Frontend/Screen/*.swift \
        Tests/DisplayIntegrationTests.swift -o "$test_dir/IntegrationTests"
    "$test_dir/IntegrationTests"
fi
