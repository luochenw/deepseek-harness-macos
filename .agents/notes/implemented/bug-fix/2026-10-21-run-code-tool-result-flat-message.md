# Agent Note: Settle run_code results from DSH 0.2 flat tool messages

Status: implemented - flat DSH 0.2 tool results now settle calls with their real output

## Problem

In a session that uses `run_code`, every historical call remains marked
`running` and its detail often says there is no output. The Host has already
stored successful tool results, but their DSH 0.2 shape is:

```json
{
  "message": {
    "source": {"kind": "tool", "callId": "call_..."},
    "toolCallId": "call_...",
    "isError": false,
    "content": [{"type": "text", "text": "tool output"}]
  }
}
```

`DSHToolResultDecoder` only recognizes the previous nested
`content[].type == "tool-result"` shape. It returns nil for the flat message,
so `tool/result` never updates the matching `tool/call`. History folding has no
turn-boundary fallback, so every unmatched call stays pulsing as running.

## Decision

Accept both result shapes in live and history decoding:

1. Prefer a nested `tool-result` block when present, preserving compatibility
   with older logs.
2. Otherwise use the flat message's `toolCallId` or `source.callId`, read direct
   text content, and read `isError` from the message.
3. During history folding, settle still-running tools when a completed
   `turn/end` is encountered. This is a fail-closed fallback for truncated or
   missing result events and prevents an old turn from remaining animated.

The display layer continues to use the call-to-result `callId` correlation.
Only result payload decoding and history turn settlement change.

## Alternatives considered

- **Settle every running tool whenever any later tool event arrives.**
  Rejected because parallel or background calls could still be active.
- **Ignore the flat message and derive output only from `view`.**
  Rejected because `run_code` history entries often have no view; the durable
  output is inside the result message content.
- **Special-case the `run_code` name.**
  Rejected because the wire-shape mismatch affects every tool using the same
  message envelope.

## Consequences

- A live flat DSH 0.2 tool result updates only its matching call, changes it
  from running to succeeded/failed, and preserves text output.
- The nested legacy result shape remains supported.
- History folding with flat results settles every completed call and retains
  each call's output.
- A completed historical turn cannot leave an orphaned running tool; a call
  from a later incomplete turn may remain running.
- Native tests, the app build, Host smoke, and signature verification pass.

Verification on October 21, 2026: replaying the affected session's 659 stored
events produced 57/57 completed `run_code` calls with 57 non-empty outputs.
The full native suite passed 153/153 tests; app build, Host API smoke, bundle
lint, signature verification, and an installed-app readback also passed.

## Risks

- A malformed result with neither a recognized nested block nor flat text will
  still fall back to turn-end settlement without detailed output.
- Calls intentionally intended to outlive `turn/end` must be represented as
  background jobs; ordinary tool calls are treated as turn-scoped.
