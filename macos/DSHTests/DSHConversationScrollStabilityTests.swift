import AppKit
import CoreGraphics
import Foundation
@testable import DSHAppLib

// MARK: - Follow policy

/// ① — following the tail is the pin's decision, never the scroll anchor's.
private func testScrollPolicy_followsTailOnlyWhilePinned() throws {
  let triggers: [DSHConversationScrollPolicy.Trigger] = [
    .tailContentChanged, .runningStateChanged, .steeringChanged, .olderHistoryFinished,
  ]
  for trigger in triggers {
    try expect(
      DSHConversationScrollPolicy.shouldFollowTail(pinned: true, trigger: trigger),
      "pinned reader must follow \(trigger)")
    try expect(
      !DSHConversationScrollPolicy.shouldFollowTail(pinned: false, trigger: trigger),
      "reader who scrolled up must not follow \(trigger)")
  }
}

private func testScrollPolicy_resizeFollowsOnlyPinnedReader() throws {
  // A LazyVStack height correction while the reader is at the bottom: follow,
  // so an over-estimated first layout still lands on the newest content.
  try expect(DSHConversationScrollPolicy.shouldFollowAfterResize(
    pinned: true, previousContentHeight: 12_000, contentHeight: 5_400))
  // Same correction while the reader is up in the history: never move.
  try expect(!DSHConversationScrollPolicy.shouldFollowAfterResize(
    pinned: false, previousContentHeight: 12_000, contentHeight: 5_400))
  // No size change, or no previous measurement: nothing to do.
  try expect(!DSHConversationScrollPolicy.shouldFollowAfterResize(
    pinned: true, previousContentHeight: 5_400, contentHeight: 5_400))
  try expect(!DSHConversationScrollPolicy.shouldFollowAfterResize(
    pinned: true, previousContentHeight: 0, contentHeight: 5_400))
}

// MARK: - Entry clamp, against a real NSScrollView (no window server needed)

/// A scroll view whose document is `contentHeight` tall, framed like a
/// transcript viewport. AppKit constrains scroller geometry on a real window, so
/// the fixture sets the clip's frame explicitly and never needs one.
@MainActor
private func makeScrollFixture(
  contentHeight: CGFloat,
  viewportHeight: CGFloat = 700,
  offset: CGFloat
) -> (scrollView: NSScrollView, documentView: NSView) {
  let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: viewportHeight))
  let documentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: contentHeight))
  scrollView.documentView = documentView
  scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
  return (scrollView, documentView)
}

@MainActor
private func makeBox(_ scrollView: NSScrollView) -> DSHTranscriptScrollViewBox {
  let box = DSHTranscriptScrollViewBox()
  box.scrollView = scrollView
  return box
}

/// The blank transcript the user hit on entry: the viewport was placed against
/// over-estimated tool/thinking rows, so the real content was shorter than the
/// offset and nothing was visible until a scroll nudged it.
private func testEntryClamp_recoversFromBlankOnlyOnce() throws {
  try MainActor.assumeIsolated {
    // Pathological: the offset is 900pt past the last page of content — the
    // whole viewport is blank. It must land on the real tail.
    let blank = makeScrollFixture(contentHeight: 3_000, offset: 3_200)
    let blankBox = makeBox(blank.scrollView)
    try expect(blankBox.clampOnEntry(), "a full blank page must be clamped")
    try expectEqual(blank.scrollView.contentView.bounds.origin.y, 2_300)
    try expect(blankBox.didClampEntry)

    // Only once per session: a later pathological offset (however it got
    // there) is the user's or AppKit's business, not the entry clamp's.
    blank.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 5_000))
    try expect(!blankBox.clampOnEntry())
    try expectEqual(blank.scrollView.contentView.bounds.origin.y, 5_000)
  }
}

private func testEntryClamp_ignoresSmallOvershootAndEmptyContent() throws {
  try MainActor.assumeIsolated {
    // Within `entryClampTolerance` of the real tail: rounding, not a blank page.
    let overshoot = makeScrollFixture(contentHeight: 3_000, offset: 2_300.5)
    let overshootBox = makeBox(overshoot.scrollView)
    try expect(!overshootBox.clampOnEntry())
    try expectEqual(overshoot.scrollView.contentView.bounds.origin.y, 2_300.5)
    // Nothing pathological happened, so the one clamp is still armed.
    try expect(!overshootBox.didClampEntry)
    overshoot.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 9_000))
    try expect(overshootBox.clampOnEntry(), "the armed clamp still gets its one chance")
    try expectEqual(overshoot.scrollView.contentView.bounds.origin.y, 2_300)

    // Content not laid out yet (0 height) must never be "clamped to 0" — that
    // is exactly the flash-to-top this gate removes.
    let empty = makeScrollFixture(contentHeight: 0, offset: 0)
    let emptyBox = makeBox(empty.scrollView)
    try expect(!emptyBox.clampOnEntry())
    try expect(!emptyBox.didClampEntry, "an empty layout must not consume the one clamp")

    // A zero-height viewport is equally unusable.
    let flat = makeScrollFixture(contentHeight: 3_000, viewportHeight: 0, offset: 4_000)
    let flatBox = makeBox(flat.scrollView)
    try expect(!flatBox.clampOnEntry())
    try expectEqual(flat.scrollView.contentView.bounds.origin.y, 4_000)
  }
}

