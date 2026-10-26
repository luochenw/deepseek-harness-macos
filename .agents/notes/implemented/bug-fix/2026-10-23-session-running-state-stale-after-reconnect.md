# Agent Note: Reconcile stale session running state after reconnect

Status: implemented - snapshots, status events, Stop, and Refresh now reconcile running state

## Problem

The composer's running state can remain `true` after the Host turn has already
ended. This happens when `turn/end` is missed, the session follow stream reports
a sequence gap, or the UI reconnects while the Host is already idle. Follow
snapshots restore messages, tools, and turn timing but do not reconcile the
local `isRunning` flag.

The stale flag keeps the composer in its running controls: the Stop button is
shown, the normal Send button is hidden, and the text field cannot submit.
`session/cancel` is not a complete recovery path because the Host accepts the
request even when the Agent is already idle; an idle Agent emits no new
`turn/end` event to clear the stale UI state.

## Decision

- Treat the opening `session/follow` snapshot, and the history-page fallback,
  as authoritative for whether a turn is active: an unfinished `turn/start`
  means running; the absence of one means idle.
- Route `$events` `api-session/status` updates through the same reconciliation
  function; previously they updated only the local row and left the displayed
  root flag stale.
- Apply that result to both the local session row and the displayed root
  running flag.
- Reopen the selected root follow stream after a durable event sequence gap,
  matching the upstream reconnecting-reader behavior instead of leaving the
  stream canceled.
- Reconcile an idle current row during `session/list` refresh so the explicit
  Refresh action is also a recovery path.
- When a follow snapshot already contains messages, keep the transcript visible
  while older pages load and show only a compact progress row above it. The
  previous full-screen skeleton hid all already-loaded content during large
  history completion.
- After an explicit Stop request, perform a short bounded `session/list`
  reconciliation. Clear the stale running state only when the Host reports the
  session idle, so an actively winding-down turn still waits for its terminal
  event.
- Keep the existing subagent routing and terminal-event paths unchanged.

## Alternatives considered

- **Clear `isRunning` immediately on Stop.** Rejected because
  `session/cancel` acknowledges admission, not quiescence; doing so could let
  the UI claim the turn ended while tools are still winding down.
- **Wait only for `turn/end`.** Rejected because that is the missing event that
  caused the stale state.
- **Restart the Host process.** Rejected because the Host and durable session
  are healthy; only the client projection is stale.
- **Poll forever after Stop.** Rejected because it adds background traffic and
  hides a real Host failure. A bounded reconciliation is enough to recover the
  idle-agent and missed-event cases.

## Consequences

- Opening or reconnecting an idle session clears a stale Stop state and restores
  the normal Send controls.
- Opening a genuinely running session still shows Stop.
- Stopping an already-idle session clears the UI after the Host list confirms
  `running = false`.
- A follow-event sequence gap reopens the root follow stream instead of leaving
  the transcript and running state permanently stale.
- A long session with a partial snapshot remains readable while older pages are
  still loading.
- Unit tests cover displayed/background reconciliation, remote status events,
  and the Stop watchdog.

## Risks

- A stale `session/list` response could report a turn as running for a short
  time; the code only uses an idle result to clear, while terminal events remain
  authoritative.
- Reopening follow after a gap repeats snapshot work; this is bounded to one
  new opening and avoids a permanently dead logical stream.

## Verification

On the previously stuck session, the installed app showed no Stop control;
the composer accepted a test draft and enabled Send, then returned Send to
disabled after clearing the draft. The full native unit suite passed with
displayed-session, background-session, and remote-status reconciliation cases.
