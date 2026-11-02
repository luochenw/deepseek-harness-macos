import AppKit
import Foundation
import SwiftUI
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

@MainActor
private func testActivityLine_movesOnlyInAWindowWhileActive() throws {
  // Core Animation runs the shuttle, so a line that stops or leaves the window
  // has to take the animation off the layer itself.
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 240, height: 2),
    styleMask: .borderless, backing: .buffered, defer: false)
  let line = DSHActivityLineView(frame: NSRect(x: 0, y: 0, width: 240, height: 2))
  line.configure(moving: true, color: .systemBlue, height: 1.2)
  try expect(!line.isShuttling, "no window, no animation")

  window.contentView?.addSubview(line)
  try expect(line.isShuttling, "an active line in a window shuttles")

  CATransaction.flush()
  let start = line.layer?.sublayers?.first?.presentation()?.position.x
  RunLoop.current.run(until: Date().addingTimeInterval(0.3))
  let later = line.layer?.sublayers?.first?.presentation()?.position.x
  try expect(start != nil && start != later, "the segment really travels, \(String(describing: start)) -> \(String(describing: later))")

  line.configure(moving: false, color: .systemBlue, height: 1.2)
  try expect(!line.isShuttling, "Reduce Motion or a finished process stops it")

  line.configure(moving: true, color: .systemBlue, height: 1.2)
  line.removeFromSuperview()
  try expect(!line.isShuttling, "leaving the window stops it")
}

@MainActor
private func testRunningBars_pulseOnlyInAWindow() throws {
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 9, height: 10),
    styleMask: .borderless, backing: .buffered, defer: true)
  let bars = DSHRunningBarsView(frame: NSRect(x: 0, y: 0, width: 9, height: 10))
  bars.configure(moving: true, color: .systemOrange, height: 10)
  try expect(!bars.isPulsing, "no window, no animation")

  window.contentView?.addSubview(bars)
  try expect(bars.isPulsing)

  bars.configure(moving: false, color: .systemOrange, height: 10)
  try expect(!bars.isPulsing, "Reduce Motion leaves the bars still")
}

@MainActor
private func testRunningWhale_animatesOnlyInAWindow() throws {
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 18, height: 18),
    styleMask: .borderless, backing: .buffered, defer: true)
  let whale = DSHRunningWhaleView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
  whale.configure(moving: true, size: 18)
  try expect(!whale.isAnimating, "no window, no animation")

  window.contentView?.addSubview(whale)
  try expect(whale.isAnimating, "every wave and the whale move")

  whale.configure(moving: false, size: 18)
  try expect(!whale.isAnimating, "Reduce Motion leaves the frame still")
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

