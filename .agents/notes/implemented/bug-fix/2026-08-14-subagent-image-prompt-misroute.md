# Agent Note: Image attachment sent while a continuable subagent is open bypassed subagent routing

Status: implemented

## Problem

`HarnessController.send()` routed a typed-text prompt to the open continuable
subagent (`sendSubagentPrompt`) only when `activeSubagentAddress?.mode ==
"continuable" && image == nil`. When a `DraftImage` was attached, the guard
failed regardless of `activeSubagentAddress`, and execution fell through to
the ordinary top-level `hostClient.prompt(sessionId: hostCurrentSessionID,
...)` call. With a continuable subagent open, `hostCurrentSessionID` is still
the **parent** session (`openSubagent` never changes it — it only tracks
`activeSubagentAddress`/`subagentPath`), so an image sent while chatting with
a subagent silently landed in the parent session's transcript instead, with
no error and no indication to the user that the message went to the wrong
place.

## Decision

`DSHHostClient.promptSubagent` (`DSHSubagentPromptPayload` /
`subagent.prompt`) already accepts the same `[DSHPromptContent]` content
array `session.prompt` does — there is no protocol reason image content
can't ride the subagent path. `send()` now builds the `[DSHPromptContent]`
array (text + optional image) once and routes the whole thing to
`hostClient.promptSubagent` whenever a continuable subagent is active,
regardless of whether an image is attached. The `image == nil` special case
is removed; `sendSubagentPrompt(_:)` (text-only) is now only used by the
`Composer`'s implicit empty-image path and both call sites converge on one
content-array-aware subagent send.

## Alternatives considered

- **Block sending with an image while a subagent is open, show an error.**
  Rejected — strictly worse for the user than just making it work, and the
  Host protocol already supports it.
- **Leave the fallthrough but show a warning toast ("image sent to parent
  session").** Rejected — treats a fixable routing bug as an accepted
  limitation instead of fixing it; would still misroute the message.

## Consequences

Sending an image while a continuable subagent's transcript is open now
reaches that subagent, matching what typed text already did. No behavior
changed for the top-level-session send path (unaffected — it's a different
branch), and no wire format changed (`promptSubagent` already accepted image
content blocks).
