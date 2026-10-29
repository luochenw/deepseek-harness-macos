import AppKit
import Foundation
import OSLog
import SwiftUI

/// Where the reader's viewport sat when older history started loading.
struct DSHTranscriptScrollAnchor: Equatable {
  /// First row that intersects the viewport top, when one was measured.
  let firstVisibleRowID: String?
  /// Row top relative to the viewport top: `0` when the row starts exactly at the top edge,
  /// negative once the reader has scrolled into it.
  let rowOffsetInViewport: CGFloat
  let rowHeight: CGFloat?
  let contentOffset: CGFloat
  let contentHeight: CGFloat
}

/// Pure scroll policy for the transcript.
enum DSHConversationScrollPolicy {
  /// One transcript update that used to compete for the viewport.
  enum Trigger: Equatable {
    /// Tail row identity or one of its rendered fields changed.
    case tailContentChanged
    /// A turn started or settled in place (the tail row swapped).
    case runningStateChanged
    /// Pending steering prompts appeared or disappeared.
    case steeringChanged
    /// A background older-history batch finished.
    case olderHistoryFinished
  }

  /// Follow the tail only while the user is pinned there.
  static func shouldFollowTail(pinned: Bool, trigger: Trigger) -> Bool {
    switch trigger {
    case .tailContentChanged, .runningStateChanged, .steeringChanged, .olderHistoryFinished:
      return pinned
    }
  }

  /// A transcript resize is not a follow request by itself: LazyVStack height corrections happen
  /// all the time.
  static func shouldFollowAfterResize(
    pinned: Bool,
    previousContentHeight: CGFloat,
    contentHeight: CGFloat
  ) -> Bool {
    guard pinned else { return false }
    guard previousContentHeight > 0 else { return false }
    return abs(contentHeight - previousContentHeight) > 0.5
  }

  /// Clamp a scroll offset to the range the current content can actually show.
  static func clampedOffset(
    _ offset: CGFloat,
    contentHeight: CGFloat,
    viewportHeight: CGFloat
  ) -> CGFloat {
    let maximum = max(0, contentHeight - viewportHeight)
    return min(maximum, max(0, offset))
  }

  /// The offset that shows the newest content — the only offset entry and follow mode ever
  /// request.
  static func tailOffset(contentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
    max(0, contentHeight - viewportHeight)
  }

  /// Entry clamp is a one-shot correction of a viewport parked past the last row — i.e.
  static let entryClampTolerance: CGFloat = 2

  static func entryClampTarget(
    offset: CGFloat,
    contentHeight: CGFloat,
    viewportHeight: CGFloat
  ) -> CGFloat? {
    guard contentHeight > 0, viewportHeight > 0 else { return nil }
    let maximum = tailOffset(contentHeight: contentHeight, viewportHeight: viewportHeight)
    guard offset > maximum + entryClampTolerance else { return nil }
    return maximum
  }

  /// Restore the pre-prepend reading position once an older-history batch settles.
  static func shouldRestoreAfterPrepend(pinned: Bool, anchor: DSHTranscriptScrollAnchor?) -> Bool {
    guard !pinned, let anchor else { return false }
    return anchor.contentHeight > 0
  }

  /// Content offset that keeps `anchor`'s visible row where the reader left it.
  static func restoredContentOffset(
    for anchor: DSHTranscriptScrollAnchor,
    newContentHeight: CGFloat,
    viewportHeight: CGFloat
  ) -> CGFloat {
    let insertedAbove = newContentHeight - anchor.contentHeight
    return clampedOffset(
      anchor.contentOffset + insertedAbove,
      contentHeight: newContentHeight,
      viewportHeight: viewportHeight)
  }

  /// Row-identity restore: if the anchored row is laid out again, move the viewport so that row's
  /// DOCUMENT-space top minus the row's old viewport offset gives the new content offset.
  static func restoredContentOffset(
    for anchor: DSHTranscriptScrollAnchor,
    rowFrame: CGRect?,
    contentHeight: CGFloat,
    viewportHeight: CGFloat
  ) -> CGFloat {
    if let rowFrame, rowFrame.height > 0 {
      return clampedOffset(
        rowFrame.minY - anchor.rowOffsetInViewport,
        contentHeight: contentHeight,
        viewportHeight: viewportHeight)
    }
    return restoredContentOffset(
      for: anchor,
      newContentHeight: contentHeight,
      viewportHeight: viewportHeight)
  }

