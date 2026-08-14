import SwiftUI

struct NativeDashboard: View {
  @EnvironmentObject var harness: HarnessController
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      if harness.hostClient == nil || harness.hostStatus.contains("断开") { Button("重新连接 Host", action: harness.reconnectHostStreams).buttonStyle(.bordered).frame(maxWidth: .infinity) }
      if let retry = harness.retryNotice { RetryNoticeCard(text: retry) }
      if let notice = harness.runNotice { RunNoticeCard(text: notice) }
      if !harness.todos.isEmpty { TodoCard(items: harness.todos) }
      if !harness.activeTools.isEmpty { JobCard(items: harness.activeTools) }
      if !harness.subagents.isEmpty || !harness.subagentPath.isEmpty { SubagentCard(items: harness.subagents) }
      if !harness.workflows.isEmpty { WorkflowCard(items: harness.workflows) }
    }
  }
}

private struct TodoCard: View {
  let items: [DSHTodoItem]
  var body: some View { VStack(alignment: .leading, spacing: 8) { Label("任务", systemImage: "checklist").font(.caption.weight(.bold)); ForEach(items) { item in HStack(spacing: 8) { Image(systemName: item.status == "completed" ? "checkmark.circle.fill" : item.status == "in_progress" ? "circle.inset.filled" : "circle").foregroundStyle(item.status == "completed" ? .green : item.status == "in_progress" ? .blue : .secondary); Text(item.content).font(.caption).lineLimit(2); Spacer() } } }.padding(12).background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12)) }
}

private struct JobCard: View {
  let items: [HarnessController.ToolActivity]
  var body: some View { VStack(alignment: .leading, spacing: 8) { Label("运行与工具", systemImage: "bolt.horizontal.circle").font(.caption.weight(.bold)); ForEach(items) { item in HStack(spacing: 8) { Image(systemName: item.state == .running ? "hourglass" : item.state == .succeeded ? "checkmark.circle" : "exclamationmark.triangle").foregroundStyle(item.state == .running ? .orange : item.state == .succeeded ? .green : .red); VStack(alignment: .leading) { Text(item.name).font(.caption.weight(.medium)); Text(item.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }; Spacer() } } }.padding(12).background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12)) }
}

private struct SubagentCard: View {
  @EnvironmentObject var harness: HarnessController
  let items: [DSHSubagentEntry]
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack { Label("子代理", systemImage: "person.3").font(.caption.weight(.bold)); Spacer(); if !harness.subagentPath.isEmpty { Button("返回上级", action: harness.navigateUpSubagent).buttonStyle(.bordered).controlSize(.small) } }
      if !harness.subagentPath.isEmpty { Text(harness.subagentPath.map(\.title).joined(separator: " › ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
      ForEach(items) { item in
        Button(action: { harness.openSubagent(item) }) { HStack(spacing: 8) {
          Image(systemName: item.activity == "running" ? "circle.inset.filled" : item.kind == "diagnostic" ? "exclamationmark.circle" : "circle").foregroundStyle(item.activity == "running" ? .blue : .secondary)
          VStack(alignment: .leading) { Text(item.label ?? item.id).font(.caption.weight(.medium)).lineLimit(1); Text(item.kind == "diagnostic" ? (item.reason ?? "不可用") : (item.mode ?? "child")).font(.caption2).foregroundStyle(.secondary) }
          Spacer()
          if item.activity == "running" && item.mode == "continuable" { Button(action: { harness.interruptSubagent(item) }) { Image(systemName: "stop.fill") }.buttonStyle(.borderless).help("中断子代理") }
          if item.hasChildren == true { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
        } }.buttonStyle(.plain).disabled(item.kind != "child")
      }
    }.padding(12).background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
  }
}

private struct WorkflowCard: View {
  @EnvironmentObject var harness: HarnessController
  let items: [HarnessController.WorkflowRun]
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("工作流", systemImage: "point.3.connected.trianglepath.dotted").font(.caption.weight(.bold))
      ForEach(items) { run in
        DisclosureGroup(isExpanded: Binding(get: { harness.selectedWorkflowRunID == run.id }, set: { if $0 { harness.selectWorkflow(run) } else if harness.selectedWorkflowRunID == run.id { harness.selectedWorkflowRunID = nil } })) {
          ForEach(run.members) { member in Button(action: { harness.openWorkflowMember(run: run, member: member) }) { HStack { VStack(alignment: .leading) { Text(member.label).font(.caption); Text([member.phase, member.outcome].compactMap { $0 }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "arrow.up.right.square").font(.caption2) } }.buttonStyle(.plain) }
        } label: { HStack { Text(run.name).font(.caption.weight(.medium)); Spacer(); Text(run.stopReason ?? "运行中").font(.caption2).foregroundStyle(run.stopReason == nil ? .blue : .secondary) } }
      }
    }.padding(12).background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
  }
}

private struct RunNoticeCard: View { let text: String; var body: some View { Label(text, systemImage: "exclamationmark.bubble").font(.caption).foregroundStyle(.orange).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10)) } }
private struct RetryNoticeCard: View {
  let text: String
  var body: some View {
    Label(text, systemImage: "arrow.clockwise")
      .font(.caption)
      .foregroundStyle(.blue)
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
  }
}
