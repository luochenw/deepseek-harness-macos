import SwiftUI
import AppKit
import Combine

/// 悬浮圈 —— app 的"收起态"：一个置顶于所有窗口、跟随所有空间的
/// 圆形小窗。会话运行中它是动态的（海浪滚动 + 月亮升落），后台完成
/// 后凝固成静态帧并亮起红点，点击唤起主窗口。
/// 状态全部自持（订阅推导），不给 HarnessController 增加任何字段 ——
/// 见 .agents/notes/implemented/feature/2026-08-17-floating-bubble.md。
@MainActor
final class FloatingBubbleManager: ObservableObject {
  static let shared = FloatingBubbleManager()
  private static let enabledKey = "dsh.floatingBubble.enabled"

  /// 有一轮在后台跑完、用户还没回来看过。红点的唯一来源。
  @Published var unseenCompletion = false
  @Published private(set) var enabled: Bool

  private var panel: NSPanel?
  private weak var harness: HarnessController?
  private var cancellables: Set<AnyCancellable> = []

  private init() {
    enabled = UserDefaults.standard.object(forKey: Self.enabledKey) == nil
      ? true : UserDefaults.standard.bool(forKey: Self.enabledKey)
  }

  func attach(_ harness: HarnessController) {
    guard self.harness !== harness else { return }
    self.harness = harness
    cancellables.removeAll()
    // 运行沿：开始新一轮先清红点；true→false 的完成沿只在 app 不在
    // 前台时点亮红点 —— 用户正看着主窗口时完成不需要额外提醒。
    harness.$isRunning
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] running in
        guard let self else { return }
        if running { unseenCompletion = false }
        else if !NSApp.isActive { unseenCompletion = true }
      }
      .store(in: &cancellables)
    NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      .sink { [weak self] _ in self?.unseenCompletion = false }
      .store(in: &cancellables)
    if enabled { show() }
  }

  func toggle() {
    enabled.toggle()
    UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
    enabled ? show() : hide()
  }

  /// 单击：回到主窗口。红点在这里熄灭（didBecomeActive 也会兜底）。
  func bubbleClicked() {
    unseenCompletion = false
    NSApp.activate(ignoringOtherApps: true)
    NSApp.windows.first { !($0 is NSPanel) && $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
  }

  private func show() {
    guard let harness else { return }
    if panel == nil {
      let p = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 52, height: 52),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered, defer: false)
      p.level = .floating
      p.isOpaque = false
      p.backgroundColor = .clear
      p.hasShadow = true
      p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      p.isMovableByWindowBackground = true
      p.hidesOnDeactivate = false
      p.isReleasedWhenClosed = false
      p.contentView = NSHostingView(rootView: FloatingBubbleView(harness: harness, manager: self))
      p.setFrameAutosaveName("dsh.floatingBubble")
      // 首次出现：主屏右上角，避开菜单栏。
      if p.frame.origin == .zero, let screen = NSScreen.main {
        p.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 76, y: screen.visibleFrame.maxY - 84))
      }
      panel = p
    }
    panel?.orderFrontRegardless()
  }

  private func hide() { panel?.orderOut(nil) }
}

struct FloatingBubbleView: View {
  @ObservedObject var harness: HarnessController
  @ObservedObject var manager: FloatingBubbleManager

  /// 任一会话在跑都算"动态"，不只当前选中的那一个。
  private var running: Bool { harness.isRunning || harness.sessions.contains { $0.isRunning } }

  var body: some View {
    ZStack(alignment: .topTrailing) {
      SeaBubbleScene(animated: running)
        .frame(width: 44, height: 44)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
      if manager.unseenCompletion && !running {
        Circle().fill(Color(red: 0.914, green: 0.290, blue: 0.235))
          .frame(width: 11, height: 11)
          .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
      }
    }
    .padding(4)
    .contentShape(Circle())
    .onTapGesture { manager.bubbleClicked() }
    .help(running ? "会话运行中 — 点击回到 DeepSeek Harness" : "点击回到 DeepSeek Harness")
  }
}

/// 悬浮圈里的海景：与转录 WaitingWaveIndicator 同一套视觉常量按 44pt
/// 重排。运行中逐帧动画；静止态渲染一张固定帧（月亮停在弧线顶点），
/// 不再空转 TimelineView。
private struct SeaBubbleScene: View {
  let animated: Bool
  var body: some View {
    if animated {
      TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
        let t = context.date.timeIntervalSinceReferenceDate
        let cycle = (t / 5.0).truncatingRemainder(dividingBy: 1)
        scene(wavePhase: t, moonArc: min(cycle / 0.82, 1.0))
      }
    } else {
      scene(wavePhase: 0, moonArc: 0.5)
    }
  }

  private func scene(wavePhase t: Double, moonArc: Double) -> some View {
    ZStack {
      LinearGradient(
        colors: [Color(red: 0.031, green: 0.106, blue: 0.125), Color(red: 0.043, green: 0.216, blue: 0.235), Color(red: 0.039, green: 0.424, blue: 0.404)],
        startPoint: .top, endPoint: .bottom)
      let theta = (Double.pi + 0.65) - moonArc * (Double.pi + 1.3)
      Circle().fill(Color(red: 0.867, green: 0.980, blue: 0.960))
        .frame(width: 7.5, height: 7.5)
        .offset(x: 15.0 * cos(theta), y: -12.5 * sin(theta) + 2.5)
        .frame(width: 44, height: 44)
        .mask(alignment: .top) { Rectangle().frame(height: 27) }
      WaveBand(baseY: 0.56, amplitude: 0.07, phase: t * 1.7).fill(Color(red: 0.290, green: 0.871, blue: 0.824).opacity(0.30))
      WaveBand(baseY: 0.66, amplitude: 0.065, phase: t * 2.3 + 2.1).fill(Color(red: 0.376, green: 0.925, blue: 0.871).opacity(0.55))
      WaveBand(baseY: 0.75, amplitude: 0.055, phase: t * 2.9 + 4.4).fill(Color(red: 0.173, green: 0.773, blue: 0.722).opacity(0.95))
    }
    .frame(width: 44, height: 44)
  }
}
