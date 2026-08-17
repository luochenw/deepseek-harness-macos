import AppKit
import Foundation

/// 语音派活：唤醒词说出的任务不进当前对话，而是派发到一个独立的后台会话
/// 静默执行 —— 见 voice-dispatch Agent Note。工作区判定是两级方案的第一级
/// （本地名称匹配，未命中回落当前工作区）；模型判定留给后续版本。
extension HarnessController {
  func dispatchVoiceTask(_ instruction: String) {
    guard let hostClient else {
      appendSystem("Host 未连接，语音任务未派发：\(instruction)")
      return
    }
    // 工作区判定 v1：话里点到已引入工作区的名字就去那里，否则当前工作区。
    let target = hostWorkspaces.first { workspace in
      !workspace.title.isEmpty && instruction.localizedCaseInsensitiveContains(workspace.title)
    }
    // 派活不依赖工作区：没选工作区、或目录已被删掉，都回退到 Host 的
    // 默认目录建会话（cwd 传 nil 是合法的；带一个不存在的路径反而会
    // 让 session.create 直接失败，派发就"无声无息没反应"了）。
    let candidate = target?.path ?? workspace?.path
    let cwd = candidate.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
    let targetName = target?.title ?? (cwd != nil ? workspaceName : "默认目录")
    if candidate != nil, cwd == nil {
      appendSystem("原工作区目录已不存在，语音任务改在默认目录执行。")
    }
    let presetId = pendingHostPresetID ?? (preset == .creator ? "cordis" : preset.rawValue)
    let (chosenProvider, chosenModel) = (provider, model)
    let chosenEffort = advertisedEffort(provider: chosenProvider, model: chosenModel, requested: reasoningEffort)
    // 第二级判定交给执行任务的模型本身：附上文件夹清单，模型自行决定去
    // 哪个目录干活（工具接受绝对路径）。单独调一次模型判定会加秒级延迟
    // 且要多养一条轻量路由，收益低于让执行者自判。
    var outgoing = instruction
    let roster = hostWorkspaces
      .filter { !$0.title.isEmpty }
      .map { "\($0.title)：\($0.path)" }
    if !roster.isEmpty {
      outgoing += "\n\n[工作区上下文] 已引入的本地文件夹（可用绝对路径访问）：\n" + roster.joined(separator: "\n")
        + "\n若任务针对其中某个文件夹，请直接在对应目录执行；未提及则使用当前目录。"
    }
    Task {
      do {
        let created = try await hostClient.createSession(cwd: cwd, agentPreset: presetId)
        if !chosenProvider.isEmpty, !chosenModel.isEmpty {
          try? await hostClient.selectModel(sessionId: created.sessionId, provider: chosenProvider, model: chosenModel, reasoningEffort: chosenEffort)
        }
        try await hostClient.prompt(sessionId: created.sessionId, content: [.text(outgoing)])
        await MainActor.run {
          self.voiceTaskSessions[created.sessionId] = String(instruction.prefix(24))
          self.appendSystem("语音任务已派发到「\(targetName)」，后台执行中：\(String(instruction.prefix(48)))")
          self.refreshHostSnapshots()
        }
      } catch {
        await MainActor.run {
          self.appendSystem("语音任务派发失败：\(error.localizedDescription)")
          self.nativeAlerts.notifyTurnFinished(summary: "语音任务派发失败")
        }
      }
    }
  }

  /// Mux events for dispatched sessions (everything except the one on
  /// screen is normally dropped) — completion is the signal that matters;
  /// approvals/questions already notify globally through their own frames.
  func handleVoiceTaskEvent(sessionID: String, event: [String: Any]) {
    guard let kind = event["type"] as? String, let label = voiceTaskSessions[sessionID] else { return }
    switch kind {
    case "turn/end":
      voiceTaskSessions[sessionID] = nil
      nativeAlerts.notifyTurnFinished(summary: "语音任务完成：\(label)。点击查看会话列表。")
      nativeAlerts.setBadge(running: !voiceTaskSessions.isEmpty, needsAttention: true)
      refreshHostSnapshots()
    default:
      break
    }
  }
}
