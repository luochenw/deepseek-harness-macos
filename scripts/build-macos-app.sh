#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/DeepSeek Harness.app"
STAGE="$ROOT/dist/.DeepSeek-Harness-stage-$RANDOM-$RANDOM.app"

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
  echo "Install it with: npm install -g @deepseek-ai/dsh" >&2
  echo "...or set DSH_SOURCE to point at an existing @deepseek-ai/dsh package directory." >&2
  exit 1
}

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
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources/Runtime"
swiftc -parse-as-library "$ROOT"/macos/DSHApp/*.swift -o "$STAGE/Contents/MacOS/DSH" -framework AppKit -framework SwiftUI
cp "$ROOT/macos/DSHApp/Info.plist" "$STAGE/Contents/Info.plist"
cp "$ROOT/macos/DSHApp/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"
cp "$NODE_SOURCE" "$STAGE/Contents/MacOS/node"
chmod 755 "$STAGE/Contents/MacOS/node"
ditto "$DSH_SOURCE" "$STAGE/Contents/Resources/Runtime/dsh"

# In-house cordis plugins (macos/Runtime-extras/<pkg>/) ride along inside the
# Runtime, one directory per package. They must also be declared in the
# Runtime's own package.json dependencies — healProfilesModuleFallback only
# symlinks packages inside that dependency closure into $DSH_HOME/profiles,
# so an out-of-tree package absent from it fails plain-name resolution from
# cordis.patch.yml even though the files are physically present.
# See .agents/notes/proposed/feature/2026-08-17-cross-session-relay.md.
RUNTIME_DSH="$STAGE/Contents/Resources/Runtime/dsh"
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