  /// Pick the row that currently covers the viewport top.
  static func firstVisibleRow(
    frames: [String: CGRect],
    viewportHeight: CGFloat
  ) -> (id: String, offset: CGFloat, height: CGFloat)? {
    guard viewportHeight > 0 else { return nil }
    var best: (id: String, offset: CGFloat, height: CGFloat)?
    for (id, frame) in frames where frame.height > 0 {
      guard frame.maxY > 0, frame.minY < viewportHeight else { continue }
      guard let current = best else {
        best = (id: id, offset: frame.minY, height: frame.height)
        continue
      }
      // Prefer the row straddling the top edge (largest minY at or above it); when every candidate
      // starts below the edge, prefer the closest one.
      let candidateAbove = frame.minY <= 0
      let currentAbove = current.offset <= 0
      let replaces: Bool
      switch (candidateAbove, currentAbove) {
      case (true, false): replaces = true
      case (false, true): replaces = false
      case (true, true): replaces = frame.minY > current.offset
      case (false, false): replaces = frame.minY < current.offset
      }
      if replaces {
        best = (id: id, offset: frame.minY, height: frame.height)
      }
    }
    return best
  }
}

/// Deterministic row metrics for the transcript: the collapsed single-line rows (whose height is
/// font metrics plus padding, never text length) and a conservative estimate for message rows
/// before they are measured.
enum DSHTranscriptRowEstimate {
  static let statusRowVerticalPadding: CGFloat = 5
  static let reasoningRowVerticalPadding: CGFloat = 4
  static let accessoryVerticalPadding: CGFloat = 2

  /// Font sizes come from `DSHType`'s exported numeric constants — the same values the rendered
  /// rows use, so the estimate cannot drift from them.
  static let toolTitleFontSize: CGFloat = DSHType.monoSize
  static let accessoryFontSize: CGFloat = DSHType.microSize
  static let reasoningTitleFontSize: CGFloat = DSHType.labelSize
  static let reasoningStatusFontSize: CGFloat = DSHType.captionSize

  static func lineHeight(of font: NSFont) -> CGFloat {
    (font.ascender - font.descender + font.leading).rounded(.up)
  }

