# Sessions — agent rules
Scope: session CRUD/fork/archive, running-state reconciliation, permission projection and defaults, goal/plan/queue mutation routing, approval and question sheets, and the dashboard cards. Does not render the transcript body and does not manage draft input or attachments.
Key files: `DSHSessionLifecycle.swift` (create/switch/fork/archive), `DSHRootSessionScope.swift` (state of the open session), `DSHSessionActivity.swift` (background sessions, request sources), `DSHSessionActions.swift` (session command surface), `DSHPermissions.swift` (permission projection), `DSHSessionOps.swift` (ops sheet), `NativeDashboard.swift` (dashboard cards), `QuestionBatchSheet.swift` (batched question UI), `DSHNewChildSession.swift` (子会话委派模板与发送).
Invariants (each must cite a Note or test):
- Switching sessions clears the root display state synchronously, and async callbacks validate the session id they started with — source: `bug-fix/2026-08-27-session-workbench-lifecycle-hardening.md`.
- Dashboard, GoalBar and QueueDock read the `displayed*` selectors only and never fall back to the root session — source: `scripts/test-subagent-context-ui.sh` ("harness.displayedTodos").
- Subagent context is read-only: every goal/plan/queue mutation entry point is guarded — source: `feature/2026-08-25-subagent-context-projection.md`.
- The permission projection carries a sequence watermark so stale snapshots are rejected, and full access always goes through the native risk confirmation — source: `feature/2026-08-27-native-permission-and-running-input.md`.
- `reconcileRootSessionRunningState` is the only writer of root running state, and only Host reports move the sidebar summary, so a late local completion cannot clear another client's turn; opening a session moves only the displayed flag — source: `architecture/2026-11-01-session-timeline.md` and the gate in `scripts/test-macos-native.sh`.
- Fields that describe the open session live in `DSHRootSessionScope`; a switch replaces the whole scope — source: `macos/DSHTests/DSHSessionActivityTests.swift` ("Switching sessions clears everything in the root scope").
- A session finishes through Host status or the session list, never a `turn/end`, because only followed sessions receive events; `sessionDidFinish` is the one place a finished run is announced — source: `macos/DSHTests/DSHSessionActivityTests.swift`.
- Lists apply in request order and never overrule a status newer than their request — source: `macos/DSHTests/DSHSessionActivityTests.swift` ("List responses apply only in request order").
- Approvals, questions and Host errors name or reach their own session — source: `macos/DSHTests/DSHSessionActivityTests.swift`.
- Running state is reconciled from three paths (snapshot/status/Stop) rather than waiting for `turn/end` alone — source: `macos/DSHTests/DSHPermissionAndSubmissionTests.swift` ("Root running reconciliation clears a displayed stale session").
- The 新建子会话 entry is offered only at a top-level session, and its delegation instruction carries the user's task verbatim — source: `macos/DSHTests/DSHSubagentProjectionTests.swift` ("New child: delegation template keeps the task verbatim", "New child: entry is offered only at a top-level session").
Before reporting done: `./scripts/test-permission-composer-ui.sh` and `bash scripts/test-subagent-context-ui.sh`.
Pitfalls:
- Only `QuestionBatchSheet` remains for questions; do not resurrect the single `QuestionSheet` — source: `simplification/2026-08-14-remove-dead-question-sheet.md`.
- `session/queue` and `session/jobs` snapshots carry no comparable sequence number, so stale snapshots cannot be rejected the way projections are — source: `feature/2026-08-25-subagent-context-projection.md`.
- `subagent.history` loads only the most recent 100 entries — source: `feature/2026-08-25-subagent-context-projection.md`.
- Reopening an already-tracked session returns early and does not refresh the projection — source: `feature/2026-08-17-port-feature-completeness-branch.md`.
- When `cordis.patch.yml` is edited externally the toggle shows stale state until a tab switch — source: `feature/2026-08-17-cross-session-relay.md`.
