import AppKit
import Foundation
import SwiftUI
@testable import DSHAppLib

enum AttachmentRailSnapshotFailure: Error, CustomStringConvertible {
  case invalid(String)

  var description: String {
    switch self { case .invalid(let message): message }
  }
}

@main
struct AttachmentRailSnapshotCheck {
  @MainActor
  static func main() throws {
    guard CommandLine.arguments.count == 2 else {
      throw AttachmentRailSnapshotFailure.invalid("usage: attachment-rail-snapshot-check OUTPUT_DIR")
    }
    _ = NSApplication.shared
    NSApp.appearance = NSAppearance(named: .aqua)

    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

    let harness = HarnessController(startRuntime: false)
    let first = HarnessController.Message(
      role: .user,
      text: "请比较两张图",
      attachment: attachment(id: "rail-a", name: "blue.png"))
    let second = HarnessController.Message(
      role: .assistant,
      text: "第二张图",
      attachment: attachment(id: "rail-b", name: "coral.png"))
    let session = HarnessController.Session(
      title: "图片轨道",
      workspaceName: "轨道",
      updatedAt: Date(),
      messages: [first, second],
      hostSessionId: "rail-session")
    harness.sessions = [session]
    harness.selectedSessionID = session.id
    harness.hostCurrentSessionID = "rail-session"
    harness.attachmentStore.cache(image(.systemBlue), for: "rail-a")
    harness.attachmentStore.cache(image(.systemRed), for: "rail-b")

    guard harness.displayedAttachmentRailItems.count == 2 else {
      throw AttachmentRailSnapshotFailure.invalid("expected two rendered rail items")
    }

    let size = CGSize(width: 420, height: 132)
    let root = AnyView(
      ConversationHeader()
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
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    hosting.layoutSubtreeIfNeeded()
    hosting.displayIfNeeded()

    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
      window.close()
      throw AttachmentRailSnapshotFailure.invalid("rail snapshot did not produce a bitmap")
    }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    window.orderOut(nil)
    window.close()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw AttachmentRailSnapshotFailure.invalid("rail snapshot could not encode PNG")
    }

    let destination = output.appendingPathComponent("attachment-rail.png")
    try png.write(to: destination)
    try validate(data: png, expected: size)
    print("attachment-rail-snapshot: \(destination.path)")
  }

  private static func attachment(id: String, name: String) -> DSHAttachmentRef {
    DSHAttachmentRef(
      attachmentId: id,
      mediaType: "image/png",
      bytes: 1,
      width: 16,
      height: 16,
      name: name)
  }

  private static func image(_ color: NSColor) -> NSImage {
    let image = NSImage(size: NSSize(width: 32, height: 32))
    image.lockFocus()
    color.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 32, height: 32)).fill()
    image.unlockFocus()
    return image
  }

  private static func validate(data: Data, expected: CGSize) throws {
    guard data.count > 2_000, let bitmap = NSBitmapImageRep(data: data) else {
      throw AttachmentRailSnapshotFailure.invalid("rail snapshot is missing or unexpectedly small")
    }
    let scaleX = Double(bitmap.pixelsWide) / expected.width
    let scaleY = Double(bitmap.pixelsHigh) / expected.height
    guard abs(scaleX - scaleY) < 0.01, scaleX >= 1, scaleX <= 3 else {
      throw AttachmentRailSnapshotFailure.invalid("rail snapshot has an invalid scale")
    }

    var sawBlue = false
    var sawRed = false
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 24)) {
      for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 64)) {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        sawBlue = sawBlue || (color.blueComponent > color.redComponent + 0.15 && color.blueComponent > color.greenComponent)
        sawRed = sawRed || (color.redComponent > color.blueComponent + 0.15 && color.redComponent > color.greenComponent)
      }
    }
    guard sawBlue, sawRed else {
      throw AttachmentRailSnapshotFailure.invalid("rail snapshot does not contain both attachment thumbnails")
    }
  }
}
