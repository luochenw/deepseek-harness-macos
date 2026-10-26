import SwiftUI

private struct HeaderChip<Content: View>: View {
  let icon: String
  let label: String
  @ViewBuilder let content: () -> Content
  var body: some View {
    Menu { content() } label: {
      HStack(spacing: 6) {
        Image(systemName: icon).font(DSHType.caption)
        Text(label).font(DSHType.caption)
      }
        .padding(.horizontal, DSHSpace.s3).padding(.vertical, 6)
        .background(
          DSHTheme.surface,
          in: RoundedRectangle(cornerRadius: DSHRadius.sm, style: .continuous))
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
    VStack(alignment: .leading, spacing: DSHSpace.s2) {
      HStack(spacing: DSHSpace.s2) {
        VStack(alignment: .leading, spacing: 2) {
          if !harness.subagentPath.isEmpty {
            HStack(spacing: 6) {
              Button(action: harness.navigateUpSubagent) { Image(systemName: "chevron.left") }.buttonStyle(.dshGhost).help("返回上一级")
              Text(harness.subagentPath.map(\.title).joined(separator: " › ")).font(.caption).foregroundStyle(DSHTheme.inkFaint).lineLimit(1)
            }
          }
          Text(harness.displayedSession?.title ?? "新会话")
            .font(DSHType.pageTitle)
            .foregroundStyle(DSHTheme.ink)
          Text(harness.conversationWorkspacePathLabel)
            .font(.caption)
            .foregroundStyle(DSHTheme.inkFaint)
            .lineLimit(1)
            .help(harness.hostCurrentSessionID == nil
              ? "新会话将在此目录中运行"
              : "当前 Host 会话的固定工作目录")
        }
        Spacer()
        if presetLocked {
          HStack(spacing: 6) {
            Image(systemName: "lock.fill").font(DSHType.caption)
            Text(lockedPresetLabel).font(DSHType.caption)
          }
            .padding(.horizontal, DSHSpace.s3).padding(.vertical, 6)
            .background(
              DSHTheme.warmSoft,
              in: RoundedRectangle(cornerRadius: DSHRadius.sm, style: .continuous))
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
        Button(action: harness.toggleWorkbench) { Image(systemName: "sidebar.right") }
          .buttonStyle(.dshGhost)
          .help("显示或隐藏工作台")
          .accessibilityLabel("显示或隐藏工作台")
      }
      if !harness.displayedAttachmentRailItems.isEmpty {
        AttachmentRail(items: harness.displayedAttachmentRailItems)
      }
    }.padding(.horizontal, DSHSpace.s5).padding(.vertical, DSHSpace.s3)
  }
}

/// Distance from the transcript's content bottom to the viewport bottom —
/// see ConversationView.pinnedToBottom.
private struct ConversationBottomDistanceKey: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

enum DSHConversationLayout {
  static let contentMaxWidth: CGFloat = 1040
  static let horizontalInset = DSHSpace.s6
}

enum DSHReasoningLayout {
  static let maximumExpandedHeight: CGFloat = 240
  static let initialExpandedHeight: CGFloat = 44

  static func expandedHeight(measured: CGFloat?) -> CGFloat {
    guard let measured else { return initialExpandedHeight }
    return min(maximumExpandedHeight, max(1, measured))
  }
}

enum DSHToolDetailsLayout {
  static let maximumExpandedHeight: CGFloat = 320
  static let initialExpandedHeight: CGFloat = 56

  static func expandedHeight(measured: CGFloat?) -> CGFloat {
    guard let measured else { return initialExpandedHeight }
    return min(maximumExpandedHeight, max(1, measured))
  }
}

private struct AdaptiveToolDetails<Content: View>: View {
  private let content: Content
  @State private var contentHeight: CGFloat?

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    ScrollView {
      content
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DSHSpace.s3)
        .padding(.vertical, DSHSpace.s2)
        .onGeometryChange(for: CGFloat.self) { geometry in
          geometry.size.height
        } action: { height in
          contentHeight = height
        }
    }
    .dshThinScrollers()
    .frame(height: DSHToolDetailsLayout.expandedHeight(measured: contentHeight))
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      DSHTheme.surfaceTint,
      in: RoundedRectangle(cornerRadius: DSHRadius.md, style: .continuous))
    .clipShape(RoundedRectangle(cornerRadius: DSHRadius.md, style: .continuous))
    .overlay(alignment: .leading) {
      RoundedRectangle(cornerRadius: 1, style: .continuous)
        .fill(DSHTheme.accentSoft)
        .frame(width: 2)
        .padding(.vertical, DSHSpace.s2)
    }
  }
}

