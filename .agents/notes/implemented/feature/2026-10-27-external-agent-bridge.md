# Agent Note: External agents run through the App-owned Host

Status: implemented - the App publishes host.json and supervises its Host (auto-restart, exit with the App); scripts/ds-agent prefers the App Host, claims its own turn by requestId, can reattach, and falls back to headless

## Problem

Local external agents (for example Claude Code delegating work to DeepSeek
through a `ds-agent` launcher) could only use the bundled runtime's
`headless` profile. Headless mounts no Host, which causes three problems while
the App is open:

- Two writers share one DSH home. The headless process and the App's Host
  both persist sessions and indexes under the same `DSH_HOME`. A single run
  showed no conflict in testing, but this is not a supported arrangement.
- The run is invisible until it ends. `session/list` returns every persisted
  session and the sidebar groups by `cwd`, so a headless session does
  eventually appear. However, the App refreshes that list only after its own
  events, so a session created outside the App appears only after some later
  refresh. The user also cannot watch or stop the run in the App.
- Credentials and model choice have to be copied by hand. Headless disables
  the credential store and reads keys from the launch environment, so the
  launcher must lift the App's stored refs into the child environment and
  copy the model selection from the web profile itself.

## Decision

- **App side** (`DSHExternalAgentBridge.swift`, two one-line hooks):
  - When the persistent Host handshake succeeds in `startPersistentHost()`,
    write `{version, baseURL, token, appPid, startedAt}` to
    `<dshHome>/host.json`. The temp file is created with
    `O_CREAT|O_EXCL` and mode 0600, then moved into place with `rename(2)`.
  - Remove the file when the Host fails to start, in
    `stopForTermination()`, and when the Host process exits.
    `DSHHostRuntime.start(onReady:onExit:)` calls `onExit` on the main queue
    with the base URL that launch printed, and `handleExternalAgentHostExit`
    deletes the file only when both its `appPid` and its `baseURL` match. A
    late exit from a replaced Host therefore cannot delete a newer record.
    On a normal quit the file is already gone, so this second delete does
    nothing.
  - Refresh `refreshHostSnapshots()` when the App becomes active, debounced
    to once every 2 seconds.
- **CLI side** (`scripts/ds-agent` entry, `scripts/ds-agent-host.mjs`
  client):
  - Host mode runs when all four hold: `host.json` exists, its `baseURL` is a
    loopback origin, `appPid` is alive, and the token handshake succeeds.
    `parseHostBaseURL` accepts only `http:` with host `127.0.0.1`, `::1` or
    `localhost`, an explicit port, and no userinfo, path, query or fragment.
    This check runs before any request, so the token is never sent to another
    host. An invalid file makes automatic mode fall back to headless with a
    stderr note; with `--host` the CLI exits 1 and names the reason.
    The flow is:
    1. `session/create {cwd}`, skipped when `--session-id` is given.
    2. `session/prompt`.
    3. Poll until the turn settles.
    4. `session/page`, taking the text blocks of the turn's last
       `assistant/message` as the reply.
  - Otherwise the CLI uses the previous headless path unchanged.
  - `--host` and `--headless` force a mode. SIGINT and SIGTERM send
    `session/cancel`.
