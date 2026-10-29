# Sidebar — agent rules
Scope: the session list only — project grouping and folding, the 5-row preview, row selection and running markers, and the converged Host status line. Does not show workspace switching and does not send RPC directly.
Key files: `SidebarView.swift` (list, selection, Host status, primary New Session action), `SidebarSessionGroupView.swift` (per-project folding and the 5-row preview).
Invariants (each must cite a Note or test):
- Each project renders 5 sessions by default plus every running session past them, and the fold control only appears when collapsing would actually hide rows — source: `macos/DSHTests/DSHSidebarTests.swift` ("Sidebar session paging never folds a running session", "Sidebar fold control hidden when collapsing removes nothing").
- Fold state lives only in the current app session; a restart returns to the 5-row default — source: `macos/DSHTests/DSHSidebarTests.swift` ("Sidebar session paging defaults to five and expands all").
- The sidebar shows only failure / action-required states and hides routine sync and reconnect copy — source: `macos/DSHTests/DSHHostProtocolTests.swift` ("Sidebar Host status hides routine success states").
- The sidebar no longer shows workspaces; it is back to the single responsibility of a session list — source: `feature/2026-08-17-workspace-chips-git-worktree.md`.
- The running marker is the shared `DSHActivityLine` at the row's bottom edge, on `DSHTheme.running` (≥3:1 against `sidebarBg`) with no text — never a second dot component — source: `scripts/test-design-system.sh` ("DSHActivityLine(active: true, color: DSHTheme.running)").
- The running line keeps the transcript's 1.2pt geometry and Reduce Motion cut-out — source: `macos/DSHTests/DSHSidebarTests.swift` ("Sidebar running line keeps its geometry and Reduce Motion cut-out").
- The 13pt gutter is unread-only; running does not claim it — source: `scripts/test-design-system.sh` ("selected and running sessions need distinct lightweight treatments").
- Rows are keyed by session identity, never by list position — source: `macos/DSHTests/DSHSidebarTests.swift` ("Sidebar visible rows keep session identity across an insert").
Before reporting done: `./scripts/test-design-system.sh` and `./scripts/test-macos-native.sh --unit`.
Pitfalls:
- A selected session past the fifth row is invisible to a user who has not expanded that project — source: `feature/2026-10-21-sidebar-project-session-folding.md`.
- Expanding a very large project adds noticeable sidebar layout work — source: `feature/2026-10-21-sidebar-project-session-folding.md`.
