#!/bin/bash
# Sign Node plus every native addon explicitly. `codesign --deep` can leave
# npm's linker-signed `.node` files with an incompatible signature, causing
# dlopen failures under macOS library validation.
set -euo pipefail

APP="${1%/}"
IDENTITY="${2:-}"

[[ -n "$APP" && -n "$IDENTITY" ]] || {
  echo "usage: $0 APP_PATH SIGNING_IDENTITY" >&2
  exit 64
}

NODE="$APP/Contents/MacOS/node"
RUNTIME="$APP/Contents/Resources/Runtime"
[[ -x "$NODE" ]] || { echo "missing embedded Node: $NODE" >&2; exit 1; }
[[ -d "$RUNTIME" ]] || { echo "missing embedded Runtime: $RUNTIME" >&2; exit 1; }

ARGS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" == "-" ]]; then
  ARGS+=(--timestamp=none)
else
  ARGS+=(--timestamp)
fi

codesign "${ARGS[@]}" "$NODE" >/dev/null
codesign --verify --strict "$NODE"
count=0
while IFS= read -r -d '' module; do
  file -b "$module" | grep -q 'Mach-O' || continue
  codesign "${ARGS[@]}" "$module" >/dev/null
  codesign --verify --strict "$module"
  if codesign -dvv "$module" 2>&1 | grep -q 'linker-signed'; then
    echo "native module remains linker-signed: $module" >&2
    exit 1
  fi
  count=$((count + 1))
done < <(find "$RUNTIME" -type f -name '*.node' -print0)

echo "signed embedded Node and $count native module(s)"
