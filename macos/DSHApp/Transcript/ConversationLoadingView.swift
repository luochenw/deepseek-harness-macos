import SwiftUI

struct ConversationLoadingView: View {
  @State private var breathing = false
  var compact = false

  @ViewBuilder
  var body: some View {
    if compact {
      HStack(spacing: DSHSpace.s2) {
        ProgressView()
          .controlSize(.small)
        Text("正在补齐更早的会话历史…")
          .font(.system(size: 12.5, weight: .medium))
          .foregroundStyle(DSHTheme.inkSoft)
      }
      .padding(.horizontal, DSHSpace.s3)
      .padding(.vertical, DSHSpace.s2)
      .background(
        DSHTheme.surfaceTint,
        in: RoundedRectangle(cornerRadius: DSHRadius.sm, style: .continuous))
      .accessibilityElement(children: .combine)
      .accessibilityLabel("正在补齐更早的会话历史")
    } else {
      VStack(alignment: .leading, spacing: DSHSpace.s3) {
        HStack(spacing: DSHSpace.s2) {
          ProgressView()
            .controlSize(.small)
          Text("正在载入会话历史…")
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(DSHTheme.inkSoft)
        }
        ForEach(Array([0.96, 0.78, 0.88, 0.64].enumerated()), id: \.offset) { index, width in
          GeometryReader { geometry in
            RoundedRectangle(cornerRadius: 4, style: .continuous)
              .fill(DSHTheme.surfaceTint2)
              .frame(width: geometry.size.width * width, height: index == 0 ? 14 : 10)
              .opacity(breathing ? 0.42 : 0.9)
              .animation(
                .easeInOut(duration: 0.9)
                  .repeatForever(autoreverses: true)
                  .delay(Double(index) * 0.08),
                value: breathing)
          }
          .frame(height: index == 0 ? 14 : 10)
        }
      }
      .frame(maxWidth: 720, alignment: .leading)
      .padding(.vertical, DSHSpace.s4)
      .onAppear { breathing = true }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("正在载入会话历史")
    }
  }
}
