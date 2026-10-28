import Foundation

enum DSHHostReconnectPolicy {
  static let maximumAttempts = 5
  static func delayNanoseconds(attempt: Int) -> UInt64 {
    UInt64(max(1, attempt)) * 750_000_000
  }
}

@MainActor
private final class DSHHostReconnectState {
  weak var controller: HarnessController?
  var task: Task<Void, Never>?
  var attempts = 0

  init(controller: HarnessController) {
    self.controller = controller
  }

  func cancel() {
    task?.cancel()
    task = nil
  }
}

@MainActor
private final class DSHHostReconnectRegistry {
  static let shared = DSHHostReconnectRegistry()
  private var states: [ObjectIdentifier: DSHHostReconnectState] = [:]

  func state(for controller: HarnessController) -> DSHHostReconnectState {
    states = states.filter { $0.value.controller != nil }
    let key = ObjectIdentifier(controller)
    if let state = states[key], let owner = state.controller, owner === controller {
      return state
    }
    let state = DSHHostReconnectState(controller: controller)
    states[key] = state
    return state
  }
}

extension HarnessController.Preset {
  var hostPresetID: String {
    switch self {
    case .standard: "standard"
    case .code: "ptc"
    case .minimal: "minimal"
    case .creator: "cordis"
    }
  }
}

extension HarnessController {
  private var hostReconnectState: DSHHostReconnectState {
    DSHHostReconnectRegistry.shared.state(for: self)
  }

  func handleHostStreamClosed() {
    hostStatus = "Host 消息流已断开，正在自动重连"
    clearPendingModelWorkbenchRequests()
    scheduleHostReconnect()
  }

  func hostStreamDidBecomeReady() {
    let state = hostReconnectState
    state.attempts = 0
    state.cancel()
  }

  private func scheduleHostReconnect() {
    let state = hostReconnectState
    guard state.task == nil,
          state.attempts < DSHHostReconnectPolicy.maximumAttempts else {
      if state.attempts >= DSHHostReconnectPolicy.maximumAttempts {
        hostStatus = "Host 自动重连失败，请手动重新连接"
      }
      return
    }
    state.attempts += 1
    let attempt = state.attempts
    state.task = Task { [weak self] in
      try? await Task.sleep(
        nanoseconds: DSHHostReconnectPolicy.delayNanoseconds(attempt: attempt))
      guard !Task.isCancelled else { return }
      state.task = nil
      guard state.controller === self else { return }
      self?.restartHostStreams()
    }
  }

  nonisolated static func canonicalHostPresetID(_ value: String) -> String {
    switch value {
    case "code": "ptc"
    case "creator": "cordis"
    default: value
    }
  }
}

extension HarnessController {
  func refreshPresets() {
    guard let hostClient else { return }
    Task { if let values = try? await hostClient.presets() { await MainActor.run { self.hostPresets = values } } }
  }

  func selectCurrentPreset(_ preset: String) {
    let preset = Self.canonicalHostPresetID(preset)
    // Lazy sessions: before the first message there is no Host session to
    // select on — remember the choice instead of silently dropping it (点了
    // 没反应 = "无法切换模式"), and apply it when the session is created.
    guard let hostClient, let sessionId = hostCurrentSessionID else {
      pendingHostPresetID = preset
      return
    }
    Task {
      do { try await hostClient.selectPreset(sessionId: sessionId, preset: preset); await MainActor.run { self.status = "已切换 Agent preset：\(preset)"; self.refreshHostSnapshots() } }
      catch { await MainActor.run { self.appendSystem("Preset 切换失败：\(error.localizedDescription)") } }
    }
  }

  /// Chip label for the preset control: the pending (not-yet-created-session)
  /// choice wins over the local default enum.
  var activePresetLabel: String {
    if let pending = pendingHostPresetID {
      return hostPresets.first(where: { $0.id == pending })?.name ?? pending
    }
    return preset.label
  }

  func refreshSettings() {
    guard let hostClient else { return }
    Task {
      do {
        let description = try await hostClient.settings()
        await MainActor.run { self.settingsDescription = description }
      } catch { await MainActor.run { self.status = "设置读取失败：\(error.localizedDescription)" } }
    }
  }

  func refreshSessionModels() {
    guard let hostClient, let sessionId = hostCurrentSessionID else { return }
    Task {
      do {
        let models = try await hostClient.sessionModels(sessionId: sessionId)
        await MainActor.run {
          guard self.hostCurrentSessionID == sessionId else { return }
          self.currentSessionModels = models
          self.provider = models.current.provider
          self.model = models.current.model
          if let effort = models.current.reasoningEffort { self.reasoningEffort = effort }
        }
      } catch {
        await MainActor.run { self.status = "会话模型读取失败：\(error.localizedDescription)" }
      }
    }
  }

