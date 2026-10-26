# Agent Note: Audit adjacent DSH 0.2 event-shape drift

Status: implemented - current assistant chunks and job terminal states are normalized

## Problem

The `run_code` audit found a general class of bug: a valid DSH event is
received, but a decoder looks for an older field or event name and silently
drops it. Real session logs expose three more cases:

1. `assistant/chunk` with `chunk.type == "text-delta"` stores the fragment in
   `chunk.text`. The native stream only reads the older `chunk.textDelta`, so
   live text streaming is lost until the final assistant message arrives.
2. Some migrated or interrupted sessions contain no final `assistant/message`
   but do contain `assistant/chunk block-end` blocks or compact
   `text-chunks` / `reasoning-chunks` events. History folding ignores those, so
   the assistant response or reasoning disappears on reload.
3. A background job with status `stopping` is currently treated as succeeded,
   and `killed` is also treated as success. The UI therefore claims work
   completed before it stopped, or when it was cancelled abnormally.

Historical turns that end with `reason.kind == "error"` also lose their error
message after reload because history folding only resets tool state.
Slash-command run/result events and compaction summaries are appended locally
while live but omitted by history folding.

## Decision

Add one normalizer for assistant stream deltas that understands:

- current `text-delta.text` and legacy `textDelta`;
- `reasoning-delta.text`;
- `block-end` text/reasoning blocks;
- compact `text-chunks` / `reasoning-chunks` `texts` arrays.

Both live event handling and history folding use that normalizer. Block-end or
aggregate snapshots are appended only if the already-streamed suffix does not
contain the same content, avoiding duplication when deltas and final blocks
both exist.

Centralize background-job status mapping:

- `running`, `pending`, `queued`, `stopping` remain running;
- `completed`, `succeeded` complete;
- `failed`, `killed`, `cancelled` fail.

During history folding, a completed turn with an error reason appends a system
error row containing the durable error message.
History folding also reconstructs command input/result rows and persisted
compaction summaries.

## Alternatives considered

- **Continue relying on `assistant/message`.** Rejected because streaming
  feedback remains broken and incomplete sessions can have no final message.
- **Append every block-end after streamed deltas.** Rejected because current
  adapters emit both and would duplicate the assistant text.
- **Treat every non-running job status as success.** Rejected because it hides
  interruptions and renders stopping jobs as complete.
- **Special-case only `run_code`.** Rejected because assistant chunks, job
  states, and flat tool results are shared protocol surfaces.

## Consequences

- Current and legacy text-delta shapes stream into the active assistant row.
- Block-end-only and aggregate-chunk-only histories retain text and reasoning.
- Deltas followed by their matching block-end do not duplicate content.
- Stopping jobs remain running; killed/cancelled jobs show failure.
- A historical turn error produces a visible system error row.
- Reloading preserves slash-command input/output and compaction summaries.
- Existing tool-result tests and all native tests remain green.

Verification on October 21, 2026: real session logs contained 1,378 tool
results across both supported shapes with no missing call IDs; the raw DSH
0.2 text-delta field was confirmed as `text`. The complete native suite passed
161/161 tests, and the rebuilt app passed Host smoke, bundle lint, and signature
verification.

## Risks

- Block-end de-duplication is suffix-based; adapters that replay unrelated text
  without delimiters could still need a future per-block accumulator.
- `killed` is represented by the existing failed state because
  `ToolActivity` has no separate cancelled state.
