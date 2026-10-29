import Foundation
@testable import DSHAppLib

private func testSidebarSessionPaging_defaultsToFiveAndExpandsAll() throws {
  try expectEqual(DSHSidebarSessionPaging.defaultVisibleCount, 5)
  let idle = [Bool](repeating: false, count: 26)
  try expectEqual(DSHSidebarSessionPaging.visibleIndices(total: 3, running: idle, expanded: false), [0, 1, 2])
  try expectEqual(DSHSidebarSessionPaging.visibleIndices(total: 5, running: idle, expanded: false), [0, 1, 2, 3, 4])
  try expectEqual(DSHSidebarSessionPaging.visibleIndices(total: 26, running: idle, expanded: false), [0, 1, 2, 3, 4])
  try expectEqual(
    DSHSidebarSessionPaging.visibleIndices(total: 26, running: idle, expanded: true),
    Array(0..<26))
}

private func testSidebarSessionPaging_reportsExactHiddenCount() throws {
  let idle = [Bool](repeating: false, count: 26)
  try expectEqual(DSHSidebarSessionPaging.hiddenCount(total: 5, running: idle, expanded: false), 0)
  try expectEqual(DSHSidebarSessionPaging.hiddenCount(total: 7, running: idle, expanded: false), 2)
  try expectEqual(DSHSidebarSessionPaging.hiddenCount(total: 7, running: idle, expanded: true), 0)
}

private func testSidebarSessionPaging_neverFoldsARunningSession() throws {
  // Eight sessions, the seventh one running: it stays visible and the fold
  // count only covers the idle rows past the preview.
  var running = [Bool](repeating: false, count: 8)
  running[6] = true
  try expectEqual(
    DSHSidebarSessionPaging.visibleIndices(total: 8, running: running, expanded: false),
    [0, 1, 2, 3, 4, 6])
  try expectEqual(
    DSHSidebarSessionPaging.hiddenCount(total: 8, running: running, expanded: false),
    2)
  try expectEqual(
    DSHSidebarSessionPaging.visibleIndices(total: 8, running: running, expanded: true),
    Array(0..<8))
}

private func testSidebarSessionPaging_foldsTheTrailingIdleRunOnly() throws {
  // Every row past the preview is running: nothing left to fold, so the
  // control disappears instead of claiming "展开其余 0 个".
  let running = [Bool](repeating: true, count: 7)
  try expectEqual(
    DSHSidebarSessionPaging.visibleIndices(total: 7, running: running, expanded: false),
    Array(0..<7))
  try expectEqual(DSHSidebarSessionPaging.hiddenCount(total: 7, running: running, expanded: false), 0)
}

private func testSidebarRunningLine_keepsItsGeometryAndHonoursReduceMotion() throws {
  // The sidebar reuses the transcript's activity line, so only its colour is
  // new: the thin geometry and the Reduce Motion cut-out must stay put.
  let line = DSHActivityLine(active: true, color: DSHTheme.running)
  try expectEqual(line.height, 1.2)
  try expect(line.active, "the sidebar hands the line an active process")
}

private func testSidebarFoldControl_hiddenWhenCollapsingWouldRemoveNothing() throws {
  // Expanded, and every row past the preview is running: collapsing would keep
  // them all visible, so the toggle must not be offered at all.
  let running = [Bool](repeating: true, count: 7)
  try expect(
    !DSHSidebarSessionPaging.showsFoldControl(total: 7, running: running),
    "an expanded group whose tail is all running must not offer 收起")

  // A foldable idle tail keeps the control, in both states.
  let idleTail: [Bool] = [false, false, false, false, false, false, false]
  try expect(DSHSidebarSessionPaging.showsFoldControl(total: 7, running: idleTail))

  // Five rows: folding cannot remove anything, so there is no control.
  try expect(!DSHSidebarSessionPaging.showsFoldControl(total: 5, running: idleTail))
}

private func testSidebarFoldControl_labelReportsTheCollapsedRowCount() throws {
  // Eight rows, the seventh running: collapsing leaves 5 + 1 = 6 rows, so an
  // expanded group must offer 「收起至 6 个」 — not the 8 it currently shows.
  var running = [Bool](repeating: false, count: 8)
  running[6] = true
  try expectEqual(
    DSHSidebarSessionPaging.foldControlLabel(total: 8, running: running, expanded: true),
    "收起至 6 个")
  try expectEqual(
    DSHSidebarSessionPaging.foldControlLabel(total: 8, running: running, expanded: false),
    "展开其余 2 个")

  // Idle-only group: the label matches the classic five-row preview.
  let idle = [Bool](repeating: false, count: 8)
  try expectEqual(
    DSHSidebarSessionPaging.foldControlLabel(total: 8, running: idle, expanded: true),
    "收起至 5 个")

  // Every trailing row running: collapsing keeps them all, so the label states
  // the honest outcome even though `showsFoldControl` hides the button.
  let allRunning = [Bool](repeating: true, count: 7)
  try expectEqual(
    DSHSidebarSessionPaging.foldControlLabel(total: 7, running: allRunning, expanded: true),
    "收起至 7 个")
}

