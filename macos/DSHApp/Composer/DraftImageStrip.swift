import AppKit
import SwiftUI

struct DraftImageStrip: View {
  let images: [HarnessController.DraftImage]
  @Binding var previewImage: HarnessController.DraftImage?
  let onRemove: (UUID) -> Void

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      LazyHStack(spacing: DSHSpace.s2) {
        ForEach(images) { image in
          ZStack(alignment: .topTrailing) {
            Button(action: { previewImage = image }) {
              Group {
                if let bitmap = NSImage(contentsOf: image.url) {
                  Image(nsImage: bitmap)
                    .resizable()
                    .scaledToFill()
                } else {
                  Image(systemName: "photo.badge.exclamationmark")
                    .foregroundStyle(DSHTheme.coral)
                }
              }
              .frame(width: 56, height: 56)
              .background(DSHTheme.surfaceTint)
              .clipShape(RoundedRectangle(cornerRadius: DSHRadius.sm))
              .overlay {
                RoundedRectangle(cornerRadius: DSHRadius.sm)
                  .strokeBorder(DSHTheme.fieldStroke.opacity(0.55), lineWidth: 1)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("预览 \(image.url.lastPathComponent)")

            Button(action: { onRemove(image.id) }) {
              Image(systemName: "xmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.white, Color.black.opacity(0.72))
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
            .help("移除图片")
          }
          .padding(.top, 5)
          .padding(.trailing, 5)
        }
      }
      .padding(.horizontal, 1)
    }
    .frame(height: 62)
  }
}

struct DraftImageLightbox: View {
  @Environment(\.dismiss) private var dismiss
  let image: HarnessController.DraftImage
  @State private var zoom: CGFloat = 1
  @State private var lastZoom: CGFloat = 1

  private static let lightboxText = Color(white: 0.94)

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(image.url.lastPathComponent)
          .font(.caption)
          .foregroundStyle(Self.lightboxText)
          .lineLimit(1)
        Spacer()
        Button("缩小") { setZoom(zoom / 1.25) }
        Button("适应窗口") { setZoom(1) }
        Button("放大") { setZoom(zoom * 1.25) }
        Button(action: { dismiss() }) {
          Image(systemName: "xmark.circle.fill")
        }
      }
      .buttonStyle(.plain)
      .foregroundStyle(Self.lightboxText)
      .padding(DSHSpace.s3)
      .background(Color.black.opacity(0.92))

      Group {
        if let bitmap = NSImage(contentsOf: image.url) {
          ScrollView([.horizontal, .vertical]) {
            Image(nsImage: bitmap)
              .resizable()
              .scaledToFit()
              .scaleEffect(zoom)
              .frame(minWidth: 560, minHeight: 420)
          }
          .gesture(
            MagnificationGesture()
              .onChanged { value in zoom = max(0.2, min(lastZoom * value, 8)) }
              .onEnded { _ in lastZoom = zoom }
          )
        } else {
          Label("无法读取图片文件", systemImage: "photo.badge.exclamationmark")
            .foregroundStyle(Self.lightboxText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .background(Color.black.opacity(0.85))
    }
    .frame(minWidth: 640, minHeight: 520)
    .onExitCommand { dismiss() }
  }

  private func setZoom(_ value: CGFloat) {
    zoom = max(0.2, min(value, 8))
    lastZoom = zoom
  }
}
