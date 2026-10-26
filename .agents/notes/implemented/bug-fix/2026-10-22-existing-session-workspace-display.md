# Agent Note: Show the existing session's fixed cwd instead of the composer target

Status: implemented - attached sessions show their fixed cwd while workspace selection remains a new-session control

## Problem

The conversation header renders `harness.workspace`, which is the directory the
Composer will use when creating the next session. It is not the cwd of an
already-open session. After opening an old session, that global value may be
nil, so the header incorrectly says "无工作区 · Host 默认目录" even while the
session is grouped under and running in a real workspace directory.

The header's workspace chip remains interactive in that state, implying that
selecting another folder moves the open session. In DSH, a session header's
`cwd` is durable and immutable. Workspace attachment only validates that the
stored cwd exactly matches the workspace path; there is no Host operation that
rewrites it.

## Decision

- Derive a conversation workspace URL from the selected Host session's `cwd`.
  Only fall back to the Composer's `workspace` when no Host session exists yet.
- Render that path in the header. An attached session with no cwd explicitly
  means "Host 默认目录".
- For an attached session, remove the interactive workspace folder selector and
  imported-folder chips. Keep the branch/worktree chip because those actions
  operate on the session's fixed cwd.
- Keep the full workspace selector for new, not-yet-created conversations.
- Make file reveal/open helpers use the same conversation workspace resolution.
- Stop mutating a local session row's workspace name when selecting the
  workspace for a future session.

## Alternatives considered

- **Hide the workspace path for old sessions.** Rejected because the directory is
  important context for filesystem and terminal actions.
- **Let the picker update the old session.** Rejected because the Host has no
  supported session-cwd mutation and workspace attach rejects a different path.
- **Fork the session when the picker changes.** Rejected because a normal folder
  selection should not silently create a new conversation; fork also inherits
  the source cwd.
- **Continue mutating only the local row label.** Rejected because it makes the
  UI disagree with the durable Host session and session grouping.

## Consequences

- Opening a Host session with `cwd` displays that cwd regardless of the
  Composer's current new-session workspace.
- An attached session with nil `cwd` displays Host default directory.
- The interactive workspace picker is available only before Host session
  creation; attached sessions get a passive fixed-directory chip.
- Branch/worktree operations for an existing session use its stored cwd.
- Selecting a future-session workspace no longer rewrites the current session
  row.
- A live old session rendered its real `ds-harness` directory in both the header
  and passive folder chip, while keeping its `main` branch control available.
- The complete 178-test unit/snapshot suite, app build, and Host smoke passed.

## Risks

- Users who expect the picker to retarget an old session need an explicit
  explanation; the fixed-directory help text and documentation cover this.
- A deleted session cwd remains displayed as historical truth; the workspace
  chip already has missing-directory labeling for registry entries.
