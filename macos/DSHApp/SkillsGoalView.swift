import SwiftUI

/// Dashboard card listing the session's available skills（skill.list →
/// `harness.skills`）. A sibling of `NativeDashboard.swift`'s
/// `TodoCard`/`JobCard`/`SubagentCard`/`WorkflowCard`: same icon+label
/// header via `.dshSectionLabel()`, same `.dshCard(tint: DSHTheme.surface,
/// radius: DSHRadius.md)` chrome.
struct SkillsCard: View {
  let items: [DSHSkillEntry]
  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s2) {
      HStack(spacing: DSHSpace.s2) { Image(systemName: "sparkles").foregroundStyle(DSHTheme.inkFaint); Text("技能").dshSectionLabel() }
      if items.isEmpty {
        Text("当前会话没有可用技能").font(.caption).foregroundStyle(DSHTheme.inkFaint)
      } else {
        ForEach(items) { skill in
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: DSHSpace.s2) {
              Text(skill.name).font(.caption.weight(.medium)).foregroundStyle(DSHTheme.ink).lineLimit(1)
              if !skill.modelInvocable { DSHBadge(text: "仅手动", tone: .neutral) }
              Spacer()
            }
            if !skill.description.isEmpty {
              Text(skill.description).font(.caption2).foregroundStyle(DSHTheme.inkFaint).lineLimit(2)
            }
          }
          .help(skill.whenToUse ?? skill.description)
        }
      }
    }
    .padding(DSHSpace.s3)
    .frame(maxWidth: .infinity, alignment: .leading)
    .dshCard(tint: DSHTheme.surface, radius: DSHRadius.md)
  }
}

/// Compact bar docked above the composer (a sibling of `QueueDockView`: same
/// `.dshCard(tint: DSHTheme.surfaceTint, radius: DSHRadius.md)` chrome,
/// same `.dshGhost` inline action buttons). With a projected goal it shows
/// the objective, phase, round progress, and phase-appropriate goal verbs
/// (pause/resume/complete/clear via `performGoalAction`). Phase vocabulary
/// comes from dsh-goal's `GoalPhase`: active | paused | blocked | complete.
struct GoalBar: View {
  @EnvironmentObject var harness: HarnessController
  @State private var draftObjective = ""

  var body: some View {
    // Renders only when a goal exists — no empty-state chrome above the
    // composer. Goal creation lives in the ＋ menu (fills "/goal ").
    if let goal = harness.displayedGoal?.goal {
      bar(goal)
    }
  }

  private func bar(_ goal: DSHGoalProjection.Goal) -> some View {
    HStack(spacing: DSHSpace.s2) {
      Image(systemName: "scope").font(.caption).foregroundStyle(Self.phaseColor(goal.phase))
      Text(goal.objective).font(.caption).foregroundStyle(DSHTheme.ink).lineLimit(1).truncationMode(.tail).help(goal.objective)
      DSHBadge(text: Self.phaseLabel(goal.phase), tone: Self.phaseTone(goal.phase))
      if let rounds = harness.displayedGoal?.roundsStarted {
        Text("\(rounds)/\(goal.maxGoalRounds) 轮").font(.caption2.monospacedDigit()).foregroundStyle(DSHTheme.inkFaint)
          .help("已开始的目标轮次 / 轮次上限")
      }
      Spacer(minLength: DSHSpace.s2)
      if harness.canMutateDisplayedGoal {
        if goal.phase == "active" {
          Button("暂停") { harness.performGoalAction("pause") }.buttonStyle(.dshGhost)
        } else if goal.phase != "complete" {
          Button("恢复") { harness.performGoalAction("resume") }.buttonStyle(.dshGhost)
        }
        if goal.phase != "complete" {
          Button("完成") { harness.performGoalAction("complete") }.buttonStyle(.dshGhost)
        }
        Button("清除") { harness.performGoalAction("clear") }.buttonStyle(.dshGhost)
      }
    }
    .font(.caption)
    .padding(.horizontal, DSHSpace.s3).padding(.vertical, DSHSpace.s2)
    .frame(maxWidth: .infinity, alignment: .leading)
    .dshCard(tint: DSHTheme.surfaceTint, radius: DSHRadius.md)
  }

  private static func phaseLabel(_ phase: String) -> String {
    switch phase {
    case "active": return "进行中"
    case "paused": return "已暂停"
    case "blocked": return "受阻"
    case "complete": return "已完成"
    default: return phase
    }
  }

  /// Leading `scope` icon color — mirrors `JobCard`'s state→color mapping
  /// in `NativeDashboard.swift` (running/succeeded/failed → accentBright/
  /// accent/coral) so "live" states share the same accent weight app-wide.
  private static func phaseColor(_ phase: String) -> Color {
    switch phase {
    case "active": return DSHTheme.accentBright
    case "paused": return DSHTheme.warm
    case "blocked": return DSHTheme.coral
    case "complete": return DSHTheme.accent
    default: return DSHTheme.inkFaint
    }
  }

  private static func phaseTone(_ phase: String) -> DSHBadge.Tone {
    switch phase {
    case "active": return .accent
    case "paused": return .warm
    case "blocked": return .coral
    case "complete": return .neutral
    default: return .neutral
    }
  }
}