  static func lineHeight(fontSize: CGFloat, weight: NSFont.Weight = .regular, monospaced: Bool = false) -> CGFloat {
    let font = monospaced
      ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: weight)
      : NSFont.systemFont(ofSize: fontSize, weight: weight)
    return lineHeight(of: font)
  }

  /// Collapsed status row height: the tallest single line in the row plus the row's vertical
  /// padding, so wrapping/font changes still fit.
  static func collapsedStatusRowHeight(
    lines: [CGFloat],
    verticalPadding: CGFloat
  ) -> CGFloat {
    let tallest = lines.map { $0.rounded(.up) }.max() ?? 0
    return tallest + verticalPadding * 2
  }

  static func toolStatusRowHeight(accessory: Bool) -> CGFloat {
    var lines = [lineHeight(fontSize: toolTitleFontSize, monospaced: true)]
    if accessory {
      lines.append(lineHeight(fontSize: accessoryFontSize, weight: .medium) + accessoryVerticalPadding * 2)
    }
    return collapsedStatusRowHeight(lines: lines, verticalPadding: statusRowVerticalPadding)
  }

  static func reasoningStatusRowHeight(status: Bool) -> CGFloat {
    var lines = [lineHeight(fontSize: reasoningTitleFontSize, weight: .medium)]
    if status {
      lines.append(lineHeight(fontSize: reasoningStatusFontSize))
    }
    return collapsedStatusRowHeight(lines: lines, verticalPadding: reasoningRowVerticalPadding)
  }

  /// Rough height for a message row before it is measured.
  static func messageHeight(_ message: HarnessController.Message, width: CGFloat) -> CGFloat {
    guard width > 0 else { return 0 }
    let usable = max(120, width - DSHSpace.s4 * 2 - DSHSpace.s6 * 2)
    switch message.role {
    case .tool:
      // A single tool message has no resolved activity here, so the accessory line cannot be
      // predicted; the measured height corrects it.
      return toolStatusRowHeight(accessory: false)
    case .system:
      return wrappedHeight(
        text: message.text,
        usable: usable,
        widthOf: { Self.width($0, fontSize: 14) },
        lineHeight: lineHeight(fontSize: 14),
        lineSpacing: 3)
    case .user, .assistant:
      let body = message.text.isEmpty ? (message.reasoning ?? "") : message.text
      if body.isEmpty, message.attachment != nil { return 180 }
      return wrappedHeight(
        text: body,
        usable: usable,
        widthOf: { Self.width($0, fontSize: 14.5) },
        lineHeight: 22,
        lineSpacing: 5
      ) + DSHSpace.s3 * 2 + 8
    }
  }

  /// Approximate advance width of one character at `fontSize`: CJK, kana, Hangul, full-width forms
  /// and most emoji are about one em, Latin ~0.55 em.
  static func width(_ character: Character, fontSize: CGFloat) -> CGFloat {
    let scalars = character.unicodeScalars
    guard let first = scalars.first else { return fontSize * 0.55 }
    let value = first.value
    let wide =
      (0x1100...0x115F).contains(value)      // Hangul Jamo
      || (0x2E80...0x303E).contains(value)   // CJK radicals, punctuation
      || (0x3041...0x33FF).contains(value)   // kana, CJK compat
      || (0x3400...0x4DBF).contains(value)   // CJK ext A
      || (0x4E00...0x9FFF).contains(value)   // CJK unified
      || (0xA000...0xA4CF).contains(value)   // Yi
      || (0xAC00...0xD7A3).contains(value)   // Hangul syllables
      || (0xF900...0xFAFF).contains(value)   // CJK compat ideographs
      || (0xFE30...0xFE6F).contains(value)   // CJK compat forms
      || (0xFF00...0xFF60).contains(value)   // full-width forms
      || (0xFFE0...0xFFE6).contains(value)
      || (0x1F300...0x1FAFF).contains(value) // emoji
      || (0x20000...0x3FFFD).contains(value) // CJK ext B+
    if wide { return fontSize }
    if character == "\t" { return fontSize * 2 }
    return fontSize * 0.55
  }

  /// Height of `text` wrapped at `usable` points: `lines` line boxes plus the spacing BETWEEN them
  /// (SwiftUI's `lineSpacing` is not added after the last).
  static func wrappedHeight(
    text: String,
    usable: CGFloat,
    widthOf: (Character) -> CGFloat,
    lineHeight: CGFloat,
    lineSpacing: CGFloat
  ) -> CGFloat {
    guard !text.isEmpty else { return 0 }
    var lines = 1
    var lineWidth: CGFloat = 0
    for character in text {
      if character == "\n" {
        lines += 1
        lineWidth = 0
        continue
      }
      let advance = widthOf(character)
      if lineWidth > 0, lineWidth + advance > usable {
        lines += 1
        lineWidth = advance
      } else {
        lineWidth += advance
      }
    }
    let total = CGFloat(lines)
    return total * lineHeight + (total - 1) * lineSpacing
  }
}

/// One layout pass of the transcript, measured from inside the scroll view.
struct DSHTranscriptLayoutMetrics: Equatable {
  var contentHeight: CGFloat = 0

  var isEmpty: Bool { contentHeight <= 0 }
}

/// Per-row frames of the laid-out rows, keyed by transcript row id.
struct DSHTranscriptRowFrameKey: PreferenceKey {
  static var defaultValue: [String: CGRect] = [:]
  static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
    value.merge(nextValue()) { _, new in new }
  }
}

struct DSHTranscriptLayoutMetricsKey: PreferenceKey {
  static var defaultValue = DSHTranscriptLayoutMetrics()
  static func reduce(value: inout DSHTranscriptLayoutMetrics, nextValue: () -> DSHTranscriptLayoutMetrics) {
    let next = nextValue()
    if !next.isEmpty { value = next }
  }
}

extension DSHConversationScrollPolicy {
  /// Capture the anchor from DOCUMENT-space row frames plus the live content offset.
  static func capturedAnchor(
    contentOffset: CGFloat,
    contentHeight: CGFloat,
    documentRowFrames: [String: CGRect],
    viewportHeight: CGFloat
  ) -> DSHTranscriptScrollAnchor {
    let viewportFrames = documentRowFrames.mapValues {
      $0.offsetBy(dx: 0, dy: -contentOffset)
    }
    let visible = firstVisibleRow(frames: viewportFrames, viewportHeight: viewportHeight)
    return DSHTranscriptScrollAnchor(
      firstVisibleRowID: visible?.id,
      rowOffsetInViewport: visible?.offset ?? 0,
      rowHeight: visible?.height,
      contentOffset: contentOffset,
      contentHeight: contentHeight)
  }
}

