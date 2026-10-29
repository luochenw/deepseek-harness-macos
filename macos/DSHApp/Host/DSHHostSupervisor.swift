import Foundation

/// Restart policy for the App-owned Host process.
struct DSHHostSupervisorPolicy: Equatable {
  static let `default` = DSHHostSupervisorPolicy()

  /// Restarts allowed inside `window`. The N+1th failure gives up.
  var maximumAttempts = 5
  /// Rolling window for those attempts (seconds).
  var window: TimeInterval = 300
  var baseDelay: TimeInterval = 1
  var maximumDelay: TimeInterval = 16
  /// How long a Host must stay connected before its failures are forgiven.
  var stableInterval: TimeInterval = 45

  /// Exponential backoff: 1s, 2s, 4s, 8s, capped at `maximumDelay`.
  func delay(forAttempt attempt: Int) -> TimeInterval {
    let exponent = Double(max(0, attempt - 1))
    return min(maximumDelay, baseDelay * pow(2, exponent))
  }
}

enum DSHHostRestartDecision: Equatable {
  case restart(attempt: Int, delay: TimeInterval)
  case giveUp(attempts: Int)
}

/// Pure crash-loop accounting, unit-testable without a running Host.
struct DSHHostRestartTracker {
  var policy: DSHHostSupervisorPolicy = .default

  private(set) var failureDates: [Date] = []
  private(set) var gaveUp = false
  private(set) var readyAt: Date?

  var attempts: Int { failureDates.count }
  /// A restart is still allowed (used by the UI to decide what to show).
  var canRestart: Bool { !gaveUp }

  init(policy: DSHHostSupervisorPolicy = .default) {
    self.policy = policy
  }

  /// The Host died without the App asking for it.
  mutating func recordUnexpectedExit(at date: Date) -> DSHHostRestartDecision {
    readyAt = nil
    failureDates = failureDates.filter { date.timeIntervalSince($0) <= policy.window }
    failureDates.append(date)
    guard failureDates.count <= policy.maximumAttempts else {
      gaveUp = true
      return .giveUp(attempts: failureDates.count)
    }
    return .restart(attempt: failureDates.count, delay: policy.delay(forAttempt: failureDates.count))
  }

  /// A launch that never became usable counts like an unexpected exit.
  mutating func recordLaunchFailure(at date: Date) -> DSHHostRestartDecision {
    recordUnexpectedExit(at: date)
  }

  /// Handshake succeeded — not yet proof of stability.
  mutating func recordReady(at date: Date) {
    readyAt = date
  }

  /// Clears the failure history once the Host stays up `stableInterval`.
  @discardableResult
  mutating func recordStabilityCheck(at date: Date) -> Bool {
    guard let readyAt else { return false }
    guard date.timeIntervalSince(readyAt) >= policy.stableInterval else { return false }
    failureDates = []
    gaveUp = false
    self.readyAt = date
    return true
  }

  /// Manual "重新连接 Host": the user asked, so start from a clean slate.
  mutating func recordManualRestart() {
    failureDates = []
    gaveUp = false
    readyAt = nil
  }
}

/// Per-controller supervisor state.
@MainActor
final class DSHHostSupervisorState {
  weak var controller: HarnessController?
  var tracker = DSHHostRestartTracker()
  /// Generation of the newest launch this controller started.
  var generation = 0
  /// A launch is in flight (single-flight guard).
  var launching = false
  /// Pending backoff wake-up.
  var restartTask: Task<Void, Never>?
  /// Generation whose startup failure has already been counted.
  var countedLaunchFailureGeneration: Int?
  /// `stopForTermination()` ran: never restart again in this process lifetime.
  var shuttingDown = false
  /// Periodic stability probe (lets a long-lived Host clear its failure count).
  var stabilityTask: Task<Void, Never>?

  init(controller: HarnessController) {
    self.controller = controller
  }

  /// Count one failure for `generation`, at most once.
  func countLaunchFailureOnce(
    generation: Int,
    at date: Date
  ) -> DSHHostRestartDecision? {
    guard countedLaunchFailureGeneration != generation else { return nil }
    countedLaunchFailureGeneration = generation
    return tracker.recordLaunchFailure(at: date)
  }

  func cancelPendingRestart() {
    restartTask?.cancel()
    restartTask = nil
  }

  func stopStabilityProbe() {
    stabilityTask?.cancel()
    stabilityTask = nil
  }

