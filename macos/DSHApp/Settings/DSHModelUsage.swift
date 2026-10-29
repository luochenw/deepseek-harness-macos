import Foundation

/// 当前会话的 Host 投影在各个原生界面中的统一展示语义。
/// token-meter 只报告会话累计 provider usage 与上下文参考值；这里不会
/// 推断账户配额、可用余额或费用。
enum DSHModelUsagePresentation {
  static func compact(_ value: Int) -> String {
    if value >= 1_000_000 {
      return value >= 10_000_000
        ? String(format: "%.0fm", Double(value) / 1_000_000)
        : String(format: "%.1fm", Double(value) / 1_000_000)
    }
    if value >= 10_000 {
      return String(format: "%.0fk", Double(value) / 1_000)
    }
    if value >= 1_000 {
      return String(format: "%.1fk", Double(value) / 1_000)
    }
    return "\(value)"
  }

  static func duration(_ milliseconds: Double) -> String {
    let seconds = max(0, milliseconds) / 1_000
    if seconds < 60 { return "\(Int(seconds.rounded())) 秒" }
    let minutes = Int(seconds) / 60
    let remainder = Int(seconds) % 60
    return remainder == 0 ? "\(minutes) 分" : "\(minutes) 分 \(remainder) 秒"
  }

  static func cacheHitRate(_ usage: DSHTokenUsage) -> Int? {
    guard usage.totalInputTokens > 0 else { return nil }
    return Int((Double(usage.cacheReadTokens) / Double(usage.totalInputTokens) * 100).rounded())
  }

  static func contextTokens(_ pressure: DSHContextPressure) -> Int? {
    let candidates = [
      pressure.projectedTokens,
      pressure.pressureTokens,
      pressure.surfaceTokens,
    ].compactMap { $0 }
    return candidates.first(where: { $0 > 0 }) ?? candidates.first
  }

  static func contextFraction(_ pressure: DSHContextPressure) -> Double? {
    guard let occupied = contextTokens(pressure), let window = pressure.contextWindow, window > 0 else { return nil }
    return min(max(Double(occupied) / Double(window), 0), 1)
  }

  static func contextPercent(_ pressure: DSHContextPressure) -> Int? {
    contextFraction(pressure).map { Int(($0 * 100).rounded()) }
  }
}

extension HarnessController {
  /// 每个根会话的快照都带有自己的 projection；切换时由
  /// syncSessionScopedState 恢复，实时 mux 帧再持续更新。
  var hasCurrentSessionUsage: Bool {
    contextPressure != nil || tokenUsage != nil || (sessionStats?.turns ?? 0) > 0
  }
}
