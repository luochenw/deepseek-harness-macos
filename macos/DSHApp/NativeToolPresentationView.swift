import SwiftUI

/// Native details renderer for the structured DSH tool presentation payload.
/// The workbench adds card chrome; the transcript reuses the same content body
/// in compact mode so both places stay faithful to the Host render intent.
struct NativeToolPresentationView: View {
  let tool: HarnessController.ToolActivity

  var body: some View {
    Card(
      icon: ToolPresentationChrome.icon(for: tool),
      title: ToolPresentationChrome.title(for: tool)
    ) {
      ToolPresentationContent(tool: tool, compact: false)
    } trailing: {
      ToolPresentationStatus(tool: tool)
    }
  }
}

struct ToolPresentationContent: View {
  let tool: HarnessController.ToolActivity
  let compact: Bool

  var body: some View {
    if let presentation = tool.presentation {
      switch presentation.card {
      case "terminal":
        terminal(presentation)
      case "diff":
        diff(presentation)
      case "read":
        read(presentation)
      case "search":
        search(presentation)
      case "web":
        web(presentation)
      default:
        ToolOutputBlock(text: presentation.output ?? tool.output)
      }
    } else if tool.state == .running {
      Text("运行中…")
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(DSHTheme.inkFaint)
    } else {
      ToolOutputBlock(text: tool.output)
    }
  }

  @ViewBuilder private func terminal(_ view: HarnessController.ToolPresentation) -> some View {
    VStack(alignment: .leading, spacing: DSHSpace.s2) {
      if let description = view.description {
        Text(description).font(.caption).foregroundStyle(DSHTheme.inkSoft)
      }
      if let cwd = view.cwd {
        Label(cwd, systemImage: "folder")
          .font(.caption.monospaced())
          .foregroundStyle(DSHTheme.inkSoft)
      }
      HStack(spacing: DSHSpace.s2) {
        Text("$").foregroundStyle(DSHTheme.inkFaint)
        Text(view.title ?? tool.name).textSelection(.enabled)
      }
      .font(.system(.caption, design: .monospaced).weight(.medium))
      ToolOutputBlock(text: view.output ?? tool.output)
      if compact, let status = ToolPresentationChrome.statusText(for: tool) {
        DSHBadge(text: status.text, tone: status.tone)
      }
    }
  }

  @ViewBuilder private func diff(_ view: HarnessController.ToolPresentation) -> some View {
    if view.diffs.isEmpty {
      ToolOutputBlock(text: view.output ?? "没有可展示的差异。")
    } else {
      VStack(alignment: .leading, spacing: compact ? DSHSpace.s2 : DSHSpace.s3) {
        ForEach(view.diffs) { item in
          ToolDiffFile(item: item, compact: compact)
        }
      }
    }
  }

  @ViewBuilder private func read(_ view: HarnessController.ToolPresentation) -> some View {
    VStack(alignment: .leading, spacing: DSHSpace.s2) {
      if let path = view.path { ToolPathView(path: path, compact: compact) }
      if let total = view.totalLines {
        Text("显示 \(view.lines.count) / \(total) 行\(view.lang.map { " · \($0)" } ?? "")")
          .font(.caption2)
          .foregroundStyle(DSHTheme.inkSoft)
      }
      if view.lines.isEmpty {
        ToolOutputBlock(text: view.output ?? "文件为空。")
      } else {
        ToolSourceLines(lines: view.lines, language: view.lang)
      }
    }
  }

  @ViewBuilder private func search(_ view: HarnessController.ToolPresentation) -> some View {
    VStack(alignment: .leading, spacing: DSHSpace.s2) {
      if view.searchShape == "matches" || view.searchShape == "paths" {
        ToolSearchRows(
          files: view.files,
          paths: view.paths,
          query: ToolPresentationFormatting.extractQuery(from: view.title),
          compact: compact)
      } else {
        ToolOutputBlock(text: tool.output)
      }
      if view.truncated {
        DSHBadge(
          text: view.total.map { "已显示部分结果（共 \($0) 条）" } ?? "已显示部分结果",
          tone: .warm)
      }
    }
  }