private struct ToolStatusHeader: View {
  let title: String?
  let running: Bool
  let failed: Bool
  let expanded: Bool
  let onToggle: () -> Void
  var onOpenDetails: (() -> Void)?
  @State private var hovering = false

  private var accessibilityState: String {
    if running { return "运行中" }
    if failed { return "失败" }
    return "已完成"
  }

  var body: some View {
    HStack(spacing: DSHSpace.s2) {
      Button {
        withAnimation(.easeInOut(duration: 0.15)) {
          onToggle()
        }
      } label: {
        ToolStatusLabel(
          title: title,
          running: running,
          failed: failed,
          expanded: expanded,
          hovering: hovering)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, DSHSpace.s2 + 1)
          .padding(.vertical, 5)
          .background(
            hovering || expanded ? DSHTheme.surfaceTint2 : DSHTheme.surfaceTint,
            in: RoundedRectangle(cornerRadius: DSHRadius.sm, style: .continuous))
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .onHover { hovering = $0 }
      .accessibilityLabel(
        "\(title ?? "指令")，\(accessibilityState)，\(expanded ? "收起详情" : "展开详情")")
      Spacer(minLength: 0)
      if let onOpenDetails {
        Button(action: onOpenDetails) {
          Image(systemName: "sidebar.right")
        }
        .buttonStyle(.dshGhost)
        .help("在工作台查看工具详情")
      }
    }
  }
}

private struct ToolStatusLabel: View {
  let title: String?
  let running: Bool
  let failed: Bool
  let expanded: Bool
  let hovering: Bool

  private var iconColor: Color {
    if running { return DSHTheme.warm }
    if failed { return DSHTheme.coral }
    return DSHTheme.inkFaint
  }

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "terminal")
        .font(DSHType.caption)
        .foregroundStyle(iconColor)
      if let title {
        Text(title)
          .font(DSHType.mono)
          .foregroundStyle(DSHTheme.inkSoft)
          .lineLimit(1)
          .truncationMode(.middle)
          .contentTransition(.opacity)
          .animation(.easeInOut(duration: 0.16), value: title)
      }
      Spacer(minLength: DSHSpace.s2)
      if running || failed {
        ToolStateAccessory(running: running, failed: failed)
          .transition(.opacity)
      }
      Image(systemName: "chevron.right")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(DSHTheme.inkFaint)
        .rotationEffect(.degrees(expanded ? 90 : 0))
    }
    .foregroundStyle(hovering || expanded ? DSHTheme.inkSoft : DSHTheme.inkFaint)
    .animation(.easeOut(duration: 0.18), value: running)
    .animation(.easeOut(duration: 0.18), value: failed)
  }
}

private struct ToolStateAccessory: View {
  let running: Bool
  let failed: Bool

  var body: some View {
    if running {
      HStack(spacing: 5) {
        DSHRunningBars(color: DSHTheme.warm, height: 9)
        Text("运行中")
          .font(DSHType.micro)
          .foregroundStyle(DSHTheme.warm)
      }
      .fixedSize()
    } else if failed {
      HStack(spacing: 4) {
        Image(systemName: "xmark.circle.fill")
          .font(DSHType.micro)
        Text("有失败")
          .font(DSHType.micro)
      }
      .foregroundStyle(DSHTheme.coral)
      .fixedSize()
    }
  }
}

