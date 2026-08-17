import SwiftUI
import AppKit

/// Forces the enclosing NSScrollView into thin overlay scrollers — the
/// modern translucent bar that appears only while scrolling and never
/// reserves a gutter. Needed at the AppKit level because with the system
/// preference "Show scroll bars: Always", SwiftUI scroll views draw the
/// legacy thick gutter scroller regardless of `.scrollIndicators`.
///
/// Usage: attach `.dshThinScrollers()` to the ScrollView's *content* (it
/// must sit inside the scroll view to find it via `enclosingScrollView`).
/// Reapplied on every SwiftUI update, which also survives AppKit resetting
/// the style when the system preference changes.
private struct ScrollerConfigurator: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async { Self.configure(from: view) }
    return view
  }
  func updateNSView(_ view: NSView, context: Context) {
    DispatchQueue.main.async { Self.configure(from: view) }
  }
  private static func configure(from view: NSView) {
    guard let scrollView = locate(from: view) else { return }
    scrollView.scrollerStyle = .overlay
    scrollView.autohidesScrollers = true
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.verticalScroller?.controlSize = .small
  }

  /// `enclosingScrollView` covers content placement; the fallback ancestor
  /// walk covers `.background(...)` placement on views like TextEditor,
  /// whose scroll view is a sibling subtree rather than an ancestor.
  private static func locate(from view: NSView) -> NSScrollView? {
    if let enclosing = view.enclosingScrollView { return enclosing }
    var ancestor = view.superview
    var hops = 0
    while let current = ancestor, hops < 4 {
      if let found = descendantScrollView(in: current) { return found }
      ancestor = current.superview
      hops += 1
    }
    return nil
  }
  private static func descendantScrollView(in view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView { return scroll }
    for subview in view.subviews {
      if let found = descendantScrollView(in: subview) { return found }
    }
    return nil
  }
}

extension View {
  func dshThinScrollers() -> some View { background(ScrollerConfigurator()) }
}
