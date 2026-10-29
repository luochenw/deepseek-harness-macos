# AGENTS.md — Architecture & Style Reference

This file is the code-style and architecture reference for `deepseek-harness-macos`. The workflow contract (how to plan, verify, and ship a change) is in [CLAUDE.md](CLAUDE.md), which points back here for "how this codebase is built" questions.

## What this is

A SwiftUI/AppKit **native** macOS client for [DSH](https://github.com/deepseek-ai/deepseek-harness) (DeepSeek Harness), an open-source agent coding harness. It is not a WebView wrapper: the bundled DSH Host runs as a local process, and the native UI drives it entirely over its documented loopback RPC + WebSocket protocol. See [README.md](README.md) for the product description and [macos/WEB_PARITY.md](macos/WEB_PARITY.md) for the living gap list against the web client this app tracks parity with.

## Repository layout

```
macos/DSHApp/       Swift sources, one directory per feature domain — no Xcode
                    project (see below). Only Info.plist and AppIcon.icns sit at
                    this level; a *.swift here fails the layout gate.
  App/                @main entry, the one HarnessController, ContentView,
                      lifecycle, global Esc policy, NativeContractCheck (fixture)
  Host/               RPC envelope + DSHHostClient, event sockets, Host runtime
                      and supervision, history/paging, external-agent bridge
  Transcript/         Message rendering: rows, scroll anchoring, tool cards,
                      Markdown text, attachment preview
  Composer/           Draft input, attachments, queue, submit policy, slash panel
  Sessions/           Session CRUD/fork/archive, permissions, dashboard, sheets
  Sidebar/            Project-grouped session list and Host status line
  Workspace/          Workspace prefs/cwd resolution, git ops, workspace chips
  Settings/           Settings window, revisioned writes, providers, credentials
  Voice/              Speech engine, dictation routing, floating bubble
  Workbench/          Per-session tab dock, browser and document panes
  AgentPlatform/      Agent Profile/Batch/Run models, policy, execution UI
  Subagents/          Subagent catalogue, child projection, tree traversal
  Design/             DSHTheme tokens and brand artwork constants
  System/             Dock badge, notifications, AppKit exception diagnostics
  AGENTS.md / CLAUDE.md (per domain)   That domain's rules and invariants;
                      Claude reads them through the one-line CLAUDE.md
scripts/             build-macos-app.sh, test-macos-native.sh, verify-native-host-api.sh,
                     ds-agent (send a task to the running App's DSH Host, or headless)
docs/driving-dsh-from-agents.md   How another model delegates work to the local
                     DSH/DeepSeek and supervises it (brief, monitor, accept)
.agents/notes/       Agent Notes — decision records; see CLAUDE.md
dist/                Build output (git-ignored, produced locally)
```

Each domain directory carries its own `AGENTS.md` (scope, key files, invariants
with sources, checks to run, pitfalls) and a one-line `CLAUDE.md` containing
`@AGENTS.md`, so an agent editing a file there reads the rules for just that
domain. `./scripts/test-macos-native.sh` enforces the shape: no `.swift` at the
`macos/DSHApp/` root, and every directory holding sources has both files with
`AGENTS.md` at 60 lines or less. Add a new feature domain by creating the
directory plus those two files — the build glob picks the sources up.

## Deliberately no Xcode / SwiftPM project

Production builds compile `macos/DSHApp/*/*.swift` directly with `swiftc`
(`scripts/build-macos-app.sh`), and `scripts/test-macos-native.sh` type-checks
the exact same glob. There is intentionally no second target list (`.xcodeproj`
or `Package.swift`) to keep in sync — see
[`.agents/notes/implemented/architecture/2026-08-14-no-xcode-project.md`](.agents/notes/implemented/architecture/2026-08-14-no-xcode-project.md).
If you add a new `.swift` file, it is picked up automatically by both scripts;
you do not need to register it anywhere.

## State management pattern

There is **one** `@MainActor final class HarnessController: ObservableObject`
(defined in `main.swift`) that owns essentially all app state as `@Published`
properties and all business logic as methods. `main.swift` is **frozen**: it
keeps only App entry, shared state declarations, initialization, and core
lifecycle (see the Agent Note linked from CLAUDE.md) and takes no new `@Published`
state, no new controller methods, and no new top-level View structs (see
CLAUDE.md's "质量规范" — `./scripts/test-macos-native.sh` enforces this as a
line-count gate, not just a convention). All *new* feature-specific logic is
added via `extension HarnessController { ... }` in a dedicated
`DSH<Feature>.swift` file — e.g. settings mutation lives in
`DSHSettingsMutate.swift` / `DSHSettingsActions.swift`; session, history,
subagent, goal, model, settings, send, and Host event actions live in their
corresponding extension files. SwiftUI views read state via
`@EnvironmentObject private var harness: HarnessController` and never hold
their own copy of Host-derived state.

When adding a feature:
1. New wire types (`Encodable`/`Decodable` structs mirroring a Host RPC
   method's payload/result) go in a `DSH<Feature>.swift` file, following the
   existing `DSH`-prefixed naming (`DSHSubagentEntry`, `DSHWorkspaceView`, …).
2. New `DSHHostClient` methods go in `DSHHostClientExtensions.swift` (or
   `DSHHostProtocol.swift` if they're core session/workspace surface).
3. New `@Published` state and controller methods go in an
   `extension HarnessController` in the matching `DSH<Feature>.swift` file
   (create one if the domain doesn't have one yet). Never inline them in
   `main.swift`, even for "core" flows — that door is closed by the freeze.
4. New views go in their own `<Feature>View.swift`.

## RPC & event protocol

- `DSHHostClient` is an `actor`. Every RPC call goes through the single
  generic `call<Payload, Value>(_:payload:as:)`, which POSTs a
  `DSHRPCEnvelope` (`{type: "client-request", rpcId, method, payload}`) to
  `api/<method>` on the bundled Host and decodes a `DSHRPCServerResponse`.
  Add new calls as small typed wrapper methods (see any existing method in
  `DSHHostProtocol.swift`) — never call `.call(...)` directly from a View or
  from `HarnessController` business logic.
- Two long-lived `DSHEventSocket` connections carry push events:
  `api/events.host` (workspace/session lifecycle — `consumeHostFrame`) and
  `api/events.mux` (per-turn streaming — `consumeMuxFrame` →
  `applyLiveEvent` for the `session/event` case). When you add a new mux
  event `type`/`kind`, add a `case` in the matching `switch` rather than a
  new dispatch mechanism.
- Every `DSHHostClient` call site follows the same shape: `Task { do { ...
  await MainActor.run { self.<published state> = ... } } catch { await
  MainActor.run { self.appendSystem(/self.status =/) "...失败：
  \(error.localizedDescription)" } } }`. Match it for new calls — don't
  introduce a different error-surfacing convention.

## Style notes

- UI-facing strings (labels, status messages, menu items) are **Chinese**;
  identifiers, types, and comments are **English**. Keep new UI copy in
  Chinese to match.
- Small handler functions are written as dense one-liners (see `main.swift`
  credential/settings methods) — this is the established style for short
  Task-wrapped RPC calls, not a one-off. Multi-branch view bodies
  (`SettingsView.settingsBody`, `ContentView`) are similarly compact
  `@ViewBuilder`/`switch` expressions rather than broken into many small
  subviews. Don't restyle existing code to a more verbose convention while
  touching it for an unrelated change.
- `guard let ... else { return }` early exits over nested `if let`.
- No force-unwraps (`!`) outside of values that are structurally guaranteed
  (e.g. `Bundle.main.resourceURL!`); prefer `guard let` / `??`.

## Rules for code changes (every agent, every change)

Reviewers check every rule below; a violation is a blocker. They come from
review findings on agent-written changes in this repo, plus widely used agent
rule sets (Karpathy-style "simplicity first / surgical changes", AGENTS.md
boundary tiers).

**Before coding**
- **Evidence first.** For a bug, reproduce it before changing code: a failing
  test, a log line, a crash-report fact. A suspect named in the task is a
  hypothesis to test, not a conclusion. If the request is ambiguous, state the
  reading you chose in your report.

**While coding**
- **Simplicity first.** Write the minimum code that solves the task. No
  speculative options, no one-use abstractions, no handling for impossible
  cases.
- **Surgical.** Every changed line traces back to the task. Don't reformat
  or "improve" neighbouring code; list unrelated problems in the report.
- **Delete before you add.** When you replace logic, remove the old path and
  anything your change orphaned. No parallel versions (`Foo2`, `legacyFoo`)
  and no second copy of a table.
- **No debug leftovers** in production code: probes, override flags,
  `print`, `/tmp` writes. Test hooks live in `macos/DSHTests` or behind
  `#if DEBUG`.
- **Comments match the file.** Most files here are under 10% comment lines.
  A comment says *why*, once. No session narratives, no local paths.
- **No machine-specific data** in sources, tests or fixtures: no
  `/Users/<name>`, ports, tokens, emails or agent prompts. Sanitize to
  `/Users/developer` and `127.0.0.1:0000`.
- **Concurrency.** UI state lives on `@MainActor`. Prefer `Task`/`async`
  over new `DispatchQueue.main` hops. No `@unchecked Sendable` or
  `nonisolated(unsafe)` without a written reason. Guard AppKit and
  AVFoundation calls that can raise ObjC exceptions (`installTap`,
  `inputNode`, window/panel ops, KVC) *before* the call: an exception that
  unwinds through a main-actor job corrupts the Swift runtime and crashes the
  app later, somewhere unrelated.
- **Defensive code must not crash.** Never call `Int(_:)` on a `Double`
  that may be NaN, ∞ or huge. No force casts or force unwraps. Check empty,
  nil, first call, repeated call and off-main-thread.

**Before reporting done**
- **Regression tests have teeth.** Run the new test on the pre-fix code and
  keep the failing output. Every assertion must be able to fail. Resolve
  fixture paths from the repo root.
- **Run the checks.** `./scripts/test-macos-native.sh`, and `--unit` when
  tests changed.
- **Report verified and unverified separately.** Verified means the command
  and its output. Don't claim "root cause", "never" or "fully covered"
  without evidence.

**Never do these; ask the user instead.** Commit or push. Launch the
installed app or a copy of it. Kill processes you didn't start. Modify
`/Applications`. Read, print or copy credentials (`DSH_HOME`,
`.credentials.yaml`, tokens). Delete or skip failing tests.

## Build & test commands

```bash
./scripts/build-macos-app.sh                 # builds dist/DeepSeek Harness.app
./scripts/refresh-macos-app.sh               # Swift-only in-place refresh of /Applications app
./scripts/test-macos-native.sh               # swiftc -typecheck + Info.plist lint (no build needed)
./scripts/test-macos-native.sh --smoke       # + starts the built app's Host, checks read/write API and Agent platform
./scripts/verify-native-host-api.sh <App>    # what --smoke calls; runnable standalone
plutil -lint "dist/DeepSeek Harness.app/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "dist/DeepSeek Harness.app"
```

`NODE_SOURCE` overrides the Node executable embedded by the build.
`CODESIGN_IDENTITY` selects the build/signing identity; it defaults to `-`
(ad-hoc) for the full build, while `scripts/refresh-macos-app.sh` auto-selects
an available Apple Development identity to keep local TCC grants stable.
`scripts/dsh-runtime-version.txt` is the single supported DSH version;
`scripts/prepare-dsh-runtime.sh` installs it into an ignored `dist` cache.
`DSH_SOURCE` is accepted only when it points to that same complete version.
