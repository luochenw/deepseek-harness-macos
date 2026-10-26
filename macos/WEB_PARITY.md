# Native DSH Web-Parity Matrix

Last audited against DSH `0.2.1-rc.2`, its Host API, and the web bundle composition.

## Native implementation connected to the real Host

| Web domain | Native status | Host transport |
|---|---|---|
| Workspaces and persistent sessions | Implemented with native workspace create/rename/delete, collapsible sidebar projects with five-session previews, archive restore, explicit legacy-session migration confirmation, and one authenticated remote mux | `workspace/follow`, `session/list`, `session/create`, `session/control` |
| Session search, rename, fork, archive | Implemented | `session/search`, `session/rename`, `session/fork`, `workspace/archiveSession`, `workspace/unarchiveSession` |
| Conversation history and streaming | Implemented with a minimal live follow tail, live assistant-stream replay/recovery, a collapsed turn-status row that follows the latest reasoning/text/tool action, retry, compaction, progressive `session/page` history that keeps the composer usable and prepends each page as it arrives, readable transcript typography/code blocks, and a 2,000-message complete-history snapshot gate | `session/follow`, `session/page`, `/api/remote.mux` |
| Prompt, queue, cancel | Implemented with client request IDs, separate running-state Queue/Steer actions, configurable busy-Enter behavior, pending steering bubbles, queue edit/remove/steer from the `inbox` projection, and cancel | `session/prompt`, `session/cancel`, `session/updateQueue`, `ui-conversation` settings |
| Images | Composer supports copied image files, pasted screenshots, multi-file selection, ordered multi-image submission, removable thumbnails, and zoomable draft previews; sent images retain durable history refs, Host retrieval, automatic native previews, and a session attachment rail | `session/prompt` image content blocks |
| Slash commands, message feedback, plugin inventory | Keyboard-driven `/` menu (↑/↓ select, Tab complete, Enter run, Esc dismiss) listing the host command roster plus the session's skills, dispatch via the native Typert client, native ZIP export and one stable model/effort picker, per-message feedback and a read-only plugin inventory | `commands/list`, `commands/execute`, `skills/list`, `messageFeedback/*`, `pluginInventory/list` |
| Tool and job state | Implemented callId-correlated Host render-intent cards with two-level disclosure: the outer row shows the current or most recent instruction, its expansion contains real instruction rows only, and each instruction independently reveals its structured output. `run_code` child calls are flattened, instruction titles come from actual commands, paths, patterns, URLs, and other arguments, and both the instruction list and result panes use adaptive height with capped internal scrolling. Empty JSON, generic fallback labels, and call counts are omitted; per-turn duration and whole-snapshot background job rows remain available from the 0.2 job stream | `tool/*`, `tool/ptc-dispatch*`, `job/list`, `session/openWorkspacePath` |
| Todo, plan, goal | Todo list, Host-driven plan mode, child-scoped projections and a composer-docked goal bar are implemented | `session/control`, `goals/*`, Typert `commands/execute` |
| Approval and questions | Implemented with a backlog queue, per-waterfall `clientId`/`eventId` acknowledgements, client-side "always allow this session," and defer/recall for questions | `$events` waterfall and `$events/result` |
| Subagents | Catalog and live transcript use parent projections plus subagent follow snapshots; continuable prompt and interrupt use 0.2 control endpoints | `subagentCatalog` projection, `session/follow`, `subagents/prompt`, `subagents/interruptByParent` |
| Skills | Catalog implemented and rendered as a dashboard card | `skills/list` |
| Models and credentials | Catalog/status/session selection, dynamic credential references, and revisioned custom endpoint authoring implemented | `session/modelCatalog`, `modelSelection` projection, `llm/listConfigurableProviders`, `credentials/describe`, `session/selectModel` |
| Agent presets | Roster/select implemented; authoring copy/remove/document actions are disabled because 0.2 no longer exposes writable preset-root APIs | `agentPresets/list`, `agentPresets/select`, `agentPresets/read` |
| Permission presets | Current session reads the `permissions` projection and option catalog, then writes through `/permission`; Settings controls the revisioned future-session default | `permissionPresets/catalog`, `permissions` projection, `commands/execute`, `settings/mutate` |
| Agent platform | Global Agent Profiles, Composer `@Profile`, multi-runtime Batch execution, isolated worktrees, logs, stop/retry/discard, restart recovery and root-Agent integration are implemented as dedicated right-workbench tabs | Typert `agentProfiles/*`, `agentBatches/*`, `agentRuns/*`, `agentContexts/*`, `agent-platform/batches` projection |
| Settings | Scrollable native inventory, selectors, model usage, revisioned JSON editor, credential writes, mutate, open-document, and conflict recovery implemented | `settings/describe`, `settings/mutate`, session projections |
| Workflow | Durable run-state, members grouped by phase, real `running/completed/failed/cancelled` status vocabulary (verified against the upstream wire types, not guessed) and native member drill-down implemented — see [workflow-phase-grouping-and-status](../.agents/notes/implemented/feature/2026-08-14-workflow-phase-grouping-and-status.md) | `tool-workflow/*` events |