/// Any visible blank at the bottom is clamped, not just a whole blank page: a
/// 200pt overshoot still shows 200pt of empty transcript.
private func testEntryClamp_recoversAVisibleBlankStrip() throws {
  try MainActor.assumeIsolated {
    let fixture = makeScrollFixture(contentHeight: 3_000, offset: 2_500)
    let box = makeBox(fixture.scrollView)
    try expect(box.clampOnEntry(), "200pt of blank is a visible bug, not rounding")
    try expectEqual(fixture.scrollView.contentView.bounds.origin.y, 2_300)
    try expect(box.didClampEntry)
  }
}

/// Rubber-band/interaction intermediates are not the entry bug: while a gesture
/// is in flight nothing is written, and the one clamp survives for afterwards.
private func testEntryClamp_neverFightsAnInFlightGesture() throws {
  try MainActor.assumeIsolated {
    let fixture = makeScrollFixture(contentHeight: 3_000, offset: 3_400)
    let box = makeBox(fixture.scrollView)
    box.noteScrollPhase(.began)
    try expect(!box.clampOnEntry())
    try expectEqual(fixture.scrollView.contentView.bounds.origin.y, 3_400)
    try expect(!box.didClampEntry)
    box.noteScrollPhase(.changed)
    try expect(!box.clampOnEntry())
    box.noteScrollPhase(.ended)
    try expect(box.clampOnEntry())
    try expectEqual(fixture.scrollView.contentView.bounds.origin.y, 2_300)
  }
}

/// A lost `.ended` (pointer left the transcript mid-swipe) must not block the
/// entry clamp for the rest of the session.
private func testEntryClamp_recoversFromALostGestureEnd() throws {
  try MainActor.assumeIsolated {
    let fixture = makeScrollFixture(contentHeight: 3_000, offset: 3_400)
    let box = makeBox(fixture.scrollView)
    box.noteScrollEvent(phase: .began, momentumPhase: [])
    try expect(!box.clampOnEntry())
    // A lost `.ended`: the timestamp alone must release the gesture.
    box.expireGestureForTesting()
    try expect(box.clampOnEntry(), "a lost .ended must not disable the clamp forever")
    try expectEqual(fixture.scrollView.contentView.bounds.origin.y, 2_300)
  }
}

private func testEntryClamp_waitsForGestures() throws {
  try MainActor.assumeIsolated {
    let fixture = makeScrollFixture(contentHeight: 3_000, offset: 4_000)
    let box = makeBox(fixture.scrollView)

    // Mid trackpad gesture: leave the viewport alone (and stay armed).
    box.noteScrollPhase(.began)
    try expect(!box.clampOnEntry())
    try expect(!box.didClampEntry)
    box.noteScrollPhase(.ended)
    try expect(box.clampOnEntry(), "the clamp runs after the gesture ends")
    try expectEqual(fixture.scrollView.contentView.bounds.origin.y, 2_300)
  }
}

// MARK: - ② restore

