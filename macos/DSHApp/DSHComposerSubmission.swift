import Foundation

enum DSHComposerSubmissionPolicy {
  enum NativeCommand: Equatable {
    case export
    case model
  }

  static func mode(
    running: Bool,
    accelerated: Bool,
    preferredBusyMode: DSHPromptMode,
    steeringAvailable: Bool
  ) -> DSHPromptMode {
    guard running, steeringAvailable else { return .queue }
    guard accelerated else { return preferredBusyMode }
    return preferredBusyMode == .queue ? .steer : .queue
  }

  static func shouldSteerQueuedMessages(hasContent: Bool, mode: DSHPromptMode) -> Bool {
    !hasContent && mode == .steer
  }

  static func shouldExecuteCommand(text: String, hasImage: Bool, isRootSession: Bool) -> Bool {
    isRootSession && !hasImage && text.hasPrefix("/")
  }

  static func nativeCommand(text: String, hasImage: Bool) -> NativeCommand? {
    guard !hasImage else { return nil }
    switch text {
    case "/export": return .export
    case "/model": return .model
    default: return nil
    }
  }
}

extension DSHPromptMode {
  var nativeLabel: String { self == .queue ? "排队发送" : "插话发送" }
}

extension HarnessController {
  func clearAcceptedComposerDraft(originalText: String, originalImageID: UUID?) {
    if let remainder = Self.acceptedRunningDraftRemainder(current: draft, submitted: originalText) {
      draft = remainder
    }
    if draftImage?.id == originalImageID {
      draftImage = nil
    }
  }

  func submitSubagentComposerDraft(
    address: DSHSubagentAddress,
    successStatus: String
  ) {
    let originalText = draft
    let text = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
    let image = draftImage
    guard !text.isEmpty || image != nil else { return }
    guard address.mode == "continuable",
          !Self.isRootOnlySubagentSlashCommand(text) else {
      status = "子代理不支持 /goal、/plan 等根会话命令"
      return
    }
    guard let hostClient else { return }
    var content: [DSHPromptContent] = text.isEmpty ? [] : [.text(text)]
    if let image {
      do {
        let bytes = try Data(contentsOf: image.url)
        content.append(.image(
          data: bytes.base64EncodedString(),
          mediaType: image.mediaType,
          name: image.url.lastPathComponent))
      } catch {
        status = "读取图片失败：\(error.localizedDescription)"
        return
      }
    }
    let submissionID = address.childSessionId
    guard beginComposerSubmission(sessionID: submissionID) else { return }
    Task {
      do {
        try await hostClient.promptSubagent(
          parentSessionId: address.parentSessionId,
          childSessionId: address.childSessionId,
          content: content)
        await MainActor.run {
          self.endComposerSubmission(sessionID: submissionID)
          if self.activeSubagentAddress == address { self.status = successStatus }
          self.clearAcceptedComposerDraft(
            originalText: originalText,
            originalImageID: image?.id)
        }
      } catch {
        await MainActor.run {
          self.endComposerSubmission(sessionID: submissionID)
          if self.activeSubagentAddress == address {
            self.status = "子代理追问失败：\(error.localizedDescription)"
          }
        }
      }
    }
  }

  @discardableResult
  func submitNativeComposerCommandIfNeeded(text: String, hasImage: Bool) -> Bool {
    guard let command = DSHComposerSubmissionPolicy.nativeCommand(text: text, hasImage: hasImage) else {
      return false
    }
    draft = ""
    switch command {
    case .export: exportCurrentSessionLog()
    case .model: showModelPicker = true
    }
    return true
  }

  var busyEnterMode: DSHPromptMode {
    guard let raw = busyEnterSettingsNamespace?
      .value.object?["busyEnter"]?.string else { return .queue }
    return DSHPromptMode(rawValue: raw) ?? .queue
  }

  var busyEnterSettingsNamespace: DSHSettingsNamespace? {
    settingsDescription?.namespaces.first { $0.ns == "ui-conversation" }
  }

  var canSubmitRunningDraft: Bool {
    let hasContent = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draftImage != nil
    return displayedIsRunning && hasContent && !isViewingReadOnlySubagent
      && hostClient != nil && hostCurrentSessionID != nil
      && !runningSubmissionInFlight && !composerSubmissionInFlight
  }

  var canSteerQueuedMessages: Bool {
    displayedIsRunning && activeSubagentAddress == nil && !displayedQueuedItems.isEmpty
  }

  func setBusyEnterMode(_ mode: DSHPromptMode) {
    guard hostClient != nil, let namespace = busyEnterSettingsNamespace else {
      status = "当前 Host 未提供运行中回车设置"
      return
    }
    guard beginSettingsChoiceMutation(namespace.ns) else { return }
    mutateSettings(
      ns: namespace.ns,
      ops: [.set(["busyEnter"], .string(mode.rawValue))],
      revision: namespace.revision,
      success: { _ in
        self.endSettingsChoiceMutation(namespace.ns)
        self.status = "运行中按回车将\(mode.nativeLabel)"
      },
      conflict: {
        self.endSettingsChoiceMutation(namespace.ns)
        self.refreshSettings()
      },
      failure: { _ in self.endSettingsChoiceMutation(namespace.ns) })
  }

  @discardableResult
  func submitBusyComposer(accelerated: Bool) -> Bool {
    guard displayedIsRunning, composerAgentProfileID == nil else { return false }
    guard !runningSubmissionInFlight, !composerSubmissionInFlight else { return true }
    let mode = DSHComposerSubmissionPolicy.mode(
      running: true,
      accelerated: accelerated,
      preferredBusyMode: busyEnterMode,
      steeringAvailable: activeSubagentAddress == nil)
    let hasContent = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draftImage != nil
    if !hasContent {
      if DSHComposerSubmissionPolicy.shouldSteerQueuedMessages(hasContent: false, mode: mode),
         canSteerQueuedMessages {
        steerQueuedMessages()
      }
      return true
    }
    submitRunningDraft(mode: mode)
    return true
  }
}
