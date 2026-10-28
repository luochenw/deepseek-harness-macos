import Foundation
@testable import DSHAppLib

/// Tests for the external-agent host file and the Host supervisor's restart
/// policy. Both are exercised through the same seams the App uses: a temporary
/// directory stands in for `DSH_HOME`, and the tracker takes explicit dates so
/// backoff/limits are deterministic instead of wall-clock dependent.
func dshExternalAgentBridgeTests() -> [NamedTest] {
  [
    ("host.json content and 0600 permissions", testHostFileContentAndMode),
    ("host.json removal requires pid and baseURL", testHostFileRemovalGuard),
    ("stale runtime callbacks cannot delete the current record", testStaleGenerationIgnored),
    ("token-less publish retracts the previous record", testTokenlessPublishRetracts),
    ("restart tracker backoff schedule", testRestartTrackerBackoff),
    ("restart tracker gives up after the attempt limit", testRestartTrackerGivesUp),
    ("restart tracker survives the crash-loop window", testRestartTrackerWindow),
    ("restart tracker forgives failures only after stability", testRestartTrackerStability),
    ("manual restart clears the failure history", testRestartTrackerManualReset),
    ("consecutive launch failures reach give-up", testLaunchFailuresReachGiveUp),
    ("one launch counts at most one failure", testLaunchFailureCountedOnce),
    ("both callback orders count one launch failure", testLaunchFailureBothOrders),
    ("stale exit retracts only its own record", testStaleExitRetraction),
    ("launch arguments inject the parent watchdog", testLaunchArgumentsInjectWatchdog),
    ("stop() escalates to SIGKILL after the runtime is released", testStopEscalatesAfterRuntimeRelease),
  ]
}

// MARK: - helpers

private struct TempHome {
  let url: URL
  init(_ label: String) {
    url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("dsh-bridge-\(label)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }
  var hostFile: URL { DSHExternalAgentHostFileStore.url(in: url) }
  func cleanup() { try? FileManager.default.removeItem(at: url) }
  /// Decode whatever is on disk, or nil.
  func read() -> DSHExternalAgentHostFile? {
    guard let data = try? Data(contentsOf: hostFile) else { return nil }
    return try? JSONDecoder().decode(DSHExternalAgentHostFile.self, from: data)
  }
  /// Mode bits, e.g. 0o600.
  func permissions() -> Int? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: hostFile.path),
          let value = attributes[.posixPermissions] as? NSNumber
    else { return nil }
    return value.intValue & 0o777
  }
}

private func record(
  baseURL: String = "http://127.0.0.1:5555",
  token: String = "secret-token",
  appPid: Int32 = getpid(),
  startedAt: String = "2026-10-27T00:00:00Z"
) -> DSHExternalAgentHostFile {
  DSHExternalAgentHostFile(
    version: DSHExternalAgentHostFile.version,
    baseURL: baseURL,
    token: token,
    appPid: appPid,
    startedAt: startedAt)
}

// MARK: - host.json

private func testHostFileContentAndMode() throws {
  let home = TempHome("content")
  defer { home.cleanup() }
  let expected = record()
  try DSHExternalAgentHostFileStore.publish(expected, to: home.url)

  try expectEqual(home.read(), expected)
  try expect(home.permissions() == 0o600, "host.json must be owner-only, got \(String(home.permissions() ?? -1, radix: 8))")
  // No temp file may be left behind next to it.
  let siblings = (try? FileManager.default.contentsOfDirectory(atPath: home.url.path)) ?? []
  try expectEqual(siblings, [DSHExternalAgentHostFile.fileName])
}

private func testHostFileRemovalGuard() throws {
  let home = TempHome("guard")
  defer { home.cleanup() }

  // Another process's record is never removed.
  try DSHExternalAgentHostFileStore.publish(record(appPid: getpid() + 1), to: home.url)
  DSHExternalAgentHostFileStore.remove(from: home.url)
  try expect(home.read() != nil, "a foreign appPid must be preserved")

  // Our record, but a different baseURL: preserved.
  try DSHExternalAgentHostFileStore.publish(record(baseURL: "http://127.0.0.1:5555"), to: home.url)
  DSHExternalAgentHostFileStore.remove(from: home.url, matchingBaseURL: "http://127.0.0.1:6666")
  try expect(home.read() != nil, "a non-matching baseURL must be preserved")

  // Both match: removed.
  DSHExternalAgentHostFileStore.remove(from: home.url, matchingBaseURL: "http://127.0.0.1:5555")
  try expect(home.read() == nil, "own record with matching baseURL must be removed")

  // nil baseURL means "any" for our own pid (the quit path).
  try DSHExternalAgentHostFileStore.publish(record(), to: home.url)
  DSHExternalAgentHostFileStore.remove(from: home.url)
  try expect(home.read() == nil, "quit removal ignores baseURL but requires our pid")
}

