import SwiftUI
import AppKit

private struct VoiceComposerTarget: Equatable {
  let selectedSessionID: UUID?
  let executionTarget: DSHDisplayedExecutionTarget
}

enum DSHComposerLayout {
  static let stackedControlsThreshold: CGFloat = 720

  static func usesStackedControls(availableWidth: CGFloat) -> Bool {
    availableWidth < stackedControlsThreshold
  }
}

struct Composer: View {
  @EnvironmentObject var harness: HarnessController
  @FocusState private var editorFocused: Bool
  /// dialog 路由听写开始时 VoiceController 通过它请求输入框获得焦点。
  @ObservedObject private var voiceFocus = VoiceFocusRequest.shared
  @State private var editorContentHeight: CGFloat = 22
  @State private var voiceTarget: VoiceComposerTarget?
  /// Draft content captured when dictation starts streaming — partials
  /// replace from here, and a cancel command restores it verbatim.
  @State private var dictationBase: String?
  // Slash-palette view state: keyboard selection plus the Esc dismissal that
  // holds until the next edit. The roster itself derives from the draft.
  @State private var paletteSelection = 0
  @State private var paletteDismissed = false
  @State private var mentionSelection = 0
  @State private var mentionDismissed = false
  var compactControls = false

  /// The palette roster for the current draft — commands, native locals, and
  /// skills, matched by NativeCommandPalette's mirror of the web `/` menu.
  /// Empty while the draft is not a bare `/token` or after Esc.
  private var paletteEntries: [DSHSlashEntry] {
    guard !paletteDismissed, harness.canUseRootSlashCatalog,
          let query = DSHSlashMatcher.bareToken(of: harness.draft) else { return [] }
    return DSHSlashMatcher.entries(commands: harness.hostCommands, skills: harness.skills, query: query)
  }
  private var selectedPaletteEntry: DSHSlashEntry? {
    let entries = paletteEntries
    guard !entries.isEmpty else { return nil }
    return entries[min(paletteSelection, entries.count - 1)]
  }
  private var mentionQuery: DSHAgentMentionQuery? {
    guard !mentionDismissed, harness.composerAgentProfileID == nil,
          !harness.isViewingReadOnlySubagent else { return nil }
    return DSHAgentMentionMatcher.query(in: harness.draft)
  }
  private var mentionProfiles: [DSHAgentProfile] {
    guard let mentionQuery else { return [] }
    return Array(DSHAgentMentionMatcher.profiles(harness.agentProfiles, matching: mentionQuery.query).prefix(7))
  }
  private var selectedMentionProfile: DSHAgentProfile? {
    guard !mentionProfiles.isEmpty else { return nil }
    return mentionProfiles[min(mentionSelection, mentionProfiles.count - 1)]
  }
  var body: some View {
    if harness.isViewingReadOnlySubagent {
      VStack(spacing: DSHSpace.s2) {
        GoalBar()
        HStack { Image(systemName: "lock.fill"); Text("只读：此子代理已结束，历史不可续写。返回上一级可继续操作。"); Spacer() }
          .font(.caption).foregroundStyle(DSHTheme.inkFaint).padding(DSHSpace.s5)
      }
    } else {
    VStack(spacing: DSHSpace.s2) {
      // No status readout here — the transcript itself (waiting wave, tool
      // rows, system notes) already narrates what's happening; a second
      // ticker in the corner was noise. Plan/queue chips stay.
      if harness.displayedPlanActive || !harness.displayedQueuedItems.isEmpty {
        HStack {
          if harness.displayedPlanActive {
            if harness.canMutateDisplayedPlan {
              Button("计划模式 ×", action: harness.exitPlanMode).buttonStyle(.dshSecondary)
            } else {
              DSHBadge(text: "子代理计划模式", tone: .neutral)
            }
          }
          if !harness.displayedQueuedItems.isEmpty {
            DSHBadge(text: "已排队 \(harness.displayedQueuedItems.count)", tone: .warm)
          }
          Spacer()
        }
      }
      GoalBar()
      QueueDockView()
      if !mentionProfiles.isEmpty {
        AgentProfilePalette(
          profiles: mentionProfiles,
          selection: min(mentionSelection, mentionProfiles.count - 1),
          onPick: pickMentionProfile)
      }
      if !paletteEntries.isEmpty {
        CommandPaletteView(entries: paletteEntries, selection: min(paletteSelection, paletteEntries.count - 1), onPick: { harness.pickSlashEntry($0) })
      }
      if let profile = harness.selectedComposerAgentProfile {
        AgentComposerSelectionBar(profile: profile)
      }
      // Above the box: workspace chips (blank conversation) on the left,
      // session figures (context / tokens / turns) on the right.
      HStack {
        if harness.isNewConversation { WorkspaceChips() }
        Spacer()
        StatusStrip()
      }
      // Text field and every compose-time control (attachments, voice,
      // model picker, send/stop) share one bordered box, matching the
      // consolidated-composer redesign — see
      // .agents/notes/implemented/bug-fix/2026-08-17-composer-consolidation.md.
      VStack(alignment: .leading, spacing: DSHSpace.s2) {
        // Auto-growing editor: an invisible mirror of the draft is measured
        // and the editor's height is pinned to it — TextEditor itself is
        // greedy (no intrinsic height) and would otherwise expand straight
        // to the max, which is exactly the "还是那么高" bug.
        ZStack(alignment: .topLeading) {
          Text(harness.draft.isEmpty ? " " : (harness.draft.hasSuffix("\n") ? harness.draft + " " : harness.draft))
            .font(.system(.body, design: .rounded))
            .padding(.horizontal, 5)
            .opacity(0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { editorContentHeight = $0 }
          TextEditor(text: $harness.draft).font(.system(.body, design: .rounded)).scrollContentBackground(.hidden)
            .focused($editorFocused)
            // No scroller on the composer at all — below the max height the
            // box grows instead of scrolling, so a bar has nothing to say;
            // past the max, wheel/trackpad still scroll. Enforced per bounds
            // change because AppKit re-adds the legacy bar on every layout
            // under "始终显示滚动条" (see NativeScrollbars).
            .dshNoTextScrollers()
            // 回车直接发送；Shift+回车换行。Intercepted before the newline is
            // inserted, so a sent draft doesn't leave a stray empty line.
            // 面板打开时回车改为执行选中项（cc/codex 的菜单语义）。
            .onKeyPress(.return, phases: .down) { press in
              if press.modifiers.contains(.shift) { return .ignored }
              // 输入法组合（拼音等）进行中：回车用于确认候选，不能发送。
              // onKeyPress 在文本输入管道前触发，组合中的 marked text 不进入
              // draft，只能查焦点文本框的组合态。
              if editorHasMarkedText { return .ignored }
              if let profile = selectedMentionProfile { pickMentionProfile(profile); return .handled }
              if let entry = selectedPaletteEntry { harness.pickSlashEntry(entry); return .handled }
              // 回车发送可关（设置→通用）：关掉后回车换行，⌘回车发送。
              if !AppPrefs.enterToSend, !press.modifiers.contains(.command) { return .ignored }
              if harness.submitBusyComposer(
                accelerated: AppPrefs.enterToSend && press.modifiers.contains(.command)
              ) {
                return .handled
              }
              guard harness.composerCanSubmit else { return .ignored }
              harness.submitComposer()
              return .handled
            }
            // Palette keys claim ↑/↓/Tab/Esc only while the palette shows;
            // otherwise `.ignored` keeps caret movement and focus traversal.
            // ↑/↓ include the `.repeat` phase so holding the key keeps
            // walking the list at the system key-repeat rate.
            .onKeyPress(.upArrow, phases: [.down, .repeat]) { _ in
              if !mentionProfiles.isEmpty {
                mentionSelection = (min(mentionSelection, mentionProfiles.count - 1) - 1 + mentionProfiles.count) % mentionProfiles.count
                return .handled
              }
              let count = paletteEntries.count
              guard count > 0 else { return .ignored }
              paletteSelection = (min(paletteSelection, count - 1) - 1 + count) % count
              return .handled
            }
            .onKeyPress(.downArrow, phases: [.down, .repeat]) { _ in
              if !mentionProfiles.isEmpty {
                mentionSelection = (min(mentionSelection, mentionProfiles.count - 1) + 1) % mentionProfiles.count
                return .handled
              }
              let count = paletteEntries.count
              guard count > 0 else { return .ignored }
              paletteSelection = (min(paletteSelection, count - 1) + 1) % count
              return .handled
            }
            .onKeyPress(.tab, phases: .down) { _ in
              if let profile = selectedMentionProfile { pickMentionProfile(profile); return .handled }
              guard let entry = selectedPaletteEntry else { return .ignored }
              harness.draft = "/\(entry.name) "
              return .handled
            }
            .onKeyPress(.escape, phases: .down) { _ in
              if !mentionProfiles.isEmpty {
                mentionDismissed = true
                return .handled
              }
              if !paletteEntries.isEmpty {
                paletteDismissed = true
                return .handled
              }
              if editorHasMarkedText { return .ignored }
              // 对话运行中：Esc 直接停止本轮（面板优先，其次停止）。
              guard harness.displayedIsRunning else { return .ignored }
              harness.stop()
              return .handled
            }
            .frame(height: min(max(editorContentHeight + 2, 24), 140))
        }
        .frame(minHeight: 24)
        .overlay(alignment: .leading) {
          // Hidden while focused, not just while non-empty: IME marked text
          // (pinyin composition) never reaches the SwiftUI binding, so a
          // focused-empty placeholder would sit under the composition
          // underline text. Focus is the only reliable signal we have.
          // Vertically centered — the box is a single line when empty.
          if harness.draft.isEmpty && !editorFocused {
            Text(harness.displayedPlanActive ? "描述任务以生成计划" : "描述你想要构建的内容")
              .font(.system(.body, design: .rounded)).foregroundStyle(DSHTheme.inkFaint)
              .padding(.leading, 5).allowsHitTesting(false)
          }
        }
        if let image = harness.draftImage {
          HStack(spacing: 6) {
            Label(image.url.lastPathComponent, systemImage: "photo").font(.caption).foregroundStyle(DSHTheme.inkSoft).lineLimit(1)
            Button(action: { harness.draftImage = nil }) { Image(systemName: "xmark.circle.fill") }.buttonStyle(.dshGhost)
            Spacer()
          }
        }
        composerControls
      }
      .padding(DSHSpace.s3)
      .frame(maxWidth: .infinity, alignment: .leading)
      .dshCard(tint: DSHTheme.surface, radius: DSHRadius.lg)
    }.padding(DSHSpace.s5)
    // Any edit re-arms the palette: selection returns to the top hit and an
    // Esc dismissal lasts only until the user types again. Opening the menu
    // (the draft becoming a lone "/") also refreshes both catalogs so newly
    // installed skills appear without re-attaching the session.
    .onChange(of: harness.draft) { _, newValue in
      paletteSelection = 0
      paletteDismissed = false
      mentionSelection = 0
      mentionDismissed = false
      if newValue == "/" { harness.refreshSlashCatalog() }
      if newValue.hasSuffix("@") { harness.refreshAgentProfiles() }
    }
    }
  }

  @ViewBuilder private var composerControls: some View {
    if compactControls {
      VStack(alignment: .leading, spacing: DSHSpace.s2) {
        if harness.canUseRootSlashCatalog {
          ComposerModelMenu(compact: true)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        HStack(spacing: DSHSpace.s2) {
          composerAccessoryControls
          Spacer(minLength: DSHSpace.s1)
          composerSubmissionControls
        }
      }
    } else {
      HStack(spacing: DSHSpace.s3) {
        composerAccessoryControls
        Spacer()
        if harness.canUseRootSlashCatalog { ComposerModelMenu() }
        composerSubmissionControls
      }
    }
  }

  @ViewBuilder private var composerAccessoryControls: some View {
    Menu {
      if harness.canUseRootSlashCatalog {
        Button("进入计划模式", action: harness.enterPlanMode)
        Button("设定目标") { harness.draft = "/goal " }
        Divider()
        Button("重命名当前会话", action: harness.beginRenameCurrentSession)
        Button("创建会话分支", action: harness.forkCurrentSession)
        Button("归档当前会话", action: harness.archiveCurrentSession)
        Button("导出会话日志", action: harness.exportCurrentSessionLog)
        Button("查看归档会话") { harness.showArchivedSessions = true }
        Divider()
      }
      Button("新会话", action: harness.newSession)
      Button("打开工作区", action: harness.openWorkspace)
    } label: { Image(systemName: "ellipsis.circle") }
      .menuStyle(.borderlessButton).fixedSize().foregroundStyle(DSHTheme.inkSoft).help("更多操作")
    Button(action: harness.pickImage) { Image(systemName: "paperclip") }.buttonStyle(.borderless).foregroundStyle(DSHTheme.inkSoft).help("添加图片")
    PermissionMenu()
    voiceInputButton
  }

  private var voiceInputButton: some View {
    // Dictation streams live into the input box (partials replace from the
    // pre-dictation base); finalized commands reuse the existing routing.
    VoiceInputButton(
      onPartial: { partial in
        let currentTarget = VoiceComposerTarget(
          selectedSessionID: harness.selectedSessionID,
          executionTarget: harness.displayedExecutionTarget)
        guard voiceTarget == currentTarget else { return }
        if dictationBase == nil { dictationBase = harness.draft }
        let base = dictationBase ?? ""
        harness.draft = base + (base.isEmpty ? "" : " ") + partial
      },
      onCommit: { text, viaWake, route in
        voiceDiag("[voice] commit '\(text)' viaWake=\(viaWake) route=\(route == .dialog ? "dialog" : "background") autoSend=\(VoiceSettings.wakeAutoSend)")
        let base = dictationBase ?? harness.draft
        dictationBase = nil
        let currentTarget = VoiceComposerTarget(
          selectedSessionID: harness.selectedSessionID,
          executionTarget: harness.displayedExecutionTarget)
        let targetChanged = route == .dialog
          && voiceTarget != nil
          && voiceTarget != currentTarget
        voiceTarget = nil
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || VoiceSettings.isCancelCommand(text) {
          if !targetChanged { harness.draft = base }
          return
        }
        let action = targetChanged ? VoiceCommitAction.fillComposer : route.commitAction(
          viaWake: viaWake,
          autoSend: VoiceSettings.wakeAutoSend,
          canSubmit: harness.composerCanSubmit,
          canQueue: harness.displayedIsRunning && harness.composerAgentProfileID == nil
        )
        if targetChanged {
          harness.status = "听写期间会话已切换，语音结果已保留在输入框"
        }
        switch action {
        case .fillComposer:
          if targetChanged {
            let current = harness.draft
            harness.draft = current + (current.isEmpty ? "" : " ") + text
          } else {
            harness.draft = base + (base.isEmpty ? "" : " ") + text
          }
        case .submitCurrent:
          harness.draft = base + (base.isEmpty ? "" : " ") + text
          harness.submitComposer()
        case .queueCurrent:
          harness.draft = base + (base.isEmpty ? "" : " ") + text
          harness.queueDraft()
        case .dispatchBackground:
          harness.draft = base
          harness.dispatchVoiceTask(text)
        }
      })
      // dialog 路由听写开始：把焦点交给输入框，让语音落进正在输入的位置。
      .onChange(of: voiceFocus.requestID) { _, _ in
        voiceTarget = VoiceComposerTarget(
          selectedSessionID: harness.selectedSessionID,
          executionTarget: harness.displayedExecutionTarget)
        editorFocused = true
      }
  }

  @ViewBuilder private var composerSubmissionControls: some View {
    if harness.displayedIsRunning {
      Button(action: harness.stop) { Image(systemName: "stop.fill").font(.system(size: 13)) }
        .buttonStyle(.dshSecondary).help("停止")
      if harness.composerAgentProfileID == nil {
        if harness.activeSubagentAddress == nil {
          Button(action: harness.steerDraft) { Image(systemName: "arrow.turn.down.right").font(.system(size: 13, weight: .semibold)) }
            .buttonStyle(.dshPrimary)
            .disabled(!harness.canSubmitRunningDraft)
            .help("插话发送：追加到当前轮")
        }
        Button(action: harness.queueDraft) { Image(systemName: "tray.and.arrow.down") }
          .buttonStyle(.dshSecondary)
          .disabled(!harness.canSubmitRunningDraft)
          .help("排队发送：本轮结束后自动发送")
      }
    } else if harness.selectedComposerAgentProfile != nil {
      Button(action: harness.submitComposer) { Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold)) }
        .buttonStyle(.dshPrimary).disabled(!harness.composerCanSubmit)
        .help("派发 Agent Batch")
    } else {
      Button(action: harness.submitComposer) { Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold)) }
        .buttonStyle(.dshPrimary).disabled(!harness.composerCanSubmit)
        .help(AppPrefs.enterToSend ? "发送（回车）" : "发送（⌘回车）")
    }
  }

  /// True while an input method (Chinese pinyin, etc.) holds an active
  /// composition in the focused text view. Enter during composition must
  /// confirm the candidate, not send the draft — onKeyPress(.return)
  /// otherwise fires before the IME consumes the key.
  private var editorHasMarkedText: Bool {
    (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true
  }

  private func pickMentionProfile(_ profile: DSHAgentProfile) {
    harness.selectComposerAgentProfile(profile, replacing: mentionQuery?.range)
    mentionSelection = 0
    mentionDismissed = true
  }
}

