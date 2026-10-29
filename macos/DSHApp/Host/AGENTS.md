# Host — agent rules
Scope: the 0.2 transport contract (token→303→cookie, unary `{args}` calls, the `/api/remote.mux` logical stream), Host process supervision and restart, `host.json` publication, history paging and projection decoding. Renders no UI and decides nothing about session selection or scroll position.
Key files: `DSHHostProtocol.swift` (envelope types, `DSHHostClient` actor, `DSHHostRuntime`), `DSHHostGateway.swift` (auth transport and unary calls), `DSHEventSocket.swift` (long-lived push connections), `DSHHostSupervisor.swift` (restart policy and generations), `DSHHistory.swift` (session paging and projection decode), `DSHExternalAgentBridge.swift` (`host.json` publication for external agents).
Invariants (each must cite a Note or test):
- One authenticated transport: unary, Typert, download and WebSocket share the same `dsh-auth-*` cookie, and a 401 re-handshakes and replays once — source: `architecture/2026-08-28-dsh-0.2-protocol-migration.md` ("401 重新握手并重放一次").
- Never pick a same-named cookie out of the shared store, or multiple loopback Hosts cross over to a stale port — source: `architecture/2026-08-28-dsh-0.2-protocol-migration.md` ("不能再从全局 cookie 存储挑选同名 cookie").
- Request payloads are always `{args:{...}}` and responses are validated by `rpcId` — source: `architecture/2026-08-28-dsh-0.2-protocol-migration.md` ("{args:{...}}").
- A single `/api/remote.mux` carries `$events`, `workspace/follow`, `session/control` and root/subagent `session/follow` — source: `architecture/2026-08-28-dsh-0.2-protocol-migration.md` ("remote.mux").
- A follow first frame carries one message and one turn; full history goes through plain `session/page` because a WebSocket message has a size cap — source: `bug-fix/2026-10-23-progressive-large-session-history.md`.
- Supervision allows at most 5 restarts in 300s, backs off 1/2/4/8/16s, clears after stability and latches give-up past the cap; callbacks from an older generation are dropped — source: `feature/2026-10-27-external-agent-bridge.md`.
Before reporting done: `./scripts/test-macos-native.sh` and `./scripts/verify-native-host-api.sh <App>`.
Pitfalls:
- A dead mux is reconnected with a bounded retry that rebuilds the logical stream; never restart the Host process for it — source: `bug-fix/2026-10-21-host-mux-reconnect.md`.
- An oversized follow snapshot raises `Message too long` (Code=40), so history must not be packed into one WebSocket message — source: `bug-fix/2026-10-23-progressive-large-session-history.md`.
- A lost `turn/end` or a seq gap leaves `isRunning` stale; recompute from a snapshot or `session/list` — source: `bug-fix/2026-10-23-session-running-state-stale-after-reconnect.md`.
- `host.json` is written atomically with mode 0600, and removal must verify both `appPid` and `baseURL` — source: `macos/DSHTests/DSHExternalAgentBridgeTests.swift` ("host.json removal requires pid and baseURL").
- Archived sessions must be filtered at the list source: `session/list` itself never excludes them — source: `bug-fix/2026-08-17-sidebar-hide-archived-sessions.md`.
