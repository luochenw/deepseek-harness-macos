# Agent Note: Core layer, one transcript for live and replay, and session activity

Status: implemented — domain logic compiles alone, live and replay render the same rows, and background sessions are driven by Host status

## Problem

After the session timeline landed, the feedback loop was still the largest cost of
changing this app. A gated test run took about seven minutes because eight
snapshot and test steps each recompiled every source file by file. Domain types
were nested in `HarnessController`, so testing a timeline change meant building the
whole app.

Two kinds of defect also shared one cause. Since DSH 0.2, session events reach the
client only through a `session/follow` stream, and only the open root session and
an open subagent have one. Code written for the old global stream still expected
events for every session: a background voice task never saw `turn/end`, so it stayed
in `voiceTaskSessions` and the Dock stayed on running; a background session finishing
sent no notification. `consumeHostFrame` had no caller and `consumeMuxFrame` had one
reachable branch, while tests kept the other eight alive. The subagent queue's only
update path sat on one of those unreachable branches.

Live and replay also disagreed in ways people could see. A todo update added a row
on reopen that split the command group around it. A failed turn showed its reason
only in a collapsed panel, and only after reopening in the transcript. An interrupted
turn reported its open tools as complete. Approval sheets did not say which session
was asking, and Host errors landed in whichever session was open.

## Decision

- `scripts/lib-test-library.sh` builds one testable library in whole-module mode and
  every gate reuses it. A gated run takes about 70 seconds.
- `macos/DSHApp/Core/` holds wire values, event decoding, the timeline, and the
  message, tool and workflow models. `HarnessController.Message` and friends are
  typealiases. `scripts/test-core.sh` compiles only those files, which enforces the
  boundary and runs in about two seconds.
- `DSHTimelineMode` replaces `DSHTimelinePolicy`. Live and replay differ only where
  their inputs differ: command rows, the summary of a running tool, the fallback
  for a missing call id, image retention across repeated results, and a failed
  attempt's stream, which live already showed. Rows carry the recorded time and user
  rows their durable id in both modes, so a replayed row merges into its live twin.
- `Sessions/DSHSessionActivity.swift` owns background sessions and is the only place
  a finished run is announced. A status edge or the session list finishes a session;
  a session only counts as finished after it was seen running, because a new session
  reports idle before its prompt starts. List responses apply only in request order
  and only within the stream generation they were requested in, and a status newer
  than a list's request wins over the list on the sidebar, the Dock and the composer.
  A session this app prompted can be finished by an idle list only after a reconnect,
  because an accepted prompt may still be queued. An error for a session that is not
  on screen, or whose history is still loading, waits until its history lands.
- A follow snapshot whose cursor is behind the highest sequence seen means the Host
  rewound the log after a crash. The cached transcript, tools and workflow runs for
  that session are dropped and history loads afresh.
- `DSHWorkflowLog` rebuilds workflow runs from a sequence-keyed log, because history
  arrives newest page first and a run can span pages. A folded page replaces what
  was logged for its sequence range.
- A tool left running settles by the turn's outcome: only a completed turn implies
  success. Any other outcome is the new `.interrupted` state, children included.
- `consumeMuxFrame` and `consumeHostFrame` are gone. Tests use `deliverFrame`, an
  adapter in `DSHTestHarness.swift`. The subagent queue reads the `inbox` projection,
  from baselines as well as updates.
- Permission watermarks relax when Host streams restart, not on a snapshot. The
  JSONL backend buffers live events for 200 ms, so a crash can rewind sequences, but
  resetting on a snapshot let a delayed one roll a newer permission back.

## Alternatives considered

- **Make Core a separate Swift module.** Rejected: it would touch every build script
  and add `public` to hundreds of declarations, while compiling the directory alone
  already enforces the boundary.
- **Follow every running session to receive its events.** Rejected: one stream per
  background session for two facts the status event already carries.
- **Split `HarnessController` into per-domain stores.** Still rejected: it would touch
  30 view files and fixes no defect found here.
- **Fold each history page into workflow runs and merge them.** Rejected: a page can
  hold a run's end without its start.
- **Add live command rows.** Rejected: `send()` already shows local commands, so they
  would appear twice. A command from another client still appears only after reopening.
- **Announce the open session from `turn/end` and others from status.** Rejected: a
  session switch between the two signals announced the same run twice.
- **Reset permission watermarks on every follow snapshot.** Rejected: a snapshot can
  be older than a list that already advanced the watermark.

## Consequences

- `./scripts/test-core.sh` is the loop for event and transcript work; `--unit` covers
  the rest in about a minute.
- A new `DSHToolActivity.State` or `DSHSessionEvent` case fails the build at every
  exhaustive switch.
- Anything that must work for an unopened session has to use status or the session
  list. AGENTS.md's "Adding a feature" table says where each kind of change goes.
- `HarnessController` still has about 430 members and Host still calls up into other
  domains. Only Core has an enforced boundary.
- About 200 grep gates still bind to source text and can fail on a move.
- Known limits, each needing a Host crash or a disconnect at a precise moment: a rewind
  that new events refill up to the old sequence before the session is reopened is not
  detected; a voice prompt still queued across a reconnect can be announced as finished;
  reconnect repair can carry a discarded tool result into the rebuilt running tool.
  Restoring a session from the in-memory cache keeps only the snapshot tail's tools
  (also true before this change).