/// Holds the latest document-space measurements outside SwiftUI's state graph.
@MainActor
final class DSHTranscriptMeasurementStore {
  private(set) var rowFrames: [String: CGRect] = [:]
  private(set) var contentHeight: CGFloat = 0
  /// Content-bottom-to-viewport-bottom distance of the latest layout.
  private(set) var bottomDistance: CGFloat = 0
  /// Bumped only when ROW FRAMES change.
  private(set) var rowGeneration = 0
  /// Bumped by any real layout delivery (rows or height).
  private(set) var heightGeneration = 0

  private var pendingAnchor: DSHTranscriptScrollAnchor?
  private var pendingRowGeneration = 0
  private var pendingHeightGeneration = 0
  private var pendingSince = Date()

  /// How long a pending restore may wait for a row-frame layout before the height-delta fallback
  /// is allowed.
  static let restoreFallbackDelay: TimeInterval = 1.2

  var hasPendingRestore: Bool { pendingAnchor != nil }

  func update(rowFrames frames: [String: CGRect]) {
    guard frames != rowFrames else { return }
    rowFrames = frames
    rowGeneration += 1
    heightGeneration += 1
  }

  func update(contentHeight height: CGFloat) {
    guard abs(height - contentHeight) > 0.5 else { return }
    contentHeight = height
    heightGeneration += 1
  }

  func update(bottomDistance distance: CGFloat) {
    bottomDistance = distance
  }

  func reset() {
    rowFrames = [:]
    contentHeight = 0
    bottomDistance = 0
    pendingAnchor = nil
    rowGeneration += 1
    heightGeneration += 1
  }

  /// Content offset of the latest layout: the live clip origin when the bridge is attached,
  /// otherwise derived from the measured bottom distance (exact, because both come from the same
  /// viewport-space content frame).
  func contentOffset(viewportHeight: CGFloat) -> CGFloat {
    max(0, contentHeight - bottomDistance - viewportHeight)
  }

  func captureAnchor(contentOffset: CGFloat, viewportHeight: CGFloat) -> DSHTranscriptScrollAnchor {
    DSHConversationScrollPolicy.capturedAnchor(
      contentOffset: contentOffset,
      contentHeight: contentHeight,
      documentRowFrames: rowFrames,
      viewportHeight: viewportHeight)
  }

  /// Arm a one-shot restore.
  func beginRestore(
    _ anchor: DSHTranscriptScrollAnchor,
    liveContentOffset: CGFloat? = nil,
    hasRowAnchor: Bool = true
  ) {
    pendingAnchor = anchor
    pendingRowGeneration = rowGeneration
    pendingHeightGeneration = heightGeneration
    pendingSince = Date()
    pendingLiveOffset = liveContentOffset
    // C: no mounted row at capture time (the prefetch only keeps the tail laid out).
    pendingRequiresHeightFallback = !hasRowAnchor
  }

  static let restoreMovementTolerance: CGFloat = 2
  private var pendingLiveOffset: CGFloat?
  private var pendingRequiresHeightFallback = false

  enum RestorePath: Equatable {
    /// A row-layout pass newer than the capture landed: use the row frame.
    case rowLayout
    /// Waited out `restoreFallbackDelay` without a row pass: use the height delta.
    case heightFallback
  }

  /// Whether the armed restore may run now, and via which path.
  func restorePath(now: Date = Date()) -> RestorePath? {
    guard pendingAnchor != nil, contentHeight > 0 else { return nil }
    if pendingRequiresHeightFallback {
      return now.timeIntervalSince(pendingSince) >= Self.restoreFallbackDelay ? .heightFallback : nil
    }
    if rowGeneration > pendingRowGeneration { return .rowLayout }
    if heightGeneration > pendingHeightGeneration,
       now.timeIntervalSince(pendingSince) >= Self.restoreFallbackDelay {
      return .heightFallback
    }
    return nil
  }

  /// True when the viewport moved away from where the reader was standing.
  func readerMovedAway(liveContentOffset: CGFloat) -> Bool {
    guard let anchor = pendingAnchor else { return false }
    if abs(liveContentOffset - anchor.contentOffset) > Self.restoreMovementTolerance {
      return true
    }
    if let expected = pendingLiveOffset,
       abs(liveContentOffset - expected) > Self.restoreMovementTolerance {
      return true
    }
    return false
  }

