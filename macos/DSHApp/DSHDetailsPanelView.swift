import SwiftUI

/// Trailing sidebar: dashboard summary (todos/jobs/subagents/workflows) plus
/// detail for whichever tool the user last selected from the message stream.
struct DetailsPanel: View {
  @EnvironmentObject var harness: HarnessController

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("详情")
          .font(.headline)
        Spacer()
        Button(action: { harness.showDetails = false }) {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
      }

      NativeDashboard()

      if let tool = harness.selectedTool {
        selectedToolDetail(tool)
      } else {
        Spacer()
        VStack(spacing: 10) {
          Image(systemName: "sidebar.right")
            .font(.title2)
            .foregroundStyle(.secondary)
          Text("点击消息流中的工具行查看详情")
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
    }
    .padding(18)
  }

  @ViewBuilder
  private func selectedToolDetail(_ tool: HarnessController.ToolActivity) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Label(tool.name, systemImage: icon(for: tool.state))
          .foregroundStyle(color(for: tool.state))
        Text(tool.summary)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      ScrollView {
        NativeToolPresentationView(tool: tool)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private func icon(for state: HarnessController.ToolActivity.State) -> String {
    switch state {
    case .running: "hourglass"
    case .succeeded: "checkmark.circle"
    case .failed: "exclamationmark.triangle"
    }
  }

  private func color(for state: HarnessController.ToolActivity.State) -> Color {
    switch state {
    case .running: .orange
    case .succeeded: .green
    case .failed: .red
    }
  }
}
