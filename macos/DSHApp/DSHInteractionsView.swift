import SwiftUI


struct ApprovalSheet: View {
  @EnvironmentObject var harness: HarnessController
  let approval: HarnessController.PendingApproval
  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s4) {
      Label("需要权限", systemImage: "exclamationmark.shield.fill").font(.title2.weight(.bold)).foregroundStyle(DSHTheme.warm)
      Text("DSH 请求执行：\(approval.toolName)").font(.headline).foregroundStyle(DSHTheme.ink)
      if let reason = approval.reason { Text(reason).foregroundStyle(DSHTheme.inkFaint) }
      Text("仅本次执行。请确认该操作符合你的意图。").font(.caption).foregroundStyle(DSHTheme.inkFaint)
      HStack { Spacer(); Button("拒绝") { harness.answerApproval(false) }.buttonStyle(.dshSecondary); Button("允许一次") { harness.answerApproval(true) }.buttonStyle(.dshPrimary) }
    }.padding(DSHSpace.s5).frame(width: 460).background(DSHTheme.surface)
  }
}
