# Agent Note: Resume live assistant streaming after revision gaps

Status: implemented - assistant chunks flow through gaps and reconnect snapshots

## Problem

The native client could display only the final assistant message even though the
Host emits dense `assistant-stream` frames. The follow stream received every
frame, but its numeric `revision` was decoded through the projection object
decoder. That decoder serializes with `JSONSerialization`, which rejects a
top-level number as an invalid JSON object, so every live Assistant frame failed
validation and was silently dropped. Two recovery guards also broke reconnects:

- any revision gap cancelled the entire session-follow stream;
- a missing/out-of-order attempt chunk permanently cleared the local attempt,
  and the reconnect snapshot's accumulated `activeAttempt.stream` was ignored.

The Host accumulator itself treats an invalid revision as a reset, not as a
fatal session failure. The native client was stricter than the protocol owner.

## Decision

Apply the Host accumulator's recovery semantics in the native client:

- a newer unexpected revision resets local assistant-stream position and does
  not cancel `session/follow`;
- a valid `start` frame begins a new attempt even after a gap;
- invalid chunk indexes reset only assistant-stream state, allowing the next
  valid generation to stream;
- snapshot `activeAttempt.stream` chunks are replayed immediately so opening a
  session mid-response shows the text accumulated so far;
- subsequent dense frames append to that replayed message through the shared
  assistant-stream normalizer;
- the in-flight assistant row shows a blinking accent cursor until the durable
  final message replaces it, making incremental delivery visually explicit.

## Alternatives considered

- **Cancel and reconnect on every revision gap.** Rejected because the Host
  explicitly resets its own accumulator and continues, and cancellation also
  blocks unrelated durable session events.
- **Wait for the final `assistant/message` only.** Rejected because it removes
  all token-by-token feedback and is the reported bug.
- **Render snapshot chunks as one final message.** Rejected because following
  chunks must continue in the same streaming row.
- **Keep round-tripping primitive numbers through the object decoder.**
  Rejected because a top-level JSON scalar is not a valid `JSONSerialization`
  object; typed reduction must happen directly on `DSHJSONValue`.

## Consequences

- A live chunk envelope decodes the current schema.
- Integer fields are read directly from JSON numbers without an invalid
  top-level `JSONSerialization` round trip.
- Snapshot active-attempt chunks decode in order.
- A revision gap resets local stream state without cancelling the session.
- Replayed snapshot chunks and subsequent live chunks update one assistant row.
- Full native tests, build, Host smoke, and signature verification pass.

Verification on October 22, 2026: a real XPA request emitted 336 text deltas.
The native UI exposed a partially rendered 216-line response before
`turn/end`, then continued to the complete 3892-character answer; the same
diagnostic earlier showed zero visible answer lines until settlement. Regression
tests cover primitive revision/index reduction as well as stream projection and
snapshot replay.

## Risks

- Missing a chunk after a revision reset can produce a partial row until the
  final durable assistant message replaces it.
- Snapshot replay relies on the Host's dense `nextIndex` ordering; duplicate
  chunks are rejected rather than merged.
