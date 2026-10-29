import SwiftUI

@MainActor
private final class DSHConversationFoldCacheState {
  weak var controller: HarnessController?
  var token: DSHConversationMessageToken?
  var running = false
  var foldedItems: [ConversationView.TranscriptItem] = []

  init(controller: HarnessController) {
    self.controller = controller
  }

  func items(
    messages: [HarnessController.Message],
    token: DSHConversationMessageToken,
    running: Bool
  ) -> [ConversationView.TranscriptItem] {
    if self.token == token, self.running == running {
      return foldedItems
    }
    let folded = ConversationView.foldTranscript(messages, activeTurnRunning: running)
    self.token = token
    self.running = running
    foldedItems = folded
    return folded
  }
}

@MainActor
private final class DSHConversationFoldRegistry {
  static let shared = DSHConversationFoldRegistry()
  private var states: [ObjectIdentifier: DSHConversationFoldCacheState] = [:]

  func state(for controller: HarnessController) -> DSHConversationFoldCacheState {
    states = states.filter { $0.value.controller != nil }
    let key = ObjectIdentifier(controller)
    if let state = states[key], state.controller === controller {
      return state
    }
    let state = DSHConversationFoldCacheState(controller: controller)
    states[key] = state
    return state
  }
}

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
  /// A failed call must be *visible* on the collapsed row: coral icon + 「失败」 chip.
  var failed: Bool = false
  let expanded: Bool
  let onToggle: () -> Void
  var onOpenDetails: (() -> Void)?
  /// A mutating row says so with three non-text cues only: the accent pencil, the 2pt leading
  /// accent bar, and the outlined 「改」 chip.
  var mutating: Bool = false
  /// Secondary line: the `cd …` prefix stripped from a shell command.
  var detail: String?
  /// Accent chip after the title — the folded group's "其中 M 条修改了文件".
  var chip: String?
  @State private var hovering = false

  private var accessibilityState: String {
    if running { return "执行中" }
    if failed { return "失败" }
    return ""
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
          hovering: hovering,
          mutating: mutating,
          detail: detail,
          chip: chip)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.leading, DSHSpace.s2 + 4)
          .padding(.trailing, DSHSpace.s2 + 1)
          .padding(.vertical, 5)
          // Collapsed execution rows are one line by construction; pinning the row to its font
          // metrics keeps the lazy stack's first layout equal to its corrected layout (minHeight
          // only grows, so nothing clips).
          .frame(minHeight: DSHTranscriptRowEstimate.toolStatusRowHeight(
            accessory: running || failed))
          .background(
            hovering || expanded ? DSHTheme.surfaceTint2 : DSHTheme.surfaceTint,
            in: RoundedRectangle(cornerRadius: DSHRadius.sm, style: .continuous))
          // 2pt accent bar marking "this row changed files" — a shape cue, not coloured text, so
          // it cannot hurt contrast.
          .overlay(alignment: .leading) {
            if mutating {
              RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(DSHTheme.accent)
                .frame(width: 2)
                .padding(.vertical, 4)
                .padding(.leading, 2)
                .allowsHitTesting(false)
            }
          }
          .overlay(alignment: .bottomLeading) {
            if running {
              DSHActivityLine(active: true)
                .padding(.horizontal, DSHSpace.s2 + 1)
                .padding(.bottom, 1)
                .allowsHitTesting(false)
            }
          }
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .onHover { hovering = $0 }
      .accessibilityLabel(
        [title ?? "指令", chip ?? "", mutating ? "修改文件" : "", accessibilityState,
         expanded ? "收起详情" : "展开详情"]
          .filter { !$0.isEmpty }
          .joined(separator: "，"))
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
  var mutating: Bool = false
  var detail: String?
  var chip: String?

  private var iconColor: Color {
    // Failure outranks running: a row that already reported an error should not read as "still
    // working".
    if failed { return DSHTheme.coral }
    if running { return DSHTheme.accent }
    return mutating ? DSHTheme.accent : DSHTheme.inkFaint
  }

  private var icon: String {
    mutating ? "pencil" : "terminal"
  }

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: icon)
        .font(DSHType.caption)
        .foregroundStyle(iconColor)
      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 6) {
          if let title {
            Text(title)
              .font(DSHType.mono)
              .foregroundStyle(DSHToolRowPalette.title)
              .lineLimit(1)
              .truncationMode(.middle)
              .contentTransition(.opacity)
              .animation(.easeInOut(duration: 0.16), value: title)
          }
          if mutating, chip == nil {
            DSHToolMutatingChip(text: "改")
          }
          if let chip {
            DSHToolMutatingChip(text: chip)
          }
        }
        if let detail, !detail.isEmpty {
          Text(detail)
            .font(DSHType.micro)
            .foregroundStyle(DSHToolRowPalette.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      Spacer(minLength: DSHSpace.s2)
      if running || failed {
        ToolStateAccessory(running: running, failed: failed)
          .transition(.opacity)
      }
      Image(systemName: "chevron.right")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(DSHToolRowPalette.secondary)
        .rotationEffect(.degrees(expanded ? 90 : 0))
    }
    .animation(.easeOut(duration: 0.18), value: running)
    .animation(.easeOut(duration: 0.18), value: failed)
  }
}

/// Small outlined chip: accent stroke, but the label inside keeps body-ink contrast on the accent
/// wash (asserted in DSHTests for both appearances).
private struct DSHToolMutatingChip: View {
  let text: String
  var body: some View {
    Text(text)
      .font(DSHType.micro)
      .foregroundStyle(DSHToolRowPalette.chipText)
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(
        DSHToolRowPalette.chipFill,
        in: Capsule())
      .overlay(
        Capsule()
          .strokeBorder(DSHToolRowPalette.accent, lineWidth: 1))
  }
}

