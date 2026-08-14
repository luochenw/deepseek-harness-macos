import SwiftUI

struct WorkspaceManagerView: View {
  @EnvironmentObject var harness: HarnessController
  @State private var renameTarget: DSHWorkspaceView?
  @State private var title = ""
  var body: some View {
    if !harness.hostWorkspaces.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text("Host 工作区").font(.caption.weight(.bold)).foregroundStyle(.secondary)
        ForEach(harness.hostWorkspaces) { ws in
          HStack { Label(ws.title, systemImage: "folder").font(.caption).lineLimit(1); Spacer(); Button(action: { title = ws.title; renameTarget = ws }) { Image(systemName: "pencil") }.buttonStyle(.borderless); Button(action: { harness.deleteWorkspace(ws) }) { Image(systemName: "trash") }.buttonStyle(.borderless) }
        }
      }
      .sheet(item: $renameTarget) { ws in
        VStack(alignment: .leading, spacing: 14) { Text("重命名工作区").font(.title3.weight(.bold)); TextField("名称", text: $title); HStack { Spacer(); Button("取消") { renameTarget = nil }; Button("保存") { harness.renameWorkspace(ws, title: title); renameTarget = nil }.buttonStyle(.borderedProminent) } }.padding(20).frame(width: 380)
      }
    }
  }
}