private struct ToolInstructionRow: View {
  @EnvironmentObject var harness: HarnessController
  let instruction: DSHToolInstruction
  let initiallyExpanded: Bool?
  @State private var userToggled: Bool?
  private var expanded: Bool { userToggled ?? initiallyExpanded ?? false }
  private var activity: HarnessController.ToolActivity? {
    guard case .activity(let activity) = instruction.source else { return nil }
    return activity
  }

  init(
    instruction: DSHToolInstruction,
    initiallyExpanded: Bool? = nil
  ) {
    self.instruction = instruction
    self.initiallyExpanded = initiallyExpanded
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      ToolStatusHeader(
        title: instruction.title,
        running: instruction.state == .running,
        failed: instruction.state == .failed,
        expanded: expanded,
        onToggle: { userToggled = !expanded },
        onOpenDetails: activity.map { selected in
          { harness.toolDetail(selected) }
        })
      if expanded {
        AdaptiveToolDetails {
          ToolInstructionDetails(instruction: instruction)
        }
        .padding(.leading, DSHSpace.s4)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct ToolInstructionDetails: View {
  @EnvironmentObject private var harness: HarnessController
  let instruction: DSHToolInstruction

  @ViewBuilder var body: some View {
    switch instruction.source {
    case .activity(let activity):
      ToolPresentationContent(tool: activity, compact: true)
        .frame(maxWidth: 760, alignment: .leading)
        .contentTransition(.opacity)
        .animation(.easeOut(duration: 0.18), value: activity.output)
    case .child(let child):
      VStack(alignment: .leading, spacing: DSHSpace.s2) {
        if child.imageAttachments.isEmpty {
          if hasArguments(child.arguments) {
            Text("参数")
              .font(DSHType.micro)
              .foregroundStyle(DSHTheme.inkFaint)
            ToolOutputBlock(text: child.arguments)
          }
          if !child.output.isEmpty {
            Text("输出")
              .font(DSHType.micro)
              .foregroundStyle(DSHTheme.inkFaint)
            ToolOutputBlock(text: child.output)
          }
        } else {
          ForEach(child.imageAttachments, id: \.attachmentId) { attachment in
            AttachmentPreview(
              ref: attachment,
              sessionID: harness.displayedAttachmentSessionID)
          }
        }
        if instruction.state == .running,
           child.output.isEmpty,
           child.imageAttachments.isEmpty {
          HStack(spacing: 5) {
            DSHRunningBars(color: DSHTheme.warm, height: 9)
            Text("等待结果…")
              .font(DSHType.micro)
              .foregroundStyle(DSHTheme.inkFaint)
          }
          .transition(.opacity)
        }
      }
      .frame(maxWidth: 760, alignment: .leading)
      .animation(.easeOut(duration: 0.18), value: child.output)
      .animation(.easeOut(duration: 0.18), value: child.imageAttachments)
    }
  }

  private func hasArguments(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && trimmed != "{}" && trimmed != "[]"
  }
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
  @State private var pointerInsideTranscript = false
  var body: some View {
    GeometryReader { viewport in
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: DSHSpace.s4) {
          let messages = harness.displayedSession?.messages ?? []
          let liveActivity = DSHConversationLiveActivity.text(
            messages: messages,
            tools: harness.displayedTools,
            running: harness.displayedIsRunning)
          let loadingPresentation = DSHConversationHistoryLoadingPresentation.resolve(
            isLoading: harness.displayedIsLoadingHistory,
            hasMessages: !messages.isEmpty)
          if loadingPresentation == .placeholder {
            ConversationLoadingView()
              .id("conversation-history-loading")
          } else if messages.isEmpty {
            ConversationEmptyState()
          } else {
            if loadingPresentation == .inline {
              ConversationLoadingView(compact: true)
                .id("conversation-history-loading-compact")
            }
            ForEach(Self.foldTranscript(
              messages,
              activeTurnRunning: harness.displayedIsRunning)) { item in
              switch item {
              case .reasoning(let trace):
                // "live" = this turn's collapsed status row follows the latest
                // thought/body/tool action until the turn settles.
                ReasoningBlock(
                  text: trace.text,
                  segments: trace.segments,
                  live: trace.live,
                  liveStatus: liveActivity)
                  .id(item.id)
              case .message(let message):
                MessageBubble(message: message).id(item.id)
              case .toolGroup(let group):
                ToolGroupRow(messages: group).id(item.id)
              }
            }
            ForEach(harness.displayedSteeringItems) { item in
              PendingSteeringBubble(item: item).id("steering-\(item.id)")
            }
            // The transcript tail row: the rolling-wave miniature animates
            // for the whole running turn (it also fills the send→first-token
            // gap), then freezes into the static icon once the turn settles.
            // One row view with a parameter — NOT an if/else of two view
            // types sharing this id: inside a LazyVStack that shape reuses
            // the cached static row on branch swap, so the TimelineView
            // never mounts and the icon sits frozen through the whole run
            // (reproduced in isolation; see the transcript-tail Agent Note).
            TranscriptTailIcon(running: harness.displayedIsRunning).id("transcript-tail")
          }
        }
          // The transcript column carries a readable measure and is centered,
          // so a wide window puts the slack on both sides instead of leaving
          // every answer hugging the left edge with a dead right half.
          .frame(maxWidth: DSHConversationLayout.contentMaxWidth, alignment: .leading)
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(.horizontal, DSHConversationLayout.horizontalInset)
          .padding(.vertical, DSHSpace.s6)
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
      .onHover { pointerInsideTranscript = $0 }
      // Distance is bookkeeping only — it must never re-engage the pin by
      // itself. The old `pinned = distance < 80` lost a race during
      // streaming: every auto-scroll zeroed the distance and re-pinned
      // before the user's upward scroll could cross the threshold, so the
      // view kept snapping down. Unpin/repin now follow the user's actual
      // wheel gestures (below), which fire synchronously.
      .onPreferenceChange(ConversationBottomDistanceKey.self) { distance in
        bottomDistance = distance
      }
      .onChange(of: harness.displayedConversationMessageToken) { oldToken, token in
        guard let last = harness.displayedSession?.messages.last else { return }
        // Follow only while pinned — except the user's own send, which
        // always snaps down so the new turn starts in view. Anchor is the
        // tail row (running animation / end marker), not the last message —
        // it is the transcript's true bottom.
        if last.role == .user, oldToken.lastID != token.lastID {
          pinnedToBottom = true
        }
        if pinnedToBottom {
          DispatchQueue.main.async {
            proxy.scrollTo("transcript-tail", anchor: .bottom)
          }
        }
      }
      // Switching sessions (or opening a subagent transcript) resets the
      // pin — a freshly opened transcript always lands at its bottom.
      .onChange(of: harness.displayedConversationContextKey) { _, contextKey in
        pinnedToBottom = true
        DispatchQueue.main.async {
          guard harness.displayedConversationContextKey == contextKey else { return }
          if harness.displayedSession?.messages.isEmpty == false {
            proxy.scrollTo("transcript-tail", anchor: .bottom)
          }
        }
      }
      // The run settling (or starting without a new message, e.g. a queued
      // drain) swaps the tail row in place — keep it in view while pinned.
      .onChange(of: harness.displayedIsRunning) { _, _ in
        if pinnedToBottom, harness.displayedSession?.messages.isEmpty == false {
          DispatchQueue.main.async {
            proxy.scrollTo("transcript-tail", anchor: .bottom)
          }
        }
      }
      .onChange(of: harness.displayedSteeringItems.map(\.id)) { _, _ in
        if pinnedToBottom {
          DispatchQueue.main.async {
            proxy.scrollTo("transcript-tail", anchor: .bottom)
          }
        }
      }
      .onAppear {
        DispatchQueue.main.async {
          if harness.displayedSession?.messages.isEmpty == false {
            proxy.scrollTo("transcript-tail", anchor: .bottom)
          }
        }
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
          guard pointerInsideTranscript else { return event }
          if event.scrollingDeltaY > 0 {
            // Scrolling up = reading history: break the pin immediately.
            pinnedToBottom = false
          } else if event.scrollingDeltaY < 0,
                    bottomDistance < 120 {
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
      // One-tap return to the latest content, icon only — a circle floating
      // centered just above the composer, shown whenever follow mode is off
      // (the user scrolled up to read history).
      .overlay(alignment: .bottom) {
        if !pinnedToBottom {
          Button {
            pinnedToBottom = true
            if harness.displayedSession?.messages.isEmpty == false {
              DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.2)) {
                  proxy.scrollTo("transcript-tail", anchor: .bottom)
                }
              }
            }
          } label: {
            Image(systemName: "arrow.down.to.line")
              .font(DSHType.label.weight(.semibold))
              .foregroundStyle(DSHTheme.ink)
              .frame(width: 34, height: 34)
              .background(DSHTheme.surface, in: Circle())
              .overlay(Circle().strokeBorder(DSHTheme.fieldStroke.opacity(0.5), lineWidth: 1))
              .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
          }
          .buttonStyle(.plain)
          .padding(.bottom, DSHSpace.s4)
          .help("回到最新")
        }
      }
    }
    }
  }

