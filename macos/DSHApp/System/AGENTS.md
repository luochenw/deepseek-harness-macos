# System — agent rules
Scope: dock badge, system notifications and permission prompts, plus the diagnostic sink for swallowed AppKit exceptions. Does not change Host RPC and does not decide session or history state — it only consumes facts published by `HarnessController`.
Key files: `NativeAlerts.swift` (dock badge, notifications, permission prompts), `DSHExceptionDiagnostics.swift` (exception hook and log writer).
Invariants (each must cite a Note or test):
- `UNUserNotificationCenter` is touched only when a bundle identifier exists, otherwise the framework raises — source: `bug-fix/2026-10-28-voice-tap-nsexception-root-cause.md`.
- The "!" badge is recomputed from one source of truth; event handlers never write the state literal directly — source: `bug-fix/2026-10-27-dock-badge-replaces-menu-bar.md`.
- The exception hook attaches to the actual `NSApp` class with `class_addMethod`/`method_setImplementation`, never `method_exchangeImplementations` — source: `bug-fix/2026-10-28-voice-tap-nsexception-root-cause.md`.
- Diagnostics record at most one entry per second, rotate past 1MB and keep only the first 40 frames — source: `macos/DSHTests/DSHExceptionDiagnosticsTests.swift` ("ExceptionDiagnostics collapses records inside the interval").
- `Info.plist` must not contain `NSApplicationCrashOnExceptions` (AppKit reads that only from the defaults domain) — source: `bug-fix/2026-10-28-voice-tap-nsexception-root-cause.md`.
Before reporting done: `./scripts/test-macos-native.sh --unit` and `plutil -lint macos/DSHApp/Info.plist`.
Pitfalls:
- The menu-bar `NSStatusItem` was removed after a system crash; do not reintroduce it — source: `bug-fix/2026-10-27-dock-badge-replaces-menu-bar.md`.
- The exception log only sees exceptions that reach `reportException`; ones swallowed inside SwiftUI/AppKit never arrive — source: `bug-fix/2026-10-28-voice-tap-nsexception-root-cause.md`.
- Re-entrancy guards use a monotonic deadline instead of a `defer` reset, or an unwinding exception leaves the flag latched — source: `bug-fix/2026-10-28-voice-tap-nsexception-root-cause.md`.
- `voice-diag.log` still has no rotation and is 0644; only the exception log was hardened — source: `bug-fix/2026-10-28-voice-tap-nsexception-root-cause.md`.
