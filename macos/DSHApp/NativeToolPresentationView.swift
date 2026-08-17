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
        HStack(spacing: DSHSpace.s2) { Text("$").foregroundStyle(DSHTheme.accent); Text(view.title ?? "").textSelection(.enabled) }
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
              DiffLines(old: item.oldText, new: item.newText)
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
        else {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(view.lines) { line in
              HStack(alignment: .top, spacing: DSHSpace.s2) {
                Text("\(line.number)").frame(minWidth: 34, alignment: .trailing).foregroundStyle(DSHTheme.inkFaint)
                Text(line.text.isEmpty ? " " : line.text).frame(maxWidth: .infinity, alignment: .leading)
              }.font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(.vertical, 1)
            }
          }.padding(DSHSpace.s2).dshCard(tint: DSHTheme.surfaceTint2, radius: DSHRadius.sm)
        }
      }
    }
  }

  private func search(_ view: HarnessController.ToolPresentation) -> some View {
    Card(icon: "magnifyingglass", title: view.title ?? "搜索结果") {
      VStack(alignment: .leading, spacing: DSHSpace.s2) {
        if view.searchShape == "matches" {
          ForEach(view.files) { file in
            VStack(alignment: .leading, spacing: DSHSpace.s1) {
              FilePathActions(path: file.path)
              ForEach(file.matches) { match in
                HStack(alignment: .top, spacing: DSHSpace.s2) {
                  Text("\(match.lineNumber)").frame(minWidth: 30, alignment: .trailing).foregroundStyle(DSHTheme.inkFaint)
                  Text(match.line).frame(maxWidth: .infinity, alignment: .leading)
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

  private func code(_ text: String) -> some View {
    Text(text.isEmpty ? "没有输出。" : text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
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
      HStack(spacing: DSHSpace.s2) { Image(systemName: icon).foregroundStyle(DSHTheme.accent); Text(title).font(.caption.weight(.semibold)).lineLimit(1); Spacer(); trailing }
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

private struct DiffLines: View {
  let old: String?
  let new: String
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let old { ForEach(old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init), id: \.self) { Text("− \($0)").foregroundStyle(DSHTheme.coral).frame(maxWidth: .infinity, alignment: .leading) } }
      ForEach(new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init), id: \.self) { Text("+ \($0)").foregroundStyle(DSHTheme.accent).frame(maxWidth: .infinity, alignment: .leading) }
    }.font(.system(.caption, design: .monospaced)).textSelection(.enabled)
  }
}