/// The regression the review found: the restore used to be handed
/// `contentHeight - bottomDistance`, which is the content offset PLUS the
/// viewport height. Near the bottom that clamps the reader to the very top.
private func testRestore_needsTheRealViewportHeight() throws {
  let anchor = DSHTranscriptScrollAnchor(
    firstVisibleRowID: "message-42",
    rowOffsetInViewport: -120,
    rowHeight: 260,
    contentOffset: 9_000,
    contentHeight: 12_000)
  // The anchored row now starts at document y = 8_880; the reader saw it 120pt
  // below the viewport top, so the correct offset is 9_000 — unchanged.
  let rowFrame = CGRect(x: 0, y: 8_880, width: 800, height: 260)

  let correct = DSHConversationScrollPolicy.restoredContentOffset(
    for: anchor,
    rowFrame: rowFrame,
    contentHeight: 12_000,
    viewportHeight: 700)
  try expectEqual(correct, 9_000)
  try expect(
    correct == 9_000,
    "a correct viewport height must not move the viewport")

  // The old derivation: bottomDistance = 12 000 - 9 000 - 700 = 2 300, so the
  // "viewport height" became 12 000 - 2 300 = 9 700. The maximum offset then
  // collapsed to 2 300 and the reader jumped to the top of the session.
  let wrongViewport: CGFloat = 12_000 - 2_300
  let broken = DSHConversationScrollPolicy.restoredContentOffset(
    for: anchor,
    rowFrame: rowFrame,
    contentHeight: 12_000,
    viewportHeight: wrongViewport)
  try expectEqual(broken, 2_300)
  try expect(broken < correct - 5_000, "this fixture must make the wrong height obvious")

  // Same rule for the height-delta fallback (row no longer laid out).
  try expectEqual(
    DSHConversationScrollPolicy.restoredContentOffset(
      for: anchor, newContentHeight: 17_000, viewportHeight: 700),
    14_000)
  // A restore that would land past the shortened content is clamped, never
  // left below the last row.
  try expectEqual(
    DSHConversationScrollPolicy.restoredContentOffset(
      for: anchor, newContentHeight: 1_000, viewportHeight: 700),
    0)
}

/// The restore must be computed from a ROW layout that landed AFTER the batch
/// finished — replaying the pre-batch row frames is a no-op by construction.
private func testRestore_waitsForANewRowLayoutGeneration() throws {
  try MainActor.assumeIsolated {
    let store = DSHTranscriptMeasurementStore()
    store.update(contentHeight: 12_000)
    store.update(rowFrames: ["message-42": CGRect(x: 0, y: 3_820, width: 800, height: 260)])
    let anchor = store.captureAnchor(contentOffset: 4_000, viewportHeight: 700)
    try expectEqual(anchor.firstVisibleRowID, "message-42")
    try expectEqual(anchor.rowOffsetInViewport, -180)

    store.beginRestore(anchor, liveContentOffset: 4_000)
    try expect(store.hasPendingRestore)
    try expect(
      store.restorePath() == nil,
      "the old snapshot must not be replayed before a new layout")

    // A real row layout (rows re-measured above the reader) unlocks the row path.
    store.update(rowFrames: ["message-42": CGRect(x: 0, y: 6_400, width: 800, height: 260)])
    let pending = store.takePendingRestore()
    try expectEqual(pending?.path, .rowLayout)
    try expect(pending != nil, "a newer row layout unlocks exactly one restore")
    try expect(store.takePendingRestore() == nil, "the restore is one-shot")
    let offset = DSHConversationScrollPolicy.restoredContentOffset(
      for: anchor,
      rowFrame: store.rowFrames["message-42"],
      contentHeight: store.contentHeight,
      viewportHeight: 700)
    // The row moved down by 2 400, so the viewport follows by the same amount.
    try expectEqual(offset, 6_400 + 180)
  }
}

/// A height change alone proves nothing about the rows: it must not authorize
/// the row path (which would write a pre-prepend frame), and it must not be
/// consumed before the bounded fallback delay either.
private func testRestore_heightChangeAloneNeverReleasesTheRowPath() throws {
  try MainActor.assumeIsolated {
    let store = DSHTranscriptMeasurementStore()
    store.update(contentHeight: 12_000)
    store.update(rowFrames: ["message-42": CGRect(x: 0, y: 3_820, width: 800, height: 260)])
    let anchor = store.captureAnchor(contentOffset: 4_000, viewportHeight: 700)
    store.beginRestore(anchor, liveContentOffset: 4_000)

    store.update(contentHeight: 14_000)
    let armedAt = Date()
    try expect(store.restorePath(now: armedAt) == nil, "no row layout yet, and no time passed")

    // Past the fallback delay: the HEIGHT path is allowed, never the row path.
    let later = armedAt.addingTimeInterval(DSHTranscriptMeasurementStore.restoreFallbackDelay + 0.01)
    try expectEqual(store.restorePath(now: later), .heightFallback)
    let pending = store.takePendingRestore(now: later)
    try expectEqual(pending?.path, .heightFallback)
    try expect(store.takePendingRestore(now: later) == nil, "one-shot even on the fallback")
  }
}

// MARK: - Reader moved away (D)

