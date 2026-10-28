import AppKit
@testable import DSHAppLib

/// Coverage for the Dock-badge replacement of the menu-bar status item — the
/// mitigation for the macOS 27 `MenuBarClientCore` + Swift executor-isolation
/// crash (7 of 13 crash reports went through that path) — plus the
/// reopen/termination lifecycle that replaced the status item's menu.
///
/// Badge writes go through `NativeAlerts.badgeWriter` and the "!"/"•" facts go
/// through the real controller (or a stub), so the state machine is exercised
/// without touching `NSApp`'s Dock tile (needs a real app bundle).

@MainActor
private final class StubFacts: DSHBadgeFactsSource {
  var hasPendingUserAction = false
  var hasBackgroundRunningWork = false
}

@MainActor
private func makeTestAlerts(
  facts: StubFacts? = nil,
  writes: @escaping (String?) -> Void = { _ in }
) -> (alerts: NativeAlerts, facts: StubFacts) {
  let facts = facts ?? StubFacts()
  let alerts = NativeAlerts()
  alerts.facts = facts
  alerts.badgeWriter = writes
  return (alerts, facts)
}

/// Waits for a queued `flushBadge` to run: polls `hasScheduledFlush` instead of
/// sleeping for a fixed interval, so a loaded machine doesn't make it flake.
@MainActor
private func drainMainQueue(_ alerts: NativeAlerts) {
  let deadline = Date().addingTimeInterval(1)
  while alerts.hasScheduledFlush, Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.005))
  }
  // One more turn so the block that cleared the flag has fully returned.
  RunLoop.main.run(until: Date().addingTimeInterval(0.005))
}

private func testBadgeLabels() throws {
  try expectEqual(DSHDockBadge.idle.label, nil)
  try expectEqual(DSHDockBadge.running.label, "•")
  try expectEqual(DSHDockBadge.attention.label, "!")
}

private func testSetBadgeUnchangedDoesNotFlush() throws {
  try MainActor.assumeIsolated {
    var writes = 0
    let (alerts, _) = makeTestAlerts { _ in writes += 1 }
    alerts.attach()
    drainMainQueue(alerts)
    try expectEqual(writes, 1)

    for _ in 0..<5 { alerts.setBadge(running: false, needsAttention: false) }
    drainMainQueue(alerts)
    try expectEqual(writes, 1)

    alerts.setBadge(running: true, needsAttention: false)
    drainMainQueue(alerts)
    try expectEqual(writes, 2)
  }
}

private func testSetBadgeBurstCoalescesIntoOneFlush() throws {
  try MainActor.assumeIsolated {
    var written: [String?] = []
    let (alerts, _) = makeTestAlerts { written.append($0) }
    alerts.attach()
    drainMainQueue(alerts)
    written.removeAll()

    // Same runloop turn: only the last requested state may reach AppKit.
    alerts.setBadge(running: true, needsAttention: false)
    alerts.setBadge(running: false, needsAttention: false)
    alerts.setBadge(running: true, needsAttention: false)
    drainMainQueue(alerts)
    try expectEqual(written.count, 1)
    try expectEqual(written[0], "•")

    // A quiet repeat after the flush is still a no-op.
    alerts.setBadge(running: true, needsAttention: false)
    drainMainQueue(alerts)
    try expectEqual(written.count, 1)
  }
}

private func testBadgeStateMapping() throws {
  try MainActor.assumeIsolated {
    var written: [String?] = []
    let (alerts, facts) = makeTestAlerts { written.append($0) }
    alerts.attach()
    drainMainQueue(alerts)
    try expectEqual(written.last ?? nil, nil)  // idle clears the badge

    alerts.setRunning(true)
    drainMainQueue(alerts)
    try expectEqual(written.last ?? nil, "•")

    facts.hasPendingUserAction = true
    alerts.recomputeBadge()
    try expectEqual(written.last ?? nil, "!")

    // Attention outranks a turn that keeps running.
    alerts.setRunning(true)
    drainMainQueue(alerts)
    try expectEqual(written.last ?? nil, "!")

    facts.hasPendingUserAction = false
    alerts.clearAttention()
    drainMainQueue(alerts)
    try expectEqual(written.last ?? nil, "•")

    alerts.setRunning(false)
    drainMainQueue(alerts)
    try expectEqual(written.last ?? nil, nil)

    // A background voice session alone keeps "•" up.
    facts.hasBackgroundRunningWork = true
    alerts.recomputeBadge()
    drainMainQueue(alerts)
    try expectEqual(written.last ?? nil, "•")
  }
}

