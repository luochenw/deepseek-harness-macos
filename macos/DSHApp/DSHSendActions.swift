import Foundation

extension HarnessController {
  func clearPendingLocalUserMessage(localSessionID: UUID, messageID: UUID) {
    guard let sessionIndex = sessions.firstIndex(where: { $0.id == localSessionID }),
          let messageIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == messageID }),
          sessions[sessionIndex].messages[messageIndex].hostMessageId == DSHTranscriptMessageMarker.pendingLocalUserHostMessageID
    else { return }
    sessions[sessionIndex].messages[messageIndex].hostMessageId = nil
  }

  func send() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    let image = draftImage
    guard !text.isEmpty || image != nil else { return }
    guard !isViewingReadOnlySubagent else { return }
    guard !composerSubmissionInFlight else { return }

    if let address = activeSubagentAddress, address.mode == "continuable" {
      submitSubagentComposerDraft(address: address, successStatus: "已发送子代理追问")
      return
    }
    // Native command plane for the two lines the web client owns
    // browser-side: the registry's `/export` handler is a web-plugin stub
    // (the real download is a browser effect), so it routes to the carrier's
    // session.export download; `/model` is a client-plane popup upstream and
    // opens the composer's picker here. Bare lines only — with arguments the
    // web adapter wouldn't claim these either.
    if submitNativeComposerCommandIfNeeded(text: text, hasImage: image != nil) { return }
    // No workspace gate: `session.create` accepts a nil cwd (verified
    // against the live Host — the session runs on the Host's default
    // directory), so a plain conversation needs no folder. Picking one
    // stays available through the header/chips for file work.
    guard hasCredential else { status = "需要配置 API Key"; showSettings = true; return }
    guard !displayedIsRunning else { return }
    // 默认页上的第一条消息：先懒创建会话（本地行 + Host 持久会话），
    // 建好后重入 send()，草稿原样还在。isCreatingFirstSession 挡住
    // 创建期间的重复触发（回车连按/按钮连点）。
    guard let sessionIndex = selectedSessionIndex else {
      guard !isCreatingFirstSession else { return }
      guard hostClient != nil else { status = "Host 未连接，无法发送；请点击重新连接后再试"; return }
      isCreatingFirstSession = true
      let localSessionID = insertLocalSessionRow()
      attachHostSessionToPlaceholder(localSessionID: localSessionID) { [weak self] sessionId in
        guard let self else { return }
        self.isCreatingFirstSession = false
        if let sessionId,
           self.selectedSessionID == localSessionID,
           self.hostCurrentSessionID == sessionId {
          self.send()
        }
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
      var localMessage = Message(role: .user, text: text)
      localMessage.hostMessageId = DSHTranscriptMessageMarker.pendingLocalUserHostMessageID
      sessions[sessionIndex].messages.append(localMessage)
      let pendingMessageID = localMessage.id
      let localSessionID = sessions[sessionIndex].id
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
              self.clearPendingLocalUserMessage(localSessionID: localSessionID, messageID: pendingMessageID)
              if let output = execution.result.text, !output.isEmpty {
                self.appendSystem(execution.succeeded ? output : "命令失败：\(output)", to: localSessionID)
              } else if self.selectedSessionID == localSessionID,
                        self.hostCurrentSessionID == hostSessionID {
                self.status = execution.succeeded ? "命令已执行" : "命令执行失败"
              }
              // Command execution isn't a turn — no `turn/end` event will
              // arrive to reset this, unlike the `prompt(...)` fallback below.
              self.setSubmissionRunning(
                false,
                localSessionID: localSessionID,
                hostSessionID: hostSessionID)
            }
          } else {
            try await hostClient.prompt(sessionId: hostSessionID, content: [.text(text)])
          }
        } catch {
          await MainActor.run {
            self.clearPendingLocalUserMessage(localSessionID: localSessionID, messageID: pendingMessageID)
            self.setSubmissionRunning(
              false,
              localSessionID: localSessionID,
              hostSessionID: hostSessionID)
            self.appendSystem("命令执行失败：\(error.localizedDescription)", to: localSessionID)
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
      let extras = DSHWorkspaceContext.additionalFolders(activeWorkspace: workspace, registered: hostWorkspaces)
        .map { "\($0.title)：\($0.path)" }
      if !extras.isEmpty {
        outgoingText += "\n\n[工作区上下文] 除当前目录外，这些本地文件夹也已引入，可用绝对路径读取：\n" + extras.joined(separator: "\n")
      }
    }
    var localMessage = Message(role: .user, text: preview)
    localMessage.hostMessageId = DSHTranscriptMessageMarker.pendingLocalUserHostMessageID
    sessions[sessionIndex].messages.append(localMessage)
    let pendingMessageID = localMessage.id
    let localSessionID = sessions[sessionIndex].id
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
        await MainActor.run {
          if self.selectedSessionID == localSessionID,
             self.hostCurrentSessionID == hostSessionID {
            self.status = "已交给持久 Host；等待事件流接入"
          }
        }
      } catch {
        await MainActor.run {
          self.clearPendingLocalUserMessage(localSessionID: localSessionID, messageID: pendingMessageID)
          self.setSubmissionRunning(
            false,
            localSessionID: localSessionID,
            hostSessionID: hostSessionID)
          self.appendSystem("Host prompt 失败：\(error.localizedDescription)", to: localSessionID)
        }
      }
    }
  }

  func setSubmissionRunning(
    _ running: Bool,
    localSessionID: UUID,
    hostSessionID: String
  ) {
    if let index = sessions.firstIndex(where: { $0.id == localSessionID }) {
      sessions[index].isRunning = running
    }
    if selectedSessionID == localSessionID && hostCurrentSessionID == hostSessionID {
      isRunning = running
    }
  }

  func stop() {
    guard let hostClient else { return }
    switch displayedExecutionTarget {
    case .subagent(let address):
      Task {
        do {
          try await hostClient.interruptSubagent(
            parentSessionId: address.parentSessionId,
            childSessionId: address.childSessionId)
          await MainActor.run { self.status = "已请求中断子代理" }
        } catch {
          await MainActor.run { self.status = "子代理中断失败：\(error.localizedDescription)" }
        }
      }
      return
    case .root(let sessionID):
      Task {
        do { try await hostClient.cancel(sessionId: sessionID); await MainActor.run { self.status = "已请求取消持久会话" } }
        catch { await MainActor.run { self.status = "取消失败：\(error.localizedDescription)" } }
      }
    case .none:
      return
    }
  }
  /// The bundled Host is a long-lived child process, not per-message — this
  /// is the only place it's asked to stop. `deinit` firing is not reliable
  /// for a GUI app's actual quit path, so `applicationWillTerminate` (wired
  /// in DSHNativeApp) calls this explicitly.
  func stopForTermination() { shutdownWorkbench(); hostRuntime?.stop() }
}
