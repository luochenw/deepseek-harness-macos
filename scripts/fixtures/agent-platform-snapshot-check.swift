import AppKit
import Foundation
import SwiftUI
@testable import DSHAppLib

enum SnapshotFailure: Error, CustomStringConvertible {
  case render(String)
  case invalid(String)

  var description: String {
    switch self {
    case .render(let message), .invalid(let message): message
    }
  }
}

@main
struct AgentPlatformSnapshotCheck {
  @MainActor
  static func main() throws {
    guard CommandLine.arguments.count == 2 else {
      throw SnapshotFailure.invalid("usage: agent-platform-snapshot-check OUTPUT_DIR")
    }
    _ = NSApplication.shared
    NSApp.appearance = NSAppearance(named: .aqua)

    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

    let harness = HarnessController(startRuntime: false)
    harness.workspace = URL(fileURLWithPath: "/tmp/dsh-agent-platform-snapshot", isDirectory: true)
    let profile = sampleProfile()
    harness.agentProfiles = [profile]
    harness.agentRuntimeStatuses = sampleRuntimeStatuses()
    harness.hostCurrentSessionID = "root-session"
    harness.agentBatches = [sampleBatch(profile: profile)]
    harness.selectedAgentBatchID = "batch-1"

    try render(
      "profiles-panel",
      size: CGSize(width: 360, height: 760),
      output: output,
      content: AgentPlatformProfilesView().padding(DSHSpace.s4).environmentObject(harness))

    try render(
      "execution-panel",
      size: CGSize(width: 360, height: 760),
      output: output,
      content: AgentPlatformExecutionView().padding(DSHSpace.s4).environmentObject(harness))

    try render(
      "profile-editor",
      size: CGSize(width: 760, height: 640),
      output: output,
      content: AgentProfileEditorSheet(profile: profile).environmentObject(harness))

    try render(
      "manual-run",
      size: CGSize(width: 620, height: 430),
      output: output,
      content: AgentManualRunSheet(profile: profile).environmentObject(harness))

    try render(
      "composer-profile",
      size: CGSize(width: 620, height: 330),
      output: output,
      content: VStack(alignment: .leading, spacing: DSHSpace.s3) {
        AgentComposerSelectionBar(profile: profile)
        AgentProfilePalette(profiles: [profile], selection: 0, onPick: { _ in })
        Spacer()
      }
      .padding(DSHSpace.s4)
      .environmentObject(harness))

    print("agent-platform-snapshots: \(output.path)")
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
      throw SnapshotFailure.render("\(name): NSHostingView produced no bitmap")
    }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    window.orderOut(nil)
    window.close()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw SnapshotFailure.render("\(name): bitmap cannot be encoded as PNG")
    }

    let destination = output.appendingPathComponent("\(name).png")
    try png.write(to: destination)
    try validate(name: name, data: png, expected: size)
  }

  private static func validate(name: String, data: Data, expected: CGSize) throws {
    guard data.count > 3_000 else {
      throw SnapshotFailure.invalid("\(name): PNG is unexpectedly small (\(data.count) bytes)")
    }
    guard let bitmap = NSBitmapImageRep(data: data) else {
      throw SnapshotFailure.invalid("\(name): PNG cannot be decoded")
    }
    let scaleX = Double(bitmap.pixelsWide) / expected.width
    let scaleY = Double(bitmap.pixelsHigh) / expected.height
    guard abs(scaleX - scaleY) < 0.01, scaleX >= 1, scaleX <= 3 else {
      throw SnapshotFailure.invalid(
        "\(name): expected \(Int(expected.width))x\(Int(expected.height)) points at a consistent 1x-3x scale, got \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
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
      throw SnapshotFailure.invalid(
        "\(name): image appears blank (visible samples \(visible), sampled colors \(colors.count))")
    }
    print(
      "\(name): \(bitmap.pixelsWide)x\(bitmap.pixelsHigh) @\(String(format: "%.1f", scaleX))x, \(data.count) bytes, \(colors.count) sampled colors")
  }

  private static func sampleProfile() -> DSHAgentProfile {
    DSHAgentProfile(
      id: "profile-review",
      name: "实现与审查",
      mention: "review",
      description: "让多个 Runtime 并行实现、审查并保留独立结果。",
      persona: "关注行为正确性、回归风险和可验证证据，结论保持简洁。",
      defaultTask: "审查当前改动并提出可直接采纳的修复。",
      defaultMode: .execution,
      allowModelDispatch: true,
      integrationPolicy: .manual,
      revision: 4,
      adapters: [
        DSHAgentAdapterBinding(
          id: "dsh-primary",
          runtime: "dsh",
          enabled: true,
          displayName: "DSH",
          model: "deepseek-v4",
          toolAllowlist: nil,
          toolDenylist: ["browser"],
          analysisSupported: true,
          executionSupported: true,
          config: nil),
        DSHAgentAdapterBinding(
          id: "codex-review",
          runtime: "codex",
          enabled: true,
          displayName: "Codex",
          model: "gpt-5.6",
          toolAllowlist: nil,
          toolDenylist: nil,
          analysisSupported: false,
          executionSupported: true,
          config: nil),
      ])
  }

  private static func sampleRuntimeStatuses() -> [DSHAgentRuntimeStatus] {
    [
      DSHAgentRuntimeStatus(
        runtime: "dsh", displayName: "DSH", available: true, version: "0.1.1-rc.2",
        detail: "continuable child", analysisSupported: true, executionSupported: true),
      DSHAgentRuntimeStatus(
        runtime: "claude-code", displayName: "Claude Code", available: true, version: "2.1.193",
        detail: nil, analysisSupported: true, executionSupported: true),
      DSHAgentRuntimeStatus(
        runtime: "codex", displayName: "Codex", available: true, version: "0.147.0",
        detail: nil, analysisSupported: false, executionSupported: true),
      DSHAgentRuntimeStatus(
        runtime: "zcode", displayName: "ZCode", available: false, version: nil,
        detail: "未检测到可执行文件", analysisSupported: true, executionSupported: true),
    ]
  }

  private static func sampleBatch(profile: DSHAgentProfile) -> DSHAgentBatch {
    let dsh = DSHAgentRun(
      id: "run-dsh",
      batchId: "batch-1",
      adapter: "dsh",
      adapterBindingId: "dsh-primary",
      adapterSnapshot: profile.adapters[0],
      runtimeProfileSnapshot: profile,
      label: "DSH",
      status: "succeeded",
      attempt: 1,
      contextId: "context-dsh",
      childSessionId: "child-dsh",
      queuedAt: 1_787_000_000_000,
      startedAt: 1_787_000_001_000,
      finishedAt: 1_787_000_041_000,
      output: "实现完成，新增 4 个回归测试并修复共享 context 生命周期。",
      error: nil,
      worktreePath: "/tmp/dsh-agent/context-dsh",
      branch: "dsh-agent/context-dsh",
      baselineCommit: "0123456789abcdef",
      diffSummary: "3 files changed, 84 insertions(+), 12 deletions(-)",
      testSummary: "Host 69/69",
      workspaceFiles: ["lib/core.js", "test/core.test.js"],
      retryable: false,
      workspaceCleaned: false,
      workspaceOutcome: nil,
      adopted: false,
      discarded: false)
    let codex = DSHAgentRun(
      id: "run-codex",
      batchId: "batch-1",
      adapter: "codex",
      adapterBindingId: "codex-review",
      adapterSnapshot: profile.adapters[1],
      runtimeProfileSnapshot: profile,
      label: "Codex",
      status: "interrupted",
      attempt: 1,
      contextId: nil,
      childSessionId: nil,
      queuedAt: 1_787_000_000_000,
      startedAt: 1_787_000_002_000,
      finishedAt: 1_787_000_020_000,
      output: nil,
      error: "Host 重启，外部 Worker 已中断",
      worktreePath: "/tmp/dsh-agent/run-codex",
      branch: "dsh-agent/run-codex",
      baselineCommit: "fedcba9876543210",
      diffSummary: nil,
      testSummary: nil,
      workspaceFiles: nil,
      retryable: true,
      workspaceCleaned: false,
      workspaceOutcome: nil,
      adopted: false,
      discarded: false)
    return DSHAgentBatch(
      id: "batch-1",
      capabilitySnapshotVersion: 1,
      recoveryBlocked: false,
      rootSessionId: "root-session",
      initiatorSessionId: "root-session",
      initiatorLabel: "当前主 Agent",
      rootCwd: "/workspace",
      sourceCwd: "/workspace/feature",
      sandboxMode: "workspace-write",
      sourceAgentOptions: DSHAgentOptionsSnapshot(
        provider: "relay",
        model: "deepseek-v4",
        maxTokens: 8_192),
      sourceToolAllowlist: ["read", "grep", "bash", "write"],
      sourceAgentPreset: "code",
      profileId: profile.id,
      profileName: profile.name,
      profileMention: profile.mention,
      profileDeleted: false,
      profileSnapshot: profile,
      task: "实现统一 Agent 编排，并复核重启恢复、worktree 隔离与右栏交互。",
      mode: .execution,
      integrationPolicy: .manual,
      status: "partial",
      createdAt: 1_787_000_000_000,
      updatedAt: 1_787_000_041_000,
      summary: "DSH 已完成实现；Codex 因 Host 重启中断，可从右侧显式重试。",
      runs: [dsh, codex],
      integrationState: "manualPending",
      integrationSummary: nil,
      integrationTestSummary: nil,
      integrationError: nil)
  }
}
