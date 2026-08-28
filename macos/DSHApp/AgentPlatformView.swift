import SwiftUI

struct DSHAgentMentionQuery {
  let range: Range<String.Index>
  let query: String
}

enum DSHAgentMentionMatcher {
  static func query(in draft: String) -> DSHAgentMentionQuery? {
    guard !draft.isEmpty else { return nil }
    var start = draft.endIndex
    while start > draft.startIndex {
      let previous = draft.index(before: start)
      if draft[previous].isWhitespace { break }
      start = previous
    }
    let token = draft[start..<draft.endIndex]
    guard token.first == "@", !token.dropFirst().contains("@") else { return nil }
    return DSHAgentMentionQuery(range: start..<draft.endIndex, query: String(token.dropFirst()).lowercased())
  }

  static func profiles(_ profiles: [DSHAgentProfile], matching query: String) -> [DSHAgentProfile] {
    profiles.filter {
      query.isEmpty
        || $0.mention.lowercased().hasPrefix(query)
        || $0.name.lowercased().contains(query)
    }
  }
}

struct AgentProfilePalette: View {
  let profiles: [DSHAgentProfile]
  let selection: Int
  let onPick: (DSHAgentProfile) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s1) {
      Text("Agent Profile").dshSectionLabel().padding(.horizontal, DSHSpace.s2)
      ForEach(Array(profiles.prefix(7).enumerated()), id: \.element.id) { index, profile in
        Button(action: { onPick(profile) }) {
          HStack(spacing: DSHSpace.s2) {
            Image(systemName: "person.crop.circle.badge.gearshape")
              .foregroundStyle(index == selection ? DSHTheme.accent : DSHTheme.inkFaint)
            VStack(alignment: .leading, spacing: 1) {
              Text(profile.name).font(.caption.weight(.medium)).foregroundStyle(DSHTheme.ink)
              Text("@\(profile.mention) · \(profile.defaultMode.label) · \(profile.enabledAdapterCount) 个 Runtime")
                .font(.caption2).foregroundStyle(DSHTheme.inkFaint).lineLimit(1)
            }
            Spacer()
          }
          .padding(.horizontal, DSHSpace.s2).padding(.vertical, 5)
          .background(index == selection ? DSHTheme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: DSHRadius.sm))
        }
        .buttonStyle(.plain)
      }
    }
    .padding(DSHSpace.s2)
    .dshCard(tint: DSHTheme.surfaceTint, radius: DSHRadius.md)
  }
}

struct AgentComposerSelectionBar: View {
  @EnvironmentObject private var harness: HarnessController
  let profile: DSHAgentProfile

  var body: some View {
    HStack(spacing: DSHSpace.s2) {
      Label("@\(profile.mention)", systemImage: "person.crop.circle.badge.gearshape")
        .font(.caption.weight(.medium)).foregroundStyle(DSHTheme.ink)
      Menu(harness.composerAgentMode.label) {
        ForEach(DSHAgentMode.allCases) { mode in
          Button(action: { harness.composerAgentMode = mode }) {
            if harness.composerAgentMode == mode { Label(mode.label, systemImage: "checkmark") }
            else { Text(mode.label) }
          }
        }
      }
      .menuStyle(.borderlessButton).fixedSize()
      Menu(harness.composerAgentIntegrationPolicy.label) {
        ForEach(DSHAgentIntegrationPolicy.allCases) { policy in
          Button(action: { harness.composerAgentIntegrationPolicy = policy }) {
            if harness.composerAgentIntegrationPolicy == policy { Label(policy.label, systemImage: "checkmark") }
            else { Text(policy.label) }
          }
        }
      }
      .menuStyle(.borderlessButton).fixedSize()
      Text("\(profile.enabledAdapterCount) 个成员").font(.caption2).foregroundStyle(DSHTheme.inkFaint)
      Spacer()
      Button(action: harness.clearComposerAgentProfile) { Image(systemName: "xmark.circle.fill") }
        .buttonStyle(.dshGhost).help("移除 Agent Profile")
    }
    .padding(.horizontal, DSHSpace.s2).padding(.vertical, 5)
    .background(DSHTheme.accentSoft, in: RoundedRectangle(cornerRadius: DSHRadius.sm))
  }
}

