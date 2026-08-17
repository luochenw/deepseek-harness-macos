import AppKit
import Foundation

// Session operations: archived-session listing, session-log ZIP export, and
// Host preset management. Views live in SessionOpsViews.swift.

extension DSHHostClient {
  /// Full workspace.list snapshot INCLUDING the registry-global archive set.
  /// `workspaces()` (DSHHostProtocol.swift) keeps returning `items` only;
  /// this method exists so the archive surface can read `archivedSessionIds`
  /// without disturbing existing call sites.
  func workspaceSnapshot() async throws -> DSHWorkspaceList { try await call("workspace.list", payload: EmptyPayload(), as: DSHWorkspaceList.self) }
}

extension HarnessController {
  // MARK: - Archived sessions

  struct ArchivedSessionRow: Identifiable {
    let sessionId: String
    /// Projection title from session.list; nil when the row has no cached
    /// title (the view falls back to the sessionId).
    let title: String?
    let cwd: String?
    let updatedAt: Date?
    var id: String { sessionId }
  }

  /// Archived ids come from workspace.list's registry-global archive set;
  /// display metadata joins against session.list, which returns every
  /// persisted session — hiding archived rows is a grouping-surface concern,
  /// not a session.list one (workspace.d.ts: "Archived sessions stay in their
  /// workspace's sessionIds account; grouping surfaces hide them").
  /// The protocol registers no unarchive method (rpc-map.d.ts), so restore is
  /// deliberately absent here; the view says so instead.
  func loadArchivedSessions() async -> [ArchivedSessionRow] {
    guard let hostClient else { return [] }
    do {
      async let snapshot = hostClient.workspaceSnapshot()
      async let summaries = hostClient.sessions()
      let (list, sessions) = try await (snapshot, summaries)
      let byId = Dictionary(sessions.map { ($0.sessionId, $0) }, uniquingKeysWith: { first, _ in first })
      return list.archivedSessionIds.map { id in
        let summary = byId[id]
        return ArchivedSessionRow(
          sessionId: id,
          title: summary?.projections?.values.title,
          cwd: summary?.cwd,
          updatedAt: summary.map { Date(timeIntervalSince1970: $0.updatedAt / 1000) },
        )
      }
    } catch {
      status = "读取归档会话失败：\(error.localizedDescription)"
      return []
    }
  }

  // MARK: - Session log export

  func exportCurrentSessionLog() {
    guard let sessionId = hostCurrentSessionID else { status = "当前会话尚未连接持久 Host，无法导出"; return }
    exportSessionLog(sessionId: sessionId)
  }

  /// Streams `GET /api/session.export?sessionId=…&includeDescendants=true`
  /// (the carrier's only download route, no RPC envelope) into
  /// ~/Downloads/dsh-session-<id>.zip, then reveals the file in Finder. The
  /// request carries the same explicit loopback Host header as the RPC
  /// carrier in DSHHostClient.call.
  func exportSessionLog(sessionId: String, includeDescendants: Bool = true) {
    guard let hostClient else { status = "Host 未连接，无法导出会话日志"; return }
    let base = hostClient.baseURL
    guard var components = URLComponents(url: base.appendingPathComponent("api/session.export"), resolvingAgainstBaseURL: false) else { return }
    components.queryItems = [
      URLQueryItem(name: "sessionId", value: sessionId),
      URLQueryItem(name: "includeDescendants", value: includeDescendants ? "true" : "false"),
    ]
    guard let url = components.url else { return }
    var request = URLRequest(url: url)
    request.setValue(base.host.map { host in base.port.map { "\(host):\($0)" } ?? host } ?? "127.0.0.1", forHTTPHeaderField: "Host")
    status = "正在导出会话日志…"
    Task {
      do {
        let (temporary, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
          try? FileManager.default.removeItem(at: temporary)
          throw URLError(.badServerResponse)
        }
        let target = Self.availableDownloadTarget(fileName: "dsh-session-\(sessionId).zip")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: temporary, to: target)
        await MainActor.run {
          self.status = "会话日志已导出：\(target.lastPathComponent)"
          NSWorkspace.shared.activateFileViewerSelecting([target])
        }
      } catch {
        await MainActor.run { self.status = "会话日志导出失败：\(error.localizedDescription)" }
      }
    }
  }

  /// Never overwrite a previous export: dsh-session-x.zip, dsh-session-x-2.zip, …
  private static func availableDownloadTarget(fileName: String) -> URL {
    let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    let base = (fileName as NSString).deletingPathExtension
    let ext = (fileName as NSString).pathExtension
    var candidate = downloads.appendingPathComponent(fileName)
    var counter = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
      candidate = downloads.appendingPathComponent("\(base)-\(counter).\(ext)")
      counter += 1
    }
    return candidate
  }

  // MARK: - Preset management

  /// Refreshes `hostPresets` and returns the full catalog so the manager view
  /// can read the deployment's `authorable` / `hasDocument` facts.
  func loadPresetCatalog() async -> DSHAgentPresetList? {
    guard let hostClient else { return nil }
    do {
      let catalog = try await hostClient.presetCatalog()
      hostPresets = catalog.presets
      return catalog
    } catch {
      status = "读取 Agent 预设失败：\(error.localizedDescription)"
      return nil
    }
  }

  func readHostPreset(_ id: String) async -> DSHPresetReadResult? {
    guard let hostClient else { return nil }
    do { return try await hostClient.readPreset(id) }
    catch { status = "读取预设内容失败：\(error.localizedDescription)"; return nil }
  }

  func copyHostPreset(from source: String, newId: String, name: String?) {
    guard let hostClient else { return }
    let trimmed = newId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    Task {
      do {
        let created = try await hostClient.copyPreset(from: source, to: trimmed, name: name)
        await MainActor.run { self.status = "已复制预设：\(created)"; self.refreshPresets() }
      } catch { await MainActor.run { self.status = "复制预设失败：\(error.localizedDescription)" } }
    }
  }

  /// Returns the resolved directory path when the deployment has no native
  /// opener (`opened: false`); nil after a successful open or a failure
  /// (both surfaced through `status`).
  func openHostPresetDocument(_ id: String) async -> String? {
    guard let hostClient else { return nil }
    do {
      let result = try await hostClient.openPresetDocument(id)
      if result.opened { status = "已在系统编辑器中打开预设目录"; return nil }
      status = "当前部署没有本机打开器，已返回预设目录路径"
      return result.path
    } catch {
      status = "打开预设目录失败：\(error.localizedDescription)"
      return nil
    }
  }

  func removeHostPreset(_ id: String) {
    guard let hostClient else { return }
    Task {
      do {
        try await hostClient.removePreset(id)
        await MainActor.run { self.status = "已删除预设：\(id)"; self.refreshPresets() }
      } catch { await MainActor.run { self.status = "删除预设失败：\(error.localizedDescription)" } }
    }
  }
}