  @ViewBuilder private func web(_ view: HarnessController.ToolPresentation) -> some View {
    VStack(alignment: .leading, spacing: DSHSpace.s2) {
      if view.webKind == "fetch", let url = view.url {
        ToolURLLabel(url: url)
        if let statusCode = view.statusCode {
          DSHBadge(
            text: "HTTP \(statusCode)",
            tone: (200...299).contains(statusCode) ? .accent : .coral)
        }
        if let body = view.output ?? view.answer, !body.isEmpty {
          ToolOutputBlock(text: body)
        }
      } else {
        if let answer = view.answer, !answer.isEmpty {
          Text(answer).font(.caption).textSelection(.enabled)
        }
        if !view.sources.isEmpty {
          ToolWebSources(sources: view.sources)
        } else if view.answer == nil {
          ToolOutputBlock(text: tool.output)
        }
      }
      if view.truncated { DSHBadge(text: "结果已截断", tone: .warm) }
    }
  }
}

private enum ToolPresentationChrome {
  struct Status {
    let text: String
    let tone: DSHBadge.Tone
  }

  static func title(for tool: HarnessController.ToolActivity) -> String {
    guard let view = tool.presentation else { return tool.name }
    switch view.card {
    case "read": return view.title ?? view.path ?? "读取文件"
    case "diff": return view.title ?? "文件更改"
    case "web": return view.title ?? (view.webKind == "fetch" ? "网页抓取" : "网页搜索")
    case "terminal": return view.title ?? "终端"
    default: return view.title ?? tool.name
    }
  }

  static func icon(for tool: HarnessController.ToolActivity) -> String {
    switch tool.presentation?.card {
    case "terminal": "terminal"
    case "diff": "arrow.left.arrow.right"
    case "read": "doc.text"
    case "search": "magnifyingglass"
    case "web": "globe"
    default: "wrench.and.screwdriver"
    }
  }

  static func statusText(for tool: HarnessController.ToolActivity) -> Status? {
    let view = tool.presentation
    guard let label = DSHTerminalStatus.label(
      exitCode: view?.exitCode,
      signal: view?.signal,
      isRunning: tool.state == .running)
    else { return nil }
    if view?.signal != nil { return Status(text: label, tone: .warm) }
    if let exitCode = view?.exitCode { return Status(text: label, tone: exitCode == 0 ? .accent : .coral) }
    return Status(text: label, tone: .warm)
  }
}

private struct ToolPresentationStatus: View {
  let tool: HarnessController.ToolActivity

  @ViewBuilder var body: some View {
    if let status = ToolPresentationChrome.statusText(for: tool) {
      DSHBadge(text: status.text, tone: status.tone)
    } else if tool.state == .running {
      ProgressView().controlSize(.small)
    }
  }
}

private struct ToolDiffFile: View {
  let item: HarnessController.ToolPresentation.Diff
  let compact: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s1) {
      ToolPathView(path: item.path, compact: compact)
      DiffLines(old: item.oldText, new: item.newText).equatable()
    }
    .padding(compact ? 0 : DSHSpace.s2)
    .modifier(ToolDiffChrome(enabled: !compact))
  }
}

private struct ToolDiffChrome: ViewModifier {
  let enabled: Bool

  func body(content: Content) -> some View {
    if enabled {
      content.dshCard(tint: DSHTheme.surfaceTint2, radius: DSHRadius.sm)
    } else {
      content
    }
  }
}

private struct ToolPathView: View {
  let path: String
  let compact: Bool

  var body: some View {
    if DSHToolPresentationLayout.showsFileActions(compact: compact) {
      FilePathActions(path: path)
    } else {
      Label(path, systemImage: "doc")
        .font(.caption.monospaced())
        .foregroundStyle(DSHTheme.inkSoft)
        .textSelection(.enabled)
        .lineLimit(1)
    }
  }
}

private struct ToolURLLabel: View {
  @EnvironmentObject private var harness: HarnessController
  let url: String

  var body: some View {
    if let destination = DSHToolPresentationURL.webURL(url) {
      Button(action: { harness.newBrowserWorkbench(url: destination) }) {
        HStack(alignment: .firstTextBaseline, spacing: DSHSpace.s1) {
          Text(url).font(.caption.monospaced()).lineLimit(2).multilineTextAlignment(.leading)
          Image(systemName: "sidebar.right").font(.caption2)
        }
      }
      .buttonStyle(.plain)
      .foregroundStyle(DSHTheme.accent)
      .help("在工作台浏览器中打开")
    } else {
      Text(url)
        .font(.caption.monospaced())
        .foregroundStyle(DSHTheme.inkSoft)
        .textSelection(.enabled)
    }
  }
}

private struct ToolOutputBlock: View {
  let text: String
  @State private var expanded = false

