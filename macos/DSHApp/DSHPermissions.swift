import Combine
import Foundation

struct DSHPermissionOption: Decodable, Identifiable, Equatable {
  let value: String
  let name: String
  let description: String?
  var id: String { value }

  var nativeLabel: String {
    switch value {
    case "read-only": "只读"
    case "workspace-write": "工作区访问"
    case "danger-full-access": "完全访问"
    case "custom": "自定义"
    default:
      name.split(separator: "-").map { word in
        word.prefix(1).uppercased() + word.dropFirst()
      }.joined(separator: " ")
    }
  }

  var nativeDetail: String {
    switch value {
    case "read-only": return "可读取文件；写入操作需要审批。"
    case "workspace-write": return "可修改当前工作区和临时目录；越界操作需要审批。"
    case "danger-full-access": return "不受文件沙箱限制，也不会发起审批请求。"
    case "custom": return "当前沙箱与审批设置不匹配任何预设。"
    default:
      guard let description, !description.isEmpty else { return name }
      return description
    }
  }

  var isSelectable: Bool { value != "custom" }
  var requiresConfirmation: Bool { value == "danger-full-access" }
}

struct DSHPermissionSelection: Decodable, Equatable {
  let options: [DSHPermissionOption]
  let currentValue: String

  var currentOption: DSHPermissionOption? {
    options.first { $0.value == currentValue }
  }
}

struct DSHSettingsStringChoice: Equatable {
  let value: String
  let name: String
}

enum DSHSettingsSchema {
  static func stringChoices(in namespace: DSHSettingsNamespace, field: String) -> [DSHSettingsStringChoice] {
    guard let schema = namespace.schema?.object,
          let refs = schema["refs"]?.object,
          let rootKey = referenceKey(schema["uid"]),
          let root = refs[rootKey]?.object,
          let dict = root["dict"]?.object,
          let fieldKey = referenceKey(dict[field]),
          let fieldNode = refs[fieldKey]?.object else { return [] }
    let candidateKeys: [String]
    if fieldNode["type"]?.string == "union" {
      candidateKeys = fieldNode["list"]?.array?.compactMap(referenceKey) ?? []
    } else {
      candidateKeys = [fieldKey]
    }
    return candidateKeys.compactMap { key in
      guard let node = refs[key]?.object,
            node["type"]?.string == "const",
            let value = node["value"]?.string else { return nil }
      let name = node["meta"]?.object?["description"]?.string ?? value
      return DSHSettingsStringChoice(value: value, name: name)
    }
  }

  private static func referenceKey(_ value: DSHJSONValue?) -> String? {
    guard case .number(let number)? = value,
          number.isFinite,
          number.rounded(.towardZero) == number else { return nil }
    return String(Int(number))
  }
}

@MainActor
private final class DSHPermissionClientState {
  struct Snapshot {
    let selection: DSHPermissionSelection
    let seq: Int
  }

  weak var controller: HarnessController?
  var snapshots: [String: Snapshot] = [:]

  init(controller: HarnessController) {
    self.controller = controller
  }

  func set(_ selection: DSHPermissionSelection, for sessionID: String, seq: Int) {
    if let current = snapshots[sessionID], seq < current.seq { return }
    if snapshots[sessionID]?.selection != selection { controller?.objectWillChange.send() }
    snapshots[sessionID] = Snapshot(selection: selection, seq: seq)
  }

  func truncate(sessionID: String, lastSeq: Int) -> Bool {
    guard let current = snapshots[sessionID], current.seq > lastSeq else { return false }
    controller?.objectWillChange.send()
    snapshots.removeValue(forKey: sessionID)
    return true
  }
}

@MainActor
private final class DSHPermissionClientRegistry {
  static let shared = DSHPermissionClientRegistry()
  private var states: [ObjectIdentifier: DSHPermissionClientState] = [:]

  func state(for controller: HarnessController) -> DSHPermissionClientState {
    states = states.filter { $0.value.controller != nil }
    let key = ObjectIdentifier(controller)
    if let state = states[key], let owner = state.controller, owner === controller {
      return state
    }
    let state = DSHPermissionClientState(controller: controller)
    states[key] = state
    return state
  }
}