  func refreshModelConfiguration() {
    guard let hostClient else { return }
    Task {
      do {
        async let models = hostClient.models()
        async let providers = hostClient.providers()
        async let settings = hostClient.settings()
        let (nextModels, nextProviders, nextSettings) = try await (models, providers, settings)
        let refs = Self.credentialReferences(in: nextSettings)
        let credentials = try await hostClient.credentials(refs: refs)
        await MainActor.run {
          self.availableModels = nextModels
          self.credentialStates = credentials
          self.configurableProviders = nextProviders
          self.settingsDescription = nextSettings
          if !self.provider.isEmpty,
             !nextModels.contains(where: { group in group.id == self.provider && group.models.contains(where: { $0.id == self.model }) }) {
            self.provider = ""
            self.model = ""
            UserDefaults.standard.removeObject(forKey: providerKey)
            UserDefaults.standard.removeObject(forKey: modelKey)
          }
        }
      } catch { await MainActor.run { self.status = "模型配置读取失败：\(error.localizedDescription)" } }
    }
  }

  func reconnectHostStreams() {
    let state = hostReconnectState
    state.cancel()
    state.attempts = 0
    restartHostStreams()
  }

  private func restartHostStreams() {
    guard let client = hostClient else {
      startPersistentHost()
      return
    }
    cancelRootSessionFollow()
    hostEvents?.stop()
    hostEvents = DSHEventSocket(client: client, onClosed: { [weak self] in
      self?.handleHostStreamClosed()
    })
    hostEvents?.start()
    openRemoteEventStream()
    openSessionControl()
    openWorkspaceFollow()
    if let sessionID = hostCurrentSessionID, let localSessionID = selectedSessionID {
      let messages = sessions.first(where: { $0.id == localSessionID })?.messages ?? []
      let summary = hostSessions.first(where: { $0.sessionId == sessionID })
      let reuseCache = summary.map {
        DSHHistoryCachePolicy.canReuse(
          cached: cachedRootHistoryVersion(sessionID: sessionID),
          hostSequence: $0.projections?.asOfSeq,
          hostUpdatedAt: $0.updatedAt,
          hasMessages: !messages.isEmpty)
      } ?? false
      startRootSessionFollow(
        sessionID: sessionID,
        localSessionID: localSessionID,
        preservingCachedHistory: reuseCache,
        retainingVisibleHistory: true)
    }
    hostStatus = "Host 事件流已重新连接"
    refreshHostSnapshots()
    refreshModelConfiguration()
    refreshSettings()
    refreshPermissionCatalog()
    refreshAgentPlatform()
  }

  func refreshHostSnapshots() {
    guard let hostClient else { return }
    Task {
      do {
        let nextSessions = try await hostClient.sessions()
        let snapshot = await MainActor.run { self.hostWorkspaceSnapshot }
        // session.list returns every persisted session — per workspace.d.ts,
        // "archived sessions stay in their workspace's sessionIds account;
        // grouping surfaces hide them". Subtracting the registry's archive
        // set here is that hiding; without it, archiving a session looked
        // like a no-op in the sidebar (the rows came straight back on the
        // next refresh) even though the Host had archived it just fine.
        let archived = Set(snapshot.archivedSessionIds)
        let visibleSessions = nextSessions.filter { !archived.contains($0.sessionId) }
        await MainActor.run {
          self.discardArchivedWorkbenchContexts(hostSessionIDs: archived)
          if let current = self.hostCurrentSessionID, archived.contains(current) {
            self.clearToDefaultPage()
          }
          self.hostSessions = visibleSessions
          self.hostWorkspaces = snapshot.items
          if let sessionID = self.hostCurrentSessionID,
             let localSessionID = self.selectedSessionID,
             let summary = visibleSessions.first(where: { $0.sessionId == sessionID }),
             !summary.running {
            // A list refresh is the explicit recovery action after a missed
            // turn boundary. Only an idle result clears here; a running row
            // stays authoritative until its terminal event or follow snapshot.
            self.reconcileRootSessionRunningState(
              sessionID: sessionID,
              localSessionID: localSessionID,
              running: false)
          }
          self.resumePendingModelWorkbenchRequests()
          for summary in visibleSessions {
            self.rememberPermissionSelection(
              summary.projections?.values.permissions,
              sessionID: summary.sessionId,
              seq: summary.projections?.asOfSeq ?? -1)
          }
          self.hostStatus = "Host 已同步 \(visibleSessions.count) 个会话 / \(snapshot.items.count) 个工作区"
        }
      } catch {
        await MainActor.run { self.hostStatus = "Host 同步失败：\(error.localizedDescription)" }
      }
    }
  }
}
