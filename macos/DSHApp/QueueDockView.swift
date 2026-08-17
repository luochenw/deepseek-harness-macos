import SwiftUI

struct QueueDockView: View {
  @EnvironmentObject var harness: HarnessController
  @State private var editing: DSHQueueItem?
  @State private var text = ""
  var body: some View {
    if !harness.queueItems.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Label("排队消息", systemImage: "list.number").font(.caption.weight(.bold))
        ForEach(harness.queueItems) { item in
          HStack(spacing: 8) {
            Text(item.placement == "steering" ? "Steer" : "Queue")
              .font(.caption2.weight(.bold))
              .foregroundStyle(item.placement == "steering" ? .orange : .secondary)
            Text(item.text)
              .font(.caption)
              .lineLimit(2)
            Spacer()
            Button(action: { text = item.text; editing = item }) {
              Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("编辑排队消息")
            Button(action: { harness.mutateQueue(item, action: .steer) }) {
              Image(systemName: "arrow.turn.down.right")
            }
            .buttonStyle(.borderless)
            .help("转为立即插入")
            Button(action: { harness.mutateQueue(item, action: .remove) }) {
              Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("移除")
          }
        }
      }
      .padding(10)
      .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
      .sheet(item: $editing) { item in
        VStack(alignment: .leading, spacing: 14) {
          Text("编辑排队消息").font(.title3.weight(.bold))
          TextEditor(text: $text).frame(minHeight: 120).overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.25)))
          HStack { Spacer(); Button("取消") { editing = nil }; Button("保存") { harness.mutateQueue(item, action: .edit(text)); editing = nil }.buttonStyle(.borderedProminent) }
        }.padding(20).frame(width: 440)
      }
    }
  }
}
