import Foundation

struct DSHWorkspaceBaseline: Decodable {
  let items: [DSHWorkspaceView]
  let archivedSessionIds: [String]
  let pinnedSessionIds: [String]?
}

struct DSHWorkspaceFollowFrame: Decodable {
  let type: String
  let value: DSHWorkspaceBaseline?
  let workspace: DSHWorkspaceView?
  let workspaceId: String?
  let workspaceIds: [String]?
  let archivedSessionIds: [String]?
  let pinnedSessionIds: [String]?
}

@MainActor
private final class DSHWorkspaceStreamState {
  weak var controller: HarnessController?
  var streamID: String?
  var items: [DSHWorkspaceView] = []
  var archivedSessionIds: Set<String> = []
  var pinnedSessionIds: [String] = []

  init(controller: HarnessController) {
    self.controller = controller
  }
}

@MainActor
private final class DSHWorkspaceStreamRegistry {
  static let shared = DSHWorkspaceStreamRegistry()
  private var states: [ObjectIdentifier: DSHWorkspaceStreamState] = [:]

  func state(for controller: HarnessController) -> DSHWorkspaceStreamState {
    states = states.filter { $0.value.controller != nil }
    let key = ObjectIdentifier(controller)
    if let state = states[key], let owner = state.controller, owner === controller {
      return state
    }
    let state = DSHWorkspaceStreamState(controller: controller)
    states[key] = state
    return state
  }
}

extension HarnessController {
  private var workspaceStreamState: DSHWorkspaceStreamState {
    DSHWorkspaceStreamRegistry.shared.state(for: self)
  }

  var hostWorkspaceSnapshot: DSHWorkspaceList {
    let state = workspaceStreamState
    return DSHWorkspaceList(items: state.items, archivedSessionIds: Array(state.archivedSessionIds))
  }

  func applyArchivedSessionIDs(_ ids: [String]) {
    let archived = Set(ids)
    let state = workspaceStreamState
    state.archivedSessionIds = archived
    discardArchivedWorkbenchContexts(hostSessionIDs: archived)
    hostSessions.removeAll { archived.contains($0.sessionId) }
    if let current = hostCurrentSessionID, archived.contains(current) {
      clearToDefaultPage()
    }
  }

  func openWorkspaceFollow() {
    let state = workspaceStreamState
    hostEvents?.cancel(state.streamID)
    state.streamID = hostEvents?.open(
      endpoint: "workspace/follow",
      payload: ["args": [:]],
      onItem: { [weak self] frame in self?.consumeWorkspaceFollowFrame(frame) },
      onEnd: { [weak self] in self?.hostStatus = "工作区事件流已结束" },
      onError: { [weak self] message in self?.hostStatus = "工作区事件流失败：\(message)" })
  }

  private func consumeWorkspaceFollowFrame(_ frame: [String: Any]) {
    guard let update = DSHProjectionDecoder.decode(DSHWorkspaceFollowFrame.self, from: frame) else { return }
    let state = workspaceStreamState
    switch update.type {
    case "baseline", "replace":
      guard let value = update.value else { return }
      state.items = value.items
      state.archivedSessionIds = Set(value.archivedSessionIds)
      state.pinnedSessionIds = value.pinnedSessionIds ?? []
    case "upsert":
      guard let workspace = update.workspace else { return }
      if let index = state.items.firstIndex(where: { $0.workspaceId == workspace.workspaceId }) {
        state.items[index] = workspace
      } else {
        state.items.append(workspace)
      }
    case "remove":
      guard let id = update.workspaceId else { return }
      state.items.removeAll { $0.workspaceId == id }
    case "order":
      guard let ids = update.workspaceIds else { return }
      let rank = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
      state.items.sort { (rank[$0.workspaceId] ?? Int.max) < (rank[$1.workspaceId] ?? Int.max) }
    case "archived":
      state.archivedSessionIds = Set(update.archivedSessionIds ?? [])
    case "pinned":
      state.pinnedSessionIds = update.pinnedSessionIds ?? []
    default:
      return
    }
    hostWorkspaces = state.items
    let archived = state.archivedSessionIds
    discardArchivedWorkbenchContexts(hostSessionIDs: archived)
    hostSessions.removeAll { archived.contains($0.sessionId) }
    if let current = hostCurrentSessionID, archived.contains(current) {
      clearToDefaultPage()
    }
  }
}