/// Item 9 / generation plumbing: a superseded launch's exit goes through the
/// real `hostLaunchDidExit` and must retract exactly the record it served,
/// leaving a newer launch's record alone — plus the port-reuse case where the
/// stale URL equals the one the live client is connected to.
private func testStaleExitRetraction() throws {
  let home = TempHome("stale-exit")
  defer { home.cleanup() }
  let previous = ProcessInfo.processInfo.environment["DSH_APP_HOME"]
  setenv("DSH_APP_HOME", home.url.path, 1)
  defer {
    if let previous { setenv("DSH_APP_HOME", previous, 1) } else { unsetenv("DSH_APP_HOME") }
  }

  let stale = URL(string: "http://127.0.0.1:1111")!
  let fresh = URL(string: "http://127.0.0.1:2222")!

  try MainActor.assumeIsolated {
    let controller = HarnessController(startRuntime: false)
    let state = controller.hostSupervisorState
    state.generation = 7

    // Case 1: the disk record is exactly the stale launch's baseURL → removed.
    try DSHExternalAgentHostFileStore.publish(
      record(baseURL: stale.absoluteString), to: controller.dshHome)
    try expect(home.read()?.baseURL == stale.absoluteString, "precondition: the stale record is on disk")
    controller.hostLaunchDidExit(generation: 6, baseURL: stale)
    try expect(home.read() == nil, "a stale exit must retract the record it published")
    try expectEqual(state.generation, 7)
    try expect(state.tracker.attempts == 0, "a stale exit must not count a failure")

    // Case 2: the disk record belongs to the newer launch → kept.
    try DSHExternalAgentHostFileStore.publish(
      record(baseURL: fresh.absoluteString), to: controller.dshHome)
    controller.hostLaunchDidExit(generation: 6, baseURL: stale)
    try expect(home.read()?.baseURL == fresh.absoluteString,
               "a stale exit must not delete a newer launch's record")

    // Case 3: same port reused by the live Host — the stale URL matches the
    // current client, so deleting it would kill a working endpoint.
    try DSHExternalAgentHostFileStore.publish(
      record(baseURL: fresh.absoluteString), to: controller.dshHome)
    controller.hostClient = DSHHostClient(baseURL: fresh)
    controller.hostLaunchDidExit(generation: 6, baseURL: fresh)
    try expect(home.read()?.baseURL == fresh.absoluteString,
               "an exit whose URL is the live Host's must not delete the record")
    controller.hostClient = nil

    controller.stopHostSupervisorForTermination()
  }
}

/// A launch that fails its handshake and then exits reports the failure twice.
/// Both orders must count exactly once — `onReady(.failure)` → `onExit` and
/// `onExit` → `onReady(.failure)`.
///
/// Exercised through `countLaunchFailureOnce` rather than the full supervisor
/// path: `hostLaunchDidFail`/`hostDidExitUnexpectedly` stop a runtime and arm
/// `scheduleHostRestart`, which would spawn the bundled `node` Host from a unit
/// test. The counter is the only decision-making part, and both callbacks route
/// through it.
private func testLaunchFailureBothOrders() throws {
  try MainActor.assumeIsolated {
    let now = Date()

    // Order 1: onReady(.failure) first.
    let first = HarnessController(startRuntime: false)
    first.hostSupervisorState.generation = 3
    guard let a = first.hostSupervisorState.countLaunchFailureOnce(generation: 3, at: now) else {
      throw TestFailure.message("onReady(.failure) must count the launch")
    }
    guard case .restart(let attemptA, _) = a else {
      throw TestFailure.message("expected a restart decision, got \(a)")
    }
    try expectEqual(attemptA, 1)
    try expect(first.hostSupervisorState.countLaunchFailureOnce(generation: 3, at: now) == nil,
               "the following onExit must not count the same launch again")
    try expectEqual(first.hostSupervisorState.tracker.attempts, 1)
    first.stopHostSupervisorForTermination()

    // Order 2: onExit first.
    let second = HarnessController(startRuntime: false)
    second.hostSupervisorState.generation = 4
    guard let b = second.hostSupervisorState.countLaunchFailureOnce(generation: 4, at: now) else {
      throw TestFailure.message("onExit must count the launch")
    }
    guard case .restart(let attemptB, _) = b else {
      throw TestFailure.message("expected a restart decision, got \(b)")
    }
    try expectEqual(attemptB, 1)
    try expect(second.hostSupervisorState.countLaunchFailureOnce(generation: 4, at: now) == nil,
               "the following onReady(.failure) must not count the same launch again")
    try expectEqual(second.hostSupervisorState.tracker.attempts, 1)
    second.stopHostSupervisorForTermination()
  }
}

