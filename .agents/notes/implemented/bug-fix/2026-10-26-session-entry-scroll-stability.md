# Agent Note: Stabilize transcript entry and incremental history loading

Status: implemented - entering and loading a session keeps one stable bottom anchor

## Problem

Opening a persisted session produced a visible shake in the conversation area.
The transcript treated every message-array count change as new tail content, so
each background history page that prepended older rows scheduled another
`scrollTo("transcript-tail")`. Those requests competed with `LazyVStack` height
estimation while the session was also swapping from its placeholder to recent
content. The overlay scroller was also configured asynchronously from inside
the content, allowing the legacy gutter width to survive a layout pass.

## Decision

- Follow the transcript tail only when the final row identity or its rendered
  fields change, not when older rows are prepended.
- Coalesce follow requests so one render transaction cannot stack multiple
  competing `scrollTo` calls.
- Track only the near-bottom threshold rather than publishing every pixel of
  scrolling distance into view state.
- Render inline history progress as a non-layout overlay, so removing the
  completion row cannot change transcript height and produce a final jump.
- Memoize transcript folding by context, full-message version, and running
  state so token, projection, and loading updates do not rescan every message.
- Start the transcript at the bottom with `defaultScrollAnchor` and reset the
  follow pin immediately when the root/subagent context changes. Give each
  context a fresh scroll viewport identity so it cannot inherit an estimated
  offset from the previous session; keep the wheel monitor outside that
  replaceable viewport.
- Apply transcript scroller configuration directly to the scroll view and
  update an already-attached hierarchy synchronously. Start with SwiftUI's
  gutterless mode so the system "Always show scroll bars" preference cannot
  reserve a legacy scroller width for the first content layout pass.
- Settle the scroll position once more after the complete-history batch ends
  while the user is pinned to the latest content.

## Alternatives considered

- **Stop rendering incremental history pages.** Rejected because the complete
  transcript must remain progressively useful rather than blocking on the
  oldest page.
- **Keep calling `scrollTo` for every prepend.** Rejected because older rows
  change content height but not the tail the reader is following.
- **Use an animated scroll after each page.** Rejected because it makes the
  layout churn more visible and steals attention from the conversation.
- **Delay all content until history finishes.** Rejected because it removes the
  already-loaded recent tail and makes large sessions feel slower.

## Consequences

- Switching sessions follows the new transcript to its latest content, including
  when its initial empty state is replaced by a later history snapshot.
- Incremental older-history pages no longer trigger repeated tail jumps.
- Streaming assistant text and newly appended messages still follow the bottom
  while the user remains pinned.
- Users who scroll up keep their reading position while older pages load.
- Reduce Motion is unaffected because this path uses non-animated scrolling.
