# Agent Note: Load large session history progressively

Status: implemented - live tail and complete HTTP history load independently and progressively

## Problem

Opening a large persisted session leaves the transcript on
“正在补齐更早的会话历史” indefinitely. Unified logs show the authenticated
`api/remote.mux` WebSocket repeatedly failing with
`NSPOSIXErrorDomain Code=40` / `Message too long`, followed by another reconnect
roughly once per second.

`URLSessionWebSocketTask` buffers a complete logical WebSocket message before
returning it to `receive`. A `session/follow` opening snapshot packages its
history window into one logical item, which can exceed the task's default
message-size ceiling even though the Host and session data are healthy.

The product requirement is still to expose the complete transcript. The
problem is coupling “start the live session” to “deliver a potentially huge
history window in one WebSocket message”.

## Decision

- Keep the `session/follow` opening snapshot minimal: one message, one turn,
  enough to establish the durable cursor and current tail.
- Load the rest of the transcript through ordinary `session/page` HTTP calls,
  which are not constrained by the WebSocket logical-message ceiling.
- Prepend each returned page to the transcript as soon as it is folded instead
  of retaining every page and publishing only after the whole history finishes.
- Keep already loaded messages and the composer usable while older pages load;
  show a compact progress row above the transcript.
- Finish with the complete message array, preserving the existing requirement
  that every history message is available after loading completes.

## Alternatives considered

- **Raise the WebSocket maximum message size.** Rejected as the product fix: it
  only postpones the next large-frame failure and still makes opening the
  session depend on allocating and decoding one oversized message.
- **Show only the latest window permanently.** Rejected because the user still
  needs access to the complete transcript.
- **Require manual “load older” gestures.** Rejected because the product should
  complete history automatically; pagination is an implementation detail.
- **Accumulate every page and prepend once at the end.** Rejected because a
  large session shows no progress and offers none of the loaded history until
  the final page arrives.
- **Replace `URLSessionWebSocketTask` with Network.framework.** Rejected because
  changing the transport does not remove the oversized-message design flaw.

## Consequences

- The follow opening snapshot requests one message and one turn, so the live
  cursor is no longer coupled to a large multi-turn history bundle.
- The current tail becomes visible immediately and the composer remains usable
  while older HTTP pages load.
- Each older page is merged into the transcript as it arrives; every history
  message still becomes available when loading completes.
- A 15-second no-progress watchdog releases the loading indicator so a stalled
  request cannot make the session look permanently unavailable.
- Unit tests cover the opening payload, incremental merge, loading presentation,
  and watchdog generation boundaries.

## Risks

- A single unusually large current message can still exceed a transport limit;
  this is narrower than bundling an entire multi-turn history window but may
  require a future Host-side frame-splitting contract.
- Incrementally prepending pages can shift the scroll position while the user is
  reading older content; the compact loading state and follow behavior need
  visual verification on a large session.

## Verification

The previously stuck 17-turn session became interactive within about one
second. Scrolling to the top reached its earliest
`Generate an SVG of a pelican riding a bicycle.` message, the loading indicator
cleared, and the clean installed process produced no `POSIX 40` /
`Message too long` WebSocket logs. The no-arg native contract and snapshot suite
passed after the change.