private func testStaleGenerationIgnored() throws {  let home = TempHome("stale")
  defer { home.cleanup() }

  // Launch #1 published, then a second launch replaced the record (#2).
  try DSHExternalAgentHostFileStore.publish(record(baseURL: "http://127.0.0.1:1111"), to: home.url)
  try DSHExternalAgentHostFileStore.publish(record(baseURL: "http://127.0.0.1:2222"), to: home.url)

  try MainActor.assumeIsolated {
    let controller = HarnessController(startRuntime: false)
    let state = controller.hostSupervisorState
    state.generation = 7
    state.tracker.recordReady(at: Date())

    // The real callback route: a superseded launch's exit only retracts its own
    // record and touches no supervisor state.
    controller.hostLaunchDidExit(
      generation: 6, baseURL: URL(string: "http://127.0.0.1:1111")!)
    try expect(controller.isCurrentHostLaunch(7), "a stale exit must not clear the current generation")
    try expectEqual(state.generation, 7)
    try expect(state.tracker.attempts == 0, "a stale exit must not count a failure")

    // Generation filtering itself, both ways.
    try expect(controller.isCurrentHostLaunch(7), "current generation is accepted")
    try expect(!controller.isCurrentHostLaunch(6), "an older generation is rejected")
    try expect(!controller.isCurrentHostLaunch(8), "a generation from the future is rejected")

    // After quitting, nothing is current even with a matching generation.
    controller.stopHostSupervisorForTermination()
    try expect(!controller.isCurrentHostLaunch(7), "termination makes every callback stale")
  }
  // The newer launch's record survives the stale launch's retraction: the
  // remove is scoped to the dead launch's own baseURL.
  DSHExternalAgentHostFileStore.remove(from: home.url, matchingBaseURL: "http://127.0.0.1:1111")
  try expect(home.read()?.baseURL == "http://127.0.0.1:2222", "the newer launch's record must survive")
}

private func testTokenlessPublishRetracts() throws {
  let home = TempHome("tokenless")
  defer { home.cleanup() }

  // A previous Host published a usable record; the new connection has no
  // token, so the real publish path must clear it rather than leave a dead
  // endpoint behind.
  try DSHExternalAgentHostFileStore.publish(record(baseURL: "http://127.0.0.1:3333"), to: home.url)
  try DSHExternalAgentHostFileStore.publish(
    record(baseURL: "http://127.0.0.1:4444", token: ""), to: home.url)
  try expect(home.read() == nil, "a token-less publish must retract the old record")

  // A foreign pid's record is still protected by the pid check.
  try DSHExternalAgentHostFileStore.publish(record(appPid: getpid() + 1), to: home.url)
  try DSHExternalAgentHostFileStore.publish(record(token: ""), to: home.url)
  try expect(home.read() != nil, "another instance's record stays")
}

// MARK: - restart policy

private func testRestartTrackerBackoff() throws {
  let policy = DSHHostSupervisorPolicy.default
  var tracker = DSHHostRestartTracker(policy: policy)
  let start = Date(timeIntervalSince1970: 1_000_000)

  var delays: [TimeInterval] = []
  for index in 0..<policy.maximumAttempts {
    let decision = tracker.recordUnexpectedExit(at: start.addingTimeInterval(Double(index)))
    guard case .restart(let attempt, let delay) = decision else {
      throw TestFailure.message("expected a restart, got \(decision)")
    }
    try expectEqual(attempt, index + 1)
    delays.append(delay)
  }
  try expect(delays == [1, 2, 4, 8, 16], "exponential backoff capped at maximumDelay, got \(delays)")
  try expectEqual(tracker.attempts, policy.maximumAttempts)
  try expect(tracker.canRestart, "still restarting at the limit")
}

