import SwiftUI

/// 当前会话的 Host 用量投影。Host 不提供账户额度或账单，因此本页只展示
/// 已确认的会话累计 token 与上下文参考值，不把未知数据伪装成“剩余配额”。
struct ModelUsageSettingsSection: View {
  @EnvironmentObject private var harness: HarnessController
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage(AppPrefs.showComposerUsageKey) private var showComposerUsage = true

  private var hasUsage: Bool { harness.hasCurrentSessionUsage }

  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s4) {
      usageHeader
      if hasUsage {
        contextGroup
        tokenGroup
        activityGroup
      } else {
        emptyState
      }
      if hasUsage && harness.tokenUsage == nil && harness.contextPressure == nil {
        noTokenProjectionNote
      }
      DSHSettingsGroup(title: "显示") {
        DSHToggleRow(
          title: "在输入框旁显示用量速览",
          caption: "显示上下文、输入/输出和会话轮次；完整拆分始终可在本页查看。",
          isOn: $showComposerUsage)
      }
      Text("所有数值来自当前会话的 Host token-meter。上下文占用用于参考，不代表账户额度、剩余额度或账单金额。")
        .font(.system(size: 11))
        .foregroundStyle(DSHTheme.inkFaint)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder private var usageHeader: some View {
    HStack(alignment: .firstTextBaseline, spacing: DSHSpace.s3) {
      VStack(alignment: .leading, spacing: DSHSpace.s1) {
        Text("当前会话累计")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(DSHTheme.ink)
        Text(harness.hostCurrentSessionID == nil ? "发送第一条消息后开始计量" : harness.currentModelLabel)
          .font(.system(size: 11))
          .foregroundStyle(DSHTheme.inkFaint)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer()
      Button(action: harness.refreshHostSnapshots) { Image(systemName: "arrow.clockwise") }
        .buttonStyle(.dshGhost)
        .help("刷新会话用量快照")
    }
  }

  private var contextGroup: some View {
    DSHSettingsGroup(title: "上下文") {
      if let pressure = harness.contextPressure,
         let occupied = DSHModelUsagePresentation.contextTokens(pressure) {
        let percent = DSHModelUsagePresentation.contextPercent(pressure)
        VStack(alignment: .leading, spacing: DSHSpace.s3) {
          HStack(alignment: .firstTextBaseline) {
            Text("\(DSHModelUsagePresentation.compact(occupied))")
              .font(.system(size: 26, weight: .semibold))
              .monospacedDigit()
              .foregroundStyle(DSHTheme.ink)
            if let window = pressure.contextWindow {
              Text("/ \(DSHModelUsagePresentation.compact(window)) tokens")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(DSHTheme.inkFaint)
            }
            Spacer()
            if let percent { DSHBadge(text: "\(percent)%", tone: percent >= 80 ? .coral : .accent) }
          }
          if let fraction = DSHModelUsagePresentation.contextFraction(pressure) {
            DSHAnimatedProgressBar(
              fraction: fraction,
              tint: fraction >= 0.8 ? DSHTheme.coral : DSHTheme.accent,
              height: 4)
          }
          Text("下一次请求的预计提示词占用；以 Host 的 projected tokens 为准，尚无预测时回退到最近请求的实际 prompt。")
            .font(.system(size: 11))
            .foregroundStyle(DSHTheme.inkFaint)
            .fixedSize(horizontal: false, vertical: true)
        }
      } else {
        Text("尚未收到上下文占用。完成一次模型请求后，Host 会提供预计占用和模型窗口。")
          .font(.system(size: 12))
          .foregroundStyle(DSHTheme.inkFaint)
      }
    }
  }

  private var tokenGroup: some View {
    DSHSettingsGroup(title: "Token 累计") {
      if let usage = harness.tokenUsage {
        VStack(spacing: DSHSpace.s3) {
          HStack(spacing: DSHSpace.s3) {
            UsageMetric(title: "输入", value: DSHModelUsagePresentation.compact(usage.totalInputTokens), detail: "含缓存读写")
            UsageMetric(title: "输出", value: DSHModelUsagePresentation.compact(usage.outputTokens), detail: "模型生成")
          }
          HStack(spacing: DSHSpace.s3) {
            UsageMetric(title: "缓存读取", value: DSHModelUsagePresentation.compact(usage.cacheReadTokens), detail: "复用提示缓存")
            UsageMetric(title: "缓存写入", value: DSHModelUsagePresentation.compact(usage.cacheWriteTokens), detail: "建立提示缓存")
          }
          HStack {
            Text("未缓存输入")
              .font(.system(size: 12))
              .foregroundStyle(DSHTheme.inkSoft)
            Spacer()
            Text(DSHModelUsagePresentation.compact(usage.uncachedInputTokens))
              .font(.system(size: 12, design: .monospaced))
              .foregroundStyle(DSHTheme.ink)
          }
          if let hitRate = DSHModelUsagePresentation.cacheHitRate(usage) {
            HStack {
              Text("缓存命中率")
                .font(.system(size: 12))
                .foregroundStyle(DSHTheme.inkSoft)
              Spacer()
              Text("\(hitRate)%")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(DSHTheme.accent)
                .contentTransition(reduceMotion ? .opacity : .numericText())
                .animation(
                  reduceMotion ? nil : .easeOut(duration: 0.22),
                  value: hitRate)
            }
            DSHAnimatedProgressBar(
              fraction: Double(hitRate) / 100,
              tint: DSHTheme.accent,
              height: 3)
          }
        }
      } else {
        Text("尚未收到 token 用量。模型提供方未返回 usage，或当前会话还没有完成可计量的请求。")
          .font(.system(size: 12))
          .foregroundStyle(DSHTheme.inkFaint)
      }
    }
  }

  private var activityGroup: some View {
    DSHSettingsGroup(title: "会话活动") {
      if let stats = harness.sessionStats, stats.turns > 0 {
        HStack(spacing: DSHSpace.s3) {
          UsageMetric(title: "回合", value: "\(stats.turns)", detail: "用户与模型往返")
          UsageMetric(title: "步骤", value: "\(stats.steps)", detail: "模型与工具执行")
          UsageMetric(title: "LLM", value: DSHModelUsagePresentation.duration(stats.llmMs), detail: "累计模型耗时")
          UsageMetric(title: "工具", value: DSHModelUsagePresentation.duration(stats.toolMs), detail: "累计工具耗时")
        }
      } else {
        Text("当前会话还没有完成的回合统计。")
          .font(.system(size: 12))
          .foregroundStyle(DSHTheme.inkFaint)
      }
    }
  }

  private var noTokenProjectionNote: some View {
    Text("此提供方尚未返回 token 用量或上下文投影；会话活动仍会在 Host 提供统计后显示。")
      .font(.system(size: 11))
      .foregroundStyle(DSHTheme.inkFaint)
      .padding(DSHSpace.s3)
      .frame(maxWidth: .infinity, alignment: .leading)
      .dshCard(tint: DSHTheme.surfaceTint, radius: DSHRadius.md)
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s2) {
      Image(systemName: "chart.bar.xaxis")
        .font(.system(size: 22, weight: .medium))
        .foregroundStyle(DSHTheme.accent)
      Text("还没有可展示的会话用量")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(DSHTheme.ink)
      Text("选择一个已有会话，或先完成一次模型请求。用量会随 Host 的实时投影自动更新。")
        .font(.system(size: 12))
        .foregroundStyle(DSHTheme.inkFaint)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(DSHSpace.s4)
    .frame(maxWidth: .infinity, alignment: .leading)
    .dshCard(tint: DSHTheme.surfaceTint, radius: DSHRadius.md)
  }
}

private struct UsageMetric: View {
  let title: String
  let value: String
  let detail: String

  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s1) {
      Text(title)
        .font(DSHType.caption.weight(.medium))
        .foregroundStyle(DSHTheme.inkSoft)
      Text(value)
        .font(DSHType.pageTitle)
        .monospacedDigit()
        .foregroundStyle(DSHTheme.ink)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
      Text(detail)
        .font(DSHType.micro)
        .foregroundStyle(DSHTheme.inkFaint)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(DSHSpace.s3)
    .background(DSHTheme.surface, in: RoundedRectangle(cornerRadius: DSHRadius.sm, style: .continuous))
  }
}
