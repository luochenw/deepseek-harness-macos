#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT_TARGET="${SWIFT_TARGET:-$(uname -m)-apple-macos14.0}"
VIEW="$ROOT/macos/DSHApp/Transcript/ConversationView.swift"
STREAMING="$ROOT/macos/DSHApp/Transcript/StreamingAssistantText.swift"
COMPOSER="$ROOT/macos/DSHApp/Composer/ComposerView.swift"
FIXTURE="$ROOT/scripts/fixtures/reasoning-snapshot-check.swift"
BUILD="$(mktemp -d)"
SNAPSHOT_DIR="${REASONING_SNAPSHOT_DIR:-${TMPDIR:-/tmp}/dsh-reasoning-snapshots}"
trap "rm -rf $BUILD" EXIT

# One thinking row per turn: the fold must aggregate a turn's step traces
# instead of replaying one row per step, and row identity must be
# type-prefixed so the answer body is not dropped as a duplicate ForEach id.
grep -q 'turnTrace' "$VIEW" || {
  echo "reasoning-ui: transcript no longer aggregates step traces per turn" >&2
  exit 1
}
grep -q 'reasoning-' "$VIEW" || {
  echo "reasoning-ui: reasoning rows must carry a type-prefixed identity" >&2
  exit 1
}
# The 「N 段」 label is gone (the collapsed row is a bare status line), so the
# old guard would pass vacuously. Assert the row really shows no segment count
# in any form, and that the dead `segments` bookkeeping stays gone.
if grep -Eq 'segments.*段|段.*segments' "$VIEW"; then
  echo "reasoning-ui: collapsed reasoning status must not expose segment counts" >&2
  exit 1
fi
if grep -q 'value: pulse' "$VIEW" \
  || grep -q 'repeatForever' "$STREAMING"; then
  echo "reasoning-ui: completed rows must not retain repeating motion" >&2
  exit 1
fi
grep -q 'harness.displayedIsRunning' "$VIEW" || {
  echo "reasoning-ui: streaming text must be gated by the active turn state" >&2
  exit 1
}
grep -q 'enum DSHConversationLayout' "$VIEW" || {
  echo "reasoning-ui: shared conversation layout is missing" >&2
  exit 1
}
grep -q 'DSHConversationLayout.contentMaxWidth' "$VIEW" \
  && grep -q 'DSHConversationLayout.contentMaxWidth' "$COMPOSER" || {
  echo "reasoning-ui: transcript and composer no longer share one reading measure" >&2
  exit 1
}
grep -q 'DSHConversationLayout.horizontalInset' "$VIEW" \
  && grep -q 'DSHConversationLayout.horizontalInset' "$COMPOSER" || {
  echo "reasoning-ui: transcript and composer no longer share one horizontal inset" >&2
  exit 1
}

rm -rf "$SNAPSHOT_DIR"
swiftc -target "$SWIFT_TARGET" -parse-as-library -enable-testing -emit-library -emit-module -module-name DSHAppLib \
  -o "$BUILD/libDSHAppLib.dylib" -module-link-name DSHAppLib \
  "$ROOT"/macos/DSHApp/*/*.swift -framework AppKit -framework SwiftUI -framework WebKit
swiftc -target "$SWIFT_TARGET" -parse-as-library -I "$BUILD" -L "$BUILD" -lDSHAppLib \
  -o "$BUILD/reasoning-snapshot-check" \
  "$FIXTURE" -framework AppKit -framework SwiftUI -framework WebKit
DYLD_LIBRARY_PATH="$BUILD" "$BUILD/reasoning-snapshot-check" "$SNAPSHOT_DIR"

for name in reasoning-wide.png reasoning-narrow.png; do
  [[ -s "$SNAPSHOT_DIR/$name" ]] || {
    echo "reasoning-ui: missing snapshot $name" >&2
    exit 1
  }
done

echo "reasoning-ui: OK"
