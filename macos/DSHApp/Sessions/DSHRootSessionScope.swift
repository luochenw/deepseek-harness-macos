import Foundation

/// Everything that describes the open root session rather than the app. Only
/// that session receives events, so one scope is enough, and replacing it whole
/// means clearing on a switch cannot miss a field.
struct DSHRootSessionScope {
  var activeTools: [HarnessController.ToolActivity] = []
  var todos: [DSHTodoItem] = []
  var subagents: [DSHSubagentEntry] = []
  var skills: [DSHSkillEntry] = []
  var workflowLog = DSHWorkflowLog()
  var selectedWorkflowRunID: String?
  var runNotice: String?
  var retryNotice: String?
  var currentSessionModels: DSHSessionModels?
  var hostPlanActive = false
  var goal: DSHGoalProjection?
  var tokenUsage: DSHTokenUsage?
  var contextPressure: DSHContextPressure?
  var sessionStats: DSHSessionStats?
  var hostCommands: [DSHCommandDescriptor] = []
  var messageFeedback: [String: DSHMessageFeedbackItem] = [:]
  var queueItems: [DSHQueueItem] = []
}

extension HarnessController {
  var activeTools: [ToolActivity] { get { rootScope.activeTools } set { rootScope.activeTools = newValue } }
  var todos: [DSHTodoItem] { get { rootScope.todos } set { rootScope.todos = newValue } }
  var subagents: [DSHSubagentEntry] { get { rootScope.subagents } set { rootScope.subagents = newValue } }
  var skills: [DSHSkillEntry] { get { rootScope.skills } set { rootScope.skills = newValue } }
  var workflows: [WorkflowRun] { rootScope.workflowLog.runs }
  var selectedWorkflowRunID: String? { get { rootScope.selectedWorkflowRunID } set { rootScope.selectedWorkflowRunID = newValue } }
  var runNotice: String? { get { rootScope.runNotice } set { rootScope.runNotice = newValue } }
  var retryNotice: String? { get { rootScope.retryNotice } set { rootScope.retryNotice = newValue } }
  var currentSessionModels: DSHSessionModels? { get { rootScope.currentSessionModels } set { rootScope.currentSessionModels = newValue } }
  var hostPlanActive: Bool { get { rootScope.hostPlanActive } set { rootScope.hostPlanActive = newValue } }
  var goal: DSHGoalProjection? { get { rootScope.goal } set { rootScope.goal = newValue } }
  var tokenUsage: DSHTokenUsage? { get { rootScope.tokenUsage } set { rootScope.tokenUsage = newValue } }
  var contextPressure: DSHContextPressure? { get { rootScope.contextPressure } set { rootScope.contextPressure = newValue } }
  var sessionStats: DSHSessionStats? { get { rootScope.sessionStats } set { rootScope.sessionStats = newValue } }
  var hostCommands: [DSHCommandDescriptor] { get { rootScope.hostCommands } set { rootScope.hostCommands = newValue } }
  var messageFeedback: [String: DSHMessageFeedbackItem] { get { rootScope.messageFeedback } set { rootScope.messageFeedback = newValue } }
  var queueItems: [DSHQueueItem] { get { rootScope.queueItems } set { rootScope.queueItems = newValue } }

  func recordWorkflowHistory(_ folded: DSHFoldedHistory, sessionID: String) {
    rootScope.workflowLog.record(folded.workflowEvents, parentSessionID: sessionID, replacing: folded.sequenceRange)
  }
}