/// A scrollbar drag or Page Up raises no wheel phase, so `isUserScrolling` stays
/// false. The armed restore must notice the viewport moved and stand down
/// instead of overwriting the reader.
private func testRestore_readerMovedAwayAbandonsTheWrite() throws {
  try MainActor.assumeIsolated {
    let store = DSHTranscriptMeasurementStore()
    store.update(contentHeight: 12_000)
    store.update(rowFrames: ["message-42": CGRect(x: 0, y: 3_820, width: 800, height: 260)])
    let anchor = store.captureAnchor(contentOffset: 4_000, viewportHeight: 700)
    store.beginRestore(anchor, liveContentOffset: 4_000)
    store.update(rowFrames: ["message-42": CGRect(x: 0, y: 6_400, width: 800, height: 260)])

    try expect(!store.readerMovedAway(liveContentOffset: 4_000), "same place: restore may run")
    try expect(!store.readerMovedAway(liveContentOffset: 4_001.5), "1.5pt jitter is not a move")
    try expect(store.readerMovedAway(liveContentOffset: 1_200), "dragged away: stand down")
    try expect(store.readerMovedAway(liveContentOffset: 9_000), "paged away: stand down")
  }
}

/// C: a capture with no mounted row must go straight to the height fallback
/// instead of arming a row restore that can never be satisfied.
private func testRestore_withoutARowAnchorUsesTheHeightFallback() throws {
  try MainActor.assumeIsolated {
    let store = DSHTranscriptMeasurementStore()
    store.update(contentHeight: 13_493)
    store.update(rowFrames: ["tail": CGRect(x: 0, y: 13_000, width: 800, height: 100)])
    let anchor = store.captureAnchor(contentOffset: 4_000, viewportHeight: 700)
    try expect(anchor.firstVisibleRowID == nil, "fixture: no row covers the viewport top")

    store.beginRestore(anchor, liveContentOffset: 4_000, hasRowAnchor: false)
    try expect(store.restorePath(now: Date()) == nil, "the fallback still waits out its delay")
    let later = Date().addingTimeInterval(DSHTranscriptMeasurementStore.restoreFallbackDelay + 0.01)
    try expectEqual(store.restorePath(now: later), .heightFallback)
    let pending = store.takePendingRestore(now: later)
    try expectEqual(pending?.path, .heightFallback)
  }
}

// MARK: - Row anchoring

private func testScrollPolicy_firstVisibleRowIsTheTopmostIntersectingRow() throws {
  let frames: [String: CGRect] = [
    "above": CGRect(x: 0, y: -900, width: 700, height: 400),
    "reading": CGRect(x: 0, y: -180, width: 700, height: 260),
    "next": CGRect(x: 0, y: 80, width: 700, height: 120),
    "below": CGRect(x: 0, y: 800, width: 700, height: 300),
  ]
  let visible = DSHConversationScrollPolicy.firstVisibleRow(frames: frames, viewportHeight: 600)
  try expectEqual(visible?.id, "reading")
  try expectEqual(visible?.offset, -180)
  try expectEqual(visible?.height, 260)

  // The row straddling the top edge wins even when another row also starts
  // inside the viewport (dictionary iteration order must not decide).
  for _ in 0..<20 {
    try expectEqual(
      DSHConversationScrollPolicy.firstVisibleRow(frames: frames, viewportHeight: 600)?.id,
      "reading")
  }

  // Rows entirely above or below the viewport are never the anchor.
  let onlyOutside: [String: CGRect] = [
    "above": CGRect(x: 0, y: -900, width: 700, height: 400),
    "below": CGRect(x: 0, y: 700, width: 700, height: 300),
  ]
  try expectEqual(
    DSHConversationScrollPolicy.firstVisibleRow(frames: onlyOutside, viewportHeight: 600)?.id,
    nil)
  try expectEqual(
    DSHConversationScrollPolicy.firstVisibleRow(frames: frames, viewportHeight: 0)?.id,
    nil)
}

/// Row frames are captured in document space, so scrolling does not change them
/// (that is what stops the per-frame preference churn).
private func testCapturedAnchor_mapsDocumentFramesToTheViewport() throws {
  let documentFrames: [String: CGRect] = [
    "message-1": CGRect(x: 0, y: 0, width: 700, height: 400),
    "message-2": CGRect(x: 0, y: 1_920, width: 700, height: 90),
  ]
  let anchor = DSHConversationScrollPolicy.capturedAnchor(
    contentOffset: 1_600,
    contentHeight: 9_400,
    documentRowFrames: documentFrames,
    viewportHeight: 700)
  try expectEqual(anchor.firstVisibleRowID, "message-2")
  try expectEqual(anchor.rowOffsetInViewport, 320)
  try expectEqual(anchor.rowHeight, 90)
  try expectEqual(anchor.contentOffset, 1_600)
  try expectEqual(anchor.contentHeight, 9_400)

  // Scrolling the same content by 100pt changes the anchor's row offset but
  // NOT the stored document frames.
  let scrolled = DSHConversationScrollPolicy.capturedAnchor(
    contentOffset: 1_700,
    contentHeight: 9_400,
    documentRowFrames: documentFrames,
    viewportHeight: 700)
  try expectEqual(scrolled.rowOffsetInViewport, 220)
}

