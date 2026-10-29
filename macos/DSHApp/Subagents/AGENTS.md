# Subagents — agent rules
Scope: the subagent catalogue and navigation, child context projection with sequence guards, the display selectors, and subagent tree traversal. Does not write child state back into the root session and gives children no mutable Goal/Plan/Queue control surface.
Key files: `DSHSubagents.swift` (catalogue and navigation), `DSHSubagentProjection.swift` (child context projection), `DSHSubagentTree.swift` (tree traversal).
Invariants (each must cite a Note or test):
- Child projection is isolated per child session; the root `activeTools`/`todos`/`goal` are never overwritten — source: `feature/2026-08-25-subagent-context-projection.md`.
- Projections apply per key against a sequence watermark, and a late stale frame must be dropped — source: `macos/DSHTests/DSHSubagentProjectionTests.swift` ("Subagent presentation rejects older projection frame").
- `displayedTools/Todos/Goal/PlanActive/QueueItems` are the only read source for Dashboard, GoalBar, Composer and QueueDock — source: `feature/2026-08-25-subagent-context-projection.md`.
- A child's Goal/Plan/Queue are read-only; the Host rejects changes with `agent-busy` — source: `macos/DSHTests/DSHSubagentProjectionTests.swift` ("One-shot subagent goal is read-only").
- Whole-tree traversal is capped at depth 6 / 200 nodes, and hitting the cap must be reported explicitly as truncation — source: `feature/2026-08-14-subagent-descendants-tree.md`.
Before reporting done: `bash scripts/test-subagent-context-ui.sh` and `./scripts/test-macos-native.sh --unit`.
Pitfalls:
- Queue/jobs snapshots carry no sequence number, so late stale snapshots cannot be rejected the way projections can — source: `feature/2026-08-25-subagent-context-projection.md`.
- Opening the whole tree costs one Host round trip per non-leaf node, so it is only suitable on demand — source: `feature/2026-08-14-subagent-descendants-tree.md`.
