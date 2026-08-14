import SwiftUI

struct AttachmentPreview: View {
  @EnvironmentObject var harness: HarnessController
  let ref: DSHAttachmentRef
  @State private var showLightbox = false
  var body: some View {
    Group {
      if let image = harness.attachmentStore.images[ref.attachmentId] {
        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 280, maxHeight: 220)
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .contentShape(Rectangle())
          .onTapGesture { showLightbox = true }
          .help("点击放大查看")
          .sheet(isPresented: $showLightbox) { AttachmentLightbox(image: image, name: ref.name) }
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

/// Zoomable, pannable full-size view of an already-fetched attachment image.
/// See .agents/notes/implemented/feature/2026-08-14-attachment-lightbox.md.
private struct AttachmentLightbox: View {
  @Environment(\.dismiss) private var dismiss
  let image: NSImage
  let name: String?
  @State private var zoom: CGFloat = 1
  @State private var lastZoom: CGFloat = 1

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(name ?? "图片附件").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        Spacer()
        Button("缩小") { setZoom(zoom / 1.25) }
        Button("适应窗口") { setZoom(1) }
        Button("放大") { setZoom(zoom * 1.25) }
        Button(action: { dismiss() }) { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
      }.padding(10)
      Divider()
      ScrollView([.horizontal, .vertical]) {
        Image(nsImage: image)
          .resizable().scaledToFit()
          .scaleEffect(zoom)
          .frame(minWidth: 560, minHeight: 420)
      }
      .background(Color.black.opacity(0.85))
      .gesture(
        MagnificationGesture()
          .onChanged { value in zoom = max(0.2, min(lastZoom * value, 8)) }
          .onEnded { _ in lastZoom = zoom }
      )
    }
    .frame(minWidth: 640, minHeight: 520)
    .onExitCommand { dismiss() }
  }

  private func setZoom(_ value: CGFloat) { zoom = max(0.2, min(value, 8)); lastZoom = zoom }
}