  deinit {
    restartTask?.cancel()
    stabilityTask?.cancel()
  }
}

@MainActor
final class DSHHostSupervisorRegistry {
  static let shared = DSHHostSupervisorRegistry()
  private var states: [ObjectIdentifier: DSHHostSupervisorState] = [:]

  func state(for controller: HarnessController) -> DSHHostSupervisorState {
    states = states.filter { $0.value.controller != nil }
    let key = ObjectIdentifier(controller)
    if let state = states[key], let owner = state.controller, owner === controller {
      return state
    }
    let state = DSHHostSupervisorState(controller: controller)
    states[key] = state
    return state
  }
}

extension HarnessController {
  /// UI copy shown once automatic restarts are exhausted.
  nonisolated static let hostGaveUpStatus =
    "Host 多次异常退出，自动重启已停止（连续失败 \(DSHHostSupervisorPolicy.default.maximumAttempts + 1) 次），请点击「重新连接 Host」"

  var hostSupervisorState: DSHHostSupervisorState {
    DSHHostSupervisorRegistry.shared.state(for: self)
  }

  /// Entry point used by `init`, `reconnectHostStreams` and the event-stream retry path.
  func startPersistentHost() {
    let state = hostSupervisorState
    guard !state.shuttingDown else { return }
    if state.launching { return }
    if let client = hostClient, let runtime = hostRuntime, runtime.isRunning {
      _ = client // Host is alive; nothing to do.
      return
    }
    if state.restartTask != nil { return }
    if state.tracker.gaveUp { return }
    launchHost(generation: state.generation + 1)
  }

  /// Manual "重新连接 Host" (the dashboard button).
  func manualHostReconnect() {
    let state = hostSupervisorState
    guard !state.shuttingDown else { return }
    state.cancelPendingRestart()
    state.tracker.recordManualRestart()
    if state.launching {
      // Single-flight: the in-flight launch *is* the reconnect, but the click still needs feedback.
      hostStatus = "Host 正在启动，请稍候…"
      return
    }
    if hostRuntime?.isRunning == true, hostClient != nil {
      reconnectHostStreams()
      return
    }
    hostRuntime?.stop()
    hostRuntime = nil
    hostClient = nil
    launchHost(generation: state.generation + 1)
  }

  /// The one place a `DSHHostRuntime` is created and wired.
  func launchHost(generation: Int) {
    let state = hostSupervisorState
    guard !state.shuttingDown else { return }
    state.cancelPendingRestart()
    state.generation = generation
    state.launching = true

    let runtime = DSHHostRuntime(node: bundledNode, dsh: bundledDSH, home: dshHome)
    hostRuntime = runtime
    let attempt = state.tracker.attempts
    hostStatus = attempt > 0 ? "Host 正在重启（第 \(attempt) 次）…" : "Host 启动中…"

    runtime.start(onReady: { [weak self] result in
      guard let self else { return }
      guard self.isCurrentHostLaunch(generation) else {
        // A superseded launch: drop its result without touching state.
        runtime.stop()
        return
      }
      self.hostSupervisorState.launching = false
      switch result {
      case .success(let connection):
        self.hostDidBecomeReady(connection: connection)
      case .failure(let error):
        self.hostLaunchDidFail(error, generation: generation)
      }
    }, onExit: { [weak self] baseURL in
      self?.hostLaunchDidExit(generation: generation, baseURL: baseURL)
    })
  }

  /// Current only while it is both the newest generation and the held runtime.
  func isCurrentHostLaunch(_ generation: Int) -> Bool {
    let state = hostSupervisorState
    return !state.shuttingDown && generation == state.generation
  }

  /// Success path: wire client + streams + refreshes, then publish the bridge record.
  func hostDidBecomeReady(connection: DSHHostConnection) {
    let state = hostSupervisorState
    let client = DSHHostClient(connection: connection)
    hostClient = client
    hostEvents?.stop()
    hostEvents = DSHEventSocket(client: client, onClosed: { [weak self] in
      self?.handleHostStreamClosed()
    })
    hostEvents?.start()
    openRemoteEventStream()
    openSessionControl()
    openWorkspaceFollow()
    hostStatus = "Host 已连接：\(client.baseURL.absoluteString)"
    publishExternalAgentHostFile(connection: connection)
    state.tracker.recordReady(at: Date())
    startHostStabilityProbe()
    refreshHostSnapshots()
    refreshModelConfiguration()
    refreshSettings()
    refreshPresets()
    refreshPermissionCatalog()
    refreshAgentPlatform()
    // No session auto-creation on connect: the first send creates one lazily.
  }