// MARK: - ③ row metrics

private func testRowEstimate_usesTheRenderedFontMetrics() throws {
  // Comparing the exported constants with themselves would be tautological, so
  // compare the real NSFont metrics the rows are rendered with.
  let mono = DSHTranscriptRowEstimate.lineHeight(
    fontSize: DSHType.monoSize, monospaced: true)
  let accessory = DSHTranscriptRowEstimate.lineHeight(
    fontSize: DSHType.microSize, weight: .medium)
  let label = DSHTranscriptRowEstimate.lineHeight(
    fontSize: DSHType.labelSize, weight: .medium)
  let status = DSHTranscriptRowEstimate.lineHeight(fontSize: DSHType.captionSize)
  try expect(mono > 0 && accessory > 0 && label > 0 && status > 0)
  try expect(label > status, "a 12.5pt label must be taller than an 11pt caption")

  let idle = DSHTranscriptRowEstimate.toolStatusRowHeight(accessory: false)
  let running = DSHTranscriptRowEstimate.toolStatusRowHeight(accessory: true)
  // Cover the real row: tallest single line + both paddings.
  try expectEqual(idle, mono + DSHTranscriptRowEstimate.statusRowVerticalPadding * 2)
  try expectEqual(
    running, max(mono, accessory + DSHTranscriptRowEstimate.accessoryVerticalPadding * 2)
      + DSHTranscriptRowEstimate.statusRowVerticalPadding * 2)
  try expect(running > idle, "the 执行中 capsule must add height, not squeeze the title")

  let thinking = DSHTranscriptRowEstimate.reasoningStatusRowHeight(status: false)
  try expectEqual(
    thinking, label + DSHTranscriptRowEstimate.reasoningRowVerticalPadding * 2)
  try expectEqual(DSHTranscriptRowEstimate.reasoningStatusRowHeight(status: true), thinking)

  // A larger accessibility font scales the estimate up on the same path.
  let large = DSHTranscriptRowEstimate.lineHeight(fontSize: 15, monospaced: true)
  try expect(large > mono)
}

// MARK: - Coordinate contract

/// `capturedAnchor` takes DOCUMENT-space frames. Feeding viewport-space frames
/// (what a coordinate space attached to the ScrollView yields) double-subtracts
/// the offset and picks the wrong row. Pin the difference so the space cannot be
/// attached to the wrong view again.
private func testCapturedAnchor_rejectsViewportSpaceFrames() throws {
  let offset: CGFloat = 26_000
  let documentFrames: [String: CGRect] = [
    "reading": CGRect(x: 0, y: offset - 120, width: 700, height: 300),
    "next": CGRect(x: 0, y: offset + 200, width: 700, height: 90),
  ]
  let documentAnchor = DSHConversationScrollPolicy.capturedAnchor(
    contentOffset: offset,
    contentHeight: 27_605,
    documentRowFrames: documentFrames,
    viewportHeight: 720)
  try expectEqual(documentAnchor.firstVisibleRowID, "reading")
  try expectEqual(documentAnchor.rowOffsetInViewport, -120)

  let viewportFrames = documentFrames.mapValues { $0.offsetBy(dx: 0, dy: -offset) }
  let viewportAnchor = DSHConversationScrollPolicy.capturedAnchor(
    contentOffset: offset,
    contentHeight: 27_605,
    documentRowFrames: viewportFrames,
    viewportHeight: 720)
  try expect(
    viewportAnchor.rowOffsetInViewport != documentAnchor.rowOffsetInViewport
      || viewportAnchor.firstVisibleRowID != documentAnchor.firstVisibleRowID,
    "viewport-space frames must not silently reproduce the document-space anchor")
  let documentRestore = DSHConversationScrollPolicy.restoredContentOffset(
    for: documentAnchor,
    rowFrame: documentFrames["reading"],
    contentHeight: 27_605,
    viewportHeight: 720)
  let viewportRestore = DSHConversationScrollPolicy.restoredContentOffset(
    for: viewportAnchor,
    rowFrame: viewportFrames["reading"],
    contentHeight: 27_605,
    viewportHeight: 720)
  try expect(
    abs(documentRestore - viewportRestore) > 1,
    "double-subtracting the offset must be observable")
}

