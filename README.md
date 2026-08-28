# DeepSeek Harness — Native macOS App

English | [中文](README.zh.md)

[![CI](https://github.com/luochenw/deepseek-harness-macos/actions/workflows/ci.yml/badge.svg)](https://github.com/luochenw/deepseek-harness-macos/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/luochenw/deepseek-harness-macos)](https://github.com/luochenw/deepseek-harness-macos/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)

An independent, **unofficial** SwiftUI/AppKit native macOS client for [DSH](https://github.com/deepseek-ai/deepseek-harness) (DeepSeek Harness) — not a WebView or Electron wrapper, and not affiliated with or endorsed by DeepSeek AI. The window, workspace picker, session view, composer, run state, folder actions, settings panels, menu bar, and system notifications are all built with native macOS APIs.

Agent reasoning, tools, MCP, terminal, filesystem, and subagents are still provided by the bundled DSH runtime. The app embeds Node.js and a complete DSH runtime, so it doesn't depend on a system-wide Node or `dsh` install to run.

![Main window: native three-pane UI running a task in a sample workspace](docs/screenshots/hero.png)

## Native features

- Native three-pane SwiftUI interface, streaming transcript, run/stop state, keyboard shortcuts.
- A Host-backed permission menu in the composer for Read Only, Workspace Access, and Full Access. Defaults and current-session access are managed separately, and Full Access requires an explicit risk confirmation.
- The composer stays writable while an Agent is running: additions can steer the current turn or queue the next turn, with a configurable busy-Enter preference.
- Native `NSOpenPanel` workspace entry; the chosen workspace persists in macOS user defaults.
- Local tasks run from the selected workspace — DSH can execute a terminal, read/write files, use skills, and use configured local tools.
- Subagent transcripts are a dedicated, live-streaming overlay on the conversation pane (not a synthetic top-level session), with a visible read-only/continuable distinction and breadcrumb navigation.
- A persistent menu bar item and system notifications for approval requests, agent questions, and turn completion — capability a browser tab structurally can't provide.
- Settings editor with inline, two-choice revision-conflict recovery (discard-and-reload or keep-edits-and-retry) instead of a silently stalled save.
- Native Finder integration, runtime settings panel, error diagnostics, and quit lifecycle.
- Bundles a universal Node.js + DSH runtime — no dependency on a global npm install or the Finder's `PATH`.

See [macos/WEB_PARITY.md](macos/WEB_PARITY.md) for the living matrix of what's implemented against the web client, what's native-only, and what's still open.

## Install

Grab the zip from the [latest release](https://github.com/luochenw/deepseek-harness-macos/releases/latest) (Apple Silicon, macOS 13+), unzip, and drag **DeepSeek Harness.app** into `/Applications`.

> **Gatekeeper:** release builds are ad-hoc signed, not notarized — macOS blocks the first launch. Open **System Settings → Privacy & Security** and click **Open Anyway**, or run:
>
> ```bash
> xattr -rd com.apple.quarantine "/Applications/DeepSeek Harness.app"
> ```
>
> Prefer not to trust an un-notarized binary? Build from source below — one command, and the result is self-contained.

## Build

Requirements: macOS 13+, Swift Command Line Tools. The build machine needs a full DSH install and Node; running the built app requires neither globally.

```bash
./scripts/build-macos-app.sh
open "dist/DeepSeek Harness.app"
```

The script auto-detects `node` on your `PATH` and a globally-installed `@deepseek-ai/dsh` (`npm install -g @deepseek-ai/dsh` if you don't have one); override with the `NODE_SOURCE` / `DSH_SOURCE` env vars if yours live elsewhere.

The result is `dist/DeepSeek Harness.app`, roughly 340–570MB depending on the DSH version bundled. It's ad-hoc signed — fine for local development, not for distribution. A real release build would build from a pinned Node/DSH release artifact, arrange native addons per architecture, sign every layer with a Developer ID, enable the hardened runtime, notarize, and produce a DMG/ZIP.

## Usage

1. Open the app and choose a workspace. This grants DSH local file and terminal access inside that directory.
2. Open Settings. The native page reads the real model catalog, configuration inventory, and credential status from the Host. Add a **Custom Configuration** for any compatible endpoint, then set its name, base URL, API protocol, model IDs, and API key through revisioned Host settings mutations.
3. API keys are saved, rotated, or cleared through the Host's write-only credential API; the native app never reads back or displays a saved secret value. Existing legacy routes remain editable as custom configurations rather than being treated as a required provider.
4. Type a task and run. While the Agent is working, use **Steer** to add context to the current turn or **Queue** to send it after the turn finishes.
5. Use the permission menu at the bottom of the composer for the current session. **Settings → General → Default permission for new sessions** affects only sessions created later.
6. ⌘W chooses a workspace; ⌘⇧K clears the native conversation view; ⌘O opens the current workspace in Finder.

## Verification and native tests

This repo deliberately has no Xcode or SwiftPM test project — production builds compile `macos/DSHApp/*.swift` directly with `swiftc`. The test script reuses that exact input set instead of maintaining a second, driftable target list (see [the Agent Note](.agents/notes/implemented/architecture/2026-08-14-no-xcode-project.md)).

```bash
# Fast, side-effect-free native contract check: compiles every production Swift source + RPC-encoding fixtures.
./scripts/test-macos-native.sh

# After a build: starts the bundled Host in a temp DSH_HOME and checks read-only Host API responses.
./scripts/build-macos-app.sh
./scripts/test-macos-native.sh --smoke

# Pre-release bundle integrity checks.
plutil -lint "dist/DeepSeek Harness.app/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "dist/DeepSeek Harness.app"
```

`NativeContractCheck.swift` is a compile-time fixture built alongside production types, covering the RPC envelope, text prompts, settings JSON patches, queue actions, and attachment references. `--unit` also exercises permission projections and Queue/Steer submission policy, while the permission/composer snapshot renders the real SwiftUI controls. `--smoke` never sends an LLM prompt or mutates the user's workspace/credentials; in a temporary `DSH_HOME` it verifies permission defaults, new-session inheritance, current-session switching, and settings persistence alongside the existing Host checks. `--smoke /path/to/App.app` checks a non-default build.

## Contributing

Issues and PRs welcome. Before changing code, read [CLAUDE.md](CLAUDE.md) — it documents the spec-coding workflow this project uses (Agent Notes for non-trivial decisions, verification steps, commit conventions) — and [AGENTS.md](AGENTS.md) for the architecture and style this codebase follows.

## License and attribution

This project's own source is [MIT licensed](LICENSE). A **built app** additionally embeds an unmodified copy of `@deepseek-ai/dsh` (MIT, Copyright DeepSeek) and a Node.js runtime; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for full attribution. This project is not affiliated with or endorsed by DeepSeek AI.
