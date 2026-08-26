import Foundation
import AppKit

struct DSHAttachmentPayload: Encodable { let sessionId: String; let attachmentId: String }
struct DSHAttachmentRef: Decodable, Equatable { let attachmentId: String; let mediaType: String; let bytes: Int; let width: Int; let height: Int; let name: String? }
struct DSHAttachmentResult: Decodable { let attachment: DSHAttachmentRef; let data: String }

extension DSHAttachmentRef {
  static func fromHistoryMessage(_ message: DSHJSONValue?) -> Self? {
    guard let content = message?.object?["content"]?.array else { return nil }
    for block in content {
      guard let block = block.object,
            block["type"]?.string == "image",
            let attachment = block["attachment"]?.object else { continue }
      guard let attachmentId = attachment["attachmentId"]?.string,
            let mediaType = attachment["mediaType"]?.string,
            let bytes = historyInteger(attachment["bytes"]) else { continue }
      return Self(
        attachmentId: attachmentId,
        mediaType: mediaType,
        bytes: bytes,
        width: historyInteger(attachment["width"]) ?? 0,
        height: historyInteger(attachment["height"]) ?? 0,
        name: attachment["name"]?.string)
    }
    return nil
  }

  static func fromLiveMessage(_ message: [String: Any]) -> Self? {
    guard let content = message["content"] as? [[String: Any]] else { return nil }
    for block in content {
      guard block["type"] as? String == "image",
            let attachment = block["attachment"] as? [String: Any],
            let attachmentId = attachment["attachmentId"] as? String,
            let mediaType = attachment["mediaType"] as? String,
            let bytes = liveInteger(attachment["bytes"]) else { continue }
      return Self(
        attachmentId: attachmentId,
        mediaType: mediaType,
        bytes: bytes,
        width: liveInteger(attachment["width"]) ?? 0,
        height: liveInteger(attachment["height"]) ?? 0,
        name: attachment["name"] as? String)
    }
    return nil
  }

  private static func historyInteger(_ value: DSHJSONValue?) -> Int? {
    guard case let .number(number)? = value else { return nil }
    return Int(number)
  }

  private static func liveInteger(_ value: Any?) -> Int? {
    if let integer = value as? Int { return integer }
    if let number = value as? NSNumber { return number.intValue }
    if let double = value as? Double { return Int(double) }
    return nil
  }
}

struct DSHAttachmentRailItem: Identifiable, Equatable {
  let messageID: UUID
  let ref: DSHAttachmentRef
  let sessionID: String
  var id: UUID { messageID }
}

enum DSHAttachmentRail {
  static func authorizationSessionID(
    rootSessionID: String?,
    childSessionID: String?,
    showsSubagent: Bool
  ) -> String? {
    normalizedSessionID(showsSubagent ? childSessionID : rootSessionID)
  }

  static func items(messages: [HarnessController.Message], sessionID: String?) -> [DSHAttachmentRailItem] {
    guard let sessionID = normalizedSessionID(sessionID) else { return [] }
    return messages.compactMap { message in
      guard let ref = message.attachment else { return nil }
      return DSHAttachmentRailItem(messageID: message.id, ref: ref, sessionID: sessionID)
    }
  }

  static func matchesLocalUserEcho(
    localText: String,
    incomingText: String,
    attachment: DSHAttachmentRef?
  ) -> Bool {
    guard attachment != nil,
          let marker = localText.range(of: "\n[图片附件：") else { return false }
    return incomingText == String(localText[..<marker.lowerBound])
  }

  private static func normalizedSessionID(_ sessionID: String?) -> String? {
    guard let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !sessionID.isEmpty else { return nil }
    return sessionID
  }
}

@MainActor
final class DSHAttachmentStore: ObservableObject {
  /// Attachment ids are DSH_HOME-global `sha256:` content addresses, so one
  /// decoded bitmap is safe to reuse across root and child session rails.
  @Published private(set) var images: [String: NSImage] = [:]
  @Published private(set) var errors: [String: String] = [:]
  @Published private(set) var loading: Set<String> = []

  func cache(_ image: NSImage, for attachmentId: String) {
    images[attachmentId] = image
    errors[attachmentId] = nil
    loading.remove(attachmentId)
  }

  func beginLoad(for attachmentId: String, retry: Bool = false) -> Bool {
    guard images[attachmentId] == nil, !loading.contains(attachmentId) else { return false }
    guard retry || errors[attachmentId] == nil else { return false }
    errors[attachmentId] = nil
    loading.insert(attachmentId)
    return true
  }

  func recordFailure(_ message: String, for attachmentId: String) {
    loading.remove(attachmentId)
    errors[attachmentId] = message
  }

  func image(for ref: DSHAttachmentRef, sessionId: String, client: DSHHostClient?) {
    requestImage(for: ref, sessionId: sessionId, client: client, retry: false)
  }

  func retryImage(for ref: DSHAttachmentRef, sessionId: String, client: DSHHostClient?) {
    requestImage(for: ref, sessionId: sessionId, client: client, retry: true)
  }

  private func requestImage(for ref: DSHAttachmentRef, sessionId: String, client: DSHHostClient?, retry: Bool) {
    guard let client, beginLoad(for: ref.attachmentId, retry: retry) else { return }
    Task {
      do {
        let result = try await client.attachment(sessionId: sessionId, attachmentId: ref.attachmentId)
        guard let data = Data(base64Encoded: result.data), let image = NSImage(data: data) else { throw URLError(.cannotDecodeContentData) }
        await MainActor.run { self.cache(image, for: ref.attachmentId) }
      } catch { await MainActor.run { self.recordFailure(error.localizedDescription, for: ref.attachmentId) } }
    }
  }
}

extension HarnessController {
  var displayedAttachmentSessionID: String? {
    DSHAttachmentRail.authorizationSessionID(
      rootSessionID: hostCurrentSessionID,
      childSessionID: activeSubagentAddress?.childSessionId,
      showsSubagent: subagentTranscript != nil)
  }

  var displayedAttachmentRailItems: [DSHAttachmentRailItem] {
    DSHAttachmentRail.items(messages: displayedSession?.messages ?? [], sessionID: displayedAttachmentSessionID)
  }

  func loadAttachment(_ ref: DSHAttachmentRef) {
    guard let hostClient, let sessionId = hostCurrentSessionID else { return }
    Task { do { let result = try await hostClient.attachment(sessionId: sessionId, attachmentId: ref.attachmentId); await MainActor.run { self.appendSystem("已读取附件：\(result.attachment.name ?? result.attachment.attachmentId)，\(result.attachment.bytes) bytes") } } catch { await MainActor.run { self.appendSystem("附件读取失败：\(error.localizedDescription)") } } }
  }

  func pickImage() {
    let panel = NSOpenPanel()
    panel.title = "选择图片附件"
    panel.allowedContentTypes = [.png, .jpeg, .webP, .gif]
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let ext = url.pathExtension.lowercased()
    let type = ext == "png" ? "image/png" : ext == "gif" ? "image/gif" : ext == "webp" ? "image/webp" : "image/jpeg"
    draftImage = DraftImage(url: url, mediaType: type)
  }
}
