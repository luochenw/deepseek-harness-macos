import SwiftUI

struct RenameSessionSheet: View {
  @EnvironmentObject var harness: HarnessController
  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s4) {
      Text("重命名会话").font(.title2.weight(.bold)).foregroundStyle(DSHTheme.ink)
      TextField("会话标题", text: $harness.renameDraft)
        .dshField(tint: DSHTheme.surfaceTint, radius: DSHRadius.md)
      HStack { Spacer(); Button("取消") { harness.showRenameSession = false }.buttonStyle(.dshSecondary); Button("保存") { harness.renameCurrentSession() }.buttonStyle(.dshPrimary).disabled(harness.renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    }.padding(DSHSpace.s5).frame(width: 420).background(DSHTheme.surface)
  }
}
