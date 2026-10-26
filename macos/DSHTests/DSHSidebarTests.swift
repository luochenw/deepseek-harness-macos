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

let dshSidebarTests: [NamedTest] = [
  ("Sidebar session paging defaults to five and expands all", testSidebarSessionPaging_defaultsToFiveAndExpandsAll),
  ("Sidebar session paging reports exact hidden count", testSidebarSessionPaging_reportsExactHiddenCount),
]
