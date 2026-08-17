import SwiftUI

private struct HeaderChip<Content: View>: View {
  let icon: String
  let label: String
  @ViewBuilder let content: () -> Content
  var body: some View {
    Menu { content() } label: {
      HStack(spacing: 6) { Image(systemName: icon).font(.system(size: 11)); Text(label).font(.system(size: 11.5)) }
        .padding(.horizontal, DSHSpace.s3).padding(.vertical, 6)
        .background(DSHTheme.surface, in: Capsule())
        .foregroundStyle(DSHTheme.inkSoft)
    }.menuStyle(.borderlessButton).fixedSize()
  }
}

struct ConversationHeader: View {
  @EnvironmentObject var harness: HarnessController

  /// The Host's live summary for the session currently shown — used only to
  /// decide whether the preset control should be locked, see `presetLocked`.
  private var currentSessionSummary: DSHSessionSummary? {
    harness.hostSessions.first { $0.sessionId == harness.hostCurrentSessionID }
  }
  /// True once the Host has real presets to offer AND the displayed session
  /// already has turn history — in that state `selectCurrentPreset` would be
  /// rejected by the Host with `agent-preset-locked`, so the control must not
  /// stay clickable and silently fail. The local `setPreset` path (used when
  /// `hostPresets` is empty, i.e. it only affects the *next* new session) is
  /// never rejected and stays untouched.
  private var presetLocked: Bool {
    guard !harness.hostPresets.isEmpty, let summary = currentSessionSummary else { return false }
    return summary.blank == false
  }
  private var lockedPresetLabel: String { currentSessionSummary?.agentPreset ?? harness.preset.label }

  var body: some View {
    HStack(spacing: DSHSpace.s2) {
      VStack(alignment: .leading, spacing: 2) {
        if !harness.subagentPath.isEmpty {
          HStack(spacing: 6) {
            Button(action: harness.navigateUpSubagent) { Image(systemName: "chevron.left") }.buttonStyle(.dshGhost).help("返回上一级")
            Text(harness.subagentPath.map(\.title).joined(separator: " › ")).font(.caption).foregroundStyle(DSHTheme.inkFaint).lineLimit(1)
          }
        }
        Text(harness.displayedSession?.title ?? "新会话").font(.system(size: 15, weight: .semibold)).foregroundStyle(DSHTheme.ink)
        Text(harness.workspace?.path ?? "选择工作区后开始").font(.caption).foregroundStyle(DSHTheme.inkFaint).lineLimit(1)
      }
      Spacer()
      if presetLocked {
        HStack(spacing: 6) { Image(systemName: "lock.fill").font(.system(size: 11)); Text(lockedPresetLabel).font(.system(size: 11.5)) }
          .padding(.horizontal, DSHSpace.s3).padding(.vertical, 6)
          .background(DSHTheme.warmSoft, in: Capsule())
          .foregroundStyle(DSHTheme.warm)
          .help("会话已开始运行，Agent Preset 无法再切换（Host 会拒绝：agent-preset-locked）")
      } else {
        HeaderChip(icon: "cpu", label: harness.activePresetLabel) {
          if harness.hostPresets.isEmpty { ForEach(HarnessController.Preset.allCases) { p in Button(p.label) { harness.setPreset(p) } } }
          else { ForEach(harness.hostPresets.filter { $0.broken == nil }) { p in Button(p.name ?? p.id) { harness.selectCurrentPreset(p.id) } } }
        }
      }
      // With content in the transcript the workspace context docks up here,
      // compact (blank conversations show it above the composer instead).
      if !harness.isNewConversation { WorkspaceChips(compact: true) }
      Button(action: { harness.showDetails.toggle() }) { Image(systemName: "sidebar.right") }.buttonStyle(.dshGhost)
    }.padding(.horizontal, DSHSpace.s5).padding(.vertical, DSHSpace.s3)
  }
}

