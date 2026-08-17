import SwiftUI

struct NativeDashboard: View {
  @EnvironmentObject var harness: HarnessController
  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s4) {
      if harness.hostClient == nil || harness.hostStatus.contains("断开") { Button("重新连接 Host", action: harness.reconnectHostStreams).buttonStyle(.dshPrimary).frame(maxWidth: .infinity) }
      if let retry = harness.retryNotice { RetryNoticeCard(text: retry) }
      if let notice = harness.runNotice { RunNoticeCard(text: notice) }
      if !harness.todos.isEmpty { TodoCard(items: harness.todos) }
      if !harness.activeTools.isEmpty { JobCard(items: harness.activeTools) }
      if !harness.subagents.isEmpty || !harness.subagentPath.isEmpty { SubagentCard(items: harness.subagents) }
      if !harness.workflows.isEmpty { WorkflowCard(items: harness.workflows) }
      if !harness.skills.isEmpty { SkillsCard(items: harness.skills) }
    }
  }
}

private struct TodoCard: View {
  let items: [DSHTodoItem]
  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s2) {
      HStack(spacing: DSHSpace.s2) { Image(systemName: "checklist").foregroundStyle(DSHTheme.inkFaint); Text("任务").dshSectionLabel() }
      ForEach(items) { item in
        HStack(spacing: DSHSpace.s2) {
          Image(systemName: Self.icon(item.status)).foregroundStyle(Self.color(item.status))
          Text(item.content).font(.caption).foregroundStyle(DSHTheme.ink).lineLimit(2)
          Spacer()
        }
      }
    }.padding(DSHSpace.s3).dshCard(tint: DSHTheme.surface, radius: DSHRadius.md)
  }
  private static func icon(_ status: String) -> String {
    switch status { case "completed": "checkmark.circle.fill"; case "in_progress": "circle.inset.filled"; default: "circle" }
  }
  private static func color(_ status: String) -> Color {
    switch status { case "completed": DSHTheme.accent; case "in_progress": DSHTheme.accentBright; default: DSHTheme.inkFaint }
  }
}

private struct JobCard: View {
  let items: [HarnessController.ToolActivity]
  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s2) {
      HStack(spacing: DSHSpace.s2) { Image(systemName: "bolt.horizontal.circle").foregroundStyle(DSHTheme.inkFaint); Text("运行与工具").dshSectionLabel() }
      ForEach(items) { item in
        HStack(spacing: DSHSpace.s2) {
          Image(systemName: Self.icon(item.state)).foregroundStyle(Self.color(item.state))
          VStack(alignment: .leading) {
            Text(item.name).font(.caption.weight(.medium)).foregroundStyle(DSHTheme.ink)
            Text(item.summary).font(.caption2).foregroundStyle(DSHTheme.inkFaint).lineLimit(1)
          }
          Spacer()
        }
      }
    }.padding(DSHSpace.s3).dshCard(tint: DSHTheme.surface, radius: DSHRadius.md)
  }
  private static func icon(_ state: HarnessController.ToolActivity.State) -> String {
    switch state { case .running: "hourglass"; case .succeeded: "checkmark.circle"; case .failed: "exclamationmark.triangle" }
  }
  private static func color(_ state: HarnessController.ToolActivity.State) -> Color {
    switch state { case .running: DSHTheme.accentBright; case .succeeded: DSHTheme.accent; case .failed: DSHTheme.coral }
  }
}

private struct SubagentCard: View {
  @EnvironmentObject var harness: HarnessController
  let items: [DSHSubagentEntry]
  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s2) {
      HStack {
        HStack(spacing: DSHSpace.s2) { Image(systemName: "person.3").foregroundStyle(DSHTheme.inkFaint); Text("子代理").dshSectionLabel() }
        Spacer()
        Button("完整树", action: { harness.showSubagentTree = true }).buttonStyle(.dshSecondary)
        if !harness.subagentPath.isEmpty { Button("返回上级", action: harness.navigateUpSubagent).buttonStyle(.dshSecondary) }
      }
      if !harness.subagentPath.isEmpty { Text(harness.subagentPath.map(\.title).joined(separator: " › ")).font(.caption2).foregroundStyle(DSHTheme.inkFaint).lineLimit(1) }
      ForEach(items) { item in
        Button(action: { harness.openSubagent(item) }) { HStack(spacing: DSHSpace.s2) {
          Image(systemName: Self.icon(item)).foregroundStyle(Self.color(item))
          VStack(alignment: .leading) {
            Text(item.label ?? item.id).font(.caption.weight(.medium)).foregroundStyle(DSHTheme.ink).lineLimit(1)
            Text(item.kind == "diagnostic" ? (item.reason ?? "不可用") : (item.mode ?? "child")).font(.caption2).foregroundStyle(DSHTheme.inkFaint)
          }
          Spacer()
          if item.activity == "running" && item.mode == "continuable" { Button(action: { harness.interruptSubagent(item) }) { Image(systemName: "stop.fill").foregroundStyle(DSHTheme.coral) }.buttonStyle(.borderless).help("中断子代理") }
          if item.hasChildren == true { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(DSHTheme.inkFaint) }
        } }.buttonStyle(.plain).disabled(item.kind != "child")
      }
    }.padding(DSHSpace.s3).dshCard(tint: DSHTheme.surface, radius: DSHRadius.md)
  }
  private static func icon(_ item: DSHSubagentEntry) -> String {
    item.activity == "running" ? "circle.inset.filled" : item.kind == "diagnostic" ? "exclamationmark.circle" : "circle"
  }
  /// Mirrors `DSHSubagentTree.SubagentTreeRow`'s activity→color mapping — keep
  /// the two in sync since they render the same subagent states in different places.
  private static func color(_ item: DSHSubagentEntry) -> Color {
    item.activity == "running" ? DSHTheme.accentBright : item.kind == "diagnostic" ? DSHTheme.coral : DSHTheme.inkFaint
  }
}