  var body: some View {
    let clean = text.strippingANSI()
    let lines = clean.components(separatedBy: "\n")
    let window = DSHDisclosureWindow.slice(count: lines.count, expanded: expanded)
    VStack(alignment: .leading, spacing: DSHSpace.s1) {
      if clean.isEmpty {
        Text("没有输出。")
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(DSHTheme.inkFaint)
      } else {
        ToolPlainLines(lines: lines, range: window.head)
        if window.isCollapsed {
          ToolDisclosureButton(hiddenCount: window.hiddenCount, expanded: expanded) {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
          }
          ToolPlainLines(lines: lines, range: window.tail)
        } else if lines.count > 16 {
          ToolDisclosureButton(hiddenCount: 0, expanded: expanded) {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
          }
        }
      }
    }
    .padding(DSHSpace.s2)
    .background(DSHTheme.surfaceTint, in: RoundedRectangle(cornerRadius: DSHRadius.sm, style: .continuous))
  }
}

private struct ToolPlainLines: View {
  let lines: [String]
  let range: Range<Int>

  var body: some View {
    Text(lines[range].joined(separator: "\n"))
      .font(.system(.caption, design: .monospaced))
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct ToolSourceLines: View {
  let lines: [HarnessController.ToolPresentation.FileLine]
  let language: String?
  @State private var expanded = false

  var body: some View {
    let tokens = DSHSourceTokenizer.tokens(in: lines.map(\.text), language: language)
    let window = DSHDisclosureWindow.slice(count: lines.count, expanded: expanded)
    VStack(alignment: .leading, spacing: 0) {
      SourceLineList(lines: lines, tokens: tokens, range: window.head)
      if window.isCollapsed {
        ToolDisclosureButton(hiddenCount: window.hiddenCount, expanded: expanded) {
          withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        }
        SourceLineList(lines: lines, tokens: tokens, range: window.tail)
      } else if lines.count > 16 {
        ToolDisclosureButton(hiddenCount: 0, expanded: expanded) {
          withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        }
      }
    }
    .padding(DSHSpace.s2)
    .background(DSHTheme.surfaceTint2, in: RoundedRectangle(cornerRadius: DSHRadius.sm, style: .continuous))
  }
}

private struct SourceLineList: View {
  let lines: [HarnessController.ToolPresentation.FileLine]
  let tokens: [[DSHSourceToken]]
  let range: Range<Int>

  var body: some View {
    ForEach(Array(range), id: \.self) { index in
      let line = lines[index]
      HStack(alignment: .top, spacing: DSHSpace.s2) {
        Text("\(line.number)")
          .frame(minWidth: 34, alignment: .trailing)
          .foregroundStyle(DSHTheme.inkFaint)
        Text(ToolPresentationFormatting.sourceText(tokens[index]))
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .font(.system(.caption, design: .monospaced))
      .textSelection(.enabled)
      .padding(.vertical, 1)
    }
  }
}

struct ToolSearchRows: View {
  struct Row: Identifiable {
    enum Kind {
      case file(String)
      case match(lineNumber: Int, line: String)
      case path(String)
    }

    let id: String
    let kind: Kind
  }

  let files: [HarnessController.ToolPresentation.SearchFile]
  let paths: [String]
  let query: String?
  let compact: Bool
  @State private var expanded = false

  private var rows: [Row] {
    if !files.isEmpty {
      return files.flatMap { file in
        let header = Row(id: "file:\(file.path)", kind: .file(file.path))
        let matches = file.matches.enumerated().map { index, match in
          Row(
            id: "match:\(file.path):\(match.lineNumber):\(index)",
            kind: .match(lineNumber: match.lineNumber, line: match.line))
        }
        return [header] + matches
      }
    }
    return paths.enumerated().map { index, path in
      Row(id: "path:\(path):\(index)", kind: .path(path))
    }
  }

  var body: some View {
    let window = DSHDisclosureWindow.slice(count: rows.count, expanded: expanded)
    VStack(alignment: .leading, spacing: DSHSpace.s1) {
      SearchRowList(rows: rows, range: window.head, query: query, compact: compact)
      if window.isCollapsed {
        ToolDisclosureButton(hiddenCount: window.hiddenCount, expanded: expanded) {
          withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        }
        SearchRowList(rows: rows, range: window.tail, query: query, compact: compact)
      } else if rows.count > 16 {
        ToolDisclosureButton(hiddenCount: 0, expanded: expanded) {
          withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        }
      }
    }
  }
}

private struct SearchRowList: View {
  private let rows: [ToolSearchRows.Row]
  let range: Range<Int>
  let query: String?
  let compact: Bool

  init(rows: [ToolSearchRows.Row], range: Range<Int>, query: String?, compact: Bool) {
    self.rows = rows
    self.range = range
    self.query = query
    self.compact = compact
  }

  var body: some View {
    ForEach(rows[range]) { row in
      switch row.kind {
      case .path(let path):
        ToolPathView(path: path, compact: compact)
      case .file(let path):
        ToolPathView(path: path, compact: compact)
      case .match(let lineNumber, let line):
        HStack(alignment: .top, spacing: DSHSpace.s2) {
          Text("\(lineNumber)")
            .frame(minWidth: 30, alignment: .trailing)
            .foregroundStyle(DSHTheme.inkFaint)
          Text(ToolPresentationFormatting.highlightedSearch(line, query: query))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
      }
    }
  }
}

private struct ToolWebSources: View {
  let sources: [HarnessController.ToolPresentation.Source]
  @State private var expanded = false

  var body: some View {
    let window = DSHDisclosureWindow.slice(count: sources.count, expanded: expanded)
    VStack(alignment: .leading, spacing: DSHSpace.s2) {
      WebSourceList(sources: sources, range: window.head)
      if window.isCollapsed {
        ToolDisclosureButton(hiddenCount: window.hiddenCount, expanded: expanded) {
          withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        }
        WebSourceList(sources: sources, range: window.tail)
      } else if sources.count > 16 {
        ToolDisclosureButton(hiddenCount: 0, expanded: expanded) {
          withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        }
      }
    }
  }
}

private struct WebSourceList: View {
  let sources: [HarnessController.ToolPresentation.Source]
  let range: Range<Int>

  var body: some View {
    ForEach(sources[range]) { source in
      VStack(alignment: .leading, spacing: DSHSpace.s1) {
        if let destination = DSHToolPresentationURL.webURL(source.url) {
          Link(source.title ?? source.url, destination: destination)
            .font(.caption.weight(.semibold))
            .lineLimit(2)
        } else {
          Text(source.title ?? source.url)
            .font(.caption.weight(.semibold))
            .foregroundStyle(DSHTheme.inkSoft)
            .textSelection(.enabled)
            .lineLimit(2)
        }
        Text(source.url)
          .font(.caption2.monospaced())
          .foregroundStyle(DSHTheme.inkFaint)
          .textSelection(.enabled)
          .lineLimit(2)
        if let snippet = source.snippet {
          Text(snippet).font(.caption).foregroundStyle(DSHTheme.inkSoft).lineLimit(3)
        }
        if let publishedAt = source.publishedAt {
          Text(publishedAt).font(.caption2).foregroundStyle(DSHTheme.inkFaint)
        }
      }
      .padding(.vertical, DSHSpace.s1)
    }
  }
}

private struct ToolDisclosureButton: View {
  let hiddenCount: Int
  let expanded: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(expanded ? "收起" : "… 其余 \(hiddenCount) 行")
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(DSHTheme.accent)
    }
    .buttonStyle(.plain)
    .padding(.vertical, 2)
  }
}

private enum ToolPresentationFormatting {
  static func extractQuery(from title: String?) -> String? {
    guard let title else { return nil }
    for (open, close) in [("\u{201C}", "\u{201D}"), ("\"", "\""), ("`", "`"), ("'", "'"), ("「", "」")] {
      guard let openRange = title.range(of: open),
            let closeRange = title.range(of: close, options: [], range: openRange.upperBound..<title.endIndex)
      else { continue }
      let query = String(title[openRange.upperBound..<closeRange.lowerBound])
      if !query.isEmpty { return query }
    }
    return nil
  }

  static func highlightedSearch(_ line: String, query: String?) -> AttributedString {
    var attributed = AttributedString(line)
    guard let query, !query.isEmpty else { return attributed }
    var searchStart = line.startIndex
    while searchStart < line.endIndex,
          let found = line.range(of: query, options: .caseInsensitive, range: searchStart..<line.endIndex) {
      if let range = Range(found, in: attributed) {
        attributed[range].inlinePresentationIntent = .stronglyEmphasized
        attributed[range].foregroundColor = DSHTheme.warm
      }
      searchStart = found.upperBound
    }
    return attributed
  }

  static func sourceText(_ tokens: [DSHSourceToken]) -> AttributedString {
    var attributed = AttributedString()
    for token in tokens {
      var fragment = AttributedString(token.text)
      fragment.foregroundColor = tokenColor(token.kind)
      if token.kind == .keyword || token.kind == .key {
        fragment.inlinePresentationIntent = .stronglyEmphasized
      }
      attributed += fragment
    }
    return attributed
  }

  private static func tokenColor(_ kind: DSHSourceTokenKind) -> Color {
    switch kind {
    case .keyword: DSHTheme.accent
    case .string: DSHTheme.warm
    case .number: DSHTheme.coral
    case .comment: DSHTheme.inkFaint
    case .key: DSHTheme.accent
    case .plain: DSHTheme.ink
    }
  }
}

private struct Card<Content: View, Trailing: View>: View {
  let icon: String
  let title: String
  let content: Content
  let trailing: Trailing

  init(icon: String, title: String, @ViewBuilder content: () -> Content, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
    self.icon = icon
    self.title = title
    self.content = content()
    self.trailing = trailing()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s3) {
      // 卡片头图标是结构不是状态——保持中性灰，别让整条会话流铺满主色
      // （见 2026-08-17-jelly-sea-restraint.md）。
      HStack(spacing: DSHSpace.s2) { Image(systemName: icon).foregroundStyle(DSHTheme.inkSoft); Text(title).font(.caption.weight(.semibold)).lineLimit(1); Spacer(); trailing }
      content
    }
    .padding(DSHSpace.s3)
    .dshCard(tint: DSHTheme.surfaceTint, radius: DSHRadius.lg)
  }
}

/// A native file affordance for every delivered path carried by a ToolPresentation.
/// Both actions route through Host so the same opener policy serves the web and app clients.
private struct FilePathActions: View {
  @EnvironmentObject var harness: HarnessController
  let path: String

