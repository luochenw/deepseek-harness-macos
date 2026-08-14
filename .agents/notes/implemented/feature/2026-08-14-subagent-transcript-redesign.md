# Agent Note: Subagent transcripts are a dedicated overlay, not synthetic top-level Sessions, and stream live

Status: implemented

## Problem

`openSubagent(_:)` displayed a subagent's history by constructing a plain
`Session` and calling `sessions.insert(local, at: 0)` — the exact same
mechanism used for a real top-level DSH session — then selecting it. Three
problems followed directly from treating a subagent transcript as if it
were a sibling top-level session:

1. **Sidebar pollution**: every subagent ever opened during a browsing
   session accumulated permanently in `sessions`/the sidebar list, with no
   eviction. A single afternoon poking around a workflow's members would
   leave a dozen stale "sessions" behind that are not real DSH sessions the
   Host tracks as top-level.
2. **No live streaming**: `consumeMuxFrame`'s `session/event` handling only
   applied incoming events when `sessionID == hostCurrentSessionID` — the
   *parent's* session id, since opening a subagent never changed
   `hostCurrentSessionID`. A subagent's live token stream, tool calls, and
   completion were silently dropped; the only way to see new subagent output
   was to close and reopen it (re-fetching `subagent.history` from
   scratch).
3. **Inconsistent "back" navigation**: `navigateUpSubagent()` popped
   `subagentPath` and reloaded the subagent *catalog* for the new top of
   path, but never touched `selectedSessionID` — so after drilling
   parent → child → grandchild and clicking "返回上级", the conversation
   pane kept showing the grandchild's frozen transcript while the sidebar
   dashboard now listed the *child's* subagent catalog, a visible mismatch.

## Decision

Introduced `@Published var subagentTranscript: Session?` and
`var displayedSession: Session? { subagentTranscript ?? selectedSession }`.
Every view that rendered `harness.selectedSession` (`ConversationView`,
`ConversationHeader`, `Composer`'s send-availability) now reads
`harness.displayedSession` instead — a subagent transcript overlays the main
conversation pane without ever entering `sessions`.

`openSubagent` and the (new) up-navigation path both go through one private
helper, `loadSubagentTranscript(address:label:running:)`, which fetches
`subagentHistory`, folds it, and sets `subagentTranscript` — so "open a
subagent" and "navigate back up to an ancestor subagent" are the same
operation and can no longer disagree about what's on screen.
`navigateUpSubagent()` now re-fetches and redisplays the new path top (or
clears `subagentTranscript`/returns to the real top-level session when the
path empties), fixing the back-navigation mismatch.

Live streaming: `consumeMuxFrame`'s `session/event` case now branches on
whether the incoming `sessionId` matches the *active subagent's*
`childSessionId` (route to the new `applyLiveSubagentEvent`, which folds
`assistant/chunk` / `assistant/message` / `user/message` / `turn/end` into
`subagentTranscript`) versus the top-level `hostCurrentSessionID` (existing
`applyLiveEvent`, unchanged). A subagent conversation now updates token-by-
token while open, matching top-level session behavior.

Composer now distinguishes the two subagent modes the Host already reports
(`DSHSubagentAddress.mode`): a `continuable` subagent keeps the normal
composer (routes through the existing `send()` → `promptSubagent` path,
unchanged from the earlier image-routing fix); any other transcript opened
in this new overlay whose mode is not `continuable` (i.e. a one-shot
subagent's frozen history) replaces the composer with a disabled "只读:
此子代理已结束,历史不可续写" banner instead of a `TextEditor` the user
could type into with no effect.

## Alternatives considered

- **Keep inserting into `sessions` but tag entries as synthetic and evict
  them on navigate-away.** Rejected — still conflates two different
  concepts (a durable, Host-tracked top-level session vs. an ephemeral
  view of a subagent's history) sharing one array and one `Identifiable`
  model, which is what made the live-streaming routing bug possible in the
  first place (nothing at the `consumeMuxFrame` layer knew "this open
  session is actually a subagent, route its events differently").
- **Give subagent transcripts their own `sessionId`-keyed dictionary/cache
  instead of a single `subagentTranscript` slot, to support multiple
  simultaneously-open subagent tabs.** Rejected for this pass — the
  existing UI (breadcrumb `subagentPath`, single `DetailsPanel`) is built
  around viewing one subagent context at a time, matching how
  `activeSubagentAddress` already worked. Multi-tab subagent viewing is a
  larger UI change tracked as a follow-up in
  [macos/WEB_PARITY.md](../../../../macos/WEB_PARITY.md) rather than forced
  into this fix.
- **Route the full `applyLiveEvent` switch (tools/todos/goal/workflow
  events, not just messages) through the subagent-vs-parent branch.**
  Rejected for scope — those dashboard cards (todo, running tools, goal)
  read naturally as "what's the top-level session doing" even while
  briefly inspecting a subagent's transcript, and re-scoping all ~15 event
  cases to be transcript-aware would be a much larger, separately-reviewable
  change. Only message streaming (the concretely broken, user-visible gap)
  is in scope here.

## Consequences

Opening, drilling into, and navigating back up through subagents no longer
grows the sidebar, no longer desyncs the conversation pane from the
subagent dashboard card, and now streams live instead of requiring a manual
reopen to see new output. The one-shot/continuable distinction is now
visible and enforced in the composer instead of silently accepting (and
discarding) typed input into a frozen transcript. Not addressed here:
whole-subagent-tree ("descendants") viewing and tool/todo/workflow dashboard
scoping to the currently-viewed subagent remain open — both are called out
in `macos/WEB_PARITY.md`.
