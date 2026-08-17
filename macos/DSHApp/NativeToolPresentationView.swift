import SwiftUI

/// Native renderer for the structured DSH tool presentation payload.
struct NativeToolPresentationView: View {
  @EnvironmentObject var harness: HarnessController
  let tool: HarnessController.ToolActivity

  var body: some View {
    if let view = tool.presentation {
      switch view.card {
      case "terminal": terminal(view)
      case "diff": diff(view)
      case "read": read(view)
      case "search": search(view)
      case "web": web(view)
      default: generic(view.title ?? tool.name, view.output ?? tool.output)
      }
    } else {
      generic(tool.name, tool.output.isEmpty ? "等待 DSH 输出…" : tool.output)
    }
  }

  private func terminal(_ view: HarnessController.ToolPresentation) -> some View {
    Card(icon: "terminal", title: view.title ?? "终端") {
      VStack(alignment: .leading, spacing: DSHSpace.s2) {
        if let description = view.description { Text(description).font(.caption).foregroundStyle(DSHTheme.inkSoft) }
        if let cwd = view.cwd { Label(cwd, systemImage: "folder").font(.caption.monospaced()).foregroundStyle(DSHTheme.inkSoft) }
        HStack(spacing: DSHSpace.s2) { Text("$").foregroundStyle(DSHTheme.inkFaint); Text(view.title ?? "").textSelection(.enabled) }
          .font(.system(.caption, design: .monospaced).weight(.medium))
        code(view.output ?? tool.output)
          .padding(.top, DSHSpace.s1)
      }
    } trailing: {
      if let exitCode = view.exitCode { DSHBadge(text: "exit \(exitCode)", tone: exitCode == 0 ? .accent : .coral) }
      else if let signal = view.signal { DSHBadge(text: signal, tone: .warm) }
      else if tool.state == .running { ProgressView().controlSize(.small) }
    }
  }

  private func diff(_ view: HarnessController.ToolPresentation) -> some View {
    Card(icon: "arrow.left.arrow.right", title: view.title ?? "文件更改") {
      if view.diffs.isEmpty { code(view.output ?? "没有可展示的差异。") }
      else {
        VStack(alignment: .leading, spacing: DSHSpace.s3) {
          ForEach(view.diffs) { item in
            VStack(alignment: .leading, spacing: DSHSpace.s1) {
              FilePathActions(path: item.path)
              DiffLines(old: item.oldText, new: item.newText).equatable()
            }.padding(DSHSpace.s2).dshCard(tint: DSHTheme.surfaceTint2, radius: DSHRadius.sm)
          }
        }
      }
    }
  }

  private func read(_ view: HarnessController.ToolPresentation) -> some View {
    Card(icon: "doc.text", title: view.title ?? view.path ?? "读取文件") {
      VStack(alignment: .leading, spacing: DSHSpace.s2) {
        if let path = view.path { FilePathActions(path: path) }
        if let total = view.totalLines { Text("显示 \(view.lines.count) / \(total) 行\(view.lang.map { " · \($0)" } ?? "")").font(.caption2).foregroundStyle(DSHTheme.inkSoft) }
        if view.lines.isEmpty { code(view.output ?? "文件为空。") }
        else { CollapsibleFileLines(lines: view.lines) }
      }
    }
  }

  private func search(_ view: HarnessController.ToolPresentation) -> some View {
    let query = Self.extractQuery(from: view.title)
    return Card(icon: "magnifyingglass", title: view.title ?? "搜索结果") {
      VStack(alignment: .leading, spacing: DSHSpace.s2) {
        if view.searchShape == "matches" {
          ForEach(view.files) { file in
            VStack(alignment: .leading, spacing: DSHSpace.s1) {
              FilePathActions(path: file.path)
              ForEach(file.matches) { match in
                HStack(alignment: .top, spacing: DSHSpace.s2) {
                  Text("\(match.lineNumber)").frame(minWidth: 30, alignment: .trailing).foregroundStyle(DSHTheme.inkFaint)
                  Text(Self.highlighted(match.line, query: query)).frame(maxWidth: .infinity, alignment: .leading)
                }.font(.system(.caption, design: .monospaced)).textSelection(.enabled)
              }
            }
          }
        } else if view.searchShape == "paths" {
          ForEach(view.paths, id: \.self) { path in FilePathActions(path: path) }
        } else { code(tool.output) }
        if view.truncated { DSHBadge(text: view.total.map { "已显示部分结果（共 \($0) 条）" } ?? "已显示部分结果", tone: .warm) }
      }
    }
  }

