import SwiftUI

enum DSHSidebarSessionPaging {
  static let defaultVisibleCount = 5

  static func visibleCount(total: Int, expanded: Bool) -> Int {
    expanded ? max(0, total) : min(max(0, total), defaultVisibleCount)
  }

  static func hiddenCount(total: Int, expanded: Bool) -> Int {
    max(0, total - visibleCount(total: total, expanded: expanded))
  }
}

struct SidebarSessionGroupView: View {
  @EnvironmentObject private var harness: HarnessController
  let group: HarnessController.WorkspaceSessionGroup
  let showsHeader: Bool
  @Binding var collapsedGroups: Set<String>
  @Binding var expandedGroups: Set<String>

  private var isCollapsed: Bool { collapsedGroups.contains(group.id) }
  private var isExpanded: Bool { expandedGroups.contains(group.id) }
  private var visibleCount: Int {
    DSHSidebarSessionPaging.visibleCount(
      total: group.sessions.count,
      expanded: isExpanded)
  }
  private var hiddenCount: Int {
    DSHSidebarSessionPaging.hiddenCount(
      total: group.sessions.count,
      expanded: isExpanded)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      if showsHeader {
        Button(action: toggleCollapsed) {
          HStack(spacing: DSHSpace.s2) {
            Image(systemName: "chevron.right")
              .font(.system(size: 8, weight: .bold))
              .rotationEffect(.degrees(isCollapsed ? 0 : 90))
              .foregroundStyle(DSHTheme.inkFaint)
            Image(systemName: "folder")
              .font(.system(size: 11.5, weight: .medium))
              .foregroundStyle(DSHTheme.inkSoft)
            Text(group.title)
              .font(.system(size: 11.5, weight: .semibold))
              .foregroundStyle(DSHTheme.inkSoft)
              .lineLimit(1)
            Text("\(group.sessions.count)")
              .font(.system(size: 10.5, design: .monospaced))
              .foregroundStyle(DSHTheme.inkFaint)
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 2)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isCollapsed ? "展开项目" : "折叠项目")
      }

      if !isCollapsed {
        ForEach(Array(group.sessions.prefix(visibleCount))) { session in
          SidebarSessionRow(session: session)
        }
        if group.sessions.count > DSHSidebarSessionPaging.defaultVisibleCount {
          Button(action: toggleExpanded) {
            HStack(spacing: 6) {
              Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 8, weight: .semibold))
              Text(isExpanded ? "收起至 5 个" : "展开其余 \(hiddenCount) 个")
                .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(DSHTheme.inkFaint)
            .padding(.leading, showsHeader ? 28 : 10)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  private func toggleCollapsed() {
    if isCollapsed { collapsedGroups.remove(group.id) }
    else { collapsedGroups.insert(group.id) }
  }

  private func toggleExpanded() {
    if isExpanded { expandedGroups.remove(group.id) }
    else { expandedGroups.insert(group.id) }
  }
}
