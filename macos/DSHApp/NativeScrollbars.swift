import SwiftUI
import AppKit

/// AppKit-level scroller control. Needed because with the system preference
/// "Show scroll bars: Always", SwiftUI scroll views (and TextEditor's inner
/// NSTextView) draw the legacy thick gutter scroller regardless of
/// `.scrollIndicators`.
///
/// Two modes:
/// - `.thin`   — overlay style, small knob: the translucent bar that appears
///               only while scrolling. For transcripts/lists.
/// - `.none`   — no scroller at all (scrolling still works via wheel and
///               trackpad). For the composer's auto-growing editor, where a
///               bar has nothing to say below the max height.
///
/// AppKit re-asserts scrollers on layout under the "always" preference, so a
/// one-shot configure isn't enough — the coordinator re-applies on every
/// bounds change of the scroll view's content.
struct ScrollerConfigurator: NSViewRepresentable {
  enum Mode { case thin, none }
  var mode: Mode = .thin
  /// Restrict to a scroll view whose document is an NSTextView — placement
  /// via `.background(...)` walks ancestors, and the composer must find its
  /// own field's scroll view, never the transcript's.
  var textViewOnly = false

  final class Coordinator {
    var observer: NSObjectProtocol?
    weak var scrollView: NSScrollView?
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
  }
  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSView {
    let view = DSHScrollerProbeView()
    view.coordinator = context.coordinator
    view.mode = mode
    view.textViewOnly = textViewOnly
    return view
  }
  func updateNSView(_ view: NSView, context: Context) {
    // Updates run after the hierarchy is attached. Configure synchronously so
    // the legacy gutter width cannot survive for one extra layout pass after
    // a transcript first receives content.
    guard let probe = view as? DSHScrollerProbeView else { return }
    probe.mode = mode
    probe.textViewOnly = textViewOnly
    probe.attachIfNeeded()
  }

  static func attach(
    from view: NSView,
    coordinator: Coordinator,
    mode: Mode,
    textViewOnly: Bool
  ) {
    if let current = coordinator.scrollView,
       !textViewOnly,
       dshScrollViewCovers(current, view) {
      // Already attached to the pane that covers us: keep the scroller style.
      apply(mode: mode, to: current)
      return
    }
    guard let scrollView = dshLocateEnclosingScrollView(from: view, accepting: { scroll in
      // The composer's field is the only NSTextView-backed scroll view, and a
      // document shorter than its viewport is a pane at rest (sidebar).
      !textViewOnly || scroll.documentView is NSTextView
    }) else { return }
    apply(mode: mode, to: scrollView)
    guard coordinator.scrollView !== scrollView else { return }
    if let old = coordinator.observer { NotificationCenter.default.removeObserver(old) }
    coordinator.scrollView = scrollView
    scrollView.contentView.postsBoundsChangedNotifications = true
    coordinator.observer = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification,
      object: scrollView.contentView,
      queue: .main
    ) { [weak scrollView] _ in
      guard let scrollView else { return }
      Self.apply(mode: mode, to: scrollView)
    }
  }

  static func apply(mode: Mode, to scrollView: NSScrollView) {
    scrollView.scrollerStyle = .overlay
    scrollView.autohidesScrollers = true
    scrollView.hasHorizontalScroller = false
    switch mode {
    case .thin:
      scrollView.hasVerticalScroller = true
      scrollView.verticalScroller?.controlSize = .small
    case .none:
      scrollView.hasVerticalScroller = false
      scrollView.verticalScroller?.isHidden = true
    }
  }
}

/// The configurator's `NSView`. Same lesson as the transcript bridge: the one
/// runloop retry fired before SwiftUI had built the scroll-view subtree, so the
/// thin overlay scroller never reached the transcript (`hasV=false`). Retry on
/// every hierarchy/layout change instead, and drop a stale attach.
final class DSHScrollerProbeView: NSView {
  weak var coordinator: ScrollerConfigurator.Coordinator?
  var mode: ScrollerConfigurator.Mode = .thin
  var textViewOnly = false

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
    guard let coordinator else { return }
    guard !isLocating else { return }
    isLocating = true
    defer { isLocating = false }
    ScrollerConfigurator.attach(
      from: self,
      coordinator: coordinator,
      mode: mode,
      textViewOnly: textViewOnly)
  }
}

