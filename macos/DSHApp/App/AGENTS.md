# App — agent rules
Scope: `@main` entry, the single `HarnessController` declaration, root view composition, sheet mounting, global Esc policy and the compile-time wire fixture. Not a home for feature logic: new `@Published` state, controller methods and top-level Views go to the owning domain directory instead.
Key files: `main.swift` (app entry + `HarnessController`), `ContentView.swift` (composition and `.sheet` mounting only), `DSHAppLifecycle.swift` (launch/terminate wiring), `DSHTaskEscapeMonitor.swift` (global Esc policy), `NativeContractCheck.swift` (compile-time RPC/prompt/settings/queue/attachment fixtures).
Invariants (each must cite a Note or test):
- `main.swift` keeps only the app entry, the `HarnessController` declaration, shared state and core lifecycle, capped at 489 lines — source: `architecture/2026-08-18-quality-remediation-plan.md`.
- Line counts use `awk 'END{print NR}'`, not `wc -l`, so a final line without a newline cannot undercount at the limit — source: `architecture/2026-08-18-quality-remediation-plan.md`.
- No session is created at launch; the first message creates it lazily — source: `feature/2026-08-17-lazy-first-session.md`.
- `ContentView` only composes and mounts `.sheet`s, with no business logic — source: `architecture/2026-08-15-native-main-window-redesign.md`.
- Shutdown stops the Host exactly once: the terminating owner is held strongly and the first install wins — source: `bug-fix/2026-10-27-dock-badge-replaces-menu-bar.md`.
- Launch completion is marked before attaching, never inferred from `NSApp.isRunning` — source: `bug-fix/2026-10-27-dock-badge-replaces-menu-bar.md`.
Before reporting done: `./scripts/test-macos-native.sh` (includes the `main.swift` line gate).
Pitfalls:
- `HarnessController()` cannot be instantiated outside a real app bundle; tests pass `startRuntime: false` — source: `architecture/2026-08-18-quality-remediation-plan.md`.
- New state/methods/top-level Views in `main.swift` are rejected by the gate, not merely discouraged — source: `scripts/test-macos-native.sh` (`MAIN_SWIFT_LINE_LIMIT`).
