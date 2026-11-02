import SwiftUI

/// Small popover behind the dashboard card's 新建 button: a task, an optional
/// short label, and one submit action. Submission routes through
/// `delegateNewChildSession` — this view never talks to the Host itself.
struct NewChildSessionPanel: View {
  @EnvironmentObject private var harness: HarnessController
  let dismiss: () -> Void
  @State private var task = ""
  @State private var label = ""

  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s3) {
      Text("新建子会话").dshSectionLabel()
      ZStack(alignment: .topLeading) {
        TextEditor(text: $task)
          .font(DSHType.body)
          .scrollContentBackground(.hidden)
          .padding(DSHSpace.s2)
          .frame(height: 108)
          .dshCard(tint: DSHTheme.fieldFill, radius: DSHRadius.sm)
          .overlay {
            RoundedRectangle(cornerRadius: DSHRadius.sm, style: .continuous)
              .strokeBorder(DSHTheme.fieldStroke, lineWidth: 1)
          }
        // Drawn after the editor on purpose: TextEditor paints an opaque
        // background, so a placeholder underneath it is never visible.
        if task.isEmpty {
          Text("要交给子会话的任务").font(DSHType.body).foregroundStyle(DSHTheme.inkFaint)
            .padding(.horizontal, DSHSpace.s2 + 1).padding(.vertical, DSHSpace.s2 + 2)
            .allowsHitTesting(false)
        }
      }
      TextField("标签（可选）", text: $label).dshField()
      HStack {
        Spacer()
        Button("交给子会话") {
          if harness.delegateNewChildSession(task: task, label: label) { dismiss() }
        }
        .buttonStyle(.dshPrimary)
        .disabled(!DSHNewChildDelegation.canSubmit(task: task))
      }
    }
    .padding(DSHSpace.s4)
    .frame(width: 360)
  }
}
