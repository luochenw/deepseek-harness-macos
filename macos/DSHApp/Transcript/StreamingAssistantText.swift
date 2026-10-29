import SwiftUI

struct StreamingAssistantText: View {
  let text: String

  var body: some View {
    (Text(text) + Text(" ▍").foregroundColor(DSHTheme.accent))
    .font(DSHType.bodyLarge)
    .lineSpacing(6)
    .foregroundStyle(DSHTheme.ink)
    .textSelection(.enabled)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityLabel(text)
  }
}
