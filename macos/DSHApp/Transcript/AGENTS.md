# Transcript — agent rules
Scope: rendering `displayedSession.messages` into the transcript — collapsing, row-height caching, scroll anchoring, tool cards, Markdown text and attachment previews. Sends no RPC, and does not own session selection or history fetching.
Key files: `ConversationView.swift` (transcript body and row composition), `DSHConversationScrollStability.swift` (scroll anchoring and scroll-view bridging), `DSHTranscriptPerf.swift` (row-frame measurement probes), `NativeToolPresentationView.swift` (shared tool card), `NativeMarkdownText.swift` (cached Markdown parsing), `StreamingAssistantText.swift` (streaming assistant row).
Invariants (each must cite a Note or test):
- The transcript renders the full message array in one pass; there is no manual paging control — source: `simplification/2026-10-22-load-complete-session-history.md`.
- Reasoning rows aggregate per turn (`turnTrace`) and row identities carry a type prefix (`reasoning-`/`message-`/`tool-`) — source: `feature/2026-08-28-reasoning-row-aggregation.md`.
- Transcript and the right-hand panel share one `ToolPresentationContent`, and tool calls start collapsed — source: `feature/2026-08-25-inline-tool-presentation-parity.md`.
- Whether the view follows the tail is decided by the pin alone; after the user scrolls up no trigger may follow — source: `macos/DSHTests/DSHConversationScrollStabilityTests.swift` ("Scroll policy follows the tail only while pinned").
- Row frames are measured in the ScrollView's document coordinate space, and the bar locates the real scroll view by coverage — source: `macos/DSHTests/DSHConversationScrollStabilityTests.swift` ("Scroll policy rejects viewport-space row frames").
- The row-height cache serves settled rows only; streaming and collapsed rows neither read nor write it — source: `macos/DSHTests/DSHTranscriptRowHeightTests.swift` ("Row height policy opts streaming and collapsed rows out of the cache").
Before reporting done: `./scripts/test-reasoning-ui.sh`, `./scripts/test-tool-presentation-ui.sh`, `./scripts/test-attachment-rail-ui.sh`, `./scripts/test-macos-native.sh --unit`.
Pitfalls:
- The golden tests are inherently brittle on CI (offscreen window, fixed run-loop duration) — source: `bug-fix/2026-10-28-interrupted-turn-blank-band.md`.
- `ToolGroupRow.==` must not read `@EnvironmentObject`; the comparison has to be a pure value check — source: `bug-fix/2026-10-28-interrupted-turn-blank-band.md`.
- Measurement switches exist only under `#if DEBUG`; Release keeps them `false` — source: `bug-fix/2026-10-28-interrupted-turn-blank-band.md`.
- The 8ms p95 frame-time target has not been reached yet — source: `bug-fix/2026-10-27-transcript-scroll-bridge-and-reading-anchor.md`.
