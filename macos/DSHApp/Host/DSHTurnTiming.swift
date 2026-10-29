import Foundation

enum DSHTurnTiming {
  static func milliseconds(from event: [String: Any]) -> Double? {
    if let value = event["time"] as? Double { return value }
    if let value = event["time"] as? Int { return Double(value) }
    if let value = event["time"] as? NSNumber { return value.doubleValue }
    return nil
  }

  static func date(from milliseconds: Double?) -> Date? {
    milliseconds.map { Date(timeIntervalSince1970: $0 / 1_000) }
  }

  static func duration(from start: Date?, to endMilliseconds: Double?) -> Double? {
    guard let start else { return nil }
    let end = date(from: endMilliseconds) ?? Date()
    return max(0, end.timeIntervalSince(start) * 1_000)
  }

  static func label(_ milliseconds: Double) -> String {
    let seconds = max(0, milliseconds) / 1_000
    if seconds < 10 {
      return String(format: "%.1f 秒", seconds)
    }
    return DSHModelUsagePresentation.duration(milliseconds)
  }
}
