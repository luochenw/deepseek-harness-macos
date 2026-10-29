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
  @State private var headerHovering = false

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
              .font(DSHType.micro.weight(.bold))
              .rotationEffect(.degrees(isCollapsed ? 0 : 90))
              .foregroundStyle(DSHTheme.inkFaint)
            Image(systemName: "folder")
              .font(DSHType.caption.weight(.medium))
              .foregroundStyle(DSHTheme.inkSoft)
            Text(group.title)
              .font(DSHType.label.weight(.semibold))
              .foregroundStyle(DSHTheme.inkSoft)
              .lineLimit(1)
            Text("\(group.sessions.count)")
              .font(DSHType.micro.monospacedDigit())
              .foregroundStyle(DSHTheme.inkSoft)
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(
                DSHTheme.surfaceTint2,
                in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Spacer(minLength: 0)
          }
          .padding(.horizontal, DSHSpace.s2)
          .padding(.vertical, 5)
          .background(
            headerHovering ? DSHTheme.surfaceTint2 : Color.clear,
            in: RoundedRectangle(cornerRadius: DSHRadius.sm, style: .continuous))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { headerHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: headerHovering)
        .help(isCollapsed ? "展开项目" : "折叠项目")
      }

      if !isCollapsed {
        ForEach(Array(group.sessions.prefix(visibleCount))) { session in
          SidebarSessionRow(session: session)
            .padding(.leading, showsHeader ? DSHSpace.s3 : 0)
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
            .padding(.leading, showsHeader ? 38 : 10)
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