@MainActor
private final class DSHSettingsChoiceClientState {
  weak var controller: HarnessController?
  var busyNamespaces: Set<String> = []
  var busySessions: Set<String> = []

  init(controller: HarnessController) {
    self.controller = controller
  }

  func beginNamespace(_ namespace: String) -> Bool {
    guard !busyNamespaces.contains(namespace) else { return false }
    controller?.objectWillChange.send()
    busyNamespaces.insert(namespace)
    return true
  }

  func endNamespace(_ namespace: String) {
    guard busyNamespaces.contains(namespace) else { return }
    controller?.objectWillChange.send()
    busyNamespaces.remove(namespace)
  }

  func beginSession(_ sessionID: String) -> Bool {
    guard !busySessions.contains(sessionID) else { return false }
    controller?.objectWillChange.send()
    busySessions.insert(sessionID)
    return true
  }

  func endSession(_ sessionID: String) {
    guard busySessions.contains(sessionID) else { return }
    controller?.objectWillChange.send()
    busySessions.remove(sessionID)
  }
}

@MainActor
private final class DSHSettingsChoiceClientRegistry {
  static let shared = DSHSettingsChoiceClientRegistry()
  private var states: [ObjectIdentifier: DSHSettingsChoiceClientState] = [:]

  func state(for controller: HarnessController) -> DSHSettingsChoiceClientState {
    states = states.filter { $0.value.controller != nil }
    let key = ObjectIdentifier(controller)
    if let state = states[key], let owner = state.controller, owner === controller {
      return state
    }
    let state = DSHSettingsChoiceClientState(controller: controller)
    states[key] = state
    return state
  }
}

private enum DSHPermissionError: LocalizedError {
  case unavailable
  case commandRejected(String)

  var errorDescription: String? {
    switch self {
    case .unavailable: "当前 Host 未提供权限切换能力"
    case .commandRejected(let text): text
    }
  }
}

extension HarnessController {
  private var permissionClientState: DSHPermissionClientState {
    DSHPermissionClientRegistry.shared.state(for: self)
  }

  private var settingsChoiceClientState: DSHSettingsChoiceClientState {
    DSHSettingsChoiceClientRegistry.shared.state(for: self)
  }

  var currentPermissionSelection: DSHPermissionSelection? {
    guard let sessionID = hostCurrentSessionID else { return nil }
    return permissionSelection(sessionID: sessionID)
  }

  func permissionSelection(sessionID: String) -> DSHPermissionSelection? {
    permissionClientState.snapshots[sessionID]?.selection
  }

  var defaultPermissionSelection: DSHPermissionSelection? {
    guard let namespace = permissionSettingsNamespace,
          let currentValue = namespace.value.object?["defaultPreset"]?.string else { return nil }
    let options = DSHSettingsSchema.stringChoices(in: namespace, field: "defaultPreset").map {
      DSHPermissionOption(value: $0.value, name: $0.name, description: nil)
    }
    return DSHPermissionSelection(options: options, currentValue: currentValue)
  }

  var displayedPermissionSelection: DSHPermissionSelection? {
    hostCurrentSessionID == nil ? defaultPermissionSelection : currentPermissionSelection
  }

  var permissionMenuOptions: [DSHPermissionOption] {
    displayedPermissionSelection?.options.filter(\.isSelectable) ?? []
  }

  var activePermissionLabel: String {
    displayedPermissionSelection?.currentOption?.nativeLabel ?? "访问模式"
  }

  var permissionMenuAvailable: Bool {
    activeSubagentAddress == nil && displayedPermissionSelection != nil
  }

  var permissionMenuBusy: Bool {
    guard let sessionID = hostCurrentSessionID else { return permissionSettingsMutationInFlight }
    return settingsChoiceClientState.busySessions.contains(sessionID)
  }

  var permissionSettingsMutationInFlight: Bool {
    settingsChoiceClientState.busyNamespaces.contains("permission")
  }

