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
      // 阴影必须由 SwiftUI 画：NSWindow 对透明内容的阴影只按首帧算且不再
      // 更新，逐帧动画下会留下一圈发灰的死边（改版前实拍可见）。
      p.hasShadow = false
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
  @State private var hovering = false
  /// 听写开始的时刻。涟漪按「相对开始时间」推进，第一圈才会从圆边推出去
  /// ——用绝对时间取模的话，按下说话那一瞬第一圈是从随机半径冒出来的。
  @State private var listenStart: Date?

  /// 任一会话在跑都算"动态"，不只当前选中的那一个。
  private var running: Bool { harness.isRunning || harness.sessions.contains { $0.isRunning } }

  var body: some View {
    ZStack {
      if voice.listening, let listenStart {
        ListeningRipples(start: listenStart)
          .transition(.opacity)
      }
      ZStack(alignment: .topTrailing) {
        SeaBubbleScene(animated: running || voice.listening,
                       waveSpeed: voice.listening ? 2.1 : 1.0)
          .frame(width: 44, height: 44)
          .clipShape(Circle())
          // 边缘要自带对比度：内圈自上而下由亮转暗的高光描边把它读成一颗
          // 被上方光源照亮的珠子，外圈一条极淡暗线保证浅色圆压在浅色背景
          // 上也分得开。改版前那条 0.35 白单边，在白窗上等于不存在。
          .overlay(Circle().strokeBorder(
            LinearGradient(colors: [.white.opacity(voice.listening ? 1.0 : 0.95),
                                    .white.opacity(0.25)],
                           startPoint: .top, endPoint: .bottom), lineWidth: 1))
          .overlay(Circle().strokeBorder(
            SeaArt.rimShade.opacity(hovering ? 0.26 : 0.18), lineWidth: 0.5))
          .shadow(color: SeaArt.rimShade.opacity(hovering ? 0.28 : 0.20),
                  radius: hovering ? 7 : 5, y: 2)
        if manager.unseenCompletion && !running {
          CompletionDot()
        }
      }
      .scaleEffect(hovering ? 1.06 : 1.0)
      .contentShape(Circle())
      .onTapGesture { manager.bubbleClicked() }
      // 这里**不加**按下态手势。DragGesture / onLongPressGesture 都会消费
      // mouseDown，而面板靠 isMovableByWindowBackground 拖动——那是 NSWindow
      // 在 sendEvent 里截 mouseDown 实现的，被 SwiftUI 手势吃掉就拖不动了。
      // 悬浮圈能拖是核心交互，不值得为一个按下反馈换掉。悬停反馈用
      // onHover，不消费事件，安全。
      .onHover { inside in
        hovering = inside
        // .set() 而不是 push/pop：无边框面板上进出事件不保证配对，
        // push/pop 会把光标栈搞失衡。
        if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
      }
    }
    .frame(width: 84, height: 84)
    .animation(.easeOut(duration: 0.9), value: voice.listening)
    .animation(.spring(response: 0.28, dampingFraction: 0.7), value: hovering)
    .onChange(of: voice.listening) { _, listening in
      listenStart = listening ? Date() : nil
    }
    .help(voice.listening ? "正在聆听…" : running ? "会话运行中 — 点击回到 DeepSeek Harness" : "点击回到 DeepSeek Harness")
  }
}

/// 唤醒动画：听写进行中，水纹从圆边一圈圈荡开 —— 海面"听到了你的声音"。
///
/// 要的是**淡淡的水纹带一点阴影扩散**，不是雷达 ping。每一圈由三层叠成，
/// 从外到内：
///   1. 暗色伴影（宽、重模糊、极低透明度）—— 阴影感的来源，在浅色背景上
///      给水纹垫出厚度；深色桌面上它几乎不可见，由第二层接手。
///   2. 柔光带（水青、更宽、重模糊）—— 扩散感的来源，任何背景都在。
///   3. 细亮线（水青，线宽随扩散从 1.0 收到 0.4）—— 水纹的锋面。
/// 峰值透明度全部压在 0.2 以下（早先那版是 0.60 的实心 1.5pt 环，读作声呐）。
/// 衰减用 1.6 次方而不是线性——真实水纹的能量耗散比线性快。
///
/// 五圈用**延迟入场**而不是相位偏移：开始听写的第一瞬只有第一圈、且正好贴
/// 在圆边上。用绝对时间取模的话，第一圈会从随机半径冒出来。
private struct ListeningRipples: View {
  let start: Date
  private static let period = 3.0
  private static let ringCount = 5
  /// 最大缩放 0.88 → 44 × 1.88 = 82.7pt，刚好收在 84pt 画布内，不会被裁。
  private static let maxScale = 0.88

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
      let elapsed = context.date.timeIntervalSince(start)
      ZStack {
        ForEach(0..<Self.ringCount, id: \.self) { ring in
          let lead = Double(ring) * Self.period / Double(Self.ringCount)
          if elapsed >= lead {
            let p = ((elapsed - lead) / Self.period).truncatingRemainder(dividingBy: 1)
            // 两端都渐变：起手 12% 用于淡入，避免贴着圆边"啪"一下出现。
            let decay = min(p / 0.12, 1) * pow(1 - p, 1.6)
            let scale = 1 + (1 - pow(1 - p, 2.2)) * Self.maxScale
            ZStack {
              Circle().strokeBorder(SeaArt.rimShade.opacity(0.09 * decay), lineWidth: 3.5)
                .blur(radius: 2.6)
              Circle().strokeBorder(SeaArt.waterNear.opacity(0.11 * decay), lineWidth: 5.0)
                .blur(radius: 3.4)
              Circle().strokeBorder(SeaArt.waterNear.opacity(0.20 * decay),
                                    lineWidth: 1.0 + (0.4 - 1.0) * CGFloat(p))
                .blur(radius: 0.6)
            }
            .frame(width: 44, height: 44)
            .scaleEffect(scale)
          }
        }
      }
    }
  }
}

