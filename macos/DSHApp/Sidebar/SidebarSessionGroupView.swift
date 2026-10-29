import SwiftUI

enum DSHSidebarSessionPaging {
  static let defaultVisibleCount = 5

  /// Rows a collapsed project renders. A running session is never folded away:
  /// the preview keeps the newest `defaultVisibleCount` rows and then appends
  /// every running session past them, in their original order.
  static func visibleIndices(total: Int, running: [Bool], expanded: Bool) -> [Int] {
    let total = max(0, total)
    guard !expanded else { return Array(0..<total) }
    let preview = min(total, defaultVisibleCount)
    var indices = Array(0..<preview)
    if total > preview {
      indices += (preview..<total).filter { index in
        index < running.count && running[index]
      }
    }
    return indices
  }

  /// Rows the "展开其余 N 个" control would add — running rows never count, they
  /// are already visible.
  static func hiddenCount(total: Int, running: [Bool], expanded: Bool) -> Int {
    max(0, max(0, total) - visibleIndices(total: total, running: running, expanded: expanded).count)
  }

  /// The rows a collapsed project renders, in order. Views iterate these
  /// directly so SwiftUI keys them by session identity instead of by position.
  static func visibleSessions(
    _ sessions: [DSHSessionSummary],
    expanded: Bool
  ) -> [DSHSessionSummary] {
    visibleIndices(
      total: sessions.count,
      running: sessions.map(\.running),
      expanded: expanded
    ).compactMap { index in
      sessions.indices.contains(index) ? sessions[index] : nil
    }
  }

  /// Whether the fold toggle would change anything. Collapsing is a no-op when
  /// the rows past the preview are all running (they stay visible either way),
  /// so the control is hidden instead of silently doing nothing.
  static func showsFoldControl(total: Int, running: [Bool]) -> Bool {
    visibleIndices(total: total, running: running, expanded: false).count
      < visibleIndices(total: total, running: running, expanded: true).count
  }

  /// Label of the fold toggle. The collapsed count is what the row list would
  /// hold after folding — never the current, fully expanded row count.
  static func foldControlLabel(total: Int, running: [Bool], expanded: Bool) -> String {
    if expanded {
      let folded = visibleIndices(total: total, running: running, expanded: false).count
      return "收起至 \(folded) 个"
    }
    return "展开其余 \(hiddenCount(total: total, running: running, expanded: false)) 个"
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
  private var runningFlags: [Bool] { group.sessions.map(\.running) }
  private var visibleSessions: [DSHSessionSummary] {
    DSHSidebarSessionPaging.visibleSessions(group.sessions, expanded: isExpanded)
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
        // Identity, not the row's index: a new session inserted at the top
        // shifts every index, and an index-keyed ForEach would carry each
        // row's @State (hover, popover) over to a different session.
        ForEach(visibleSessions) { session in
          SidebarSessionRow(session: session)
            .padding(.leading, showsHeader ? DSHSpace.s3 : 0)
        }
        // Only offer the toggle when it actually changes what is on screen:
        // collapsing a group whose remainder is entirely running would remove
        // nothing, and a button that does nothing is worse than no button.
        if showsFoldControl {
          Button(action: toggleExpanded) {
            HStack(spacing: 6) {
              Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 8, weight: .semibold))
              Text(expandLabel)
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

  private var showsFoldControl: Bool {
    DSHSidebarSessionPaging.showsFoldControl(
      total: group.sessions.count,
      running: runningFlags)
  }

  private var expandLabel: String {
    DSHSidebarSessionPaging.foldControlLabel(
      total: group.sessions.count,
      running: runningFlags,
      expanded: isExpanded)
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
