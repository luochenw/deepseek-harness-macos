# Agent Note: Replace the menu-bar status item with a Dock badge

Status: implemented — the NSStatusItem is gone; attention/running state is shown on the Dock icon

## Problem

On macOS 27 beta the app crashed repeatedly (four times in one morning) with
`EXC_BAD_ACCESS` at `0x7c8` inside `swift_task_isCurrentExecutor` →
`isMainExecutor`. 7 of 13 collected crash reports went through
`MenuBarClientCore`; the rest through SwiftUI's
`CoreInteractionRepresentableEffect` / `MainActor.assumeIsolated`. The system
framework calls `MainActor.assumeIsolated` after the runtime's cached main
executor reference has gone stale, so app code cannot fix the check itself.
Every crash also orphaned the bundled Host, which kept holding session writer
locks.

A second, independent defect: `stopForTermination()` was only reachable from a
view-level `.onReceive(willTerminateNotification)`. Quitting after the last
window was closed skipped it, so the Host was never stopped.

## Decision

- `NativeAlerts` no longer creates an `NSStatusItem`. The "打开 DeepSeek
  Harness / 退出" menu is removed with it.
- The Dock tile carries the state (`DSHDockBadge`): `"!"` while **any** session
  has an unanswered approval or question, `"•"` while a foreground turn or a
  background voice session runs, `nil` when idle. `"!"` is derived from one
  source of truth (`DSHBadgeFactsSource`, implemented by `HarnessController`):
  turn ends, voice completions and resolutions only ask for a recompute, never
  write a literal state. Writes are coalesced and deduplicated; attention is
  written immediately.
- `DSHAppDelegate` (via `@NSApplicationDelegateAdaptor`) owns launch, reopen
  and quit:
  - `applicationDidFinishLaunching` marks launch before attaching the badge, so
    attach timing is never inferred from `NSApp.isRunning`;
  - `applicationShouldHandleReopen` brings a hidden or minimised main window
    forward, or lets `WindowGroup` build a new one; this replaces the removed
    menu's way back after the last window is closed;
  - `applicationWillTerminate` calls `stopForTermination()`, which is one-shot
    (`claimTermination`) and returns whether it ran. The termination owner is
    held strongly and the first owner wins.
- System notifications and `requestUserAttention` are unchanged.

## Alternatives considered

- **Keep the status item and wait for Apple**: the crash is in a beta system
  framework path we hit on every launch-time interaction; the user chose not to
  file a report and to remove the trigger instead.
- **`SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE` / compiler flags /
  deployment-target changes**: investigated (read-only) and ruled out; the
  failing check runs inside system frameworks, which ignore the app's build
  settings, and the environment override did not change the crashing path.
- **Defer status-item creation until after launch**: still runs
  `MenuBarClientCore` on the main executor; it only moves the crash.
- **Write `"!"` directly at each notification point** (the previous scheme):
  a finished turn in session B cleared session A's pending approval, and a
  finished voice task left `"!"` stuck. A recompute from shared facts fixes both.

## Consequences

- No menu-bar presence. The Dock icon is the at-a-glance signal, and Dock
  reopen is the way back after closing the window.
- Quitting from the Dock, with ⌘Q, or on logout stops the Host exactly once,
  even with no window open.
- SwiftUI's `CoreInteractionRepresentableEffect` crash path is not addressed
  here; if it recurs it needs its own investigation.
- Not verified on device yet:
  - Dock reopen when no window exists;
  - a notification click after the last window was closed. `handleReopen` only
    activates an existing window there; creating a new one from that path is a
    follow-up.
- Supersedes the menu-bar half of
  [2026-08-14-native-menu-bar-and-notifications](../feature/2026-08-14-native-menu-bar-and-notifications.md).
  Tests: `macos/DSHTests/DSHMenuBarTests.swift`.
