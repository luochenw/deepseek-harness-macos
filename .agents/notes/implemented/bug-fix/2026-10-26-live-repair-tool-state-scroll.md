# Agent Note: Stabilize live-session repair and execution feedback

Status: implemented - reconnects repair in the background and tool activity has one quiet live state

## Problem

An active session could suddenly replace its transcript and show
“正在补齐更早的会话历史” when the Host event socket reconnected or an event
sequence gap triggered a follow-snapshot repair. This interrupted the user while
they were watching an active turn and also caused scroll repositioning.

The collapsed reasoning row exposed a segment count that was internal fold
detail. Tool instruction rows exposed a failure label the user did not want, but
their running state was too quiet to answer the more useful question: is a
command executing right now?

## Decision

- Treat reconnect and sequence-gap snapshots as background repairs. Keep the
  current transcript visible and merge the snapshot tail by stable Host message,
  tool-call, or content identity.
- Accumulate missing older pages in a separate repair buffer. Replace or merge
  the visible transcript only when repair completes successfully.
- Never show the inline history-loading row while an active turn already has
  visible messages.
- Memoize transcript folding by context and message-tail version so scroll and
  unrelated projection updates do not rescan all messages.
- Memoize Markdown block and inline parsing for completed transcript rows so
  lazy row reuse during scrolling does not rerun regular expressions and
  `AttributedString` parsing.
- Remove the reasoning segment-count badge.
- Remove the reasoning row's permanent star pulse. Use a static symbol while
  live and reserve continuous motion for explicit execution indicators.
- Remove failure copy from the collapsed instruction status.
- Show an explicit “执行中” capsule, a restrained three-bar waveform, and one
  moving bottom line while a command is active. Completed and failed commands
  return to the plain instruction line.
- Lower the transcript tail animation from 30fps to 20fps while keeping motion.

## Alternatives considered

- **Replace the visible transcript after every reconnect.** Rejected because a
  transport repair must not look like a new conversation load.
- **Keep showing the history-loading overlay during repair.** Rejected because
  it hides the active work the user is watching and causes an avoidable layout
  change.
- **Skip missing history on reconnect.** Rejected because the visible transcript
  would silently become incomplete.
- **Keep the failure badge but make it smaller.** Rejected because failure is
  already present in the command result when the user expands it; the collapsed
  status should answer only whether work is active.
- **Keep only a color change for running state.** Rejected because the user
  could not reliably tell whether a command was still executing.

## Consequences

- Socket reconnects and sequence-gap repairs do not clear the current
  transcript or surface a loading prompt.
- Newly missed events are repaired in memory and applied after the repair batch
  completes.
- Active commands are visibly identified by text, waveform, and motion; reduced
  motion keeps a static line and text.
- A completed turn cannot leave a blinking text caret or reasoning pulse
  running: streamed text only shows its caret during `displayedIsRunning`, and
  completed messages immediately use the normal Markdown renderer.
- Completed and failed instruction rows contain only the concrete command.
- Long-session scrolling avoids repeated full-transcript folding and a 30fps
  tail animation.
