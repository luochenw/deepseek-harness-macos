import Foundation
import AppKit

struct DSHAttachmentPayload: Encodable { let sessionId: String; let attachmentId: String }
struct DSHAttachmentRef: Decodable, Equatable { let attachmentId: String; let mediaType: String; let bytes: Int; let width: Int; let height: Int; let name: String? }
struct DSHAttachmentResult: Decodable { let attachment: DSHAttachmentRef; let data: String }

@MainActor
final class DSHAttachmentStore: ObservableObject {
  @Published private(set) var images: [String: NSImage] = [:]
  @Published private(set) var errors: [String: String] = [:]
  func image(for ref: DSHAttachmentRef, sessionId: String, client: DSHHostClient?) {
    guard images[ref.attachmentId] == nil, errors[ref.attachmentId] == nil, let client else { return }
    Task {
      do {
        let result = try await client.attachment(sessionId: sessionId, attachmentId: ref.attachmentId)
        guard let data = Data(base64Encoded: result.data), let image = NSImage(data: data) else { throw URLError(.cannotDecodeContentData) }
        await MainActor.run { self.images[ref.attachmentId] = image }
      } catch { await MainActor.run { self.errors[ref.attachmentId] = error.localizedDescription } }
    }
  }
}

extension HarnessController {
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