/// 完成未读的红点。弹簧弹出 + 一圈柔光，让它出现的那一下能被余光抓到——
/// 一个直接冒出来的静态圆点很容易被完全错过。
private struct CompletionDot: View {
  @State private var shown = false
  private static let red = Color(red: 0.914, green: 0.290, blue: 0.235)

  var body: some View {
    ZStack {
      Circle().fill(Self.red.opacity(0.28))
        .frame(width: 19, height: 19)
        .blur(radius: 3)
        .scaleEffect(shown ? 1 : 0.4)
        .opacity(shown ? 1 : 0)
      Circle().fill(Self.red)
        .frame(width: 11, height: 11)
        .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
    }
    .scaleEffect(shown ? 1 : 0.2)
    .opacity(shown ? 1 : 0)
    .onAppear {
      withAnimation(.spring(response: 0.42, dampingFraction: 0.55)) { shown = true }
    }
  }
}

/// 悬浮圈里的海景，和转录尾部指示器、App 图标同一套形状与配色（都来自
/// SeaArt / SeaWhaleScene），按 44pt 排布。
///
/// 这里管的是**潮位**：空闲时潮位 0，圈里只有一只鲸静静浮着，没有海浪；
/// 开始运行海水涨上来，鲸开始跃身；运行结束海水退去，回到那只鲸。
/// "在不在跑"就是"有没有水"——不用靠动不动去分辨。
///
/// 退潮走完之前不熄火：TimelineView 一直跑到潮位归零才切回静态帧，所以
/// 结束动画能完整播完（用户早先反馈"结束的时候走完完整一遍"）。中途又开始
/// 运行的话，过渡从**当前潮位**起算，不会跳回去重来。
private struct SeaBubbleScene: View {
  let animated: Bool
  /// 听写中海浪加速涌动（唤醒动画的一部分）；常态 1.0。
  var waveSpeed: Double = 1.0

  /// 波形相位累加器：速度变化瞬间保持相位连续（`t × speed` 的绝对相位在
  /// 切速时会跳变，浪面看起来像"瞬移"）。用类引用装载，逐帧更新不触发视图
  /// 失效。
  private final class PhaseBox { var phase: Double = 0; var last: Date? }
  @State private var box = PhaseBox()
  /// 潮位过渡：从 fromLevel 走到 toLevel，用 startedAt 计时。
  @State private var fromLevel: CGFloat = 0
  @State private var toLevel: CGFloat = 0
  @State private var startedAt = Date.distantPast
  /// true = 潮位已归零且不再运行，渲染静态帧，不空转 TimelineView。
  @State private var settled = true
  /// 让迟到的"落潮完成"回调作废（期间又开始了新一轮运行）。
  @State private var settleGeneration = 0

  private var duration: Double { toLevel > fromLevel ? SeaArt.tideRise : SeaArt.tideFall }

  private func level(at now: Date) -> CGFloat {
    guard duration > 0 else { return toLevel }
    let p = now.timeIntervalSince(startedAt) / duration
    return fromLevel + (toLevel - fromLevel) * SeaArt.easeInOut(p)
  }

  var body: some View {
    ZStack {
      if settled {
        SeaWhaleScene(wavePhase: box.phase, breachTime: 0, level: 0)
      } else {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
          let t = context.date.timeIntervalSinceReferenceDate
          let dt = box.last.map { min(max(context.date.timeIntervalSince($0), 0), 0.2) } ?? 0
          let _ = { box.phase += dt * waveSpeed; box.last = context.date }()
          SeaWhaleScene(wavePhase: box.phase, breachTime: t, level: level(at: context.date))
        }
      }
    }
    .onAppear {
      fromLevel = animated ? 1 : 0
      toLevel = fromLevel
      settled = !animated
    }
    .onChange(of: animated) { _, nowAnimated in
      settleGeneration += 1
      let generation = settleGeneration
      let now = Date()
      // 从当前潮位起算，中途反转不会跳回起点。
      fromLevel = settled ? 0 : level(at: now)
      toLevel = nowAnimated ? 1 : 0
      startedAt = now
      if nowAnimated {
        box.last = nil
        settled = false
        return
      }
      // 退潮播完再熄火。
      DispatchQueue.main.asyncAfter(deadline: .now() + SeaArt.tideFall + 0.05) {
        guard settleGeneration == generation else { return }
        box.last = nil
        settled = true
      }
    }
  }
}
