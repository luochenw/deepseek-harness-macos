import SwiftUI

struct StreamingAssistantText: View {
  let text: String
  @State private var cursorVisible = true

  var body: some View {
    (
      Text(text)
      + Text(cursorVisible ? " ▍" : " ")
        .foregroundColor(DSHTheme.accent)
    )
    .font(DSHType.bodyLarge)
    .lineSpacing(6)
    .foregroundStyle(DSHTheme.ink)
    .textSelection(.enabled)
    .frame(maxWidth: .infinity, alignment: .leading)
    .onAppear {
      withAnimation(.easeInOut(duration: 0.65).repeatForever(autoreverses: true)) {
        cursorVisible = false
      }
    }
    .accessibilityLabel(text)
  }
}