private func testRestartTrackerGivesUp() throws {
  let policy = DSHHostSupervisorPolicy.default
  var tracker = DSHHostRestartTracker(policy: policy)
  let start = Date(timeIntervalSince1970: 1_000_000)

  for index in 0..<policy.maximumAttempts {
    _ = tracker.recordUnexpectedExit(at: start.addingTimeInterval(Double(index)))
  }
  let decision = tracker.recordUnexpectedExit(at: start.addingTimeInterval(10))
  try expectEqual(decision, .giveUp(attempts: policy.maximumAttempts + 1))
  try expect(tracker.gaveUp, "the tracker must latch give-up")
  try expect(!tracker.canRestart, "no restarts after giving up")

  // Further exits keep reporting give-up instead of reviving the count.
  let again = tracker.recordUnexpectedExit(at: start.addingTimeInterval(20))
  try expectEqual(again, .giveUp(attempts: policy.maximumAttempts + 2))

  // The UI copy must not claim a number the policy does not use.
  let expected = policy.maximumAttempts + 1
  try expect(
    HarnessController.hostGaveUpStatus.contains("\(expected) 次"),
    "the give-up copy must state \(expected) failures, got \(HarnessController.hostGaveUpStatus)")
}

private func testRestartTrackerWindow() throws {
  let policy = DSHHostSupervisorPolicy(maximumAttempts: 3, window: 300, baseDelay: 1, maximumDelay: 16, stableInterval: 45)
  var tracker = DSHHostRestartTracker(policy: policy)
  let start = Date(timeIntervalSince1970: 2_000_000)

  // Three failures inside the window: the fourth gives up.
  for index in 0..<3 {
    _ = tracker.recordUnexpectedExit(at: start.addingTimeInterval(Double(index)))
  }
  try expectEqual(tracker.recordUnexpectedExit(at: start.addingTimeInterval(3)), .giveUp(attempts: 4))
  try expect(tracker.gaveUp)

  // A fresh tracker whose failures are old enough to have aged out keeps going.
  var aged = DSHHostRestartTracker(policy: policy)
  _ = aged.recordUnexpectedExit(at: start)
  _ = aged.recordUnexpectedExit(at: start.addingTimeInterval(1))
  _ = aged.recordUnexpectedExit(at: start.addingTimeInterval(2))
  let later = start.addingTimeInterval(1_000)
  guard case .restart(let attempt, _) = aged.recordUnexpectedExit(at: later) else {
    throw TestFailure.message("old failures should have aged out of the window")
  }
  try expect(attempt == 1, "only the new failure counts after the window, got \(attempt)")
  try expect(!aged.gaveUp, "a windowed-out history must not stay latched")
}

private func testRestartTrackerStability() throws {
  let policy = DSHHostSupervisorPolicy.default
  var tracker = DSHHostRestartTracker(policy: policy)
  let start = Date(timeIntervalSince1970: 3_000_000)

  _ = tracker.recordUnexpectedExit(at: start)
  _ = tracker.recordUnexpectedExit(at: start.addingTimeInterval(1))
  try expectEqual(tracker.attempts, 2)

  // Connected, but not yet long enough: the count must not reset, otherwise a
  // Host that dies every few seconds would restart forever.
  tracker.recordReady(at: start.addingTimeInterval(2))
  let early = tracker.recordStabilityCheck(at: start.addingTimeInterval(2 + policy.stableInterval / 2))
  try expect(!early)
  try expect(tracker.attempts == 2, "failures survive until the Host proves stable, got \(tracker.attempts)")

  let late = tracker.recordStabilityCheck(at: start.addingTimeInterval(2 + policy.stableInterval + 1))
  try expect(late)
  try expect(tracker.attempts == 0, "a stable Host clears its failure history, got \(tracker.attempts)")

  // Stability checks do nothing when the Host never became ready.
  var idle = DSHHostRestartTracker(policy: policy)
  _ = idle.recordUnexpectedExit(at: start)
  try expect(!idle.recordStabilityCheck(at: start.addingTimeInterval(10_000)))
  try expectEqual(idle.attempts, 1)
}