private struct WorkflowCard: View {
  @EnvironmentObject var harness: HarnessController
  let items: [HarnessController.WorkflowRun]
  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s2) {
      HStack(spacing: DSHSpace.s2) { Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(DSHTheme.inkFaint); Text("工作流").dshSectionLabel() }
      ForEach(items) { run in
        DisclosureGroup(isExpanded: Binding(get: { harness.selectedWorkflowRunID == run.id }, set: { if $0 { harness.selectWorkflow(run) } else if harness.selectedWorkflowRunID == run.id { harness.selectedWorkflowRunID = nil } })) {
          ForEach(Self.groupedByPhase(run.members), id: \.phase) { group in
            VStack(alignment: .leading, spacing: DSHSpace.s1) {
              if let phase = group.phase { Text(phase).font(.caption2.weight(.semibold)).foregroundStyle(DSHTheme.inkFaint).padding(.top, DSHSpace.s1) }
              ForEach(group.members) { member in
                Button(action: { harness.openWorkflowMember(run: run, member: member) }) {
                  HStack {
                    statusDot(member.status)
                    Text(member.label).font(.caption).foregroundStyle(DSHTheme.ink)
                    Spacer()
                    Image(systemName: "arrow.up.right.square").font(.caption2).foregroundStyle(DSHTheme.inkFaint)
                  }
                }.buttonStyle(.plain)
              }
            }
          }
        } label: { runLabel(run) }
      }
    }.padding(DSHSpace.s3).dshCard(tint: DSHTheme.accentSoft, radius: DSHRadius.md)
  }

  private static func groupedByPhase(_ members: [HarnessController.WorkflowRun.Member]) -> [(phase: String?, members: [HarnessController.WorkflowRun.Member])] {
    var order: [String?] = []
    var buckets: [String?: [HarnessController.WorkflowRun.Member]] = [:]
    for member in members {
      if buckets[member.phase] == nil { order.append(member.phase) }
      buckets[member.phase, default: []].append(member)
    }
    return order.map { (phase: $0, members: buckets[$0] ?? []) }
  }

  @ViewBuilder private func statusDot(_ status: HarnessController.WorkflowRun.Status) -> some View {
    Image(systemName: Self.icon(status)).foregroundStyle(Self.color(status)).font(.caption2)
  }
  @ViewBuilder private func runLabel(_ run: HarnessController.WorkflowRun) -> some View {
    HStack {
      statusDot(run.status)
      Text(run.name).font(.caption.weight(.medium)).foregroundStyle(DSHTheme.ink)
      Spacer()
      Text(Self.label(run.status)).font(.caption2).foregroundStyle(DSHTheme.inkFaint)
    }
  }
  private static func icon(_ status: HarnessController.WorkflowRun.Status) -> String {
    switch status { case .running: "circle.dotted"; case .completed: "checkmark.circle.fill"; case .failed: "xmark.circle.fill"; case .cancelled: "minus.circle.fill" }
  }
  private static func color(_ status: HarnessController.WorkflowRun.Status) -> Color {
    switch status { case .running: DSHTheme.accentBright; case .completed: DSHTheme.accent; case .failed: DSHTheme.coral; case .cancelled: DSHTheme.inkFaint }
  }
  private static func label(_ status: HarnessController.WorkflowRun.Status) -> String {
    switch status { case .running: "运行中"; case .completed: "已完成"; case .failed: "失败"; case .cancelled: "已取消" }
  }
}

private struct RunNoticeCard: View {
  let text: String
  var body: some View {
    Label(text, systemImage: "exclamationmark.bubble")
      .font(.caption)
      .foregroundStyle(DSHTheme.warm)
      .padding(DSHSpace.s3)
      .frame(maxWidth: .infinity, alignment: .leading)
      .dshCard(tint: DSHTheme.warmSoft, radius: DSHRadius.md)
  }
}

/// Uses the accent tone (not `warm`) rather than mirroring `RunNoticeCard`: a
/// retry is the app self-recovering as designed, not something the user needs
/// to act on — keeping it visually distinct from run notices (which can carry
/// real failures) avoids the two reading as the same severity.
private struct RetryNoticeCard: View {
  let text: String
  var body: some View {
    Label(text, systemImage: "arrow.clockwise")
      .font(.caption)
      .foregroundStyle(DSHTheme.accent)
      .padding(DSHSpace.s3)
      .frame(maxWidth: .infinity, alignment: .leading)
      .dshCard(tint: DSHTheme.accentSoft, radius: DSHRadius.md)
  }
}