private func testAttachIsIdempotent() throws {
  try MainActor.assumeIsolated {
    var writes = 0
    let (alerts, _) = makeTestAlerts { _ in writes += 1 }
    alerts.attach()
    alerts.attach()
    alerts.attach()
    drainMainQueue(alerts)
    try expectEqual(writes, 1)
  }
}

private func testDetachClearsBadgeAndStopsWrites() throws {
  try MainActor.assumeIsolated {
    var written: [String?] = []
    let (alerts, facts) = makeTestAlerts { written.append($0) }
    alerts.attach()
    alerts.setRunning(true)
    drainMainQueue(alerts)
    try expectEqual(written.last ?? nil, "•")

    alerts.detach()
    // Detach clears the Dock badge itself.
    try expectEqual(written.last ?? nil, nil)
    let afterDetach = written.count

    facts.hasPendingUserAction = true
    alerts.recomputeBadge()
    drainMainQueue(alerts)
    try expectEqual(written.count, afterDetach)

    alerts.detach()  // safe twice
    try expect(!alerts.isAttached)
    alerts.attach()
    drainMainQueue(alerts)
    try expect(alerts.isAttached)
    try expectEqual(written.last ?? nil, "!")
  }
}

private func testPreAttachFlushIsReplayedOnAttach() throws {
  try MainActor.assumeIsolated {
    var written: [String?] = []
    let (alerts, _) = makeTestAlerts { written.append($0) }
    // Requested before the Dock may be touched: not recorded as applied.
    alerts.setRunning(true)
    drainMainQueue(alerts)
    try expectEqual(written.count, 0)

    alerts.attach()
    drainMainQueue(alerts)
    try expectEqual(written.count, 1)
    try expectEqual(written[0], "•")
  }
}

private func testAttentionIsWrittenImmediately() throws {
  try MainActor.assumeIsolated {
    var written: [String?] = []
    let (alerts, facts) = makeTestAlerts { written.append($0) }
    alerts.attach()
    drainMainQueue(alerts)
    written.removeAll()

    // No drain: attention must not wait for the coalescing turn, otherwise a
    // turn end in the same runloop turn would swallow the "!" badge.
    facts.hasPendingUserAction = true
    alerts.recomputeBadge()
    try expectEqual(written.count, 1)
    try expectEqual(written[0], "!")

    facts.hasPendingUserAction = false
    alerts.recomputeBadge()
    drainMainQueue(alerts)
    try expectEqual(written.last ?? nil, nil)
  }
}

private func testStaleQueuedFlushIsDiscardedAfterDetach() throws {
  try MainActor.assumeIsolated {
    var written: [String?] = []
    let (alerts, _) = makeTestAlerts { written.append($0) }
    alerts.attach()
    drainMainQueue(alerts)
    written.removeAll()

    alerts.setBadge(running: true, needsAttention: false)  // queued for this cycle
    alerts.detach()                                        // bumps generation
    alerts.attach()
    drainMainQueue(alerts)
    // detach clears, then attach replays the live state: no stale "•" write.
    try expectEqual(written.count, 2)
    try expectEqual(written[0], nil)
    try expectEqual(written[1], "•")
  }
}

// MARK: - "!" facts

private func testTurnEndKeepsAttentionFromAnotherSession() throws {
  try MainActor.assumeIsolated {
    DSHAppLifecycle.resetForTesting()
    let harness = HarnessController(startRuntime: false)
    var written: [String?] = []
    harness.nativeAlerts.badgeWriter = { written.append($0) }
    harness.nativeAlerts.facts = harness
    harness.nativeAlerts.attach()
    drainMainQueue(harness.nativeAlerts)

    // Session A is waiting on an approval while session B is running.
    harness.pendingApproval = HarnessController.PendingApproval(
      id: "a1", rpcId: "a1", sessionId: "A", toolName: "shell", reason: nil)
    harness.isRunning = true
    drainMainQueue(harness.nativeAlerts)
    try expectEqual(written.last ?? nil, "!")

    // Session B finishes — the approval is still unanswered, so "!" stays.
    harness.isRunning = false
    harness.nativeAlerts.notifyTurnFinished(summary: "B 完成")
    drainMainQueue(harness.nativeAlerts)
    try expectEqual(written.last ?? nil, "!")

    // Answered → falls back to "•" while another session still runs.
    harness.pendingApproval = nil
    harness.isRunning = true
    harness.nativeAlerts.clearAttention()
    drainMainQueue(harness.nativeAlerts)
    try expectEqual(written.last ?? nil, "•")

    DSHAppLifecycle.resetForTesting()
  }
}

