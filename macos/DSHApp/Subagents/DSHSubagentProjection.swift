import Combine
import Foundation

struct DSHBufferedSubagentEvent {
  let raw: DSHRawEvent
  let event: DSHSessionEvent
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

extension HarnessController {
  private var subagentPresentationState: DSHSubagentPresentationState {
    stateBag.state { DSHSubagentPresentationState(controller: self) }
  }

  private var displayedSubagentSessionID: String? {
    activeSubagentAddress?.childSessionId
  }

  var displayedTools: [ToolActivity] {
    guard let sessionID = displayedSubagentSessionID else { return activeTools }
    return subagentPresentationState.contexts[sessionID]?.tools ?? []
  }

  var displayedIsLoadingHistory: Bool {
    subagentTranscript?.isLoadingHistory
      ?? displayedSession?.isLoadingHistory
      ?? false
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

  var displayedQueuedItems: [DSHQueueItem] {
    displayedQueueItems.filter(\.isQueued)
  }

  var displayedSteeringItems: [DSHQueueItem] {
    displayedQueueItems.filter(\.isSteering)
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

  func subagentTool(sessionID: String, callID: String) -> ToolActivity? {
    subagentPresentationState.contexts[sessionID]?.tools.last { $0.callId == callID }
  }

  @discardableResult
  func beginSubagentPresentationLoad(address: DSHSubagentAddress) -> Int {
    let state = subagentPresentationState
    state.loadGeneration += 1
    state.requestedAddress = address
    if state.contexts[address.childSessionId] == nil {
      var context = DSHSubagentPresentationContext()
      context.queueItems = cachedQueueSnapshot(sessionID: address.childSessionId)
      state.contexts[address.childSessionId] = context
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

  /// A workflow row first resolves the member through `subagentCatalog`.
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

  func bufferSubagentEvent(sessionID: String, raw: DSHRawEvent, event: DSHSessionEvent) {
    guard var context = subagentPresentationState.contexts[sessionID] else { return }
    context.bufferedEvents.append(DSHBufferedSubagentEvent(raw: raw, event: event))
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
      .filter { ($0.raw.sequence ?? Int.max) > historySequence }
      .sorted { ($0.raw.sequence ?? Int.max) < ($1.raw.sequence ?? Int.max) }
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
        context.tools[index] = DSHToolActivityMerge.merging(
          incoming: tool,
          previous: context.tools[index])
      } else {
        context.tools.append(tool)
      }
      context.toolSequences[tool.callId] = sequence
    }
    if let projections, let projectionSeq = projections.asOfSeq {
      if shouldApplySubagentProjectionBaseline(
        key: "todos",
        rawValue: projections.rawValues["todos"],
        typedValuePresent: projections.values.todos != nil,
        seq: projectionSeq,
        context: context
      ) {
        if case .null? = projections.rawValues["todos"] { context.todos = [] }
        else { context.todos = projections.values.todos ?? [] }
        context.projectionSequences["todos"] = projectionSeq
      }
      if shouldApplySubagentProjectionBaseline(
        key: "goal",
        rawValue: projections.rawValues["goal"],
        typedValuePresent: projections.values.goal != nil,
        seq: projectionSeq,
        context: context
      ) {
        if case .null? = projections.rawValues["goal"] { context.goal = nil }
        else { context.goal = projections.values.goal }
        context.projectionSequences["goal"] = projectionSeq
      }
      if shouldApplySubagentProjectionBaseline(
        key: "plan",
        rawValue: projections.rawValues["plan"],
        typedValuePresent: projections.values.plan != nil,
        seq: projectionSeq,
        context: context
      ) {
        if case .null? = projections.rawValues["plan"] { context.planActive = false }
        else { context.planActive = projections.values.plan?.active ?? false }
        context.projectionSequences["plan"] = projectionSeq
      }
      if let inbox = projections.rawValues["inbox"],
         shouldApplySubagentProjectionBaseline(
           key: "inbox",
           rawValue: inbox,
           typedValuePresent: true,
           seq: projectionSeq,
           context: context) {
        context.queueItems = DSHQueueItem.fromInbox(inbox.plainValue) ?? []
        context.projectionSequences["inbox"] = projectionSeq
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
    case "inbox":
      guard let items = DSHQueueItem.fromInbox(value) else { return }
      context.queueItems = items
    default:
      return
    }
    context.projectionSequences[key] = seq
    subagentPresentationState.contexts[sessionID] = context
    subagentPresentationState.notify()
  }

  /// Tools and projections stay keyed by child session even while another
  /// transcript is on screen; message rows reach only the displayed child.
  func applySubagentEvent(_ event: DSHSessionEvent, raw: DSHRawEvent, sessionID: String) {
    var store = DSHSubagentTimelineStore(controller: self, sessionID: sessionID)
    DSHSessionTimeline.apply(event, raw: raw, mode: .live, to: &store)
    if case .todos(let items) = event, let seq = raw.sequence {
      replaceSubagentTodos(sessionID: sessionID, items: items, seq: seq)
    }
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

  func settleSubagentTools(sessionID: String, as state: ToolActivity.State, seq: Int) {
    guard var context = subagentPresentationState.contexts[sessionID] else { return }
    var changed = false
    for index in context.tools.indices
    where context.tools[index].state == .running
      && seq >= context.toolSequences[context.tools[index].callId, default: -1] {
      context.tools[index].settle(as: state)
      context.toolSequences[context.tools[index].callId] = seq
      changed = true
    }
    guard changed else { return }
    subagentPresentationState.contexts[sessionID] = context
    subagentPresentationState.notify()
  }

  func replaceSubagentTodos(sessionID: String, items: [DSHTodoItem], seq: Int) {
    guard var context = subagentPresentationState.contexts[sessionID],
          seq >= context.projectionSequences["todos", default: -1]
    else { return }
    context.todos = items
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

  func retireSubagentSteeringItem(messageID: String, sessionID: String) {
    guard var context = subagentPresentationState.contexts[sessionID],
          let index = context.queueItems.firstIndex(where: { $0.isSteering && $0.messageID == messageID })
    else { return }
    context.queueItems.remove(at: index)
    subagentPresentationState.contexts[sessionID] = context
    subagentPresentationState.notify()
  }

  func mergeSubagentJobs(sessionID: String, jobs: [[String: Any]]) {
    guard var context = subagentPresentationState.contexts[sessionID] else { return }
    for job in jobs {
      guard let id = job["id"] as? String else { continue }
      let status = (job["status"] as? String ?? "running").lowercased()
      let state = DSHToolJobState.resolve(status)
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

@MainActor
struct DSHSubagentTimelineStore: DSHTimelineStore {
  let controller: HarnessController
  let sessionID: String

  private var isDisplayed: Bool { controller.activeSubagentAddress?.childSessionId == sessionID }

  var turnStartedAt: Date? {
    get { isDisplayed ? controller.subagentTranscript?.turnStartedAt : nil }
    nonmutating set {
      if isDisplayed { controller.subagentTranscript?.turnStartedAt = newValue }
    }
  }

  mutating func withMessages(_ body: (inout [HarnessController.Message]) -> Void) {
    guard isDisplayed, var transcript = controller.subagentTranscript else { return }
    body(&transcript.messages)
    controller.subagentTranscript = transcript
  }

  mutating func addTool(_ tool: HarnessController.ToolActivity, seq: Int) {
    controller.appendSubagentTool(sessionID: sessionID, tool: tool, seq: seq)
  }

  mutating func updateTool(
    callID: String,
    seq: Int,
    _ update: (inout HarnessController.ToolActivity) -> Void
  ) {
    controller.updateSubagentTool(sessionID: sessionID, callID: callID, seq: seq, update: update)
  }

  mutating func settleRunningTools(as state: DSHToolActivity.State, seq: Int) {
    controller.settleSubagentTools(sessionID: sessionID, as: state, seq: seq)
  }

  mutating func setRunning(_ running: Bool) {
    if isDisplayed { controller.subagentTranscript?.isRunning = running }
  }

  mutating func recordWorkflowEvent(_ event: DSHSessionEvent, seq: Int) {}
}
