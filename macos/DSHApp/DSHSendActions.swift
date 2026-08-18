import Foundation

extension HarnessController {
  func send() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    let image = draftImage
    guard !text.isEmpty || image != nil else { return }
    guard !isViewingReadOnlySubagent else { return }
    var content: [DSHPromptContent] = text.isEmpty ? [] : [.text(text)]
    if let image, let bytes = try? Data(contentsOf: image.url) { content.append(.image(data: bytes.base64EncodedString(), mediaType: image.mediaType, name: image.url.lastPathComponent)) }

    if let hostClient, let address = activeSubagentAddress, address.mode == "continuable" {
      draft = ""
      draftImage = nil
      Task {
        do { try await hostClient.promptSubagent(parentSessionId: address.parentSessionId, childSessionId: address.childSessionId, content: content); await MainActor.run { self.status = "已发送子代理追问" } }
        catch { await MainActor.run { self.appendSystem("子代理追问失败：\(error.localizedDescription)") } }
      }
      return
    }
    // Native command plane for the two lines the web client owns
    // browser-side: the registry's `/export` handler is a web-plugin stub
    // (the real download is a browser effect), so it routes to the carrier's
    // session.export download; `/model` is a client-plane popup upstream and
    // opens the composer's picker here. Bare lines only — with arguments the
    // web adapter wouldn't claim these either.
    if image == nil {
      if text == "/export" { draft = ""; exportCurrentSessionLog(); return }
      if text == "/model" { draft = ""; showModelPicker = true; return }
    }
    guard workspace != nil else { status = "请选择工作区"; chooseWorkspace(); return }
    guard hasCredential else { status = "需要配置 API Key"; showSettings = true; return }
    guard !isRunning else { return }
    // 默认页上的第一条消息：先懒创建会话（本地行 + Host 持久会话），
    // 建好后重入 send()，草稿原样还在。isCreatingFirstSession 挡住
    // 创建期间的重复触发（回车连按/按钮连点）。
    guard let sessionIndex = selectedSessionIndex else {
      guard !isCreatingFirstSession else { return }
      guard hostClient != nil else { status = "Host 未连接，无法发送；请点击重新连接后再试"; return }
      isCreatingFirstSession = true
      insertLocalSessionRow()
      attachHostSessionToCurrentPlaceholder { [weak self] ok in
        guard let self else { return }
        self.isCreatingFirstSession = false
        if ok { self.send() }
      }
      return
    }
    guard let hostClient, let hostSessionID = hostCurrentSessionID else {
      status = "Host 未连接，无法发送；请点击重新连接后再试"
      return
    }

    // Slash commands dispatch through the Typert command registry with a
    // typed result; an unresolvable line falls back to a normal prompt.
    if text.hasPrefix("/"), image == nil {
      draft = ""
      sessions[sessionIndex].messages.append(Message(role: .user, text: text))
      // Gate re-entry the same way the normal-prompt path below does — a
      // fallback to `prompt(...)` starts a real turn, and without this the
      // `guard !isRunning` above never engages, letting a second send fire
      // into the same session while the first is still in flight.
      isRunning = true
      sessions[sessionIndex].isRunning = true
      Task {
        do {
          if let execution = try await hostClient.executeCommand(sessionId: hostSessionID, line: text) {
            await MainActor.run {
              if let output = execution.result.text, !output.isEmpty { self.appendSystem(execution.succeeded ? output : "命令失败：\(output)") }
              else { self.status = execution.succeeded ? "命令已执行" : "命令执行失败" }
              // Command execution isn't a turn — no `turn/end` event will
              // arrive to reset this, unlike the `prompt(...)` fallback below.
              self.isRunning = false
              if let current = self.selectedSessionIndex { self.sessions[current].isRunning = false }
            }
          } else {
            try await hostClient.prompt(sessionId: hostSessionID, content: [.text(text)])
          }
        } catch {
          await MainActor.run {
            self.isRunning = false
            if let current = self.selectedSessionIndex { self.sessions[current].isRunning = false }
            self.appendSystem("命令执行失败：\(error.localizedDescription)")
          }
        }
      }
      return
    }

    draft = ""
    draftImage = nil
    let preview = image == nil ? text : "\(text)\n[图片附件：\(image!.url.lastPathComponent)]"
    // First prompt of a session carries the imported-folder context: the
    // session's Agent only knows its cwd, but every file tool accepts
    // absolute paths — naming the other registered folders is what actually
    // lets the model read them. Sent once (the session keeps it in context),
    // shown to the user as typed.
    var outgoingText = text
    if !sessions[sessionIndex].messages.contains(where: { $0.role == .user }) {
      let current = workspace?.standardizedFileURL.path
      let extras = hostWorkspaces
        .filter { URL(fileURLWithPath: $0.path).standardizedFileURL.path != current }
        .map { "\($0.title)：\($0.path)" }
      if !extras.isEmpty {
        outgoingText += "\n\n[工作区上下文] 除当前目录外，这些本地文件夹也已引入，可用绝对路径读取：\n" + extras.joined(separator: "\n")
      }
    }
    sessions[sessionIndex].messages.append(Message(role: .user, text: preview))
    // No placeholder assistant bubble here — `assistant/chunk` (above) opens
    // a fresh bubble itself on the first delta; a synchronous placeholder
    // previously left either a glued-together "处理中…<real text>" bubble or
    // a dangling stale line once real content replaced it (never cleaned up
    // — see .agents/notes/implemented/bug-fix/2026-08-17-composer-consolidation.md).
    sessions[sessionIndex].isRunning = true
    isRunning = true
    status = "持久 Host 正在处理"
    Task {
      do {
        var content: [DSHPromptContent] = outgoingText.isEmpty ? [] : [.text(outgoingText)]
        if let image, let bytes = try? Data(contentsOf: image.url) { content.append(.image(data: bytes.base64EncodedString(), mediaType: image.mediaType, name: image.url.lastPathComponent)) }
        try await hostClient.prompt(sessionId: hostSessionID, content: content)
        await MainActor.run { self.status = "已交给持久 Host；等待事件流接入" }
      } catch {
        await MainActor.run {
          self.isRunning = false
          if let current = self.selectedSessionIndex { self.sessions[current].isRunning = false }
          self.appendSystem("Host prompt 失败：\(error.localizedDescription)")
        }
      }
    }
  }

  func stop() {
    guard let hostClient, let hostSessionID = hostCurrentSessionID else { return }
    Task {
      do { try await hostClient.cancel(sessionId: hostSessionID); await MainActor.run { self.status = "已请求取消持久会话" } }
      catch { await MainActor.run { self.status = "取消失败：\(error.localizedDescription)" } }
    }
  }
  /// The bundled Host is a long-lived child process, not per-message — this
  /// is the only place it's asked to stop. `deinit` firing is not reliable
  /// for a GUI app's actual quit path, so `applicationWillTerminate` (wired
  /// in DSHNativeApp) calls this explicitly.
  func stopForTermination() { hostRuntime?.stop() }
}
