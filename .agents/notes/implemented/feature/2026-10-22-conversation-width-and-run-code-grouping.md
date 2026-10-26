# Agent Note: Align composer width and group consecutive run_code calls

Status: implemented - composer and transcript share one reading measure and consecutive run_code calls reuse tool grouping

## Problem

The transcript centers its content at a 1040-point maximum width, while the
composer expands to the full conversation pane and uses a different horizontal
padding. On wide windows the input box and rendered answer no longer share an
edge.

The transcript fold logic explicitly excludes `run_code` from consecutive tool
grouping. A Code Mode turn can therefore produce a long ladder of `run_code`
rows even though the same sequence of `bash` or another repeated tool is merged.

## Decision

- Define one shared conversation content width and horizontal inset.
- Apply that measure and padding to both `ConversationView` and `Composer`.
- Remove the `run_code` exclusion from transcript folding.
- Reuse `ToolGroupRow`: its collapsed header shows the call count, while its
  expanded state lists each individual `run_code` row with the existing source,
  nested call, and output disclosure.
- Update fold and snapshot contracts so consecutive `run_code` calls are one
  group and non-consecutive calls remain separate.

## Alternatives considered

- **Give the composer an independent width.** Rejected because the two values
  would drift again on future layout changes.
- **Flatten all run_code details into one giant expanded panel.** Rejected
  because it removes per-program boundaries and makes nested calls ambiguous.
- **Merge every run_code in a turn regardless of intervening content.**
  Rejected because answers or other tool calls between programs describe
  separate execution segments.
- **Only merge terminal-style run_code summaries.** Rejected because it creates
  a second grouping model alongside the existing tool group.

## Consequences

- At narrow and wide widths, the composer card and transcript content use the
  same centered 1040-point maximum measure and 32-point horizontal inset.
- Consecutive `run_code` rows become one expandable tool group.
- Expanding the group exposes each original `run_code` row and its own details.
- A non-consecutive `run_code` sequence remains separate.
- Fold tests and the wide/narrow reasoning snapshots cover both grouping and
  the shared layout contract.
- A real 208-step Code Mode session rendered consecutive runs as
  `run_code ×6` and `run_code ×39`; expanding the 39-call group revealed the
  individual rows and their existing inline details.

## Risks

- A very long Code Mode turn still expands to many individual run_code rows;
  this is intentional because each program retains independent disclosure.
- The shared width constant changes composer layout on wide windows, so snapshot
  coverage must include both compact and wide widths.