  /// One assistant turn's step traces, aggregated into a single ✻ row.
  struct ReasoningTrace: Identifiable {
    let id: UUID
    var text: String
    var segments: Int
    var live: Bool
    let turnOrdinal: Int
  }

  /// A transcript row after folding: plain message, an aggregated trace, or a
  /// run of consecutive same-tool calls merged into one execution status so
  /// repeated steps do not read as a ladder of identical rows.
  enum TranscriptItem: Identifiable {
    case reasoning(ReasoningTrace)
    case message(HarnessController.Message)
    case toolGroup([HarnessController.Message])
    /// Type-prefixed identity: a turn's trace row and the answer row carrying
    /// the same message id must stay distinct rows, and a duplicate ForEach
    /// identity silently drops one of them.
    var id: String {
      switch self {
      case .reasoning(let trace): "reasoning-\(trace.id.uuidString)"
      case .message(let message): "message-\(message.id.uuidString)"
      case .toolGroup(let group): "tool-\(group[0].id.uuidString)"
      }
    }
  }

  /// Fold the transcript for rendering: same-name tool rows collapse into one
  /// group, and every step trace of a turn folds into ONE ✻ row.
  ///
  /// A turn emits a reasoning block per step, so the raw transcript carries a
  /// dozen traces per answer. Rendering one row each stacked an identical
  /// "思考过程" one-liner around every tool call — the same thought looked like
  /// it was being shown over and over. Each turn now owns exactly one trace row,
  /// anchored where that turn's first trace landed and extended in place as
  /// later steps add theirs ("N 段" says how many), so the row never moves and
  /// expanding it still exposes every step. Steps whose only content is a trace
  /// or a tool call contribute no body row of their own.
  static func foldTranscript(
    _ messages: [HarnessController.Message],
    activeTurnRunning: Bool = false
  ) -> [TranscriptItem] {
    var items: [TranscriptItem] = []
    // Index into `items` of the current turn's aggregated trace row, if any.
    var turnTrace: Int?
    var turnOrdinal = 0

    for message in messages {
      if message.role == .user {
        turnOrdinal += 1
        turnTrace = nil
      }
      let reasoning = message.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let hasBody = !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || message.attachment != nil
      if message.role == .assistant, !reasoning.isEmpty {
        if let index = turnTrace, case .reasoning(var existing) = items[index] {
          existing.text += "\n\n" + reasoning
          existing.segments += 1
          existing.live = false
          items[index] = .reasoning(existing)
        } else {
          items.append(.reasoning(ReasoningTrace(
            id: message.id,
            text: reasoning,
            segments: 1,
            live: false,
            turnOrdinal: turnOrdinal)))
          turnTrace = items.count - 1
        }
        if hasBody { items.append(.message(message)) }
        continue
      }
      if message.role == .assistant, !hasBody { continue }
      // A new user/system row opens the next turn: its traces get their own row.
      if message.role == .system { turnTrace = nil }
      if message.role == .tool,
         case .toolGroup(var group) = items.last, group[0].text == message.text {
        group.append(message)
        items[items.count - 1] = .toolGroup(group)
        continue
      }
      if message.role == .tool,
         case .message(let previous) = items.last,
         previous.role == .tool, previous.text == message.text {
        items[items.count - 1] = .toolGroup([previous, message])
        continue
      }
      items.append(.message(message))
    }
    if activeTurnRunning,
       let index = items.lastIndex(where: { item in
         guard case .reasoning(let trace) = item else { return false }
         return trace.turnOrdinal == turnOrdinal
       }),
       case .reasoning(var trace) = items[index] {
      trace.live = true
      items[index] = .reasoning(trace)
    }
    return items
  }
}

