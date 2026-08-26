import Foundation


struct DSHSubagentEntry: Decodable, Identifiable {
  let kind: String
  let id: String
  let activity: String?
  let hasChildren: Bool?
  let mode: String?
  let label: String?
  let reason: String?
}

struct DSHSubagentCatalog: Decodable {
  let entries: [DSHSubagentEntry]
  let parentAvailable: Bool
}

struct DSHSubagentListPayload: Encodable { let parentSessionId: String }

struct DSHSubagentAddress: Encodable, Equatable {
  let parentSessionId: String
  let childSessionId: String
  let mode: String
}

struct DSHSubagentInterruptReceipt: Decodable { let accepted: Bool }
struct DSHSubagentHistoryPayload: Encodable { let parentSessionId: String; let childSessionId: String; let mode: String; let maxMessages: Int }
struct DSHSubagentPromptPayload: Encodable { let parentSessionId: String; let childSessionId: String; let mode: String; let content: [DSHPromptContent] }
struct DSHSubagentPromptReceipt: Decodable { let messageId: String }

extension HarnessController {
  var currentSubagentParentID: String? { subagentPath.last?.address.childSessionId ?? hostCurrentSessionID }

  func openSubagent(_ entry: DSHSubagentEntry) {
    guard let parent = currentSubagentParentID, entry.kind == "child",
          !isManagedAgentChild(entry), let mode = entry.mode else { return }
    let address = DSHSubagentAddress(parentSessionId: parent, childSessionId: entry.id, mode: mode)
    let label = entry.label ?? entry.id
    let generation = beginSubagentPresentationLoad(address: address)
    Task {
      guard await loadSubagentTranscript(
        address: address,
        label: label,
        running: entry.activity == "running",
        generation: generation)
      else { return }
      await MainActor.run {
        guard self.acceptsSubagentPresentationLoad(address: address, generation: generation) else { return }
        self.subagentPath.append(SubagentNavigationNode(address: address, title: label))
        self.loadSubagents(parentSessionId: entry.id)
      }
    }
  }

  func navigateUpSubagent() {
    guard !subagentPath.isEmpty else { return }
    let nextPath = Array(subagentPath.dropLast())
    guard let node = nextPath.last else {
      invalidateSubagentPresentationLoad()
      subagentPath = []
      activeSubagentAddress = nil
      subagentTranscript = nil
      if let parent = hostCurrentSessionID { loadSubagents(parentSessionId: parent) }
      return
    }
    let generation = beginSubagentPresentationLoad(address: node.address)
    Task {
      guard await loadSubagentTranscript(
        address: node.address,
        label: node.title,
        running: false,
        generation: generation)
      else { return }
      await MainActor.run {
        guard self.acceptsSubagentPresentationLoad(address: node.address, generation: generation) else { return }
        self.subagentPath = nextPath
        self.loadSubagents(parentSessionId: node.address.childSessionId)
      }
    }
  }

  /// Fetches and folds a subagent's history into `subagentTranscript`. Shared
  /// by `openSubagent` (drill down) and `navigateUpSubagent` (drill back up
  /// to an ancestor) so both paths can never disagree about what's on screen.
  @discardableResult
  private func loadSubagentTranscript(
    address: DSHSubagentAddress,
    label: String,
    running: Bool,
    generation: Int
  ) async -> Bool {
    guard let hostClient else { return false }
    do {
      let page = try await hostClient.subagentHistory(parentSessionId: address.parentSessionId, childSessionId: address.childSessionId, mode: address.mode)
      let folded = foldHistoryContent(page.events)
      return await MainActor.run {
        self.activateLoadedSubagentPresentation(
          address: address,
          label: label,
          running: running,
          generation: generation,
          folded: folded,
          projections: page.projections,
          historySequence: page.projections?.asOfSeq
            ?? page.events.map(\.event.seq).max()
            ?? -1)
      }
    } catch {
      await MainActor.run {
        guard self.acceptsSubagentPresentationLoad(address: address, generation: generation) else { return }
        self.appendSystem("读取子代理历史失败：\(error.localizedDescription)")
      }
      return false
    }
  }

  func activateLoadedSubagentPresentation(
    address: DSHSubagentAddress,
    label: String,
    running: Bool,
    generation: Int,
    folded: DSHFoldedHistory,
    projections: DSHSessionProjections?,
    historySequence: Int
  ) -> Bool {
    guard acceptsSubagentPresentationLoad(address: address, generation: generation) else { return false }
    mergeSubagentPresentation(
      sessionID: address.childSessionId,
      tools: folded.tools,
      toolSequences: folded.toolSequences,
      projections: projections)
    subagentTranscript = Session(
      title: label,
      workspaceName: "子代理",
      updatedAt: Date(),
      messages: folded.messages.isEmpty
        ? [Message(role: .system, text: "子代理尚无可展示的消息。")]
        : folded.messages,
      isRunning: running)
    activeSubagentAddress = address
    let (events, jobs) = drainBufferedSubagentEvents(
      sessionID: address.childSessionId,
      after: historySequence)
    for buffered in events {
      applyLiveSubagentEvent(
        sessionID: address.childSessionId,
        event: buffered.event,
        view: buffered.view)
    }
    if !jobs.isEmpty {
      mergeSubagentJobs(sessionID: address.childSessionId, jobs: jobs)
    }
    status = "已打开子代理历史"
    return true
  }

  func selectWorkflow(_ run: WorkflowRun) { selectedWorkflowRunID = run.id }

  func openWorkflowMember(run: WorkflowRun, member: WorkflowRun.Member) {
    guard let hostClient, hostCurrentSessionID == run.parentSessionId else { return }
    let generation = beginWorkflowMemberNavigation()
    Task { do {
      let catalog = try await hostClient.subagents(parentSessionId: run.parentSessionId)
      await MainActor.run {
        guard self.acceptsWorkflowMemberNavigation(generation: generation),
              self.hostCurrentSessionID == run.parentSessionId
        else { return }
        guard let entry = catalog.entries.first(where: { $0.id == member.childId }) else {
          self.status = "工作流成员已不可用"
          return
        }
        self.selectedWorkflowRunID = run.id
        self.activeSubagentAddress = nil
        self.subagentPath = []
        self.subagentTranscript = nil
        self.openSubagent(entry)
      }
    } catch {
      await MainActor.run {
        guard self.acceptsWorkflowMemberNavigation(generation: generation),
              self.hostCurrentSessionID == run.parentSessionId
        else { return }
        self.status = "读取工作流成员失败：\(error.localizedDescription)"
      }
    } }
  }

  func interruptSubagent(_ entry: DSHSubagentEntry) {
    guard let hostClient, let parent = currentSubagentParentID, entry.kind == "child", entry.mode == "continuable" else { return }
    Task {
      do {
        try await hostClient.interruptSubagent(parentSessionId: parent, childSessionId: entry.id)
        await MainActor.run { self.status = "已请求中断子代理"; self.loadSubagents(parentSessionId: parent) }
      } catch { await MainActor.run { self.appendSystem("子代理中断失败：\(error.localizedDescription)") } }
    }
  }
}
