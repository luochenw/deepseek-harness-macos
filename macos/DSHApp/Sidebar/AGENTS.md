# Sidebar — agent rules
Scope: the session list only — project grouping and folding, the 5-row preview, row selection and running markers, and the converged Host status line. Does not show workspace switching and does not send RPC directly.
Key files: `SidebarView.swift` (list, selection, Host status, primary New Session action), `SidebarSessionGroupView.swift` (per-project folding and the 5-row preview).
Invariants (each must cite a Note or test):
- Each project renders 5 sessions by default and shows the exact hidden count beyond that — source: `feature/2026-10-21-sidebar-project-session-folding.md`.
- Fold state lives only in the current app session; a restart returns to the 5-row default — source: `macos/DSHTests/DSHSidebarTests.swift` ("Sidebar session paging defaults to five and expands all").
- The sidebar shows only failure / action-required states and hides routine sync and reconnect copy — source: `macos/DSHTests/DSHHostProtocolTests.swift` ("Sidebar Host status hides routine success states").
- The sidebar no longer shows workspaces; it is back to the single responsibility of a session list — source: `feature/2026-08-17-workspace-chips-git-worktree.md`.
- Selection and running markers reuse theme tokens, and the running line is static under Reduce Motion — source: `scripts/test-design-system.sh` ("accessibilityReduceMotion").
Before reporting done: `./scripts/test-design-system.sh` and `./scripts/test-macos-native.sh --unit`.
Pitfalls:
- A selected session past the fifth row is invisible to a user who has not expanded that project — source: `feature/2026-10-21-sidebar-project-session-folding.md`.
- Expanding a very large project adds noticeable sidebar layout work — source: `feature/2026-10-21-sidebar-project-session-folding.md`.