- **Host supervision** (`DSHHostSupervisor.swift`; this is a product
  behaviour change the user approved):
  - Every launch goes through `launchHost(generation:)`, which is the only
    place a `DSHHostRuntime` is created. `startPersistentHost()` allows one
    launch at a time: a launch in flight, a live Host, a pending backoff or
    the give-up state all stop a second one.
  - Callbacks carry their launch's generation. A superseded launch's
    `onReady` only stops its process. Its `onExit` only retracts its own
    `host.json` (exact `baseURL` match, skipped when the current Host reuses
    that port).
  - An unexpected exit, or a launch that fails (timeout, handshake, non-zero
    exit), stops the process and counts one failure per launch. The two
    callbacks of one launch never count twice.
    - Backoff: 1/2/4/8/16 s, at most 5 restarts within 300 s. The 6th
      failure gives up and shows 「Host 多次异常退出，自动重启已停止（连续失败 6 次），请点击『重新连接 Host』」.
    - 45 s connected clears the count.
  - 「重新连接 Host」 calls `manualHostReconnect()`. It cancels a pending
    backoff, clears the count, and either reconnects streams to a live Host
    or relaunches a dead one. During a launch it only shows 「Host 正在启动，请稍候…」.
  - `stopForTermination()` makes the supervisor inert first, so quitting
    never triggers a restart.
  - The dead Host's event socket is `detach()`ed before it is stopped, so its
    close callback cannot overwrite the supervisor's status text.
    `DSHHostSync.swift` (which has the user's uncommitted edits) is
    untouched.
- **Host exits when the App dies.** Today's macOS 27 crashes left the Host
  orphaned (ppid 1). It kept running turns and held session write locks, so
  the next App's Host got `writer-held`. `DSHHostRuntime.launchArguments`
  now starts node with `--import data:text/javascript;base64,…`, a watchdog
  that runs inside the Host process:
  - It polls `process.ppid` every second. When the parent changes, it stops
    the timer and sends itself **one** SIGTERM.
  - One signal matters: dsh's `createProcessShutdown().interrupt()`
    force-exits on a second signal and skips `dispose`.
  - A 10 s `process.exit(1)` backstop runs after dsh's own 5 s shutdown
    timeout.
  - No runtime patch is involved.
- **Claiming our own turn by `requestId`.** The real Host stores the
  `requestId` of `session/prompt` in the persisted `user/message` event as
  `data.source.rpcId`. The transport envelope's `rpcId` is not echoed.
  `claimTurn` finds that message, takes the turn number from the closest
  preceding `turn/start`, and then accepts only `assistant/message` and
  `turn/end` events whose `data.turn` matches. The turn is done when our own
  `turn/end` appears, and the reply is the last non-empty assistant text of
  that turn. `session/page` returns windows of whole turns, so once a later
  turn opens, ours slides out of the window. `claimWithBackfill` then pages
  backwards until our turn is covered again.
- **Fallback completion rule** (a Host that does not echo prompt ids): the
  session is idle, and either the turn outline grew or the client saw the
  session go from running to idle. The CLI prints one stderr warning when it
  switches to this rule. Outline growth alone is not enough, because the
  Host appends the outline entry at `turn/start`.
- **Full reply source**: `turnOutline[].response` is a clipped preview (120
  characters), so it is never used as the reply.

## Alternatives considered

- **Keep headless and add a periodic refresh.** Rejected: sessions would show
  up, but two writers would still share the DSH home and the run still
  couldn't be watched live.
- **Edit `workspace.json` to attach sessions.** Rejected: it bypasses the
  registry's consistency and recovery rules and races the live Host. It is
  also unnecessary, because the sidebar groups by `cwd`, not by
  `sessionIds`.
- **Let ds-agent boot its own Host.** Rejected: while the App runs, two Hosts
  would share one DSH home, which is worse than headless.
- **Add a new socket or proxy service inside the App.** Rejected: it would
  need new authentication and a new protocol. The Host already serves
  loopback RPC with a token-to-cookie handshake; `host.json` only hands that
  existing credential to processes of the same user.
- **Use `turnOutline[].response` as the reply.** Rejected: it is a clipped
  preview, so long replies would be cut off.
- **Treat the first outline entry after the baseline as our turn.** This was
  the first-round rule. Rejected: with prompts queued on one session it
  claimed another client's reply. In a real-Host race, two `ds-agent`
  processes both printed the same answer.
- **Claim by the transport `rpcId`.** Rejected: the Host does not echo it;
  searching a real page for it found 0 matches.
- **Retract `host.json` by checking `hostClient == nil` on activation.**
  Rejected: nothing ever sets `hostClient` back to nil, so that branch was
  dead code. The process termination handler is the reliable signal.
- **Watch the parent through a stdin pipe (EOF when the App dies).**
  Rejected: dsh never reads stdin, so it would still need code inside the
  Host. Polling `process.ppid` needs only an `--import` of a few lines and
  no runtime change.
- **Patch the dsh runtime to watch its parent.** Rejected: it would touch
  the runtime-patch pipeline, which another task is editing
  (`patch-llm-runtime.mjs`), and would need a runtime reinstall. The
  `--import` module stays inside the App's launch arguments.
- **Watchdog that keeps signalling every second until the process exits.**
  Rejected: dsh treats a second signal during shutdown as "force exit now"
  and skips `dispose`. The watchdog sends exactly one SIGTERM.
- **Let the existing stream-reconnect loop also restart the Host.**
  Rejected: that loop lives in `DSHHostSync.swift`, which has the user's
  uncommitted edits. Its retries would also race the backoff. The
  supervisor owns process restarts, and the stream path only calls the
  single-flight `startPersistentHost()`.

## Consequences

- **Trust boundary.** The token is a bearer credential for this Host. It
  lives in a 0600 file inside the 0700 DSH home, next to the 0600
  `.credentials.yaml` that holds the API keys. Any process of the same user
  can already read those keys and run dsh, so the file grants nothing new.
- **Stale file after a crash.** If the App is killed with SIGKILL, it leaves
  `host.json` behind. The CLI checks the pid and the handshake, and falls back
  to headless when either fails.
- **Host died but the App is alive.** The supervisor retracts `host.json`,
  clears `hostClient`, and restarts the Host with backoff. A new `host.json`
  is published when the new Host is ready. While no Host is up, the CLI
  falls back to headless.
- **Continuing a busy session** now works. A prompt queued behind another
  client's turn waits for its own `user/message` and claims only its own
  turn.
- **CLI waiting and reattaching.**
  - The CLI waits with no limit by default. `--timeout 90s|30m|2h|<ms>`
    (or `DS_AGENT_TIMEOUT_MS`) sets one.
  - A timeout never cancels the turn. It prints the session id, the
    requestId and a ready-to-run `ds-agent --attach <sid> --request-id <id>`.
  - `--attach` never sends a prompt:
    - With a requestId it claims exactly that turn.
    - Without one it waits for the running turn and returns the last turn's
      reply.
    - It fails with a non-zero exit, never "empty reply and exit 0", when
      the turn cannot be found or settled.
  - `--json` guarantees only the first line (`session`) and the last line
    (`final`, carrying the `requestId`). A `prompt` line may appear in
    between.
- **CLI interrupt only touches our own turn.** The requestId is generated
  before the prompt is sent. On SIGINT/SIGTERM:
  - If our item is still queued, the CLI removes it.
  - If the open turn is provably ours, it cancels it.
  - Otherwise it cancels nothing and suggests `--attach`, so another
    client's turn on the same session is never cancelled.
- **SIGKILL escalation for a wedged Host.** `DSHHostRuntime.stop()` sends
  SIGTERM, then after `terminateGracePeriod` (8 s) sends SIGKILL if that same
  `Process` is still running. The closure captures the `Process` itself, not
  the runtime, so it still fires after the supervisor has dropped the
  runtime. A first version captured `[weak self]` and never fired on the
  paths that needed it. `killProcess` is a replaceable seam for tests.
- **Merging into the main working tree** needs two hand merges:
  - `stopForTermination()`: the crash fix adds `nativeAlerts.detach()`; keep
    the supervisor-first order.
  - `DSHTestsMain.swift`: add `dshConversationScrollStabilityTests` to the
    chunked `+=` list.
- **Verification.**
  - `node --test scripts/ds-agent.test.mjs` passes 21 cases against a fake
    Host.
  - `./scripts/test-macos-native.sh`, `./scripts/build-macos-app.sh` and
    `--smoke` pass.
  - End to end against the built App on the real DSH home:
    - `host.json` is published about 3 seconds after launch, with mode 0600
      and the App's pid.
    - A read-only task with tool calls runs through the Host and returns its
      full multi-paragraph reply.
    - `--session-id` continues that session through the Host.
    - Quitting the App removes `host.json` and leaves no temp files.
    - With the App closed, the CLI falls back to headless, and `--host` exits
      1 with a clear message.
  - Not verified: the sidebar itself, both the session appearing while the
    App is open and the refresh on activation. This build session had no
    screen-recording or accessibility permission, so these need a visual
    check.
- **Round 2 verification** (Host exit retracts the file, loopback `baseURL`,
  claiming by `requestId`).
  - `node --test scripts/ds-agent.test.mjs`: 30/30 pass. The new tests cover
    5 valid and 13 invalid `baseURL` values, rejection before any handshake,
    two clients racing one session in a one-turn window, a prompt queued
    behind another turn, backwards paging, and the warning for a Host that
    does not echo ids.
  - `./scripts/test-macos-native.sh` (main.swift 485/489),
    `./scripts/build-macos-app.sh` and `--smoke` pass.
  - End to end on the round-2 build, real DSH home, with the worktree's
    `scripts/ds-agent`:
    - `host.json` has mode 0600 and the new App's pid.
    - A single turn goes through the Host.
    - `--session-id` continues the session.
    - A slow turn (`sleep 20`) and a fast turn queued 4 seconds later on the
      same session each print their own reply.
    - `--host` with a non-loopback, path-carrying, userinfo-carrying or
      `https` `baseURL` exits 1 with the reason.
  - Per the coordinating session, a normal quit of the previous build removed
    `host.json`.
  - A read-only DeepSeek cross-review was interrupted by an App restart and
    then resumed in the same session. Claude checked each finding against the
    code:
    - Confirmed: the startup-failure branch above, and the Host not
      restarting after a crash.
    - Dismissed: the claim that a hint without a turn number makes the wait
      hang. Walking back finds our own `user/message` again; a fake-Host
      script returned `ended` with the right reply.
    - Recorded as low-priority suggestions: a `migration-required`
      projection has no `asOfSeq`; `onReady` may run off the main thread
      (this predates the change).
  - Not verified on the real App: the Host process dying while the App keeps
    running. Testing it means killing the Host, which leaves the App unusable
    until relaunch, so it was only covered by DeepSeek's `/bin/sh` fake-Host
    run of `DSHHostRuntime` (`onExit` fired once with the right URL). The
    sidebar behaviour also still needs a visual check.
- **Round 3 verification** (supervisor, watchdog, CLI timeout and attach).
  - `env -u DS_AGENT_TIMEOUT_MS node --test scripts/ds-agent.test.mjs`:
    55/55.
  - `heavy-gate.sh ./scripts/test-macos-native.sh --unit`: 211/211, including
    the type check, snapshots and main.swift 485/489.
    `DSHExternalAgentBridgeTests.swift` covers the following, calling the
    production `DSHExternalAgentHostFileStore` and `hostLaunchDidExit`:
    - publish/remove, including a 0600 file;
    - the restart tracker;
    - counting a launch failure once in either callback order;
    - stale-exit retraction, including port reuse;
    - the watchdog payload;
    - SIGKILL escalation after the runtime is released, using a real child
      that ignores SIGTERM.
  - A one-off real-process check with the bundled node v24.13.1: after the
    parent was killed with `kill -9`, the child noticed the ppid change
    within about 1 s, sent itself SIGTERM, and exited.
  - Two read-only DeepSeek cross-reviews, one of rounds 2 and 3 and one of the
    fix increment. Both hit their time caps and delivered through report-only
    turns. Claude ruled on every finding against the code; the confirmed ones
    were fixed in two headless fix rounds.
  - `DSHHostSync.swift` and `main.swift` match HEAD, and nothing on the
    main-tree dirty list was touched.
  - Not verified on a real App: auto-restart after killing the Host, the
    give-up text in the sidebar, the watchdog under a real App crash
    releasing the session lock, and the sidebar refresh. These wait for the
    merged build and the user's OK. Not verified at all: whether dsh's
    `dispose` releases the session write lock within its 5 s shutdown
    window.
