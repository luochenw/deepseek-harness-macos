# Core — agent rules
Scope: the domain layer. Wire values, event decoding, the session timeline, transcript and tool models, and pure tool-title logic. Holds no SwiftUI, no AppKit, no `HarnessController` and no networking.
Key files: `DSHSessionEvent.swift` (event names and payload shapes), `DSHSessionTimeline.swift` (events into rows, tools and turn state), `DSHTranscriptModel.swift` (message, tool and workflow models, history merge), `DSHToolDecoding.swift` (tool payload decoders), `DSHCommandTitle.swift` (command titles and write classification), `DSHWireValue.swift` (typed JSON and raw events).
Invariants (each must cite a Note or test):
- Core compiles alone: `scripts/test-core.sh` builds these files with nothing else, so a dependency on UI or the controller fails the build — source: `architecture/2026-11-02-core-layer-and-session-activity.md`.
- Event names and payload shapes are read only in `DSHSessionEvent.swift` — source: `macos/DSHTests/DSHCoreTimelineTests.swift`.
- Live and replay differ only by `DSHTimelineMode`; a third surface difference needs a product reason — source: `macos/DSHTests/DSHCoreTimelineTests.swift` ("Live and replay render the same rows").
- Rows carry the recorded event time in both modes, or a replayed row cannot merge into its live twin — source: `macos/DSHTests/DSHCoreTimelineTests.swift` ("Replayed rows merge into their live twins").
- A tool still running when its turn ends settles by the turn's outcome: only a completed turn means it succeeded — source: `macos/DSHTests/DSHCoreTimelineTests.swift`.
Before reporting done: `./scripts/test-core.sh` (seconds), then `./scripts/test-macos-native.sh --unit`.
Pitfalls:
- `Message`, `ToolActivity`, `ToolPresentation` and `WorkflowRun` on `HarnessController` are typealiases of the `DSH*` types here.
- Decoded JSON numbers are `Double`, so `as? Int` on a plain dictionary silently fails; this hid workflow members and retry counts — source: `macos/DSHTests/DSHSessionEventParityTests.swift` ("Live events read numbers decoded from JSON").
- `DSHToolActivityMerge` compares the literal summaries `工具调用` and `正在运行`, so the timeline keeps both — source: `DSHToolDecoding.swift`.
