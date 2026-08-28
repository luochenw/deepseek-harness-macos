import AppKit
import Foundation
import SwiftUI
@testable import DSHAppLib

enum WorkbenchSnapshotFailure: Error, CustomStringConvertible {
  case invalid(String)

  var description: String {
    switch self { case .invalid(let message): message }
  }
}

@main
struct WorkbenchSnapshotCheck {
  @MainActor
  static func main() throws {
    guard CommandLine.arguments.count == 2 else {
      throw WorkbenchSnapshotFailure.invalid("usage: workbench-snapshot-check OUTPUT_DIR")
    }
    _ = NSApplication.shared
    NSApp.appearance = NSAppearance(named: .aqua)

    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let document = output.appendingPathComponent("architecture.md")
    try """
    # Right Workbench

    The right dock keeps development context beside the conversation.

    ## Core behavior

    - [x] Session-scoped tabs
    - [x] Stable browser runtime
    - [ ] Future terminal tab

    ```swift
    struct DSHWorkbenchTab: Identifiable {
      let id: UUID
    }
    ```
    """.write(to: document, atomically: true, encoding: .utf8)

    for width in [360, 520, 760] {
      let harness = HarnessController(startRuntime: false)
      harness.openExecutionWorkbench()
      harness.openAgentsWorkbench()
      harness.openMarkdownWorkbench(document.path)
      RunLoop.main.run(until: Date().addingTimeInterval(0.2))
      try render(
        "workbench-\(width)",
        size: CGSize(width: width, height: 760),
        output: output,
        content: WorkbenchView().environmentObject(harness))
    }

    NSApp.appearance = NSAppearance(named: .darkAqua)
    let darkHarness = HarnessController(startRuntime: false)
    darkHarness.openMarkdownWorkbench(document.path)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    try render(
      "workbench-520-dark",
      size: CGSize(width: 520, height: 760),
      output: output,
      content: WorkbenchView().environmentObject(darkHarness))

    NSApp.appearance = NSAppearance(named: .aqua)
    let fullHarness = HarnessController(startRuntime: false)
    fullHarness.workspace = output
    let session = HarnessController.Session(
      title: "右侧工作台",
      workspaceName: output.lastPathComponent,
      updatedAt: Date(),
      messages: [
        HarnessController.Message(role: .user, text: "打开架构文档并检查本地页面。"),
        HarnessController.Message(role: .assistant, text: "工作台会在右侧保留浏览器、Markdown 和执行详情。"),
      ],
      hostSessionId: "workbench-root")
    fullHarness.sessions = [session]
    fullHarness.selectedSessionID = session.id
    fullHarness.hostCurrentSessionID = "workbench-root"
    fullHarness.openMarkdownWorkbench(document.path)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    try render(
      "workbench-full-window",
      size: CGSize(width: 1180, height: 760),
      output: output,
      content: HStack(spacing: 0) {
        Sidebar().frame(width: 290)
        ConversationWorkbenchLayout()
      }
      .background(DSHTheme.canvasGradient)
      .environmentObject(fullHarness))
    print("workbench-snapshots: \(output.path)")
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
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    hosting.layoutSubtreeIfNeeded()
    hosting.displayIfNeeded()

    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
      window.close()
      throw WorkbenchSnapshotFailure.invalid("\(name): no bitmap")
    }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    window.orderOut(nil)
    window.close()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw WorkbenchSnapshotFailure.invalid("\(name): cannot encode PNG")
    }
    let destination = output.appendingPathComponent("\(name).png")
    try png.write(to: destination)
    try validate(name: name, data: png, expected: size)
  }

  private static func validate(name: String, data: Data, expected: CGSize) throws {
    guard data.count > 3_000, let bitmap = NSBitmapImageRep(data: data) else {
      throw WorkbenchSnapshotFailure.invalid("\(name): snapshot is blank or too small")
    }
    let scaleX = Double(bitmap.pixelsWide) / expected.width
    let scaleY = Double(bitmap.pixelsHigh) / expected.height
    guard abs(scaleX - scaleY) < 0.01, scaleX >= 1, scaleX <= 3 else {
      throw WorkbenchSnapshotFailure.invalid("\(name): invalid scale")
    }

    let stepX = max(1, bitmap.pixelsWide / 48)
    let stepY = max(1, bitmap.pixelsHigh / 48)
    var visible = 0
    var colors = Set<UInt32>()
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: stepY) {
      for x in stride(from: 0, to: bitmap.pixelsWide, by: stepX) {
        guard let rgb = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        if rgb.alphaComponent > 0.05 { visible += 1 }
        let red = UInt32((rgb.redComponent * 31).rounded())
        let green = UInt32((rgb.greenComponent * 31).rounded())
        let blue = UInt32((rgb.blueComponent * 31).rounded())
        let alpha = UInt32((rgb.alphaComponent * 31).rounded())
        colors.insert((red << 15) | (green << 10) | (blue << 5) | alpha)
      }
    }
    guard visible > 500, colors.count > 12 else {
      throw WorkbenchSnapshotFailure.invalid("\(name): image appears blank")
    }
    print("\(name): \(bitmap.pixelsWide)x\(bitmap.pixelsHigh), \(data.count) bytes, \(colors.count) sampled colors")
  }
}