/// Find the `NSScrollView` that belongs to a `.background(...)`-placed
/// representable.
///
/// `.background` puts the representable's view NEXT TO its scroll view in the
/// same container rather than inside `documentView`/`clipView`, so
/// `enclosingScrollView` alone often returns nil. Try it first, then walk up a
/// BOUNDED number of ancestors looking for a scroll-view subtree — the same
/// fallback the scroller configurator and the markdown position bridge have
/// always needed.
///
/// Deliberately bounded. Source order inside those ancestors is NOT meaningful:
/// once the walk reaches the hosting view it sees the sidebar and the composer as
/// well, and "first descendant" used to return the sidebar's scroll view. Collect
/// every candidate and keep only those whose window frame covers this view — a
/// `.background` view is laid out exactly over the scroll view it decorates.
/// Ambiguous means nil: moving the wrong pane is worse than retrying later.
func dshLocateEnclosingScrollView(
  from view: NSView,
  accepting accepts: (NSScrollView) -> Bool = { _ in true }
) -> NSScrollView? {
  if let enclosing = view.enclosingScrollView, accepts(enclosing) { return enclosing }
  var candidates: [NSScrollView] = []
  var seen = Set<ObjectIdentifier>()
  var ancestor = view.superview
  var hops = 0
  while let current = ancestor, hops < 5 {
    dshCollectScrollViews(in: current, accepting: accepts, into: &candidates, seen: &seen)
    ancestor = current.superview
    hops += 1
  }
  guard !candidates.isEmpty else { return nil }
  // NO single-candidate shortcut: the only candidate is often the sidebar's
  // scroll view, because the transcript's subtree is built later. Coverage is
  // what makes a candidate "ours"; without it the caller must retry.
  let frameInWindow = view.convert(view.bounds, to: nil)
  let covering = candidates.filter {
    $0.convert($0.bounds, to: nil).contains(NSPoint(x: frameInWindow.midX, y: frameInWindow.midY))
  }
  // Highest document wins; a small nested pane never beats the transcript.
  return covering.max { lhs, rhs in
    (lhs.documentView?.bounds.height ?? 0) < (rhs.documentView?.bounds.height ?? 0)
  }
}

/// Whether `scrollView` still covers `view`. Used to drop a stale/wrong attach
/// (e.g. a pane that was replaced, or the sidebar picked before the transcript
/// existed) and re-locate on the next layout pass.
func dshScrollViewCovers(_ scrollView: NSScrollView, _ view: NSView) -> Bool {
  guard scrollView.window != nil, view.window != nil else { return false }
  let frameInWindow = view.convert(view.bounds, to: nil)
  return scrollView.convert(scrollView.bounds, to: nil)
    .contains(NSPoint(x: frameInWindow.midX, y: frameInWindow.midY))
}

private func dshCollectScrollViews(
  in view: NSView,
  accepting accepts: (NSScrollView) -> Bool,
  into out: inout [NSScrollView],
  seen: inout Set<ObjectIdentifier>
) {
  if let scroll = view as? NSScrollView, accepts(scroll), seen.insert(ObjectIdentifier(scroll)).inserted {
    out.append(scroll)
  }
  for subview in view.subviews {
    dshCollectScrollViews(in: subview, accepting: accepts, into: &out, seen: &seen)
  }
}

extension View {
  /// Thin overlay scroller (appears while scrolling, no gutter).
  func dshThinScrollers() -> some View { background(ScrollerConfigurator(mode: .thin)) }
  /// No visible scroller at all; scrolling still works. Targets the nearest
  /// text-view-backed scroll view, for TextEditor via `.background` placement.
  func dshNoTextScrollers() -> some View { background(ScrollerConfigurator(mode: .none, textViewOnly: true)) }
}