  /// Consume the armed restore (one-shot) together with the path to use.
  func takePendingRestore(now: Date = Date()) -> (anchor: DSHTranscriptScrollAnchor, path: RestorePath)? {
    guard let path = restorePath(now: now), let anchor = pendingAnchor else { return nil }
    pendingAnchor = nil
    pendingLiveOffset = nil
    pendingRequiresHeightFallback = false
    return (anchor, path)
  }

  func cancelRestore() {
    pendingAnchor = nil
    pendingLiveOffset = nil
    pendingRequiresHeightFallback = false
  }
}

/// Finds the transcript's `NSScrollView` so the entry pass can be clamped to content that actually
/// exists, and so a restored reading position can be written back.
struct DSHTranscriptScrollViewBridge: NSViewRepresentable {
  let box: DSHTranscriptScrollViewBox
  /// Reports a successful attach.
  var onAttach: (() -> Void)?

  final class Coordinator {
    weak var scrollView: NSScrollView?
    var isAttached = false
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSView {
    let view = DSHTranscriptScrollProbeView()
    view.coordinator = context.coordinator
    view.box = box
    view.onAttach = onAttach
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    guard let probe = view as? DSHTranscriptScrollProbeView else { return }
    probe.box = box
    probe.onAttach = onAttach
    probe.attachIfNeeded()
  }

  func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    // Only clear the shared box when it still points at OUR scroll view: SwiftUI does not
    // guarantee a replaced bridge is dismantled before the new one attaches, and an unconditional
    // clear would leave the new session detached.
    if let scrollView = coordinator.scrollView, box.scrollView === scrollView {
      box.scrollView = nil
    }
    coordinator.scrollView = nil
    coordinator.isAttached = false
  }
}

/// The representable's `NSView`, which retries the lookup whenever AppKit tells it the hierarchy
/// changed.
final class DSHTranscriptScrollProbeView: NSView {
  weak var coordinator: DSHTranscriptScrollViewBridge.Coordinator?
  weak var box: DSHTranscriptScrollViewBox?
  var onAttach: (() -> Void)?

  private var isLocating = false

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    attachIfNeeded()
  }

  override func layout() {
    super.layout()
    attachIfNeeded()
  }

  func attachIfNeeded() {
    guard let coordinator, let box else { return }
    // Re-validate an existing attach: a bridge that locked onto a pane which does not cover it
    // (the sidebar, picked before the transcript existed) must be dropped, not trusted for the
    // rest of the session.
    if coordinator.isAttached {
      if let current = coordinator.scrollView,
         current.window != nil,
         dshScrollViewCovers(current, self),
         box.scrollView === current {
        return
      }
      coordinator.isAttached = false
      coordinator.scrollView = nil
      if let current = box.scrollView, !dshScrollViewCovers(current, self) {
        box.scrollView = nil
      }
    }
    guard !isLocating else { return }
    isLocating = true
    defer { isLocating = false }
    guard let scrollView = dshLocateEnclosingScrollView(from: self, accepting: { candidate in
      // Transcript-side validation: the composer's scroll view has an NSTextView document, and a
      // document shorter than its viewport is a pane at rest (sidebar), not the transcript.
      guard !(candidate.documentView is NSTextView) else { return false }
      let viewportHeight = candidate.contentView.bounds.height
      let documentHeight = candidate.documentView?.bounds.height ?? 0
      guard viewportHeight > 0, documentHeight >= viewportHeight else { return false }
      // Coverage is checked again here (not only inside locate) so a future caller of
      // `dshLocateEnclosingScrollView` cannot bypass it.
      return true
    }), dshScrollViewCovers(scrollView, self) else { return }
    coordinator.scrollView = scrollView
    coordinator.isAttached = true
    box.scrollView = scrollView
    DispatchQueue.main.async { [onAttach] in onAttach?() }
  }
}

/// Entry clamp state + offset writes for the transcript's `NSScrollView`.
@MainActor
final class DSHTranscriptScrollViewBox {
  weak var scrollView: NSScrollView?
  /// At most one entry clamp per session.
  private(set) var didClampEntry = false
  private var isGestureInProgress = false
  /// True between a direct-phase `.began` and its `.ended`: the finger is on the trackpad.
  private var isDirectPhaseActive = false
  private var isMomentumActive = false

