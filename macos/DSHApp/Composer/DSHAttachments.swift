import Foundation
import AppKit
import UniformTypeIdentifiers

struct DSHAttachmentPayload: Encodable { let sessionId: String; let attachmentId: String }
struct DSHAttachmentRef: Decodable, Equatable { let attachmentId: String; let mediaType: String; let bytes: Int; let width: Int; let height: Int; let name: String? }
struct DSHAttachmentResult: Decodable { let attachment: DSHAttachmentRef; let data: String }

extension DSHAttachmentRef {
  static func fromHistoryMessage(_ message: DSHJSONValue?) -> Self? {
    fromHistoryContent(message?.object?["content"]?.array ?? []).first
  }

  static func fromHistoryContent(_ content: [DSHJSONValue]) -> [Self] {
    content.compactMap { block in
      guard let block = block.object,
            block["type"]?.string == "image",
            let attachment = block["attachment"]?.object,
            let attachmentId = attachment["attachmentId"]?.string,
            let mediaType = attachment["mediaType"]?.string,
            let bytes = historyInteger(attachment["bytes"])
      else { return nil }
      return Self(
        attachmentId: attachmentId,
        mediaType: mediaType,
        bytes: bytes,
        width: historyInteger(attachment["width"]) ?? 0,
        height: historyInteger(attachment["height"]) ?? 0,
        name: attachment["name"]?.string)
    }
  }

  static func fromLiveMessage(_ message: [String: Any]) -> Self? {
    fromLiveContent(message["content"] as? [[String: Any]] ?? []).first
  }

  static func fromLiveContent(_ content: [[String: Any]]) -> [Self] {
    return content.compactMap { block in
      guard block["type"] as? String == "image",
            let attachment = block["attachment"] as? [String: Any],
            let attachmentId = attachment["attachmentId"] as? String,
            let mediaType = attachment["mediaType"] as? String,
            let bytes = liveInteger(attachment["bytes"])
      else { return nil }
      return Self(
        attachmentId: attachmentId,
        mediaType: mediaType,
        bytes: bytes,
        width: liveInteger(attachment["width"]) ?? 0,
        height: liveInteger(attachment["height"]) ?? 0,
        name: attachment["name"] as? String)
    }
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
  static let maximumDraftImageCount = 20

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
    panel.allowsMultipleSelection = true
    guard panel.runModal() == .OK else { return }
    appendDraftImages(panel.urls.compactMap(draftImage(for:)))
  }

  func appendDraftImages(_ images: [DraftImage]) {
    let existing = Set(draftImages.map { $0.url.standardizedFileURL.path })
    let remaining = max(0, Self.maximumDraftImageCount - draftImages.count)
    var accepted: [DraftImage] = []
    var seen = existing
    var duplicateCount = 0
    var overLimitCount = 0
    for image in images {
      let path = image.url.standardizedFileURL.path
      guard !seen.contains(path) else {
        duplicateCount += 1
        continue
      }
      guard accepted.count < remaining else {
        overLimitCount += 1
        continue
      }
      seen.insert(path)
      accepted.append(image)
    }
    guard !accepted.isEmpty else {
      if overLimitCount > 0 {
        status = "最多添加 \(Self.maximumDraftImageCount) 张图片"
      } else if duplicateCount > 0 {
        status = "这些图片已在输入框中"
      }
      return
    }
    draftImages.append(contentsOf: accepted)
    var details: [String] = []
    if duplicateCount > 0 { details.append("忽略 \(duplicateCount) 张重复图片") }
    if overLimitCount > 0 { details.append("已达 \(Self.maximumDraftImageCount) 张上限") }
    status = (["已添加 \(accepted.count) 张图片"] + details).joined(separator: "，")
  }

  func removeDraftImage(_ id: UUID) {
    draftImages.removeAll { $0.id == id }
  }

  func imagePromptContents(_ images: [DraftImage]) throws -> [DSHPromptContent] {
    try images.map { image in
      let bytes = try Data(contentsOf: image.url)
      return .image(
        data: bytes.base64EncodedString(),
        mediaType: image.mediaType,
        name: image.url.lastPathComponent)
    }
  }

  static func draftPreviewText(_ text: String, images: [DraftImage]) -> String {
    guard !images.isEmpty else { return text }
    let names = images.map(\.url.lastPathComponent).joined(separator: "、")
    return text + (text.isEmpty ? "" : "\n") + "[图片附件：\(names)]"
  }

  @discardableResult
  func pasteImageFromPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
    let fileURLs = (pasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [
        .urlReadingFileURLsOnly: true,
        .urlReadingContentsConformToTypes: [UTType.image.identifier],
      ]) as? [URL]) ?? []
    let files = fileURLs.compactMap(draftImage(for:))
    if !files.isEmpty {
      appendDraftImages(files)
      return true
    }
    guard let image = NSImage(pasteboard: pasteboard), !image.representations.isEmpty else {
      return false
    }
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else {
      status = "无法读取剪贴板图片"
      return true
    }
    let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
      .first?
      .appendingPathComponent("com.github.deepseek-harness-macos.app/pasted-images", isDirectory: true)
      ?? FileManager.default.temporaryDirectory.appendingPathComponent("DSH-Pasted-Images", isDirectory: true)
    let target = directory.appendingPathComponent("Pasted-\(UUID().uuidString).png")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try png.write(to: target, options: .atomic)
      appendDraftImages([DraftImage(url: target, mediaType: "image/png")])
    } catch {
      status = "保存剪贴板图片失败：\(error.localizedDescription)"
    }
    return true
  }

  private func draftImage(for url: URL) -> DraftImage? {
    guard let type = UTType(filenameExtension: url.pathExtension),
          type.conforms(to: .image)
    else { return nil }
    return DraftImage(url: url, mediaType: type.preferredMIMEType ?? "application/octet-stream")
  }
}
