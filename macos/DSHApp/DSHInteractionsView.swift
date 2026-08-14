import SwiftUI


struct ApprovalSheet: View {
  @EnvironmentObject var harness: HarnessController
  let approval: HarnessController.PendingApproval
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Label("需要权限", systemImage: "exclamationmark.shield.fill").font(.title2.weight(.bold)).foregroundStyle(.orange)
      Text("DSH 请求执行：\(approval.toolName)").font(.headline)
      if let reason = approval.reason { Text(reason).foregroundStyle(.secondary) }
      Text("仅本次执行。请确认该操作符合你的意图。").font(.caption).foregroundStyle(.secondary)
      HStack { Spacer(); Button("拒绝") { harness.answerApproval(false) }.buttonStyle(.bordered); Button("允许一次") { harness.answerApproval(true) }.buttonStyle(.borderedProminent) }
    }.padding(26).frame(width: 460)
  }
}
