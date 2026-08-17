import SwiftUI
import AppKit
import Combine

/// 悬浮圈 —— app 的"收起态"：一个置顶于所有窗口、跟随所有空间的
/// 圆形小窗。会话运行中它是动态的（海浪滚动 + 月亮升落），后台完成
/// 后凝固成静态帧并亮起红点，点击唤起主窗口。
/// 状态全部自持（订阅推导），不给 HarnessController 增加任何字段 ——
/// 见 .agents/notes/implemented/feature/2026-08-17-floating-bubble.md。
/// 语音状态 → 悬浮圈的最小桥：听写（唤醒词触发或手动按下）进行中时
/// 为 true，悬浮圈据此播放声呐涟漪。由 VoiceInputButton 的状态变化
/// 单向写入，语音模块不需要知道悬浮圈的存在。
@MainActor
final class VoiceWakeSignal: ObservableObject {
  static let shared = VoiceWakeSignal()
  @Published var listening = false
  private init() {}
}

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
  /// 刚有语音派发时更进一步——直接进入那条新建的对话。
  func bubbleClicked() {
    unseenCompletion = false
    NSApp.activate(ignoringOtherApps: true)
    NSApp.windows.first { !($0 is NSPanel) && $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
    harness?.openPendingVoiceTaskSession()
  }

  private func show() {
    guard let harness else { return }
    if panel == nil {
      // 84pt 画布：中间 44pt 的圆，四周留给声呐涟漪扩散（唤醒动画）。
      let p = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 84, height: 84),
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
      // autosave 会连尺寸一起恢复（可能是旧版的 52pt），画布尺寸以
      // 当前代码为准。
      p.setContentSize(NSSize(width: 84, height: 84))
      // 首次出现：主屏右上角，避开菜单栏。
      if p.frame.origin == .zero, let screen = NSScreen.main {
        p.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 104, y: screen.visibleFrame.maxY - 112))
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
  @ObservedObject private var voice = VoiceWakeSignal.shared

  /// 任一会话在跑都算"动态"，不只当前选中的那一个。
  private var running: Bool { harness.isRunning || harness.sessions.contains { $0.isRunning } }

  var body: some View {
    ZStack {
      // 唤醒动画：听写进行中，三圈声呐涟漪从圆边向外扩散消散 ——
      // 海面"听到了你的声音"。结束时不瞬间消失：外层 .animation 让
      // 移除走 0.9s 的透明度过渡，期间涟漪仍在继续扩散，读作"散尽"。
      if voice.listening {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
          let t = context.date.timeIntervalSinceReferenceDate
          ZStack {
            ForEach(0..<3, id: \.self) { ring in
              let p = ((t / 1.6) + Double(ring) / 3).truncatingRemainder(dividingBy: 1)
              Circle()
                .strokeBorder(Color(red: 0.376, green: 0.925, blue: 0.871).opacity((1 - p) * 0.55), lineWidth: 1.5)
                .frame(width: 44, height: 44)
                .scaleEffect(1 + p * 0.85)
            }
          }
        }
        .transition(.opacity)
      }
      ZStack(alignment: .topTrailing) {
        SeaBubbleScene(animated: running || voice.listening, waveSpeed: voice.listening ? 2.1 : 1.0)
          .frame(width: 44, height: 44)
          .clipShape(Circle())
          .overlay(Circle().strokeBorder(Color.white.opacity(voice.listening ? 0.6 : 0.35), lineWidth: 1))
        if manager.unseenCompletion && !running {
          Circle().fill(Color(red: 0.914, green: 0.290, blue: 0.235))
            .frame(width: 11, height: 11)
            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
        }
      }
      .contentShape(Circle())
      .onTapGesture { manager.bubbleClicked() }
    }
    .frame(width: 84, height: 84)
    .animation(.easeOut(duration: 0.9), value: voice.listening)
    .help(voice.listening ? "正在聆听…" : running ? "会话运行中 — 点击回到 DeepSeek Harness" : "点击回到 DeepSeek Harness")
  }
}

/// 悬浮圈里的海景：与转录 WaitingWaveIndicator 同一套视觉常量按 44pt
/// 重排。运行中逐帧动画；静止态渲染一张固定帧（月亮停在弧线顶点）,
/// 不再空转 TimelineView。
///
/// 结束不突兀（用户反馈"结束的时候走完完整一遍"）：`animated` 关闭后
/// 先把当前月亮周期走完——月亮落入海面、进入休止段——到周期边界才
/// 用 0.6s 透明度过渡淡入静态帧；期间若重新开始运行则直接续播。
private struct SeaBubbleScene: View {
  let animated: Bool
  /// 听写中海浪加速涌动（唤醒动画的一部分）；常态 1.0。
  var waveSpeed: Double = 1.0

  /// 波形相位累加器：速度变化瞬间保持相位连续（`t × speed` 的绝对
  /// 相位在切速时会跳变，浪面看起来像"瞬移"）。用类引用装载，逐帧
  /// 更新不触发视图失效。
  private final class PhaseBox { var phase: Double = 0; var last: Date? }
  @State private var box = PhaseBox()
  /// true = 显示静态帧。animated 关闭后延迟到周期边界才置 true。
  @State private var frozen = true
  /// 让迟到的"定格"回调作废（期间又开始了新一轮动画）。
  @State private var finishGeneration = 0

  var body: some View {
    ZStack {
      if frozen {
        scene(wavePhase: box.phase, moonArc: 0.5).transition(.opacity)
      } else {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
          let t = context.date.timeIntervalSinceReferenceDate
          let dt = box.last.map { min(max(context.date.timeIntervalSince($0), 0), 0.2) } ?? 0
          let _ = { box.phase += dt * waveSpeed; box.last = context.date }()
          let cycle = (t / 5.0).truncatingRemainder(dividingBy: 1)
          scene(wavePhase: box.phase, moonArc: min(cycle / 0.82, 1.0))
        }
        .transition(.opacity)
      }
    }
    .onAppear { frozen = !animated }
    .onChange(of: animated) { _, nowAnimated in
      finishGeneration += 1
      let generation = finishGeneration
      if nowAnimated {
        box.last = nil
        withAnimation(.easeInOut(duration: 0.3)) { frozen = false }
        return
      }
      // 走完当前周期：等到下一个 5s 周期边界（此时月亮已落海并休止）
      // 再定格；淡入静态帧时月亮在水下→顶点的切换发生在不可见处。
      let now = Date().timeIntervalSinceReferenceDate
      let remain = 5.0 - now.truncatingRemainder(dividingBy: 5.0) + 0.05
      DispatchQueue.main.asyncAfter(deadline: .now() + remain) {
        guard finishGeneration == generation else { return }
        box.last = nil
        withAnimation(.easeInOut(duration: 0.6)) { frozen = true }
      }
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