private func sidebarSummary(
  _ id: String,
  running: Bool,
  origin: String? = nil,
  parent: String? = nil,
  updatedAt: Double = 0,
  title: String? = nil,
  cwd: String = "/Users/developer/project/ds-harness"
) -> DSHSessionSummary {
  DSHSessionSummary(
    sessionId: id,
    updatedAt: updatedAt,
    running: running,
    blank: false,
    cwd: cwd,
    agentPreset: nil,
    parentSessionId: parent,
    origin: origin,
    projections: title.map { title in
      DSHSessionProjections(
        asOfSeq: 1,
        values: DSHSessionProjectionValues(
          title: title,
          todos: nil,
          plan: nil,
          goal: nil,
          tokenUsage: nil,
          contextPressure: nil,
          sessionStats: nil))
    })
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

private func testSidebarSubagentLayout_nestsChildrenUnderTheirParent() throws {
  let rows = DSHSidebarSubagentLayout.rows([
    sidebarSummary("parent", running: false),
    sidebarSummary("child-1", running: false, origin: "subagent", parent: "parent"),
    sidebarSummary("other", running: false),
    sidebarSummary("child-2", running: true, origin: "subagent", parent: "parent"),
    sidebarSummary("child-3", running: false, origin: "subagent", parent: "parent"),
  ])
  // Only the two top-level sessions stay in the list; the three children are
  // reachable through their parent row alone.
  try expectEqual(rows.topLevel.map(\.sessionId), ["parent", "other"])
  try expectEqual(
    rows.children["parent"]?.map(\.sessionId) ?? [],
    ["child-1", "child-2", "child-3"])
  try expectEqual(rows.children.count, 1)
}

private func testSidebarSubagentLayout_orphanFallsBackToTopLevel() throws {
  // The parent is archived and gone from the snapshot: its child must not
  // vanish with it, it becomes a normal top-level row again.
  let rows = DSHSidebarSubagentLayout.rows([
    sidebarSummary("child", running: false, origin: "subagent", parent: "archived-parent"),
    sidebarSummary("other", running: false),
  ])
  try expectEqual(rows.topLevel.map(\.sessionId), ["child", "other"])
  try expect(rows.children.isEmpty, "an orphan has no parent row to nest under")

  // A self-referencing parentSessionId cannot nest under itself either.
  let selfParent = DSHSidebarSubagentLayout.rows([
    sidebarSummary("loop", running: false, origin: "subagent", parent: "loop"),
  ])
  try expectEqual(selfParent.topLevel.map(\.sessionId), ["loop"])
  try expect(selfParent.children.isEmpty, "a self-parented session cannot nest under itself")
}

private func testSidebarSubagentLayout_grandchildStaysVisible() throws {
  // Z is a root, X is Z's subagent, Y is X's subagent. A child row renders no
  // children of its own, so nesting Y under X would put it nowhere on screen.
  // Every session must appear exactly once in what the sidebar draws.
  let rows = DSHSidebarSubagentLayout.rows([
    sidebarSummary("z", running: false),
    sidebarSummary("x", running: false, origin: "subagent", parent: "z"),
    sidebarSummary("y", running: false, origin: "subagent", parent: "x"),
  ])
  try expectEqual(rows.topLevel.map(\.sessionId), ["z", "y"])
  try expectEqual(rows.children["z"]?.map(\.sessionId) ?? [], ["x"])
  try expect(rows.children["x"] == nil, "a nested row cannot carry children of its own")
  let rendered = Set(
    rows.topLevel.map(\.sessionId) + rows.children.values.flatMap { $0.map(\.sessionId) })
  try expectEqual(rendered, Set(["z", "x", "y"]))
}

private func testSidebarSubagentLayout_forkStaysTopLevel() throws {
  // A forked session names its source in parentSessionId but carries no
  // subagent origin — the sidebar keeps it as a peer row.
  let rows = DSHSidebarSubagentLayout.rows([
    sidebarSummary("source", running: false),
    sidebarSummary("fork", running: false, parent: "source"),
  ])
  try expectEqual(rows.topLevel.map(\.sessionId), ["source", "fork"])
  try expect(rows.children.isEmpty, "a fork is not a subagent and must not collapse")
}

private func testSidebarSubagentLayout_childrenDoNotCountTowardsFolding() throws {
  // One parent + three children: the sidebar shows one top-level row, and the
  // 5-row preview / 「展开其余 N 个」 arithmetic never sees the children.
  let parent = sidebarSummary("parent", running: false)
  let children = (1...3).map {
    sidebarSummary("child-\($0)", running: false, origin: "subagent", parent: "parent")
  }
  let rows = DSHSidebarSubagentLayout.rows([parent] + children)
  try expectEqual(rows.children["parent"]?.count, 3)

  let visible = DSHSidebarSessionPaging.visibleSessions(rows.topLevel, expanded: false)
  try expectEqual(visible.map(\.sessionId), ["parent"])
  try expectEqual(
    DSHSidebarSessionPaging.hiddenCount(total: rows.topLevel.count, running: [false], expanded: false),
    0)
  try expect(
    !DSHSidebarSessionPaging.showsFoldControl(total: rows.topLevel.count, running: [false]),
    "a parent with three children is still one row and offers no fold control")

  // Eight top-level rows with four children each: the preview still stops at
  // five rows, and the hidden count is rows — not rows plus children.
  let many = (0..<8).map { sidebarSummary("p\($0)", running: false) }
  let manyChildren = many.flatMap { parent in
    (0..<4).map {
      sidebarSummary(
        "\(parent.sessionId)-c\($0)",
        running: false,
        origin: "subagent",
        parent: parent.sessionId)
    }
  }
  let manyRows = DSHSidebarSubagentLayout.rows(many + manyChildren)
  try expectEqual(manyRows.topLevel.count, 8)
  try expectEqual(
    DSHSidebarSessionPaging.visibleSessions(manyRows.topLevel, expanded: false).count,
    5)
  try expectEqual(
    DSHSidebarSessionPaging.hiddenCount(total: manyRows.topLevel.count, running: [Bool](repeating: false, count: 8), expanded: false),
    3)
  try expectEqual(manyChildren.count, 32)
}

private func testSidebarSubagentLayout_runningChildKeepsParentRowActive() throws {
  // The parent itself is idle; only a child runs. The parent row must still
  // paint the activity line.
  let parent = sidebarSummary("parent", running: false)
  let child = sidebarSummary("child", running: true, origin: "subagent", parent: "parent")
  let rows = DSHSidebarSubagentLayout.rows([parent, child])
  let flags = DSHSidebarSubagentLayout.runningFlags(rows.topLevel, subagents: rows.children)
  try expectEqual(flags, [true])
  try expect(DSHSidebarSubagentLayout.showsActivity(parent, subagents: [child]))

  // Idle parent, idle child: no activity.
  let idleChild = sidebarSummary("idle-child", running: false, origin: "subagent", parent: "parent")
  try expect(!DSHSidebarSubagentLayout.showsActivity(parent, subagents: [idleChild]))
  try expect(!DSHSidebarSubagentLayout.showsActivity(parent, subagents: []))

  // A running parent with no children still reports itself.
  try expect(
    DSHSidebarSubagentLayout.showsActivity(sidebarSummary("busy", running: true), subagents: []))
}

private func testSidebarSubagentLayout_orphansRejoinTheirProjectGroup() throws {
  // `sessionGroups` drops subagent rows; an orphaned child must come back into
  // the group its directory maps to, in updatedAt order.
  let workspace = HarnessController.WorkspaceSessionGroup(
    workspace: DSHWorkspaceView(
      workspaceId: "ws-1",
      path: "/Users/developer/project/ds-harness",
      title: "ds-harness",
      sessionIds: []),
    sessions: [sidebarSummary("parent", running: false, updatedAt: 300)])
  let orphan = sidebarSummary(
    "orphan", running: false, origin: "subagent", parent: "gone", updatedAt: 200)
  let grouped = DSHSidebarSubagentLayout.groups([workspace], sessions: [orphan])
  try expectEqual(grouped.count, 1)
  try expectEqual(grouped[0].sessions.map(\.sessionId), ["parent", "orphan"])

  // No matching group: the child gets its own directory bucket instead of
  // disappearing from the sidebar entirely.
  let ungrouped = DSHSidebarSubagentLayout.groups([], sessions: [orphan])
  try expectEqual(ungrouped.count, 1)
  try expectEqual(ungrouped[0].sessions.map(\.sessionId), ["orphan"])
  try expectEqual(ungrouped[0].title, "ds-harness")

  // Nested children are not orphans and must not be duplicated into groups.
  let nested = sidebarSummary("child", running: false, origin: "subagent", parent: "parent")
  let untouched = DSHSidebarSubagentLayout.groups(
    [workspace],
    sessions: [sidebarSummary("parent", running: false, updatedAt: 300), nested])
  try expectEqual(untouched[0].sessions.map(\.sessionId), ["parent"])
}

private func testSidebarSubagentLayout_orphanPrefersItsNamedBucketOverFlat() throws {
  // The flat bucket (no workspace, no folder name) is listed FIRST. A single
  // scan that falls through to it would swallow the child even though a folder
  // bucket further down actually names its directory.
  let flat = HarnessController.WorkspaceSessionGroup(
    workspace: nil,
    sessions: [sidebarSummary("flat-member", running: false, updatedAt: 900)])
  let folder = HarnessController.WorkspaceSessionGroup(
    workspace: nil,
    sessions: [sidebarSummary("folder-member", running: false, updatedAt: 900)],
    fallbackTitle: "ds-harness")
  let orphan = sidebarSummary("orphan", running: false, origin: "subagent", parent: "gone")
  let grouped = DSHSidebarSubagentLayout.groups([flat, folder], sessions: [orphan])
  try expect(grouped.count == 2, "the child joins an existing bucket, it does not add one")
  try expectEqual(grouped[0].sessions.map(\.sessionId), ["flat-member"])
  try expectEqual(grouped[1].sessions.map(\.sessionId), ["folder-member", "orphan"])
}

private func testSidebarSubagentLayout_sameNamedFoldersMatchTheExactPath() throws {
  // Two different directories both called "proj": the name alone is ambiguous,
  // so the child is routed by the full path of its own cwd.
  let first = HarnessController.WorkspaceSessionGroup(
    workspace: DSHWorkspaceView(
      workspaceId: "ws-a",
      path: "/Users/developer/a/proj",
      title: "proj",
      sessionIds: []),
    sessions: [sidebarSummary("a-member", running: false, updatedAt: 900)])
  let second = HarnessController.WorkspaceSessionGroup(
    workspace: DSHWorkspaceView(
      workspaceId: "ws-b",
      path: "/Users/developer/b/proj",
      title: "proj",
      sessionIds: []),
    sessions: [sidebarSummary("b-member", running: false, updatedAt: 900)])
  let orphan = sidebarSummary(
    "orphan", running: false, origin: "subagent", parent: "gone",
    cwd: "/Users/developer/b/proj")

  let grouped = DSHSidebarSubagentLayout.groups([first, second], sessions: [orphan])
  try expectEqual(grouped.count, 2)
  try expectEqual(grouped[0].sessions.map(\.sessionId), ["a-member"])
  try expectEqual(grouped[1].sessions.map(\.sessionId), ["b-member", "orphan"])
}

private func testSidebarSubagentLayout_selectionFollowsTheVisibleRow() throws {
  let parent = sidebarSummary("parent", running: false)
  let child = sidebarSummary("child", running: false, origin: "subagent", parent: "parent")
  let elsewhere = sidebarSummary("elsewhere", running: false)

  func highlighted(showsSubagentRows: Bool, openChild: String?, current: String) -> [String] {
    [parent, child, elsewhere]
      .filter {
        DSHSidebarSubagentLayout.carriesSelection(
          session: $0,
          subagents: [child],
          activeChildSessionId: openChild,
          currentSessionId: current,
          showsSubagentRows: showsSubagentRows)
      }
      .map(\.sessionId)
  }

  // Child rows drawn: only the child is highlighted.
  try expectEqual(highlighted(showsSubagentRows: true, openChild: "child", current: "parent"), ["child"])
  // Child rows collapsed (or the project folded): the parent takes it, else the
  // list would show no selection at all.
  try expectEqual(highlighted(showsSubagentRows: false, openChild: "child", current: "parent"), ["parent"])

  // No child open: the current session is the one highlighted.
  try expectEqual(highlighted(showsSubagentRows: true, openChild: nil, current: "elsewhere"), ["elsewhere"])

  // The child's own row is drawn: it keeps the highlight even if some other
  // session is the current one, and no unrelated row lights up.
  try expectEqual(highlighted(showsSubagentRows: true, openChild: "child", current: "elsewhere"), ["child"])
}

// MARK: - Offscreen snapshot of the subagent rows
//
// The nesting is a layout claim as much as a data claim: the 「N 个子会话」
// control, the indented child rows and the parent's running line have to be
// visible in both appearances. No fixture — the rows are synthesised here.

private struct SidebarSubagentSnapshotProbe: View {
  let group: HarnessController.WorkspaceSessionGroup
  let subagents: [String: [DSHSessionSummary]]
  @State private var expandedRows: Set<String>

  init(
    group: HarnessController.WorkspaceSessionGroup,
    subagents: [String: [DSHSessionSummary]],
    expanded: Bool
  ) {
    self.group = group
    self.subagents = subagents
    _expandedRows = State(initialValue: expanded ? Set(group.sessions.map(\.sessionId)) : [])
  }

  var body: some View {
    SidebarSessionGroupView(
      group: group,
      showsHeader: true,
      subagents: subagents,
      collapsedGroups: .constant([]),
      expandedGroups: .constant([]),
      expandedSubagentRows: $expandedRows)
      .padding(DSHSpace.s4)
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .background(DSHTheme.sidebarBg)
  }
}

@MainActor private func sidebarSnapshotDirectory() -> URL {
  let directory = ProcessInfo.processInfo.environment["DSH_SIDEBAR_SNAPSHOT_OUT"]
    .map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? URL(fileURLWithPath: "/tmp/dsh-sidebar/out", isDirectory: true)
  try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

@MainActor private func writeSidebarSnapshot(
  _ root: AnyView,
  name: String,
  size: CGSize,
  appearance: NSAppearance.Name
) throws -> Data {
  let hosting = NSHostingView(rootView: root)
  hosting.appearance = NSAppearance(named: appearance)
  hosting.frame = NSRect(origin: .zero, size: size)
  let window = NSWindow(
    contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
    styleMask: .borderless,
    backing: .buffered,
    defer: false)
  window.isReleasedWhenClosed = false
  window.contentView = hosting
  window.orderFrontRegardless()
  // Two passes: the first lays the rows out, the second lets the running
  // line's 0.18s appear animation finish before the capture.
  RunLoop.main.run(until: Date().addingTimeInterval(0.3))
  hosting.layoutSubtreeIfNeeded()
  RunLoop.main.run(until: Date().addingTimeInterval(0.3))
  hosting.layoutSubtreeIfNeeded()
  hosting.displayIfNeeded()
  guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
    window.orderOut(nil)
    window.close()
    throw TestFailure.message("\(name): no bitmap")
  }
  hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
  window.orderOut(nil)
  window.close()
  guard let png = bitmap.representation(using: .png, properties: [:]) else {
    throw TestFailure.message("\(name): cannot encode PNG")
  }
  try expect(png.count > 3_000, "\(name): snapshot looks empty")
  let destination = sidebarSnapshotDirectory().appendingPathComponent("\(name).png")
  try png.write(to: destination)
  print("  sidebar snapshot \(name) → \(destination.path)")
  return png
}

private func testSidebarSubagents_snapshotInBothAppearances() throws {
  try MainActor.assumeIsolated {
    _ = NSApplication.shared
    let now = 1_790_000_000_000.0
    let parent = sidebarSummary(
      "parent", running: false, updatedAt: now, title: "重构侧边栏分组")
    let children = [
      sidebarSummary(
        "child-1", running: true, origin: "subagent", parent: "parent",
        updatedAt: now - 20_000, title: "探索分页实现"),
      sidebarSummary(
        "child-2", running: false, origin: "subagent", parent: "parent",
        updatedAt: now - 60_000, title: "核对折叠规则"),
      sidebarSummary(
        "child-3", running: false, origin: "subagent", parent: "parent",
        updatedAt: now - 120_000, title: "补离屏快照"),
    ]
    let peer = sidebarSummary(
      "peer", running: false, updatedAt: now - 240_000, title: "修复转录区高度")
    let group = HarnessController.WorkspaceSessionGroup(
      workspace: nil,
      sessions: [parent, peer],
      fallbackTitle: "ds-harness")
    let rows = DSHSidebarSubagentLayout.rows([parent, peer] + children)
    let subagents = rows.children

    // The canvas alone proves nothing: a picture of an empty sidebar would
    // still be a valid PNG. These assertions pin what the frame must contain.
    try expect(
      subagents["parent"]?.count == 3,
      "all three children must nest under the parent, got \(subagents["parent"]?.count ?? 0)")
    try expectEqual(rows.topLevel.map(\.sessionId), ["parent", "peer"])
    let flags = DSHSidebarSubagentLayout.runningFlags(rows.topLevel, subagents: subagents)
    try expect(flags == [true, false],
               "an idle parent with a running child must report activity, got \(flags)")

    let harness = HarnessController(startRuntime: false)
    harness.hostSessions = [parent, peer] + children
    harness.hostCurrentSessionID = "parent"

    var images: [String: Data] = [:]
    for (suffix, appearance) in [
      ("", NSAppearance.Name.aqua),
      ("-dark", NSAppearance.Name.darkAqua),
    ] {
      for expanded in [false, true] {
        let name = "sidebar-subagents-\(expanded ? "expanded" : "collapsed")\(suffix)"
        let root = AnyView(
          SidebarSubagentSnapshotProbe(
            group: group,
            subagents: subagents,
            expanded: expanded)
            .environmentObject(harness))
        images[name] = try writeSidebarSnapshot(
          root,
          name: name,
          size: CGSize(width: DSHMainWindowLayout.regularSidebarWidth, height: 300),
          appearance: appearance)
      }
    }
    NSApp.appearance = NSAppearance(named: .aqua)

    // Same content, same size: only the resolved appearance can make the bytes
    // differ, so this fails if one of the two passes silently rendered neither.
    try expect(
      images["sidebar-subagents-expanded"] != images["sidebar-subagents-expanded-dark"],
      "light and dark must resolve to different pixels")
    try expect(
      images["sidebar-subagents-collapsed"] != images["sidebar-subagents-expanded"],
      "the collapsed and expanded frames must differ — the child rows must draw")
  }
}

let dshSidebarTests: [NamedTest] = [
  ("Sidebar session paging defaults to five and expands all", testSidebarSessionPaging_defaultsToFiveAndExpandsAll),
  ("Sidebar session paging reports exact hidden count", testSidebarSessionPaging_reportsExactHiddenCount),
  ("Sidebar session paging never folds a running session", testSidebarSessionPaging_neverFoldsARunningSession),
  ("Sidebar session paging folds only the trailing idle run", testSidebarSessionPaging_foldsTheTrailingIdleRunOnly),
  ("Sidebar running token clears three to one on the sidebar", testSidebarRunningToken_clearsThreeToOneOnTheSidebar),
  ("Sidebar visible rows keep session identity across an insert", testSidebarVisibleSessions_followSessionIdentityAcrossAnInsert),
  ("Sidebar running line keeps its geometry and Reduce Motion cut-out", testSidebarRunningLine_keepsItsGeometryAndHonoursReduceMotion),
  ("Activity line moves only in a window while active", { try MainActor.assumeIsolated { try testActivityLine_movesOnlyInAWindowWhileActive() } }),
  ("Running bars pulse only in a window", { try MainActor.assumeIsolated { try testRunningBars_pulseOnlyInAWindow() } }),
  ("Running whale animates only in a window", { try MainActor.assumeIsolated { try testRunningWhale_animatesOnlyInAWindow() } }),
  ("Sidebar fold control hidden when collapsing removes nothing", testSidebarFoldControl_hiddenWhenCollapsingWouldRemoveNothing),
  ("Sidebar fold control label reports the collapsed row count", testSidebarFoldControl_labelReportsTheCollapsedRowCount),
  ("Sidebar session timestamp uses stable Chinese labels", testSidebarSessionTimestamp_usesStableChineseLabels),
  ("Sidebar subagents nest under their parent row", testSidebarSubagentLayout_nestsChildrenUnderTheirParent),
  ("Sidebar orphaned subagent falls back to a top-level row", testSidebarSubagentLayout_orphanFallsBackToTopLevel),
  ("Sidebar grandchild subagent stays visible", testSidebarSubagentLayout_grandchildStaysVisible),
  ("Sidebar fork is not collapsed as a subagent", testSidebarSubagentLayout_forkStaysTopLevel),
  ("Sidebar subagent rows do not count towards folding", testSidebarSubagentLayout_childrenDoNotCountTowardsFolding),
  ("Sidebar running subagent keeps the parent row active", testSidebarSubagentLayout_runningChildKeepsParentRowActive),
  ("Sidebar orphaned subagent rejoins its project group", testSidebarSubagentLayout_orphansRejoinTheirProjectGroup),
  ("Sidebar orphan prefers its named bucket over the flat one", testSidebarSubagentLayout_orphanPrefersItsNamedBucketOverFlat),
  ("Sidebar same-named folders match the exact path", testSidebarSubagentLayout_sameNamedFoldersMatchTheExactPath),
  ("Sidebar selection follows the visible row", testSidebarSubagentLayout_selectionFollowsTheVisibleRow),
  ("Sidebar subagent rows render in both appearances", testSidebarSubagents_snapshotInBothAppearances),
]
