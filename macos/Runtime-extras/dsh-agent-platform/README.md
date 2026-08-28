# DSH Agent Platform Runtime

Bundled Host plugin for the native macOS Agent platform:

`AgentProfile -> RuntimeAdapter -> RuntimeContext -> AgentRun -> AgentBatch`

The Host owns persistence, scheduling, isolated execution workspaces, process
lifecycle, restart recovery, and Batch settlement. Swift is a typed control
plane over the Typert Gateway.

## Gateway

Every endpoint uses the normal client-request envelope and the Gateway's
mandatory `{"args": {...}}` payload.

| Namespace | Methods |
|---|---|
| `agentProfiles` | `list`, `save`, `remove`, `runtimeStatus` |
| `agentBatches` | `start`, `list`, `detail`, `stop`, `retryRun`, `setIntegration`, `requestIntegration` |
| `agentRuns` | `log`, `inspectWorkspace`, `discard` |
| `agentContexts` | `discard`, `resetAnalysis` |

Example:

```json
{
  "type": "client-request",
  "rpcId": "example",
  "method": "agentProfiles/list",
  "payload": { "args": {} }
}
```

Profile save:

```json
{
  "args": {
    "profile": {
      "name": "Implementation Review",
      "mention": "review",
      "defaultTask": "Review the current changes and run focused tests.",
      "defaultMode": "analysis",
      "allowModelDispatch": false,
      "integrationPolicy": "manual",
      "adapters": [
        { "id": "dsh", "runtime": "dsh", "enabled": true },
        { "id": "codex", "runtime": "codex", "enabled": true }
      ]
    }
  }
}
```

One Profile can bind several distinct runtimes. The same runtime cannot be
bound twice because Run identity, continuation, and retry semantics are
runtime-scoped.

## Runtime Rules

- Global concurrency is three. DSH work for one
  `(initiatorSessionId, profileId, mode)` lane is FIFO.
- Batch creation snapshots the initiating Agent/Subagent's cwd, sandbox mode,
  model options, inheritable tool surface, and Agent Preset. Retries and Host
  restart use this immutable snapshot even if the initiator is no longer live.
- Capability snapshots are versioned. Legacy nonterminal Batches without a
  complete snapshot are interrupted fail-closed, cannot be retried, and must be
  dispatched again. Their logs/worktrees remain inspectable, and legacy DSH
  contexts are never reused.
- Analysis is hard-filtered. Codex analysis is unsupported because its current
  non-interactive CLI cannot remove mutation tools. DSH analysis also receives
  a durable `read-only` sandbox override in addition to its tool allowlist.
- Execution allocates an isolated Git snapshot worktree, including dirty
  tracked and unignored files without changing the parent index or history.
  Non-Git roots fail; there is no directory-copy or parent-checkout fallback.
- External CLIs run through DSH's `sandboxPolicy` and `sandbox` services. A
  confined initiating mode is preserved, with `workspace-write` rooted at the
  member worktree; only an initiating `danger-full-access` mode bypasses
  confinement.
- DSH execution persists its worktree as the child Session `cwd` and reuses the
  continuable child until adoption or discard. The child remains root-owned for
  automatic Host recovery, but its preset, model, tools, cwd, and sandbox come
  from the immutable initiator snapshot rather than the root Agent.
- DSH analysis reuses a separate continuable context. Integrating an analysis
  result does not close it; only explicit reset starts a fresh context.
- Platform-managed children reject ordinary `subagent.prompt` and
  `send_message` follow-ups. Only the platform coordinator can create another
  tracked Run.
- External workers become `interrupted` after Host restart and are never
  restarted automatically. The platform resumes each unique root through the
  Host's own `session.create(sessionId, cwd)` adoption path, then continues DSH
  runs on their durable child/worktree lane.
- Profile deletion blocks new starts and retries. Historical Batch, Profile,
  adapter, Run, log, diff, and integration snapshots remain readable.
- Worktrees are retained after completion. Adoption or explicit discard cleans
  them; cleanup is blocked while a retry sharing the workspace is active.
- DSH child and message ids are reserved before delivery. Embedded runtime
  retries are idempotent by those ids, and startup removes allocation
  directories that durable state no longer references.

## Settlement And Integration

Managed per-child `subagent-settled` notices are removed in the Host
`agent/pre-step` waterfall. One durable outbox message is delivered to the root
Agent only after every Batch member is terminal.

Automatic integration sends the root Agent the original task plus member
worktree, diff, test, and output context, including preferred and still-eligible
Run ids. Manual analysis Batches can send text-only results without a worktree.
The Host never runs a blind merge or cherry-pick. The root Agent selectively
integrates through natural language and records completion with the model-only
`complete_agent_integration` tool. No unauthenticated Gateway endpoint can
mark work adopted.

One DSH execution context can span several Batches. Integration is deferred
while any Run already bound to that context remains active. The integration
instruction includes the accumulated Batch task history, and adopting or
discarding the context updates every associated Run and Batch before the
worktree is removed.

Integration completion and physical cleanup use durable two-phase intents.
Evidence is persisted before deletion; cleanup is idempotent and resumes after
Host restart. An `integrating` Batch without a cleanup intent is re-requested
after restart, while a failed cleanup retains the same intent for explicit
retry and continues blocking later DSH work on that context lane. Explicit
discard/reset close intents also resume after restart. A closing context blocks
new DSH admission at scheduling, context selection, and atomic Run binding.
Cleanup and integration-completion transactions are mutually exclusive, and a
Batch with no still-eligible member cannot request an empty integration.

## Embedded Runtime Patch

`scripts/patch-agent-platform-runtime.mjs` is version-gated to the single DSH
release in `scripts/dsh-runtime-version.txt` and fails the app build when the
package version or expected source anchors drift. It adds:

- continuable child `cwd` override;
- fixed child sandbox mode and Agent Preset overrides, restored on cold resume;
- reserved child/message identities and idempotent message acceptance;
- exact child disposal through upstream `drainContinuableChildren`;
- managed-child follow-up protection;
- the replayable `agent-platform/batches` Session event;
- default Host plugin mounting.