  var body: some View {
    HStack(spacing: DSHSpace.s1) {
      Label(path, systemImage: "doc")
        .font(.caption.monospaced())
        .foregroundStyle(DSHTheme.inkSoft)
        .textSelection(.enabled)
        .lineLimit(1)
      Spacer(minLength: DSHSpace.s1)
      if ["md", "markdown", "mdown", "mkd"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) {
        Button { harness.openMarkdownWorkbench(path) } label: {
          Image(systemName: "doc.richtext")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help("在工作台阅读 Markdown")
        .accessibilityLabel("在工作台阅读 Markdown")
      }
      Button("打开") { harness.openDeliveredFile(path) }
        .controlSize(.mini)
        .help("使用默认应用打开文件")
      Button { harness.revealDeliveredFile(path) } label: {
        Image(systemName: "folder")
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
      .help("在 Finder 中打开所在文件夹")
      .accessibilityLabel("在 Finder 中打开所在文件夹")
    }
  }
}

/// Line-level diff renderer: LCS-based hunks with trimmed context, tinted
/// change rows, and a whole-block fallback for very large payloads.
// `.equatable()` at the call site skips re-running the O(n·m) LCS diff below
// on every unrelated `@EnvironmentObject` change from an ancestor — only an
// actual old/new text change invalidates the view.
// Not `private`: the transcript's inline tool rows (ToolCallRow in
// main.swift) reuse this to show edit diffs Claude Code-style.
struct DiffLines: View, Equatable {
  let old: String?
  let new: String
  @State private var expanded = false

  private enum RowKind { case context, deletion, addition, skip(Int) }
  private struct Row: Identifiable { let id: Int; let kind: RowKind; let text: String }
  private static let maxDiffLines = 2000
  private static let contextLines = 3

  static func == (lhs: DiffLines, rhs: DiffLines) -> Bool {
    lhs.old == rhs.old && lhs.new == rhs.new
  }

  var body: some View {
    let oldLines = old.map { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) } ?? []
    let newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let rows = oldLines.count > Self.maxDiffLines || newLines.count > Self.maxDiffLines
      ? Self.fallbackRows(old: oldLines, new: newLines)
      : Self.rows(old: oldLines, new: newLines)
    let window = DSHDisclosureWindow.slice(count: rows.count, expanded: expanded)
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(rows[window.head])) { row in rowView(kind: row.kind, text: row.text) }
      if window.isCollapsed {
        ToolDisclosureButton(hiddenCount: window.hiddenCount, expanded: expanded) {
          withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        }
        ForEach(Array(rows[window.tail])) { row in rowView(kind: row.kind, text: row.text) }
      } else if rows.count > 16 {
        ToolDisclosureButton(hiddenCount: 0, expanded: expanded) {
          withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        }
      }
    }
    .font(.system(.caption, design: .monospaced))
    .textSelection(.enabled)
  }