  var busyEnterSettingsMutationInFlight: Bool {
    settingsChoiceClientState.busyNamespaces.contains("ui-conversation")
  }

  var permissionSettingsNamespace: DSHSettingsNamespace? {
    settingsDescription?.namespaces.first { $0.ns == "permission" }
  }

  func rememberPermissionSelection(_ selection: DSHPermissionSelection?, sessionID: String, seq: Int) {
    guard let selection else { return }
    permissionClientState.set(selection, for: sessionID, seq: seq)
  }

  @discardableResult
  func truncatePermissionSelection(sessionID: String, lastSeq: Int) -> Bool {
    permissionClientState.truncate(sessionID: sessionID, lastSeq: lastSeq)
  }

  func beginSettingsChoiceMutation(_ namespace: String) -> Bool {
    settingsChoiceClientState.beginNamespace(namespace)
  }

  func endSettingsChoiceMutation(_ namespace: String) {
    settingsChoiceClientState.endNamespace(namespace)
  }

  func beginPermissionSessionMutation(_ sessionID: String) -> Bool {
    settingsChoiceClientState.beginSession(sessionID)
  }

  func endPermissionSessionMutation(_ sessionID: String) {
    settingsChoiceClientState.endSession(sessionID)
  }

  func selectPermission(_ value: String, sessionID: String?) {
    if let sessionID {
      guard value != permissionSelection(sessionID: sessionID)?.currentValue else { return }
      switchCurrentPermission(value, sessionID: sessionID)
    } else {
      guard value != defaultPermissionSelection?.currentValue else { return }
      setDefaultPermission(value)
    }
  }

  func setDefaultPermission(_ value: String) {
    guard hostClient != nil,
          let namespace = permissionSettingsNamespace,
          defaultPermissionSelection?.options.contains(where: { $0.value == value && $0.isSelectable }) == true else {
      status = "当前 Host 未提供可写的默认权限设置"
      return
    }
    guard beginSettingsChoiceMutation(namespace.ns) else { return }
    mutateSettings(
      ns: namespace.ns,
      ops: [.set(["defaultPreset"], .string(value))],
      revision: namespace.revision,
      success: { _ in
        self.endSettingsChoiceMutation(namespace.ns)
        self.status = "新会话默认权限已设为\(Self.permissionLabel(value))"
      },
      conflict: {
        self.endSettingsChoiceMutation(namespace.ns)
        self.refreshSettings()
      },
      failure: { _ in self.endSettingsChoiceMutation(namespace.ns) })
  }

  private func switchCurrentPermission(_ value: String, sessionID: String) {
    guard let hostClient,
          permissionSelection(sessionID: sessionID)?.options.contains(where: { $0.value == value && $0.isSelectable }) == true else {
      status = "当前会话没有可用的权限选项"
      return
    }
    guard beginPermissionSessionMutation(sessionID) else { return }
    let localSessionID = sessions.first(where: { $0.hostSessionId == sessionID })?.id
    Task {
      do {
        guard let execution = try await hostClient.executeCommand(
          sessionId: sessionID,
          line: "/permission \(value)") else { throw DSHPermissionError.unavailable }
        guard execution.succeeded else {
          throw DSHPermissionError.commandRejected(execution.result.text ?? "权限切换失败")
        }
        await MainActor.run {
          self.endPermissionSessionMutation(sessionID)
          if self.hostCurrentSessionID == sessionID {
            self.status = "当前会话权限已切换为\(Self.permissionLabel(value))"
          }
          self.refreshHostSnapshots()
        }
      } catch {
        await MainActor.run {
          self.endPermissionSessionMutation(sessionID)
          if let localSessionID {
            self.appendSystem("权限切换失败：\(error.localizedDescription)", to: localSessionID)
          } else if self.hostCurrentSessionID == sessionID {
            self.status = "权限切换失败：\(error.localizedDescription)"
          }
        }
      }
    }
  }

  static func permissionLabel(_ value: String) -> String {
    DSHPermissionOption(value: value, name: value, description: nil).nativeLabel
  }
}
