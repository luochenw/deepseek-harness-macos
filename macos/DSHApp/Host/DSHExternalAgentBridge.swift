import Foundation
import AppKit
import Darwin

/// host.json payload that lets a local external agent (`ds-agent`) reach the App-owned Host
/// instead of starting its own headless run.
struct DSHExternalAgentHostFile: Codable, Equatable {
  static let version = 1
  static let fileName = "host.json"

  let version: Int
  let baseURL: String
  let token: String
  let appPid: Int32
  let startedAt: String
}

/// Production read/write/delete for `host.json`, parameterised by the DSH home directory.
enum DSHExternalAgentHostFileStore {
  static func url(in directory: URL) -> URL {
    directory.appendingPathComponent(DSHExternalAgentHostFile.fileName)
  }

  /// Write via a same-directory temp file + rename(2) so readers never observe a partial JSON
  /// document.
  static func publish(_ record: DSHExternalAgentHostFile, to directory: URL) throws {
    guard record.token.isEmpty == false else {
      remove(from: directory, matchingBaseURL: nil)
      return
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try publish(try encoder.encode(record), to: directory)
  }

  static func publish(_ data: Data, to directory: URL) throws {
    let destination = url(in: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let temporary = directory.appendingPathComponent(
      ".\(DSHExternalAgentHostFile.fileName).\(UUID().uuidString).tmp")
    let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    var failure: Int32 = 0
    data.withUnsafeBytes { buffer in
      guard let base = buffer.baseAddress else { return }
      var offset = 0
      while offset < buffer.count {
        let written = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
        if written <= 0 {
          if errno == EINTR { continue }
          failure = errno
          return
        }
        offset += written
      }
    }
    close(fd)
    guard failure == 0 else {
      try? FileManager.default.removeItem(at: temporary)
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure))
    }
    guard rename(temporary.path, destination.path) == 0 else {
      let code = errno
      try? FileManager.default.removeItem(at: temporary)
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
  }

  /// Remove `host.json` when it still belongs to `pid` and describes `matchingBaseURL` (nil =
  /// any).
  static func remove(
    from directory: URL,
    matchingBaseURL: String? = nil,
    pid: Int32 = getpid()
  ) {
    let file = url(in: directory)
    guard let data = try? Data(contentsOf: file),
          let existing = try? JSONDecoder().decode(DSHExternalAgentHostFile.self, from: data),
          existing.appPid == pid,
          matchingBaseURL == nil || existing.baseURL == matchingBaseURL
    else { return }
    try? FileManager.default.removeItem(at: file)
  }
}

@MainActor
private final class DSHExternalAgentBridgeState {
  weak var controller: HarnessController?
  /// `NSApplication.didBecomeActiveNotification` token, installed once.
  var activationObserver: NSObjectProtocol?
  /// Debounce marker for the foreground snapshot refresh (2s window).
  var lastForegroundRefresh: Date?

  init(controller: HarnessController) {
    self.controller = controller
  }
}

/// Registry keyed by controller identity — the state lives outside `HarnessController` because
/// main.swift is frozen (see AGENTS.md).
@MainActor
private final class DSHExternalAgentBridgeRegistry {
  static let shared = DSHExternalAgentBridgeRegistry()
  private var states: [ObjectIdentifier: DSHExternalAgentBridgeState] = [:]

  func state(for controller: HarnessController) -> DSHExternalAgentBridgeState {
    prune()
    let key = ObjectIdentifier(controller)
    if let state = states[key], let owner = state.controller, owner === controller {
      return state
    }
    let state = DSHExternalAgentBridgeState(controller: controller)
    states[key] = state
    return state
  }

  /// Drop observers for controllers that have been deallocated — an NSObjectProtocol token
  /// retained in a dictionary outlives the block's weak capture otherwise.
  private func prune() {
    let dead = states.filter { $0.value.controller == nil }.map(\.key)
    for key in dead {
      if let token = states[key]?.activationObserver {
        NotificationCenter.default.removeObserver(token)
      }
      states.removeValue(forKey: key)
    }
  }
}

extension HarnessController {
  /// Debounce window for the app-activation snapshot refresh.
  static let externalAgentForegroundRefreshInterval: TimeInterval = 2

  var externalAgentHostFileURL: URL {
    dshHome.appendingPathComponent(DSHExternalAgentHostFile.fileName)
  }

  /// Publish the live Host endpoint for external agents.
  func publishExternalAgentHostFile(connection: DSHHostConnection) {
    installExternalAgentActivationObserver()
    guard let token = connection.launch.token, token.isEmpty == false else {
      // No token ⇒ nothing can be reached through the record, so a file this process wrote earlier
      // (old port, old token) must not survive and point external agents at a dead endpoint.
      removeExternalAgentHostFile(matchingBaseURL: nil)
      return
    }
    let record = DSHExternalAgentHostFile(
      version: DSHExternalAgentHostFile.version,
      baseURL: connection.launch.baseURL.absoluteString,
      token: token,
      appPid: getpid(),
      startedAt: ISO8601DateFormatter().string(from: Date()))
    do {
      try DSHExternalAgentHostFileStore.publish(record, to: dshHome)
    } catch {
      status = "外部 Agent 桥接文件写入失败：\(error.localizedDescription)"
    }
  }

  /// Refresh sidebar snapshots when the App becomes frontmost, so sessions an external process
  /// created while the App was in the background show up without any user action.
  func installExternalAgentActivationObserver() {
    let state = DSHExternalAgentBridgeRegistry.shared.state(for: self)
    guard state.activationObserver == nil else { return }
    state.activationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.refreshHostSnapshotsOnActivation() }
    }
  }

  func refreshHostSnapshotsOnActivation() {
    let state = DSHExternalAgentBridgeRegistry.shared.state(for: self)
    let now = Date()
    if let last = state.lastForegroundRefresh,
       now.timeIntervalSince(last) < Self.externalAgentForegroundRefreshInterval {
      return
    }
    state.lastForegroundRefresh = now
    refreshHostSnapshots()
  }

  /// Called from `DSHHostRuntime`'s termination handler when the Host process exits (crash, kill,
  /// or the terminate issued by `stopForTermination()`).
  func handleExternalAgentHostExit(baseURL: URL?) {
    guard let baseURL else { return }
    removeExternalAgentHostFile(matchingBaseURL: baseURL.absoluteString)
  }

  /// Remove host.json when this process owns it and it still describes `baseURL` (nil = any).
  func removeExternalAgentHostFile(matchingBaseURL baseURL: String? = nil) {
    DSHExternalAgentHostFileStore.remove(from: dshHome, matchingBaseURL: baseURL)
  }
}
