import Combine
import Foundation

struct DSHBufferedSubagentEvent {
  let seq: Int?
  let event: [String: Any]
  let view: [String: Any]?
}

enum DSHDisplayedExecutionTarget: Equatable {
  case root(sessionID: String)
  case subagent(DSHSubagentAddress)
  case none
}

struct DSHSubagentPresentationContext {
  var tools: [HarnessController.ToolActivity] = []
  var toolSequences: [String: Int] = [:]
  var todos: [DSHTodoItem] = []
  var goal: DSHGoalProjection?
  var planActive = false
  var queueItems: [DSHQueueItem] = []
  var projectionSequences: [String: Int] = [:]
  var bufferedEvents: [DSHBufferedSubagentEvent] = []
  var bufferedJobs: [[String: Any]] = []
}

@MainActor
private final class DSHSubagentPresentationState {
  weak var controller: HarnessController?
  var contexts: [String: DSHSubagentPresentationContext] = [:]
  var requestedAddress: DSHSubagentAddress?
  var loadGeneration = 0
  var catalogParentID: String?
  var catalogGeneration = 0

  init(controller: HarnessController) {
    self.controller = controller
  }

  func notify() {
    controller?.objectWillChange.send()
  }
}

@MainActor
private final class DSHSubagentPresentationRegistry {
  static let shared = DSHSubagentPresentationRegistry()
  private var states: [ObjectIdentifier: DSHSubagentPresentationState] = [:]

  func state(for controller: HarnessController) -> DSHSubagentPresentationState {
    states = states.filter { $0.value.controller != nil }
    let key = ObjectIdentifier(controller)
    if let state = states[key], let owner = state.controller, owner === controller {
      return state
    }
    let state = DSHSubagentPresentationState(controller: controller)
    states[key] = state
    return state
  }
}

extension HarnessController {
  private var subagentPresentationState: DSHSubagentPresentationState {
    DSHSubagentPresentationRegistry.shared.state(for: self)
  }

  private var displayedSubagentSessionID: String? {
    activeSubagentAddress?.childSessionId
  }

  var displayedTools: [ToolActivity] {
    guard let sessionID = displayedSubagentSessionID else { return activeTools }
    return subagentPresentationState.contexts[sessionID]?.tools ?? []
  }

  var displayedTodos: [DSHTodoItem] {
    guard let sessionID = displayedSubagentSessionID else { return todos }
    return subagentPresentationState.contexts[sessionID]?.todos ?? []
  }

  var displayedGoal: DSHGoalProjection? {
    guard let sessionID = displayedSubagentSessionID else { return goal }
    return subagentPresentationState.contexts[sessionID]?.goal
  }

  var displayedGoalSessionID: String? {
    displayedSubagentSessionID ?? hostCurrentSessionID
  }

  var displayedPlanActive: Bool {
    guard let sessionID = displayedSubagentSessionID else { return hostPlanActive }
    return subagentPresentationState.contexts[sessionID]?.planActive ?? false
  }

  var displayedQueueItems: [DSHQueueItem] {
    guard let sessionID = displayedSubagentSessionID else { return queueItems }
    return subagentPresentationState.contexts[sessionID]?.queueItems ?? []
  }

  /// The root session's Typert roster is not a child-session catalog.
  /// Continuable children accept literal prompts but must not expose root
  /// commands such as /goal or /plan through the shared composer palette.
  var canUseRootSlashCatalog: Bool {
    activeSubagentAddress == nil && subagentTranscript == nil
  }

  static func isRootOnlySubagentSlashCommand(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("/") else { return false }
    let name = trimmed.dropFirst()
      .split(whereSeparator: \.isWhitespace)
      .first?
      .lowercased()
    return ["goal", "plan", "export", "model"].contains(name ?? "")
  }

  var canMutateDisplayedGoal: Bool {
    activeSubagentAddress == nil
  }

