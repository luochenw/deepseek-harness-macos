import AppKit
import Foundation
import SwiftUI
@testable import DSHAppLib

enum ToolPresentationSnapshotFailure: Error, CustomStringConvertible {
  case invalid(String)

  var description: String {
    switch self { case .invalid(let message): message }
  }
}

@main
struct ToolPresentationSnapshotCheck {
  @MainActor
  static func main() throws {
    guard CommandLine.arguments.count == 2 else {
      throw ToolPresentationSnapshotFailure.invalid("usage: tool-presentation-snapshot-check OUTPUT_DIR")
    }
    _ = NSApplication.shared
    NSApp.appearance = NSAppearance(named: .aqua)

    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

    let harness = HarnessController(startRuntime: false)
    harness.workspace = URL(fileURLWithPath: "/workspace", isDirectory: true)

    let tools = fixtures()
    harness.activeTools = tools
    for tool in tools {
      try render(
        "tool-\(tool.callId)",
        size: CGSize(width: 620, height: 520),
        output: output,
        content: ScrollView {
          NativeToolPresentationView(tool: tool)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DSHSpace.s4)
        }
        .environmentObject(harness))

      try render(
        "tool-inline-\(tool.callId)",
        size: CGSize(width: 620, height: 520),
        output: output,
        content: ScrollView {
          ToolCallRow(
            message: HarnessController.Message(role: .tool, text: tool.name, toolCallId: tool.callId),
            initiallyExpanded: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DSHSpace.s4)
        }
        .environmentObject(harness))
    }

    try render(
      "tool-inline-stack",
      size: CGSize(width: 620, height: 760),
      output: output,
      content: ScrollView {
        VStack(alignment: .leading, spacing: DSHSpace.s4) {
          ForEach(tools) { tool in
            ToolCallRow(
              message: HarnessController.Message(role: .tool, text: tool.name, toolCallId: tool.callId),
              initiallyExpanded: true)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .padding(DSHSpace.s4)
      }
      .environmentObject(harness))
  }

  @MainActor
  private static func render<V: View>(
    _ name: String,
    size: CGSize,
    output: URL,
    content: V
  ) throws {
    let root = AnyView(content
      .frame(width: size.width, height: size.height)
      .background(DSHTheme.canvas))
    let hosting = NSHostingView(rootView: root)
    hosting.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
      styleMask: .borderless,
      backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.backgroundColor = .clear
    window.contentView = hosting
    window.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    hosting.layoutSubtreeIfNeeded()
    hosting.displayIfNeeded()

    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
      window.close()
      throw ToolPresentationSnapshotFailure.invalid("\(name): no bitmap")
    }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    window.orderOut(nil)
    window.close()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw ToolPresentationSnapshotFailure.invalid("\(name): cannot encode PNG")
    }

