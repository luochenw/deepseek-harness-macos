# Sourced by the native gates. One testable build of the app sources, shared by
# every gate in a run: test-macos-native.sh builds it once and exports the
# directory, and a gate run on its own builds its own copy.
#
# Whole-module mode: file-by-file compilation re-parses every source once per
# file, which took about a minute against 15 seconds here.
dsh_test_library() {
  [[ -z "${DSH_TEST_LIBRARY_DIR:-}" ]] || return 0
  DSH_TEST_LIBRARY_DIR="$1"
  export DSH_TEST_LIBRARY_DIR
  # -D DEBUG keeps the probe counters and their switches settable. The shipping
  # build does NOT define it, so `DSHTranscriptPerf.isEnabled`/`forceRowFrames`
  # are `let false` there and nothing can turn measurement on in production.
  swiftc -target "$SWIFT_TARGET" -parse-as-library -D DEBUG -enable-testing -wmo -num-threads 8 \
    -emit-library -emit-module -module-name DSHAppLib \
    -o "$DSH_TEST_LIBRARY_DIR/libDSHAppLib.dylib" -module-link-name DSHAppLib \
    "$ROOT"/macos/DSHApp/*/*.swift -framework AppKit -framework SwiftUI -framework WebKit
}
