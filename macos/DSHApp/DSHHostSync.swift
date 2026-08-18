import Foundation

extension HarnessController {
  func refreshPresets() {
    guard let hostClient else { return }
    Task { if let values = try? await hostClient.presets() { await MainActor.run { self.hostPresets = values } } }
  }

  func selectCurrentPreset(_ preset: String) {
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
    guard let client = hostClient else {
      startPersistentHost()
      return
    }
    hostEvents?.stop()
    muxEvents?.stop()
    hostEvents = DSHEventSocket(baseURL: client.baseURL, path: "api/events.host", handler: { [weak self] frame in self?.consumeHostFrame(frame) }, onClosed: { [weak self] in self?.hostStatus = "Host 事件流已断开" })
    muxEvents = DSHEventSocket(baseURL: client.baseURL, path: "api/events.mux", handler: { [weak self] frame in self?.consumeMuxFrame(frame) }, onClosed: { [weak self] in self?.hostStatus = "Host 消息流已断开" })
    hostEvents?.start()
    muxEvents?.start()
    hostStatus = "Host 事件流已重新连接"
    refreshHostSnapshots()
    refreshModelConfiguration()
    refreshSettings()
  }

  func refreshHostSnapshots() {
    guard let hostClient else { return }
    Task {
      do {
        async let sessions = hostClient.sessions()
        async let workspaces = hostClient.workspaceSnapshot()
        let (nextSessions, snapshot) = try await (sessions, workspaces)
        // session.list returns every persisted session — per workspace.d.ts,
        // "archived sessions stay in their workspace's sessionIds account;
        // grouping surfaces hide them". Subtracting the registry's archive
        // set here is that hiding; without it, archiving a session looked
        // like a no-op in the sidebar (the rows came straight back on the
        // next refresh) even though the Host had archived it just fine.
        let archived = Set(snapshot.archivedSessionIds)
        let visibleSessions = nextSessions.filter { !archived.contains($0.sessionId) }
        await MainActor.run {
          self.hostSessions = visibleSessions
          self.hostWorkspaces = snapshot.items
          self.hostStatus = "Host 已同步 \(visibleSessions.count) 个会话 / \(snapshot.items.count) 个工作区"
        }
      } catch {
        await MainActor.run { self.hostStatus = "Host 同步失败：\(error.localizedDescription)" }
      }
    }
  }
}
