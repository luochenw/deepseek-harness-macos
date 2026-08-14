# Agent Notes

A lightweight decision-record convention, adapted from the much more
elaborate one in the upstream [deepseek-ai/deepseek-harness
`.agents/notes/`](https://github.com/deepseek-ai/deepseek-harness/tree/main/.agents/notes)
(this app is a client for). We keep the parts that scale down to a
single-app repo — the path-encoded lifecycle/class, the mandatory header,
the mandatory `## Alternatives considered` — and drop the parts built for a
large team (automated format gates, the `rejected/`/`archived/` lifecycle
stages, bilingual sidecars). See [CLAUDE.md](../../CLAUDE.md) for when to
write one.

## Layout

`{lifecycle}/{class}/yyyy-mm-dd-topic-title.md`

- **Lifecycle**: `proposed/` (not yet built) or `implemented/` (shipped —
  kept in sync with what actually shipped).
- **Class**: `feature`, `bug-fix`, `simplification`, `architecture`,
  `process`.

## Format

```markdown
# Agent Note: <title>

Status: proposed | implemented

## Problem
## Proposal            (proposed) — future tense, what to do
## Decision             (implemented) — present tense, what shipped
…bespoke technical sections as needed…
## Alternatives considered   — mandatory: each rejected option + why
## Acceptance criteria / Risks   (proposed)
## Consequences                  (implemented) — what the trade-off cost and bought
```

Moving `proposed/` → `implemented/`: rewrite `## Proposal` into `## Decision`
(present tense), fold `## Acceptance criteria` / `## Risks` into
`## Consequences`, update `Status:`.