  private func web(_ view: HarnessController.ToolPresentation) -> some View {
    Card(icon: "globe", title: view.title ?? (view.webKind == "fetch" ? "网页抓取" : "网页搜索")) {
      VStack(alignment: .leading, spacing: DSHSpace.s2) {
        if view.webKind == "fetch", let url = view.url {
          Link(url, destination: URL(string: url) ?? URL(string: "https://example.invalid")!).font(.caption.monospaced()).lineLimit(2)
          if let statusCode = view.statusCode { DSHBadge(text: "HTTP \(statusCode)", tone: (200...299).contains(statusCode) ? .accent : .coral) }
          if let body = view.output ?? view.answer, !body.isEmpty { code(body) }
        } else {
          if let answer = view.answer, !answer.isEmpty { Text(answer).font(.caption).textSelection(.enabled) }
          ForEach(view.sources) { source in
            VStack(alignment: .leading, spacing: DSHSpace.s1) {
              Link(source.title ?? source.url, destination: URL(string: source.url) ?? URL(string: "https://example.invalid")!).font(.caption.weight(.semibold)).lineLimit(2)
              if let snippet = source.snippet { Text(snippet).font(.caption).foregroundStyle(DSHTheme.inkSoft).lineLimit(3) }
              if let publishedAt = source.publishedAt { Text(publishedAt).font(.caption2).foregroundStyle(DSHTheme.inkFaint) }
            }.padding(.vertical, DSHSpace.s1)
          }
          if view.sources.isEmpty && view.answer == nil { code(tool.output) }
        }
        if view.truncated { DSHBadge(text: "结果已截断", tone: .warm) }
      }
    }
  }

  private func generic(_ title: String, _ output: String) -> some View {
    Card(icon: "wrench.and.screwdriver", title: title) { code(output) }
  }

  private func code(_ text: String) -> some View { CollapsibleCode(text: text) }

  /// The search payload carries no dedicated query field (ToolPresentation.from
  /// in main.swift only decodes title/files/paths), so the query is best-effort
  /// extracted from the first quoted fragment of the card title.
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

  /// Bolds and tints every case-insensitive occurrence of the query in a matched line.
  static func highlighted(_ line: String, query: String?) -> AttributedString {
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
}

/// Monospaced output block: strips ANSI escapes and folds long output behind an
/// expand toggle (over `foldThreshold` lines shows only the first `foldedCount`).
private struct CollapsibleCode: View {
  let text: String
  @State private var expanded = false
  private let foldThreshold = 40
  private let foldedCount = 20

  var body: some View {
    let clean = text.strippingANSI()
    let lines = clean.split(separator: "\n", omittingEmptySubsequences: false)
    let folded = !expanded && lines.count > foldThreshold
    VStack(alignment: .leading, spacing: DSHSpace.s1) {
      Text(clean.isEmpty ? "没有输出。" : (folded ? lines.prefix(foldedCount).joined(separator: "\n") : clean))
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      if lines.count > foldThreshold {
        Button(expanded ? "收起" : "展开全部 \(lines.count) 行") { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
          .buttonStyle(.borderless)
          .controlSize(.mini)
          .font(.caption2)
          .foregroundStyle(DSHTheme.accent)
      }
    }
  }
}

/// Numbered file lines with the same fold behavior as CollapsibleCode.
private struct CollapsibleFileLines: View {
  let lines: [HarnessController.ToolPresentation.FileLine]
  @State private var expanded = false
  private let foldThreshold = 40
  private let foldedCount = 20

  var body: some View {
    let visible = expanded || lines.count <= foldThreshold ? lines : Array(lines.prefix(foldedCount))
    VStack(alignment: .leading, spacing: 0) {
      ForEach(visible) { line in
        HStack(alignment: .top, spacing: DSHSpace.s2) {
          Text("\(line.number)").frame(minWidth: 34, alignment: .trailing).foregroundStyle(DSHTheme.inkFaint)
          Text(line.text.isEmpty ? " " : line.text).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(.vertical, 1)
      }
      if lines.count > foldThreshold {
        Button(expanded ? "收起" : "展开全部 \(lines.count) 行") { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
          .buttonStyle(.borderless)
          .controlSize(.mini)
          .font(.caption2)
          .foregroundStyle(DSHTheme.accent)
          .padding(.top, DSHSpace.s1)
      }
    }.padding(DSHSpace.s2).dshCard(tint: DSHTheme.surfaceTint2, radius: DSHRadius.sm)
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

  private enum RowKind { case context, deletion, addition, skip(Int) }
  private struct Row: Identifiable { let id: Int; let kind: RowKind; let text: String }
  private static let maxDiffLines = 2000
  private static let contextLines = 3

  var body: some View {
    let oldLines = old.map { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) } ?? []
    let newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    VStack(alignment: .leading, spacing: 0) {
      if oldLines.count > Self.maxDiffLines || newLines.count > Self.maxDiffLines {
        // Degrade to whole-block old/new rendering so the O(n·m) diff never stalls the UI.
        ForEach(Array(oldLines.enumerated()), id: \.offset) { _, line in rowView(kind: .deletion, text: line) }
        ForEach(Array(newLines.enumerated()), id: \.offset) { _, line in rowView(kind: .addition, text: line) }
      } else {
        ForEach(Self.rows(old: oldLines, new: newLines)) { row in rowView(kind: row.kind, text: row.text) }
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