// MARK: - Shared scroll-view lookup

/// `.background(...)` puts a representable's view beside the scroll view, not
/// inside it, so `enclosingScrollView` alone is nil — locating it is what makes
/// the bridge attach at all.
private func testLocate_scrollViewFindsSiblingPlacedBackgrounds() throws {
  try MainActor.assumeIsolated {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 700))
    let scrollView = NSScrollView(frame: container.bounds)
    scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 4_000))
    container.addSubview(scrollView)
    let backgroundView = NSView(frame: container.bounds)
    container.addSubview(backgroundView)

    try expect(backgroundView.enclosingScrollView == nil, "fixture must reproduce the nil case")
    try expect(
      dshLocateEnclosingScrollView(from: backgroundView) === scrollView,
      "the bounded ancestor walk must find the sibling scroll view")

    // The scroller configurator's text-view filter still applies.
    try expect(dshLocateEnclosingScrollView(from: backgroundView, accepting: { _ in false }) == nil)

    // Bounded: when the scroll view only shows up more than five ancestors up,
    // the lookup gives up instead of returning an arbitrary nested scroll view
    // (the transcript has several). The scroll view here is a sibling of the
    // fifth ancestor, so only a 6th hop could reach it.
    let deepRoot = NSView(frame: container.bounds)
    let deepScroll = NSScrollView(frame: container.bounds)
    deepScroll.documentView = NSView(frame: container.bounds)
    deepRoot.addSubview(deepScroll)
    let deepProbe = NSView(frame: container.bounds)
    var leaf = deepProbe
    for _ in 0..<5 {
      let wrapper = NSView(frame: container.bounds)
      wrapper.addSubview(leaf)
      leaf = wrapper
    }
    deepRoot.addSubview(leaf)
    try expect(
      dshLocateEnclosingScrollView(from: deepProbe) == nil,
      "the walk must stay bounded")
    // One hop fewer still resolves — otherwise the assertion above could pass
    // for the wrong reason.
    let shallow = NSView(frame: container.bounds)
    let shallowScroll = NSScrollView(frame: container.bounds)
    shallowScroll.documentView = NSView(frame: container.bounds)
    shallow.addSubview(shallowScroll)
    let shallowProbe = NSView(frame: container.bounds)
    shallow.addSubview(shallowProbe)
    try expect(dshLocateEnclosingScrollView(from: shallowProbe) === shallowScroll)
  }
}

/// The production failure: once the walk reaches the hosting view it sees the
/// sidebar's scroll view first. Source order must not decide — the scroll view
/// that actually covers the probe wins, and an ambiguous probe gets nil instead
/// of a stranger's pane.
private func testLocate_prefersTheCoveringScrollView() throws {
  try MainActor.assumeIsolated {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 800))
    // Sidebar: narrow, short document, added FIRST so it is the "first descendant".
    let sidebar = NSScrollView(frame: NSRect(x: 0, y: 0, width: 258, height: 800))
    sidebar.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 258, height: 42))
    root.addSubview(sidebar)
    // Transcript: the pane the probe decorates.
    let pane = NSView(frame: NSRect(x: 258, y: 0, width: 912, height: 800))
    root.addSubview(pane)
    let transcript = NSScrollView(frame: pane.bounds)
    transcript.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 912, height: 27_630))
    pane.addSubview(transcript)

    // A background view laid over the transcript, in the same container as it.
    let probe = NSView(frame: pane.bounds)
    pane.addSubview(probe)
    try expect(probe.enclosingScrollView == nil, "fixture must reproduce the .background case")
    try expect(
      dshLocateEnclosingScrollView(from: probe) === transcript,
      "the covering scroll view must win over the first descendant (the sidebar)")

    // Ambiguous probe: no scroll view's window frame covers it, so it must get
    // nil rather than a stranger's pane.
    let floating = NSView(frame: NSRect(x: 2_200, y: 0, width: 100, height: 100))
    root.addSubview(floating)
    try expect(
      dshLocateEnclosingScrollView(from: floating) == nil,
      "a probe covered by no scroll view must not move an arbitrary pane")
  }
}


// MARK: - Gesture-aware pinning (fast-scroll fix)

/// Momentum is still running: a "near bottom" estimate comes from LazyVStack's
/// uncorrected heights, so nothing may pin yet.
private func testFollowPolicy_neverPinsDuringAnInteraction() throws {
  try expect(!DSHConversationScrollFollow.mayPin(isInteracting: true))
  try expect(DSHConversationScrollFollow.mayPin(isInteracting: false))
  try expect(
    !DSHConversationScrollFollow.mayFollowTail(isInteracting: true, force: false),
    "resize/new-message follow must wait for the interaction to end")
  try expect(
    DSHConversationScrollFollow.mayFollowTail(isInteracting: true, force: true),
    "the user's own send always scrolls")
  try expect(DSHConversationScrollFollow.mayFollowTail(isInteracting: false, force: false))
}

