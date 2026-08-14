# Agent Note: Menu bar presence + system notifications for approvals, questions, and turn completion

Status: implemented

## Problem

The product goal for this app beyond web parity is to add native capability
the browser-based DSH client structurally cannot have — not just catch up to
it. The architecture sweep
([Swift architecture report](../architecture/2026-08-14-no-xcode-project.md)-adjacent
research; see the plugin/HMR findings) concluded that DSH's own runtime
extension points (`cordis-plugin-hmr`, `dynamicCordisRunner`) are either
dev-only or require a browser page to host their Client-half — this app
deliberately never embeds a WebView, so neither is a real integration
surface today. Meanwhile, the app already models exactly the moments a user
most wants to know about while *not* looking at the window:
`pendingApproval` (a tool needs explicit permission), `pendingQuestion` (the
agent is blocked waiting on an answer), and turn completion — and today all
three are silent unless the app is frontmost. A long-running task that
finishes, or blocks on a question, while the user is in another app gives no
signal at all.

## Decision

Added `NativeAlerts` (`NativeAlerts.swift`), a small `@MainActor` class
`HarnessController` owns and calls into at the three existing state-change
sites — no new Host protocol surface, purely a native-side reaction to state
this app already tracks:

- An `NSStatusItem` (menu bar icon) is created once, on `HarnessController`
  init, via `nativeAlerts.attach(to: self)`. Its symbol/tint reflects the
  current state (idle → `sparkles`, running → filled circle tinted blue,
  needs-attention → exclamation circle tinted orange) and its menu offers
  "打开 DeepSeek Harness" (activate + front the window) and "退出". This
  gives the app a persistent, glanceable presence and a fast way back in
  even when the main window is closed or behind other apps — something a
  browser tab cannot offer.
- `UNUserNotificationCenter` local notifications fire for
  `pendingApproval`/`pendingQuestion` being set (`consumeMuxFrame`'s
  `approval/requested` / `question/requested` cases) and for top-level
  `turn/end` (`applyLiveEvent`), each gated on `NSApp.isActive == false` so
  a foregrounded app doesn't double-announce what's already visible on
  screen. Clicking a notification activates the app
  (`UNUserNotificationCenterDelegate.didReceive`) — the relevant sheet is
  already showing itself via the existing `.sheet(item:)` bindings, so no
  extra routing logic was needed. Approval/question notifications also call
  `NSApp.requestUserAttention(.informationalRequest)` to bounce the Dock
  icon, matching how other native macOS apps request attention.
- Scope: only **top-level session** turn completion notifies, not every
  subagent's. Subagent completions are comparatively frequent/nested and a
  notification per child agent would be noisy; the top-level "your task
  finished" moment is the one users actually want to be pulled back for.

Supporting change: `Info.plist`'s `CFBundleIdentifier` moved from
`ai.deepseek.dsh.native` to `com.github.deepseek-harness-macos.app`. The
`ai.deepseek.*` reverse-DNS namespace belongs to DeepSeek; this project is
an independent, unofficial client (see `LICENSE`), and claiming a
subdomain of DeepSeek's own namespace for local notification/status-item
registration was incorrect regardless of feature work. Local
`UNUserNotificationCenter` authorization/registration is also tied to
`CFBundleIdentifier`, so this had to change together with adding
notifications rather than as an unrelated follow-up.

## Alternatives considered

- **A persistent in-window banner instead of system notifications.**
  Rejected as the primary mechanism — it only helps if the window is
  visible, which is exactly the case that doesn't need help. Kept the
  existing in-window `runNotice`/`retryNotice` banners as-is for the
  foregrounded case; notifications are additive for the backgrounded case.
- **Dock badge count (e.g. number of pending approvals) instead of/in
  addition to a menu bar item.** Deferred — a menu bar item was chosen
  first because it can show live running/idle/needs-attention state via
  tint, not just a count, and doesn't require the Dock icon (which some
  users hide). A badge count can be layered on later without conflicting
  with this decision.
- **Route notification clicks to open the specific sheet/session, not just
  activate the app.** Not needed: `pendingApproval`/`pendingQuestion` are
  still set when the notification is clicked (nothing clears them), so the
  existing `.sheet(item:)` bindings already present the right UI the
  instant the app activates. Turn-completion notifications have no sheet to
  route to. Revisit only if a future notification type needs to jump to a
  specific session that isn't already the selected one.

## Consequences

The app now has a menu bar presence and notifies the user for the three
moments that actually need their attention while away from the window,
using only state the app already maintains — no new Host RPC surface. Local
notification permission is requested once at first launch (standard macOS
system prompt); a user who denies it simply gets no notifications, the menu
bar item and in-app banners are unaffected. The bundle identifier change is
a one-time, low-risk rename (no persisted data keys off `CFBundleIdentifier`
in this app — `UserDefaults.standard` keys used here are app-name-scoped by
the OS via the running process, and `~/Library/Application Support/DeepSeek
Harness/dsh` is a hardcoded path in `main.swift`, not derived from the
bundle ID) but is worth flagging for anyone who built and ran the app before
this change: macOS treats it as a different app for notification permission
and Login Items purposes going forward.
