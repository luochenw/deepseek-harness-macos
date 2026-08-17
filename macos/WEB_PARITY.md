# Native DSH Web-Parity Matrix

Last audited against the installed DSH Web Host API and the web bundle composition.

## Native implementation connected to the real Host

| Web domain | Native status | Host transport |
|---|---|---|
| Workspaces and persistent sessions | Implemented with native workspace create/rename/delete | `workspace.list`, `session.list`, `session.create`, host events |
| Session search, rename, fork, archive | Implemented | `session.search`, `session.rename`, `session.fork`, `workspace.archiveSession` |
| Conversation history and streaming | Implemented with reasoning, retry, compaction, pagination and trajectory baseline | `session.history`, `events.mux` |
| Prompt, queue, cancel | Implemented with native queue edit/remove/steer | `session.prompt`, `session.cancel`, `session/queue` |
| Images | Implemented send, durable history ref, Host retrieval and automatic native preview | `session.prompt` image content block |
| Slash commands, message feedback, plugin inventory | Command-line autocomplete/dispatch, per-message thumbs up/down, and a read-only plugin-inventory list in Settings implemented via the native Typert Gateway client | `commands/list`, `commands/execute`, `messageFeedback/*`, `pluginInventory/list` |
| Tool and job state | Implemented callId-correlated Host render-intent cards, including delivered file open/reveal controls | `tool/*`, `session/jobs`, `host.openPath` |
| Todo, plan, goal | Todo list, Host-driven plan mode (`plan.active`, not a local toggle), and a composer-docked goal bar (objective, phase, round progress, pause/resume/complete/clear) implemented | session projections, `goal.*`, Typert `commands/execute` |
| Approval and questions | Implemented with a backlog queue (a second request no longer overwrites the one already showing), "always allow this session," and defer/recall for questions | answerable mux frames and `/api/respond` |
| Subagents | Catalog, nested history navigation, continuable prompt (text and image) and interrupt implemented. A subagent transcript is a dedicated overlay on the conversation pane (not a synthetic top-level session) that streams live and visually distinguishes read-only (one-shot) from continuable transcripts — see [subagent-transcript-redesign](.agents/notes/implemented/feature/2026-08-14-subagent-transcript-redesign.md) | `subagent.list`, `subagent.history`, `subagent.prompt`, `subagent.interrupt` |
| Skills | Catalog implemented and rendered as a dashboard card (name, description, model-invocable badge) | `skill.list` |
| Models and credentials | Catalog/status/session selection, dynamic credential references, and revisioned custom endpoint authoring implemented; legacy route IDs remain compatible but are not a required product entry | `llm.models`, `credentials.describe`, `session.selectModel` |
| Agent presets | Roster/select implemented | `agentPreset.list`, `agentPreset.select` |
| Settings | Scrollable native inventory, revisioned JSON editor, generic credential-reference writes, mutate, open-document, and inline revision-conflict recovery (discard-and-reload or keep-edits-and-retry) implemented | `settings.describe` |
| Workflow | Durable run-state, members grouped by phase, real `running/completed/failed/cancelled` status vocabulary (verified against the upstream wire types, not guessed) and native member drill-down implemented — see [workflow-phase-grouping-and-status](.agents/notes/implemented/feature/2026-08-14-workflow-phase-grouping-and-status.md) | `tool-workflow/*` events |

## Native capability beyond web parity

Not every native feature is "catching up" to the web client — some native
capability is only possible because this is a native app:

- **Menu bar presence + system notifications**: a persistent `NSStatusItem`
  reflects idle/running/needs-attention state; local notifications fire for
  approval requests, agent questions, and top-level turn completion whenever
  the app isn't frontmost, with a Dock-bounce attention request and a
  click-to-activate path back into the app. See
  [native-menu-bar-and-notifications](.agents/notes/implemented/feature/2026-08-14-native-menu-bar-and-notifications.md).

## Remaining web-parity work

- Refine presentation parity for every tool render intent: terminal, diff, read, search, web results, and code dispatch (syntax highlighting, collapse/expand for long output). Attachment images gained a [zoomable lightbox](.agents/notes/implemented/feature/2026-08-14-attachment-lightbox.md); the cross-message attachment **rail** (a strip of every image in the session) is still open.
- Complete session-event folding with full trajectory virtualization (currently `LazyVStack`, on-screen-lazy but not measured/windowed). Compaction summaries now [persist into the scrollback](.agents/notes/implemented/feature/2026-08-14-workflow-phase-grouping-and-status.md) instead of only an ephemeral banner; retry notices remain ephemeral by design (frequent, transient — see that note's rationale).
- Subagents: gained a [whole-tree ("descendants") view](.agents/notes/implemented/feature/2026-08-14-subagent-descendants-tree.md), walked client-side (depth/node-capped, with explicit truncation disclosure) since the client-facing `subagent.list` RPC's support for a server-side descendants scope is unverified. Still open: scope the tool/todo/goal dashboard cards to the currently-viewed subagent instead of always the top-level session.
- Add native accessibility/UI tests that execute a real App instance and verify Host event projections.

## Deliberate architecture

The macOS app is SwiftUI/AppKit native. It starts the bundled DSH Host only as a local runtime, consumes its documented loopback RPC and WebSocket event protocol, and does not embed the Web UI in a WebView. Its RPC client implements the legacy dot-method `ApiProxy` surface (`session.*`, `workspace.*`, `subagent.*`, ...) plus a native Typert Gateway client (`/api/<namespace>/<method>`) covering `commands/*`, `messageFeedback/*`, and `pluginInventory/*`; newer Gateway namespaces such as `dynamicCordisRunner` self-modification remain unimplemented.
