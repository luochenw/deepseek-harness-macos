# Agent Note: Codex-style run_code details and per-turn duration

Status: implemented - run_code inputs, nested calls, outputs, and turn timing are visible

## Problem

The transcript renders every `run_code` call as almost the same generic row.
Even after result decoding was fixed, users still cannot tell what TypeScript
was executed, which SDK tool calls ran inside it, what each nested call
returned, or what the final program returned. This is far less informative
than Codex's command/tool transcript.

The transcript also has no per-turn execution time. Session-level LLM/tool
totals exist in Settings, but users cannot see how long the current request
actually took.

## Decision

Parse `tool/call.arguments` for `run_code` and create a dedicated code
presentation:

- the collapsed row shows the model-supplied description;
- expanded content shows the full TypeScript program;
- nested `tool/ptc-dispatch-start` / `tool/ptc-dispatch` events (and legacy
  `tool/code-dispatch-*` aliases) are tracked under the owning root call;
- each nested call shows its tool name, extracted command/path/query summary,
  state, and output;
- the final `run_code` result remains visible after the nested calls.

Record `turn/start.time` per session and, on `turn/end`, append a persistent
system row such as `本轮用时 1 分 12 秒`. History folding reconstructs the same
timing from durable event timestamps. If a session is opened mid-turn, the
active start timestamp is recovered from the follow snapshot so its eventual
duration is still correct.

## Alternatives considered

- **Show raw `run_code` JSON only.** Rejected because arguments/code are hard
  to scan and still hide nested command results.
- **Create one transcript row per nested tool call.** Rejected because it
  breaks the existing grouping and makes a single run_code program look like
  unrelated top-level calls. Nested calls belong under their root.
- **Use session-level `sessionStats` as "this turn" time.** Rejected because
  those values are cumulative across the whole session, not this turn.
- **Display only live timing.** Rejected because reopening history must retain
  the same information.

## Consequences

- A run_code row exposes its description without expanding.
- Expanded run_code shows source code, nested commands with arguments, nested
  output, and final output.
- Current and legacy nested dispatch event names both update the root call.
- Per-turn duration is computed from start/end timestamps and survives history
  reload.
- An in-progress turn opened from a snapshot gets a start timestamp and can
  report duration when it ends.
- Tool state, native tests, app build, Host smoke, and signature checks pass.

Verification on October 21, 2026: replaying the affected 57-call session
produced 57 individually rendered run_code rows, 130 nested child calls, 57
descriptions, 57 source programs, and 57 non-empty final outputs. All four
historical turns reported durations. Reopening and reconnecting the app kept
the same descriptions, nested commands, and outputs instead of degrading to
generic `run_code` rows. The complete native suite passed 169/169
tests, including the new run_code presentation snapshot; app build, Host smoke,
bundle lint, and signature verification also passed.

## Risks

- Very large run_code programs and nested outputs make the expanded view long;
  existing output disclosure limits remain in place.
- Nested call details are summarized from tool arguments. Unknown tools fall
  back to formatted JSON.