/// Distance from the transcript's content bottom to the viewport bottom —
/// see ConversationView.pinnedToBottom.
private struct ConversationBottomDistanceKey: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct ConversationView: View {
  @EnvironmentObject var harness: HarnessController
  /// Follow-mode: auto-scroll tracks streaming output only while the user
  /// is already parked near the bottom. Scrolling up breaks the pin (so
  /// reading history during a running turn isn't yanked back down);
  /// returning to the bottom re-engages it.
  @State private var pinnedToBottom = true
  @State private var bottomDistance: CGFloat = 0
  @State private var scrollMonitor: Any?
  var body: some View {
    GeometryReader { viewport in
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: DSHSpace.s4) {
          if harness.historyHasMore && harness.subagentTranscript == nil {
            Button("载入更早消息", action: harness.loadOlderHistory).buttonStyle(.dshSecondary).frame(maxWidth: .infinity)
          }
          let messages = harness.displayedSession?.messages ?? []
          if messages.isEmpty {
            ConversationEmptyState()
          } else {
            ForEach(Self.foldTranscript(messages)) { item in
              switch item {
              case .message(let message):
                VStack(alignment: .leading, spacing: DSHSpace.s2) {
                  if let reasoning = message.reasoning {
                    // "live" = this thought is still streaming: last row of a
                    // running turn with no answer text yet.
                    ReasoningBlock(text: reasoning, live: harness.isRunning && message.id == messages.last?.id && message.text.isEmpty)
                  }
                  MessageBubble(message: message)
                }.id(message.id)
              case .toolGroup(let group):
                ToolGroupRow(messages: group).id(group[0].id)
              }
            }
            // The transcript tail row: the rolling-wave miniature animates
            // for the whole running turn (it also fills the send→first-token
            // gap), then freezes into the static icon once the turn settles.
            // One row view with a parameter — NOT an if/else of two view
            // types sharing this id: inside a LazyVStack that shape reuses
            // the cached static row on branch swap, so the TimelineView
            // never mounts and the icon sits frozen through the whole run
            // (reproduced in isolation; see the transcript-tail Agent Note).
            TranscriptTailIcon(running: harness.isRunning).id("transcript-tail")
          }
        }.frame(maxWidth: .infinity).padding(DSHSpace.s6)
          // Thin overlay scroller (appears while scrolling, no gutter) —
          // AppKit-level because "始终显示滚动条" otherwise forces the
          // thick legacy bar.
          .dshThinScrollers()
          // Content-bottom-to-viewport-bottom distance, measured on every
          // layout pass: ~0 when parked at the bottom, grows as the user
          // scrolls up. Drives the follow-mode pin.
          .background(GeometryReader { content in
            Color.clear.preference(
              key: ConversationBottomDistanceKey.self,
              value: content.frame(in: .named("dshConversationScroll")).maxY - viewport.size.height)
          })
      }
      .coordinateSpace(name: "dshConversationScroll")
      // Distance is bookkeeping only — it must never re-engage the pin by
      // itself. The old `pinned = distance < 80` lost a race during
      // streaming: every auto-scroll zeroed the distance and re-pinned
      // before the user's upward scroll could cross the threshold, so the
      // view kept snapping down. Unpin/repin now follow the user's actual
      // wheel gestures (below), which fire synchronously.
      .onPreferenceChange(ConversationBottomDistanceKey.self) { distance in
        bottomDistance = distance
      }
      .onChange(of: harness.displayedSession?.messages) { _, messages in
        guard let last = messages?.last else { return }
        // Follow only while pinned — except the user's own send, which
        // always snaps down so the new turn starts in view. Anchor is the
        // tail row (running animation / end marker), not the last message —
        // it is the transcript's true bottom.
        if last.role == .user { pinnedToBottom = true }
        if pinnedToBottom { proxy.scrollTo("transcript-tail", anchor: .bottom) }
      }
      // Switching sessions (or opening a subagent transcript) resets the
      // pin — a freshly opened transcript always lands at its bottom.
      .onChange(of: harness.displayedSession?.id) { _, _ in
        pinnedToBottom = true
        if harness.displayedSession?.messages.isEmpty == false { proxy.scrollTo("transcript-tail", anchor: .bottom) }
      }
      // The run settling (or starting without a new message, e.g. a queued
      // drain) swaps the tail row in place — keep it in view while pinned.
      .onChange(of: harness.isRunning) { _, _ in
        if pinnedToBottom, harness.displayedSession?.messages.isEmpty == false {
          proxy.scrollTo("transcript-tail", anchor: .bottom)
        }
      }
      .onAppear {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
          if event.scrollingDeltaY > 0 {
            // Scrolling up = reading history: break the pin immediately.
            pinnedToBottom = false
          } else if event.scrollingDeltaY < 0, bottomDistance < 120 {
            // Scrolling down and (nearly) at the bottom: re-engage.
            pinnedToBottom = true
          }
          return event
        }
      }
      .onDisappear {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
      }
      // One-tap return to the latest content, icon only — shown whenever
      // follow mode is off.
      .overlay(alignment: .bottomTrailing) {
        if !pinnedToBottom {
          Button {
            pinnedToBottom = true
            if harness.displayedSession?.messages.isEmpty == false {
              withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("transcript-tail", anchor: .bottom) }
            }
          } label: {
            Image(systemName: "arrow.down")
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(DSHTheme.ink)
              .frame(width: 34, height: 34)
              .background(DSHTheme.surface, in: Circle())
              .overlay(Circle().strokeBorder(DSHTheme.fieldStroke.opacity(0.5), lineWidth: 1))
              .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
          }
          .buttonStyle(.plain)
          .padding(.trailing, DSHSpace.s5).padding(.bottom, DSHSpace.s4)
          .help("回到最新")
        }
      }
    }
    }
  }

  /// A transcript row after folding: plain message, or a run of consecutive
  /// same-tool calls merged into one group ("run_code ×3") so repeated steps
  /// read as one status instead of a ladder of identical rows.
  fileprivate enum TranscriptItem: Identifiable {
    case message(HarnessController.Message)
    case toolGroup([HarnessController.Message])
    var id: UUID {
      switch self {
      case .message(let message): message.id
      case .toolGroup(let group): group[0].id
      }
    }
  }

  private static func foldTranscript(_ messages: [HarnessController.Message]) -> [TranscriptItem] {
    var items: [TranscriptItem] = []
    for message in messages {
      if message.role == .tool, case .toolGroup(var group) = items.last, group[0].text == message.text {
        group.append(message)
        items[items.count - 1] = .toolGroup(group)
        continue
      }
      if message.role == .tool, case .message(let previous) = items.last, previous.role == .tool, previous.text == message.text {
        items[items.count - 1] = .toolGroup([previous, message])
        continue
      }
      items.append(.message(message))
    }
    return items
  }
}

