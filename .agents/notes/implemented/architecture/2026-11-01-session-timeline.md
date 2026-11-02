# Agent Note: One session timeline for live events and history

Status: implemented — one event decoder and one timeline serve root live, subagent live and history replay; root-session state is grouped and registry state returned to the controller

Superseded in part by: [Core layer and session activity](2026-11-02-core-layer-and-session-activity.md), which removes the surface differences this note kept.

## Problem

Three functions interpreted the same DSH event stream: `applyLiveEvent`,
`applyLiveSubagentEvent` and `foldHistoryContent`. Only 14 of the 27 event types
were handled by all three, and every shape fix had to land in a live and a
history twin. Both inputs were the same `DSHRawEvent`: the live path decoded it,
converted it back to `[String: Any]`, and parsed it again with a second decoder
set. That round trip also hid a production bug. Decoded numbers became `Double`,
so `as? Int` returned nil: workflow members never appeared live and retry notices
read zero, while tests that wrote Swift `Int` literals passed.

Root-session state was flattened onto the controller.
`resetRootSessionPresentationState` was a hand-written list of 17 fields, and running
state had four copies written from five files.

`main.swift` is frozen and Swift extensions cannot store properties, so 12
identical singleton registries keyed by `ObjectIdentifier(controller)` held state
outside the controller. Line count fell; coupling did not.

## Decision

- `DSHSessionEvent` is the only code that reads event names and payload shapes.
  `consumeSessionEvent` is the only entry point; `consumeMuxFrame` keeps a tolerant
  adapter because test frames omit `seq` and `time`. All live/history decoder twins
  and four copies of `anyValue` are gone.
- `DSHSessionTimeline.apply` is the only code that turns an event into transcript
  rows, tool state and turn state. Surfaces differ by a `DSHTimelineStore` (where
  state lives) and a `DSHTimelinePolicy` (what each renders).
- `DSHRootSessionScope` groups the fields of the old reset list, so a switch
  replaces the whole value and cannot miss one.
- `reconcileRootSessionRunningState` is the only writer of root running state.
  Switching sessions only re-reads the row. A local submission moves the row and
  the displayed flag but not the sidebar summary, which records what the Host
  reported, so a late completion cannot clear a turn another client started.
  Opening a session moves only the displayed flag: its summary may be older than
  the row, and writing that into the row could show Stop on an idle session.
- `DSHControllerStateBag`, owned by the controller, replaces the registries.
- `test-macos-native.sh` gates event-name literals and uses, parity coverage of
  every event, decoder twins, controller-keyed singletons, the number of running-state
  writes and the `@Published` count in `main.swift`. These are ratchets on source
  text: they catch drift, they do not prove a second interpreter cannot exist.

## Alternatives considered

- **Split the controller into per-domain stores.** Rejected for now: it touches 30
  view files and leaves three event interpreters in place.
- **Keep per-session maps of every field.** Rejected: only the open root session
  receives events, so a single scope models the real behaviour.
- **Replace `Message.id` with a derived stable id.** Rejected: reconnect repair
  already goes through `DSHHistoryPageMerge.mergeTail`, which keeps row identity,
  and re-keying a row when it settles would remount it mid-stream.
- **Make `isRunning` a computed selector.** Rejected: `FloatingBubble` subscribes to
  `$isRunning`, and `NativeAlerts` needs the change edge.
- **Resolve the surface differences here.** Rejected: they change what users see, so
  they need a product decision. Each is now one policy field.

## Consequences

- A new event needs a name and a case in `DSHSessionEvent.swift`, then handling in
  the timeline. The compiler lists every switch that has no default.
- `DSHSessionEventParityTests` freezes all surfaces and fails when an event gains
  handling on one surface only. It runs on a clean checkout, unlike the golden tests.
- `DSHSessionEventParityTests` expected values were captured by running the same
  steps on the code before this change, so they pin old behaviour, not new code.
- Behaviour changes, all deliberate: workflow members and retry numbers now appear
  live; replay treats an empty `rootCallId` as absent, as live always did,
  so those child calls settle instead of staying running after a reload.
- Unknown event names are logged once under the `contract` category.
- Known surface differences remain and are listed by `DSHTimelinePolicy`. Child
  `session/follow` frames still drop `view`, so subagent tool cards appear only after
  reopening. A turn that ends interrupted still settles running tools as succeeded.
- `session/jobs`, `session/queue` and projection frames still use untyped dictionaries.
