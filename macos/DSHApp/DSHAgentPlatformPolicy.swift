import Foundation

/// Pure decisions shared by the Agent platform UI and its standalone contract
/// test. These state transitions are risky enough to exercise without an
/// Xcode/XCTest target.
enum DSHAgentPlatformPolicy {
  static func shouldRouteToBatch(selectedProfileID: String?, profileResolved: Bool) -> Bool {
    selectedProfileID != nil && profileResolved
  }

  static func hasUnresolvedSelection(selectedProfileID: String?, profileResolved: Bool) -> Bool {
    selectedProfileID != nil && !profileResolved
  }

  static func shouldApplyBatch(acceptedRootSessionID: String, displayedRootSessionID: String?) -> Bool {
    acceptedRootSessionID == displayedRootSessionID
  }

  static func shouldClearComposer(
    acceptedRootSessionID: String,
    displayedRootSessionID: String?,
    submittedProfileID: String,
    selectedProfileID: String?,
    submittedTask: String,
    currentDraft: String
  ) -> Bool {
    acceptedRootSessionID == displayedRootSessionID
      && submittedProfileID == selectedProfileID
      && submittedTask == currentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func canRetry(
    profileID: String?,
    profileDeleted: Bool,
    activeProfileIDs: Set<String>,
    runStatus: String,
    retryable: Bool?
  ) -> Bool {
    guard !profileDeleted, let profileID, activeProfileIDs.contains(profileID) else { return false }
    if let retryable { return retryable }
    return ["failed", "interrupted", "cancelled"].contains(runStatus)
  }

  static func canRequestIntegration(
    policy: String,
    state: String?,
    isActive: Bool,
    hasEligibleMember: Bool,
    requestInFlight: Bool = false,
    recoveryBlocked: Bool = false
  ) -> Bool {
    guard !isActive, hasEligibleMember, !requestInFlight, !recoveryBlocked else { return false }
    if ["requested", "integrating", "adopted", "discarded"].contains(state ?? "") { return false }
    return policy == "manual" || state == "failed"
  }

  static func canDiscardResult(
    integrationState: String?,
    runIsActive: Bool,
    workspaceCleaned: Bool
  ) -> Bool {
    guard !runIsActive, !workspaceCleaned else { return false }
    return !["requested", "integrating", "failed"].contains(integrationState ?? "")
  }
}
