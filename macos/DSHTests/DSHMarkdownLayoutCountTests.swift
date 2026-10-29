import AppKit
import Foundation
import SwiftUI
@testable import DSHAppLib

// MARK: - A long reply must be parsed once, not once per layout pass
//
// Opening a session with a long Markdown answer produced >50ms frames on
// 2026-10-29. The measurement split (see the note) says the frame is NOT
// repeated parsing: `NativeMarkdownText` already caches blocks and inline
// spans, and the worst frames record zero parses. What the cache does buy is
// that the cost is paid ONCE, so these tests pin that: the same text laid out
// several times may parse once and build each inline span once.
//
// Counted, never timed, and no fixture: the text is synthesised here.

/// A reply of the shape that was slow: headings, prose paragraphs, a list and a
/// fenced block, ~20 KB.
private func longMarkdownReply(paragraphs: Int = 120) -> String {
  var lines = ["## 结论", ""]
  for index in 0..<paragraphs {
    lines.append("第 \(index) 段：这段文字用来说明当时的取舍，包含 `code` 与 **加粗**，")
    lines.append("并且刻意写长一些，让换行和行高测量都有真实的工作量。")
    lines.append("")
    if index % 8 == 3 {
      lines.append("- 要点一：缓存键要包含内容与宽度")
      lines.append("- 要点二：流式行不能因此变慢")
      lines.append("")
    }
  }
  lines.append("```swift")
  lines.append("let cached = parsedBlockCache[text]")
  lines.append("```")
  return lines.joined(separator: "\n")
}

@MainActor
private func hostMarkdown(_ text: String, width: CGFloat = 720) -> (NSWindow, NSHostingView<AnyView>) {
  let root = AnyView(
    MarkdownText(text: text)
      .frame(width: width, alignment: .leading)
      .background(DSHTheme.canvas))
  let hosting = NSHostingView(rootView: root)
  hosting.frame = NSRect(x: 0, y: 0, width: width, height: 1_200)
  let window = NSWindow(
    contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: 1_200),
    styleMask: .borderless, backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentView = hosting
  window.orderFrontRegardless()
  return (window, hosting)
}

/// ① One text, mounted three times (a reader opening the session, scrolling it
/// away and back): exactly ONE block parse. Each mount is a fresh hosting view,
/// so this cannot pass by accident — without the cache every mount re-parses.
private func testMarkdownLayout_parsesEachTextOnce() throws {
  try MainActor.assumeIsolated {
    let text = longMarkdownReply()
    try expect(text.utf8.count > 20_000, "the synthetic reply must be long enough to matter")
    _ = NSApplication.shared
    NSApp.appearance = NSAppearance(named: .aqua)

    DSHTranscriptPerf.isEnabled = true
    defer { DSHTranscriptPerf.isEnabled = false }
    DSHTranscriptPerf.markdownParses = 0
    DSHTranscriptPerf.markdownInlineBuilds = 0
    DSHTranscriptPerf.markdownParseCacheHits = 0

    for _ in 0..<3 {
      let (window, hosting) = hostMarkdown(text)
      hosting.layoutSubtreeIfNeeded()
      for _ in 0..<2 {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        hosting.layoutSubtreeIfNeeded()
      }
      window.orderOut(nil)
      window.close()
    }

    let parses = DSHTranscriptPerf.markdownParses
    print("  markdown: 3 mounts → \(parses) parse(s),"
      + " \(DSHTranscriptPerf.markdownInlineBuilds) inline build(s),"
      + " \(DSHTranscriptPerf.markdownParseCacheHits) block hits")
    try expect(parses == 1,
               "the same reply was block-parsed \(parses) times across 3 mounts; it must be"
                 + " parsed once and served from the cache afterwards")
    try expect(DSHTranscriptPerf.markdownParseCacheHits >= 2,
               "only \(DSHTranscriptPerf.markdownParseCacheHits) block cache hits for 3 mounts")
  }
}

/// ② The cache is keyed by CONTENT: two different replies of the same length are
/// parsed separately, so a stale entry can never paint the wrong text.
private func testMarkdownLayout_differentTextParsesSeparately() throws {
  try MainActor.assumeIsolated {
    let first = longMarkdownReply(paragraphs: 12)
    var second = first
    second = second.replacingOccurrences(of: "第 3 段", with: "第 3 節")
    try expect(first != second, "the two texts must differ")
    try expectEqual(first.utf8.count, second.utf8.count)

    _ = NSApplication.shared
    NSApp.appearance = NSAppearance(named: .aqua)
    DSHTranscriptPerf.isEnabled = true
    defer { DSHTranscriptPerf.isEnabled = false }
    DSHTranscriptPerf.markdownParses = 0

    for text in [first, second] {
      let (window, hosting) = hostMarkdown(text)
      hosting.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.03))
      hosting.layoutSubtreeIfNeeded()
      window.orderOut(nil)
      window.close()
    }
    try expectEqual(DSHTranscriptPerf.markdownParses, 2)
  }
}

let dshMarkdownLayoutCountTests: [NamedTest] = [
  ("Markdown: a long reply is parsed once across layout passes",
   testMarkdownLayout_parsesEachTextOnce),
  ("Markdown: different text of equal length parses separately",
   testMarkdownLayout_differentTextParsesSeparately),
]
