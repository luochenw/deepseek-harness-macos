# Agent Note: Collapsible sidebar projects with five-session previews

Status: implemented - project groups default to five rows and reveal sessions on demand

## Problem

The native sidebar renders every session in every workspace group. Large
projects such as `ds-harness` can contain dozens of sessions, pushing other
projects far below the fold. The group heading is static, so users cannot fold
an individual project after locating it.

## Decision

Render each project through a dedicated group view:

- the project heading is a button with a disclosure chevron and session count;
- collapsing the heading hides all rows in that project;
- an expanded project initially shows only its five most recent sessions;
- when additional sessions exist, show one trailing control such as
  `展开其余 21 个`;
- after expansion, the same control collapses back to five;
- group disclosure and session expansion state live in the sidebar for the
  current app session, so they survive streaming/session-list refreshes but
  reset to the compact five-row default on next launch.

## Alternatives considered

- **Collapse every project by default.** Rejected because it hides recent
  sessions and adds a click before the common action of opening a project.
- **Limit the overall sidebar list to five.** Rejected because the requirement
  is per project; one large project must not consume the other projects'
  visibility.
- **Persist expansion indefinitely.** Rejected because the requested default
  is five rows each time; a previous large expansion should not permanently
  recreate the original clutter.
- **Use `DisclosureGroup`.** Rejected because its system disclosure chrome and
  row padding do not match the existing custom sidebar style.

## Acceptance criteria

- A project can be collapsed and expanded from its header.
- Every project initially renders no more than five session rows.
- Projects with more than five sessions expose the exact hidden count.
- Expanding reveals all remaining sessions in the existing sorted order.
- Re-collapsing the project and reducing back to five are independent actions.
- Native tests, sidebar snapshots, app build, Host smoke, and signature checks pass.

## Risks

- Expanding a very large project intentionally increases sidebar layout work;
  `LazyVStack` remains the outer container.
- If the selected session is older than the fifth row, it is hidden until the
  user expands that project.

## Consequences

- Large projects no longer push every other project below the sidebar fold.
- Project collapse and session expansion remain independent and survive stream
  updates for the current app session.
- Restarting the app restores the compact five-session default.
- Project headings have a dedicated hover surface and counted badge; sessions
  are indented beneath the project with stronger selected-title weight.
- Selected sessions use a very light logo-color background and stronger title
  weight instead of an outline or side marker. A running session uses one
  short bottom line as a slow left-right shuttle; hover remains a separate
  neutral wash, and Reduce Motion leaves the running line stationary.