private func testVoiceCompletionDoesNotFakeAttention() throws {
  try MainActor.assumeIsolated {
    DSHAppLifecycle.resetForTesting()
    let harness = HarnessController(startRuntime: false)
    var written: [String?] = []
    harness.nativeAlerts.badgeWriter = { written.append($0) }
    harness.nativeAlerts.facts = harness
    harness.nativeAlerts.attach()
    drainMainQueue(harness.nativeAlerts)

    harness.voiceTaskSessions["voice-1"] = "语音任务"
    harness.isRunning = true
    harness.nativeAlerts.recomputeBadge()
    drainMainQueue(harness.nativeAlerts)
    try expectEqual(written.last ?? nil, "•")

    // Exactly what handleVoiceTaskEvent(_:event:) does on turn/end.
    harness.voiceTaskSessions["voice-1"] = nil
    harness.isRunning = false
    harness.nativeAlerts.notifyTurnFinished(summary: "语音任务完成")
    drainMainQueue(harness.nativeAlerts)
    try expectEqual(written.last ?? nil, nil)

    DSHAppLifecycle.resetForTesting()
  }
}

private func testAttentionFallsBackAfterResolution() throws {
  try MainActor.assumeIsolated {
    DSHAppLifecycle.resetForTesting()
    let harness = HarnessController(startRuntime: false)
    var written: [String?] = []
    harness.nativeAlerts.badgeWriter = { written.append($0) }
    harness.nativeAlerts.facts = harness
    harness.nativeAlerts.attach()
    drainMainQueue(harness.nativeAlerts)

    harness.isRunning = true
    harness.pendingQuestion = HarnessController.PendingQuestion(
      id: "q1", rpcId: "q1", sessionId: "A", items: [])
    harness.nativeAlerts.recomputeBadge()
    try expectEqual(written.last ?? nil, "!")

    harness.pendingQuestion = nil
    harness.refreshAttentionBadge()
    drainMainQueue(harness.nativeAlerts)
    try expectEqual(written.last ?? nil, "•")

    harness.isRunning = false
    harness.nativeAlerts.setRunning(false)
    drainMainQueue(harness.nativeAlerts)
    try expectEqual(written.last ?? nil, nil)

    DSHAppLifecycle.resetForTesting()
  }
}

// MARK: - Reopen / termination

private func testReopenActivatesExistingWindowOrRequestsNewOne() throws {
  try MainActor.assumeIsolated {
    DSHAppLifecycle.resetForTesting()

    // A hidden/minimised window existed → bring it forward, no new window.
    DSHAppLifecycle.existingWindowActivator = { true }
    try expect(!DSHAppLifecycle.handleReopen())

    // No window at all → ask SwiftUI's WindowGroup to build one.
    DSHAppLifecycle.existingWindowActivator = { false }
    try expect(DSHAppLifecycle.handleReopen())

    DSHAppLifecycle.resetForTesting()
  }
}

private func testSecondInstallKeepsExistingTerminationTarget() throws {
  try MainActor.assumeIsolated {
    DSHAppLifecycle.resetForTesting()
    let first = HarnessController(startRuntime: false)
    let second = HarnessController(startRuntime: false)
    first.nativeAlerts.badgeWriter = { _ in }
    second.nativeAlerts.badgeWriter = { _ in }
    DSHAppLifecycle.install(first.nativeAlerts, terminationOwner: first)
    DSHAppLifecycle.install(second.nativeAlerts, terminationOwner: second)

    DSHAppLifecycle.terminate()
    // The first (real) owner is the one that ran; the second was ignored.
    try expectEqual(DSHAppLifecycle.terminationStopCount, 1)
    try expect(!first.nativeAlerts.isAttached)

    DSHAppLifecycle.resetForTesting()
  }
}

private func testWillTerminateStopsHostOnlyOnce() throws {
  try MainActor.assumeIsolated {
    DSHAppLifecycle.resetForTesting()
    let harness = HarnessController(startRuntime: false)
    harness.nativeAlerts.badgeWriter = { _ in }
    DSHAppLifecycle.install(harness.nativeAlerts, terminationOwner: harness)
    DSHAppLifecycle.markLaunchedAndAttach()

    // Both quit paths: the view-level `.onReceive` and the app delegate.
    harness.stopForTermination()
    DSHAppLifecycle.terminate()
    try expectEqual(DSHAppLifecycle.terminationStopCount, 1)
    try expect(!harness.nativeAlerts.isAttached)

    DSHAppLifecycle.resetForTesting()
  }
}