  /// Startup failed for the *current* launch.
  func hostLaunchDidFail(_ error: Error, generation: Int) {
    let state = hostSupervisorState
    // Generation is passed in so a superseded callback cannot touch the newer runtime.
    guard isCurrentHostLaunch(generation) else { return }
    hostRuntime?.stop()
    hostRuntime = nil
    hostClient = nil
    // The other callback for this launch may already have counted it; keep that decision.
    guard let decision = state.countLaunchFailureOnce(generation: generation, at: Date()) else {
      return
    }
    switch decision {
    case .restart(let attempt, let delay):
      hostStatus = "Host 启动失败：\(error.localizedDescription)（\(Int(delay)) 秒后重试，第 \(attempt) 次）"
      scheduleHostRestart(after: delay)
    case .giveUp:
      hostStatus = Self.hostGaveUpStatus
    }
  }

  /// Process-exit callback for the launch that carried `generation`.
  func hostLaunchDidExit(generation: Int, baseURL: URL?) {
    guard isCurrentHostLaunch(generation) else {
      // A new launch can be handed the old port, so a baseURL match alone would
      // retract a live endpoint.
      if let baseURL, let live = hostClient?.baseURL, live.absoluteString == baseURL.absoluteString {
        return
      }
      handleExternalAgentHostExit(baseURL: baseURL)
      return
    }
    hostDidExitUnexpectedly(baseURL: baseURL)
  }

  /// The Host process exited.
  func hostDidExitUnexpectedly(baseURL: URL?) {
    let state = hostSupervisorState
    let generation = state.generation
    state.launching = false
    // The callee refuses to delete a newer launch's file (own pid + exact baseURL).
    handleExternalAgentHostExit(baseURL: baseURL)
    // Detach before stop: the failing receive's `close()` would overwrite the status below.
    hostEvents?.detach()
    hostEvents?.stop()
    hostEvents = nil
    // Clearing it makes `restartHostStreams` come back here instead of dialling a dead port.
    hostClient = nil
    hostRuntime = nil
    state.stopStabilityProbe()

    // A launch that never became ready already reported through `hostLaunchDidFail`.
    guard let decision = state.countLaunchFailureOnce(generation: generation, at: Date()) else {
      return
    }
    switch decision {
    case .restart(let attempt, let delay):
      hostStatus = "Host 已退出，\(Int(delay)) 秒后自动重启（第 \(attempt) 次）"
      scheduleHostRestart(after: delay)
    case .giveUp:
      hostStatus = Self.hostGaveUpStatus
    }
  }

  /// Backoff wake-up → one more launch, still single-flight.
  func scheduleHostRestart(after delay: TimeInterval? = nil) {
    let state = hostSupervisorState
    guard !state.shuttingDown, !state.tracker.gaveUp else { return }
    guard state.restartTask == nil else { return }
    let seconds: TimeInterval
    if let delay {
      seconds = delay
    } else {
      // A launch failure counts as an attempt too; reuse the policy delay.
      seconds = state.tracker.policy.delay(forAttempt: max(1, state.tracker.attempts + 1))
    }
    state.restartTask = Task { [weak self] in
      let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
      try? await Task.sleep(nanoseconds: nanoseconds)
      guard !Task.isCancelled else { return }
      guard let self else { return }
      let state = self.hostSupervisorState
      state.restartTask = nil
      guard !state.shuttingDown, !state.tracker.gaveUp else { return }
      self.launchHost(generation: state.generation + 1)
    }
  }

  /// Forgets earlier failures once the Host has stayed up long enough.
  func startHostStabilityProbe() {
    let state = hostSupervisorState
    state.stopStabilityProbe()
    let interval = max(5, state.tracker.policy.stableInterval / 3)
    state.stabilityTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        guard !Task.isCancelled, let self else { return }
        let state = self.hostSupervisorState
        guard self.hostClient != nil else { return }
        state.tracker.recordStabilityCheck(at: Date())
      }
    }
  }

  /// Quit path.
  func stopHostSupervisorForTermination() {
    let state = hostSupervisorState
    state.shuttingDown = true
    state.cancelPendingRestart()
    state.stopStabilityProbe()
    state.launching = false
  }
}
