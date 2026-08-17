import SwiftUI

/// Bottom composer: draft input, send/stop/queue controls, session-action menu,
/// and the reasoning-effort selector. Read-only when viewing a finished subagent
/// transcript (`harness.isViewingReadOnlySubagent`).
struct Composer: View {
  @EnvironmentObject var harness: HarnessController

  var body: some View {
    if harness.isViewingReadOnlySubagent {
      readOnlyBanner
    } else {
      composerBody
    }
  }

  // MARK: - Read-only banner

  private var readOnlyBanner: some View {
    Label("只读：此子代理已结束，历史不可续写。返回上一级可继续操作。", systemImage: "lock.fill")
      .font(.caption)
      .foregroundStyle(.orange)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)
      .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
      .padding(18)
  }

  // MARK: - Active composer

  private var composerBody: some View {
    VStack(spacing: 10) {
      statusRow
      QueueDockView()
      inputRow
      toolbarRow
    }
    .padding(18)
  }

  /// Plan-mode indicator, queued-message count, and the live status line.
  private var statusRow: some View {
    HStack(spacing: 10) {
      if harness.planMode {
        Button("计划模式 ×", action: harness.togglePlanMode)
          .buttonStyle(.bordered)
          .tint(.orange)
      }
      if !harness.queuedPrompts.isEmpty {
        Label("已排队 \(harness.queuedPrompts.count)", systemImage: "list.number")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Text(harness.status)
        .font(.caption)
        .foregroundStyle(harness.isRunning ? .blue : .secondary)
    }
  }

  /// The draft TextEditor plus its adjacent send / stop+queue controls.
  private var inputRow: some View {
    HStack(alignment: .bottom, spacing: 10) {
      TextEditor(text: $harness.draft)
        .font(.system(.body, design: .rounded))
        .frame(minHeight: 54, maxHeight: 140)
        .padding(7)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.secondary.opacity(0.25)))

      if harness.isRunning {
        VStack(spacing: 7) {
          Button("停止", action: harness.stop)
            .buttonStyle(.bordered)
          Button("排队", action: harness.queueDraft)
            .buttonStyle(.bordered)
            .disabled(harness.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      } else {
        Button("发送", action: harness.send)
          .buttonStyle(.borderedProminent)
          .disabled(!harness.canSend)
      }
    }
  }

  /// Attachment/session-action menu, the draft-image chip, placeholder copy,
  /// and the reasoning-effort selector.
  private var toolbarRow: some View {
    HStack(spacing: 10) {
      actionMenu
      if let image = harness.draftImage {
        draftImageChip(image)
      }
      Text(harness.planMode ? "描述任务以生成计划" : "描述你想要构建的内容")
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
      modelMenu
      reasoningMenu
    }
  }

  private var actionMenu: some View {
    Menu {
      Button("添加图片", action: harness.pickImage)
      Button("进入计划模式", action: harness.togglePlanMode)
      Button("重命名当前会话", action: harness.beginRenameCurrentSession)
      Button("创建会话分支", action: harness.forkCurrentSession)
      Button("归档当前会话", action: harness.archiveCurrentSession)
      Button("新会话", action: harness.newSession)
      Button("打开工作区", action: harness.openWorkspace)
    } label: {
      Image(systemName: "plus")
    }
  }

  private func draftImageChip(_ image: HarnessController.DraftImage) -> some View {
    HStack(spacing: 6) {
      Label(image.url.lastPathComponent, systemImage: "photo")
        .font(.caption)
        .lineLimit(1)
      Button(action: { harness.draftImage = nil }) {
        Image(systemName: "xmark.circle.fill")
      }
      .buttonStyle(.borderless)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(.secondary.opacity(0.08), in: Capsule())
  }

  /// Live model/provider switcher for the *current* session — lists whatever
  /// routes the Host actually reports for this session (`currentSessionModels`,
  /// refreshed on demand), including any DeepSeek-hosted groups, and applies a
  /// pick immediately via `selectCurrentModel`. This used to live in the
  /// conversation header; moved here so composer users always have a working
  /// model picker instead of the reasoning-effort menu's read-only label.
  private var modelMenu: some View {
    Menu {
      if let sessionModels = harness.currentSessionModels {
        if !sessionModels.routable {
          Text("当前会话没有可用模型路由")
        }
        ForEach(sessionModels.groups) { group in
          ForEach(group.models) { item in
            Button("\(group.name) / \(item.name)") {
              harness.selectCurrentModel(provider: group.id, model: item.id)
            }
          }
        }
        Divider()
        Button("刷新模型列表") { harness.refreshSessionModels() }
      } else {
        Button("加载模型列表") { harness.refreshSessionModels() }
      }
    } label: {
      Label(harness.model, systemImage: "brain")
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.secondary.opacity(0.08), in: Capsule())
    }
    .menuStyle(.borderlessButton)
    .onAppear { harness.refreshSessionModels() }
    .onChange(of: harness.hostCurrentSessionID) { _, _ in harness.refreshSessionModels() }
  }

  /// Reasoning-effort selector, styled as a compact pill per the "card, not
  /// line" grouping convention (DESIGN_SYSTEM.md section 1) applied to a
  /// small inline control. Shows only the effort level — provider/model
  /// already has its own pill (`modelMenu`), repeating them here just
  /// duplicated the same text twice in a row.
  private var reasoningMenu: some View {
    Menu {
      Button("关闭推理") {
        harness.reasoningEffort = "off"
        harness.selectCurrentModel(provider: harness.provider, model: harness.model, reasoning: "off")
      }
      Button("高") {
        harness.reasoningEffort = "high"
        harness.selectCurrentModel(provider: harness.provider, model: harness.model, reasoning: "high")
      }
      Button("最大") {
        harness.reasoningEffort = "max"
        harness.selectCurrentModel(provider: harness.provider, model: harness.model, reasoning: "max")
      }
    } label: {
      Label(reasoningEffortLabel, systemImage: "gauge")
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.secondary.opacity(0.08), in: Capsule())
    }
    .menuStyle(.borderlessButton)
  }

  private var reasoningEffortLabel: String {
    switch harness.reasoningEffort {
    case "off": "关闭推理"
    case "high": "推理：高"
    case "max": "推理：最大"
    default: harness.reasoningEffort
    }
  }
}
