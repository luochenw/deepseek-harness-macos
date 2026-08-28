import SwiftUI

enum MarkdownPresentation {
  case transcript
  case document
}

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
  var presentation: MarkdownPresentation = .transcript
  var baseURL: URL?
  var allowedFileRoot: URL?

  private enum Block {
    case paragraph(String)
    case heading(level: Int, text: String, anchor: String)
    case code(String)
    case bullet([String])
    case numbered([(marker: String, text: String)])
    case quote(String)
    case table([String])
    case image(alt: String, path: String)
  }

  private struct IdentifiedBlock: Identifiable { let id: Int; let block: Block }

  var body: some View {
    VStack(alignment: .leading, spacing: presentation == .document ? DSHSpace.s3 : 7) {
      ForEach(Self.parse(text)) { entry in
        blockView(entry.block)
      }
    }
  }

  @ViewBuilder private func blockView(_ block: Block) -> some View {
    switch block {
    case .paragraph(let content):
      Text(Self.inline(content))
        .font(paragraphFont).foregroundStyle(DSHTheme.ink)
        .textSelection(.enabled)
    case .heading(let level, let content, let anchor):
      Text(Self.inline(content))
        .font(headingFont(level))
        .foregroundStyle(DSHTheme.ink)
        .textSelection(.enabled)
        .padding(.top, presentation == .document ? DSHSpace.s3 : 3)
        .id(anchor)
    case .code(let content):
      CollapsibleCodeBlock(content: content, collapsesLongContent: presentation == .transcript)
    case .bullet(let items):
      VStack(alignment: .leading, spacing: 3) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
          HStack(alignment: .top, spacing: 7) {
            if let task = Self.taskItem(item) {
              Image(systemName: task.checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(task.checked ? DSHTheme.accent : DSHTheme.inkFaint)
              Text(Self.inline(task.text)).foregroundStyle(DSHTheme.ink).textSelection(.enabled)
            } else {
              Text("•").foregroundStyle(DSHTheme.inkSoft)
              Text(Self.inline(item)).foregroundStyle(DSHTheme.ink).textSelection(.enabled)
            }
          }.font(paragraphFont)
        }
      }
    case .numbered(let items):
      VStack(alignment: .leading, spacing: 3) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
          HStack(alignment: .top, spacing: 7) {
            Text(item.marker).foregroundStyle(DSHTheme.inkSoft).monospacedDigit()
            Text(Self.inline(item.text)).foregroundStyle(DSHTheme.ink).textSelection(.enabled)
          }.font(paragraphFont)
        }
      }
    case .quote(let content):
      HStack(alignment: .top, spacing: 9) {
        RoundedRectangle(cornerRadius: 1.5).fill(DSHTheme.inkFaint.opacity(0.5)).frame(width: 3)
        Text(Self.inline(content)).font(paragraphFont).foregroundStyle(DSHTheme.inkSoft).textSelection(.enabled)
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
      ScrollView(.horizontal) {
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
      }
      .padding(10)
      .background(DSHTheme.surfaceTint, in: RoundedRectangle(cornerRadius: DSHRadius.sm, style: .continuous))
    case .image(let alt, let path):
      markdownImage(alt: alt, path: path)
    }
  }

  private var paragraphFont: Font {
    presentation == .document ? .system(size: 14, design: .rounded) : .system(.body, design: .rounded)
  }

  private func headingFont(_ level: Int) -> Font {
    let transcriptSizes: [CGFloat] = [17, 15.5, 14.5, 13.5, 13, 13]
    let documentSizes: [CGFloat] = [24, 19, 16, 14.5, 14, 14]
    let sizes = presentation == .document ? documentSizes : transcriptSizes
    return .system(size: sizes[min(level, 6) - 1], weight: .semibold, design: .rounded)
  }

  @ViewBuilder private func markdownImage(alt: String, path: String) -> some View {
    if let url = Self.resourceURL(
      path,
      baseURL: baseURL,
      allowedFileRoot: allowedFileRoot) {
      if url.isFileURL {
        MarkdownLocalImage(
          url: url,
          alt: alt,
          allowedFileRoot: allowedFileRoot)
      } else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
        Link(destination: url) {
          Label(alt.isEmpty ? path : alt, systemImage: "photo")
            .font(.caption)
        }
      } else {
        Label(alt.isEmpty ? path : alt, systemImage: "photo")
          .font(.caption).foregroundStyle(DSHTheme.inkFaint)
      }
    } else {
      Label(alt.isEmpty ? path : alt, systemImage: "photo")
        .font(.caption).foregroundStyle(DSHTheme.inkFaint)
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

  static func headings(in text: String) -> [DSHMarkdownHeading] {
    parse(text).compactMap { entry in
      guard case .heading(let level, let title, let anchor) = entry.block else { return nil }
      return DSHMarkdownHeading(level: level, title: title, anchor: anchor)
    }
  }

  static func anchor(_ title: String) -> String {
    let lowered = title.lowercased()
    let pieces = lowered.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    return pieces.isEmpty ? "section" : pieces.joined(separator: "-")
  }

  static func resourceURL(
    _ path: String,
    baseURL: URL?,
    allowedFileRoot: URL? = nil
  ) -> URL? {
    if let absolute = URL(string: path), absolute.scheme != nil {
      if !absolute.isFileURL { return absolute }
      guard baseURL != nil else { return nil }
      guard let allowedFileRoot else { return absolute.standardizedFileURL }
      return DSHModelWorkbenchTool.authorizedFileURL(absolute, within: allowedFileRoot)
    }
    guard let baseURL else { return nil }
    let resolved = URL(
      fileURLWithPath: path.removingPercentEncoding ?? path,
      relativeTo: baseURL).standardizedFileURL
    guard let allowedFileRoot else { return resolved }
    return DSHModelWorkbenchTool.authorizedFileURL(resolved, within: allowedFileRoot)
  }

  private static func taskItem(_ item: String) -> (checked: Bool, text: String)? {
    let lower = item.lowercased()
    if lower.hasPrefix("[ ] ") { return (false, String(item.dropFirst(4))) }
    if lower.hasPrefix("[x] ") { return (true, String(item.dropFirst(4))) }
    return nil
  }

  private static func parse(_ text: String) -> [IdentifiedBlock] {
    var blocks: [Block] = []
    var paragraph: [String] = []
    var codeLines: [String] = []
    var inFence = false
    var bullets: [String] = []
    var numbers: [(String, String)] = []
    var tableRows: [String] = []
    var headingCounts: [String: Int] = [:]

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

      if let image = markdownImage(in: trimmed) {
        flushParagraph(); flushLists()
        blocks.append(.image(alt: image.alt, path: image.path))
        continue
      }
      if trimmed.hasPrefix("#"), let range = trimmed.range(of: "^#{1,6} +", options: .regularExpression) {
        flushParagraph(); flushLists()
        let level = trimmed.prefix(while: { $0 == "#" }).count
        let title = String(trimmed[range.upperBound...])
        let baseAnchor = anchor(title)
        let duplicate = headingCounts[baseAnchor, default: 0]
        headingCounts[baseAnchor] = duplicate + 1
        blocks.append(.heading(
          level: level,
          text: title,
          anchor: duplicate == 0 ? baseAnchor : "\(baseAnchor)-\(duplicate)"))
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

  private static func markdownImage(in line: String) -> (alt: String, path: String)? {
    guard line.hasPrefix("!["),
          let altEnd = line.firstIndex(of: "]"),
          line.index(after: altEnd) < line.endIndex,
          line[line.index(after: altEnd)] == "(",
          line.hasSuffix(")") else { return nil }
    let altStart = line.index(line.startIndex, offsetBy: 2)
    let pathStart = line.index(altEnd, offsetBy: 2)
    let pathEnd = line.index(before: line.endIndex)
    guard altStart <= altEnd, pathStart <= pathEnd else { return nil }
    return (String(line[altStart..<altEnd]), String(line[pathStart..<pathEnd]))
  }
}

private struct MarkdownLocalImage: View {
  let url: URL
  let alt: String
  let allowedFileRoot: URL?
  @State private var image: NSImage?
  @State private var failed = false

  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s1) {
      if let image {
        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
      } else if failed {
        Label(alt.isEmpty ? url.lastPathComponent : alt, systemImage: "photo.badge.exclamationmark")
          .font(.caption).foregroundStyle(DSHTheme.inkFaint)
      } else {
        ProgressView().frame(maxWidth: .infinity, minHeight: 80)
      }
      if image != nil, !alt.isEmpty {
        Text(alt).font(.caption).foregroundStyle(DSHTheme.inkFaint)
      }
    }
    .padding(DSHSpace.s2)
    .background(DSHTheme.surfaceTint, in: RoundedRectangle(cornerRadius: DSHRadius.md, style: .continuous))
    .task(id: url) {
      let data: Data? = await Task.detached(priority: .utility) {
        try? DSHVerifiedFile.readData(
          url,
          within: allowedFileRoot,
          maxBytes: 20 * 1024 * 1024)
      }.value
      image = data.flatMap(NSImage.init(data:))
      failed = image == nil
    }
  }
}

/// Fenced code with Claude Code-style folding: long blocks default to their
/// first lines plus an expand toggle, so a pasted script doesn't swallow the
/// conversation. Short blocks render in full with no chrome. Not `private`:
/// the transcript's inline tool rows reuse it for terminal/read/search output.
struct CollapsibleCodeBlock: View {
  let content: String
  var collapsesLongContent = true
  @State private var expanded = false
  private static let collapseThreshold = 14
  private static let previewLines = 8
  var body: some View {
    let lines = content.components(separatedBy: "\n")
    let collapsible = collapsesLongContent && lines.count > Self.collapseThreshold
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
    .background(DSHTheme.surfaceTint, in: RoundedRectangle(cornerRadius: DSHRadius.sm, style: .continuous))
  }
}
