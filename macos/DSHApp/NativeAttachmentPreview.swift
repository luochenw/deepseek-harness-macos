import SwiftUI

struct AttachmentPreview: View {
  @EnvironmentObject var harness: HarnessController
  let ref: DSHAttachmentRef
  var body: some View {
    Group {
      if let image = harness.attachmentStore.images[ref.attachmentId] {
        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 280, maxHeight: 220)
      } else if let error = harness.attachmentStore.errors[ref.attachmentId] {
        Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
      } else {
        Label("\(ref.name ?? "图片附件") · \(ref.width)×\(ref.height)", systemImage: "photo")
          .font(.caption).foregroundStyle(.secondary)
          .onAppear {
            harness.attachmentStore.image(for: ref, sessionId: harness.hostCurrentSessionID ?? "", client: harness.hostClientForAttachments)
          }
      }
    }
  }
}
