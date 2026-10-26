# Agent Note: Keep a collapsed live activity status visible

Status: implemented - the collapsed turn status follows the latest live action

## Problem

The native transcript intentionally folds a turn's reasoning into one collapsed
row, but its live presentation is too narrow:

- the row is marked live only while its message is the tail and has no answer
  body;
- once text or a tool call arrives, the row immediately renders as a completed
  “思考过程” row;
- the collapsed preview only contains the latest reasoning line, not the
  latest tool or output action;
- an `assistant/message` containing reasoning and a tool call but no text does
  not settle the stream-only placeholder, so its final lifecycle is ambiguous;
- consecutive `run_code` calls collapse into a count without surfacing the
  latest call's title while work continues.

The transport already publishes dense reasoning deltas. The missing “dynamic”
feeling is therefore primarily a presentation bug, not proof that streaming is
absent.

## Decision

- Keep reasoning and tool sections collapsed by default.
- Keep one compact active status row live for the current turn until
  `turn/end`, even after answer text or tool calls begin.
- Continuously replace the status row's one-line detail with the latest action:
  reasoning line, streamed answer line, running tool title, or a neutral
  “继续处理中…” state.
- Use a subtle repeating pulse in the status icon so the row stays visually
  alive even when the detail text pauses.
- Let expanded reasoning remain the full chronological trace, but do not force
  it open. Size the expanded trace to its content and cap it at one maximum
  height; only content beyond that cap scrolls.
- Settle reasoning-only `assistant/message` events so the stream placeholder
  receives its durable id even when the model emitted no answer text.
- Show the latest running call's title in a collapsed execution status row
  without exposing a call count.

## Alternatives considered

- **Auto-expand all live reasoning.** Rejected because it turns a normal turn
  into a long wall of text and does not match the requested collapsed status
  bar.
- **Create one permanent reasoning row per step.** Rejected because it makes
  long tool-heavy turns noisy; one collapsed turn status is enough.
- **Add client-side artificial typing delay.** Rejected because the Host
  already emits dense deltas; fabricated latency would lag real output and
  complicate final-message reconciliation.
- **Leave completed rows unchanged.** Rejected because the row stops reporting
  the current action as soon as the first body/tool arrives.

## Consequences

- A live turn keeps one collapsed status row visible throughout reasoning,
  output, and tool execution.
- The row's detail changes with the latest action without expanding, and its
  sparkle pulses while the turn remains active.
- The row becomes a completed collapsed “思考过程” row after the turn ends.
- Reasoning-only assistant messages settle without leaving a streaming marker.
- Final assistant text no longer concatenates reasoning blocks into the answer.
- A running tool group exposes the latest call title while collapsed.
- Tests cover live-status selection, reasoning-only settlement, and dedicated
  live reasoning/tool snapshots.
- Short expanded reasoning hugs its content; long reasoning stops growing at a
  fixed maximum height and scrolls internally.

## Risks

- Updating a one-line preview on every token can cause excessive layout work;
  the row keeps a fixed line height and uses only a short latest-line slice.
- Expanded reasoning opens scrolled to its latest paragraph; users can then
  scroll independently inside the fixed-height pane.
- The latest action is inferred from message/tool order rather than an extra
  wire field; unknown interleavings fall back to “继续处理中…”.

## Verification

A real non-tool turn showed only `STREAM_STATUS_OK` in the final answer body,
with reasoning retained behind the collapsed “思考过程” row. The final native
suite passed all snapshots including `reasoning-live-status.png` and
`reasoning-tool-status.png`; unit tests passed 187/187.
