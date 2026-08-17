import SwiftUI

// MARK: - ConversationHeader

struct ConversationHeader: View {
  @EnvironmentObject var harness: HarnessController

  /// The Host's live summary for the session currently shown. Used only to
  /// decide whether the preset control should be locked — see
  /// `presetLocked` below.
  private var currentSessionSummary: DSHSessionSummary? {
    harness.hostSessions.first { $0.id == harness.hostCurrentSessionID }
  }

  /// True once the Host has real presets to offer AND the displayed session
  /// already has turn history. In that state `selectCurrentPreset` would be
  /// rejected by the Host with `agent-preset-locked`, so per design system
  /// §8 the control must not stay clickable — it gets swapped for a locked
  /// label instead of letting the user hit the RPC error. The local,
  /// never-locked `harness.setPreset` path (used when `hostPresets` is
  /// empty) is untouched.
  private var presetLocked: Bool {
    guard !harness.hostPresets.isEmpty, let summary = currentSessionSummary else { return false }
    return summary.blank == false
  }

  /// Label shown while locked: the session's own recorded preset if the
  /// Host reported one, else the locally tracked preset.
  private var lockedPresetLabel: String {
    currentSessionSummary?.agentPreset ?? harness.preset.label
  }

  var body: some View {
    HStack(spacing: 10) {
      titleColumn
      Spacer()
      presetControl
      permissionControl
      detailsToggle
    }
    .padding(.horizontal, 22)
    .padding(.vertical, 12)
  }

  private var titleColumn: some View {
    VStack(alignment: .leading, spacing: 2) {
      if !harness.subagentPath.isEmpty {
        HStack(spacing: 6) {
          Button(action: harness.navigateUpSubagent) {
            Image(systemName: "chevron.left")
          }
          .buttonStyle(.borderless)
          .help("返回上一级")

          Text(harness.subagentPath.map(\.title).joined(separator: " › "))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }

      Text(harness.displayedSession?.title ?? "新会话")
        .font(.headline)

      Text(harness.workspace?.path ?? "选择工作区后开始")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
  }

  @ViewBuilder
  private var presetControl: some View {
    if presetLocked {
      Label(lockedPresetLabel, systemImage: "lock.fill")
        .font(.caption)
        .foregroundStyle(.orange)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.12), in: Capsule())
        .help("会话已开始运行，Agent Preset 无法再切换（Host 会拒绝：agent-preset-locked）")
    } else {
      Menu {
        if harness.hostPresets.isEmpty {
          ForEach(HarnessController.Preset.allCases) { preset in
            Button(preset.label) { harness.setPreset(preset) }
          }
        } else {
          ForEach(harness.hostPresets.filter { $0.broken == nil }) { preset in
            Button(preset.name ?? preset.id) { harness.selectCurrentPreset(preset.id) }
          }
        }
      } label: {
        Label(harness.preset.label, systemImage: "cpu")
          .headerPillStyle()
      }
      .menuStyle(.borderlessButton)
    }
  }

  private var permissionControl: some View {
    Menu {
      ForEach(HarnessController.PermissionMode.allCases) { mode in
        Button(mode.label) { harness.setPermission(mode) }
      }
    } label: {
      Label(harness.permission.label, systemImage: "lock.shield")
        .headerPillStyle()
    }
    .menuStyle(.borderlessButton)
  }

  private var detailsToggle: some View {
    Button(action: { harness.showDetails.toggle() }) {
      Image(systemName: harness.showDetails ? "sidebar.right" : "sidebar.right")
    }
    .buttonStyle(.borderless)
  }
}

/// Consistent capsule/pill treatment for the header's three Menu labels
/// (design system §5 icon conventions, §2 pill sizing) — a neutral,
/// low-contrast background so the trio reads as one control group rather
/// than three unrelated borderless buttons.
private extension View {
  func headerPillStyle() -> some View {
    self
      .font(.caption)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(.secondary.opacity(0.08), in: Capsule())
  }
}

// MARK: - ConversationView

struct ConversationView: View {
  @EnvironmentObject var harness: HarnessController

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 16) {
          if harness.historyHasMore && harness.subagentTranscript == nil {
            Button("载入更早消息", action: harness.loadOlderHistory)
              .buttonStyle(.bordered)
              .frame(maxWidth: .infinity)
          }

          let messages = harness.displayedSession?.messages ?? []
          if messages.isEmpty {
            ConversationEmptyState()
          } else {
            ForEach(messages) { message in
              MessageBubble(message: message).id(message.id)
            }
          }
        }
        .padding(28)
      }
      .onChange(of: harness.displayedSession?.messages) { _, messages in
        if let last = messages?.last {
          proxy.scrollTo(last.id, anchor: .bottom)
        }
      }
    }
  }
}

/// Lightweight welcome state for a session with no messages yet (design
/// system §6). Kept deliberately small — the composer immediately below
/// already supplies the call-to-action, so this only needs to explain that
/// the blank space is intentional.
private struct ConversationEmptyState: View {
  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: "bubble.left")
        .font(.system(size: 26))
        .foregroundStyle(.secondary)
      Text("还没有消息")
        .font(.callout)
        .foregroundStyle(.secondary)
      Text("在下方输入内容开始对话")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 48)
  }
}

// MARK: - MessageBubble

struct MessageBubble: View {
  @EnvironmentObject var harness: HarnessController
  let message: HarnessController.Message

  var body: some View {
    HStack {
      if message.role == .user {
        Spacer(minLength: 180)
      }

      VStack(alignment: .leading, spacing: 7) {
        Text(label)
          .font(.caption.weight(.bold))
          .foregroundStyle(tint)

        if let reasoning = message.reasoning {
          DisclosureGroup("推理过程") {
            Text(reasoning)
              .font(.caption.monospaced())
              .textSelection(.enabled)
              .foregroundStyle(.secondary)
          }
        }

        Text(message.text.isEmpty ? "正在思考…" : message.text)
          .textSelection(.enabled)
          .font(.system(.body, design: .rounded))
          .frame(maxWidth: 760, alignment: .leading)

        if let attachment = message.attachment {
          AttachmentPreview(ref: attachment)
        }
      }
      .padding(15)
      .background(background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

      if message.role != .user {
        Spacer(minLength: 180)
      }
    }
  }

  private var label: String {
    switch message.role {
    case .user: "你"
    case .assistant: "DSH"
    case .system: "系统"
    }
  }

  private var tint: Color {
    switch message.role {
    case .user: .cyan
    case .assistant: .mint
    case .system: .secondary
    }
  }

  private var background: Color {
    switch message.role {
    case .user: .cyan.opacity(0.12)
    case .assistant: .mint.opacity(0.10)
    case .system: .secondary.opacity(0.08)
    }
  }
}