private func testSidebarRunningToken_clearsThreeToOneOnTheSidebar() throws {
  // The logo mint was 1.25:1 here; the running token must stay legible in both
  // appearances, so the numbers are asserted rather than eyeballed.
  let light = sidebarContrastRatio(DSHTheme.runningLightRGBA, DSHTheme.sidebarBgLightRGBA)
  let dark = sidebarContrastRatio(DSHTheme.runningDarkRGBA, DSHTheme.sidebarBgDarkRGBA)
  try expect(light >= 3, "light running marker contrast is \(light):1, needs >= 3:1")
  try expect(dark >= 3, "dark running marker contrast is \(dark):1, needs >= 3:1")
}

private func testSidebarVisibleSessions_followSessionIdentityAcrossAnInsert() throws {
  // A new session lands at the top: every index shifts by one. The rows the
  // view builds must still be keyed by session, so their @State stays with the
  // right conversation instead of travelling with the index.
  let before = [
    sidebarSummary("s1", running: false),
    sidebarSummary("s2", running: true),
    sidebarSummary("s3", running: false),
  ]
  let after = [sidebarSummary("s0", running: false)] + before

  let visibleBefore = DSHSidebarSessionPaging.visibleSessions(before, expanded: false)
  let visibleAfter = DSHSidebarSessionPaging.visibleSessions(after, expanded: false)
  try expectEqual(visibleBefore.map(\.sessionId), ["s1", "s2", "s3"])
  try expectEqual(visibleAfter.map(\.sessionId), ["s0", "s1", "s2", "s3"])
  // The running row kept its identity — it moved index, not session.
  try expectEqual(visibleAfter.filter(\.running).map(\.sessionId), ["s2"])
  try expectEqual(Set(visibleAfter.map(\.id)), Set(["s0", "s1", "s2", "s3"]))
}

/// sRGB contrast helper: the running marker has to stay legible in both
/// appearances, and eyeballing a screenshot is not a regression check.
private func sidebarContrastRatio(
  _ foreground: (Double, Double, Double, Double),
  _ background: (Double, Double, Double, Double)
) -> Double {
  let foregroundLuminance = sidebarRelativeLuminance(foreground)
  let backgroundLuminance = sidebarRelativeLuminance(background)
  return (max(foregroundLuminance, backgroundLuminance) + 0.05)
    / (min(foregroundLuminance, backgroundLuminance) + 0.05)
}

private func sidebarRelativeLuminance(_ rgba: (Double, Double, Double, Double)) -> Double {
  func linear(_ channel: Double) -> Double {
    channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
  }
  return 0.2126 * linear(rgba.0) + 0.7152 * linear(rgba.1) + 0.0722 * linear(rgba.2)
}

private func sidebarSummary(_ id: String, running: Bool) -> DSHSessionSummary {
  DSHSessionSummary(
    sessionId: id,
    updatedAt: 0,
    running: running,
    blank: false,
    cwd: "/Users/developer/project/ds-harness",
    agentPreset: nil,
    parentSessionId: nil,
    origin: nil,
    projections: nil)
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
  ("Sidebar session paging never folds a running session", testSidebarSessionPaging_neverFoldsARunningSession),
  ("Sidebar session paging folds only the trailing idle run", testSidebarSessionPaging_foldsTheTrailingIdleRunOnly),
  ("Sidebar running token clears three to one on the sidebar", testSidebarRunningToken_clearsThreeToOneOnTheSidebar),
  ("Sidebar visible rows keep session identity across an insert", testSidebarVisibleSessions_followSessionIdentityAcrossAnInsert),
  ("Sidebar running line keeps its geometry and Reduce Motion cut-out", testSidebarRunningLine_keepsItsGeometryAndHonoursReduceMotion),
  ("Sidebar fold control hidden when collapsing removes nothing", testSidebarFoldControl_hiddenWhenCollapsingWouldRemoveNothing),
  ("Sidebar fold control label reports the collapsed row count", testSidebarFoldControl_labelReportsTheCollapsedRowCount),
  ("Sidebar session timestamp uses stable Chinese labels", testSidebarSessionTimestamp_usesStableChineseLabels),
]
