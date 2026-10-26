# Agent Note: Reconnect the remote mux and restore the active session follow

Status: implemented - closed Host mux connections now recover automatically

## Problem

The app says `Host 消息流已断开，正在等待重新连接`, but nothing schedules a
reconnect. `openHostSession` still changes the selected title and calls
`session/follow`, whose open frame is queued on the dead socket because
`DSHEventSocket` has already been stopped. The result is a session title with
only the local placeholder row and no history. Opening more sessions appears
to erase all history even though durable Host data is intact.

## Decision

When the mux closes, mark the Host disconnected, schedule bounded automatic
reconnect attempts with a delay, rebuild all logical streams, and re-subscribe
the selected root session. Reset retry accounting when `$events` reports
`ready`. Preserve the existing manual reconnect path and do not restart the
Host process for transport-only failures.

## Alternatives considered

- **Reconnect immediately on every close.** Rejected because a server crash
  would create a tight connection loop.
- **Poll `session/list` without restoring follow.** Rejected because history
  snapshots and live turn events require the mux stream.
- **Restart the Host process for every mux close.** Rejected because it would
  interrupt healthy turns and child processes.
- **Require the hidden dashboard button.** Rejected because session opening
  should recover history without requiring a diagnostic-panel action.

## Consequences

- A closed mux schedules automatic retries with no duplicate retry chains.
- Successful `ready` resets retry accounting.
- Reconnect re-subscribes the selected root session and reloads its snapshot.
- Switching to an ordinary session after reconnect shows durable history.
- Migration-required sessions still require explicit upgrade confirmation.
- Native tests, app build, Host smoke, and signature checks pass.

Verification on October 21, 2026: switching to an ordinary session reproduced
the title change with no history while the mux was disconnected. The final
build follows the automatic-retry path, reconstructs all streams, and resumes
the selected `session/follow`; in the installed app, the same session then
reloaded its durable `123` exchange and turn duration after automatic
reconnect. The full native suite passed 170/170 tests and the rebuilt app
passed Host smoke, bundle lint, and signature verification.

## Risks

- Five failed attempts cannot repair a Host process that exited; manual
  reconnect remains the explicit fallback.
- A reconnect can briefly show the prior local placeholder until the new
  snapshot arrives.
