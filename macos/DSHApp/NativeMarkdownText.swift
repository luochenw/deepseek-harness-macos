import SwiftUI

/// Lightweight Markdown renderer for assistant transcript text. SwiftUI's
/// own `AttributedString(markdown:)` only understands inline spans (bold,
/// italic, code, links) and flattens block structure, so blocks are split
/// here by hand — headings, fenced code, lists, quotes, tables — and each
/// block delegates its inline spans back to `AttributedString`. No external
/// markdown dependency: the app is a single swiftc target (see the
/// no-xcode-project Agent Note) and this covers what model output actually
/// uses.
struct MarkdownText: View {
  let text: String

  private enum Block {
    case paragraph(String)
    case heading(Int, String)
    case code(String)
    case bullet([String])
    case numbered([(marker: String, text: String)])
    case quote(String)
    case table([String])
  }

  private struct IdentifiedBlock: Identifiable { let id: Int; let block: Block }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      ForEach(Self.parse(text)) { entry in
        blockView(entry.block)
      }
    }
  }

  @ViewBuilder private func blockView(_ block: Block) -> some View {
    switch block {
    case .paragraph(let content):
      Text(Self.inline(content))
        .font(.system(.body, design: .rounded)).foregroundStyle(DSHTheme.ink)
        .textSelection(.enabled)
    case .heading(let level, let content):
      Text(Self.inline(content))
        .font(.system(size: [17, 15.5, 14.5, 13.5, 13, 13][min(level, 6) - 1], weight: .semibold, design: .rounded))
        .foregroundStyle(DSHTheme.ink)
        .textSelection(.enabled)
        .padding(.top, 3)
    case .code(let content):
      CollapsibleCodeBlock(content: content)
    case .bullet(let items):
      VStack(alignment: .leading, spacing: 3) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
          HStack(alignment: .top, spacing: 7) {
            Text("•").foregroundStyle(DSHTheme.inkSoft)
            Text(Self.inline(item)).foregroundStyle(DSHTheme.ink).textSelection(.enabled)
          }.font(.system(.body, design: .rounded))
        }
      }
    case .numbered(let items):
      VStack(alignment: .leading, spacing: 3) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
          HStack(alignment: .top, spacing: 7) {
            Text(item.marker).foregroundStyle(DSHTheme.inkSoft).monospacedDigit()
            Text(Self.inline(item.text)).foregroundStyle(DSHTheme.ink).textSelection(.enabled)
          }.font(.system(.body, design: .rounded))
        }
      }
    case .quote(let content):
      HStack(alignment: .top, spacing: 9) {
        RoundedRectangle(cornerRadius: 1.5).fill(DSHTheme.inkFaint.opacity(0.5)).frame(width: 3)
        Text(Self.inline(content)).font(.system(.body, design: .rounded)).foregroundStyle(DSHTheme.inkSoft).textSelection(.enabled)
      }
    case .table(let rows):
      // Real grid, not monospaced pipes: cells split on `|`, first row is
      // the header (bolder, no divider line — grouping by weight/背景 per
      // the design convention here, not hard rules).
      let parsed = rows.map { row in
        row.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
          .components(separatedBy: "|")
          .map { $0.trimmingCharacters(in: .whitespaces) }
      }
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
        ForEach(Array(parsed.enumerated()), id: \.offset) { rowIndex, cells in
          GridRow {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
              Text(Self.inline(cell))
                .font(.system(size: 12.5, design: .rounded))
                .fontWeight(rowIndex == 0 ? .semibold : .regular)
                .foregroundStyle(rowIndex == 0 ? DSHTheme.ink : DSHTheme.inkSoft)
                .textSelection(.enabled)
            }
          }
        }
      }
      .padding(10)
      .background(DSHTheme.surfaceTint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
  }

  /// Inline spans (bold/italic/code/links) via Foundation's markdown parser;
  /// raw text untouched when parsing fails mid-stream on unbalanced markers.
  private static func inline(_ string: String) -> AttributedString {
    (try? AttributedString(
      markdown: string,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(string)
  }

  private static func parse(_ text: String) -> [IdentifiedBlock] {
    var blocks: [Block] = []
    var paragraph: [String] = []
    var codeLines: [String] = []
    var inFence = false
    var bullets: [String] = []
    var numbers: [(String, String)] = []
    var tableRows: [String] = []

    func flushParagraph() {
      if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
    }
    func flushLists() {
      if !bullets.isEmpty { blocks.append(.bullet(bullets)); bullets = [] }
      if !numbers.isEmpty { blocks.append(.numbered(numbers)); numbers = [] }
      if !tableRows.isEmpty { blocks.append(.table(tableRows)); tableRows = [] }
    }

    for rawLine in text.components(separatedBy: "\n") {
      let line = rawLine
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      if trimmed.hasPrefix("```") {
        if inFence {
          blocks.append(.code(codeLines.joined(separator: "\n")))
          codeLines = []
          inFence = false
        } else {
          flushParagraph(); flushLists()
          inFence = true
        }
        continue
      }
      if inFence { codeLines.append(line); continue }

      if trimmed.isEmpty { flushParagraph(); flushLists(); continue }

      if trimmed.hasPrefix("#"), let range = trimmed.range(of: "^#{1,6} +", options: .regularExpression) {
        flushParagraph(); flushLists()
        let level = trimmed.prefix(while: { $0 == "#" }).count
        blocks.append(.heading(level, String(trimmed[range.upperBound...])))
        continue
      }
      if trimmed.hasPrefix("|") {
        flushParagraph()
        if !bullets.isEmpty { blocks.append(.bullet(bullets)); bullets = [] }
        if !numbers.isEmpty { blocks.append(.numbered(numbers)); numbers = [] }
        // Divider rows (|---|---|) add nothing once the pipes are monospaced.
        if trimmed.range(of: "^\\|[ :\\-|]+\\|$", options: .regularExpression) == nil { tableRows.append(trimmed) }
        continue
      }
      if let range = trimmed.range(of: "^[-*+] +", options: .regularExpression) {
        flushParagraph()
        bullets.append(String(trimmed[range.upperBound...]))
        continue
      }
      if let range = trimmed.range(of: "^\\d+[.)] +", options: .regularExpression) {
        flushParagraph()
        let marker = String(trimmed[trimmed.startIndex..<range.upperBound]).trimmingCharacters(in: .whitespaces)
        numbers.append((marker, String(trimmed[range.upperBound...])))
        continue
      }
      if let range = trimmed.range(of: "^> ?", options: .regularExpression) {
        flushParagraph(); flushLists()
        blocks.append(.quote(String(trimmed[range.upperBound...])))
        continue
      }
      flushLists()
      paragraph.append(line)
    }
    // A fence left open mid-stream still renders as code, not raw backticks.
    if inFence, !codeLines.isEmpty { blocks.append(.code(codeLines.joined(separator: "\n"))) }
    flushParagraph()
    if !bullets.isEmpty { blocks.append(.bullet(bullets)) }
    if !numbers.isEmpty { blocks.append(.numbered(numbers)) }
    if !tableRows.isEmpty { blocks.append(.table(tableRows)) }

    return blocks.enumerated().map { IdentifiedBlock(id: $0.offset, block: $0.element) }
  }
}

/// Fenced code with Claude Code-style folding: long blocks default to their
/// first lines plus an expand toggle, so a pasted script doesn't swallow the
/// conversation. Short blocks render in full with no chrome.
private struct CollapsibleCodeBlock: View {
  let content: String
  @State private var expanded = false
  private static let collapseThreshold = 14
  private static let previewLines = 8
  var body: some View {
    let lines = content.components(separatedBy: "\n")
    let collapsible = lines.count > Self.collapseThreshold
    VStack(alignment: .leading, spacing: 6) {
      Text(collapsible && !expanded ? lines.prefix(Self.previewLines).joined(separator: "\n") : content)
        .font(.system(size: 12, design: .monospaced)).foregroundStyle(DSHTheme.ink)
        .textSelection(.enabled)
      if collapsible {
        Button(action: { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }) {
          Text(expanded ? "收起" : "… 展开全部 \(lines.count) 行")
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(DSHTheme.accent)
        }.buttonStyle(.plain)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(DSHTheme.surfaceTint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}
