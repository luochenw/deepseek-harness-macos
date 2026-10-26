# Agent Note: Refresh the installed native app in place

Status: implemented - local Swift-only changes refresh the installed app without repackaging the embedded runtime

## Problem

The full build packages an 843 MB Node/DSH runtime and produces a replacement
app bundle. During local Swift UI iteration this forces the developer to move or
reinstall the app after every change even though the runtime is unchanged.

Replacing a Mach-O executable while its process is running is unsafe, and macOS
does not provide general-purpose hot reload for a signed SwiftUI app. A useful
local workflow can still avoid reinstalling by rebuilding only the native
executable, stopping the selected installed app, replacing that executable
atomically, signing the replacement, and relaunching.

## Decision

Add `scripts/refresh-macos-app.sh`:

- accept an installed app path, defaulting to
  `/Applications/DeepSeek Harness.app`;
- verify its embedded DSH runtime version matches
  `scripts/dsh-runtime-version.txt`;
- compile `macos/DSHApp/*.swift` to a temporary executable using the same
  minimum macOS deployment target as the full build;
- stop only processes belonging to the selected app;
- atomically replace `Contents/MacOS/DSH`, verify the staged native executable's
  signature, and relaunch;
- auto-select an installed Apple Development identity by default so the
  designated requirement remains stable for local TCC grants, while retaining
  `CODESIGN_IDENTITY=-` as an explicit ad-hoc fallback;
- keep complete-bundle re-signing behind `REFRESH_FULL_SIGN=1` because scanning
  the 843 MB Runtime takes minutes;
- leave the embedded runtime, user sessions, credentials, and app preferences
  untouched.

The full build remains mandatory when Node, DSH, runtime patches, licenses, or
other bundle resources change.

## Alternatives considered

- **Replace a running executable without restarting.** Rejected because the
  running process has already mapped the old binary and the Host child still
  uses bundle resources; this is not a safe update boundary.
- **Run only `dist/DeepSeek Harness.app` during development.** Rejected as the
  sole workflow because it does not update the installed app or its Dock/menu
  integration.
- **Adopt Sparkle for this local loop.** Rejected for now because Sparkle solves
  signed release distribution, not incremental source builds, and still
  requires an app relaunch.
- **Point the signed bundle at an external hot-swapped executable.** Rejected
  because it weakens bundle identity/signature semantics and risks incorrect
  `Bundle.main` resource resolution.

## Consequences

- Refreshing changes the installed native binary while preserving the embedded
  Runtime and application data.
- The measured fast refresh took 36.42 seconds without rebuilding or copying
  the 843 MB Runtime.
- The staged native executable verifies before installation, and the installed
  bytes are compared with that verified artifact.
- Runtime-version drift fails closed and directs the user to the full build.
- The selected app is relaunched automatically.
- Complete-bundle signing and strict verification remain available with
  `REFRESH_FULL_SIGN=1`; the measured full path took 160.92 seconds.

## Risks

- Stopping the app interrupts any active model run.
- The script refreshes native code only; it must never be used as a shortcut for
  runtime or bundle-resource changes.
- Fast mode intentionally leaves the surrounding app-bundle seal stale. It is
  suitable only for local development; release artifacts must use the full
  build and complete signing path.
- Without an Apple Development identity, the fallback remains ad-hoc and its
  cdhash-based designated requirement can cause macOS to request TCC approvals
  again after a rebuild.
