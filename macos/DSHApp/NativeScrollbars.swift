import SwiftUI
import AppKit

/// Truly hides the enclosing NSScrollView's scrollers. SwiftUI's
/// `.scrollIndicators(.hidden)` is advisory on macOS: when the system
/// preference is "Show scroll bars: Always", the legacy (thick, gutter-style)
/// scroller still draws. This walks up from inside the scroll content to the
/// AppKit scroll view and removes the scrollers outright — scrolling itself
/// (wheel, trackpad, scrollTo) is unaffected.
///
/// Usage: attach `.dshHiddenScrollers()` to the ScrollView's *content* (it
/// must sit inside the scroll view to find it via `enclosingScrollView`).
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
    guard let scrollView = view.enclosingScrollView else { return }
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    scrollView.scrollerStyle = .overlay
    scrollView.autohidesScrollers = true
  }
}

extension View {
  func dshHiddenScrollers() -> some View { background(ScrollerConfigurator()) }
}
