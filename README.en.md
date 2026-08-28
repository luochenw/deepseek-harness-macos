# DeepSeek Harness — Native macOS App

[中文](README.md) | English

[![CI](https://github.com/luochenw/deepseek-harness-macos/actions/workflows/ci.yml/badge.svg)](https://github.com/luochenw/deepseek-harness-macos/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/luochenw/deepseek-harness-macos)](https://github.com/luochenw/deepseek-harness-macos/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)

An independent, **unofficial** SwiftUI/AppKit native macOS client for [DSH](https://github.com/deepseek-ai/deepseek-harness) (DeepSeek Harness) — not a WebView or Electron wrapper around the DSH Web UI, and not affiliated with or endorsed by DeepSeek AI. The application shell is native; WebKit is used only for browser tabs opened by the user or explicitly requested by a model in the right workbench.

Agent reasoning, tools, MCP, terminal, filesystem, and subagents are still provided by the bundled DSH runtime. The app embeds Node.js and a complete DSH runtime, so it doesn't depend on a system-wide Node or `dsh` install to run.

![Main window: native three-pane UI running a task in a sample workspace](docs/screenshots/hero.png)

## Native features

- Native three-pane SwiftUI interface, streaming transcript, run/stop state, keyboard shortcuts.
- A Host-backed permission menu in the composer for Read Only, Workspace Access, and Full Access. Defaults and current-session access are managed separately, and Full Access requires an explicit risk confirmation.
- The composer stays writable while an Agent is running: additions can steer the current turn or queue the next turn, with a configurable busy-Enter preference.
- Long conversations use a sliding render window capped at 240 messages, preserving reading anchors while preventing streaming updates from rebuilding the full transcript.
- A session-scoped, resizable right workbench with multiple browser, Markdown, execution, Agent, and tool-detail tabs. Switching tabs or sessions preserves browser page state. Models can call `open_workbench_browser` / `open_workbench_markdown` to request a tab for the current task, but cannot read the DOM, inject scripts, click the page, or receive browser/document contents.
- Native `NSOpenPanel` workspace entry; the chosen workspace persists in macOS user defaults.
- Local tasks run from the selected workspace — DSH can execute a terminal, read/write files, use skills, and use configured local tools.
- Subagent transcripts are a dedicated, live-streaming overlay on the conversation pane (not a synthetic top-level session), with a visible read-only/continuable distinction and breadcrumb navigation.
- Reusable Agent Profiles dispatch DSH, Claude Code, Codex, and ZCode together from the composer, a manual run sheet, or an authorized Agent/Subagent tool call. The three external runtimes must be installed and authenticated separately on the Mac. Dedicated right-workbench tabs show durable Batches, member logs, stop/retry/discard actions, immutable runtime snapshots, and selective root-Agent integration.
- Execution members require isolated Git worktrees. Each Batch freezes the initiating session's cwd, sandbox mode, model, tool surface, and Agent Preset; external CLIs run through DSH's sandbox provider, while continuable DSH contexts reuse their worktree until adoption or discard.
- A persistent menu bar item and system notifications for approval requests, agent questions, and turn completion — capability a browser tab structurally can't provide.
- Wake-word dictation routes by app context: it sends to the current conversation while the app is in front, dispatches a separate background session otherwise, and only fills the composer when auto-send is disabled.
- Settings editor with inline, two-choice revision-conflict recovery (discard-and-reload or keep-edits-and-retry) instead of a silently stalled save.
- Native Finder integration, runtime settings panel, error diagnostics, and quit lifecycle.
- Bundles a Node.js binary matching the app artifact's architecture plus the complete DSH runtime — no dependency on a global npm install or the Finder's `PATH`.

See [macos/WEB_PARITY.md](macos/WEB_PARITY.md) for the living matrix of what's implemented against the web client, what's native-only, and what's still open.

## Install

Grab the zip from the [latest release](https://github.com/luochenw/deepseek-harness-macos/releases/latest) (Apple Silicon, macOS 14+), unzip, and drag **DeepSeek Harness.app** into `/Applications`.

> **Gatekeeper:** release builds are ad-hoc signed, not notarized — macOS blocks the first launch. Open **System Settings → Privacy & Security** and click **Open Anyway**, or run:
>
> ```bash
> xattr -rd com.apple.quarantine "/Applications/DeepSeek Harness.app"
> ```
>
> Prefer not to trust an un-notarized binary? Build from source below — one command, and the result is self-contained.

## Build

Requirements: macOS 14+, Swift Command Line Tools. The build machine needs a full DSH install and Node; running the built app requires neither globally.

```bash
./scripts/build-macos-app.sh
open "dist/DeepSeek Harness.app"
```

The script auto-detects `node` on your `PATH` and a globally-installed `@deepseek-ai/dsh` (recommended: `npm install -g @deepseek-ai/dsh@0.1.1-rc.2`; `0.1.0-rc.6` and `0.1.0-rc.7` remain supported); override with the `NODE_SOURCE` / `DSH_SOURCE` env vars if yours live elsewhere.

The result is `dist/DeepSeek Harness.app`, roughly 340–570MB depending on the bundled DSH version, and matches the build machine's architecture. Current releases are ad-hoc signed and not notarized, so first launch requires the Gatekeeper step above. A future fully signed distribution would use pinned Node/DSH artifacts, sign every layer with a Developer ID, enable the hardened runtime, and notarize the package.

## Usage

1. Open the app and choose a workspace. This grants DSH local file and terminal access inside that directory.
2. Open Settings. The native page reads the real model catalog, configuration inventory, and credential status from the Host. Add a **Custom Configuration** for any compatible endpoint, then set its name, base URL, API protocol, model IDs, and API key through revisioned Host settings mutations.
3. API keys are saved, rotated, or cleared through the Host's write-only credential API; RPC never returns the secret. On the same Mac, the native app can prefill the current value from its own local configuration directory. Existing legacy routes remain editable as custom configurations rather than being treated as a required provider.
4. Type a task and run. While it is running, Enter uses the configured Queue/Steer behavior and Command-Enter uses the other behavior; the two actions are also available as separate buttons.
5. Use the permission menu at the bottom of the composer for the current session. **Settings → General → Default permission for new sessions** affects only sessions created later.
6. ⌘W chooses a workspace; ⌘O opens it in Finder; ⌘⇧B creates a browser tab; ⌘⇧M opens Markdown; ⌘⌥B toggles the workbench.

## Verification and native tests

This repo deliberately has no Xcode or SwiftPM test project — production builds compile `macos/DSHApp/*.swift` directly with `swiftc`. The test script reuses that exact input set instead of maintaining a second, driftable target list (see [the Agent Note](.agents/notes/implemented/architecture/2026-08-14-no-xcode-project.md)).

```bash
# Fast, side-effect-free native contract check: compiles every production Swift source + RPC-encoding fixtures.
./scripts/test-macos-native.sh

# After a build: starts the bundled Host in a temp DSH_HOME and checks read/write and Agent-platform paths.
./scripts/build-macos-app.sh
./scripts/test-macos-native.sh --smoke

# Pre-release bundle integrity checks.
plutil -lint "dist/DeepSeek Harness.app/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "dist/DeepSeek Harness.app"
```

`NativeContractCheck.swift` is a compile-time fixture built alongside production types, covering the RPC envelope, text prompts, settings JSON patches, queue actions, attachment references, and Agent Profile/Batch requests. `--unit` also runs pure-logic tests and renders real AppKit/SwiftUI snapshots for the Agent platform, workbench, permission/running-input controls, and a 2,000-message conversation. The workbench check additionally loads a loopback HTTP page in a real `WKWebView`. `--smoke` never sends an LLM prompt or mutates the user's workspace/credentials; in a temporary `DSH_HOME` it verifies permission defaults, new-session inheritance, current-session switching, settings persistence, model-visible workbench tools, Agent Profile CRUD, runtime status, and Batch failure isolation. `--smoke /path/to/App.app` checks a non-default build.

## FAQ

### Is there a native macOS app for DeepSeek Harness?

Officially, no — [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) ships a CLI (`dsh`) and a browser UI, both Node.js/TypeScript. This project is exactly that missing piece: an independent, MIT-licensed SwiftUI/AppKit app, not a WebView or Electron wrapper. Grab it from the [releases page](https://github.com/luochenw/deepseek-harness-macos/releases/latest).

### Do I need to install Node.js or dsh first?

No. The app bundles a Node.js runtime and a complete `dsh` install — download, drag to Applications, done. Nothing touches your global environment.

### Why does macOS say the app "cannot be opened" or is from an "unidentified developer"?

Release builds are ad-hoc signed and not notarized (no paid Apple Developer account behind this project). Open **System Settings → Privacy & Security → Open Anyway** once, or run `xattr -rd com.apple.quarantine "/Applications/DeepSeek Harness.app"`. If you'd rather not trust an un-notarized binary, `./scripts/build-macos-app.sh` builds an equivalent self-contained app from source in one command.

### Can I use it with other OpenAI-compatible endpoints or self-hosted models?

Yes. Settings supports custom configurations: any endpoint with a name, base URL, protocol, and model IDs. API keys are stored through the Host's write-only credential API, which never returns the secret over RPC; on the same Mac, the native app can prefill it from its own local configuration directory. The MIT source is here to verify that behavior.

### Does it run on Intel Macs?

The release zip is Apple Silicon only. Intel works via the one-command build from source on your own machine.

### What does it do that the web UI can't?

A persistent menu bar presence, system notifications for approvals/questions/completion while the app is in the background, live subagent overlays, Finder integration, and native windowing — things a browser tab structurally can't provide. The full feature-by-feature comparison lives in [macos/WEB_PARITY.md](macos/WEB_PARITY.md).

## Contributing

Issues and PRs welcome. Before changing code, read [CLAUDE.md](CLAUDE.md) — it documents the spec-coding workflow this project uses (Agent Notes for non-trivial decisions, verification steps, commit conventions) — and [AGENTS.md](AGENTS.md) for the architecture and style this codebase follows.

## License and attribution

This project's own source is [MIT licensed](LICENSE). A **built app** additionally embeds `@deepseek-ai/dsh` (MIT, Copyright DeepSeek) plus a Node.js runtime. The build applies a narrow, version-gated runtime patch for the Agent platform; the patch source is in this repository. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for full attribution. This project is not affiliated with or endorsed by DeepSeek AI.
