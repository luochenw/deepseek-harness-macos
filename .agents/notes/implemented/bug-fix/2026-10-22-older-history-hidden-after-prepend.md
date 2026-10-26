# Agent Note: Make the older-history action visibly reveal its loaded page

Status: implemented - older pages now request through a durable fallback and reveal the newly loaded rows

Superseded by: [Load the complete session transcript automatically](../simplification/2026-10-22-load-complete-session-history.md).

## Problem

The transcript offers "载入更早消息" whenever `historyHasMore` is true. Clicking
it starts a valid `session/page` request, but the UI gives no loading feedback.
On success the older messages are prepended and the previous first message is
restored at the top of the viewport. Because the new rows are above that anchor,
the screen appears unchanged even though the Host returned another page.

The action also returns silently when its internal follow cursor or oldest
sequence is not ready, even though the button remains enabled.

Real diagnosis additionally showed `historyOldestSeq=2955` and
`historyHasMore=true` while the in-memory follow cursor was nil, so the button
was blocked before any RPC. The selected Host summary still exposed a durable
projection `asOfSeq`, which is a valid page cut.

## Decision

- Mark the displayed session as loading older history for the duration of the
  request and disable/relabel the action.
- Use the live follow cursor when available, otherwise fall back to the selected
  Host session summary's durable projection `asOfSeq`.
- On success, restore the previous first message at the bottom of the viewport,
  so the newly prepended page occupies the visible area above it.
- Surface success, empty-page, cursor-not-ready, and request failures instead of
  returning without feedback.
- Clear loading state on success, failure, cancellation, or generation
  invalidation.
- Keep automatic history restoration's default anchor alignment at the top;
  only the explicit older-page action requests bottom alignment.

## Alternatives considered

- **Scroll to the new first message.** Rejected because it jumps over the whole
  loaded page and disorients the reader.
- **Keep the old top anchor.** Rejected because it makes a successful request
  look like a no-op.
- **Auto-fetch repeatedly until viewport height is filled.** Rejected because a
  single click should map to one bounded Host page and preserve predictable
  cursor progress.
- **Show only a toast.** Rejected because success must expose the actual older
  messages, not merely acknowledge that bytes arrived.

## Consequences

- The button changes to a disabled loading label and shows a top loading row.
- A successful page makes previously hidden rows visible above the old first
  row without jumping over the loaded page.
- Cursor-not-ready and Host errors are visible.
- Loading state clears on every completion path.
- Existing automatic prepend behavior remains top-anchored.
- A real old session loaded 632 events into 107 visible messages from seq range
  `2323...2954`; the missing rows immediately became visible in the transcript.
- The complete 180-test unit/snapshot suite, app build, and Host smoke passed.

## Risks

- A page containing only non-visible lifecycle events may produce no message
  rows; the UI reports that explicitly and cursor progress still determines
  whether another page is available.
- The bottom anchor intentionally changes reading position for this explicit
  user action.
