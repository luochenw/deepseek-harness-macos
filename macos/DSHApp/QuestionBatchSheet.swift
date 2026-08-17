import SwiftUI

struct QuestionBatchSheet: View {
  @EnvironmentObject var harness: HarnessController
  let question: HarnessController.PendingQuestion
  @State private var selections: [String: String] = [:]
  @State private var custom: [String: String] = [:]
  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s4) {
      Text("Agent 需要你的回答")
        .font(.title2.weight(.bold))
        .foregroundStyle(DSHTheme.ink)
      ScrollView {
        VStack(alignment: .leading, spacing: DSHSpace.s4) {
          ForEach(question.items) { item in
            QuestionItemView(item: item, selection: selectionBinding(item.id), custom: customBinding(item.id))
          }
        }
      }.frame(maxHeight: 380)
      HStack {
        Spacer()
        Button("稍后回答") { harness.deferPendingQuestion(question) }.buttonStyle(.dshSecondary).help("暂不回答，问题将保留，可稍后继续回答")
        Button("提交") { harness.answerQuestionBatch(question, selections: selections, custom: custom) }.buttonStyle(.dshPrimary)
      }
    }
    .padding(DSHSpace.s5)
    .frame(width: 560)
    .background(DSHTheme.surface)
  }
  private func selectionBinding(_ id: String) -> Binding<String> { Binding(get: { selections[id] ?? "" }, set: { selections[id] = $0 }) }
  private func customBinding(_ id: String) -> Binding<String> { Binding(get: { custom[id] ?? "" }, set: { custom[id] = $0 }) }
}

private struct QuestionItemView: View {
  let item: HarnessController.PendingQuestion.Item
  @Binding var selection: String
  @Binding var custom: String
  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s2) {
      Text(item.question)
        .font(.headline)
        .foregroundStyle(DSHTheme.ink)
      Picker("选项", selection: $selection) {
        Text("请选择").tag("")
        ForEach(Array(item.options.enumerated()), id: \.offset) { _, option in
          Text(option).tag(option)
        }
      }
      TextField("自定义回答（可选）", text: $custom).dshField()
    }
    .padding(DSHSpace.s3)
    .dshCard(tint: DSHTheme.surfaceTint, radius: DSHRadius.md)
  }
}