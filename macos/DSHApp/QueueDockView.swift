import SwiftUI

struct QueueDockView: View {
  @EnvironmentObject var harness: HarnessController
  @State private var editing: DSHQueueItem?
  @State private var text = ""
  var body: some View {
    if !harness.displayedQueuedItems.isEmpty {
      VStack(alignment: .leading, spacing: DSHSpace.s2) {
        Label("排队消息", systemImage: "list.number").font(.caption.weight(.bold)).foregroundStyle(DSHTheme.ink)
        ForEach(harness.displayedQueuedItems) { item in
          HStack(spacing: DSHSpace.s2) {
            DSHBadge(text: "Queue", tone: .neutral)
            Text(item.displayText).font(.caption).foregroundStyle(DSHTheme.inkSoft).lineLimit(2)
            Spacer()
            if harness.canMutateDisplayedQueue {
              if item.isEditable {
                Button(action: { text = item.text; editing = item }) { Image(systemName: "pencil") }
                  .buttonStyle(.dshGhost)
                  .help("编辑排队消息")
              }
              Button(action: { harness.mutateQueue(item, action: .steer) }) { Image(systemName: "arrow.turn.down.right") }
                .buttonStyle(.dshGhost)
                .disabled(!harness.displayedIsRunning)
                .help(harness.displayedIsRunning ? "插话发送" : "仅运行中可插话发送")
              Button(action: { harness.mutateQueue(item, action: .remove) }) { Image(systemName: "trash") }.buttonStyle(.dshGhost)
            }
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
