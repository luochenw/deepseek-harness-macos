import AppKit
import Foundation
import SwiftUI
@testable import DSHAppLib

enum ConversationWindowSnapshotFailure: Error, CustomStringConvertible {
  case invalid(String)

  var description: String {
    switch self { case .invalid(let message): message }
  }
}

@main
struct ConversationWindowSnapshotCheck {
  @MainActor
  static func main() throws {
    guard CommandLine.arguments.count == 2 else {
      throw ConversationWindowSnapshotFailure.invalid("usage: conversation-window-snapshot-check OUTPUT_DIR")
    }
    _ = NSApplication.shared
    NSApp.appearance = NSAppearance(named: .aqua)
    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

    let harness = HarnessController(startRuntime: false)
    let messages = (0..<2_000).map { index -> HarnessController.Message in
      switch index % 3 {
      case 0: return HarnessController.Message(role: .user, text: "用户消息 \(index)：继续检查这个长会话。")
      case 1: return HarnessController.Message(role: .assistant, text: "助手回复 \(index)：当前只物化窗口内的消息。")
      default: return HarnessController.Message(role: .system, text: "状态更新 \(index)")
      }
    }
    let session = HarnessController.Session(
      title: "长会话",
      workspaceName: "ds-harness",
      updatedAt: Date(),
      messages: messages,
      hostSessionId: "long-session")
    harness.sessions = [session]
    harness.selectedSessionID = session.id
    harness.hostCurrentSessionID = "long-session"
    harness.updateDisplayedConversationWindow(messageCount: messages.count, pinnedToBottom: true)

    guard let snapshot = harness.conversationWindowDebugSnapshot,
          snapshot.totalCount == 2_000,
          snapshot.materializedCount == DSHConversationWindowPlanner.capacity else {
      throw ConversationWindowSnapshotFailure.invalid("conversation window is not bounded to the configured capacity")
    }

    let size = CGSize(width: 900, height: 720)
    let root = AnyView(
      ConversationView()
        .frame(width: size.width, height: size.height)
        .background(DSHTheme.canvas)
        .environmentObject(harness))
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
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    hosting.layoutSubtreeIfNeeded()
    hosting.displayIfNeeded()

    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
      window.close()
      throw ConversationWindowSnapshotFailure.invalid("ConversationView produced no bitmap")
    }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    window.orderOut(nil)
    window.close()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw ConversationWindowSnapshotFailure.invalid("ConversationView could not encode PNG")
    }
    let destination = output.appendingPathComponent("conversation-window-2000.png")
    try png.write(to: destination)
    try validate(data: png, expected: size)
    print("conversation-window-snapshot: \(destination.path)")
  }

  private static func validate(data: Data, expected: CGSize) throws {
    guard data.count > 4_000, let bitmap = NSBitmapImageRep(data: data) else {
      throw ConversationWindowSnapshotFailure.invalid("conversation snapshot is blank or unexpectedly small")
    }
    let scaleX = Double(bitmap.pixelsWide) / expected.width
    let scaleY = Double(bitmap.pixelsHigh) / expected.height
    guard abs(scaleX - scaleY) < 0.01, scaleX >= 1, scaleX <= 3 else {
      throw ConversationWindowSnapshotFailure.invalid("conversation snapshot has an invalid scale")
    }
    var colors = Set<UInt32>()
    var nonBackgroundSamples = 0
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 48)) {
      for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 60)) {
        guard let rgb = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        let red = UInt32((rgb.redComponent * 31).rounded())
        let green = UInt32((rgb.greenComponent * 31).rounded())
        let blue = UInt32((rgb.blueComponent * 31).rounded())
        let alpha = UInt32((rgb.alphaComponent * 31).rounded())
        colors.insert((red << 15) | (green << 10) | (blue << 5) | alpha)
        if max(rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
          - min(rgb.redComponent, rgb.greenComponent, rgb.blueComponent) > 0.02 {
          nonBackgroundSamples += 1
        }
      }
    }
    guard colors.count > 12, nonBackgroundSamples > 20 else {
      throw ConversationWindowSnapshotFailure.invalid(
        "conversation snapshot appears blank (\(colors.count) colors, \(nonBackgroundSamples) content samples)")
    }
  }
}
