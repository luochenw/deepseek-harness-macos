# AGENTS.md — Architecture & Style Reference

This file is the code-style and architecture reference for `deepseek-harness-macos`. The workflow contract (how to plan, verify, and ship a change) is in [CLAUDE.md](CLAUDE.md), which points back here for "how this codebase is built" questions.

## What this is

A SwiftUI/AppKit **native** macOS client for [DSH](https://github.com/deepseek-ai/deepseek-harness) (DeepSeek Harness), an open-source agent coding harness. It is not a WebView wrapper: the bundled DSH Host runs as a local process, and the native UI drives it entirely over its documented loopback RPC + WebSocket protocol. See [README.md](README.md) for the product description and [macos/WEB_PARITY.md](macos/WEB_PARITY.md) for the living gap list against the web client this app tracks parity with.

## Repository layout

```
macos/DSHApp/       All Swift sources — flat directory, no Xcode project (see below)
  main.swift           @main App entry and HarnessController
                        (the one ObservableObject)
  DSHHostProtocol.swift   RPC envelope types, DSHHostClient actor, DSHHostRuntime
                          (spawns/reads the bundled `dsh web` process)
  DSHHostClientExtensions.swift   Additional DSHHostClient RPC methods (subagents,
                                  presets, goal, queue, respond) split out of the
                                  core file above
  DSH<Feature>.swift   One file per feature domain, each an `extension HarnessController`
                        plus that domain's wire model structs (see Naming below)
  <Feature>View.swift / Native<Feature>*.swift   SwiftUI views for a feature
  NativeContractCheck.swift   Compile-time fixture exercising RPC envelope,
                              prompt, settings-patch, queue and attachment wire types
  Info.plist
scripts/             build-macos-app.sh, test-macos-native.sh, verify-native-host-api.sh
.agents/notes/       Agent Notes — decision records; see CLAUDE.md
dist/                Build output (git-ignored, produced locally)
```

## Deliberately no Xcode / SwiftPM project

Production builds compile `macos/DSHApp/*.swift` directly with `swiftc`
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

## Build & test commands

```bash
./scripts/build-macos-app.sh                 # builds dist/DeepSeek Harness.app
./scripts/test-macos-native.sh               # swiftc -typecheck + Info.plist lint (no build needed)
./scripts/test-macos-native.sh --smoke       # + starts the built app's Host, checks read/write API and Agent platform
./scripts/verify-native-host-api.sh <App>    # what --smoke calls; runnable standalone
plutil -lint "dist/DeepSeek Harness.app/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "dist/DeepSeek Harness.app"
```

`NODE_SOURCE` and `DSH_SOURCE` env vars override what the build embeds; see
`scripts/build-macos-app.sh` for their auto-detected defaults.
