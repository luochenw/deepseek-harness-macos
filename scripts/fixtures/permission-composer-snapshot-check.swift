import AppKit
import Foundation
import SwiftUI
@testable import DSHAppLib

enum PermissionComposerSnapshotFailure: Error, CustomStringConvertible {
  case invalid(String)

  var description: String {
    switch self { case .invalid(let message): message }
  }
}

@main
struct PermissionComposerSnapshotCheck {
  @MainActor
  static func main() throws {
    guard CommandLine.arguments.count == 2 else {
      throw PermissionComposerSnapshotFailure.invalid("usage: permission-composer-snapshot-check OUTPUT_DIR")
    }
    _ = NSApplication.shared
    NSApp.appearance = NSAppearance(named: .aqua)
    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

    let harness = HarnessController(startRuntime: false)
    let session = HarnessController.Session(
      title: "运行中的会话",
      workspaceName: "ds-harness",
      updatedAt: Date(),
      messages: [
        HarnessController.Message(role: .user, text: "实现权限菜单"),
        HarnessController.Message(role: .assistant, text: "正在检查 Host 协议。"),
      ],
      isRunning: true,
      hostSessionId: "session-running")
    harness.sessions = [session]
    harness.selectedSessionID = session.id
    harness.hostCurrentSessionID = "session-running"
    harness.isRunning = true
    harness.availableModels = try modelCatalog()
    harness.provider = "xpa"
    harness.model = "DeepSeek-V4.1-Flash"
    harness.reasoningEffort = "max"
    harness.draft = "补充：完成后运行全部测试"
    harness.draftImages = try draftImages(in: output)
    harness.queueItems = [
      DSHQueueItem(id: "queued-1", placement: "queued", text: "再检查发布说明"),
      DSHQueueItem(id: "steering-1", placement: "steering", text: "先保证菜单与原生样式一致"),
    ]
    harness.rememberPermissionSelection(
      DSHPermissionSelection(
        options: [
          DSHPermissionOption(value: "read-only", name: "read-only", description: nil),
          DSHPermissionOption(value: "workspace-write", name: "workspace-write", description: nil),
          DSHPermissionOption(value: "danger-full-access", name: "danger-full-access", description: nil),
        ],
        currentValue: "workspace-write"),
      sessionID: "session-running",
      seq: 4)
    harness.settingsDescription = try settingsDescription()

    try render(
      "composer-running",
      size: CGSize(width: 720, height: 450),
      output: output,
      content: Composer().environmentObject(harness))
    try render(
      "draft-image-lightbox",
      size: CGSize(width: 640, height: 520),
      output: output,
      content: DraftImageLightbox(image: harness.draftImages[0]))
    try render(
      "settings-general",
      size: CGSize(width: 810, height: 580),
      output: output,
      content: SettingsView().environmentObject(harness))
    try render(
      "model-picker-panel",
      size: CGSize(width: 340, height: 560),
      output: output,
      content: ModelPickerPanel().environmentObject(harness))

    print("permission-composer-snapshots: \(output.path)")
  }

  private static func draftImages(in output: URL) throws -> [HarnessController.DraftImage] {
    try ["reference-a.png", "reference-b.png"].enumerated().map { index, name in
      guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 96,
        pixelsHigh: 72,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      ) else {
        throw PermissionComposerSnapshotFailure.invalid("could not create draft image")
      }
      for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
          let red = CGFloat(x) / CGFloat(bitmap.pixelsWide)
          let green = CGFloat(y) / CGFloat(bitmap.pixelsHigh)
          let blue = index == 0 ? CGFloat(0.8) : CGFloat(0.35)
          bitmap.setColor(
            NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1),
            atX: x,
            y: y)
        }
      }
      guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw PermissionComposerSnapshotFailure.invalid("could not encode draft image")
      }
      let url = output.appendingPathComponent(name)
      try png.write(to: url)
      return HarnessController.DraftImage(url: url, mediaType: "image/png")
    }
  }

  private static func settingsDescription() throws -> DSHSettingsDescription {
    let data = Data("""
    {
      "writable":true,
      "hasDocument":true,
      "namespaces":[
        {
          "ns":"permission",
          "schema":{
            "uid":5,
            "refs":{
              "1":{"type":"const","meta":{},"value":"read-only"},
              "2":{"type":"const","meta":{},"value":"workspace-write"},
              "3":{"type":"const","meta":{},"value":"danger-full-access"},
              "4":{"type":"union","meta":{"required":true},"list":[1,2,3]},
              "5":{"type":"object","meta":{},"dict":{"defaultPreset":4}}
            }
          },
          "value":{"defaultPreset":"workspace-write"},
          "applies":"live",
          "secrets":[],
          "revision":0
        },
        {
          "ns":"ui-conversation",
          "value":{"busyEnter":"steer"},
          "applies":"live",
          "secrets":[],
          "revision":0
        }
      ]
    }
    """.utf8)
    return try JSONDecoder().decode(DSHSettingsDescription.self, from: data)
  }

  private static func modelCatalog() throws -> [DSHModelGroup] {
    let data = Data("""
    [
      {
        "id":"xpa",
        "name":"XPA Relay",
        "models":[
          {
            "id":"DeepSeek-V4.1-Flash",
            "name":"DeepSeek-V4.1-Flash",
            "reasoning":{
              "efforts":[
                {"id":"off","name":"Off"},
                {"id":"low","name":"Low"},
                {"id":"medium","name":"Medium"},
                {"id":"high","name":"High"},
                {"id":"xhigh","name":"Xhigh"},
                {"id":"max","name":"Max"}
              ],
              "defaultEffort":"high"
            }
          },
          {"id":"DeepSeek-V4-Pro","name":"DeepSeek-V4-Pro"}
        ]
      }
    ]
    """.utf8)
    return try JSONDecoder().decode([DSHModelGroup].self, from: data)
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
      throw PermissionComposerSnapshotFailure.invalid("\(name): no bitmap")
    }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    window.orderOut(nil)
    window.close()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw PermissionComposerSnapshotFailure.invalid("\(name): could not encode PNG")
    }
    let destination = output.appendingPathComponent("\(name).png")
    try png.write(to: destination)
    try validate(name: name, data: png, expected: size)
  }

  private static func validate(name: String, data: Data, expected: CGSize) throws {
    guard data.count > 3_000, let bitmap = NSBitmapImageRep(data: data) else {
      throw PermissionComposerSnapshotFailure.invalid("\(name): snapshot is blank or too small")
    }
    let scaleX = Double(bitmap.pixelsWide) / expected.width
    let scaleY = Double(bitmap.pixelsHigh) / expected.height
    guard abs(scaleX - scaleY) < 0.01, scaleX >= 1, scaleX <= 3 else {
      throw PermissionComposerSnapshotFailure.invalid("\(name): invalid snapshot scale")
    }
    var colors = Set<UInt32>()
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 36)) {
      for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 60)) {
        guard let rgb = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        let red = UInt32((rgb.redComponent * 31).rounded())
        let green = UInt32((rgb.greenComponent * 31).rounded())
        let blue = UInt32((rgb.blueComponent * 31).rounded())
        let alpha = UInt32((rgb.alphaComponent * 31).rounded())
        colors.insert((red << 15) | (green << 10) | (blue << 5) | alpha)
      }
    }
    guard colors.count > 12 else {
      throw PermissionComposerSnapshotFailure.invalid("\(name): snapshot lacks visible UI detail")
    }
    print("\(name): \(bitmap.pixelsWide)x\(bitmap.pixelsHigh), \(data.count) bytes, \(colors.count) sampled colors")
  }
}