  @ViewBuilder private func rowView(kind: RowKind, text: String) -> some View {
    switch kind {
    case .skip(let count):
      Text("⋯ 跳过 \(count) 行")
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(DSHTheme.inkFaint)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    case .context: line(" ", text, DSHTheme.inkSoft, .clear)
    case .deletion: line("−", text, DSHTheme.coral, DSHTheme.coralSoft)
    case .addition: line("+", text, DSHTheme.accent, DSHTheme.accentSoft)
    }
  }

  private func line(_ prefix: String, _ text: String, _ color: Color, _ background: Color) -> some View {
    HStack(alignment: .top, spacing: DSHSpace.s2) {
      Text(prefix).foregroundStyle(color).frame(width: 12, alignment: .center)
      Text(text.isEmpty ? " " : text).foregroundStyle(color).frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, DSHSpace.s1)
    .background(background)
  }

  /// Classic LCS line diff — O(old.count * new.count); body guards the size.
  private static func operations(old: [String], new: [String]) -> [(kind: RowKind, text: String)] {
    let n = old.count, m = new.count
    let width = m + 1
    // lcs[i * width + j] = LCS length of old[i...] vs new[j...]
    var lcs = [Int](repeating: 0, count: (n + 1) * width)
    for i in stride(from: n - 1, through: 0, by: -1) {
      for j in stride(from: m - 1, through: 0, by: -1) {
        lcs[i * width + j] = old[i] == new[j]
          ? lcs[(i + 1) * width + j + 1] + 1
          : max(lcs[(i + 1) * width + j], lcs[i * width + j + 1])
      }
    }
    var ops: [(kind: RowKind, text: String)] = []
    var i = 0, j = 0
    while i < n, j < m {
      if old[i] == new[j] { ops.append((.context, old[i])); i += 1; j += 1 }
      else if lcs[(i + 1) * width + j] >= lcs[i * width + j + 1] { ops.append((.deletion, old[i])); i += 1 }
      else { ops.append((.addition, new[j])); j += 1 }
    }
    while i < n { ops.append((.deletion, old[i])); i += 1 }
    while j < m { ops.append((.addition, new[j])); j += 1 }
    return ops
  }

