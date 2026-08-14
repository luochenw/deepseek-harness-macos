import SwiftUI

struct RenameSessionSheet: View {
  @EnvironmentObject var harness: HarnessController
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("重命名会话").font(.title2.weight(.bold))
      TextField("会话标题", text: $harness.renameDraft).textFieldStyle(.roundedBorder)
      HStack { Spacer(); Button("取消") { harness.showRenameSession = false }; Button("保存") { harness.renameCurrentSession() }.buttonStyle(.borderedProminent).disabled(harness.renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    }.padding(24).frame(width: 420)
  }
}
