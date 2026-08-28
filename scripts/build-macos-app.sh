#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/DeepSeek Harness.app"
STAGE="$ROOT/dist/.DeepSeek-Harness-stage-$RANDOM-$RANDOM.app"
MINIMUM_MACOS_VERSION="14.0"
SWIFT_TARGET="${SWIFT_TARGET:-$(uname -m)-apple-macos${MINIMUM_MACOS_VERSION}}"
BUILD_ARCH="${SWIFT_TARGET%%-*}"

# Auto-detected from the build machine's own toolchain; override with
# NODE_SOURCE / DSH_SOURCE env vars if yours live somewhere nonstandard.
NODE_SOURCE="${NODE_SOURCE:-$(command -v node || true)}"
DSH_SOURCE="${DSH_SOURCE:-$(npm root -g 2>/dev/null)/@deepseek-ai/dsh}"

[[ -n "$NODE_SOURCE" && -x "$NODE_SOURCE" ]] || {
  echo "Node runtime not found. Install Node.js, or set NODE_SOURCE to a node executable." >&2
  exit 1
}
[[ -f "$DSH_SOURCE/lib/bin.js" ]] || {
  echo "DSH runtime not found at: $DSH_SOURCE" >&2
  echo "Install it with: npm install -g @deepseek-ai/dsh@0.1.1-rc.2" >&2
  echo "...or set DSH_SOURCE to point at an existing @deepseek-ai/dsh package directory." >&2
  exit 1
}
NODE_EXECUTABLE="$("$NODE_SOURCE" -p 'process.execPath')"
NODE_VERSION="$("$NODE_SOURCE" -p 'process.versions.node')"
[[ -x "$NODE_EXECUTABLE" ]] || {
  echo "Resolved Node runtime is not executable: $NODE_EXECUTABLE" >&2
  exit 1
}
NODE_ARCHS="$(lipo -archs "$NODE_EXECUTABLE" 2>/dev/null || true)"
case " $NODE_ARCHS " in
  *" $BUILD_ARCH "*) ;;
  *)
    echo "Resolved Node runtime lacks the build architecture $BUILD_ARCH: $NODE_EXECUTABLE ($NODE_ARCHS)" >&2
    exit 1
    ;;
esac

# Two sessions can legitimately build in the same checkout around the same
# time (see CLAUDE.md's 多 Agent 并行) — without this lock, one run's cleanup
# sweep below could delete another run's in-progress stage dir, or its
# ".previous" backup mid-swap at the end. Waits rather than fails so both
# builds still complete; if a run is killed before its `trap` can fire, the
# stale "$ROOT/dist/.build.lock" it leaves behind is safe to `rmdir` by hand.
mkdir -p "$ROOT/dist"
LOCK_DIR="$ROOT/dist/.build.lock"
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
  echo "Another build is in progress (lock: $LOCK_DIR) — waiting..." >&2
  sleep 2
done
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

# Each run's STAGE dir has a fresh random suffix, so a run that gets killed or
# crashes mid-build leaves its stage dir (and a dangling "$APP.previous" from
# the swap below) behind forever — nothing else ever names it again to clean
# it up. Sweep those before staging a new build (safe now that the lock above
# rules out a concurrently running build owning one of these).
find "$ROOT/dist" -maxdepth 1 -name ".DeepSeek-Harness-stage-*.app" -exec rm -rf {} +
rm -rf "$APP.previous"

rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources/Runtime" "$STAGE/Contents/Resources/Licenses"
swiftc -target "$SWIFT_TARGET" -parse-as-library "$ROOT"/macos/DSHApp/*.swift \
  -o "$STAGE/Contents/MacOS/DSH" -framework AppKit -framework SwiftUI -framework WebKit
APP_MINOS="$(xcrun vtool -show-build "$STAGE/Contents/MacOS/DSH" | awk '/minos / { print $2; exit }')"
[[ "$APP_MINOS" == "$MINIMUM_MACOS_VERSION" ]] || {
  echo "Built app minimum macOS version is $APP_MINOS, expected $MINIMUM_MACOS_VERSION." >&2
  exit 1
}
cp "$ROOT/macos/DSHApp/Info.plist" "$STAGE/Contents/Info.plist"
cp "$ROOT/macos/DSHApp/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"
cp "$ROOT/LICENSE" "$STAGE/Contents/Resources/Licenses/DeepSeek-Harness-LICENSE"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$STAGE/Contents/Resources/Licenses/THIRD_PARTY_NOTICES.md"
node_license=""
for candidate in \
  "${NODE_LICENSE_SOURCE:-}" \
  "$(dirname "$NODE_EXECUTABLE")/../LICENSE" \
  "$(dirname "$NODE_EXECUTABLE")/../../LICENSE"; do
  if [[ -n "$candidate" && -f "$candidate" ]]; then
    node_license="$candidate"
    break
  fi
done
if [[ -n "$node_license" ]]; then
  cp "$node_license" "$STAGE/Contents/Resources/Licenses/Node.js-LICENSE"
else
  command -v curl >/dev/null || {
    echo "Node.js license not found beside $NODE_EXECUTABLE and curl is unavailable." >&2
    echo "Set NODE_LICENSE_SOURCE to the LICENSE file for Node.js $NODE_VERSION." >&2
    exit 1
  }
  curl -fsSL --retry 3 \
    "https://raw.githubusercontent.com/nodejs/node/v$NODE_VERSION/LICENSE" \
    -o "$STAGE/Contents/Resources/Licenses/Node.js-LICENSE"
fi
cp "$NODE_EXECUTABLE" "$STAGE/Contents/MacOS/node"
chmod 755 "$STAGE/Contents/MacOS/node"
# GitHub's hosted Node can be dynamically linked against a sibling
# `lib/libnode.*.dylib`; the app bundle cannot rely on that host path. Static
# Node distributions have no matches, so this stays a no-op for local builds.
NODE_LIB_DIR="$(cd "$(dirname "$NODE_EXECUTABLE")/../lib" 2>/dev/null && pwd || true)"
if [[ -n "$NODE_LIB_DIR" ]]; then
  shopt -s nullglob
  node_libraries=("$NODE_LIB_DIR"/libnode*.dylib)
  shopt -u nullglob
  if (( ${#node_libraries[@]} > 0 )); then
    mkdir -p "$STAGE/Contents/lib"
    for library in "${node_libraries[@]}"; do
      cp "$library" "$STAGE/Contents/lib/"
    done
  fi
fi
ditto "$DSH_SOURCE" "$STAGE/Contents/Resources/Runtime/dsh"

# sharp ships a platform libvips binary whose npm package omits the upstream
# license and notice files. Bundle the exact release texts plus the GNU
# GPL/LGPL terms they reference. The checked-in copies cover the currently
# supported local runtime; another package version is fetched from its tag.
RUNTIME_DSH="$STAGE/Contents/Resources/Runtime/dsh"
SHARP_LIBVIPS_MANIFEST="$(find "$RUNTIME_DSH/node_modules/@img" -maxdepth 2 -path '*/sharp-libvips-*/package.json' -print -quit 2>/dev/null || true)"
if [[ -n "$SHARP_LIBVIPS_MANIFEST" ]]; then
  SHARP_LIBVIPS_VERSION="$("$NODE_SOURCE" -e '
    const fs = require("node:fs");
    process.stdout.write(JSON.parse(fs.readFileSync(process.argv[1], "utf8")).version);
  ' "$SHARP_LIBVIPS_MANIFEST")"
  if [[ "$SHARP_LIBVIPS_VERSION" == "1.3.2" ]]; then
    cp "$ROOT/licenses/sharp-libvips-LICENSE" "$STAGE/Contents/Resources/Licenses/sharp-libvips-LICENSE"
    cp "$ROOT/licenses/sharp-libvips-THIRD-PARTY-NOTICES.md" "$STAGE/Contents/Resources/Licenses/sharp-libvips-THIRD-PARTY-NOTICES.md"
  else
    command -v curl >/dev/null || {
      echo "curl is required to fetch sharp-libvips $SHARP_LIBVIPS_VERSION license notices." >&2
      exit 1
    }
    curl -fsSL --retry 3 \
      "https://raw.githubusercontent.com/lovell/sharp-libvips/v$SHARP_LIBVIPS_VERSION/LICENSE" \
      -o "$STAGE/Contents/Resources/Licenses/sharp-libvips-LICENSE"
    curl -fsSL --retry 3 \
      "https://raw.githubusercontent.com/lovell/sharp-libvips/v$SHARP_LIBVIPS_VERSION/THIRD-PARTY-NOTICES.md" \
      -o "$STAGE/Contents/Resources/Licenses/sharp-libvips-THIRD-PARTY-NOTICES.md"
  fi
  curl -fsSL --retry 3 https://www.gnu.org/licenses/lgpl-3.0.txt \
    -o "$STAGE/Contents/Resources/Licenses/LGPL-3.0.txt"
  curl -fsSL --retry 3 https://www.gnu.org/licenses/gpl-3.0.txt \
    -o "$STAGE/Contents/Resources/Licenses/GPL-3.0.txt"
