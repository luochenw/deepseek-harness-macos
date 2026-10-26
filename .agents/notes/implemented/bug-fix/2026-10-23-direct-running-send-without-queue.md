# Agent Note: Send directly when the running session has no queue

Status: implemented - empty-queue sends go directly to the current turn

## Problem

While a turn is running, the busy-Enter policy can choose the `queue` mode even
when no queued messages exist. The composer then reports “已排队” and exposes a
queue action even though there is nothing to queue behind. This adds latency and
feedback that contradicts the user's immediate intent.

## Decision

- If the root turn is running, steering is available, and the queue is empty,
  send the draft directly to the current turn.
- Keep the configured Queue/Steer preference for the case where at least one
  queued message already exists.
- Hide the queue button until the first queued message exists; the primary
  running action uses the normal Send symbol and sends directly.
- Debounce queue chrome for 300 ms. Host admission can briefly publish a
  steering submission through the queue snapshot; that transient frame must
  not render an “已排队” badge, dock, or queue button.
- Apply the same rule to wake-word/dialog voice auto-send: empty queue means
  direct current-turn submission, not `queueCurrent`.
- Keep explicit queue navigation for existing queued messages unchanged.

## Alternatives considered

- **Always steer while running.** Rejected because users with an existing queue
  still need to append behind it.
- **Ignore the busy-Enter setting entirely.** Rejected because it is useful once
  a queue exists.
- **Keep showing Queue disabled when empty.** Rejected because it is still
  misleading visual chrome and suggests the send was queued.

## Consequences

- Running with an empty queue and sending by Enter returns `steer`, not `queue`.
- The root queue action is absent while the queue is empty; the primary running
  action uses the normal Send symbol.
- A transient Host queue snapshot no longer flashes queue UI during direct
  steering.
- Running with queued messages continues to honor the configured preference.
- Voice auto-send uses direct steering when the queue is empty.
- Explicit queued-message navigation and continuable-subagent queue submission
  remain unchanged.

## Risks

- A user who explicitly wants to create the first queued message can no longer do
  so from the running composer; the new product rule treats empty-queue sends as
  immediate steering.

## Verification

Policy tests cover empty-queue direct steering, existing-queue preference, and
accelerated mode. Voice routing tests cover direct steering before queueing.
The permission/composer snapshot suite and 188 native tests passed, and the
composer UI test now guards the queue button's empty-queue visibility. In the
installed app, a running turn exposed only Stop and the direct Send action; the
Queue action was absent while its queue was empty.
