# Agent Note: Host startup had no timeout and a hung/failed startup offered no in-app recovery

Status: implemented

## Problem

`DSHHostRuntime.start(onReady:)` spawns the bundled `node .../dsh web`
process and waits for a `dsh web: http://127.0.0.1:<port>` line on stdout.
If that line never arrives and the process never exits (hangs — e.g. stuck
on a slow first-run install step, a wedged port bind, or any other startup
condition Host code might get into) `onReady` is simply never invoked.
`HarnessController.hostStatus` stays at its initial "正在启动持久 DSH
Host…" forever, with no failure state and no action for the user.

Even the cases that already reached `onReady(.failure(...))` (nonzero
process exit) landed in `hostStatus = "Host 启动失败：..."` — but
`NativeDashboard`'s only recovery button was gated on
`hostStatus.contains("断开")` ("disconnected"), a string that only appears
after a *successful* connection later drops. A startup failure or timeout
produces neither string, so the retry button never appeared for either case
— the only recovery was quitting and relaunching the app.

## Decision

`DSHHostRuntime.start` now arms a 20-second `DispatchWorkItem` when the
process launches. A `resolved` flag (set on the main-queue callback path
alongside the existing stdout-parsing / termination-handler code, so no new
synchronization primitive is needed — all three paths already run on
`DispatchQueue.main`) ensures `onReady` fires exactly once: whichever of
{ready line seen, process exited, timeout elapsed} happens first wins, and
the timeout closure calls `onReady(.failure(...))` with a
`URLError(.timedOut)` if nothing else resolved it first. The stdout
readability handler and termination handler both cancel the timeout item
before calling `onReady`.

`NativeDashboard`'s retry button condition changed from
`harness.hostStatus.contains("断开")` to
`harness.hostClient == nil || harness.hostStatus.contains("断开")` — it now
also shows whenever the Host has never successfully produced a client
(covers both the timeout and the pre-existing failure case), in addition to
the existing post-connection-drop case. `reconnectHostStreams()` already
handled `hostClient == nil` correctly (falls back to `startPersistentHost()`
instead of trying to reuse a socket), so no change was needed there.

## Alternatives considered

- **Retry automatically instead of surfacing a button.** Rejected for a
  first pass — an automatic retry loop needs its own backoff/give-up policy
  to avoid spinning forever on a persistently broken install, which is more
  design surface than this fix's scope. A manual retry button is the
  minimum viable recovery path; automatic retry can be layered on top later
  as its own decision.
- **Use a `Task`-based timeout (`Task.sleep` + `race`) instead of
  `DispatchWorkItem`.** Rejected only for locality — `DSHHostRuntime` is
  entirely `DispatchQueue`/`Process`-based already (no Swift Concurrency),
  and mixing in a `Task` here for one timeout would need its own
  cancellation wiring for no benefit over the `DispatchWorkItem` the class
  already uses this pattern for elsewhere (`HarnessController.forceStopDeadline`
  in `main.swift` uses the identical arm/cancel `DispatchWorkItem` idiom for
  the process-stop deadline — this fix matches existing style).

## Consequences

A hung Host startup now surfaces a failure state and a working retry button
after 20 seconds instead of leaving the user staring at "正在启动…"
indefinitely with no recourse but force-quitting the app. No change to the
success path's timing or behavior.
