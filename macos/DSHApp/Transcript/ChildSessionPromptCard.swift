import SwiftUI

/// One child session the model asked to open, and what the user decided.
enum DSHChildSessionDecision: Equatable {
  case allowed
  case declined
}

/// Everything the card's visual state depends on. Kept as a value so the
/// resolution below is testable without a mounted view.
struct DSHChildSessionCardInputs: Equatable {
  /// An unanswered approval for this call.
  var approvalPending = false
  /// What the user answered, once answered.
  var decision: DSHChildSessionDecision?
  /// The child session id parsed out of the tool result.
  var childSessionId: String?
  /// The tool result came back as an error.
  var resultFailed = false
  /// The child's `running` flag from the session list, when it is known.
  var childRunning: Bool?

  init(
    approvalPending: Bool = false,
    decision: DSHChildSessionDecision? = nil,
    childSessionId: String? = nil,
    resultFailed: Bool = false,
    childRunning: Bool? = nil
  ) {
    self.approvalPending = approvalPending
    self.decision = decision
    self.childSessionId = childSessionId
    self.resultFailed = resultFailed
    self.childRunning = childRunning
  }
}

/// The states the card can be in.
enum DSHChildSessionCardStatus: Equatable {
  /// Waiting for the user: title, one-line note, two buttons.
  case confirming
  /// The child session exists and is working: title + time + running line.
  case running
  /// The child session is idle: "已完成 · 时间".
  case finished
  /// The user chose to stay in this session (or the call failed).
  case declined
}

enum DSHChildSessionCard {
  /// The only two tools that create a new child session.
  static let toolNames: Set<String> = ["subagent", "subagent_fork"]

  static func isChildSessionTool(_ name: String) -> Bool {
    toolNames.contains(name.lowercased())
  }

  /// Resolve the card from approval, tool result and catalogue state.
  ///
  /// Precedence is deliberate: an unanswered approval is always `confirming`,
  /// and a decision the user already made outranks whatever the catalogue says
  /// about a child that may not exist yet.
  static func status(_ inputs: DSHChildSessionCardInputs) -> DSHChildSessionCardStatus {
    if inputs.approvalPending { return .confirming }
    if inputs.decision == .declined || inputs.resultFailed { return .declined }
    guard inputs.childSessionId != nil else {
      // Approved but not started yet: the tool call is still running.
      return .running
    }
    return inputs.childRunning == false ? .finished : .running
  }

  /// Child session id out of the tool result text ("started subagent <id>").
  static func childSessionId(fromResult text: String?) -> String? {
    guard let text else { return nil }
    let prefix = "started subagent "
    guard text.hasPrefix(prefix) else { return nil }
    let id = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
    return id.isEmpty ? nil : id
  }

  /// The model's own label for the new session, out of the call's arguments.
  ///
  /// Prefers `description`; falls back to the prompt's first line so a card is
  /// never titleless, and caps it so one long description cannot take over the
  /// row.
  static func description(arguments: String?) -> String {
    let object = arguments.flatMap { raw -> [String: Any]? in
      guard let data = raw.data(using: .utf8) else { return nil }
      return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    let description = firstLine(object?["description"] as? String)
    if !description.isEmpty { return String(description.prefix(120)) }
    return String(firstLine(object?["prompt"] as? String).prefix(120))
  }

  static func title(_ description: String) -> String {
    let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "新会话" : "新会话：\(trimmed)"
  }

  private static func firstLine(_ text: String?) -> String {
    guard let text else { return "" }
    guard let line = text.split(whereSeparator: \.isNewline).first else { return "" }
    return line.trimmingCharacters(in: .whitespaces)
  }
}

/// The child-session row in the transcript: a plain session row while the child
/// runs, a question with two answers while it waits for the user.
struct ChildSessionPromptCard: View {
  @EnvironmentObject private var harness: HarnessController
  @ObservedObject var prompts: DSHChildSessionPromptState
  let message: HarnessController.Message
  @State private var hovering = false

  private var callId: String? { message.toolCallId }

  private var tool: HarnessController.ToolActivity? {
    guard let callId else { return nil }
    return harness.displayedTools.last { $0.callId == callId }
  }

  private var childSessionId: String? {
    DSHChildSessionCard.childSessionId(fromResult: tool?.output)
  }