/// Merged view of consecutive same-tool calls: one header with a count and a
/// live (pulsing) dot while any member is still running; expanding lists the
/// individual calls with their own inline detail.
private struct ToolGroupRow: View {
  @EnvironmentObject var harness: HarnessController
  let messages: [HarnessController.Message]
  @State private var expanded = false
  private var activities: [HarnessController.ToolActivity] {
    messages.compactMap { message in
      guard let id = message.toolCallId else { return nil }
      return harness.activeTools.last { $0.callId == id }
    }
  }
  private var anyRunning: Bool { activities.contains { $0.state == .running } }
  private var anyFailed: Bool { activities.contains { $0.state == .failed } }
  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Button(action: { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }) {
        HStack(spacing: 7) {
          ToolStateDot(color: anyRunning ? DSHTheme.warm : anyFailed ? Color.red.opacity(0.75) : DSHTheme.accent, pulsing: anyRunning)
          Text("\(messages[0].text) ×\(messages.count)")
            .font(.system(size: 12.5, design: .monospaced)).foregroundStyle(DSHTheme.ink)
          Text(anyRunning ? "运行中…" : anyFailed ? "有失败" : "完成")
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(anyRunning ? DSHTheme.warm : anyFailed ? DSHTheme.coral : DSHTheme.inkFaint)
          Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
            .foregroundStyle(DSHTheme.inkFaint).rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if expanded {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(messages) { message in ToolCallRow(message: message) }
        }
        .padding(.leading, 13)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// One rolling wave band of the waiting indicator — top edge is a cosine
/// curve whose phase the caller advances per frame.
struct WaveBand: Shape {
  let baseY: CGFloat
  let amplitude: CGFloat
  let phase: CGFloat
  func path(in rect: CGRect) -> Path {
    var path = Path()
    let steps = 24
    path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
    for i in 0...steps {
      let fraction = CGFloat(i) / CGFloat(steps)
      let x = rect.minX + fraction * rect.width
      let y = rect.minY + baseY * rect.height + amplitude * rect.height * cos(phase + fraction * .pi * 2.5)
      path.addLine(to: CGPoint(x: x, y: y))
    }
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    path.closeSubpath()
    return path
  }
}

/// One frame of the miniature app icon (deep-sea gradient, moon, layered
/// waves) at time `t` — the shared artwork behind the animated running
/// indicator and the static end-of-turn marker. Colors are the icon
/// generator's constants — keep the two in sync when the icon changes.
/// Drawn at its native 26 pt then scaled to `size`, so the wave/moon
/// constants never need retuning when the display size changes.
private struct WaveIconArt: View {
  let t: Double
  var size: CGFloat = 18
  var body: some View {
    artwork
      .scaleEffect(size / 26)
      .frame(width: size, height: size)
  }
  private var artwork: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 6.5, style: .continuous)
        .fill(LinearGradient(
          colors: [Color(red: 0.031, green: 0.106, blue: 0.125), Color(red: 0.043, green: 0.216, blue: 0.235), Color(red: 0.039, green: 0.424, blue: 0.404)],
          startPoint: .top, endPoint: .bottom))
      // 月亮的升落弧线：一个周期内前 82% 走完左下→顶点→右下的半弧，
      // 其余时间停在海平面之下，读起来就是"月落片刻，再从左边升起"。
      // 波浪是半透明的遮不住它，所以用海平面遮罩硬裁：月亮只在浪线
      // 以上可见，升落时被地平线渐渐"吃掉"。
      let cycle = (t / 5.0).truncatingRemainder(dividingBy: 1)
      let arc = min(cycle / 0.82, 1.0)
      let theta = (Double.pi + 0.65) - arc * (Double.pi + 1.3)
      Circle().fill(Color(red: 0.867, green: 0.980, blue: 0.960))
        .frame(width: 4.5, height: 4.5)
        .offset(x: 9.0 * cos(theta), y: -7.5 * sin(theta) + 1.5)
        .frame(width: 26, height: 26)
        .mask(alignment: .top) { Rectangle().frame(height: 16) }
      WaveBand(baseY: 0.56, amplitude: 0.07, phase: t * 1.7).fill(Color(red: 0.290, green: 0.871, blue: 0.824).opacity(0.30))
      WaveBand(baseY: 0.66, amplitude: 0.065, phase: t * 2.3 + 2.1).fill(Color(red: 0.376, green: 0.925, blue: 0.871).opacity(0.55))
      WaveBand(baseY: 0.75, amplitude: 0.055, phase: t * 2.9 + 4.4).fill(Color(red: 0.173, green: 0.773, blue: 0.722).opacity(0.95))
    }
    .frame(width: 26, height: 26)
    .clipShape(RoundedRectangle(cornerRadius: 6.5, style: .continuous))
  }
}