  /// Collapses unchanged runs to at most `contextLines` of context around each
  /// hunk, inserting a skip marker for the elided middle.
  private static func rows(old: [String], new: [String]) -> [Row] {
    let ops = operations(old: old, new: new)
    let hasChanges = ops.contains { if case .context = $0.kind { return false } else { return true } }
    guard hasChanges else { return ops.enumerated().map { Row(id: $0.offset, kind: .context, text: $0.element.text) } }
    var rows: [Row] = []
    func add(_ kind: RowKind, _ text: String) { rows.append(Row(id: rows.count, kind: kind, text: text)) }
    var index = 0
    while index < ops.count {
      guard case .context = ops[index].kind else {
        add(ops[index].kind, ops[index].text)
        index += 1
        continue
      }
      var end = index
      while end < ops.count, case .context = ops[end].kind { end += 1 }
      let run = ops[index..<end]
      let keepHead = index == 0 ? 0 : contextLines
      let keepTail = end == ops.count ? 0 : contextLines
      if run.count > keepHead + keepTail + 1 {
        for op in run.prefix(keepHead) { add(.context, op.text) }
        add(.skip(run.count - keepHead - keepTail), "")
        for op in run.suffix(keepTail) { add(.context, op.text) }
      } else {
        for op in run { add(.context, op.text) }
      }
      index = end
    }
    return rows
  }

  private static func fallbackRows(old: [String], new: [String]) -> [Row] {
    let deleted = old.enumerated().map { Row(id: $0.offset, kind: .deletion, text: $0.element) }
    let added = new.enumerated().map { Row(id: old.count + $0.offset, kind: .addition, text: $0.element) }
    return deleted + added
  }
}

private extension String {
  /// Removes ANSI escape sequences (CSI, OSC, and two-byte ESC codes) so raw
  /// terminal/tool output renders as plain text.
  func strippingANSI() -> String {
    guard contains("\u{1B}") else { return self }
    let pattern = "\u{1B}(?:\\[[0-9;:?]*[ -/]*[@-~]|\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)?|[@-_])"
    return replacingOccurrences(of: pattern, with: "", options: .regularExpression)
  }
}