## Native capability beyond web parity

Not every native feature is "catching up" to the web client — some native
capability is only possible because this is a native app:

- **Menu bar presence + system notifications**: a persistent `NSStatusItem`
  reflects idle/running/needs-attention state; local notifications fire for
  approval requests, agent questions, and top-level turn completion whenever
  the app isn't frontmost, with a Dock-bounce attention request and a
  click-to-activate path back into the app. See
  [native-menu-bar-and-notifications](../.agents/notes/implemented/feature/2026-08-14-native-menu-bar-and-notifications.md).

- **Cross-session relay** (experimental, off by default): a Settings toggle
  mounts a host-plane cordis plugin (`macos/Runtime-extras/dsh-tool-session-relay/`)
  giving the model `list_sessions`, `send_to_session`, and
  `notify_session_on_done` tools, so one top-level session can discover and
  message another directly — something the Host's own RPC surface and the
  web client have no equivalent for (harness only ships ancestor-scoped
  subagent messaging). See
  [cross-session-relay](../.agents/notes/implemented/feature/2026-08-17-cross-session-relay.md).

- **Unified local Agent platform**: reusable Profiles dispatch DSH,
  Claude Code, Codex, and ZCode members into one durable Batch with global
  concurrency control, hard analysis restrictions, isolated execution
  worktrees, initiator sandbox/model/tool/preset snapshots, a single
  root-session settlement, and natural-language selective integration.
  The right workbench shows Profiles or the current root session's
  Batches, member logs, immutable execution environment, cleanup state and
  integration evidence. Platform-managed DSH children retain continuable
  history but cannot be prompted outside the tracked Run/Batch path. See
  [unified-agent-platform](../.agents/notes/implemented/feature/2026-08-17-unified-agent-platform.md).

- **Session-scoped development workbench**: the resizable right dock keeps
  multiple browser, Markdown, execution, Agent and tool-detail tabs per
  top-level session. Browser tabs retain one stable `WKWebView`; Markdown
  documents render natively, watch external file changes, and route local or
  web links back through the workbench. Models can request a browser or
  workspace-confined Markdown tab through dedicated tools; the native client
  waits for a successful tool result before opening it. Browser content remains
  user-operated and neither browser nor document contents are exposed back to
  the Agent context.

## Remaining web-parity work

- Tool presentation supports terminal, diff, read, search, web results, and generic/code-dispatch cards inline and in workbench tabs, with bounded folding and lightweight source tokens. Remaining: richer syntax parsing and any Host card vocabularies added beyond the current supported set. Composer image drafts support multiple ordered attachments, previews, and removal; durable native transcript rows still retain one attachment reference per message, so history and the session rail expose only the first image from a multi-image Host message.
- Event-level trajectory virtualization beyond the current bounded message window remains open. Compaction summaries now [persist into the scrollback](../.agents/notes/implemented/feature/2026-08-14-workflow-phase-grouping-and-status.md) instead of only an ephemeral banner; retry notices remain ephemeral by design (frequent, transient — see that note's rationale).
- Subagents: gained a [whole-tree ("descendants") view](../.agents/notes/implemented/feature/2026-08-14-subagent-descendants-tree.md), walked client-side because the 0.2 client surface exposes direct-child projections only. Child history opens a dedicated follow snapshot; page-by-page subagent pagination is not yet exposed.
- Add native accessibility/UI tests that execute a real App instance and verify Host event projections.

## Deliberate architecture

The macOS app is SwiftUI/AppKit native. It starts the bundled DSH Host only as a local runtime, completes the 0.2 token/cookie handshake, then consumes authenticated Typert unary calls and one `/api/remote.mux` WebSocket carrying `$events`, workspace/control state, and session follows. WebKit is used only by browser tabs in the native workbench. Newer namespaces such as `dynamicCordisRunner` self-modification remain unimplemented.