/// Running style for the whole turn — from send to settlement: the waves
/// actually roll and the moon transits. It doubles as the "waiting" filler
/// between send and the first streamed token (the send path seeds no
/// placeholder bubble; see the composer-consolidation note).
private struct WaitingWaveIndicator: View {
  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
      WaveIconArt(t: context.date.timeIntervalSinceReferenceDate)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// The transcript tail in one row view: animated while the turn runs,
/// frozen once it settles. Deliberately a single view type whose parameter
/// flips — two sibling view types alternating under one explicit id makes
/// LazyVStack reuse the cached row and the animation never mounts.
private struct TranscriptTailIcon: View {
  let running: Bool
  var body: some View {
    if running { WaitingWaveIndicator() } else { TranscriptEndMarker() }
  }
}

/// End-of-turn marker: the same icon frozen with the moon at its apex —
/// the settled counterpart of the running animation, marking where the
/// transcript ends. t = 2.05 puts the arc at θ ≈ π/2 (moon on top).
private struct TranscriptEndMarker: View {
  var body: some View {
    WaveIconArt(t: 2.05)
      .opacity(0.75)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct ConversationEmptyState: View {
  var body: some View {
    VStack(spacing: DSHSpace.s2) {
      Image(systemName: "bubble.left").font(.system(size: 26)).foregroundStyle(DSHTheme.inkFaint)
      Text("还没有消息").font(.callout).foregroundStyle(DSHTheme.inkFaint)
      Text("在下方输入内容开始对话").font(.caption).foregroundStyle(DSHTheme.inkFaint)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, DSHSpace.s7)
  }
}

/// A model's reasoning/thinking trace, Claude Code / Codex-style: while the
/// thought is still streaming (`live`) the row shows the latest line rolling
/// by in dim italic; once done it collapses to a bare "✻ 思考过程" one-liner
/// with no preview — completed thinking is chrome, not content. Click to
/// expand the full trace either way.
private struct ReasoningBlock: View {
  let text: String
  var live: Bool = false
  @State private var expanded = false
  private var latestLine: String {
    text.split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init) ?? ""
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Button(action: { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }) {
        HStack(spacing: 6) {
          Text("✻").font(.system(size: 11))
          Text(live ? "思考中" : "思考过程").font(.system(size: 12)).italic()
          if live, !expanded, !latestLine.isEmpty {
            Text(latestLine).font(.system(size: 12)).italic().lineLimit(1).opacity(0.7)
          }
          Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .foregroundStyle(DSHTheme.inkFaint)
        .contentShape(Rectangle())
      }.buttonStyle(.plain)
      if expanded {
        Text(text)
          .font(.system(size: 12)).italic().foregroundStyle(DSHTheme.inkFaint)
          .textSelection(.enabled)
          .frame(maxWidth: 760, alignment: .leading)
          .padding(.leading, 17)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// Claude Code-style rows, no role captions: role is carried entirely by
// layout — user input is a right-aligned tinted bubble, assistant output is
// plain text on the canvas, system notes are dim small print. Labels like
// "你 / DSH / 系统" restated the same information on every row and made the
// transcript read like a chat log instead of a working session.
private struct MessageBubble: View {
  @EnvironmentObject var harness: HarnessController
  let message: HarnessController.Message
  @State private var hovering = false
  var body: some View {
    switch message.role {
    case .user:
      HStack {
        Spacer(minLength: 180)
        VStack(alignment: .trailing, spacing: 5) {
          // 跨会话信使投递的消息在正文里自带 "[跨会话消息 · 来自会话「X」]"
          // 信封——这里只加一枚小标签复述来源，键的是结构化的 isRelayMessage
          // 字段（source.plugin == "session-relay"），不裁剪信封本身：正文
          // 原样全文展示。
          if message.isRelayMessage {
            Label("来自其他会话", systemImage: "arrow.triangle.branch")
              .font(.system(size: 10.5, weight: .medium))
              .foregroundStyle(DSHTheme.accent)
          }
          VStack(alignment: .leading, spacing: 7) {
            Text(message.text)
              .textSelection(.enabled).font(.system(.body, design: .rounded)).foregroundStyle(DSHTheme.ink)
            if let attachment = message.attachment { AttachmentPreview(ref: attachment) }
          }
          .padding(.horizontal, DSHSpace.s4).padding(.vertical, DSHSpace.s3)
          .dshCard(tint: DSHTheme.surfaceTint2, radius: DSHRadius.lg)
        }
        // The card hugs its content and sits on the right edge; 640 is only
        // the wrap ceiling. A maxWidth frame directly on the Text is greedy —
        // it stretched every bubble to full width, so a short message wore a
        // long empty gray bar.
        .frame(maxWidth: 640, alignment: .trailing)
      }
    case .assistant:
      VStack(alignment: .leading, spacing: 7) {
        if message.text.isEmpty {
          // Empty text + reasoning = the ✻ thinking row above already says
          // what's happening; a second "正在思考…" line doubles the signal.
          if message.reasoning == nil {
            Text("正在思考…").font(.system(.body, design: .rounded)).foregroundStyle(DSHTheme.inkFaint)
          }
        } else {
          MarkdownText(text: message.text).frame(maxWidth: 760, alignment: .leading)
        }
        if let attachment = message.attachment { AttachmentPreview(ref: attachment) }
        // Hover-revealed, Claude Code-style: an always-on 👍👎 under every
        // intermediate narration line reads as clutter across a long turn.
        if let messageId = message.hostMessageId {
          // A rating already given stays visible; unrated bars appear on hover.
          FeedbackBar(messageId: messageId).opacity(hovering || harness.messageFeedback[messageId]?.rating != nil ? 1 : 0)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .onHover { hovering = $0 }
    case .system:
      HStack(spacing: 7) {
        Image(systemName: "info.circle").font(.system(size: 11))
        Text(message.text).textSelection(.enabled).font(.system(size: 12, design: .rounded))
      }
      .foregroundStyle(DSHTheme.inkFaint)
      .frame(maxWidth: .infinity, alignment: .leading)
    case .tool:
      ToolCallRow(message: message)
    }
  }
}

/// Claude Code-style inline tool row: a state dot plus `Name(argument)` in
/// monospace, a dim `⎿ result` summary, and click-to-expand inline detail —
/// terminal output as a folded code block, file edits as real ± diff lines
/// (diff cards start expanded, CC-style: the change IS the content there).
private struct ToolCallRow: View {
  @EnvironmentObject var harness: HarnessController
  let message: HarnessController.Message
  /// nil until the user toggles; the default is open only for diff cards.
  @State private var userToggled: Bool?
  private var activity: HarnessController.ToolActivity? {
    guard let id = message.toolCallId else { return nil }
    return harness.activeTools.last { $0.callId == id }
  }
  private var isDiffCard: Bool { activity?.presentation?.card == "diff" }
  private var expanded: Bool { userToggled ?? isDiffCard }
  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Button(action: { userToggled = !expanded }) {
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 7) {
            ToolStateDot(color: dotColor, pulsing: activity?.state == .running)
            Text(headline).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(DSHTheme.ink).lineLimit(1)
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
              .foregroundStyle(DSHTheme.inkFaint).rotationEffect(.degrees(expanded ? 90 : 0))
          }
          if !expanded, let detail {
            HStack(alignment: .top, spacing: 6) {
              Text("⎿").font(.system(size: 11, design: .monospaced))
              Text(detail).font(.system(size: 11.5, design: .monospaced)).lineLimit(2).multilineTextAlignment(.leading)
            }
            .foregroundStyle(DSHTheme.inkFaint)
            .padding(.leading, 13)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if expanded, let activity {
        expandedBody(activity)
          .padding(.leading, 13)
          .frame(maxWidth: 760, alignment: .leading)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private func expandedBody(_ activity: HarnessController.ToolActivity) -> some View {
    if let presentation = activity.presentation {
      switch presentation.card {
      case "diff":
        VStack(alignment: .leading, spacing: 6) {
          ForEach(presentation.diffs) { item in
            VStack(alignment: .leading, spacing: 3) {
              Text(item.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(DSHTheme.inkSoft)
              DiffLines(old: item.oldText, new: item.newText).equatable()
            }
          }
        }
      case "read":
        CollapsibleCodeBlock(content: presentation.lines.map { "\($0.number)  \($0.text)" }.joined(separator: "\n"))
      case "search":
        CollapsibleCodeBlock(content: presentation.files.flatMap { file in
          file.matches.map { "\(file.path):\($0.lineNumber)  \($0.line)" }
        }.joined(separator: "\n"))
      default:
        if !activity.output.isEmpty, activity.output != "工具已完成" {
          CollapsibleCodeBlock(content: activity.output)
        } else if activity.state == .running {
          Text("运行中…").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(DSHTheme.inkFaint)
        }
      }
      if let exitCode = presentation.exitCode, exitCode != 0 {
        Text("退出码 \(exitCode)\(presentation.signal.map { " · \($0)" } ?? "")")
          .font(.system(size: 11, design: .monospaced)).foregroundStyle(DSHTheme.coral)
      }
    } else if !activity.output.isEmpty {
      CollapsibleCodeBlock(content: activity.output)
    }
  }

  /// `Name(argument)` — the argument is the presentation's own title when the
  /// adapter supplied one (command line, file path, search query), else bare name.
  private var headline: String {
    let name = activity?.name ?? message.text
    let argument = activity?.presentation?.title ?? activity?.presentation?.path
    if let argument, !argument.isEmpty, argument != name { return "\(name)(\(argument))" }
    return name
  }
  /// Collapsed summary: first output line plus a "+N 行" tail when more
  /// follows; the running placeholder while in flight.
  private var detail: String? {
    guard let activity else { return nil }
    if activity.state == .running { return "运行中…" }
    let lines = activity.output.split(separator: "\n", omittingEmptySubsequences: true)
    if let first = lines.first.map(String.init), !first.isEmpty, first != "工具已完成" {
      return lines.count > 1 ? "\(first) … +\(lines.count - 1) 行" : first
    }
    if activity.state == .failed { return activity.summary }
    return nil
  }
  private var dotColor: Color {
    switch activity?.state {
    case .running: DSHTheme.warm
    case .failed: Color.red.opacity(0.75)
    default: DSHTheme.accent
    }
  }
}

/// The tool row's state dot; a running tool pulses (opacity breathing plus a
/// soft expanding halo) so "in progress" is visible motion, not just amber.
private struct ToolStateDot: View {
  let color: Color
  let pulsing: Bool
  @State private var pulse = false
  var body: some View {
    ZStack {
      if pulsing {
        Circle().fill(color.opacity(0.35))
          .frame(width: 13, height: 13)
          .scaleEffect(pulse ? 1.0 : 0.4)
          .opacity(pulse ? 0 : 0.9)
      }
      Circle().fill(color)
        .frame(width: 7, height: 7)
        .opacity(pulsing && pulse ? 0.55 : 1)
    }
    .frame(width: 13, height: 13)
    .animation(pulsing ? .easeInOut(duration: 0.9).repeatForever(autoreverses: false) : .default, value: pulse)
    .onAppear { if pulsing { pulse = true } }
    .onChange(of: pulsing) { _, active in pulse = active }
  }
}

/// Per-message rating strip backed by the Typert messageFeedback service.
private struct FeedbackBar: View {
  @EnvironmentObject var harness: HarnessController
  let messageId: String
  var body: some View {
    let current = harness.messageFeedback[messageId]?.rating
    HStack(spacing: 6) {
      Button(action: { harness.setFeedback(messageId: messageId, rating: current == "positive" ? nil : "positive") }) {
        Image(systemName: current == "positive" ? "hand.thumbsup.fill" : "hand.thumbsup")
      }.help("有帮助")
      Button(action: { harness.setFeedback(messageId: messageId, rating: current == "negative" ? nil : "negative") }) {
        Image(systemName: current == "negative" ? "hand.thumbsdown.fill" : "hand.thumbsdown")
      }.help("没帮助")
    }
    .buttonStyle(.dshGhost).font(.caption)
    .foregroundStyle(current == nil ? DSHTheme.inkFaint : DSHTheme.accent)
  }
}