  private var childSummary: DSHSessionSummary? {
    guard let childSessionId else { return nil }
    return harness.hostSessions.first { $0.sessionId == childSessionId }
  }

  private var status: DSHChildSessionCardStatus {
    DSHChildSessionCard.status(inputs)
  }

  /// Inputs resolved once, so the body and the height both read one value.
  var inputs: DSHChildSessionCardInputs {
    DSHChildSessionCardInputs(
      approvalPending: callId.flatMap { prompts.request($0) } != nil,
      decision: callId.flatMap { prompts.decision($0) },
      childSessionId: childSessionId,
      resultFailed: tool?.state == .failed,
      childRunning: childSummary?.running)
  }

  /// The model's label: the call's own arguments first, then the approval's
  /// description (the arguments are not always on screen yet).
  private var description: String {
    let fromArguments = DSHChildSessionCard.description(arguments: tool?.arguments)
    if !fromArguments.isEmpty { return fromArguments }
    return callId.flatMap { prompts.request($0)?.description } ?? ""
  }

  private var updatedAt: Date? {
    guard let childSummary else { return nil }
    return Date(timeIntervalSince1970: childSummary.updatedAt / 1000)
  }

  var body: some View {
    switch status {
    case .confirming: confirming
    case .running, .finished, .declined: row
    }
  }

  private var title: String { DSHChildSessionCard.title(description) }

  private var confirming: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s2) {
      Text(title)
        .font(DSHType.label.weight(.semibold))
        .foregroundStyle(DSHTheme.ink)
        .lineLimit(2)
      Text("模型想新开一个子会话做这件事，确认后才会创建。")
        .font(DSHType.caption)
        .foregroundStyle(DSHTheme.inkFaint)
      HStack(spacing: DSHSpace.s2) {
        Button("新建会话") { answer(allowed: true) }
          .buttonStyle(.dshPrimary)
        Button("在这里做") { answer(allowed: false) }
          .buttonStyle(.dshSecondary)
      }
      .padding(.top, 2)
    }
    .padding(.horizontal, DSHSpace.s4)
    .padding(.vertical, DSHSpace.s3)
    .frame(maxWidth: .infinity, alignment: .leading)
    .dshCard(tint: DSHTheme.surface, radius: DSHRadius.lg)
  }

  private var row: some View {
    Button(action: openChildSession) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: DSHSpace.s2) {
          DSHStatusDot(kind: status == .running ? .live : .idle)
          Text(title)
            .font(DSHType.label)
            .foregroundStyle(DSHTheme.ink)
            .lineLimit(1)
          Spacer(minLength: 0)
        }
        Text(subtitle)
          .font(DSHType.micro)
          .foregroundStyle(DSHTheme.inkFaint)
          .padding(.leading, 13)
      }
      .padding(.horizontal, DSHSpace.s3)
      .padding(.top, 7)
      .padding(.bottom, status == .running ? 4 : 7)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .background(
        hovering ? DSHTheme.surfaceTint2 : DSHTheme.surface,
        in: RoundedRectangle(cornerRadius: DSHRadius.md, style: .continuous))
      .overlay(alignment: .bottomLeading) {
        // The same running line the sidebar uses, inside the card's own padding
        // so the rounded corner does not clip it.
        if status == .running {
          DSHActivityLine(active: true, color: DSHTheme.running)
            .padding(.horizontal, DSHSpace.s3)
            .padding(.bottom, 2)
            .allowsHitTesting(false)
        }
      }
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .accessibilityValue(status == .running ? "运行中" : "已完成")
    .help(status == .running ? "打开正在运行的子会话" : "打开子会话")
  }

  private var subtitle: String {
    switch status {
    case .declined:
      return inputs.decision == .declined ? "在当前会话完成" : "未创建子会话"
    case .finished:
      return updatedAt.map { "已完成 · \(DSHSidebarSessionTimestamp.compact($0))" } ?? "已完成"
    case .running, .confirming:
      return updatedAt.map { DSHSidebarSessionTimestamp.compact($0) } ?? "正在运行"
    }
  }

  private func answer(allowed: Bool) {
    guard let callId else { return }
    harness.answerChildSessionApproval(callId: callId, allowed: allowed)
  }

  private func openChildSession() {
    guard let childSessionId else {
      harness.status = "子会话还没有出现在会话列表里"
      return
    }
    harness.openChildSessionFromCard(childSessionId: childSessionId)
  }
}