private func testRestartTrackerManualReset() throws {
  let policy = DSHHostSupervisorPolicy.default
  var tracker = DSHHostRestartTracker(policy: policy)
  let start = Date(timeIntervalSince1970: 4_000_000)

  for index in 0...policy.maximumAttempts {
    _ = tracker.recordUnexpectedExit(at: start.addingTimeInterval(Double(index)))
  }
  try expect(tracker.gaveUp, "precondition: the tracker gave up")

  tracker.recordManualRestart()
  try expect(!tracker.gaveUp, "a manual reconnect must clear give-up")
  try expectEqual(tracker.attempts, 0)
  guard case .restart(let attempt, let delay) = tracker.recordUnexpectedExit(at: start.addingTimeInterval(100)) else {
    throw TestFailure.message("a manual reset must allow restarts again")
  }
  try expectEqual(attempt, 1)
  try expectEqual(delay, policy.baseDelay)
}

/// The reported bug: a launch that never became ready (20s handshake timeout, a
/// failed handshake, or a spawn error) was not counted at all, so the App
/// retried forever, ~21s apart, stacking Hosts on the same DSH home.
private func testLaunchFailuresReachGiveUp() throws {
  let policy = DSHHostSupervisorPolicy.default
  var tracker = DSHHostRestartTracker(policy: policy)
  let start = Date(timeIntervalSince1970: 5_000_000)

  for index in 0..<policy.maximumAttempts {
    let decision = tracker.recordLaunchFailure(at: start.addingTimeInterval(Double(index)))
    guard case .restart(let attempt, let delay) = decision else {
      throw TestFailure.message("launch failure \(index + 1) must back off, got \(decision)")
    }
    try expectEqual(attempt, index + 1)
    try expectEqual(delay, policy.delay(forAttempt: index + 1))
  }
  try expectEqual(
    tracker.recordLaunchFailure(at: start.addingTimeInterval(Double(policy.maximumAttempts))),
    .giveUp(attempts: policy.maximumAttempts + 1))
  try expect(tracker.gaveUp, "consecutive launch failures must latch give-up")
  try expect(!tracker.canRestart)
}

/// A Host that fails its handshake and then exits reports the failure twice
/// (`onReady(.failure)` and `onExit`); the supervisor must count the launch
/// once, or it gives up in half the real attempts.
private func testLaunchFailureCountedOnce() throws {
  try MainActor.assumeIsolated {
    let controller = HarnessController(startRuntime: false)
    let state = controller.hostSupervisorState
    state.generation = 3
    let now = Date()

    // First callback counts.
    guard let first = state.countLaunchFailureOnce(generation: 3, at: now) else {
      throw TestFailure.message("the first callback for a launch must count")
    }
    guard case .restart(let attempt, _) = first else {
      throw TestFailure.message("first failure should ask for a restart, got \(first)")
    }
    try expectEqual(attempt, 1)

    // Second callback for the same launch: no decision, no extra count.
    try expect(state.countLaunchFailureOnce(generation: 3, at: now) == nil, "the same launch must not count twice")
    try expectEqual(state.tracker.attempts, 1)

    // A new launch counts again.
    state.generation = 4
    guard state.countLaunchFailureOnce(generation: 4, at: now) != nil else {
      throw TestFailure.message("a new generation is a new failure")
    }
    try expectEqual(state.tracker.attempts, 2)
    state.cancelPendingRestart()
  }
}

