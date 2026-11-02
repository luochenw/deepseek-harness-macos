import SwiftUI

extension View {
  /// Start a row at its remembered height and record the height it got;
  /// `minHeight` so a stale entry can only make a row taller, never clip it.
  /// `isLive` / `isCollapsible` rows opt out: a streamed height fed back as
  /// `minHeight` pads the row for good once the stream shrinks or ends.
  func dshTranscriptCachedHeight(
    id: String,
    version: Int,
    width: CGFloat,
    estimate: CGFloat,
    isLive: Bool = false,
    isCollapsible: Bool = false,
    isEmpty: Bool = false
  ) -> some View {
    modifier(DSHTranscriptCachedHeightModifier(
      id: id,
      version: version,
      width: width,
      estimate: estimate,
      mode: DSHTranscriptRowHeightPolicy.mode(isLive: isLive, isCollapsible: isCollapsible),
      isEmpty: isEmpty))
  }
}

private struct DSHTranscriptCachedHeightModifier: ViewModifier {
  let id: String
  let version: Int
  let width: CGFloat
  let estimate: CGFloat
  let mode: DSHTranscriptRowHeightPolicy.Mode
  let isEmpty: Bool
  /// Height this row's CONTENT last rendered at, in every mode.
  @State private var measured: CGFloat?

  func body(content: Content) -> some View {
    let cached = DSHTranscriptRowHeightPolicy.shouldReadCache(mode)
      ? DSHTranscriptHeightCache.height(for: id, version: version, width: width)
      : nil
    let base = DSHTranscriptRowHeightPolicy.minHeight(
      cached: cached,
      estimate: estimate,
      isEmpty: isEmpty)
    // Replaces `base`: a floor under the real height is a permanent blank band.
    let target = isEmpty ? 0 : (measured ?? base)
    content
      // On the CONTENT, before the min-height frame, or it measures its own padding.
      .onGeometryChange(for: CGFloat.self) { proxy in
        proxy.size.height
      } action: { height in
        if height > 0.5, height != measured { measured = height }
        guard DSHTranscriptRowHeightPolicy.shouldWriteCache(mode, height: height) else {
          if isEmpty || height <= 1 { DSHTranscriptHeightCache.invalidate(id: id) }
          return
        }
        DSHTranscriptHeightCache.remember(id: id, version: version, width: width, height: height)
      }
      .frame(minHeight: target, alignment: .top)
      .onChange(of: version) { _, _ in measured = nil }
      .onChange(of: isEmpty) { _, empty in if empty { measured = nil } }
  }
}