private struct ToolStateAccessory: View {
  var running: Bool = true
  var failed: Bool = false

  var body: some View {
    if running {
      HStack(spacing: 5) {
        DSHRunningBars(color: DSHTheme.accent, height: 9)
        Text("执行中")
          .font(DSHType.micro)
          .foregroundStyle(DSHTheme.sessionSelectedForeground)
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(DSHTheme.accentSoft, in: Capsule())
      .fixedSize()
    } else if failed {
      HStack(spacing: 4) {
        Image(systemName: "xmark.circle.fill")
          .font(DSHType.micro)
        Text("失败")
          .font(DSHType.micro)
      }
      .foregroundStyle(DSHTheme.coral)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(DSHTheme.coralSoft, in: Capsule())
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

  /// Directory lifted out of a leading `cd …` for the secondary line.
  private var directory: String? {
    guard let activity else { return nil }
    return activity.commandSummary?.directory
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
        },
        mutating: instruction.mutating,
        detail: directory)
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
  @State private var isNearBottom = true
  @State private var scrollMonitor: Any?
  @State private var pointerInsideTranscript = false
  @State private var scrollRequestGeneration = 0
  /// Document-space measurements + the one-shot prepend restore.
  @State private var measurements = DSHTranscriptMeasurementStore()
  /// Coalesced tail-follow request that arrived while the user was scrolling.
  @State private var deferredTailAction: (() -> Void)?
  @State private var scrollBoundsObserver: Any?
  @State private var lastTracedClipOffset: CGFloat = 0
  @State private var isProgrammaticScrollWindow = false
  @State private var settleGeneration = 0
  @State private var prependAnchor: DSHTranscriptScrollAnchor?
  @State private var scrollViewBox = DSHTranscriptScrollViewBox()
  /// Row frames are only consumed while a reading position can be captured or restored.
  @ViewBuilder
  private func transcriptRow(
    _ item: TranscriptItem,
    width: CGFloat,
    measureFrames: Bool,
    isRunning: Bool,
    feedbackAnchorID: String?
  ) -> some View {
    switch item {
    case .reasoning(let trace):
      ReasoningBlock(
        text: trace.text,
        live: trace.live,
        liveStatus: DSHConversationLiveActivity.text(
          messages: harness.displayedSession?.messages ?? [],
          tools: harness.displayedTools,
          running: harness.displayedIsRunning))
        .equatable()
        .id(item.id)
        // Measured OUTSIDE the `.equatable()` scope: a subtree SwiftUI skips must not be the only
        // publisher of the row-frame preference (that is what silently emptied `rowFrames` and
        // degraded the prepend restore to the height-delta fallback).
        .dshTranscriptRowFrameIfNeeded(id: item.id, enabled: measureFrames)
        .onAppear { if DSHTranscriptPerf.isEnabled { DSHTranscriptPerf.rowAppearances += 1 } }
        .dshTranscriptCachedHeight(
          id: item.id,
          version: Self.rowVersion(reasoning: trace.text, live: trace.live),
          width: width,
          estimate: DSHTranscriptRowEstimate.reasoningStatusRowHeight(
            status: trace.live && isRunning),
          // A trace row expands/collapses from its own @State, so its measured height is not a
          // property of the row id.
          isLive: trace.live,
          isCollapsible: true,
          isEmpty: trace.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    case .message(let message):
      MessageBubble(
        message: message,
        isFeedbackAnchor: item.id == feedbackAnchorID)
        .equatable()
        .id(item.id)
        .dshTranscriptRowFrameIfNeeded(id: item.id, enabled: measureFrames)
        .onAppear { if DSHTranscriptPerf.isEnabled { DSHTranscriptPerf.rowAppearances += 1 } }
        .dshTranscriptCachedHeight(
          id: item.id,
          version: Self.rowVersion(message: message),
          width: width,
          estimate: DSHTranscriptRowEstimate.messageHeight(message, width: width),
          // The streamed reply grows within one row id; its measured height is a frame of a moving
          // target, never a stable minimum.
          isLive: Self.isStreamingRow(message, isRunning: isRunning),
          isEmpty: Self.isEmptyBody(message))
    case .toolGroup(let group):
      ToolGroupRow(
        messages: group,
        signature: Self.toolGroupSignature(group, tools: harness.displayedTools))
        .equatable()
        .id(item.id)
        .dshTranscriptRowFrameIfNeeded(id: item.id, enabled: measureFrames)
        .onAppear { if DSHTranscriptPerf.isEnabled { DSHTranscriptPerf.rowAppearances += 1 } }
        .dshTranscriptCachedHeight(
          id: item.id,
          version: Self.rowVersion(toolGroup: group),
          width: width,
          // A folded group is ONE collapsed line no matter how many commands it holds, and it
          // expands from its own @State.
          estimate: DSHTranscriptRowEstimate.toolStatusRowHeight(
            accessory: Self.toolGroupHasAccessory(group, tools: harness.displayedTools)),
          isCollapsible: true)
    }
  }

  /// The row that carries this turn's rating strip: the LAST assistant reply with a durable id —
  /// and nothing at all while the turn is still running.
  nonisolated static func feedbackAnchorID(
    _ items: [TranscriptItem],
    running: Bool
  ) -> String? {
    guard !running else { return nil }
    for item in items.reversed() {
      guard case .message(let message) = item,
            message.role == .assistant,
            let id = message.hostMessageId,
            id != DSHTranscriptMessageMarker.streamingAssistantHostMessageID else { continue }
      return "message-\(message.id.uuidString)"
    }
    return nil
  }

  /// The bits of a tool group's rendered line that do NOT come from its messages: resolved
  /// activity titles, running state and failure count.
  nonisolated static func toolGroupSignature(
    _ messages: [HarnessController.Message],
    tools: [HarnessController.ToolActivity]
  ) -> String {
    let calls = messages.map { message -> DSHToolGroupDigestBuilder.Call in
      let activity = message.toolCallId.flatMap { id in tools.last { $0.callId == id } }
      let title = activity.flatMap { DSHToolGroupStatus.instructionTitle(for: $0) }
        ?? message.text
      let kind = activity?.callKind
        ?? DSHToolCallClassifier.kind(name: message.text, arguments: String?.none)
      return DSHToolGroupDigestBuilder.Call(
        title: title,
        kind: kind,
        running: activity?.state == .running,
        failed: activity?.state == .failed)
    }
    guard let digest = DSHToolGroupDigestBuilder.digest(for: calls) else { return "empty" }
    return [
      String(digest.commandCount),
      String(digest.mutatingCount),
      String(digest.failedCount),
      digest.runningTitle ?? "-"
    ].joined(separator: "|")
  }

  /// A tool group is "running" while any of its calls is still executing: the header then renders
  /// the status accessory, which is taller than the idle row, so its estimate must follow the
  /// rendered state.
  nonisolated static func toolGroupHasAccessory(
    _ group: [HarnessController.Message],
    tools: [HarnessController.ToolActivity]
  ) -> Bool {
    group.contains { message in
      guard let id = message.toolCallId else { return false }
      return tools.contains {
        $0.callId == id && ($0.state == .running || $0.state == .failed)
      }
    }
  }

  /// Rows whose rendered body is empty keep NO placeholder height: an empty reply bubble used to
  /// reserve its estimate, which is what left a blank band under an interrupted turn.
  nonisolated static func isEmptyBody(_ message: HarnessController.Message) -> Bool {
    message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (message.reasoning ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && message.attachment == nil
  }

  /// The reply currently being streamed keeps changing under one row id, so it must never seed
  /// `minHeight` from a measurement.
  nonisolated static func isStreamingRow(
    _ message: HarnessController.Message,
    isRunning: Bool
  ) -> Bool {
    isRunning
      && message.role == .assistant
      && message.hostMessageId == DSHTranscriptMessageMarker.streamingAssistantHostMessageID
  }

  /// Cheap content version per row: any change that can change the rendered height bumps it, which
  /// invalidates that row's cached height.
  nonisolated static func rowVersion(message: HarnessController.Message) -> Int {
    var hasher = Hasher()
    hasher.combine(message.text.utf8.count)
    hasher.combine(message.text.hashValue)
    hasher.combine(message.reasoning ?? "")
    hasher.combine(message.toolCallId)
    hasher.combine(message.attachment?.attachmentId)
    hasher.combine(message.isRelayMessage)
    return hasher.finalize()
  }

  nonisolated static func rowVersion(reasoning text: String, live: Bool) -> Int {
    var hasher = Hasher()
    hasher.combine(text.utf8.count)
    hasher.combine(text.hashValue)
    hasher.combine(live)
    return hasher.finalize()
  }

  nonisolated static func rowVersion(toolGroup: [HarnessController.Message]) -> Int {
    var hasher = Hasher()
    hasher.combine(toolGroup.count)
    for message in toolGroup {
      hasher.combine(message.text.utf8.count)
      hasher.combine(message.toolCallId)
    }
    return hasher.finalize()
  }

  private var measuresRowFrames: Bool {
    DSHTranscriptMeasurementPolicy.shouldMeasure(
      pinned: pinnedToBottom,
      isLoadingHistory: harness.displayedIsLoadingHistory,
      hasPendingRestore: measurements.hasPendingRestore,
      force: DSHTranscriptPerf.forceRowFrames)
  }

  var body: some View {
    if DSHTranscriptPerf.isEnabled { DSHTranscriptPerf.bodyEvaluations += 1 }
    return GeometryReader { viewport in
    let messages = harness.displayedSession?.messages ?? []
    let messageToken = harness.displayedConversationMessageToken
    let transcriptItems = messages.isEmpty
      ? []
      : DSHConversationFoldRegistry.shared.state(for: harness).items(
        messages: messages,
        token: messageToken,
        running: harness.displayedIsRunning)
    let loadingPresentation = DSHConversationHistoryLoadingPresentation.resolve(
      isLoading: harness.displayedIsLoadingHistory,
      hasMessages: !messages.isEmpty,
      running: harness.displayedIsRunning)
    let rowWidth = viewport.size.width
    let rowGates = measuresRowFrames
    let feedbackAnchorID = Self.feedbackAnchorID(
      transcriptItems, running: harness.displayedIsRunning)
    ScrollViewReader { proxy in
      ScrollView(.vertical, showsIndicators: false) {
        LazyVStack(alignment: .leading, spacing: DSHSpace.s4) {
          if loadingPresentation == .placeholder {
            ConversationLoadingView()
              .id("conversation-history-loading")
          } else if messages.isEmpty {
            ConversationEmptyState()
          } else {
            ForEach(transcriptItems) { item in
              transcriptRow(
                item,
                width: rowWidth,
                measureFrames: rowGates,
                isRunning: harness.displayedIsRunning,
                feedbackAnchorID: feedbackAnchorID)
            }
            ForEach(harness.displayedSteeringItems) { item in
              PendingSteeringBubble(item: item).id("steering-\(item.id)")
            }
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
          // The content's own document coordinate space: row frames measured here are
          // scroll-invariant.
          .dshTranscriptDocumentSpace()
          // Content-bottom-to-viewport-bottom distance, measured on every
          // layout pass: ~0 when parked at the bottom, grows as the user
          // scrolls up. Drives the follow-mode pin. Content height and offset
          // ride along: a resize must not move a reader who scrolled up, and
          // an older-history batch needs the height it inserted above them.
          .background(GeometryReader { content in
            let frame = content.frame(in: DSHConversationScrollGeometry.viewportSpace)
            Color.clear.preference(
              key: ConversationBottomDistanceKey.self,
              value: frame.maxY - viewport.size.height)
            Color.clear.preference(
              key: DSHTranscriptLayoutMetricsKey.self,
              value: DSHTranscriptLayoutMetrics(contentHeight: frame.height))
          })
      }
      // Thin overlay scroller (appears while scrolling, no gutter) — AppKit-level because
      // "始终显示滚动条" otherwise forces the thick legacy bar.
      .dshThinScrollers()
      // A context switch gets a fresh viewport with its own initial offset, rather than inheriting
      // an estimated offset from the previous session.
      .id(harness.displayedConversationContextKey ?? "conversation-new")
      // The newest content is the stable entry point for a persisted session, but ONLY for the
      // first layout pass: content-size changes must never re-anchor the viewport (LazyVStack
      // corrects row heights continuously, and each correction used to drag the reader back to the
      // bottom).
      .dshInitialBottomScrollAnchor()
      // Keeps the viewport inside content that exists, so an offset sampled against over-estimated
      // tool/thinking rows cannot render a blank page.
      .background(
        DSHTranscriptScrollViewBridge(box: scrollViewBox, onAttach: handleBridgeAttach))
      .coordinateSpace(name: DSHConversationScrollGeometry.viewportSpaceName)
      // Keep background history progress out of LazyVStack's measured content.
      .overlay(alignment: .top) {
        if loadingPresentation == .inline {
          ConversationLoadingView(compact: true)
            .padding(.top, DSHSpace.s3)
            .padding(.horizontal, DSHSpace.s5)
            .allowsHitTesting(false)
        }
      }
      .onHover { pointerInsideTranscript = $0 }
      // Distance is bookkeeping only — it must never re-engage the pin by
      // itself. The old `pinned = distance < 80` lost a race during
      // streaming: every auto-scroll zeroed the distance and re-pinned
      // before the user's upward scroll could cross the threshold, so the
      // view kept snapping down. Unpin/repin now follow the user's actual
      // wheel gestures (below), which fire synchronously.
      .onPreferenceChange(ConversationBottomDistanceKey.self) { distance in
        if DSHTranscriptPerf.isEnabled { DSHTranscriptPerf.bottomDistanceDeliveries += 1 }
        // Reference-type store: this must not re-evaluate the transcript body.
        measurements.update(bottomDistance: distance)
        // Only bookkeeping now: this distance is derived from LazyVStack's ESTIMATED content
        // height, so it may not pin or unpin anything.
        isNearBottom = DSHConversationScrollFollow.isNearBottom(distance)
      }
      .onChange(of: messageToken) { previous, token in
        if token.contextKey != previous.contextKey {
          setPinned(true, reason: "context-change")
          return
        }
        guard let last = harness.displayedSession?.messages.last else { return }
        // Follow only while pinned — except the user's own send, which
        // always snaps down so the new turn starts in view. Anchor is the
        // tail row (running animation / end marker), not the last message —
        // it is the transcript's true bottom.
        let isOwnSend = last.role == .user && previous.lastID != token.lastID
        if isOwnSend {
          setPinned(true, reason: "own-send")
        }
        let follow = DSHConversationScrollPolicy.shouldFollowTail(
          pinned: pinnedToBottom,
          trigger: .tailContentChanged)
        if follow, token.shouldFollowTail(comparedTo: previous) {
          // The user's own send is the one path that must scroll immediately, even if a
          // gesture/momentum is still in flight.
          requestScrollToTail(proxy, force: isOwnSend)
        }
      }
      // The run settling (or starting without a new message, e.g. a queued
      // drain) swaps the tail row in place — keep it in view while pinned.
      .onChange(of: harness.displayedIsRunning) { _, _ in
        if DSHConversationScrollPolicy.shouldFollowTail(
          pinned: pinnedToBottom,
          trigger: .runningStateChanged) {
          requestScrollToTail(proxy)
        }
      }
      .onChange(of: harness.displayedSteeringItems.map(\.id)) { _, _ in
        if DSHConversationScrollPolicy.shouldFollowTail(
          pinned: pinnedToBottom,
          trigger: .steeringChanged) {
          requestScrollToTail(proxy)
        }
      }
      // Document-space row frames: scroll-invariant, so this fires when rows are
      // added/removed/re-measured — never on a scrolled pixel.
      .onPreferenceChange(DSHTranscriptRowFrameKey.self) { frames in
        if DSHTranscriptPerf.isEnabled { DSHTranscriptPerf.rowFrameDeliveries += 1 }
        measurements.update(rowFrames: frames)
        resolvePendingRestore(viewportHeight: viewport.size.height)
      }
      .onPreferenceChange(DSHTranscriptLayoutMetricsKey.self) { metrics in
        let previous = measurements.contentHeight
        if DSHTranscriptPerf.isEnabled {
          let step = abs(Double(metrics.contentHeight - previous))
          DSHTranscriptPerf.contentHeightDrift += step
          DSHTranscriptPerf.metricDeliveries += 1
          DSHTranscriptPerf.metricLargestStep = max(DSHTranscriptPerf.metricLargestStep, step)
        }
        measurements.update(contentHeight: metrics.contentHeight)
        // Second (and only other) trigger for the one-shot entry clamp: the bridge can attach
        // before SwiftUI has measured the document, and after that nothing else would call it.
        scrollViewBox.clampOnEntry()
        resolvePendingRestore(viewportHeight: viewport.size.height)
        // A transcript that grew or shrank is not a follow request by itself.
        guard DSHConversationScrollPolicy.shouldFollowAfterResize(
          pinned: pinnedToBottom,
          previousContentHeight: previous,
          contentHeight: metrics.contentHeight)
        else { return }
        requestScrollToTail(proxy)
      }
      // Older pages are prepended incrementally for responsiveness.
      .onChange(of: harness.displayedIsLoadingHistory) { wasLoading, isLoading in
        if !wasLoading, isLoading {
          capturePrependAnchorIfReading(viewportHeight: viewport.size.height)
          return
        }
        guard wasLoading, !isLoading else { return }
        let anchor = prependAnchor
        prependAnchor = nil
        if DSHConversationScrollPolicy.shouldRestoreAfterPrepend(
          pinned: pinnedToBottom,
          anchor: anchor),
           let anchor {
          beginPrependRestore(anchor, proxy: proxy, viewportHeight: viewport.size.height)
        } else if DSHConversationScrollPolicy.shouldFollowTail(
          pinned: pinnedToBottom,
          trigger: .olderHistoryFinished) {
          requestScrollToTail(proxy)
        }
      }
      // A reader who scrolls up WHILE a batch is in flight must not be dragged back to where the
      // batch started: their interest moved.
      .onChange(of: pinnedToBottom) { _, pinned in
        measurements.cancelRestore()
        guard !pinned, harness.displayedIsLoadingHistory else { return }
        // The wheel that unpinned us is applied to the clip AFTER this callback, so the live
        // offset is still the old bottom.
        DispatchQueue.main.async {
          capturePrependAnchorIfReading(viewportHeight: viewport.size.height)
        }
      }
      // One-tap return to the latest content, icon only — a circle floating
      // centered just above the composer, shown whenever follow mode is off
      // (the user scrolled up to read history).
      .overlay(alignment: .bottom) {
        if !pinnedToBottom {
          Button {
            setPinned(true, reason: "back-to-latest")
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
    .onChange(of: harness.displayedConversationContextKey) { _, _ in
      scrollRequestGeneration += 1
      measurements.reset()
      prependAnchor = nil
      // A new session gets its own single entry clamp.
      scrollViewBox.resetEntryClamp()
      setPinned(true, reason: "context-change")
    }
    }
    .onAppear {
      scrollViewBox.onInteractionChange = { interacting in
        guard !interacting else { return }
        settlePinAfterInteraction()
      }
      scrollViewBox.trace = { DSHScrollTrace.log("box", before: nil, after: nil, contentHeight: nil, pinned: pinnedToBottom, gesture: true, extra: $0) }
      installScrollMonitor()
      installScrollTraceObserver()
    }
    .onDisappear { removeScrollMonitor() }
  }

  private func installScrollMonitor() {
    guard scrollMonitor == nil else { return }
    scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
      guard pointerInsideTranscript else { return event }
      // Direct phase AND momentum phase both count as "the user is scrolling": while either is
      // live, a "near bottom" reading comes from LazyVStack's estimates (still being corrected)
      // and pinning there is what produced the "fast scroll jumps to the bottom, then stutters"
      // report.
      scrollViewBox.noteScrollEvent(phase: event.phase, momentumPhase: event.momentumPhase)
      scheduleSettleAfterInteraction()
      if event.scrollingDeltaY > 0 {
        // Scrolling up = reading history: break the pin immediately.
        setPinned(false, reason: "wheel-up")
      }
      // Re-pinning happens only at rest, from AppKit's real geometry
      // (`settlePinAfterInteraction`), never from a mid-gesture event.
      return event
    }
  }

  private func removeScrollMonitor() {
    if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
    scrollMonitor = nil
    if let scrollBoundsObserver { NotificationCenter.default.removeObserver(scrollBoundsObserver) }
    scrollBoundsObserver = nil
  }

  /// Single place that flips the pin, so every flip is traced and the deferred tail follow can be
  /// flushed when it goes true at rest.
  private func setPinned(_ pinned: Bool, reason: String) {
    guard pinnedToBottom != pinned else { return }
    pinnedToBottom = pinned
    DSHScrollTrace.log(
      "pin", before: scrollViewBox.contentOffset, after: scrollViewBox.contentOffset,
      contentHeight: scrollViewBox.contentHeight, pinned: pinned,
      gesture: scrollViewBox.isUserScrolling, extra: "reason=\(reason)")
    if pinned, !scrollViewBox.isUserScrolling, let action = deferredTailAction {
      deferredTailAction = nil
      action()
    }
  }

  /// Edge callbacks alone are not enough: a `.ended` that AppKit coalesces away (or a gesture the
  /// monitor first sees mid-flight) leaves the pin stuck and the reader never follows the newest
  /// content again.
  private func scheduleSettleAfterInteraction() {
    settleGeneration += 1
    let generation = settleGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
      guard generation == settleGeneration, !scrollViewBox.isUserScrolling else { return }
      settlePinAfterInteraction()
    }
  }

  /// Called when the gesture AND its momentum have both ended (or the timestamp expired).
  private func settlePinAfterInteraction() {
    guard scrollViewBox.isAvailable else {
      // No bridge: fall back to the estimated distance, as before.
      setPinned(isNearBottom, reason: "settle-estimated")
      return
    }
    guard let distance = scrollViewBox.realBottomDistance else { return }
    let atBottom = DSHConversationScrollFollow.shouldPinAtRest(
      atRealBottom: distance <= DSHConversationScrollFollow.realBottomThreshold)
    DSHScrollTrace.log(
      "pin-settle", before: scrollViewBox.contentOffset, after: scrollViewBox.contentOffset,
      contentHeight: scrollViewBox.contentHeight, pinned: atBottom,
      gesture: false, extra: "realDistance=\(String(format: "%.1f", distance))")
    setPinned(atBottom, reason: "settle-real-bottom")
  }

  /// `NSView.boundsDidChangeNotification` watchdog: with no programmatic write in flight, a single
  /// >400pt jump is unexplained and worth printing.
  private func installScrollTraceObserver() {
    guard scrollBoundsObserver == nil, let clip = scrollViewBox.scrollView?.contentView else { return }
    clip.postsBoundsChangedNotifications = true
    lastTracedClipOffset = clip.bounds.origin.y
    scrollBoundsObserver = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
    ) { _ in
      let now = scrollViewBox.contentOffset
      let delta = now - lastTracedClipOffset
      if abs(delta) > 400, !isProgrammaticScrollWindow {
        DSHScrollTrace.log(
          "unexplained-jump", before: lastTracedClipOffset, after: now,
          contentHeight: scrollViewBox.contentHeight, pinned: pinnedToBottom,
          gesture: scrollViewBox.isUserScrolling,
          extra: "delta=\(String(format: "%.1f", delta))")
      }
      lastTracedClipOffset = now
    }
  }

  /// Capture the reader's position only when there is one to keep: a reader parked at the tail is
  /// following new content, and restoring a bottom anchor after they scroll up would drag them
  /// back down.
  private func capturePrependAnchorIfReading(viewportHeight: CGFloat) {
    guard !pinnedToBottom, viewportHeight > 0 else {
      prependAnchor = nil
      return
    }
    let liveOffset = scrollViewBox.isAvailable
      ? scrollViewBox.contentOffset
      : measurements.contentOffset(viewportHeight: viewportHeight)
    prependAnchor = measurements.captureAnchor(
      contentOffset: liveOffset,
      viewportHeight: viewportHeight)
  }

  /// The bridge reports a successful attach.
  private func handleBridgeAttach() {
    scrollViewBox.onInteractionChange = { interacting in
      guard !interacting else { return }
      settlePinAfterInteraction()
    }
    scrollViewBox.trace = { message in
      DSHScrollTrace.log(
        "box", before: scrollViewBox.contentOffset, after: scrollViewBox.contentOffset,
        contentHeight: scrollViewBox.contentHeight, pinned: pinnedToBottom,
        gesture: scrollViewBox.isUserScrolling, extra: message)
    }
    installScrollTraceObserver()
    scrollViewBox.clampOnEntry()
  }

  /// Arm the restore and let the NEXT real row layout finish it.
  private func beginPrependRestore(
    _ anchor: DSHTranscriptScrollAnchor,
    proxy: ScrollViewProxy,
    viewportHeight: CGFloat
  ) {
    guard scrollViewBox.isAvailable else {
      // No bridge: ScrollViewReader cannot express "row at viewport offset X", and `anchor: .top`
      // would snap the row to the top edge (up to a full viewport of error) — a visible jump.
      return
    }
    // A capture taken while the row set was still empty cannot restore anything: do not arm a
    // restore that would end up writing nothing.
    guard anchor.firstVisibleRowID != nil || anchor.contentHeight > 0 else { return }
    measurements.beginRestore(
      anchor,
      liveContentOffset: scrollViewBox.contentOffset,
      hasRowAnchor: anchor.firstVisibleRowID != nil)
    // The batch's final layout may already have landed before this change fired; try once now,
    // then rely on the preference callbacks.
    resolvePendingRestore(viewportHeight: viewportHeight)
    scheduleRestoreWatchdog(viewportHeight: viewportHeight)
  }

  /// Bounded retry: the row-frame layout that unlocks a restore can be delivered after the last
  /// preference callback we observe, and a height-only change only unlocks the fallback after
  /// `restoreFallbackDelay`.
  private func scheduleRestoreWatchdog(viewportHeight: CGFloat) {
    for delay in [0.05, 0.15, 0.3, 0.6, 1.0, 1.4] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        resolvePendingRestore(viewportHeight: viewportHeight)
      }
    }
  }

  /// Consume the armed restore once a layout newer than the capture has landed.
  private func resolvePendingRestore(viewportHeight: CGFloat) {
    guard measurements.hasPendingRestore, viewportHeight > 0 else { return }
    guard !scrollViewBox.isUserScrolling else { return }
    guard scrollViewBox.isAvailable else { return }
    // D: a scrollbar drag / Page Up produces no scrollWheel event, so the gesture flag never
    // rises.
    if measurements.readerMovedAway(liveContentOffset: scrollViewBox.contentOffset) {
      // D/F: a scrollbar drag or Page Up raised no wheel phase, so the gesture flag stayed down;
      // the reader simply is not where the batch started.
      measurements.cancelRestore()
      return
    }
    guard let pending = measurements.takePendingRestore() else { return }
    let anchor = pending.anchor
    // Only the row path may use a row frame; the height fallback must not, or it re-writes a
    // pre-prepend position (the bug the generation split removes).
    let rowFrame = pending.path == .rowLayout
      ? anchor.firstVisibleRowID.flatMap { measurements.rowFrames[$0] }
      : nil
    let offset = DSHConversationScrollPolicy.restoredContentOffset(
      for: anchor,
      rowFrame: rowFrame,
      contentHeight: measurements.contentHeight,
      viewportHeight: viewportHeight)
    scrollViewBox.setContentOffset(offset)
  }

  /// Coalesce repeated follow requests in the same render transaction.
  private func requestScrollToTail(_ proxy: ScrollViewProxy, force: Bool = false) {
    if scrollViewBox.isUserScrolling,
       DSHConversationScrollFollow.mayFollowTail(isInteracting: true, force: force) == false {
      deferredTailAction = { [proxy] in requestScrollToTail(proxy, force: true) }
      return
    }
    let generation = scrollRequestGeneration + 1
    scrollRequestGeneration = generation
    DispatchQueue.main.async {
      guard generation == scrollRequestGeneration,
            pinnedToBottom,
            harness.displayedSession?.messages.isEmpty == false
      else { return }
      let before = scrollViewBox.contentOffset
      var transaction = Transaction()
      transaction.animation = nil
      isProgrammaticScrollWindow = true
      withTransaction(transaction) {
        proxy.scrollTo("transcript-tail", anchor: .bottom)
      }
      DispatchQueue.main.async { isProgrammaticScrollWindow = false }
      DSHScrollTrace.log(
        "requestScrollToTail", before: before, after: scrollViewBox.contentOffset,
        contentHeight: scrollViewBox.contentHeight, pinned: pinnedToBottom,
        gesture: scrollViewBox.isUserScrolling, extra: "force=\(force)")
    }
  }

  /// One assistant turn's step traces, aggregated into a single ✻ row.
  struct ReasoningTrace: Identifiable {
    let id: UUID
    var text: String
    var live: Bool
    let turnOrdinal: Int
  }

  /// A transcript row after folding: plain message, an aggregated trace, or one merged row for a
  /// turn's command calls (bash/read/write/edit/…), collapsed by default so a long tool run reads
  /// as one line.
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

    /// More than one command is worth folding; a single call stays a plain row.
    static func shouldGroup(_ messages: [HarnessController.Message]) -> Bool {
      messages.count > 1
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
    // Index into `items` of the current turn's merged command row, if any.
    var turnGroup: Int?
    var turnOrdinal = 0

    for message in messages {
      if message.role == .user {
        turnOrdinal += 1
        turnTrace = nil
        turnGroup = nil
      }
      let reasoning = message.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let hasBody = !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || message.attachment != nil
      if message.role == .assistant, !reasoning.isEmpty {
        if let index = turnTrace, case .reasoning(var existing) = items[index] {
          existing.text += "\n\n" + reasoning
          existing.live = false
          items[index] = .reasoning(existing)
        } else {
          items.append(.reasoning(ReasoningTrace(
            id: message.id,
            text: reasoning,
            live: false,
            turnOrdinal: turnOrdinal)))
          turnTrace = items.count - 1
        }
        if hasBody { items.append(.message(message)) }
        continue
      }
      if message.role == .assistant, !hasBody { continue }
      // A new user/system row opens the next turn: its traces get their own row.
      if message.role == .system {
        turnTrace = nil
        turnGroup = nil
      }
      // Command tools fold into ONE row for the whole turn.
      if message.role == .tool,
         DSHToolCallShape.isCommandTool(message.text) {
        if let index = turnGroup, index < items.count {
          if case .toolGroup(var group) = items[index] {
            group.append(message)
            items[index] = .toolGroup(group)
            continue
          }
          if case .message(let previous) = items[index], previous.role == .tool {
            items[index] = .toolGroup([previous, message])
            continue
          }
        }
        // A single command is not a group yet — it stays a plain row and is promoted the moment a
        // second command lands in the same turn.
        items.append(.message(message))
        turnGroup = items.count - 1
        continue
      }
      // Non-command tools (run_code / agent dispatches) keep the old rule: only an immediately
      // preceding row with the same name joins.
      if message.role == .tool {
        turnGroup = nil
      }
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

/// One turn's command calls share a single collapsed row: "执行了 N 条命令 · 其中 M 条修改了文件 ›".
struct ToolGroupRow: View, Equatable {
  @EnvironmentObject var harness: HarnessController
  let messages: [HarnessController.Message]
  @State private var expanded: Bool

  /// Precomputed by the parent, NOT read from the environment here.
  var signature: String = ""

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.messages.count == rhs.messages.count
      && ConversationView.rowVersion(toolGroup: lhs.messages)
        == ConversationView.rowVersion(toolGroup: rhs.messages)
      && lhs.signature == rhs.signature
  }

  init(
    messages: [HarnessController.Message],
    initiallyExpanded: Bool = false,
    signature: String = ""
  ) {
    self.messages = messages
    self.signature = signature
    _expanded = State(initialValue: initiallyExpanded)
  }

  private var activities: [HarnessController.ToolActivity] {
    messages.compactMap { message in
      guard let id = message.toolCallId else { return nil }
      return harness.displayedTools.last { $0.callId == id }
    }
  }
  private var instructions: [DSHToolInstruction] {
    DSHToolInstructionFlatten.instructions(from: activities)
  }

  /// Digest drives the collapsed line: N commands, M of them mutating, and — while the turn runs —
  /// the title of the command being executed.
  private var digest: DSHToolGroupDigest? {
    let calls = messages.map { message -> DSHToolGroupDigestBuilder.Call in
      let activity = message.toolCallId.flatMap { id in
        harness.displayedTools.last { $0.callId == id }
      }
      let title = activity.flatMap { DSHToolGroupStatus.instructionTitle(for: $0) }
        ?? message.text
      let kind = activity?.callKind
        ?? DSHToolCallClassifier.kind(name: message.text, arguments: String?.none)
      return DSHToolGroupDigestBuilder.Call(
        title: title,
        kind: kind,
        running: activity?.state == .running,
        failed: activity?.state == .failed)
    }
    return DSHToolGroupDigestBuilder.digest(for: calls)
  }

  /// Body of the group line in normal ink; the running command and the mutation count are separate
  /// chips, never accent-coloured text.
  private var groupTitle: String {
    guard let digest else { return "执行了 \(messages.count) 条命令" }
    guard let running = digest.runningTitle else { return digest.headline }
    return "\(digest.headline) · \(running)"
  }

  private var mutatingCount: Int {
    digest?.mutatingCount ?? 0
  }

  /// One chip slot, failure first: 「N 条失败」 is the thing a reader must not miss, 「其中 M 条修改了文件」 is
  /// secondary.
  private var chipText: String? {
    digest?.failedSummary ?? digest?.mutatingSummary
  }

  var body: some View {
    if DSHTranscriptPerf.isEnabled { DSHTranscriptPerf.rowEvaluations += 1 }
    return groupBody
  }

  @ViewBuilder
  private var groupBody: some View {
    #if DEBUG
    // Record what this body actually composed.
    let _ = { DSHTranscriptPerf.renderedGroupTitle = groupTitle }()
    #endif
    groupContent
  }

  @ViewBuilder
  private var groupContent: some View {
    VStack(alignment: .leading, spacing: 3) {
      ToolStatusHeader(
        title: groupTitle,
        running: digest?.isRunning == true,
        failed: digest?.isFailed == true,
        expanded: expanded,
        onToggle: { expanded.toggle() },
        mutating: mutatingCount > 0,
        chip: chipText)
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
    TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
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
private struct ReasoningBlock: View, Equatable {
  let text: String
  var live: Bool = false
  var liveStatus: String?
  @State private var expanded = false

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.text == rhs.text && lhs.live == rhs.live && lhs.liveStatus == rhs.liveStatus
  }
  @State private var hovering = false
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
    if DSHTranscriptPerf.isEnabled { DSHTranscriptPerf.rowEvaluations += 1 }
    return reasoningBody
  }

  @ViewBuilder
  private var reasoningBody: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s2) {
      Button(action: { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }) {
        HStack(spacing: 6) {
          Text("✻")
            .font(DSHType.caption)
            .opacity(live ? 0.78 : 1)
          Text(live ? "处理中" : "思考过程")
            .font(DSHType.label)
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
        // Same reason as the tool status row: a collapsed thinking row is one line, so give it its
        // metrics instead of letting the lazy stack guess.
        .frame(minHeight: DSHTranscriptRowEstimate.reasoningStatusRowHeight(
          status: live && !expanded))
        .background(
            RoundedRectangle(cornerRadius: DSHRadius.sm, style: .continuous)
              .fill(hovering || expanded ? DSHTheme.surfaceTint2 : DSHTheme.surfaceTint))
        .contentShape(Rectangle())
      }.buttonStyle(.plain)
      .onHover { hovering = $0 }
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
// Internal (not `private`) so the golden tests can ask
// `MessageBubble.stripMessageID` rather than re-implementing the rule.
struct MessageBubble: View, Equatable {
  @EnvironmentObject var harness: HarnessController
  let message: HarnessController.Message
  /// True for the ONE row that anchors this turn's rating strip: the last assistant reply of a
  /// turn that has finished.
  var isFeedbackAnchor = false

  /// Identity + content version only: a streaming chunk in some OTHER row must not re-evaluate
  /// this one's body (that is the mounted-row cost that keeps a fast scroll at ~14 ms/frame).
  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.message.id == rhs.message.id
      && ConversationView.rowVersion(message: lhs.message)
        == ConversationView.rowVersion(message: rhs.message)
      && lhs.isFeedbackAnchor == rhs.isFeedbackAnchor
  }


  var body: some View {
    if DSHTranscriptPerf.isEnabled { DSHTranscriptPerf.rowEvaluations += 1 }
    return bubbleContent
  }

  /// The durable id whose rating this row shows, or nil for no strip.
  private var feedbackMessageID: String? {
    guard message.role == .assistant else { return nil }
    return Self.stripMessageID(
      hostMessageID: message.hostMessageId,
      isAnchor: isFeedbackAnchor,
      rated: message.hostMessageId.flatMap { harness.messageFeedback[$0]?.rating } != nil)
  }

  /// Pure form of the rule above, so a test can ask the same question without a mounted view.
  nonisolated static func stripMessageID(
    hostMessageID: String?,
    isAnchor: Bool,
    rated: Bool
  ) -> String? {
    guard let hostMessageID,
          hostMessageID != DSHTranscriptMessageMarker.streamingAssistantHostMessageID else {
      return nil
    }
    return (isAnchor || rated) ? hostMessageID : nil
  }

  @ViewBuilder
  private var bubbleContent: some View {
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
          if message.hostMessageId == DSHTranscriptMessageMarker.streamingAssistantHostMessageID,
             harness.displayedIsRunning {
            StreamingAssistantText(text: message.text)
          } else {
            MarkdownText(text: message.text).frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        if let attachment = message.attachment { AttachmentPreview(ref: attachment, sessionID: harness.displayedAttachmentSessionID) }
        // The rating strip is a real row here — but only on the turn's LAST assistant reply, and
        // only once the turn has ended.
        if let messageId = feedbackMessageID {
          // Fixed row height instead of negative padding: the ghost buttons' line box carries ~4pt
          // of slack on each side, and clipping it with `.padding(.vertical, -4)` would also
          // shrink the hit area (and break the moment a system/font update moves the slack).
          FeedbackBar(messageId: messageId)
            .frame(height: 20)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
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
        initiallyExpanded: initiallyExpanded ?? false,
        signature: ConversationView.toolGroupSignature(
          [message], tools: harness.displayedTools))
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
    // A 20pt row would clip the buttons' own 22pt hit area: the content shape re-declares a
    // full-size target so a shorter strip stays easy to click.
    .frame(minWidth: 56, minHeight: 20)
    .contentShape(Rectangle())
    .buttonStyle(.dshGhost).font(.caption)
    .foregroundStyle(current == nil ? DSHTheme.inkFaint : DSHTheme.accent)
  }
}
