import SwiftUI

struct QueueDockView: View {
  @EnvironmentObject var harness: HarnessController
  @State private var editing: DSHQueueItem?
  @State private var text = ""
  var body: some View {
    if !harness.queueItems.isEmpty {
      VStack(alignment: .leading, spacing: DSHSpace.s2) {
        Label("排队消息", systemImage: "list.number").font(.caption.weight(.bold)).foregroundStyle(DSHTheme.ink)
        ForEach(harness.queueItems) { item in
          HStack(spacing: DSHSpace.s2) {
            DSHBadge(text: item.placement == "steering" ? "Steer" : "Queue", tone: item.placement == "steering" ? .warm : .neutral)
            Text(item.text).font(.caption).foregroundStyle(DSHTheme.inkSoft).lineLimit(2)
            Spacer()
            Button(action: { text = item.text; editing = item }) { Image(systemName: "pencil") }.buttonStyle(.dshGhost)
            Button(action: { harness.mutateQueue(item, action: .steer) }) { Image(systemName: "arrow.turn.down.right") }.buttonStyle(.dshGhost)
            Button(action: { harness.mutateQueue(item, action: .remove) }) { Image(systemName: "trash") }.buttonStyle(.dshGhost)
          }
        }
      }
      .padding(DSHSpace.s3)
      .dshCard(tint: DSHTheme.surfaceTint, radius: DSHRadius.md)
      .sheet(item: $editing) { item in
        VStack(alignment: .leading, spacing: DSHSpace.s4) {
          Text("编辑排队消息").font(.title3.weight(.bold)).foregroundStyle(DSHTheme.ink)
          TextEditor(text: $text)
            .padding(DSHSpace.s2)
            .frame(minHeight: 120)
            .dshCard(tint: DSHTheme.surfaceTint2, radius: DSHRadius.sm)
          HStack {
            Spacer()
            Button("取消") { editing = nil }.buttonStyle(.dshSecondary)
            Button("保存") { harness.mutateQueue(item, action: .edit(text)); editing = nil }.buttonStyle(.dshPrimary)
          }
        }
        .padding(DSHSpace.s5)
        .frame(width: 440)
        .background(DSHTheme.surface)
      }
    }
  }
}
