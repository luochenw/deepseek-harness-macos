import SwiftUI

struct WorkspaceManagerView: View {
  @EnvironmentObject var harness: HarnessController
  @State private var renameTarget: DSHWorkspaceView?
  @State private var title = ""
  var body: some View {
    if !harness.hostWorkspaces.isEmpty {
      VStack(alignment: .leading, spacing: DSHSpace.s2) {
        Text("Host 工作区").dshSectionLabel()
        ForEach(harness.hostWorkspaces) { ws in
          HStack(spacing: DSHSpace.s2) {
            Label(ws.title, systemImage: "folder")
              .font(.caption)
              .foregroundStyle(DSHTheme.ink)
              .lineLimit(1)
            Spacer()
            Button(action: { title = ws.title; renameTarget = ws }) { Image(systemName: "pencil") }.buttonStyle(.dshGhost)
            Button(action: { harness.deleteWorkspace(ws) }) { Image(systemName: "trash") }.buttonStyle(.dshGhost)
          }
        }
      }
      .sheet(item: $renameTarget) { ws in
        VStack(alignment: .leading, spacing: DSHSpace.s4) {
          Text("重命名工作区")
            .font(.title3.weight(.bold))
            .foregroundStyle(DSHTheme.ink)
          TextField("名称", text: $title).dshField(tint: DSHTheme.surfaceTint)
          HStack {
            Spacer()
            Button("取消") { renameTarget = nil }.buttonStyle(.dshSecondary)
            Button("保存") { harness.renameWorkspace(ws, title: title); renameTarget = nil }.buttonStyle(.dshPrimary)
          }
        }
        .padding(DSHSpace.s5)
        .frame(width: 380)
        .background(DSHTheme.surface)
      }
    }
  }
}