  var canMutateDisplayedPlan: Bool {
    activeSubagentAddress == nil
  }

  var canMutateDisplayedQueue: Bool {
    activeSubagentAddress == nil
  }

  var displayedIsRunning: Bool {
    guard activeSubagentAddress != nil else { return isRunning }
    return subagentTranscript?.isRunning ?? false
  }

  var isViewingContinuableSubagent: Bool {
    activeSubagentAddress?.mode == "continuable"
  }

  var displayedExecutionTarget: DSHDisplayedExecutionTarget {
    if let address = activeSubagentAddress {
      return address.mode == "continuable" ? .subagent(address) : .none
    }
    if let sessionID = hostCurrentSessionID {
      return .root(sessionID: sessionID)
    }
    return .none
  }

  func hasSubagentPresentation(sessionID: String) -> Bool {
    subagentPresentationState.contexts[sessionID] != nil
  }

  @discardableResult
  func beginSubagentPresentationLoad(address: DSHSubagentAddress) -> Int {
    let state = subagentPresentationState
    state.loadGeneration += 1
    state.requestedAddress = address
    if state.contexts[address.childSessionId] == nil {
      state.contexts[address.childSessionId] = DSHSubagentPresentationContext()
    }
    return state.loadGeneration
  }

  func acceptsSubagentPresentationLoad(
    address: DSHSubagentAddress,
    generation: Int
  ) -> Bool {
    let state = subagentPresentationState
    return state.loadGeneration == generation && state.requestedAddress == address
  }

  func invalidateSubagentPresentationLoad() {
    let state = subagentPresentationState
    state.loadGeneration += 1
    state.requestedAddress = nil
    state.catalogGeneration += 1
    state.catalogParentID = nil
  }

  @discardableResult
  func beginSubagentCatalogLoad(parentSessionID: String) -> Int {
    let state = subagentPresentationState
    state.catalogGeneration += 1
    state.catalogParentID = parentSessionID
    return state.catalogGeneration
  }

  func acceptsSubagentCatalogLoad(parentSessionID: String, generation: Int) -> Bool {
    let state = subagentPresentationState
    return state.catalogGeneration == generation && state.catalogParentID == parentSessionID
  }

  /// A workflow row first resolves the member through `subagent.list`.
  /// Reuse the navigation generation so an old catalog cannot force the
  /// interface back to a root session after the user has navigated away.
  @discardableResult
  func beginWorkflowMemberNavigation() -> Int {
    let state = subagentPresentationState
    state.loadGeneration += 1
    state.requestedAddress = nil
    state.catalogGeneration += 1
    state.catalogParentID = nil
    return state.loadGeneration
  }

  func acceptsWorkflowMemberNavigation(generation: Int) -> Bool {
    let state = subagentPresentationState
    return state.loadGeneration == generation && state.requestedAddress == nil
  }

  func isLoadingSubagentPresentation(sessionID: String) -> Bool {
    let state = subagentPresentationState
    return state.requestedAddress?.childSessionId == sessionID
      && activeSubagentAddress?.childSessionId != sessionID
  }

  func bufferSubagentEvent(
    sessionID: String,
    event: [String: Any],
    view: [String: Any]?
  ) {
    guard var context = subagentPresentationState.contexts[sessionID] else { return }
    context.bufferedEvents.append(DSHBufferedSubagentEvent(
      seq: event["seq"] as? Int,
      event: event,
      view: view))
    subagentPresentationState.contexts[sessionID] = context
  }

  func bufferSubagentJobs(sessionID: String, jobs: [[String: Any]]) {
    guard var context = subagentPresentationState.contexts[sessionID] else { return }
    context.bufferedJobs = jobs
    subagentPresentationState.contexts[sessionID] = context
  }