private struct PendingSteeringBubble: View {
  let item: DSHQueueItem
  var body: some View {
    HStack {
      Spacer(minLength: 180)
      HStack(alignment: .top, spacing: DSHSpace.s2) {
        Image(systemName: "arrow.turn.down.right")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(DSHTheme.accent)
          .padding(.top, 3)
        Text(item.displayText)
          .textSelection(.enabled)
          .font(DSHType.body)
          .lineSpacing(4)
          .foregroundStyle(DSHTheme.ink)
      }
      .padding(.horizontal, DSHSpace.s4).padding(.vertical, DSHSpace.s3)
      .dshCard(tint: DSHTheme.accentSoft, radius: DSHRadius.lg)
      .frame(maxWidth: 640, alignment: .trailing)
    }
  }
}

/// Consecutive same-tool calls share one compact execution status. Expanding
/// it reveals instruction rows only; each instruction owns its result details.
struct ToolGroupRow: View {
  @EnvironmentObject var harness: HarnessController
  let messages: [HarnessController.Message]
  @State private var expanded: Bool

  init(
    messages: [HarnessController.Message],
    initiallyExpanded: Bool = false
  ) {
    self.messages = messages
    _expanded = State(initialValue: initiallyExpanded)
  }

  private var activities: [HarnessController.ToolActivity] {
    messages.compactMap { message in
      guard let id = message.toolCallId else { return nil }
      return harness.displayedTools.last { $0.callId == id }
    }
  }
  private var summary: DSHToolGroupStatusSummary? {
    DSHToolGroupStatus.summary(for: activities)
  }
  private var instructions: [DSHToolInstruction] {
    DSHToolInstructionFlatten.instructions(from: activities)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      ToolStatusHeader(
        title: summary?.detail,
        running: summary?.running == true,
        failed: summary?.failed == true,
        expanded: expanded,
        onToggle: { expanded.toggle() })
      if expanded, !instructions.isEmpty {
        AdaptiveToolDetails {
          VStack(alignment: .leading, spacing: DSHSpace.s2) {
            ForEach(instructions) { instruction in
              ToolInstructionRow(instruction: instruction)
            }
          }
        }
        .padding(.leading, DSHSpace.s4)
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
  /// 每层浪的空间周期数。三层**共用同一个值**：浪峰才会平行推进、间距均匀。
  /// 曾给三层配不同频率、再各叠一个二次谐波，想避免"三层长一样"——结果浪面
  /// 变成一串疙瘩（用户反馈"不够规则，不好看"）。层次靠基线高度、幅度和流速
  /// 拉开就够了，波形本身要保持干净的余弦。
  var freq: CGFloat = 1.5
  func path(in rect: CGRect) -> Path {
    var path = Path()
    let steps = 48
    path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
    for i in 0...steps {
      let fraction = CGFloat(i) / CGFloat(steps)
      let x = rect.minX + fraction * rect.width
      let y = baseY * rect.height + amplitude * rect.height * cos(phase + fraction * .pi * 2 * freq)
      path.addLine(to: CGPoint(x: x, y: rect.minY + y))
    }
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    path.closeSubpath()
    return path
  }
}

/// One frame of the miniature app icon (daylight lagoon, breaching whale) at
/// time `t` — the shared artwork behind the animated running indicator and the
/// static end-of-turn marker. Shapes and colors come from `SeaArt` /
/// `SeaWhaleScene`, the single source shared with the floating bubble and the
/// icon generator; don't inline new constants here.
/// Drawn at its native 26 pt then scaled to `size`, so nothing needs retuning
/// when the display size changes.
private struct WaveIconArt: View {
  let t: Double
  var size: CGFloat = 18
  /// Tide level: 1 while the turn runs (full sea, whale breaching), 0 once it
  /// settles (just the whale, no waves). Presence of water is what says
  /// "running" — a single frame is enough, no need to watch it move.
  var level: CGFloat = 1
  var body: some View {
    SeaWhaleScene(wavePhase: t, breachTime: t, level: level, side: 26)
      .clipShape(RoundedRectangle(cornerRadius: 6.5, style: .continuous))
      .scaleEffect(size / 26)
      .frame(width: size, height: size)
  }
}

/// Running style for the whole turn — from send to settlement: the waves
/// actually roll and the whale breaches. It doubles as the "waiting" filler
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

/// End-of-turn marker: the same icon at low tide — the waves have drained and
/// only the whale is left — marking where the transcript ends.
private struct TranscriptEndMarker: View {
  var body: some View {
    WaveIconArt(t: 2.05, level: 0)
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

/// A model's reasoning/thinking trace, Codex-style: while the turn is active,
/// this remains one collapsed status row whose preview follows the latest
/// thought, answer, or tool action. Once done it becomes a bare
/// "✻ 思考过程" row. Click to expand the full trace at any time.
private struct ReasoningBlock: View {
  let text: String
  /// How many step traces this run aggregates — one turn emits a trace per step,
  /// and the label says so instead of repeating an identical row per step.
  var segments: Int = 1
  var live: Bool = false
  var liveStatus: String?
  @State private var expanded = false
  @State private var hovering = false
  @State private var pulse = false
  @State private var expandedContentHeight: CGFloat?
  private var latestLine: String {
    var end = text.endIndex
    while end > text.startIndex, text[text.index(before: end)].isNewline {
      end = text.index(before: end)
    }
    guard end > text.startIndex,
          let newline = text[..<end].lastIndex(of: "\n") else {
      return String(text[..<end])
    }
    return String(text[text.index(after: newline)..<end])
  }
  /// Traces are free-form prose; blank lines separate steps, so render them as
  /// paragraphs instead of one undifferentiated wall of text.
  private var paragraphs: [String] {
    text.components(separatedBy: "\n\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s2) {
      Button(action: { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }) {
        HStack(spacing: 6) {
          Text("✻")
            .font(DSHType.caption)
            .opacity(live && pulse ? 0.42 : 1)
          Text(live ? "处理中" : "思考过程")
            .font(DSHType.label)
          if segments > 1 {
            Text("\(segments) 段")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(DSHTheme.inkFaint)
              .padding(.horizontal, 5).padding(.vertical, 1)
              .background(
                DSHTheme.surfaceTint2,
                in: RoundedRectangle(cornerRadius: 4, style: .continuous))
          }
          if live, !expanded, let status = liveStatus ?? nonEmpty(latestLine) {
            Text(status)
              .font(DSHType.caption).italic().lineLimit(1)
              .foregroundStyle(DSHTheme.inkFaint)
              .contentTransition(.opacity)
              .animation(.easeInOut(duration: 0.16), value: status)
          }
          Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .foregroundStyle(DSHTheme.inkFaint)
        }
        .foregroundStyle(hovering || expanded ? DSHTheme.inkSoft : DSHTheme.inkFaint)
        .padding(.horizontal, DSHSpace.s2 + 1)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: DSHRadius.sm, style: .continuous)
              .fill(hovering || expanded ? DSHTheme.surfaceTint2 : DSHTheme.surfaceTint))
        .contentShape(Rectangle())
      }.buttonStyle(.plain)
      .onHover { hovering = $0 }
      .onAppear { pulse = live }
      .onChange(of: live) { _, active in pulse = active }
      .animation(
        live ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default,
        value: pulse)
      .accessibilityLabel(expanded ? "收起思考过程" : "展开思考过程")
      if expanded {
        ScrollViewReader { proxy in
          ScrollView {
            VStack(alignment: .leading, spacing: DSHSpace.s2) {
              ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                  .font(DSHType.body)
                  .lineSpacing(6)
                  .foregroundStyle(DSHTheme.inkSoft)
                  .textSelection(.enabled)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
              Color.clear
                .frame(height: 1)
                .id("reasoning-expanded-bottom")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { geometry in
              geometry.size.height
            } action: { height in
              expandedContentHeight = height
            }
          }
          .dshThinScrollers()
          .frame(height: DSHReasoningLayout.expandedHeight(measured: expandedContentHeight))
          .onAppear {
            proxy.scrollTo("reasoning-expanded-bottom", anchor: .bottom)
          }
        }
        .padding(.vertical, DSHSpace.s2)
        .padding(.leading, DSHSpace.s4)
        .padding(.trailing, DSHSpace.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: DSHRadius.md, style: .continuous)
            .fill(DSHTheme.surfaceTint))
        .overlay(alignment: .leading) {
          RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(DSHTheme.accentSoft)
            .frame(width: 2)
            .padding(.vertical, DSHSpace.s2)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func nonEmpty(_ value: String) -> String? {
    value.isEmpty ? nil : value
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
              .textSelection(.enabled)
              .font(DSHType.bodyLarge)
              .lineSpacing(5)
              .foregroundStyle(DSHTheme.ink)
            if let attachment = message.attachment { AttachmentPreview(ref: attachment, sessionID: harness.displayedAttachmentSessionID) }
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
          if message.reasoning == nil, message.attachment == nil {
            Text("正在思考…")
              .font(DSHType.bodyLarge)
              .foregroundStyle(DSHTheme.inkFaint)
          }
        } else {
          if message.hostMessageId == DSHTranscriptMessageMarker.streamingAssistantHostMessageID {
            StreamingAssistantText(text: message.text)
          } else {
            MarkdownText(text: message.text).frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        if let attachment = message.attachment { AttachmentPreview(ref: attachment, sessionID: harness.displayedAttachmentSessionID) }
        // Hover-revealed, Claude Code-style: an always-on 👍👎 under every
        // intermediate narration line reads as clutter across a long turn.
        if let messageId = message.hostMessageId,
           messageId != DSHTranscriptMessageMarker.streamingAssistantHostMessageID {
          // A rating already given stays visible; unrated bars appear on hover.
          FeedbackBar(messageId: messageId).opacity(hovering || harness.messageFeedback[messageId]?.rating != nil ? 1 : 0)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .onHover { hovering = $0 }
    case .system:
      HStack(spacing: 7) {
        Image(systemName: "info.circle").font(.system(size: 11))
        Text(message.text)
          .textSelection(.enabled)
          .font(DSHType.body)
          .lineSpacing(3)
      }
      .foregroundStyle(DSHTheme.inkFaint)
      .frame(maxWidth: .infinity, alignment: .leading)
    case .tool:
      ToolCallRow(message: message)
    }
  }
}

/// One instruction disclosure. Its result is rendered only after the user
/// expands that instruction.
struct ToolCallRow: View {
  @EnvironmentObject var harness: HarnessController
  let message: HarnessController.Message
  let initiallyExpanded: Bool?
  private var activities: [HarnessController.ToolActivity] {
    guard let id = message.toolCallId else { return [] }
    return harness.displayedTools.last { $0.callId == id }.map { [$0] } ?? []
  }
  private var instructions: [DSHToolInstruction] {
    DSHToolInstructionFlatten.instructions(from: activities)
  }

  init(message: HarnessController.Message, initiallyExpanded: Bool? = nil) {
    self.message = message
    self.initiallyExpanded = initiallyExpanded
  }

  @ViewBuilder var body: some View {
    if instructions.count > 1 {
      ToolGroupRow(
        messages: [message],
        initiallyExpanded: initiallyExpanded ?? false)
    } else if let instruction = instructions.first {
      ToolInstructionRow(
        instruction: instruction,
        initiallyExpanded: initiallyExpanded)
    }
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