struct AgentPlatformProfilesView: View {
  @EnvironmentObject private var harness: HarnessController
  @State private var removeTarget: DSHAgentProfile?

  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s3) {
      HStack {
        Text("Agent Profile").dshSectionLabel()
        Spacer()
        Button(action: harness.refreshAgentPlatform) { Image(systemName: "arrow.clockwise") }
          .buttonStyle(.dshGhost).help("刷新")
        Button(action: { harness.editAgentProfile() }) { Image(systemName: "plus") }
          .buttonStyle(.dshPrimary).help("新建 Agent Profile")
      }

      runtimeSummary

      if harness.agentProfiles.isEmpty {
        Spacer()
        VStack(spacing: DSHSpace.s2) {
          Image(systemName: "person.3.sequence").font(.title2).foregroundStyle(DSHTheme.inkFaint)
          Text("还没有 Agent Profile").font(.caption).foregroundStyle(DSHTheme.inkFaint)
          Button("新建 Profile", action: { harness.editAgentProfile() }).buttonStyle(.dshPrimary)
        }.frame(maxWidth: .infinity)
        Spacer()
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: DSHSpace.s3) {
            ForEach(harness.agentProfiles) { profile in
              profileRow(profile)
            }
          }
          .padding(.bottom, DSHSpace.s2)
        }
        .dshThinScrollers()
      }
    }
    .confirmationDialog("删除 \(removeTarget?.name ?? "Profile")？", isPresented: Binding(
      get: { removeTarget != nil },
      set: { if !$0 { removeTarget = nil } })) {
        Button("删除", role: .destructive) {
          if let profile = removeTarget { harness.removeAgentProfile(profile) }
          removeTarget = nil
        }
        Button("取消", role: .cancel) { removeTarget = nil }
      } message: {
        Text("删除后不能新建或重试运行；历史 Batch、日志和 worktree 会保留配置快照。")
      }
  }

  private var runtimeSummary: some View {
    HStack(spacing: DSHSpace.s2) {
      ForEach(harness.agentRuntimeStatuses) { runtime in
        HStack(spacing: 4) {
          DSHStatusDot(kind: runtime.available ? .success : .failure, diameter: 6)
          Text(runtime.label).font(.caption2).foregroundStyle(DSHTheme.inkSoft).lineLimit(1)
        }
        .help(runtime.detail ?? runtime.version ?? runtime.label)
      }
      if harness.agentRuntimeStatuses.isEmpty {
        Text("尚未读到 Runtime 状态").font(.caption2).foregroundStyle(DSHTheme.inkFaint)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func profileRow(_ profile: DSHAgentProfile) -> some View {
    VStack(alignment: .leading, spacing: DSHSpace.s2) {
      HStack(alignment: .top, spacing: DSHSpace.s2) {
        VStack(alignment: .leading, spacing: 2) {
          Text(profile.name).font(.caption.weight(.semibold)).foregroundStyle(DSHTheme.ink)
          Text("@\(profile.mention)").font(.caption2.monospaced()).foregroundStyle(DSHTheme.inkFaint)
        }
        Spacer()
        Button(action: { harness.runAgentProfile(profile) }) { Image(systemName: "play.fill") }
          .buttonStyle(.dshGhost).help("手动运行")
        Button(action: { harness.editAgentProfile(profile) }) { Image(systemName: "pencil") }
          .buttonStyle(.dshGhost).help("编辑")
        Button(action: { removeTarget = profile }) { Image(systemName: "trash") }
          .buttonStyle(.dshGhost).foregroundStyle(DSHTheme.coral).help("删除")
      }
      if let description = profile.description, !description.isEmpty {
        Text(description).font(.caption2).foregroundStyle(DSHTheme.inkSoft).lineLimit(2)
      }
      HStack(spacing: DSHSpace.s1) {
        DSHBadge(text: profile.defaultMode.label, tone: profile.defaultMode == .execution ? .warm : .neutral)
        DSHBadge(text: profile.integrationPolicy.label, tone: profile.integrationPolicy == .auto ? .accent : .neutral)
        if profile.allowModelDispatch { DSHBadge(text: "允许模型派发", tone: .accent) }
      }
      Text(profile.adapters.filter(\.enabled).map(\.label).joined(separator: " · "))
        .font(.caption2).foregroundStyle(DSHTheme.inkFaint).lineLimit(2)
    }
    .padding(DSHSpace.s3)
    .dshCard(tint: DSHTheme.surface, radius: DSHRadius.md)
  }
}

struct AgentPlatformExecutionView: View {
  @EnvironmentObject private var harness: HarnessController
  @State private var discardContextID: String?
  @State private var discardRun: DSHAgentRun?

  var body: some View {
    if let run = harness.selectedAgentRun {
      runLog(run)
    } else {
      VStack(alignment: .leading, spacing: DSHSpace.s3) {
        NativeDashboard()
        HStack {
          Text("当前会话执行").dshSectionLabel()
          Spacer()
          Button(action: { harness.refreshAgentBatches() }) { Image(systemName: "arrow.clockwise") }
            .buttonStyle(.dshGhost).help("刷新执行")
        }
        if harness.hostCurrentSessionID == nil {
          Spacer()
          Text("发送消息或手动运行 Profile 后，这里会展示 Batch。")
            .font(.caption).foregroundStyle(DSHTheme.inkFaint).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
          Spacer()
        } else if harness.agentBatches.isEmpty {
          Spacer()
          VStack(spacing: DSHSpace.s2) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
              .font(.title2).foregroundStyle(DSHTheme.inkFaint)
            Text("当前会话还没有 Agent Batch").font(.caption).foregroundStyle(DSHTheme.inkFaint)
          }.frame(maxWidth: .infinity)
          Spacer()
        } else {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: DSHSpace.s3) {
              ForEach(harness.agentBatches) { batch in batchCard(batch) }
            }.padding(.bottom, DSHSpace.s2)
          }
          .dshThinScrollers()
        }
      }
      .confirmationDialog("丢弃这个执行上下文？", isPresented: Binding(
        get: { discardContextID != nil },
        set: { if !$0 { discardContextID = nil } })) {
          Button("丢弃并清理 worktree", role: .destructive) {
            if let contextId = discardContextID { harness.discardAgentContext(contextId) }
            discardContextID = nil
          }
          Button("取消", role: .cancel) { discardContextID = nil }
        } message: {
          Text("该 DSH execution context 累积的未采纳改动会被标记为已丢弃，下一次执行将创建新上下文。")
        }
      .confirmationDialog("丢弃 \(discardRun?.displayLabel ?? "成员") 的结果？", isPresented: Binding(
        get: { discardRun != nil },
        set: { if !$0 { discardRun = nil } })) {
          Button("丢弃并清理 worktree", role: .destructive) {
            if let run = discardRun { harness.discardAgentRun(run) }
            discardRun = nil
          }
          Button("取消", role: .cancel) { discardRun = nil }
        } message: {
          Text("该成员的日志和配置快照仍会保留，但隔离 worktree 及未采纳改动会被删除。")
        }
    }
  }

  private func batchCard(_ batch: DSHAgentBatch) -> some View {
    DisclosureGroup(isExpanded: Binding(
      get: { harness.selectedAgentBatchID == batch.id },
      set: { expanded in harness.selectedAgentBatchID = expanded ? batch.id : nil })) {
        VStack(alignment: .leading, spacing: DSHSpace.s2) {
          Text(batch.task).font(.caption).foregroundStyle(DSHTheme.inkSoft).lineLimit(3)
          if let initiator = batch.initiatorLabel {
            Text("发起者：\(initiator)").font(.caption2).foregroundStyle(DSHTheme.inkFaint)
          }
          if batch.recoveryBlocked == true {
            Label("旧运行缺少发起能力快照，仅保留日志与 worktree 供审阅；请重新派发后再整合。", systemImage: "exclamationmark.shield")
              .font(.caption2).foregroundStyle(DSHTheme.warm).fixedSize(horizontal: false, vertical: true)
          }
          profileSnapshot(batch)
          ForEach(batch.runs) { run in runRow(run, batch: batch) }
          if let summary = batch.summary, !summary.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
              Text("汇总").dshSectionLabel()
              Text(summary).font(.caption2).foregroundStyle(DSHTheme.inkSoft).textSelection(.enabled)
            }
            .padding(.top, DSHSpace.s1)
          }
          if let integration = batch.integrationSummary, !integration.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
              Text("整合结论").dshSectionLabel()
              Text(integration).font(.caption2).foregroundStyle(DSHTheme.inkSoft).textSelection(.enabled)
              if let tests = batch.integrationTestSummary, !tests.isEmpty {
                Label(tests, systemImage: "checkmark.seal")
                  .font(.caption2).foregroundStyle(DSHTheme.accent).textSelection(.enabled)
              }
            }
            .padding(.top, DSHSpace.s1)
          }
          if let error = batch.integrationError, !error.isEmpty {
            Label(error, systemImage: "exclamationmark.triangle.fill")
              .font(.caption2).foregroundStyle(DSHTheme.coral).textSelection(.enabled)
          }
          batchActions(batch)
        }
        .padding(.top, DSHSpace.s2)
      } label: {
        HStack(spacing: DSHSpace.s2) {
          DSHStatusDot(kind: statusDot(batch.status), diameter: 7)
          VStack(alignment: .leading, spacing: 1) {
            Text(batch.profileName).font(.caption.weight(.medium)).foregroundStyle(DSHTheme.ink).lineLimit(1)
            Text("\(batch.mode.label) · \(statusLabel(batch.status))")
              .font(.caption2).foregroundStyle(DSHTheme.inkFaint)
          }
          Spacer()
          Text("\(batch.runs.filter(\.isActive).count)/\(batch.runs.count)")
            .font(.caption2.monospaced()).foregroundStyle(DSHTheme.inkFaint)
        }
      }
    .padding(DSHSpace.s3)
    .dshCard(tint: batch.isActive ? DSHTheme.accentSoft : DSHTheme.surface, radius: DSHRadius.md)
  }

  private func runRow(_ run: DSHAgentRun, batch: DSHAgentBatch) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: DSHSpace.s2) {
        Image(systemName: statusIcon(run.status)).font(.caption2).foregroundStyle(statusColor(run.status))
        Text(run.displayLabel).font(.caption).foregroundStyle(DSHTheme.ink).lineLimit(1)
        Spacer()
        Text(statusLabel(run.status)).font(.caption2).foregroundStyle(DSHTheme.inkFaint)
        Button(action: { harness.loadAgentRunLog(run) }) { Image(systemName: "doc.text.magnifyingglass") }
          .buttonStyle(.dshGhost).help("查看日志")
      }
      if let error = run.error, !error.isEmpty {
        Text(error).font(.caption2).foregroundStyle(DSHTheme.coral).lineLimit(2)
      } else if let output = run.output, !output.isEmpty {
        Text(output).font(.caption2).foregroundStyle(DSHTheme.inkSoft).lineLimit(2)
      }
      if let runtimeProfile = run.runtimeProfileSnapshot,
         runtimeProfile.revision != batch.profileSnapshot?.revision {
        Text("复用 DSH 上下文配置 rev \(runtimeProfile.revision ?? 0)")
          .font(.caption2).foregroundStyle(DSHTheme.warm)
      }
      HStack(spacing: DSHSpace.s1) {
        if run.worktreePath != nil, run.workspaceCleaned != true {
          Button(action: { harness.openAgentWorkspace(run) }) {
            Label("worktree", systemImage: "folder")
          }.buttonStyle(.dshSecondary)
        }
        if DSHAgentPlatformPolicy.canRetry(
          profileID: batch.profileId,
          profileDeleted: batch.profileDeleted == true,
          activeProfileIDs: Set(harness.agentProfiles.map(\.id)),
          runStatus: run.status,
          retryable: run.retryable
        ) {
          Button(action: { harness.retryAgentRun(run) }) {
            Image(systemName: "arrow.clockwise")
          }.buttonStyle(.dshSecondary).help("重试成员")
        }
        if batch.mode == .execution,
           DSHAgentPlatformPolicy.canDiscardResult(
             integrationState: batch.integrationState,
             runIsActive: run.isActive,
             workspaceCleaned: run.workspaceCleaned == true) {
          Button(action: {
            if run.adapter == "dsh", let contextId = run.contextId { discardContextID = contextId }
            else { discardRun = run }
          }) {
            Image(systemName: "trash")
          }.buttonStyle(.dshSecondary).foregroundStyle(DSHTheme.coral).help("丢弃成员结果并清理 worktree")
        }
        if run.workspaceCleaned == true {
          DSHBadge(text: run.workspaceOutcome == "adopted" ? "已采纳并清理" : "已丢弃并清理", tone: run.workspaceOutcome == "adopted" ? .accent : .neutral)
        }
      }
    }
    .padding(.vertical, DSHSpace.s1)
  }

  @ViewBuilder private func batchActions(_ batch: DSHAgentBatch) -> some View {
    HStack(spacing: DSHSpace.s2) {
      if batch.isActive {
        Button(action: { harness.stopAgentBatch(batch) }) {
          Label("停止", systemImage: "stop.fill")
        }.buttonStyle(.dshSecondary).foregroundStyle(DSHTheme.coral)
      } else if DSHAgentPlatformPolicy.canRequestIntegration(
        policy: batch.integrationPolicy.rawValue,
        state: batch.integrationState,
        isActive: batch.isActive,
        hasEligibleMember: batch.runs.contains(where: \.isIntegrationEligible),
        requestInFlight: harness.agentIntegrationRequests.contains(batch.id),
        recoveryBlocked: batch.recoveryBlocked == true
      ) {
        Button(action: { harness.requestAgentIntegration(batch) }) {
          Label("交给主 Agent 整合", systemImage: "arrow.triangle.merge")
        }.buttonStyle(.dshPrimary)
      }
      if batch.mode == .analysis,
         DSHAgentPlatformPolicy.canDiscardResult(
           integrationState: batch.integrationState,
           runIsActive: batch.isActive,
           workspaceCleaned: false),
         batch.runs.contains(where: { $0.adapter == "dsh" && $0.contextId != nil }) {
        Button(action: { harness.resetAgentAnalysisContext(batch) }) {
          Image(systemName: "arrow.counterclockwise")
        }.buttonStyle(.dshSecondary).help("重置 DSH 分析上下文")
      }
      if let state = batch.integrationState, !state.isEmpty {
        DSHBadge(text: integrationLabel(state), tone: state == "adopted" ? .accent : .neutral)
      }
    }
  }

  private func runLog(_ run: DSHAgentRun) -> some View {
    VStack(alignment: .leading, spacing: DSHSpace.s3) {
      HStack {
        Button(action: harness.closeAgentRunLog) { Image(systemName: "chevron.left") }
          .buttonStyle(.dshGhost).help("返回 Batch")
        VStack(alignment: .leading, spacing: 1) {
          Text(run.displayLabel).font(.caption.weight(.semibold)).foregroundStyle(DSHTheme.ink)
          Text(statusLabel(run.status)).font(.caption2).foregroundStyle(statusColor(run.status))
        }
        Spacer()
        if run.worktreePath != nil, run.workspaceCleaned != true {
          Button(action: { harness.openAgentWorkspace(run) }) { Image(systemName: "folder") }
            .buttonStyle(.dshGhost).help("打开 worktree")
        }
      }
      if let inspection = harness.selectedAgentWorkspace {
        VStack(alignment: .leading, spacing: DSHSpace.s2) {
          if inspection.workspaceCleaned == true {
            Label(
              inspection.workspaceOutcome == "adopted" ? "worktree 已在采纳后清理" : "worktree 已丢弃并清理",
              systemImage: "archivebox")
              .font(.caption).foregroundStyle(DSHTheme.inkFaint)
          } else {
            if let path = inspection.worktreePath { Text(path).font(.caption2.monospaced()).foregroundStyle(DSHTheme.inkFaint).textSelection(.enabled) }
            if let diff = inspection.diffSummary, !diff.isEmpty {
              Text(diff).font(.system(size: 11, design: .monospaced)).foregroundStyle(DSHTheme.inkSoft).textSelection(.enabled)
            }
            if let files = inspection.files, !files.isEmpty {
              Text(files.joined(separator: "\n")).font(.system(size: 11, design: .monospaced)).foregroundStyle(DSHTheme.inkFaint).textSelection(.enabled)
            }
          }
          if let tests = inspection.testSummary, !tests.isEmpty {
            Label(tests, systemImage: "checkmark.seal").font(.caption2).foregroundStyle(DSHTheme.accent).textSelection(.enabled)
          }
        }
        .padding(DSHSpace.s2)
        .dshCard(tint: DSHTheme.surfaceTint, radius: DSHRadius.sm)
      }
      if harness.agentRunLogHasMore, let first = harness.selectedAgentRunLog.first {
        Button("载入更早日志") { harness.loadAgentRunLog(run, before: first.seq) }
          .buttonStyle(.dshSecondary).frame(maxWidth: .infinity)
      }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: DSHSpace.s2) {
          ForEach(harness.selectedAgentRunLog) { entry in
            VStack(alignment: .leading, spacing: 2) {
              HStack {
                Text(entry.stream ?? "log").font(.caption2.monospaced()).foregroundStyle(DSHTheme.inkFaint)
                Spacer()
                Text(logTime(entry.time)).font(.caption2.monospaced()).foregroundStyle(DSHTheme.inkFaint)
              }
              Text(entry.text).font(.system(size: 11, design: .monospaced)).foregroundStyle(DSHTheme.inkSoft)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          if harness.selectedAgentRunLog.isEmpty {
            Text("暂无日志").font(.caption).foregroundStyle(DSHTheme.inkFaint).frame(maxWidth: .infinity)
          }
        }
      }
      .dshThinScrollers()
    }
  }

  private func statusDot(_ status: String) -> DSHStatusDot.Kind {
    if ["running", "queued", "preparing", "stopping"].contains(status) { return .live }
    if ["succeeded", "completed"].contains(status) { return .success }
    if ["failed", "interrupted"].contains(status) { return .failure }
    return .idle
  }

  @ViewBuilder private func profileSnapshot(_ batch: DSHAgentBatch) -> some View {
    if let profile = batch.profileSnapshot {
      VStack(alignment: .leading, spacing: 3) {
        HStack {
          Text("运行配置").dshSectionLabel()
          Spacer()
          if batch.profileDeleted == true { DSHBadge(text: "Profile 已删除", tone: .warm) }
        }
        Text("@\(profile.mention) · \(profile.defaultMode.label) · \(profile.integrationPolicy.label)")
          .font(.caption2).foregroundStyle(DSHTheme.inkFaint)
        let inherited = [
          batch.sourceAgentPreset.map { "Preset \($0)" },
          batch.sourceAgentOptions?.modelLabel.map { "模型 \($0)" },
          batch.sandboxMode.map { "Sandbox \($0)" },
          batch.sourceToolAllowlist.map { "\($0.count) 个继承工具" },
        ].compactMap { $0 }
        if !inherited.isEmpty {
          Text(inherited.joined(separator: " · "))
            .font(.caption2).foregroundStyle(DSHTheme.inkFaint).lineLimit(2)
        }
        if let sourceCwd = batch.sourceCwd, !sourceCwd.isEmpty {
          Text(sourceCwd).font(.caption2.monospaced()).foregroundStyle(DSHTheme.inkFaint)
            .lineLimit(1).truncationMode(.middle).help(sourceCwd)
        }
        if let persona = profile.persona, !persona.isEmpty {
          Text(persona).font(.caption2).foregroundStyle(DSHTheme.inkSoft).lineLimit(4)
        }
        ForEach(profile.adapters.filter(\.enabled)) { adapter in
          VStack(alignment: .leading, spacing: 1) {
            Text(adapter.label + (adapter.model.map { " · \($0)" } ?? ""))
              .font(.caption2.weight(.medium)).foregroundStyle(DSHTheme.ink)
            let allow = adapter.toolAllowlist?.joined(separator: ", ")
            let deny = adapter.toolDenylist?.joined(separator: ", ")
            if allow != nil || deny != nil {
              Text([
                allow.map { "允许：\($0)" },
                deny.map { "禁用：\($0)" },
              ].compactMap { $0 }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(DSHTheme.inkFaint).lineLimit(3)
            }
          }
        }
      }
      .padding(DSHSpace.s2)
      .padding(.top, DSHSpace.s1)
    }
  }

  private func statusIcon(_ status: String) -> String {
    switch status {
    case "running", "preparing": "circle.dotted"
    case "queued": "clock"
    case "succeeded", "completed": "checkmark.circle.fill"
    case "failed": "xmark.circle.fill"
    case "interrupted": "bolt.slash.circle.fill"
    case "cancelled": "minus.circle.fill"
    default: "circle"
    }
  }

  private func statusColor(_ status: String) -> Color {
    switch statusDot(status) {
    case .live: DSHTheme.accentBright
    case .success: DSHTheme.accent
    case .failure: DSHTheme.coral
    default: DSHTheme.inkFaint
    }
  }

  private func statusLabel(_ status: String) -> String {
    switch status {
    case "queued": "等待中"
    case "preparing": "准备中"
    case "running": "运行中"
    case "stopping": "停止中"
    case "succeeded", "completed": "已完成"
    case "failed": "失败"
    case "cancelled": "已取消"
    case "interrupted": "已中断"
    case "partial": "部分完成"
    default: status
    }
  }

  private func integrationLabel(_ state: String) -> String {
    switch state {
    case "manualPending": "待整合"
    case "requested": "已请求整合"
    case "integrating": "整合中"
    case "adopted": "已采纳"
    case "partiallyAdopted": "部分采纳"
    case "discarded": "已丢弃"
    case "partiallyDiscarded": "部分丢弃"
    case "failed": "整合失败"
    default: state
    }
  }

  private func logTime(_ value: Double) -> String {
    Date(timeIntervalSince1970: value / 1000).formatted(date: .omitted, time: .standard)
  }
}

