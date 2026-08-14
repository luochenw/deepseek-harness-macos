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
