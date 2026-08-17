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

rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources/Runtime"
swiftc -parse-as-library "$ROOT"/macos/DSHApp/*.swift -o "$STAGE/Contents/MacOS/DSH" -framework AppKit -framework SwiftUI
cp "$ROOT/macos/DSHApp/Info.plist" "$STAGE/Contents/Info.plist"
cp "$ROOT/macos/DSHApp/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"
cp "$NODE_SOURCE" "$STAGE/Contents/MacOS/node"
chmod 755 "$STAGE/Contents/MacOS/node"
ditto "$DSH_SOURCE" "$STAGE/Contents/Resources/Runtime/dsh"
cd "$STAGE/Contents/Resources"
find Runtime -type f -not -path "*/node_modules/*" -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 > Runtime.manifest.sha256
find Runtime/dsh/node_modules -type l -print0 | LC_ALL=C sort -z | xargs -0 -I{} shasum -a 256 "{}" 2>/dev/null >> Runtime.manifest.sha256 || true
cd - >/dev/null
"$STAGE/Contents/MacOS/node" "$STAGE/Contents/Resources/Runtime/dsh/lib/bin.js" --version
( cd "$STAGE/Contents/Resources" && shasum -a 256 -c Runtime.manifest.sha256 >/dev/null )
codesign --force --deep --sign - "$STAGE"
if [[ -e "$APP" ]]; then mv "$APP" "$APP.previous" 2>/dev/null || true; fi
mv "$STAGE" "$APP"
rm -rf "$APP.previous" 2>/dev/null || true
echo "Built self-contained app: $APP"
echo "Runtime: $(du -sh "$APP/Contents/Resources/Runtime" | cut -f1)"