fi

# In-house cordis plugins (macos/Runtime-extras/<pkg>/) ride along inside the
# Runtime, one directory per package. They must also be declared in the
# Runtime's own package.json dependencies — healProfilesModuleFallback only
# symlinks packages inside that dependency closure into $DSH_HOME/profiles,
# so an out-of-tree package absent from it fails plain-name resolution from
# cordis.patch.yml even though the files are physically present.
# See .agents/notes/implemented/feature/2026-08-17-cross-session-relay.md.
extra_dests=()
shopt -s nullglob  # an empty (or missing) Runtime-extras/ must no-op, not fail the build on the literal glob
for extra in "$ROOT"/macos/Runtime-extras/*/; do
  extra="${extra%/}"
  read -r pkg_name pkg_version < <("$NODE_SOURCE" -e "
    const p = require('$extra/package.json');
    console.log(p.name + ' ' + p.version);
  ")
  dest="$RUNTIME_DSH/node_modules/$pkg_name"
  mkdir -p "$(dirname "$dest")"
  ditto "$extra" "$dest"
  # Relative to $STAGE/Contents/Resources — matches the manifest's own path
  # convention (see the hashing loop below), not the absolute $dest used for
  # the filesystem ops above.
  extra_dests+=("Runtime/dsh/node_modules/$pkg_name")
  "$NODE_SOURCE" -e "
    const fs = require('node:fs');
    const path = '$RUNTIME_DSH/package.json';
    const manifest = JSON.parse(fs.readFileSync(path, 'utf8'));
    manifest.dependencies['$pkg_name'] = '$pkg_version';
    fs.writeFileSync(path, JSON.stringify(manifest, null, 2) + '\n');
  "
done
shopt -u nullglob

# Native extensions need narrow, version-specific embedded-Runtime changes.
# The fail-closed patch supports rc.6, rc.7, and rc.2, mounts the Agent
# Platform plus model-facing workbench tools, and registers the platform's
# replayable projection event.
"$NODE_SOURCE" "$ROOT/scripts/patch-agent-platform-runtime.mjs" "$RUNTIME_DSH"

cd "$STAGE/Contents/Resources"
find Runtime -type f -not -path "*/node_modules/*" -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 > Runtime.manifest.sha256
find Runtime/dsh/node_modules -type l -print0 | LC_ALL=C sort -z | xargs -0 -I{} shasum -a 256 "{}" 2>/dev/null >> Runtime.manifest.sha256 || true
# The two passes above deliberately skip node_modules' real files (the
# upstream dependency tree, ~342MB, already vetted by its own npm install) —
# but that same exclusion also blinds the manifest to our own in-house
# plugins' real files, ditto'd in above as actual files, not symlinks. Hash
# those specifically so a corrupted/truncated in-house plugin still fails
# the integrity check below.
for rel_dest in "${extra_dests[@]}"; do
  find "$rel_dest" -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 >> Runtime.manifest.sha256
done
cd - >/dev/null
"$STAGE/Contents/MacOS/node" "$STAGE/Contents/Resources/Runtime/dsh/lib/bin.js" --version
( cd "$STAGE/Contents/Resources" && shasum -a 256 -c Runtime.manifest.sha256 >/dev/null )
codesign --force --deep --sign - "$STAGE"
if [[ -e "$APP" ]]; then mv "$APP" "$APP.previous" 2>/dev/null || true; fi
mv "$STAGE" "$APP"
rm -rf "$APP.previous" 2>/dev/null || true
echo "Built self-contained app: $APP"
echo "Runtime: $(du -sh "$APP/Contents/Resources/Runtime" | cut -f1)"