private func testControllerIsRunningDeduplicatesSameValue() throws {
  try MainActor.assumeIsolated {
    DSHAppLifecycle.resetForTesting()
    let harness = HarnessController(startRuntime: false)
    var writes = 0
    harness.nativeAlerts.badgeWriter = { _ in writes += 1 }
    harness.nativeAlerts.facts = harness
    harness.nativeAlerts.attach()
    drainMainQueue(harness.nativeAlerts)
    let afterAttach = writes

    harness.isRunning = true
    harness.isRunning = true
    harness.isRunning = true
    drainMainQueue(harness.nativeAlerts)
    // `willSet` drops same-value assignments: one state change, one write.
    try expectEqual(writes, afterAttach + 1)

    harness.isRunning = false
    drainMainQueue(harness.nativeAlerts)
    try expectEqual(writes, afterAttach + 2)

    DSHAppLifecycle.resetForTesting()
  }
}

private func testInstallAttachesOnlyAfterLaunch() throws {
  try MainActor.assumeIsolated {
    DSHAppLifecycle.resetForTesting()
    let harness = HarnessController(startRuntime: false)
    var writes = 0
    harness.nativeAlerts.badgeWriter = { _ in writes += 1 }
    DSHAppLifecycle.install(harness.nativeAlerts, terminationOwner: harness)
    drainMainQueue(harness.nativeAlerts)
    // Not launched yet: no attachment, no writes.
    try expect(!harness.nativeAlerts.isAttached)
    try expectEqual(writes, 0)

    DSHAppLifecycle.markLaunchedAndAttach()
    drainMainQueue(harness.nativeAlerts)
    try expect(harness.nativeAlerts.isAttached)
    try expectEqual(writes, 1)

    // A controller created after launch attaches immediately.
    let late = HarnessController(startRuntime: false)
    var lateWrites = 0
    late.nativeAlerts.badgeWriter = { _ in lateWrites += 1 }
    DSHAppLifecycle.install(late.nativeAlerts, terminationOwner: late)
    drainMainQueue(late.nativeAlerts)
    try expect(late.nativeAlerts.isAttached)
    try expectEqual(lateWrites, 1)

    DSHAppLifecycle.resetForTesting()
  }
}

let dshMenuBarTests: [NamedTest] = [
  ("DSHDockBadge maps idle/running/attention to dock labels", testBadgeLabels),
  ("NativeAlerts.setBadge skips an unchanged state", testSetBadgeUnchangedDoesNotFlush),
  ("NativeAlerts.setBadge coalesces a burst into one flush", testSetBadgeBurstCoalescesIntoOneFlush),
  ("NativeAlerts maps running/attention to dock badge labels", testBadgeStateMapping),
  ("NativeAlerts.attach is idempotent", testAttachIsIdempotent),
  ("NativeAlerts.detach clears the badge and stops writes", testDetachClearsBadgeAndStopsWrites),
  ("NativeAlerts replays a pre-attach request on attach", testPreAttachFlushIsReplayedOnAttach),
  ("NativeAlerts writes attention immediately", testAttentionIsWrittenImmediately),
  ("NativeAlerts discards a flush queued before detach", testStaleQueuedFlushIsDiscardedAfterDetach),
  ("A turn end keeps another session's pending attention", testTurnEndKeepsAttentionFromAnotherSession),
  ("Voice completion does not fake an attention badge", testVoiceCompletionDoesNotFakeAttention),
  ("Attention falls back to running/nil after resolution", testAttentionFallsBackAfterResolution),
  ("DSHAppLifecycle reopens an existing window or asks for a new one", testReopenActivatesExistingWindowOrRequestsNewOne),
  ("DSHAppLifecycle keeps its first termination target", testSecondInstallKeepsExistingTerminationTarget),
  ("applicationWillTerminate stops the host only once", testWillTerminateStopsHostOnlyOnce),
  ("HarnessController.isRunning ignores a same-value assignment", testControllerIsRunningDeduplicatesSameValue),
  ("DSHAppLifecycle.install attaches before/after launch", testInstallAttachesOnlyAfterLaunch),
]
