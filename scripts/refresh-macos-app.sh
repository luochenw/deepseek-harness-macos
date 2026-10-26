#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-/Applications/DeepSeek Harness.app}"
APP="${APP%/}"
MINIMUM_MACOS_VERSION="14.0"
SWIFT_TARGET="${SWIFT_TARGET:-$(uname -m)-apple-macos${MINIMUM_MACOS_VERSION}}"
FULL_SIGN="${REFRESH_FULL_SIGN:-0}"
SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"

die() {
  echo "refresh-macos-app: $*" >&2
  exit 1
}

[[ $# -le 1 ]] || die "usage: $0 [APP_PATH]"
[[ "$FULL_SIGN" == "0" || "$FULL_SIGN" == "1" ]] \
  || die "REFRESH_FULL_SIGN must be 0 or 1"
[[ -d "$APP" ]] || die "installed app not found: $APP"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist" 2>/dev/null || true)"
[[ "$BUNDLE_ID" == "com.github.deepseek-harness-macos.app" ]] \
  || die "not a DeepSeek Harness app: $APP"
[[ -x "$APP/Contents/MacOS/DSH" ]] || die "native executable is missing"
[[ -x "$APP/Contents/MacOS/node" ]] || die "embedded Node executable is missing"
[[ -f "$APP/Contents/Resources/Runtime/dsh/package.json" ]] \
  || die "embedded DSH runtime is missing"

EXPECTED_DSH_VERSION="$(tr -d '[:space:]' < "$ROOT/scripts/dsh-runtime-version.txt")"
INSTALLED_DSH_VERSION="$("$APP/Contents/MacOS/node" -e '
  const fs = require("node:fs");
  const p = process.argv[1];
  process.stdout.write(JSON.parse(fs.readFileSync(p, "utf8")).version);
' "$APP/Contents/Resources/Runtime/dsh/package.json")"
[[ "$INSTALLED_DSH_VERSION" == "$EXPECTED_DSH_VERSION" ]] || {
  die "embedded DSH runtime is $INSTALLED_DSH_VERSION, expected $EXPECTED_DSH_VERSION; run ./scripts/build-macos-app.sh and replace the app"
}

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/^ *[0-9]*) \([0-9A-F]*\) "Apple Development:.*/\1/p' \
    | head -n 1)"
  SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "No Apple Development identity selected; TCC may ask for voice permissions again after refreshes." >&2
else
  echo "Using stable Apple Development signing identity: $SIGN_IDENTITY"
fi

mkdir -p "$ROOT/dist"
WORK="$(mktemp -d "$ROOT/dist/.native-refresh.XXXXXX")"
cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "Compiling native executable for $SWIFT_TARGET..."
swiftc -target "$SWIFT_TARGET" -parse-as-library "$ROOT"/macos/DSHApp/*.swift \
  -o "$WORK/DSH" -framework AppKit -framework SwiftUI -framework WebKit

APP_MINOS="$(xcrun vtool -show-build "$WORK/DSH" | awk '/minos / { print $2; exit }')"
[[ "$APP_MINOS" == "$MINIMUM_MACOS_VERSION" ]] || {
  die "built app minimum macOS version is $APP_MINOS, expected $MINIMUM_MACOS_VERSION"
}
codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$WORK/DSH"
codesign --verify --strict "$WORK/DSH"

APP_PIDS=()
APP_COPY_PATHS=()
while IFS= read -r line; do
  pid="${line%% *}"
  command="${line#"$pid"}"
  command="${command# }"
  [[ "$pid" == "$$" ]] && continue
  candidate_app=""
  if [[ "$command" == *"/Contents/MacOS/DSH" ]]; then
    candidate_app="${command%/Contents/MacOS/DSH}"
  elif [[ "$command" == *"/Contents/MacOS/node "* ]]; then
    candidate_app="${command%%/Contents/MacOS/node *}"
  fi
  [[ -n "$candidate_app" ]] || continue
  candidate_bundle="$(plutil -extract CFBundleIdentifier raw \
    "$candidate_app/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$candidate_bundle" == "$BUNDLE_ID" ]]; then
    APP_PIDS+=("$pid")
    APP_COPY_PATHS+=("$candidate_app")
  fi
done < <(ps -axo pid=,command=)

if (( ${#APP_PIDS[@]} > 0 )); then
  printf 'Stopping running DeepSeek Harness app copies:\n'
  printf '  %s\n' "${APP_COPY_PATHS[@]}" | sort -u
  kill -TERM "${APP_PIDS[@]}" 2>/dev/null || true
  for _ in $(seq 1 100); do
    alive=()
    for pid in "${APP_PIDS[@]}"; do
      kill -0 "$pid" 2>/dev/null && alive+=("$pid")
    done
    (( ${#alive[@]} == 0 )) && break
    sleep 0.1
  done
  if (( ${#alive[@]} > 0 )); then
    kill -KILL "${alive[@]}" 2>/dev/null || true
    sleep 0.2
  fi
fi

BIN_DIR="$APP/Contents/MacOS"
PREVIOUS="$WORK/DSH.previous"
STAGED="$BIN_DIR/.DSH.refresh.$$"
cp "$APP/Contents/MacOS/DSH" "$PREVIOUS"
cp "$WORK/DSH" "$STAGED"
chmod 755 "$STAGED"

echo "Replacing native executable..."
mv -f "$BIN_DIR/DSH" "$WORK/DSH.replaced"
mv "$STAGED" "$BIN_DIR/DSH"

restore_previous() {
  mv -f "$BIN_DIR/DSH" "$WORK/DSH.failed"
  cp "$PREVIOUS" "$BIN_DIR/DSH"
  codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" \
    "$BIN_DIR/DSH" >/dev/null 2>&1 || true
}

if [[ "$FULL_SIGN" == "1" ]]; then
  echo "Re-signing the complete app bundle..."
  if ! "$ROOT/scripts/sign-runtime-native-code.sh" "$APP" "$SIGN_IDENTITY"; then
    restore_previous
    die "runtime native-code signing failed; restored the previous executable"
  fi
  if ! codesign --force --sign "$SIGN_IDENTITY" "$APP"; then
    restore_previous
    die "bundle signing failed; restored the previous executable"
  fi
  if ! codesign --verify --deep --strict "$APP"; then
    restore_previous
    die "bundle signature verification failed; restored the previous executable"
  fi
else
  echo "Using fast local signing (complete bundle seal is not refreshed)."
  if ! cmp -s "$WORK/DSH" "$BIN_DIR/DSH"; then
    restore_previous
    die "installed native executable does not match the verified build; restored the previous executable"
  fi
fi

plutil -lint "$APP/Contents/Info.plist" >/dev/null
echo "Refreshed native executable:"
echo "  app:     $APP"
echo "  runtime: $INSTALLED_DSH_VERSION (unchanged)"
echo "  signing: $([[ "$FULL_SIGN" == "1" ]] && echo bundle || echo native-fast)"
echo "  identity: $SIGN_IDENTITY"
echo "  sha256:  $(shasum -a 256 "$BIN_DIR/DSH" | awk '{print $1}')"

if [[ "${REFRESH_NO_LAUNCH:-0}" != "1" ]]; then
  echo "Launching app..."
  open "$APP"
fi
