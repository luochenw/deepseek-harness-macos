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

struct DSHSubagentAddress: Encodable {
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
    guard let parent = currentSubagentParentID, entry.kind == "child", let mode = entry.mode else { return }
    let address = DSHSubagentAddress(parentSessionId: parent, childSessionId: entry.id, mode: mode)
    let label = entry.label ?? entry.id
    Task {
      guard await loadSubagentTranscript(address: address, label: label, running: entry.activity == "running") else { return }
      await MainActor.run {
        self.subagentPath.append(SubagentNavigationNode(address: address, title: label))
        self.loadSubagents(parentSessionId: entry.id)
      }
    }
  }

  func navigateUpSubagent() {
    guard !subagentPath.isEmpty else { return }
    subagentPath.removeLast()
    guard let node = subagentPath.last else {
      activeSubagentAddress = nil
      subagentTranscript = nil
      if let parent = hostCurrentSessionID { loadSubagents(parentSessionId: parent) }
      return
    }
    Task {
      await loadSubagentTranscript(address: node.address, label: node.title, running: false)
      await MainActor.run { self.loadSubagents(parentSessionId: node.address.childSessionId) }
    }
  }

  /// Fetches and folds a subagent's history into `subagentTranscript`. Shared
  /// by `openSubagent` (drill down) and `navigateUpSubagent` (drill back up
  /// to an ancestor) so both paths can never disagree about what's on screen.
  @discardableResult
  private func loadSubagentTranscript(address: DSHSubagentAddress, label: String, running: Bool) async -> Bool {
    guard let hostClient else { return false }
    do {
      let page = try await hostClient.subagentHistory(parentSessionId: address.parentSessionId, childSessionId: address.childSessionId, mode: address.mode)
      let messages = foldHistory(page.events)
      await MainActor.run {
        self.subagentTranscript = Session(title: label, workspaceName: "子代理", updatedAt: Date(), messages: messages.isEmpty ? [Message(role: .system, text: "子代理尚无可展示的消息。")] : messages, isRunning: running)
        self.activeSubagentAddress = address
        self.status = "已打开子代理历史"
      }
      return true
    } catch {
      await MainActor.run { self.appendSystem("读取子代理历史失败：\(error.localizedDescription)") }
      return false
    }
  }

  func selectWorkflow(_ run: WorkflowRun) { selectedWorkflowRunID = run.id }

  func openWorkflowMember(run: WorkflowRun, member: WorkflowRun.Member) {
    guard let hostClient else { return }
    Task { do {
      let catalog = try await hostClient.subagents(parentSessionId: run.parentSessionId)
      guard let entry = catalog.entries.first(where: { $0.id == member.childId }) else { await MainActor.run { self.status = "工作流成员已不可用" }; return }
      await MainActor.run { self.selectedWorkflowRunID = run.id; self.subagentPath = []; self.hostCurrentSessionID = run.parentSessionId; self.openSubagent(entry) }
    } catch { await MainActor.run { self.appendSystem("读取工作流成员失败：\(error.localizedDescription)") } } }
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
