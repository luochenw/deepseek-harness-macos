# Agent Note: Load the complete session transcript automatically

Status: implemented - persisted sessions load the complete transcript automatically

## Problem

Opening a persisted session currently exposes two kinds of history pagination:

- `session/follow` restores only the snapshot tail, and the UI asks the user to
  click "载入更早消息" to fetch each older Host page.
- `DSHConversationWindow` materializes only 240 messages, and the transcript
  asks the user to click "载入上一段" or "载入下一段" to move that local window.

The first mechanism is a transport detail, while the second is a rendering
optimization. Exposing both as navigation controls makes a normal old session
feel incomplete and requires repeated user action just to read history that is
already available from the local Host.

## Decision

- Keep the Host `session/page` API and its page size as an internal batching
  detail.
- After a root snapshot reports more history, automatically request older pages
  until `hasMore` is false or the cursor stops making progress.
- Keep the transcript loading state visible while pages are fetched, then
  prepend the accumulated history to the live session transcript.
- Remove local conversation-window ranges, edge sentinels, restore anchors, and
  the "载入上一段" / "载入下一段" controls.
- Render the complete session message array through the existing `LazyVStack`.
- Preserve the Host fallback path for streams whose follow cursor is unavailable,
  but make that path load all remaining pages too.

## Alternatives considered

- **Increase the local window from 240 messages.** Rejected because it preserves
  the same manual pagination behavior and only moves the boundary.
- **Load all pages only after the user scrolls to the top.** Rejected because the
  user explicitly requires a complete transcript on open, not gesture-driven
  loading.
- **Issue one unbounded `session/page` request.** Rejected because the Host
  contract expects a bounded `maxMessages`; the App should hide batching without
  inventing an unbounded RPC.
- **Keep the window as a rendering cache while showing controls.** Rejected
  because the controls expose an implementation detail the user does not want.

## Consequences

- Opening a long session never shows "载入更早消息", "载入上一段", or
  "载入下一段"; older pages are fetched automatically until history is
  exhausted.
- The App preserves live rows appended while older pages load by prepending the
  accumulated pages to the current transcript only at the end.
- The displayed message array always covers the complete selected session.
- Empty pages and non-advancing cursors stop with a visible error instead of
  looping forever.
- The 2,000-message snapshot gate verifies that all 2,000 messages are present
  and still renders a nonblank transcript.
- Long sessions now fold and diff every message on transcript updates. The
  existing `LazyVStack` limits view creation, but incremental folding may still
  be needed if real sessions become unresponsive.
- Source switching during background loading continues to cancel stale page
  updates through the existing generation guard.
- Validation passed with 177 unit/UI tests, the complete native typecheck and
  snapshot suite, a built app, and `native-host-api-smoke`.
