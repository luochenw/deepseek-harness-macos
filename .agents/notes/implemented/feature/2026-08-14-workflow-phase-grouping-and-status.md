# Agent Note: Workflow card groups members by phase and uses the real outcome/stopReason vocabulary

Status: implemented

## Problem

`NativeDashboard.swift`'s `WorkflowCard` rendered `run.members` as one flat
list regardless of `member.phase`, and status was a bare, un-normalized
string: `Text([member.phase, member.outcome].compactMap { $0 }.joined(separator: " · "))`
for members, and `Text(run.stopReason ?? "运行中")` for the run — whatever
raw wire string arrived was shown verbatim, with only a binary
nil-vs-non-nil color distinction (blue vs. secondary), not a real
running/completed/failed/cancelled status.

## Decision

Verified the actual wire vocabulary against the upstream source before
building a status mapping (`packages/workflow/workflow/src/types.ts` in the
local reference checkout — not guessed): `WorkflowAgentOutcome = 'completed'
| 'failed' | 'cancelled'` (member-level, absent while running) and
`WorkflowStopReason = 'completed' | 'cancelled' | 'error'` (run-level,
absent while running).

Added `HarnessController.WorkflowRun.Status` (`running | completed | failed
| cancelled`) as a computed property on both `WorkflowRun` and
`WorkflowRun.Member`, mapping `stopReason`/`outcome` through that exact
3-value-plus-running vocabulary — `nil` outcome/stopReason means running,
`"error"` stopReason maps to `.failed` (member outcome has no `"error"`
value; run stopReason has no `"failed"` value — the two wire vocabularies
are similar but not identical, and the mapping keeps them distinct rather
than assuming they line up).

`WorkflowCard` now groups `run.members` by `phase` (a small local grouping
helper preserving first-seen phase order — phase names aren't a known
closed set, so this doesn't hardcode one) and renders each phase as its own
labeled sub-section within the run's `DisclosureGroup`, with a status
dot+color+label (run and each member) instead of a raw string.

## Alternatives considered

- **Invent a 5-value status enum matching the web client's
  `WorkflowRunStatus` (`running|completed|failed|cancelled|interrupted`)
  mentioned in prior research.** Rejected once the actual wire types were
  checked: there is no `interrupted` outcome or stop reason in the Host's
  `tool-workflow` event data this native client receives — that value (if
  it exists) belongs to a different, richer status computation the web
  client's own `WorkflowRunPanel.tsx` builds client-side, not something the
  wire vocabulary hands over directly. Matching wire reality here rather
  than a remembered web-side abstraction avoids introducing a state
  (`.interrupted`) that could never actually be reached, which is worse
  than not having it.

## Consequences

Workflow members are now grouped the way the workflow tool actually phases
them, and status is a real, normalized 4-state value with consistent
icon/color/label instead of a raw wire string users had to already know how
to read. No Host protocol change — this is a display-layer fix using data
already received (`tool-workflow/agent-start`'s `phase` field was already
captured into `Member.phase` but never grouped on).
