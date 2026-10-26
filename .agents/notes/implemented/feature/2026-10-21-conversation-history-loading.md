# Agent Note: Animated conversation-history loading state

Status: implemented - history loading uses an animated transcript placeholder

## Problem

Opening a Host session inserts a local system row while the durable history
snapshot is requested. On slower or large sessions this reads like an empty
conversation with permanent diagnostic text, even though loading is still in
progress. There was no visual distinction between a genuinely empty session
and one waiting for its history.

## Decision

Track history loading explicitly on each `Session`. The transcript renders a
dedicated animated skeleton while loading:

- a small progress spinner and short Chinese loading label;
- four breathing placeholder lines with staggered timing;
- the full skeleton when only the local-open placeholder exists;
- a compact reload indicator above existing messages when refreshing a loaded
  session.

The loading flag clears on snapshot success, history-page fallback success,
stream end, stream error, or snapshot mismatch. A genuinely empty durable
session therefore returns to the normal empty state rather than spinning
forever.

## Alternatives considered

- **Continue showing the local system-placeholder text.** Rejected because it
  looks like transcript content and makes a loading session resemble an empty
  session.
- **Use only `ProgressView`.** Rejected because a spinner alone does not occupy
  the transcript shape and makes layout jump more when history arrives.
- **Infer loading from `hostStatus`.** Rejected because global connection
  status is not session-specific and can remain synced while a per-session
  follow is still loading.
- **Delay rendering the conversation pane.** Rejected because it would cause a
  larger flash and prevent showing existing content during refresh.

## Consequences

- Large histories have immediate visual feedback without adding more status
  text to the composer or sidebar.
- Loading state is per session and survives switching without inheriting
  another session's state.
- The loading animation is limited to the transcript content area and is
  disabled by the combined accessibility label when appropriate.

## Risks

- If a Host follow request neither succeeds nor errors and projection metadata
  cannot drive the page fallback, the error/watchdog path must eventually
  clear the loading flag.
- Rapid session switching can briefly show the compact refresh indicator over
  already cached messages before the new snapshot arrives.

## Verification

The conversation snapshot suite now renders `conversation-loading.png` in
addition to wide/narrow reasoning views. The complete native suite passed
172/172 tests.
