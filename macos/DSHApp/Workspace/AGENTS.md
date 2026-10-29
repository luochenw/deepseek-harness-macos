# Workspace — agent rules
Scope: workspace preference persistence (including the explicit "no workspace" case), session cwd resolution and chips, Git branch/worktree operations, and opening paths through the Host. Does not rewrite the cwd of an existing session and does not put git state into the core controller.
Key files: `DSHWorkspaceActions.swift` (preference and cwd resolution), `DSHGitOps.swift` (branch and worktree operations), `NativeWorkspaceChips.swift` (chip row), `WorkspaceManagerView.swift` (attach/select/manage UI).
Invariants (each must cite a Note or test):
- The workspace preference persists "explicitly no workspace" with its own marker, and re-picking a directory clears it — source: `bug-fix/2026-08-27-no-workspace-selection.md`.
- The cwd of an attached session is durable and immutable; the header shows it and the picker only serves future sessions — source: `bug-fix/2026-10-22-existing-session-workspace-display.md`.
- A nil cwd on an attached session means the Host default directory and must not fall back to the Composer's pending workspace — source: `macos/DSHTests/DSHWorkspaceTests.swift` ("Conversation workspace treats nil attached cwd as Host default").
- The attached-directory list excludes only the current workspace — source: `macos/DSHTests/DSHWorkspaceTests.swift` ("Workspace context excludes only the active workspace").
- Session-to-workspace ownership compares session cwd, not `DSHWorkspaceView.sessionIds` — source: `feature/2026-08-17-multi-workspace-default-and-grouping.md`.
Before reporting done: `./scripts/test-macos-native.sh --unit` and `./scripts/test-attachment-rail-ui.sh`.
Pitfalls:
- If the default workspace directory is deleted by hand, the next launch still points at the dead path (current known gap) — source: `feature/2026-08-17-multi-workspace-default-and-grouping.md`.
- Deleting a workspace has no confirmation dialog; that is the current state — source: `feature/2026-08-17-workspace-add-switch.md`.
- Git status is view-local `@State`, not controller state — source: `feature/2026-08-17-workspace-chips-git-worktree.md`.
