import Foundation

@main
struct AgentPlatformPolicyCheck {
  static func main() {
    precondition(DSHAgentPlatformPolicy.shouldRouteToBatch(selectedProfileID: "p1", profileResolved: true))
    precondition(!DSHAgentPlatformPolicy.shouldRouteToBatch(selectedProfileID: "p1", profileResolved: false))
    precondition(DSHAgentPlatformPolicy.hasUnresolvedSelection(selectedProfileID: "p1", profileResolved: false))
    precondition(!DSHAgentPlatformPolicy.hasUnresolvedSelection(selectedProfileID: nil, profileResolved: false))

    precondition(DSHAgentPlatformPolicy.shouldApplyBatch(acceptedRootSessionID: "root-a", displayedRootSessionID: "root-a"))
    precondition(!DSHAgentPlatformPolicy.shouldApplyBatch(acceptedRootSessionID: "root-a", displayedRootSessionID: "root-b"))
    precondition(DSHAgentPlatformPolicy.shouldClearComposer(
      acceptedRootSessionID: "root-a",
      displayedRootSessionID: "root-a",
      submittedProfileID: "p1",
      selectedProfileID: "p1",
      submittedTask: "review",
      currentDraft: " review "))
    precondition(!DSHAgentPlatformPolicy.shouldClearComposer(
      acceptedRootSessionID: "root-a",
      displayedRootSessionID: "root-b",
      submittedProfileID: "p1",
      selectedProfileID: "p1",
      submittedTask: "review",
      currentDraft: "review"))

    precondition(DSHAgentPlatformPolicy.canRetry(
      profileID: "p1",
      profileDeleted: false,
      activeProfileIDs: ["p1"],
      runStatus: "interrupted",
      retryable: nil))
    precondition(!DSHAgentPlatformPolicy.canRetry(
      profileID: "p1",
      profileDeleted: true,
      activeProfileIDs: ["p1"],
      runStatus: "interrupted",
      retryable: true))
    precondition(!DSHAgentPlatformPolicy.canRetry(
      profileID: "p1",
      profileDeleted: false,
      activeProfileIDs: [],
      runStatus: "failed",
      retryable: true))
    precondition(!DSHAgentPlatformPolicy.canRetry(
      profileID: "p1",
      profileDeleted: false,
      activeProfileIDs: ["p1"],
      runStatus: "failed",
      retryable: false))

    precondition(DSHAgentPlatformPolicy.canRequestIntegration(
      policy: "manual", state: "manualPending", isActive: false, hasEligibleMember: true))
    precondition(!DSHAgentPlatformPolicy.canRequestIntegration(
      policy: "auto", state: "integrating", isActive: false, hasEligibleMember: true))
    precondition(!DSHAgentPlatformPolicy.canRequestIntegration(
      policy: "manual", state: "adopted", isActive: false, hasEligibleMember: true))
    precondition(!DSHAgentPlatformPolicy.canRequestIntegration(
      policy: "manual", state: "manualPending", isActive: false, hasEligibleMember: true, requestInFlight: true))
    precondition(DSHAgentPlatformPolicy.canRequestIntegration(
      policy: "auto", state: "failed", isActive: false, hasEligibleMember: true))
    precondition(!DSHAgentPlatformPolicy.canRequestIntegration(
      policy: "manual", state: "manualPending", isActive: false, hasEligibleMember: false))
    precondition(!DSHAgentPlatformPolicy.canRequestIntegration(
      policy: "manual", state: "manualPending", isActive: false, hasEligibleMember: true, recoveryBlocked: true))
    precondition(!DSHAgentPlatformPolicy.canDiscardResult(
      integrationState: "integrating", runIsActive: false, workspaceCleaned: false))
    precondition(!DSHAgentPlatformPolicy.canDiscardResult(
      integrationState: "failed", runIsActive: false, workspaceCleaned: false))
    precondition(DSHAgentPlatformPolicy.canDiscardResult(
      integrationState: "partiallyAdopted", runIsActive: false, workspaceCleaned: false))

    print("agent-platform-policy: OK")
  }
}
