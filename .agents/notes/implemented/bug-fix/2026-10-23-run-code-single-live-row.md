# Agent Note: Present tool executions as one latest-command status row

Status: implemented - every tool now collapses to one latest-command status row

Superseded in part by: [Stabilize live-session repair and execution feedback](2026-10-26-live-repair-tool-state-scroll.md).

## Problem

Tool execution presentation was split across two visual languages. Consecutive
`run_code` calls showed a `run_code ×N` count, while other tools used their own
state dots and `Name(argument)` labels. Diff cards opened by default, and other
collapsed rows exposed a two-line output summary. The count and per-tool chrome
are implementation detail rather than useful task information, and the mixed
rows make a tool-heavy turn feel like a dashboard instead of one execution
stream. During a run, the user mainly needs to know the current or most recently
executed instruction.

## Decision

- Render single and consecutive tool calls with the same collapsed status row.
- Use one fixed terminal glyph for every tool and nested command.
- Show the concrete instruction directly instead of a generic `工具执行`,
  `执行记录`, or completion label.
- Store each top-level tool call's raw arguments and resolve instruction titles
  from real command, path, pattern, URL, patch, or other semantic fields.
- Flatten `run_code` into its child tool calls instead of presenting the parent
  script as the instruction.
- Show the latest running or last completed command title; before a nested
  command starts, fall back to the parent tool description.
- Remove call counts and collapsed output summaries.
- Show an animated `运行中` accessory while an instruction is active and
  `有失败` only on failure; completed instructions add no status copy.
- Use the same three-bar activity waveform for running instruction rows and
  running sessions in the sidebar, with an explicit `运行中` label.
- Keep expanded instruction identity and disclosure state stable while output
  and image attachments arrive, fading updates in place without rebuilding the
  row.
- Expanding the outer row reveals instruction rows only; it does not flatten
  every tool result into the transcript.
- Cap the instruction list at the same `320pt` adaptive height as result panes;
  overflow scrolls inside the list.
- Keep every instruction, including diff cards, collapsed until that
  instruction is expanded.
- Size expanded content to its measured height and cap it; only content beyond
  the cap scrolls inside the detail pane.
- Keep the full call sequence, source, nested commands, and outputs available
  only after the relevant instruction is expanded.

## Alternatives considered

- **Keep the count but hide it behind hover.** Rejected because the row still
  communicates execution volume instead of current work.
- **Keep per-tool glyphs for faster recognition.** Rejected because tool type is
  already named in the command detail, while the icon changes add noise and
  break the stable status-bar rhythm.
- **One visual icon per nested tool.** Rejected because it creates noise and
  splits attention when the nested tools are implementation detail.
- **Show every command in the collapsed transcript.** Rejected because it
  recreates the ladder of rows that grouping was intended to remove.
- **Auto-expand diffs.** Rejected because the transcript should disclose detail
  consistently on demand instead of allowing one card kind to dominate the turn.
- **Give every expanded detail the same fixed height.** Rejected because short
  output then carries empty space; the pane should hug short content and cap
  only long content.
- **Show status and completion labels in each instruction row.** Rejected
  because the command itself is the useful information, and generic status copy
  adds a second visual level without helping users scan execution.
- **Use `{}` or a generic label such as `执行代码` when a title is absent.**
  Rejected because the raw arguments and child tool calls contain the actual
  action. Missing data is omitted until the real instruction arrives instead of
  showing incomplete meaning.

## Consequences

- Collapsed rows contain no call counts or output excerpts.
- Running and failed states remain explicit; completion remains visually quiet.
- Running session rows no longer depend on a static color dot; continuous
  motion plus text makes background Host activity visible while scanning.
- Every tool uses one stable terminal glyph.
- The outer disclosure shows the concrete instruction first.
- Top-level tool arguments are retained so instruction labels do not depend on
  whether the Host render view happens to include a title.
- `run_code` instruction rows represent its child tool calls, with titles
  extracted from the child arguments.
- The detail switches to the latest running or last completed command, with the
  parent description as the pre-child fallback.
- Outer expansion exposes one compact row per instruction without printing any
  results and scrolls internally after `320pt`.
- Expanding an individual instruction preserves its complete source, output,
  and structured details.
- Expanded details update in place when Host results arrive and honor macOS
  Reduce Motion.
- Short expansion hugs its content; expansion above the cap becomes an internal
  scroll region rather than growing the transcript without limit.
- Existing grouping and tool-detail data remain unchanged.

## Verification

The tool snapshot suite renders the collapsed stack, individually expanded
instruction details, and an expanded outer group whose instruction results stay
collapsed. Production source typechecking and design-system checks pass before
the Swift-only in-place refresh.
