import SwiftUI

struct AttachmentPreview: View {
  @EnvironmentObject private var harness: HarnessController
  let ref: DSHAttachmentRef
  let sessionID: String?
  @State private var showLightbox = false

  var body: some View {
    AttachmentInlinePreview(
      store: harness.attachmentStore,
      ref: ref,
      sessionID: sessionID,
      onOpen: { showLightbox = true },
      onLoad: loadImage,
      onRetry: retryImage)
    .sheet(isPresented: $showLightbox) {
      AttachmentLightbox(
        store: harness.attachmentStore,
        ref: ref,
        onLoad: loadImage,
        onRetry: retryImage)
    }
  }

  private func loadImage() {
    guard let sessionID else { return }
    harness.attachmentStore.image(for: ref, sessionId: sessionID, client: harness.hostClientForAttachments)
  }

  private func retryImage() {
    guard let sessionID else { return }
    harness.attachmentStore.retryImage(for: ref, sessionId: sessionID, client: harness.hostClientForAttachments)
  }
}

struct AttachmentRail: View {
  @EnvironmentObject private var harness: HarnessController
  let items: [DSHAttachmentRailItem]
  @State private var selectedItem: DSHAttachmentRailItem?

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      LazyHStack(spacing: DSHSpace.s2) {
        ForEach(items) { item in
          AttachmentRailThumbnail(
            store: harness.attachmentStore,
            item: item,
            onOpen: { selectedItem = item },
            onLoad: {
              harness.attachmentStore.image(
                for: item.ref,
                sessionId: item.sessionID,
                client: harness.hostClientForAttachments)
            },
            onRetry: {
              harness.attachmentStore.retryImage(
                for: item.ref,
                sessionId: item.sessionID,
                client: harness.hostClientForAttachments)
            })
        }
      }
      .padding(.vertical, 2)
    }
    .frame(height: 56)
    .sheet(item: $selectedItem) { item in
      AttachmentLightbox(
        store: harness.attachmentStore,
        ref: item.ref,
        onLoad: {
          harness.attachmentStore.image(
            for: item.ref,
            sessionId: item.sessionID,
            client: harness.hostClientForAttachments)
        },
        onRetry: {
          harness.attachmentStore.retryImage(
            for: item.ref,
            sessionId: item.sessionID,
            client: harness.hostClientForAttachments)
        })
    }
  }
}

private struct AttachmentInlinePreview: View {
  @ObservedObject var store: DSHAttachmentStore
  let ref: DSHAttachmentRef
  let sessionID: String?
  let onOpen: () -> Void
  let onLoad: () -> Void
  let onRetry: () -> Void

  var body: some View {
    if let image = store.images[ref.attachmentId] {
      Button(action: onOpen) {
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
          .frame(maxWidth: 280, maxHeight: 220)
          .clipShape(RoundedRectangle(cornerRadius: DSHRadius.md))
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("点击放大查看")
    } else if let error = store.errors[ref.attachmentId] {
      Button(action: onRetry) {
        Label(error, systemImage: "arrow.clockwise")
      }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(DSHTheme.coral)
        .help("重新读取图片")
    } else if sessionID == nil {
      Label("图片附件暂不可读取", systemImage: "photo")
        .font(.caption)
        .foregroundStyle(DSHTheme.inkFaint)
    } else {
      Label("\(ref.name ?? "图片附件") · \(ref.width)×\(ref.height)", systemImage: "photo")
        .font(.caption)
        .foregroundStyle(DSHTheme.inkFaint)
        .onAppear(perform: onLoad)
    }
  }
}

private struct AttachmentRailThumbnail: View {
  @ObservedObject var store: DSHAttachmentStore
  let item: DSHAttachmentRailItem
  let onOpen: () -> Void
  let onLoad: () -> Void
  let onRetry: () -> Void

  var body: some View {
    Button(action: {
      if store.errors[item.ref.attachmentId] == nil { onOpen() }
      else { onRetry() }
    }) {
      Group {
        if let image = store.images[item.ref.attachmentId] {
          Image(nsImage: image)
            .resizable()
            .scaledToFill()
        } else if store.errors[item.ref.attachmentId] != nil {
          Image(systemName: "exclamationmark.triangle")
            .foregroundStyle(DSHTheme.coral)
        } else {
          ProgressView().controlSize(.small)
        }
      }
      .frame(width: 52, height: 52)
      .background(DSHTheme.surfaceTint, in: RoundedRectangle(cornerRadius: DSHRadius.sm))
      .clipShape(RoundedRectangle(cornerRadius: DSHRadius.sm))
      .overlay {
        RoundedRectangle(cornerRadius: DSHRadius.sm)
          .strokeBorder(DSHTheme.fieldStroke.opacity(0.45), lineWidth: 1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(store.errors[item.ref.attachmentId] == nil ? (item.ref.name ?? "打开图片附件") : "重新读取图片")
    .onAppear(perform: onLoad)
  }
}

/// Zoomable, pannable full-size view of an already-fetched attachment image.
/// See .agents/notes/implemented/feature/2026-08-14-attachment-lightbox.md.
private struct AttachmentLightbox: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var store: DSHAttachmentStore
  let ref: DSHAttachmentRef
  let onLoad: () -> Void
  let onRetry: () -> Void
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
        Text(ref.name ?? "图片附件").font(.caption).foregroundStyle(Self.lightboxText).lineLimit(1)
        Spacer()
        Button("缩小") { setZoom(zoom / 1.25) }.buttonStyle(.plain).foregroundStyle(Self.lightboxText)
        Button("适应窗口") { setZoom(1) }.buttonStyle(.plain).foregroundStyle(Self.lightboxText)
        Button("放大") { setZoom(zoom * 1.25) }.buttonStyle(.plain).foregroundStyle(Self.lightboxText)
        Button(action: { dismiss() }) { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(Self.lightboxText)
      }
      .padding(DSHSpace.s3)
      .background(Color.black.opacity(0.92))
      Group {
        if let image = store.images[ref.attachmentId] {
          ScrollView([.horizontal, .vertical]) {
            Image(nsImage: image)
              .resizable().scaledToFit()
              .scaleEffect(zoom)
              .frame(minWidth: 560, minHeight: 420)
          }
        } else if let error = store.errors[ref.attachmentId] {
          Button(action: onRetry) {
            Label(error, systemImage: "arrow.clockwise")
          }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(Self.lightboxText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ProgressView("正在读取图片…")
            .tint(Self.lightboxText)
            .foregroundStyle(Self.lightboxText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear(perform: onLoad)
        }
      }
      .background(Color.black.opacity(0.85))
      .gesture(
        MagnificationGesture()
          .onChanged { value in zoom = max(0.2, min(lastZoom * value, 8)) }
          .onEnded { _ in lastZoom = zoom }
      )
    }
    .frame(minWidth: 640, minHeight: 520)
    .onAppear(perform: onLoad)
    .onExitCommand { dismiss() }
  }

  private func setZoom(_ value: CGFloat) { zoom = max(0.2, min(value, 8)); lastZoom = zoom }
}