struct AgentProfileEditorSheet: View {
  @EnvironmentObject private var harness: HarnessController
  @Environment(\.dismiss) private var dismiss
  @State private var draft: DSHAgentProfileDraft
  @State private var toolAllowDrafts: [String: String]
  @State private var toolDenyDrafts: [String: String]

  init(profile: DSHAgentProfile?) {
    let initial = DSHAgentProfileDraft(profile: profile)
    _draft = State(initialValue: initial)
    _toolAllowDrafts = State(initialValue: Dictionary(
      uniqueKeysWithValues: initial.adapters.map { ($0.runtime, $0.toolAllowlist?.joined(separator: ", ") ?? "") }))
    _toolDenyDrafts = State(initialValue: Dictionary(
      uniqueKeysWithValues: initial.adapters.map { ($0.runtime, $0.toolDenylist?.joined(separator: ", ") ?? "") }))
  }

  private var normalizedMention: String {
    draft.mention.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
  }
  private var canSave: Bool {
    !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !normalizedMention.isEmpty
      && draft.adapters.contains(where: \.enabled)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s4) {
      HStack {
        Text(draft.id == nil ? "新建 Agent Profile" : "编辑 Agent Profile")
          .font(.system(size: 18, weight: .semibold)).foregroundStyle(DSHTheme.ink)
        Spacer()
        Button(action: { dismiss(); harness.showAgentProfileEditor = false }) { Image(systemName: "xmark") }
          .buttonStyle(.dshGhost)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: DSHSpace.s5) {
          identityFields
          behaviorFields
          runtimeFields
        }
        .padding(.trailing, DSHSpace.s2)
      }
      .scrollIndicators(.visible, axes: .vertical)
      HStack {
        Spacer()
        Button("取消") { dismiss(); harness.showAgentProfileEditor = false }.buttonStyle(.dshSecondary)
        Button("保存") {
          var submitted = normalizedDraft()
          submitted.mention = normalizedMention
          harness.saveAgentProfile(submitted)
        }
        .buttonStyle(.dshPrimary).disabled(!canSave)
      }
    }
    .padding(DSHSpace.s5)
    .frame(width: 760, height: 640)
    .background(DSHTheme.surface)
  }

  private var identityFields: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s3) {
      Text("身份").dshSectionLabel()
      HStack(spacing: DSHSpace.s3) {
        TextField("名称", text: $draft.name).dshField()
        TextField("@mention", text: $draft.mention).dshField()
      }
      TextField("简短说明", text: optionalBinding(\.description)).dshField()
      TextField("默认任务（手动运行时可修改）", text: optionalBinding(\.defaultTask)).dshField()
      VStack(alignment: .leading, spacing: DSHSpace.s1) {
        Text("Persona").font(.caption).foregroundStyle(DSHTheme.inkFaint)
        TextEditor(text: optionalBinding(\.persona))
          .font(.body).scrollContentBackground(.hidden).frame(minHeight: 92)
          .padding(DSHSpace.s2).dshCard(tint: DSHTheme.fieldFill, radius: DSHRadius.sm)
          .overlay { RoundedRectangle(cornerRadius: DSHRadius.sm).strokeBorder(DSHTheme.fieldStroke) }
      }
    }
  }

  private var behaviorFields: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s3) {
      Text("默认行为").dshSectionLabel()
      HStack {
        Picker("模式", selection: $draft.defaultMode) {
          ForEach(DSHAgentMode.allCases) { Text($0.label).tag($0) }
        }
        Picker("整合", selection: $draft.integrationPolicy) {
          ForEach(DSHAgentIntegrationPolicy.allCases) { Text($0.label).tag($0) }
        }
        Spacer()
      }
      Toggle("允许主 Agent / Subagent 主动派发", isOn: $draft.allowModelDispatch)
        .toggleStyle(.switch).controlSize(.small).tint(DSHTheme.accent)
    }
  }

  private var runtimeFields: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s3) {
      HStack {
        Text("Runtime").dshSectionLabel()
        Spacer()
        Text("至少启用一个").font(.caption2).foregroundStyle(DSHTheme.inkFaint)
      }
      ForEach(runtimeRows, id: \.runtime) { runtime in
        VStack(alignment: .leading, spacing: DSHSpace.s2) {
          HStack {
            Toggle(isOn: runtimeEnabledBinding(runtime.runtime)) {
              HStack(spacing: DSHSpace.s2) {
                DSHStatusDot(kind: runtime.available ? .success : .failure, diameter: 6)
                Text(runtime.label).font(.caption.weight(.medium)).foregroundStyle(DSHTheme.ink)
              }
            }
            .toggleStyle(.switch).controlSize(.small).tint(DSHTheme.accent)
            Spacer()
            if !runtime.analysisSupported { DSHBadge(text: "不支持分析", tone: .warm) }
            if !runtime.executionSupported { DSHBadge(text: "不支持执行", tone: .warm) }
          }
          if isRuntimeEnabled(runtime.runtime) {
            if runtime.runtime == "zcode" {
              Text("ZCode 当前 headless CLI 不支持模型覆盖")
                .font(.caption2).foregroundStyle(DSHTheme.inkFaint)
            } else {
              TextField("模型覆盖（可选）", text: runtimeModelBinding(runtime.runtime)).dshField()
            }
            if runtime.runtime == "codex" {
              Text("Codex 当前 CLI 不支持按工具过滤；分析模式会直接标记不支持")
                .font(.caption2).foregroundStyle(DSHTheme.inkFaint)
            } else {
              TextField("允许工具，逗号分隔（留空为继承）", text: runtimeToolDraftBinding(runtime.runtime, allow: true)).dshField()
              TextField("禁用工具，逗号分隔", text: runtimeToolDraftBinding(runtime.runtime, allow: false)).dshField()
            }
          }
          if let detail = runtime.detail, !detail.isEmpty {
            Text(detail).font(.caption2).foregroundStyle(DSHTheme.inkFaint).lineLimit(2)
          }
        }
        .padding(.vertical, DSHSpace.s1)
      }
    }
  }

  private var runtimeRows: [DSHAgentRuntimeStatus] {
    var rows = harness.agentRuntimeStatuses
    let known = Set(rows.map(\.runtime))
    for adapter in draft.adapters where !known.contains(adapter.runtime) {
      rows.append(DSHAgentRuntimeStatus(
        runtime: adapter.runtime,
        displayName: adapter.displayName,
        available: false,
        version: nil,
        detail: "当前 Host 未检测到此 Runtime",
        analysisSupported: adapter.analysisSupported ?? false,
        executionSupported: adapter.executionSupported ?? false))
    }
    return rows
  }

  private func optionalBinding(_ keyPath: WritableKeyPath<DSHAgentProfileDraft, String?>) -> Binding<String> {
    Binding(
      get: { draft[keyPath: keyPath] ?? "" },
      set: { draft[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
  }

  private func isRuntimeEnabled(_ runtime: String) -> Bool {
    draft.adapters.first(where: { $0.runtime == runtime })?.enabled == true
  }

  private func runtimeEnabledBinding(_ runtime: String) -> Binding<Bool> {
    Binding(
      get: { isRuntimeEnabled(runtime) },
      set: { enabled in
        var adapters = draft.adapters
        if let index = adapters.firstIndex(where: { $0.runtime == runtime }) {
          adapters[index].enabled = enabled
        } else if let status = runtimeRows.first(where: { $0.runtime == runtime }) {
          adapters.append(DSHAgentAdapterBinding(
            id: runtime,
            runtime: runtime,
            enabled: enabled,
            displayName: status.label,
            model: nil,
            toolAllowlist: nil,
            toolDenylist: nil,
            analysisSupported: status.analysisSupported,
            executionSupported: status.executionSupported,
            config: nil))
          toolAllowDrafts[runtime] = ""
          toolDenyDrafts[runtime] = ""
        }
        draft.adapters = adapters
      })
  }

  private func runtimeModelBinding(_ runtime: String) -> Binding<String> {
    Binding(
      get: { draft.adapters.first(where: { $0.runtime == runtime })?.model ?? "" },
      set: { value in
        var adapters = draft.adapters
        guard let index = adapters.firstIndex(where: { $0.runtime == runtime }) else { return }
        adapters[index].model = value.isEmpty ? nil : value
        draft.adapters = adapters
      })
  }

  private func runtimeToolDraftBinding(_ runtime: String, allow: Bool) -> Binding<String> {
    Binding(
      get: { allow ? toolAllowDrafts[runtime, default: ""] : toolDenyDrafts[runtime, default: ""] },
      set: { value in
        if allow { toolAllowDrafts[runtime] = value }
        else { toolDenyDrafts[runtime] = value }
      })
  }

  private func normalizedDraft() -> DSHAgentProfileDraft {
    var submitted = draft
    for index in submitted.adapters.indices {
      let runtime = submitted.adapters[index].runtime
      if runtime == "codex" {
        submitted.adapters[index].toolAllowlist = nil
        submitted.adapters[index].toolDenylist = nil
      } else {
        submitted.adapters[index].toolAllowlist = parseToolList(toolAllowDrafts[runtime] ?? "")
        submitted.adapters[index].toolDenylist = parseToolList(toolDenyDrafts[runtime] ?? "")
      }
      if runtime == "zcode" { submitted.adapters[index].model = nil }
    }
    return submitted
  }

  private func parseToolList(_ value: String) -> [String]? {
    let items = value.split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return items.isEmpty ? nil : items
  }
}

struct AgentManualRunSheet: View {
  @EnvironmentObject private var harness: HarnessController
  @Environment(\.dismiss) private var dismiss
  let profile: DSHAgentProfile
  @State private var task = ""
  @State private var mode: DSHAgentMode
  @State private var policy: DSHAgentIntegrationPolicy
  @State private var submitting = false

  init(profile: DSHAgentProfile) {
    self.profile = profile
    _task = State(initialValue: profile.defaultTask ?? "")
    _mode = State(initialValue: profile.defaultMode)
    _policy = State(initialValue: profile.integrationPolicy)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s4) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("运行 \(profile.name)").font(.system(size: 18, weight: .semibold)).foregroundStyle(DSHTheme.ink)
          Text("@\(profile.mention) · \(profile.enabledAdapterCount) 个成员")
            .font(.caption).foregroundStyle(DSHTheme.inkFaint)
        }
        Spacer()
        Button(action: { dismiss() }) { Image(systemName: "xmark") }.buttonStyle(.dshGhost)
      }
      HStack {
        Picker("模式", selection: $mode) { ForEach(DSHAgentMode.allCases) { Text($0.label).tag($0) } }
        Picker("整合", selection: $policy) { ForEach(DSHAgentIntegrationPolicy.allCases) { Text($0.label).tag($0) } }
        Spacer()
      }
      TextEditor(text: $task)
        .font(.body).scrollContentBackground(.hidden)
        .padding(DSHSpace.s3).frame(minHeight: 180)
        .dshCard(tint: DSHTheme.fieldFill, radius: DSHRadius.md)
        .overlay { RoundedRectangle(cornerRadius: DSHRadius.md).strokeBorder(DSHTheme.fieldStroke) }
      HStack {
        Spacer()
        Button("取消") { dismiss() }.buttonStyle(.dshSecondary)
        Button("开始运行") {
          submitting = true
          harness.startAgentBatch(
            profile: profile,
            task: task,
            mode: mode,
            integrationPolicy: policy,
            source: .manual,
            accepted: { _ in dismiss() },
            failed: { _ in submitting = false })
        }
        .buttonStyle(.dshPrimary)
        .disabled(submitting || task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(DSHSpace.s5)
    .frame(width: 620, height: 430)
    .background(DSHTheme.surface)
  }
}
