# DeepSeek Harness — Native macOS App

[中文](README.md) | English

[![CI](https://github.com/luochenw/deepseek-harness-macos/actions/workflows/ci.yml/badge.svg)](https://github.com/luochenw/deepseek-harness-macos/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/luochenw/deepseek-harness-macos)](https://github.com/luochenw/deepseek-harness-macos/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)

An independent, **unofficial** SwiftUI/AppKit native macOS client for [DSH](https://github.com/deepseek-ai/deepseek-harness) (DeepSeek Harness) — not a WebView or Electron wrapper around the DSH Web UI. The application shell is native; WebKit is used only for browser tabs opened by the user or explicitly requested by a model in the right workbench.

Agent reasoning, tools, MCP, terminal, filesystem, and subagents are still provided by the bundled DSH runtime. The app embeds Node.js and a complete DSH runtime, so it doesn't depend on a system-wide Node or `dsh` install to run.

![Main window: native three-pane UI running a task in a sample workspace](docs/screenshots/hero.png)

## Native features

- Native three-pane SwiftUI interface, streaming transcript, run/stop state, keyboard shortcuts.
- One native-workbench design system across the product: cool neutral solid surfaces and aqua `#A2E4E0`, sampled from the original rendered App Icon, as the single primary color. Primary actions use `#A2E4E0` with white labels. The logo itself is unchanged, and shared SF typography roles, tighter radii, and consistent button/form states avoid a second primary palette or global decorative gradients.
- While a turn is running, press `Esc` anywhere outside editable text in the main window to stop the current root turn or continuable subagent. Input fields, IME composition, dialogs, and menus retain Escape priority.
- The sidebar groups sessions by project. Each project is collapsible and previews its five most recent sessions with on-demand expansion.
- Opening an existing session shows that Host session's fixed working directory; the workspace picker only controls sessions that have not been created yet.
- Transcript prose uses a larger reading scale with clearer spacing and structural icons. The composer follows the same centered reading width as the transcript. Code blocks show line counts, collapse controls, and one-click copy; tables and quotes have distinct visual hierarchy.
- Reasoning and tool activity stay in one collapsed live status row that continuously reflects the latest thought, answer, or tool action, then settles into an expandable “Reasoning” row instead of expanding the entire trace into a log wall.
- Paste screenshots or multiple copied image files directly into the composer, or select several files at once. Drafts show removable thumbnails and open in a zoomable preview.
- Every tool run uses the same two-level disclosure. The outer row shows the current or most recent instruction directly. Expanding it reveals instruction rows only, capped at `320pt` with internal scrolling, never a wall of results or an unbounded transcript. `run_code` is expanded into its actual child tool calls, with instruction titles derived from commands, file paths, patterns, URLs, and other real arguments. Empty JSON, generic fallback labels, call counts, and per-tool icon changes are omitted. Each instruction can independently reveal its own output.
- A Host-backed permission menu in the composer for Read Only, Workspace Access, and Full Access. Defaults and current-session access are managed separately, and Full Access requires an explicit risk confirmation.
- The composer stays writable while an Agent is running. With an empty queue, Send goes directly to the current turn; Queue appears only once a queued message exists, and the busy-Enter preference applies to that existing queue.
- Opening a persisted session immediately shows the latest usable content and re-enables the composer, then incrementally fetches older Host pages in the background. Each page appears as it arrives, and the final transcript is complete without manual “load older messages” or local transcript-window controls.
- The composer's model label opens one stable picker containing the live model catalog and the selected model's advertised reasoning efforts. A choice is sent directly to the Host instead of relying on a hover-only nested submenu.
- A session-scoped, resizable right workbench with multiple browser, Markdown, execution, Agent, and tool-detail tabs. Switching tabs or sessions preserves browser page state. Models can call `open_workbench_browser` / `open_workbench_markdown` to request a tab for the current task, but cannot read the DOM, inject scripts, click the page, or receive browser/document contents.
- Native `NSOpenPanel` workspace entry; the chosen workspace persists in macOS user defaults.
- Local tasks run from the selected workspace — DSH can execute a terminal, read/write files, use skills, and use configured local tools.
- Subagent transcripts are a dedicated, live-streaming overlay on the conversation pane (not a synthetic top-level session), with a visible read-only/continuable distinction and breadcrumb navigation.
- Reusable Agent Profiles dispatch DSH, Claude Code, Codex, and ZCode together from the composer, a manual run sheet, or an authorized Agent/Subagent tool call. The three external runtimes must be installed and authenticated separately on the Mac. Dedicated right-workbench tabs show durable Batches, member logs, stop/retry/discard actions, immutable runtime snapshots, and selective root-Agent integration.
- Execution members require isolated Git worktrees. Each Batch freezes the initiating session's cwd, sandbox mode, model, tool surface, and Agent Preset; external CLIs run through DSH's sandbox provider, while continuable DSH contexts reuse their worktree until adoption or discard.
- A Dock icon badge and system notifications for approval requests, agent questions, and turn completion — capability a browser tab structurally can't provide. The badge shows "!" while any session waits on an approval or question, "•" while work is running, and nothing when idle; after closing the window, click the Dock icon to reopen it. (The menu bar item was removed to avoid a macOS 27 beta system crash.)
- Consecutive tool calls in a turn fold into one row, "ran N commands · M modified files", which expands on click. Calls that modify files get a pencil icon, an accent bar and a "改" tag; multi-line scripts and heredocs show a readable summary (for example "Python script · modifies js/scene.js").
- External agent bridge: while the app runs it publishes its local Host address, and `scripts/ds-agent` sends tasks to the app's Host so the session appears live in the sidebar; without the app it falls back to headless. The Host restarts automatically if it dies, and exits when the app quits or crashes.
- Wake-word dictation routes by app context: it sends to the current conversation while the app is in front, dispatches a separate background session otherwise, and only fills the composer when auto-send is disabled.
- Settings → Usage shows current-session context occupancy, cumulative input/output tokens, cache reads/writes and hit rate, plus LLM/tool timing. Figures come from live Host projections and never invent account balances, remaining quota, or costs.
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

Requirements: macOS 14+, Swift Command Line Tools, Node.js, and npm. Running the built app requires none of these globally.

```bash
./scripts/build-macos-app.sh
open "dist/DeepSeek Harness.app"
```

The script auto-detects `node` on your `PATH`, verifies that the version pinned in `scripts/dsh-runtime-version.txt` is still npm `latest`, installs it into an isolated cache under `dist`, and embeds it in the app. It never reads a global DSH installation or falls back to an older release; cached builds still perform the latest-version check. `NODE_SOURCE` may override Node, while `DSH_SOURCE` is accepted only for a complete runtime at the same exact version. Set `DSH_RUNTIME_VERIFY_LATEST=0` explicitly for an offline rebuild; other DSH versions are still rejected.

The result is `dist/DeepSeek Harness.app`, embeds the currently pinned DSH runtime, and matches the build machine's architecture. Current releases are ad-hoc signed and not notarized, so first launch requires the Gatekeeper step above. A future fully signed distribution would use a pinned Node artifact, sign every layer with a Developer ID, enable the hardened runtime, and notarize the package.

For local Swift-only changes, you do not need to package and drag-install the app again. Refresh the native executable inside the installed app, preserve its embedded Runtime and application data, and relaunch it with:

```bash
./scripts/refresh-macos-app.sh
```

The refresh stops every app copy with the same bundle identifier before relaunching the target, so two Hosts cannot retain the shared-session write lease. The default fast local mode updates and verifies only the native executable in roughly 40–50 seconds. It does not refresh Node, DSH, runtime patches, or other bundle resources; those changes still require the full build. The script refuses to update an app whose embedded DSH version differs from the repository. Set `REFRESH_FULL_SIGN=1` to re-sign and verify the complete bundle, which is much slower because macOS scans the 843 MB Runtime. Refreshing interrupts running model work.

The refresh script automatically selects an available local `Apple Development` signing identity. Unlike an ad-hoc cdhash identity, its stable designated requirement lets microphone and speech-recognition grants survive subsequent refreshes. Switching from ad-hoc to a development certificate may require one final macOS approval. Override the identity with `CODESIGN_IDENTITY=<certificate hash or name>`, or force ad-hoc signing with `CODESIGN_IDENTITY=-`; ad-hoc refreshes can prompt for TCC access again on every new build. The full build accepts the same `CODESIGN_IDENTITY` environment variable.

## Usage

1. Open the app and choose a workspace. This grants DSH local file and terminal access inside that directory.
2. Open Settings. The native page reads the real model catalog, configuration inventory, and credential status from the Host. Add a **Custom Configuration** for any compatible endpoint, then set its name, base URL, API protocol, model IDs, and API key through revisioned Host settings mutations.
3. API keys are saved, rotated, or cleared through the Host's write-only credential API; RPC never returns the secret. On the same Mac, the native app can prefill the current value from its own local configuration directory. Existing legacy routes remain editable as custom configurations rather than being treated as a required provider.
4. Type a task, then attach or paste images if needed and run. While it is running, Enter uses the configured Queue/Steer behavior and Command-Enter uses the other behavior; the two actions are also available as separate buttons.
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

`NativeContractCheck.swift` is a compile-time fixture built alongside production types, covering the DSH 0.2 RPC envelope, prompt request identity, settings JSON patches, queue actions, attachment references, and Agent Profile/Batch requests. `--unit` also runs pure-logic tests and renders real AppKit/SwiftUI snapshots for the Agent platform, workbench, permission/running-input controls, and a 2,000-message conversation. The workbench check additionally loads a loopback HTTP page in a real `WKWebView`. `--smoke` never sends an LLM prompt or mutates the user's workspace/credentials; in a temporary `DSH_HOME` it verifies token authentication, `session/list/create/follow`, workspace/control streams, settings persistence, and Agent Profile CRUD. `--smoke /path/to/App.app` checks a non-default build.

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

### Can an existing session switch workspaces?

Not directly. DSH stores the session's `cwd` in its durable header, and workspace attachment only validates that directory; there is no mutation endpoint. The conversation header shows the real fixed directory. Start a new session to work in another folder. Branch/worktree controls for the existing session still operate on that fixed cwd.

### Why does the app report `session/writer-held`?

Another live Host still owns the session's write handle. This is not log corruption. The most common cause is opening both `/Applications/DeepSeek Harness.app` and a `dist/DeepSeek Harness.app` copy: they share one session directory, and DSH permits only one writer. Quit every app copy and reopen the intended app; the kernel releases the lease when the old process exits. Do not delete `session.lock`. The in-place refresh script now stops all copies with the same bundle identifier first.

### What does it do that the web UI can't?

A Dock badge, system notifications for approvals/questions/completion while the app is in the background, live subagent overlays, Finder integration, and native windowing — things a browser tab structurally can't provide. The full feature-by-feature comparison lives in [macos/WEB_PARITY.md](macos/WEB_PARITY.md).

## Contributing

Issues and PRs welcome. Before changing code, read [CLAUDE.md](CLAUDE.md) — it documents the spec-coding workflow this project uses (Agent Notes for non-trivial decisions, verification steps, commit conventions) — and [AGENTS.md](AGENTS.md) for the architecture and style this codebase follows.

## License and attribution

This project's own source is [MIT licensed](LICENSE). A **built app** additionally embeds `@deepseek-ai/dsh` (MIT, Copyright DeepSeek) plus a Node.js runtime. The build applies a narrow, version-gated runtime patch for the Agent platform; the patch source is in this repository. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for full attribution.
