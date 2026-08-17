import SwiftUI

struct AttachmentPreview: View {
  @EnvironmentObject var harness: HarnessController
  let ref: DSHAttachmentRef
  @State private var showLightbox = false
  var body: some View {
    Group {
      if let image = harness.attachmentStore.images[ref.attachmentId] {
        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 280, maxHeight: 220)
          .clipShape(RoundedRectangle(cornerRadius: DSHRadius.md))
          .contentShape(Rectangle())
          .onTapGesture { showLightbox = true }
          .help("点击放大查看")
          .sheet(isPresented: $showLightbox) { AttachmentLightbox(image: image, name: ref.name) }
      } else if let error = harness.attachmentStore.errors[ref.attachmentId] {
        Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(DSHTheme.coral)
      } else {
        Label("\(ref.name ?? "图片附件") · \(ref.width)×\(ref.height)", systemImage: "photo")
          .font(.caption).foregroundStyle(DSHTheme.inkFaint)
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

  // The lightbox canvas is intentionally fixed-dark regardless of system
  // appearance (image viewers conventionally use a dark surround to frame the
  // photo) — DSHTheme.ink resolves dark in light mode and would be unreadable
  // on this black canvas, so toolbar content deliberately uses a fixed
  // near-white literal instead of a theme token. `.dshGhost` is avoided here
  // for the same reason: it resolves to DSHTheme.inkSoft, which is illegible
  // on this always-dark surface.
  private static let lightboxText = Color(white: 0.94)

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(name ?? "图片附件").font(.caption).foregroundStyle(Self.lightboxText).lineLimit(1)
        Spacer()
        Button("缩小") { setZoom(zoom / 1.25) }.buttonStyle(.plain).foregroundStyle(Self.lightboxText)
        Button("适应窗口") { setZoom(1) }.buttonStyle(.plain).foregroundStyle(Self.lightboxText)
        Button("放大") { setZoom(zoom * 1.25) }.buttonStyle(.plain).foregroundStyle(Self.lightboxText)
        Button(action: { dismiss() }) { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(Self.lightboxText)
      }
      .padding(DSHSpace.s3)
      .background(Color.black.opacity(0.92))
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