  func drainBufferedSubagentEvents(
    sessionID: String,
    after historySequence: Int
  ) -> ([DSHBufferedSubagentEvent], [[String: Any]]) {
    guard var context = subagentPresentationState.contexts[sessionID] else { return ([], []) }
    let events = context.bufferedEvents
      .filter { ($0.seq ?? Int.max) > historySequence }
      .sorted { ($0.seq ?? Int.max) < ($1.seq ?? Int.max) }
    let jobs = context.bufferedJobs
    context.bufferedEvents = []
    context.bufferedJobs = []
    subagentPresentationState.contexts[sessionID] = context
    return (events, jobs)
  }

  func seedSubagentPresentation(
    sessionID: String,
    tools: [ToolActivity],
    projections: DSHSessionProjections?
  ) {
    mergeSubagentPresentation(
      sessionID: sessionID,
      tools: tools,
      toolSequences: [:],
      projections: projections)
  }

  func mergeSubagentPresentation(
    sessionID: String,
    tools: [ToolActivity],
    toolSequences: [String: Int],
    projections: DSHSessionProjections?
  ) {
    var context = subagentPresentationState.contexts[sessionID] ?? DSHSubagentPresentationContext()
    for tool in tools {
      let sequence = toolSequences[tool.callId, default: -1]
      guard sequence >= context.toolSequences[tool.callId, default: -1] else { continue }
      if let index = context.tools.lastIndex(where: { $0.callId == tool.callId }) {
        context.tools[index] = tool
      } else {
        context.tools.append(tool)
      }
      context.toolSequences[tool.callId] = sequence
    }
    if let projections {
      if shouldApplySubagentProjectionBaseline(
        key: "todos",
        rawValue: projections.rawValues["todos"],
        typedValuePresent: projections.values.todos != nil,
        seq: projections.asOfSeq,
        context: context
      ) {
        if case .null? = projections.rawValues["todos"] { context.todos = [] }
        else { context.todos = projections.values.todos ?? [] }
        context.projectionSequences["todos"] = projections.asOfSeq
      }
      if shouldApplySubagentProjectionBaseline(
        key: "goal",
        rawValue: projections.rawValues["goal"],
        typedValuePresent: projections.values.goal != nil,
        seq: projections.asOfSeq,
        context: context
      ) {
        if case .null? = projections.rawValues["goal"] { context.goal = nil }
        else { context.goal = projections.values.goal }
        context.projectionSequences["goal"] = projections.asOfSeq
      }
      if shouldApplySubagentProjectionBaseline(
        key: "plan",
        rawValue: projections.rawValues["plan"],
        typedValuePresent: projections.values.plan != nil,
        seq: projections.asOfSeq,
        context: context
      ) {
        if case .null? = projections.rawValues["plan"] { context.planActive = false }
        else { context.planActive = projections.values.plan?.active ?? false }
        context.projectionSequences["plan"] = projections.asOfSeq
      }
    }
    subagentPresentationState.contexts[sessionID] = context
    subagentPresentationState.notify()
  }

  func applySubagentProjection(sessionID: String, key: String, value: Any, seq: Int) {
    guard var context = subagentPresentationState.contexts[sessionID],
          seq >= context.projectionSequences[key, default: -1]
    else { return }

    switch key {
    case "todos":
      if value is NSNull {
        context.todos = []
      } else {
        guard let todos = DSHProjectionDecoder.decode([DSHTodoItem].self, from: value) else { return }
        context.todos = todos
      }
    case "goal":
      if value is NSNull {
        context.goal = nil
      } else {
        guard let goal = DSHProjectionDecoder.decode(DSHGoalProjection.self, from: value) else { return }
        context.goal = goal
      }
    case "plan":
      if value is NSNull {
        context.planActive = false
      } else {
        guard let plan = DSHProjectionDecoder.decode(DSHPlanState.self, from: value) else { return }
        context.planActive = plan.active
      }
    default:
      return
    }
    context.projectionSequences[key] = seq
    subagentPresentationState.contexts[sessionID] = context
    subagentPresentationState.notify()
  }