/// At rest the pin comes from AppKit's real geometry, ±24pt.
private func testFollowPolicy_pinsAtRestOnlyAtTheRealBottom() throws {
  try expect(DSHConversationScrollFollow.shouldPinAtRest(atRealBottom: true))
  try expect(!DSHConversationScrollFollow.shouldPinAtRest(atRealBottom: false))

  // 10 000pt of content, 600pt viewport.
  let contentHeight: CGFloat = 10_000
  let viewportHeight: CGFloat = 600
  let maxOffset = contentHeight - viewportHeight
  try expect(DSHConversationScrollFollow.isAtRealBottom(
    contentOffset: maxOffset, contentHeight: contentHeight, viewportHeight: viewportHeight))
  try expect(DSHConversationScrollFollow.isAtRealBottom(
    contentOffset: maxOffset - 23, contentHeight: contentHeight, viewportHeight: viewportHeight))
  try expect(!DSHConversationScrollFollow.isAtRealBottom(
    contentOffset: maxOffset - 25, contentHeight: contentHeight, viewportHeight: viewportHeight))
  // The bug: an over-estimated height made the ESTIMATED distance look small
  // while the real viewport was still 800pt above the bottom.
  try expect(!DSHConversationScrollFollow.isAtRealBottom(
    contentOffset: maxOffset - 800, contentHeight: contentHeight, viewportHeight: viewportHeight))
  // Degenerate geometry never reports "at bottom".
  try expect(!DSHConversationScrollFollow.isAtRealBottom(
    contentOffset: 0, contentHeight: 0, viewportHeight: 600))
}

/// The box must treat direct phase AND momentum phase as one interaction, and
/// only end it when both are gone.
private func testScrollBox_tracksMomentumAsAnInteraction() throws {
  try MainActor.assumeIsolated {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 10_000))
    let box = DSHTranscriptScrollViewBox()
    box.scrollView = scroll
    var edges: [Bool] = []
    box.onInteractionChange = { edges.append($0) }

    try expect(!box.isUserScrolling)
    box.noteScrollEvent(phase: .began, momentumPhase: [])
    try expect(box.isUserScrolling, "finger down")
    box.noteScrollEvent(phase: .ended, momentumPhase: [])
    try expect(!box.isUserScrolling, "finger up without momentum: interaction over")
    box.noteScrollEvent(phase: [.mayBegin], momentumPhase: .began)
    try expect(box.isUserScrolling, "coasting is still an interaction")
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 9_400))
    try expect((box.realBottomDistance ?? -1) <= 1, "AppKit truth at the bottom")
    box.noteScrollEvent(phase: [], momentumPhase: .ended)
    try expect(!box.isUserScrolling)
    try expectEqual(edges, [true, false, true, false])
  }
}

/// A gesture whose `.ended` vanished must expire by timestamp instead of
/// blocking the pin forever.
private func testScrollBox_expiresALostGestureEnd() throws {
  try MainActor.assumeIsolated {
    let box = DSHTranscriptScrollViewBox()
    box.scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    box.noteScrollEvent(phase: .began, momentumPhase: [])
    try expect(box.isUserScrolling)
    try expect(box.isUserScrolling, "still inside the stale window")
    box.expireGestureForTesting()
    try expect(!box.isUserScrolling, "timestamp expiry releases the gesture")
  }
}


// MARK: - Equatable rows must still publish row frames

/// A `.equatable()` row may be skipped by SwiftUI, so the row-frame preference
/// must be attached OUTSIDE the equatable scope. This pins the gate contract
/// that broke `capturedAnchor` (empty `rowFrames` -> silent height-delta
/// fallback): a pinned idle reader measures nothing, everything else measures.
private func testRowFrames_publishOutsideEquatable() throws {
  try MainActor.assumeIsolated {
    try expect(!DSHTranscriptMeasurementPolicy.shouldMeasure(
      pinned: true, isLoadingHistory: false, hasPendingRestore: false, force: false),
      "a pinned idle reader pays nothing")
    try expect(DSHTranscriptMeasurementPolicy.shouldMeasure(
      pinned: false, isLoadingHistory: false, hasPendingRestore: false, force: false),
      "an unpinned reader is measured")
    try expect(DSHTranscriptMeasurementPolicy.shouldMeasure(
      pinned: true, isLoadingHistory: true, hasPendingRestore: false, force: false),
      "a history batch is measured")
    try expect(DSHTranscriptMeasurementPolicy.shouldMeasure(
      pinned: true, isLoadingHistory: false, hasPendingRestore: true, force: false),
      "an armed restore is measured")
    try expect(DSHTranscriptMeasurementPolicy.shouldMeasure(
      pinned: true, isLoadingHistory: false, hasPendingRestore: false, force: true),
      "the probe switch forces measurement")
  }
}

