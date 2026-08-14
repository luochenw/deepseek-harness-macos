# Agent Note: Build via direct `swiftc`, no Xcode/SwiftPM project

Status: implemented

## Problem

A native macOS app conventionally ships an `.xcodeproj` or SwiftPM
`Package.swift` as its build/test entry point. Either one requires a second,
hand-maintained list of source files (the Xcode project's file references, or
the package's target `sources`) that has to be kept in sync with the actual
`.swift` files on disk. In a repo edited primarily by an AI agent adding one
feature file at a time, that second list is exactly the kind of bookkeeping
that silently drifts — a new file compiles locally (if the editor happens to
add it) but is absent from CI/release builds, or vice versa.

## Decision

Production builds (`scripts/build-macos-app.sh`) and native tests
(`scripts/test-macos-native.sh`) both invoke `swiftc` directly against the
same glob, `macos/DSHApp/*.swift`:

- Build: `swiftc -parse-as-library "$ROOT"/macos/DSHApp/*.swift -o
  "$STAGE/Contents/MacOS/DSH" -framework AppKit -framework SwiftUI`
- Test: `swiftc -typecheck -parse-as-library "$ROOT"/macos/DSHApp/*.swift
  -framework AppKit -framework SwiftUI`

There is exactly one source-of-truth file list (the directory itself). Adding
a new `.swift` file under `macos/DSHApp/` makes it part of both the next
build and the next typecheck automatically, with no project file to edit.
`NativeContractCheck.swift` — a compile-time fixture that exercises the RPC
envelope, prompt, settings-patch, queue and attachment wire types — is
compiled as part of this same production source set rather than as a
separate XCTest target, so it can never drift from what actually ships.

## Alternatives considered

- **`.xcodeproj`**: standard, gets Xcode's UI/debugger/Instruments
  integration for free. Rejected because its file list is a second manifest
  that duplicates the filesystem and is edited through Xcode's project
  editor, not a plain diff — much harder for an agent to keep correct
  without opening Xcode, and any manual drift breaks silently until someone
  opens the project.
- **SwiftPM `Package.swift` + `XCTest` target**: `sources` can glob a
  directory in Swift 5.9+, which would avoid the same-manifest problem, and
  would give a standard `swift test` entry point. Rejected primarily because
  the production artifact is an app bundle with embedded Node + DSH runtime
  and a specific `Contents/` layout (see build script), which SwiftPM's
  executable-product model doesn't produce directly — the app-bundle
  assembly step (`ditto` the runtime, `codesign`, `Info.plist`) would still
  be a separate shell script either way, so SwiftPM would add a second build
  path without removing the shell script it was meant to unify with.
  Revisit if the project outgrows shell-script bundle assembly.

## Consequences

Gained: one file list, mechanically impossible to drift, zero Xcode-project
merge conflicts, and `NativeContractCheck.swift` guaranteed to compile
against exactly what ships. Cost: no Xcode debugger/breakpoint UI on the
production build target (an ad-hoc `.xcodeproj` can still be created locally
for debugging — it just isn't the build of record and isn't checked in), and
no `XCTest`/`swift test` runner — `test-macos-native.sh` is the test entry
point instead, and any future UI/XCUITest work (tracked in
[macos/WEB_PARITY.md](../../../../macos/WEB_PARITY.md)) will need its own
decision about how it fits this constraint.