  func appendSubagentTool(sessionID: String, tool: ToolActivity, seq: Int) {
    guard var context = subagentPresentationState.contexts[sessionID] else { return }
    guard seq >= context.toolSequences[tool.callId, default: -1] else { return }
    if let index = context.tools.lastIndex(where: { $0.callId == tool.callId }) {
      context.tools[index] = tool
    } else {
      context.tools.append(tool)
    }
    context.toolSequences[tool.callId] = seq
    subagentPresentationState.contexts[sessionID] = context
    subagentPresentationState.notify()
  }

  @discardableResult
  func updateSubagentTool(
    sessionID: String,
    callID: String,
    seq: Int,
    update: (inout ToolActivity) -> Void
  ) -> ToolActivity? {
    guard var context = subagentPresentationState.contexts[sessionID],
          let index = context.tools.lastIndex(where: { $0.callId == callID }),
          seq >= context.toolSequences[callID, default: -1]
    else { return nil }
    update(&context.tools[index])
    let tool = context.tools[index]
    context.toolSequences[callID] = seq
    subagentPresentationState.contexts[sessionID] = context
    subagentPresentationState.notify()
    return tool
  }

  func settleSubagentTools(sessionID: String, seq: Int) {
    guard var context = subagentPresentationState.contexts[sessionID] else { return }
    var changed = false
    for index in context.tools.indices
    where context.tools[index].state == .running
      && seq >= context.toolSequences[context.tools[index].callId, default: -1] {
      context.tools[index].state = .succeeded
      context.toolSequences[context.tools[index].callId] = seq
      changed = true
    }
    guard changed else { return }
    subagentPresentationState.contexts[sessionID] = context
    subagentPresentationState.notify()
  }

  func replaceSubagentTodos(sessionID: String, value: [[String: Any]], seq: Int) {
    guard var context = subagentPresentationState.contexts[sessionID],
          seq >= context.projectionSequences["todos", default: -1]
    else { return }
    context.todos = value.compactMap { item in
      guard let content = item["content"] as? String, let status = item["status"] as? String else { return nil }
      return DSHTodoItem(content: content, status: status)
    }
    context.projectionSequences["todos"] = seq
    subagentPresentationState.contexts[sessionID] = context
    subagentPresentationState.notify()
  }

  func replaceSubagentQueue(sessionID: String, items: [DSHQueueItem]) {
    guard var context = subagentPresentationState.contexts[sessionID] else { return }
    context.queueItems = items
    subagentPresentationState.contexts[sessionID] = context
    subagentPresentationState.notify()
  }

  func mergeSubagentJobs(sessionID: String, jobs: [[String: Any]]) {
    guard var context = subagentPresentationState.contexts[sessionID] else { return }
    for job in jobs {
      guard let id = job["id"] as? String else { continue }
      let status = (job["status"] as? String ?? "running").lowercased()
      let state: ToolActivity.State =
        status == "failed" ? .failed :
        ["running", "pending", "in-progress", "in_progress"].contains(status) ? .running : .succeeded
      if let index = context.tools.lastIndex(where: { $0.callId == id }) {
        context.tools[index].state = state
        if let detail = job["detail"] as? String { context.tools[index].summary = detail }
      } else {
        context.tools.append(ToolActivity(
          callId: id,
          name: job["label"] as? String ?? "后台任务",
          summary: job["detail"] as? String ?? status,
          state: state,
          output: "",
          presentation: nil))
      }
    }
    subagentPresentationState.contexts[sessionID] = context
    subagentPresentationState.notify()
  }

  private func shouldApplySubagentProjectionBaseline(
    key: String,
    rawValue: DSHJSONValue?,
    typedValuePresent: Bool,
    seq: Int,
    context: DSHSubagentPresentationContext
  ) -> Bool {
    (rawValue != nil || typedValuePresent)
      && seq >= context.projectionSequences[key, default: -1]
  }
}