// MARK: - Row height cache

/// A cached measurement is only valid for the same content version AND width;
/// a stale hit would freeze a row at an old height.
private func testHeightCache_keysOnContentVersionAndWidth() throws {
  try MainActor.assumeIsolated {
    DSHTranscriptHeightCache.removeAll()
    DSHTranscriptHeightCache.remember(id: "row", version: 7, width: 900, height: 128)
    try expectEqual(DSHTranscriptHeightCache.height(for: "row", version: 7, width: 900), 128)
    try expectEqual(DSHTranscriptHeightCache.height(for: "row", version: 8, width: 900), nil)
    try expectEqual(DSHTranscriptHeightCache.height(for: "row", version: 7, width: 700), nil)
    // A width change re-measures instead of reusing the old wrap: the new
    // measurement replaces the entry, and the old width no longer resolves
    // (only one height per row is kept — the layout can only have one).
    DSHTranscriptHeightCache.remember(id: "row", version: 7, width: 700, height: 190)
    try expectEqual(DSHTranscriptHeightCache.height(for: "row", version: 7, width: 700), 190)
    try expectEqual(DSHTranscriptHeightCache.height(for: "row", version: 7, width: 900), nil)
  }
}

let dshConversationScrollStabilityTests: [NamedTest] = [
  ("Scroll policy follows the tail only while pinned", testScrollPolicy_followsTailOnlyWhilePinned),
  ("Scroll policy follows a resize only while pinned", testScrollPolicy_resizeFollowsOnlyPinnedReader),
  ("Entry clamp recovers a blank page exactly once", testEntryClamp_recoversFromBlankOnlyOnce),
  ("Entry clamp recovers a visible blank strip", testEntryClamp_recoversAVisibleBlankStrip),
  ("Entry clamp ignores small overshoot and empty content", testEntryClamp_ignoresSmallOvershootAndEmptyContent),
  ("Entry clamp waits for gestures", testEntryClamp_waitsForGestures),
  ("Entry clamp never fights an in-flight gesture", testEntryClamp_neverFightsAnInFlightGesture),
  ("Entry clamp recovers from a lost gesture end", testEntryClamp_recoversFromALostGestureEnd),
  ("Restore needs the real viewport height", testRestore_needsTheRealViewportHeight),
  ("Restore waits for a new row layout generation", testRestore_waitsForANewRowLayoutGeneration),
  ("Restore height change alone never releases the row path", testRestore_heightChangeAloneNeverReleasesTheRowPath),
  ("Restore stands down when the reader moved away", testRestore_readerMovedAwayAbandonsTheWrite),
  ("Restore without a row anchor uses the height fallback", testRestore_withoutARowAnchorUsesTheHeightFallback),
  ("Scroll policy anchors on the topmost visible row", testScrollPolicy_firstVisibleRowIsTheTopmostIntersectingRow),
  ("Scroll policy captures the reading row before a prepend", testCapturedAnchor_mapsDocumentFramesToTheViewport),
  ("Scroll policy rejects viewport-space row frames", testCapturedAnchor_rejectsViewportSpaceFrames),
  ("Row estimate uses the rendered font metrics", testRowEstimate_usesTheRenderedFontMetrics),
  ("Locate finds a sibling-placed background's scroll view", testLocate_scrollViewFindsSiblingPlacedBackgrounds),
  ("Locate prefers the covering scroll view over the first one", testLocate_prefersTheCoveringScrollView),
  ("Row height cache keys on content version and width", testHeightCache_keysOnContentVersionAndWidth),
  ("Row frames stay measurable outside equatable rows", testRowFrames_publishOutsideEquatable),
  ("Follow policy never pins during an interaction", testFollowPolicy_neverPinsDuringAnInteraction),
  ("Follow policy pins at rest only at the real bottom", testFollowPolicy_pinsAtRestOnlyAtTheRealBottom),
  ("Scroll box tracks momentum as an interaction", testScrollBox_tracksMomentumAsAnInteraction),
  ("Scroll box expires a lost gesture end", testScrollBox_expiresALostGestureEnd),
]
