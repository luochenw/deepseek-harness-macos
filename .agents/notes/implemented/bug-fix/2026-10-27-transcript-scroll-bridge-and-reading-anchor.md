# Agent Note: Attach transcript scroll fixes to the real scroll view and keep the reading position

Status: implemented — wiring verified with off-screen probes; one prepend case is still open (see Consequences)

## Problem

The transcript still jumped after
[2026-10-26-session-entry-scroll-stability](2026-10-26-session-entry-scroll-stability.md).
Opening a session could show a blank viewport until the user scrolled, and
loading older history could move the reader. Three review rounds, each using
off-screen `NSHostingView` probes with the real `ContentView()`, found that the
earlier fixes were correct as policy but never reached the real scroll view:

- **The bridge attached to the wrong view.** The AppKit bridge sat beside the
  `ScrollView`, retried for one run-loop turn only, and took the first
  `NSScrollView` in the ancestor subtree. In the full window that was the
  sidebar (258 wide), not the transcript (910 wide).
- **Row frames used the wrong coordinate space.** They were measured in a space
  attached outside the `ScrollView`, which gives viewport coordinates. They
  changed on every scrolled pixel, and the restore math subtracted the offset
  twice.
- **The entry clamp fired at most once.** It had a single trigger and only
  corrected gaps larger than half a viewport.
- **The restore gate opened on stale data.** Height-only updates opened it and
  it consumed stale row frames.

## Decision

- **Locate by coverage.** `DSHTranscriptScrollProbeView` sits inside the
  scrolled content and re-locates on `viewDidMoveToWindow` / `layout`.
  - A candidate scroll view must contain the probe in window coordinates, must
    not be an `NSTextView`, and its document must be at least as tall as its
    viewport.
  - There is no single-candidate shortcut, and an ambiguous result returns nil
    and retries. An attachment that stops covering the probe is dropped and
    re-located.
  - The thin overlay scrollers (`DSHScrollerProbeView`) use the same mechanism.
- **Document coordinates.** `dshTranscriptDocumentSpace()` is attached to the
  content column, so a row's `minY` does not change while scrolling (probe:
  6188.4 before and after a 200pt scroll).
- **Entry clamp.** Any overshoot beyond `max + 2pt` is clamped once per entry.
  It is triggered on attach and on content-height changes. It is skipped during
  live resize and while the user is scrolling; that flag expires after
  `gestureStaleInterval`, so a lost `.ended` event cannot block it.
- **Reading anchor.**
  - `rowGeneration` and `heightGeneration` are separate: row-frame restore
    needs new row layout, and the height-difference fallback waits
    `restoreFallbackDelay`.
  - Restore is consumed once, retried by a bounded watchdog, and skipped when
    the reader moved away (scrollbar drag, keyboard paging).
  - Readers pinned to the bottom capture no anchor. An empty anchor goes
    straight to the height fallback.
  - The imprecise `scrollTo(.top)` fallback was removed: when the bridge is
    unavailable the viewport is left alone.

### Round 6: fast trackpad scrolling (real-device feedback)

On device, a fast trackpad swipe toward newer content snapped to the bottom and then kept jumping. Fast swipes in either direction felt jerky.

- **Pin only at rest, using the real AppKit position.** `pinnedToBottom` used to re-engage on any downward wheel event once SwiftUI's *estimated* bottom distance was under 120pt. Mid-swipe the estimate is short, so the view pinned far from the bottom, and every row re-measurement then triggered `requestScrollToTail`. Now:
  - A gesture plus its momentum counts as one interaction. No pin and no tail-follow happens during it; a tail request is deferred to the interaction's end.
  - The pin re-engages after a 350ms debounce, only when the clip view is within 24pt of the real document bottom.
  - The user's own send still forces the tail.
- **Trace log.** `scroll-trace` (os_log, `.info`) records every programmatic viewport write, pin flip and interaction edge. Any unexplained jump over 400pt is logged as `unexplained-jump`.
- **Height cache and estimate seeding.** `DSHTranscriptHeightCache` stores each row's measured height keyed by row id, content version and width bucket. Unmeasured rows get a text-based height estimate. Mid-scroll height drift drops to small per-frame corrections; the one large total-height swap happens only on the first mount frame.
- **Equatable rows.** `MessageBubble`, `ToolGroupRow` and `ReasoningBlock` compare by id plus content version, so roughly 4 rows re-evaluate per frame instead of every mounted row.
- **Row-frame measurement on demand.** Rows report frames only while unpinned, loading history or restoring. The measurement modifier sits outside `.equatable()`, and `DSHTranscriptMeasurementPolicy` is a tested pure function.
- **Off-screen fast-scroll benchmark** (600 mixed rows, 400pt per frame, both directions warmed): downward p95 went from 15.9ms to 10.1ms and upward to 11.3ms. Layout takes about 85% of a frame; display takes about 1.5ms.

## Alternatives considered

- **Keep the `.background` bridge with longer retries**: the scroll view still
  lives in a sibling subtree, and a depth-first search still reaches the sidebar
  first.
- **Pick the tallest scroll view in the window**: fragile with long sidebars and
  nested scroll views; coverage of the probe view is the precise test.
- **Keep observing bounds changes to clamp continuously**: fought rubber-band,
  momentum and magnification; a one-time clamp on entry is enough for the blank
  page.
- **Re-anchor with `ScrollViewReader.scrollTo(id, anchor: .top)`**: loses the
  in-row offset, so the reading row snaps to the top edge.

## Consequences

- Probes confirm all of these: the bridge attaches to the transcript even with
  a 60-session sidebar; the thin scrollers attach to the transcript; a scrollbar
  drag is not overwritten; the clamp is one-shot; scrolling keeps document
  coordinates. Unit tests: `DSHConversationScrollStabilityTests` (240 in the
  full suite pass).
- Round 6 identified the "drag to the bottom" writer: tail-follow fired from a premature pin during the swipe. The scroll-trace log can confirm it on device.
- The 8ms p95 frame-time target is not met yet. The remaining cost is SwiftUI layout of newly mounted rows. Fixing measured rows to their cached size is the next thing to try.
- macOS 14 keeps `defaultScrollAnchor(.bottom)` for all roles (no
  `.initialOffset`), so the behaviour there is unchanged and unverified.
- The probes ran off-screen with simulated loading state. Real trackpad
  momentum and real Host history streaming are verified on device only.
