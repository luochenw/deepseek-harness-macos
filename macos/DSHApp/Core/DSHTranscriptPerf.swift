import Foundation

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
  /// `ToolGroupRow.init` calls: a row that is destroyed and rebuilt by
  /// LazyVStack recycling increments this again, and its `@State` starts over.
  static var toolGroupMounts = 0
  /// How many group bodies were composed with the group OPEN, and how many with
  /// it closed. A row that comes back from LazyVStack recycling composes its
  /// first body closed (its `@State` started over), so these two counts are the
  /// direct evidence for "the expanded row folded itself".
  static var groupBodiesExpanded = 0
  static var groupBodiesCollapsed = 0
  /// Set by the row whenever its toggle flips; a test can assert the user's
  /// flip is not followed by a silent collapse.
  static var groupToggleFlips = 0
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
  /// Group digests actually built (cache misses). A layout pass that changes
  /// nothing must not add to this — that is the freeze's unit of work.
  static var toolGroupDigestBuilds = 0
  /// Commands classified (one `callKind` pass per command per digest build).
  /// Counted rather than timed, so the assertion is stable on any machine.
  static var toolGroupClassifications = 0
  /// Markdown work actually performed — a block parse or an inline
  /// `AttributedString(markdown:)` build — and the parse-cache hits that avoided
  /// one. A reply re-laid out across passes must parse once; repeats are the defect.
  static var markdownParses = 0
  static var markdownInlineBuilds = 0
  static var markdownParseCacheHits = 0

  /// Requests that tried to scroll the transcript to its tail, including the
  /// ones coalesced away, and the ones that actually ran. A single expand must
  /// not produce an unbounded run of them: that would be the height → follow →
  /// relayout loop the 2026-10-29 freeze was suspected of.
  static var tailScrollRequests = 0
  static var tailScrollExecutions = 0
  /// Tail-scroll requests dropped because the viewport was already at the tail.
  static var tailScrollSuppressed = 0
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
