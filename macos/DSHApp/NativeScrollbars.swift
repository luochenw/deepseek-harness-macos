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
private struct ScrollerConfigurator: NSViewRepresentable {
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
    let view = NSView()
    DispatchQueue.main.async { attach(from: view, coordinator: context.coordinator) }
    return view
  }
  func updateNSView(_ view: NSView, context: Context) {
    DispatchQueue.main.async { attach(from: view, coordinator: context.coordinator) }
  }

  private func attach(from view: NSView, coordinator: Coordinator) {
    guard let scrollView = locate(from: view) else { return }
    apply(to: scrollView)
    guard coordinator.scrollView !== scrollView else { return }
    if let old = coordinator.observer { NotificationCenter.default.removeObserver(old) }
    coordinator.scrollView = scrollView
    scrollView.contentView.postsBoundsChangedNotifications = true
    coordinator.observer = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
    ) { [weak scrollView] _ in
      if let scrollView { self.apply(to: scrollView) }
    }
  }

  private func apply(to scrollView: NSScrollView) {
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

  private func locate(from view: NSView) -> NSScrollView? {
    if !textViewOnly, let enclosing = view.enclosingScrollView { return enclosing }
    var ancestor = view.superview
    var hops = 0
    while let current = ancestor, hops < 5 {
      if let found = descendantScrollView(in: current) { return found }
      ancestor = current.superview
      hops += 1
    }
    return nil
  }
  private func descendantScrollView(in view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView, !textViewOnly || scroll.documentView is NSTextView { return scroll }
    for subview in view.subviews {
      if let found = descendantScrollView(in: subview) { return found }
    }
    return nil
  }
}

extension View {
  /// Thin overlay scroller (appears while scrolling, no gutter).
  func dshThinScrollers() -> some View { background(ScrollerConfigurator(mode: .thin)) }
  /// No visible scroller at all; scrolling still works. Targets the nearest
  /// text-view-backed scroll view, for TextEditor via `.background` placement.
  func dshNoTextScrollers() -> some View { background(ScrollerConfigurator(mode: .none, textViewOnly: true)) }
}
