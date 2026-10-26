# Agent Note: Session follow snapshots decode history records independently

Status: implemented - one malformed auxiliary field can no longer erase a session transcript

## Problem

Opening the largest recent session still showed only the local placeholder
even while the mux connection was healthy and smaller sessions loaded
normally. `session/follow` snapshots were decoded as one strict Decodable
value: one invalid projection, assistant-stream field, or record discarded the
entire snapshot before history folding ran. The durable session file contains
249 user/assistant messages, so the UI looked as if history had been deleted.

The sidebar also displayed routine success text such as `Host 已同步 37 个会话`,
which adds noise and can obscure actionable disconnect/error states.

## Decision

Keep strict whole-snapshot decoding as the fast path. If it fails:

- decode the snapshot envelope and header directly;
- decode every history record independently and skip only malformed records;
- decode projections and assistant-stream metadata as optional best-effort
  fields;
- continue folding and rendering all valid durable records.

Hide routine connection/sync success messages from the sidebar. Continue to
show startup, disconnecting, retrying, and failure states.

## Alternatives considered

- **Relax every nested model field to `Any`.** Rejected because it weakens
  type checks for all healthy snapshots and makes projection behavior harder
  to reason about.
- **Drop the whole snapshot but refetch with `session/page`.** Rejected as the
  primary recovery because page requests still need the same follow cursor and
  could encounter the same malformed auxiliary metadata.
- **Show partial decoding as an error and load nothing.** Rejected because the
  transcript records are independently valid and useful; auxiliary projection
  loss should not hide durable history.
- **Keep sync text but style it quietly.** Rejected because success state is
  already represented by the live interface and the text provides no action.

## Consequences

- Large sessions remain readable even when an unrelated snapshot field changes.
- Malformed individual records are skipped rather than blocking all history.
- Projection or assistant-stream metadata can degrade independently without
  affecting the transcript.
- The sidebar is quieter; disconnects, retries, startup, and failures remain
  visible.

## Risks

- A malformed record is silently omitted. Normal Host data should not trigger
  this; broader diagnostics could be added later if partial decodes become
  frequent.
- Losing a projection during fallback can temporarily clear dashboard metadata
  until the next valid projection frame.

## Verification

The affected session contains 249 user/assistant messages and reproduced the
blank transcript before this change. The resilient decoder test preserves a
valid record while deliberately corrupting the projection and assistant-stream
metadata. In the rebuilt app, the first session rendered its full run_code
history instead of the placeholder, and routine `Host 已同步` text was absent
from the sidebar. The full native suite passed 172/172 tests; app build, Host
smoke, bundle lint, and signature checks passed.