  /// Called whenever an interaction starts or ends, so the view can re-evaluate the pin at rest
  /// and flush a deferred tail follow.
  var onInteractionChange: ((Bool) -> Void)?
  var trace: ((String) -> Void)?

  var isAvailable: Bool { scrollView != nil }
  var contentOffset: CGFloat { scrollView?.contentView.bounds.origin.y ?? 0 }
  var viewportHeight: CGFloat { scrollView?.contentView.bounds.height ?? 0 }
  var contentHeight: CGFloat { scrollView?.documentView?.bounds.height ?? 0 }

  /// AppKit-truth bottom distance. `nil` when the bridge is not attached.
  var realBottomDistance: CGFloat? {
    guard let scrollView else { return nil }
    let height = scrollView.documentView?.bounds.height ?? 0
    let viewport = scrollView.contentView.bounds.height
    guard height > 0, viewport > 0 else { return nil }
    return max(0, height - (scrollView.contentView.bounds.origin.y + viewport))
  }

  func resetEntryClamp() { didClampEntry = false }

  /// Track the user's own scroll gesture so entry clamping never lands in the middle of one, and
  /// so nothing pins the viewport while they are scrolling.
  static let gestureStaleInterval: TimeInterval = 1.2
  private var lastPhaseChange = Date()

  func noteScrollEvent(phase: NSEvent.Phase, momentumPhase: NSEvent.Phase) {
    let before = isUserScrolling
    if phase.contains(.began) || phase.contains(.changed) {
      isDirectPhaseActive = true
    }
    if phase.contains(.ended) || phase.contains(.cancelled) {
      isDirectPhaseActive = false
    }
    if momentumPhase.contains(.began) || momentumPhase.contains(.changed) {
      isMomentumActive = true
    }
    if momentumPhase.contains(.ended) || momentumPhase.contains(.cancelled) {
      isMomentumActive = false
    }
    // A direct phase and its momentum tail are separate NSEvent streams: only the momentum end (or
    // a stale timestamp) ends the interaction.
    isGestureInProgress = isDirectPhaseActive || isMomentumActive
    lastPhaseChange = Date()
    let after = isGestureInProgress
    if before != after {
      trace?("pin-interaction \(after ? "begin" : "end") direct=\(isDirectPhaseActive) momentum=\(isMomentumActive)")
      onInteractionChange?(after)
    }
  }

  func noteScrollPhase(_ phase: NSEvent.Phase) {
    noteScrollEvent(phase: phase, momentumPhase: [])
  }

  /// True while the reader is holding/wheeling the transcript; used to decide whether a restore
  /// may write the viewport at all.
  var isUserScrolling: Bool {
    if isGestureInProgress,
       Date().timeIntervalSince(lastPhaseChange) > Self.gestureStaleInterval {
      isGestureInProgress = false
      isDirectPhaseActive = false
      isMomentumActive = false
      trace?("pin-interaction end stale-timeout")
      onInteractionChange?(false)
    }
    return isGestureInProgress
  }

  /// Test seam for the lost-`.ended` path: pretend the gesture started long ago.
  func noteScrollPhaseExpiredForTesting() {
    lastPhaseChange = Date()
    isGestureInProgress = true
  }

  /// Test seam: jump past `gestureStaleInterval` without waiting in real time.
  func expireGestureForTesting() {
    lastPhaseChange = Date().addingTimeInterval(-(Self.gestureStaleInterval + 0.1))
    isGestureInProgress = true
  }

  /// Clamp the viewport back onto the content, once per session, and only for a viewport parked
  /// past the last row (ANY visible blank at the bottom, not just a whole blank page).
  @discardableResult
  func clampOnEntry() -> Bool {
    guard !didClampEntry, let scrollView else { return false }
    let clip = scrollView.contentView
    let contentHeight = scrollView.documentView?.bounds.height ?? 0
    let viewportHeight = clip.bounds.height
    // No usable layout yet — stay armed; ConversationView re-triggers this on every content-height
    // change, so "the next real layout" does exist now.
    guard contentHeight > 0, viewportHeight > 0 else { return false }
    // A live resize or an in-flight gesture would be fought by a write here; leave the flag armed
    // so a later pass still gets its one chance.
    guard !scrollView.inLiveResize, !isUserScrolling else { return false }
    // A healthy offset keeps the flag armed for a later blank pass.
    guard let target = DSHConversationScrollPolicy.entryClampTarget(
      offset: clip.bounds.origin.y,
      contentHeight: contentHeight,
      viewportHeight: viewportHeight)
    else { return false }
    didClampEntry = true
    let before = clip.bounds.origin.y
    clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
    scrollView.reflectScrolledClipView(clip)
    DSHScrollTrace.log(
      "clampOnEntry", before: before, after: clip.bounds.origin.y,
      contentHeight: contentHeight, pinned: false, gesture: isGestureInProgress)
    return true
  }

