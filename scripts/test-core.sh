#!/bin/bash
# The Core layer on its own: no AppKit, no SwiftUI, no HarnessController. Linking
# only these sources is what enforces that boundary, and it takes seconds, so run
# this after every change to event handling or the transcript model.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_TARGET="${SWIFT_TARGET:-$(uname -m)-apple-macos14.0}"

if grep -nE '^import (AppKit|SwiftUI|WebKit|Combine)' "$ROOT"/macos/DSHApp/Core/*.swift; then
  echo "core: Core must not import a UI framework (see above)" >&2
  exit 1
fi

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
swiftc -target "$SWIFT_TARGET" -parse-as-library -D DEBUG -enable-testing -wmo -num-threads 8 \
  -emit-library -emit-module -module-name DSHAppLib \
  -o "$BUILD/libDSHAppLib.dylib" -module-link-name DSHAppLib \
  "$ROOT"/macos/DSHApp/Core/*.swift
swiftc -target "$SWIFT_TARGET" -parse-as-library -wmo -num-threads 8 \
  -I "$BUILD" -L "$BUILD" -lDSHAppLib -o "$BUILD/dsh-core-tests" \
  "$ROOT"/macos/DSHTests/DSHTestSupport.swift \
  "$ROOT"/macos/DSHTests/DSHCoreTimelineTests.swift \
  "$ROOT"/macos/DSHTests/CoreRunner/main.swift
DYLD_LIBRARY_PATH="$BUILD" "$BUILD/dsh-core-tests"