/// The composer-docked model/reasoning picker — the only in-app place a
/// model change actually reaches the Host (`selectCurrentModel` posts
/// `session.selectModel`). Options are read live from `harness.availableModels`
/// (`llm.models`'s groups, keyed by real provider id, e.g. "deepseek-official")
/// rather than a hardcoded relay/deepseek pair, so a tap always names a
/// provider id the catalog actually has.
private struct ComposerModelMenu: View {
  @EnvironmentObject var harness: HarnessController
  var compact = false
  var body: some View {
    Menu {
      if harness.availableModels.isEmpty {
        Text("尚未读到 Host 模型目录")
        Button("刷新模型目录", action: harness.refreshModelConfiguration)
      } else {
        ForEach(harness.availableModels) { group in
          Menu(group.nativeDisplayName) {
            ForEach(group.models) { model in
              Button(action: { harness.selectCurrentModel(provider: group.id, model: model.id) }) {
                if harness.provider == group.id && harness.model == model.id { Label(model.name, systemImage: "checkmark") }
                else { Text(model.name) }
              }
            }
          }
        }
        // Effort rows come from the selected model's adapter-advertised
        // levels, mirroring the upstream web composer: a fixed off/high/max
        // list offered levels the adapter would reject outright
        // (hand-declared relay models advertise none at all). No metadata →
        // no effort submenu, matching "an adapter without reasoning metadata
        // leaves the Effort row absent" in the model-selection contract.
        if let reasoning = harness.currentModelEntry?.reasoning {
          Divider()
          Menu("推理强度") {
            ForEach(reasoning.efforts) { effort in
              Button(action: { harness.selectCurrentModel(provider: harness.provider, model: harness.model, reasoning: effort.id) }) {
                if harness.reasoningEffort == effort.id { Label(effort.name, systemImage: "checkmark") }
                else { Text(effort.name) }
              }
            }
          }
        }
      }
    } label: {
      Text(harness.currentModelLabel)
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundStyle(DSHTheme.inkFaint)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .menuStyle(.borderlessButton)
    .fixedSize(horizontal: !compact, vertical: true)
    // `/model` 的落点：同一目录的 popover 形态（Menu 无法编程打开）。
    .popover(isPresented: $harness.showModelPicker, arrowEdge: .top) { ModelPickerPanel().environmentObject(harness) }
  }
}

/// Compact live-session figures from the Host's projection pushes: context
/// occupancy vs window, cumulative token usage, and turn/step counts. Hidden
/// entirely once none of the three have data yet (fresh session).
private struct StatusStrip: View {
  @EnvironmentObject var harness: HarnessController
  var body: some View {
    if harness.contextPressure != nil || harness.tokenUsage != nil || (harness.sessionStats?.turns ?? 0) > 0 {
      HStack(spacing: DSHSpace.s3) {
        if let pressure = harness.contextPressure, let occupied = pressure.projectedTokens ?? pressure.pressureTokens {
          Text("上下文 \(Self.compact(occupied))\(pressure.contextWindow.map { "/\(Self.compact($0))" } ?? "")")
            .foregroundStyle(pressure.contextWindow.map { Double(occupied) > Double($0) * 0.8 } == true ? DSHTheme.coral : DSHTheme.inkFaint)
            .help("下一次请求的预计上下文占用 / 模型窗口")
        }
        if let usage = harness.tokenUsage {
          Text("↑\(Self.compact(usage.totalInputTokens)) ↓\(Self.compact(usage.outputTokens))")
            .foregroundStyle(DSHTheme.inkFaint)
            .help("会话累计 token：输入（含缓存读写）↑ / 输出 ↓")
          if usage.totalInputTokens > 0 {
            Text("命中 \(Int((Double(usage.cacheReadTokens) / Double(usage.totalInputTokens) * 100).rounded()))%")
              .foregroundStyle(DSHTheme.inkFaint)
              .help("提示缓存命中率：缓存读 \(Self.compact(usage.cacheReadTokens)) / 总输入 \(Self.compact(usage.totalInputTokens))")
          }
        }
        if let stats = harness.sessionStats, stats.turns > 0 {
          Text("\(stats.turns) 轮 · \(stats.steps) 步")
            .foregroundStyle(DSHTheme.inkFaint)
            .help("整个会话的回合与步骤计数（LLM \(Int(stats.llmMs / 1000))s · 工具 \(Int(stats.toolMs / 1000))s）")
        }
      }
      .font(.system(size: 10.5, design: .monospaced))
    }
  }

  private static func compact(_ value: Int) -> String {
    value >= 10_000 ? String(format: "%.0fk", Double(value) / 1000) : value >= 1000 ? String(format: "%.1fk", Double(value) / 1000) : "\(value)"
  }
}