  /// Write a restored offset.
  func setContentOffset(_ offset: CGFloat) {
    guard let scrollView else { return }
    let clip = scrollView.contentView
    let contentHeight = scrollView.documentView?.bounds.height ?? 0
    let clamped = DSHConversationScrollPolicy.clampedOffset(
      offset,
      contentHeight: contentHeight,
      viewportHeight: clip.bounds.height)
    let before = clip.bounds.origin.y
    clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clamped))
    scrollView.reflectScrolledClipView(clip)
    DSHScrollTrace.log(
      "setContentOffset", before: before, after: clip.bounds.origin.y,
      contentHeight: contentHeight, pinned: false, gesture: isGestureInProgress,
      extra: "requested=\(String(format: "%.1f", offset))")
  }
}

enum DSHScrollTrace {
  static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "DSH", category: "scroll-trace")

  /// One line per viewport write / pin flip / interaction edge.
  static func log(
    _ writer: String,
    before: CGFloat?,
    after: CGFloat?,
    contentHeight: CGFloat?,
    pinned: Bool,
    gesture: Bool,
    extra: String = ""
  ) {
    func fmt(_ value: CGFloat?) -> String {
      guard let value else { return "-" }
      return String(format: "%.1f", value)
    }
    logger.info(
      "writer=\(writer, privacy: .public) before=\(fmt(before), privacy: .public) after=\(fmt(after), privacy: .public) contentH=\(fmt(contentHeight), privacy: .public) pinned=\(pinned, privacy: .public) gesture=\(gesture, privacy: .public) \(extra, privacy: .public)")
  }
}

extension View {
  /// Anchor the transcript at the bottom for the FIRST layout pass only
  /// (`ScrollAnchorRole.initialOffset`). ① is a macOS 15+ fix: the 14.x fallback keeps the old
  /// behaviour, which can re-anchor on content-size changes.
  @ViewBuilder
  func dshInitialBottomScrollAnchor() -> some View {
    if #available(macOS 15.0, *) {
      self.defaultScrollAnchor(.bottom, for: .initialOffset)
    } else {
      self.defaultScrollAnchor(.bottom)
    }
  }

  /// Publish one row's frame in the transcript's document coordinate space, keyed by transcript
  /// row id.
  func dshTranscriptRowFrame(id: String) -> some View {
    background(GeometryReader { proxy in
      Color.clear.preference(
        key: DSHTranscriptRowFrameKey.self,
        value: [id: proxy.frame(in: DSHConversationScrollGeometry.documentSpace)])
    })
  }

  /// Row-frame measurement is only needed while a reading position can be captured or restored
  /// (the reader scrolled away from the tail, or older history is loading).
  @ViewBuilder
  func dshTranscriptRowFrameIfNeeded(id: String, enabled: Bool) -> some View {
    if enabled {
      dshTranscriptRowFrame(id: id)
    } else {
      self
    }
  }

  /// The transcript's document coordinate space.
  func dshTranscriptDocumentSpace() -> some View {
    coordinateSpace(name: DSHConversationScrollGeometry.documentSpaceName)
  }
}

enum DSHConversationScrollGeometry {
  static let documentSpaceName = "dshConversationContent"
  static let documentSpace: CoordinateSpace = .named(documentSpaceName)
  /// Viewport-relative space used by the bottom-distance / content-height probe.
  static let viewportSpaceName = "dshConversationScroll"
  static let viewportSpace: CoordinateSpace = .named(viewportSpaceName)
}

/// When the transcript needs per-row frames at all.
enum DSHTranscriptMeasurementPolicy {
  static func shouldMeasure(
    pinned: Bool,
    isLoadingHistory: Bool,
    hasPendingRestore: Bool,
    force: Bool
  ) -> Bool {
    if force { return true }
    return !pinned || isLoadingHistory || hasPendingRestore
  }
}