/// Parent watchdog: `node --import <data URL>` must run before the Host entry
/// point, and the payload must decode back to the exact JS source.
private func testLaunchArgumentsInjectWatchdog() throws {
  let arguments = DSHHostRuntime.launchArguments(dshPath: "/tmp/dsh/lib/bin.js")
  guard let importIndex = arguments.firstIndex(of: "--import") else {
    throw TestFailure.message("launchArguments must inject --import, got \(arguments)")
  }
  try expect(importIndex + 1 < arguments.count, "‑-import needs a value")
  let value = arguments[importIndex + 1]
  let prefix = "data:text/javascript;base64,"
  try expect(value.hasPrefix(prefix), "the import must be a base64 data URL, got \(value.prefix(40))")
  let encoded = String(value.dropFirst(prefix.count))
  guard let data = Data(base64Encoded: encoded),
        let source = String(data: data, encoding: .utf8)
  else { throw TestFailure.message("the data URL payload must base64-decode to UTF-8 JS") }
  try expectEqual(source, DSHHostRuntime.parentWatchdogSource)
  try expect(source.contains("process.ppid"), "the watchdog must watch the parent pid")
  try expect(source.contains("SIGTERM"), "the watchdog must ask dsh to shut down gracefully")
  // Sending SIGTERM again while dsh is already shutting down makes it force
  // exit without disposing (skipping the session-lock release), so the timer
  // must clear itself before the single kill.
  try expect(source.contains("clearInterval(timer)"), "the watchdog must stop after the first SIGTERM")
  guard let clearIndex = source.range(of: "clearInterval(timer)"),
        let killIndex = source.range(of: "process.kill(process.pid, 'SIGTERM')")
  else { throw TestFailure.message("watchdog is missing the clear/kill pair") }
  try expect(clearIndex.lowerBound < killIndex.lowerBound, "clearInterval must precede the SIGTERM")
  try expect(source.contains("10000"), "the hard-exit fallback must sit after dsh's own 5s shutdown timeout")

  // Relative order of the Host entry point and the `web` subcommand is
  // unchanged; only the Node flag is new and comes first.
  guard let dshIndex = arguments.firstIndex(of: "/tmp/dsh/lib/bin.js"),
        let webIndex = arguments.firstIndex(of: "web")
  else { throw TestFailure.message("missing dsh entry point or web subcommand") }
  try expect(importIndex < dshIndex, "–-import must precede the dsh entry point")
  try expect(dshIndex < webIndex, "the entry point must precede `web`")
}

/// `stop()` must escalate to SIGKILL even after the supervisor dropped the
/// runtime (`hostLaunchDidFail` / `manualHostReconnect` nil it right after
/// `stop()`), and it must hit the pid it launched, not a recycled one. The
/// child here really ignores SIGTERM, and the kill seam records the escalation
/// so the assertion doesn't depend on the signal actually landing.
private func testStopEscalatesAfterRuntimeRelease() throws {
  let savedGrace = DSHHostRuntime.terminateGracePeriod
  let savedKill = DSHHostRuntime.killProcess
  defer {
    DSHHostRuntime.terminateGracePeriod = savedGrace
    DSHHostRuntime.killProcess = savedKill
  }

  // Our own child, never someone else's process.
  let child = Process()
  let ready = Pipe()
  child.executableURL = URL(fileURLWithPath: "/bin/sh")
  child.arguments = ["-c", "trap '' TERM; echo ready; while :; do sleep 1; done"]
  child.standardOutput = ready
  try child.run()
  let pid = child.processIdentifier
  defer {
    if child.isRunning, child.processIdentifier == pid { kill(pid, SIGKILL) }
    child.waitUntilExit()
  }
  // The signal disposition only takes effect once `trap` has run, so wait for
  // the marker instead of racing the shell's startup.
  let marker = ready.fileHandleForReading.availableData
  try expect(String(decoding: marker, as: UTF8.self).contains("ready"), "the child must install its SIGTERM trap before we terminate it")

  DSHHostRuntime.terminateGracePeriod = 0.2
  let lock = NSLock()
  var calls: [(pid: pid_t, signal: Int32)] = []
  DSHHostRuntime.killProcess = { pid, signal in
    lock.lock()
    calls.append((pid, signal))
    lock.unlock()
    return 0
  }

  weak var released: DSHHostRuntime?
  autoreleasepool {
    let runtime = DSHHostRuntime(
      node: URL(fileURLWithPath: "/usr/bin/true"),
      dsh: URL(fileURLWithPath: "/tmp/dsh/bin.js"),
      home: URL(fileURLWithPath: "/tmp/dsh-home"),
      process: child)
    released = runtime
    runtime.stop()
  }
  // The escalation closure must not keep the runtime alive through `self`.
  try expect(released == nil, "stop() must not retain the runtime")
  try expect(child.isRunning, "the child ignores SIGTERM, so it must survive terminate()")

  let deadline = Date().addingTimeInterval(3)
  while Date() < deadline {
    lock.lock()
    let escalated = !calls.isEmpty
    lock.unlock()
    if escalated { break }
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
  }
  lock.lock()
  let recorded = calls
  lock.unlock()
  try expectEqual(recorded.count, 1)
  try expectEqual(recorded.first?.pid, pid)
  try expectEqual(recorded.first?.signal, SIGKILL)
  // The grace period had really elapsed before the escalation.
  try expect(child.isRunning, "the child ignores SIGTERM and should still be running")
}
