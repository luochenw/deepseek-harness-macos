import Foundation
@testable import DSHAppLib

private func testSidebarSessionPaging_defaultsToFiveAndExpandsAll() throws {
  try expectEqual(DSHSidebarSessionPaging.defaultVisibleCount, 5)
  try expectEqual(DSHSidebarSessionPaging.visibleCount(total: 3, expanded: false), 3)
  try expectEqual(DSHSidebarSessionPaging.visibleCount(total: 5, expanded: false), 5)
  try expectEqual(DSHSidebarSessionPaging.visibleCount(total: 26, expanded: false), 5)
  try expectEqual(DSHSidebarSessionPaging.visibleCount(total: 26, expanded: true), 26)
}

private func testSidebarSessionPaging_reportsExactHiddenCount() throws {
  try expectEqual(DSHSidebarSessionPaging.hiddenCount(total: 5, expanded: false), 0)
  try expectEqual(DSHSidebarSessionPaging.hiddenCount(total: 7, expanded: false), 2)
  try expectEqual(DSHSidebarSessionPaging.hiddenCount(total: 7, expanded: true), 0)
}

private func sidebarTestDate(
  _ year: Int,
  _ month: Int,
  _ day: Int,
  _ hour: Int,
  _ minute: Int,
  calendar: Calendar
) -> Date {
  guard let date = calendar.date(from: DateComponents(
    year: year,
    month: month,
    day: day,
    hour: hour,
    minute: minute))
  else {
    fatalError("invalid sidebar test date")
  }
  return date
}

private func testSidebarSessionTimestamp_usesStableChineseLabels() throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.locale = Locale(identifier: "zh_CN")
  calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
  let now = sidebarTestDate(2026, 10, 26, 15, 30, calendar: calendar)

  try expectEqual(
    DSHSidebarSessionTimestamp.compact(
      now.addingTimeInterval(-30),
      now: now,
      calendar: calendar),
    "刚刚")
  try expectEqual(
    DSHSidebarSessionTimestamp.compact(
      sidebarTestDate(2026, 10, 26, 15, 25, calendar: calendar),
      now: now,
      calendar: calendar),
    "5 分钟前")
  try expectEqual(
    DSHSidebarSessionTimestamp.compact(
      sidebarTestDate(2026, 10, 26, 9, 5, calendar: calendar),
      now: now,
      calendar: calendar),
    "09:05")
  try expectEqual(
    DSHSidebarSessionTimestamp.compact(
      sidebarTestDate(2026, 10, 25, 21, 8, calendar: calendar),
      now: now,
      calendar: calendar),
    "昨天 21:08")
  try expectEqual(
    DSHSidebarSessionTimestamp.compact(
      sidebarTestDate(2026, 3, 2, 10, 0, calendar: calendar),
      now: now,
      calendar: calendar),
    "3月2日")
  try expectEqual(
    DSHSidebarSessionTimestamp.compact(
      sidebarTestDate(2025, 12, 31, 10, 0, calendar: calendar),
      now: now,
      calendar: calendar),
    "2025年12月31日")
}

let dshSidebarTests: [NamedTest] = [
  ("Sidebar session paging defaults to five and expands all", testSidebarSessionPaging_defaultsToFiveAndExpandsAll),
  ("Sidebar session paging reports exact hidden count", testSidebarSessionPaging_reportsExactHiddenCount),
  ("Sidebar session timestamp uses stable Chinese labels", testSidebarSessionTimestamp_usesStableChineseLabels),
]