    let destination = output.appendingPathComponent("\(name).png")
    try png.write(to: destination)
    try validate(name: name, data: png, expected: size)
    print("\(name): \(destination.path)")
  }

  private static func validate(name: String, data: Data, expected: CGSize) throws {
    guard data.count > 3_000, let bitmap = NSBitmapImageRep(data: data) else {
      throw ToolPresentationSnapshotFailure.invalid("\(name): PNG is missing or unexpectedly small")
    }
    let scaleX = Double(bitmap.pixelsWide) / expected.width
    let scaleY = Double(bitmap.pixelsHigh) / expected.height
    guard abs(scaleX - scaleY) < 0.01, scaleX >= 1, scaleX <= 3 else {
      throw ToolPresentationSnapshotFailure.invalid("\(name): invalid image scale")
    }

    let stepX = max(1, bitmap.pixelsWide / 48)
    let stepY = max(1, bitmap.pixelsHigh / 48)
    var visible = 0
    var colors = Set<UInt32>()
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: stepY) {
      for x in stride(from: 0, to: bitmap.pixelsWide, by: stepX) {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        if color.alphaComponent > 0.05 { visible += 1 }
        let red = UInt32((color.redComponent * 31).rounded())
        let green = UInt32((color.greenComponent * 31).rounded())
        let blue = UInt32((color.blueComponent * 31).rounded())
        let alpha = UInt32((color.alphaComponent * 31).rounded())
        colors.insert((red << 15) | (green << 10) | (blue << 5) | alpha)
      }
    }
    guard visible > 500, colors.count > 12 else {
      throw ToolPresentationSnapshotFailure.invalid(
        "\(name): output appears blank (visible \(visible), colors \(colors.count))")
    }
  }

  private static func fixtures() -> [HarnessController.ToolActivity] {
    [
      tool(
        id: "terminal",
        name: "bash",
        output: (1...24).map { "terminal line \($0)" }.joined(separator: "\n"),
        presentation: presentation(
          card: "terminal",
          title: "rg -n TODO src",
          output: (1...24).map { "terminal line \($0)" }.joined(separator: "\n"),
          exitCode: 0,
          cwd: "/workspace/src",
          description: "查找待处理标记")),
      tool(
        id: "diff",
        name: "edit",
        output: "已更新文件",
        presentation: presentation(
          card: "diff",
          title: "更新 App.swift",
          diffs: [
            .init(
              path: "Sources/App.swift",
              oldText: (1...20).map { "old \($0)" }.joined(separator: "\n"),
              newText: (1...20).map { "new \($0)" }.joined(separator: "\n")),
          ])),
      tool(
        id: "read",
        name: "read",
        output: "",
        presentation: presentation(
          card: "read",
          title: "读取 DSHTool.swift",
          path: "macos/DSHApp/DSHTool.swift",
          lines: (1...24).map {
            .init(number: $0, text: $0 == 1 ? "import Foundation" : "let value\($0) = \($0) // detail")
          },
          totalLines: 240,
          lang: "swift")),
      tool(
        id: "search",
        name: "grep",
        output: "",
        presentation: presentation(
          card: "search",
          title: "搜索 \"attachment\"",
          searchShape: "matches",
          files: [
            .init(
              path: "macos/DSHApp/DSHAttachments.swift",
              matches: (1...20).map { .init(lineNumber: $0, line: "attachment result \($0)") }),
          ],
          truncated: true,
          total: 48)),
      tool(
        id: "web",
        name: "web_search",
        output: "",
        presentation: presentation(
          card: "web",
          title: "网页搜索",
          webKind: "search",
          answer: "找到多个参考来源。",
          sources: (1...18).map {
            .init(
              url: "https://example.com/source-\($0)",
              title: "Source \($0)",
              snippet: "A concise source excerpt for result \($0).",
              publishedAt: "2026-08-\(String(format: "%02d", $0))")
          })),
      tool(
        id: "generic",
        name: "code_dispatch",
        output: (1...20).map { "dispatch output \($0)" }.joined(separator: "\n"),
        presentation: presentation(
          card: "generic",
          title: "代码派发",
          output: (1...20).map { "dispatch output \($0)" }.joined(separator: "\n"))),
    ]
  }

  private static func tool(
    id: String,
    name: String,
    output: String,
    presentation: HarnessController.ToolPresentation
  ) -> HarnessController.ToolActivity {
    HarnessController.ToolActivity(
      callId: id,
      name: name,
      summary: "已完成",
      state: .succeeded,
      output: output,
      presentation: presentation)
  }

  private static func presentation(
    card: String,
    title: String? = nil,
    path: String? = nil,
    output: String? = nil,
    exitCode: Int? = nil,
    signal: String? = nil,
    cwd: String? = nil,
    description: String? = nil,
    diffs: [HarnessController.ToolPresentation.Diff] = [],
    lines: [HarnessController.ToolPresentation.FileLine] = [],
    totalLines: Int? = nil,
    lang: String? = nil,
    searchShape: String? = nil,
    files: [HarnessController.ToolPresentation.SearchFile] = [],
    paths: [String] = [],
    truncated: Bool = false,
    total: Int? = nil,
    webKind: String? = nil,
    answer: String? = nil,
    url: String? = nil,
    statusCode: Int? = nil,
    sources: [HarnessController.ToolPresentation.Source] = []
  ) -> HarnessController.ToolPresentation {
    HarnessController.ToolPresentation(
      card: card,
      title: title,
      path: path,
      output: output,
      exitCode: exitCode,
      signal: signal,
      cwd: cwd,
      description: description,
      diffs: diffs,
      lines: lines,
      totalLines: totalLines,
      lang: lang,
      searchShape: searchShape,
      files: files,
      paths: paths,
      truncated: truncated,
      total: total,
      webKind: webKind,
      answer: answer,
      url: url,
      statusCode: statusCode,
      sources: sources)
  }
}
