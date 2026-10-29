import Foundation
import SwiftUI

/// Opt-in counters for the transcript scroll path; when `isEnabled` is false
/// every call site is one predictable branch, so production behaviour is unchanged.
enum DSHTranscriptPerf {
  #if DEBUG
  /// Debug-only and off by default; a probe/test arms them before layout.
  static var isEnabled = false
  static var forceRowFrames = false
  #else
  /// Release builds compile the counters out and no caller needs an `#if`.
  static let isEnabled = false
  static let forceRowFrames = false
  #endif

  static var bodyEvaluations = 0
  static var rowEvaluations = 0
  static var rowAppearances = 0
  static var rowFrameDeliveries = 0
  static var bottomDistanceDeliveries = 0
  static var contentHeightDrift: Double = 0
  static var heightCacheHits = 0
  static var heightCacheMisses = 0
  static var heightCacheWrites = 0
  static var metricDeliveries = 0
  static var metricLargestStep: Double = 0
  /// The string a `ToolGroupRow` last drew; a golden test catches `==` ignoring the digest.
  static var renderedGroupTitle: String?
}

/// Per-row measured heights, keyed by row id and content version: starting a
/// re-mounted row at its measured height keeps the first layout the final one.
@MainActor
enum DSHTranscriptHeightCache {
  private struct Entry {
    let version: Int
    let height: CGFloat
    let widthBucket: Int
    let sequence: Int
  }

  private static var entries: [String: Entry] = [:]
  private static var sequence = 0
  private static let limit = 2_000

  static func remember(id: String, version: Int, width: CGFloat, height: CGFloat) {
    // Drop, not skip: a leftover entry resurrects a stale tall height later.
    guard height > 1 else {
      entries.removeValue(forKey: id)
      return
    }
    let bucket = Int(width.rounded())
    if let existing = entries[id],
       existing.version == version,
       existing.widthBucket == bucket,
       abs(existing.height - height) < 0.5 {
      return
    }
    sequence += 1
    if DSHTranscriptPerf.isEnabled { DSHTranscriptPerf.heightCacheWrites += 1 }
    entries[id] = Entry(version: version, height: height, widthBucket: bucket, sequence: sequence)
    if entries.count > limit { prune() }
  }

  static func height(for id: String, version: Int, width: CGFloat) -> CGFloat? {
    let found = lookup(id: id, version: version, width: width)
    if DSHTranscriptPerf.isEnabled {
      if found == nil { DSHTranscriptPerf.heightCacheMisses += 1 } else { DSHTranscriptPerf.heightCacheHits += 1 }
    }
    return found
  }

  private static func lookup(id: String, version: Int, width: CGFloat) -> CGFloat? {
    guard let entry = entries[id],
          entry.version == version,
          entry.widthBucket == Int(width.rounded())
    else { return nil }
    return entry.height
  }

  static func removeAll() {
    entries.removeAll(keepingCapacity: true)
    sequence = 0
  }

  private static func prune() {
    let keep = entries.sorted { $0.value.sequence > $1.value.sequence }.prefix(limit / 2)
    entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
  }

  /// A stale entry for a shortened row becomes permanent blank (`minHeight` only grows).
  static func invalidate(id: String) {
    entries.removeValue(forKey: id)
  }
}

/// Whether a transcript row may use the remembered `minHeight`, as a pure policy
/// so the stale-live-row and expanded-collapsed-row cases are unit-testable.
enum DSHTranscriptRowHeightPolicy: Equatable {
  /// `off`: no remembered height; `live`: never read or write (a streaming
  /// measurement is one frame of a moving target); `cached`: both.
  enum Mode: Equatable { case off, live, cached }

  static func mode(isLive: Bool, isCollapsible: Bool) -> Mode {
    if isCollapsible { return .off }
    return isLive ? .live : .cached
  }

  /// A cache hit wins over the estimate; a row with no content gets no padding.
  static func minHeight(
    cached: CGFloat?,
    estimate: CGFloat,
    isEmpty: Bool
  ) -> CGFloat {
    guard !isEmpty else { return 0 }
    return max(cached ?? 0, max(0, estimate))
  }

  static func shouldReadCache(_ mode: Mode) -> Bool { mode == .cached }
  static func shouldWriteCache(_ mode: Mode, height: CGFloat) -> Bool {
    mode == .cached && height > 1
  }
}

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
