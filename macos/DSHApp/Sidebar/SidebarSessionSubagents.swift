import SwiftUI

/// Sidebar grouping for `origin == "subagent"` sessions. A child nests under the
/// parent row it names; when that parent is not in the list (archived, filtered)
/// the child falls back to a top-level row instead of disappearing. A fork keeps
/// `parentSessionId` but has no subagent origin, so it stays top level.
enum DSHSidebarSubagentLayout {
  struct Rows {
    var topLevel: [DSHSessionSummary]
    var children: [String: [DSHSessionSummary]]
  }

  static func rows(_ sessions: [DSHSessionSummary]) -> Rows {
    // Nesting is one level deep on purpose: a nested row is drawn by
    // `SidebarSessionRow`, which renders no children of its own. A grandchild
    // would land in `children` with nothing on screen to show it — so a
    // session whose parent is itself a subagent stays a top-level row.
    let roots = Set(sessions.filter { $0.origin != "subagent" }.map(\.sessionId))
    var rows = Rows(topLevel: [], children: [:])
    for session in sessions {
      guard nests(session, under: roots), let parent = session.parentSessionId else {
        rows.topLevel.append(session)
        continue
      }
      rows.children[parent, default: []].append(session)
    }
    return rows
  }

  private static func nests(_ session: DSHSessionSummary, under roots: Set<String>) -> Bool {
    guard session.origin == "subagent",
          let parent = session.parentSessionId,
          parent != session.sessionId
    else { return false }
    return roots.contains(parent)
  }

  /// A collapsed parent row still reports that work is happening underneath it.
  static func showsActivity(
    _ parent: DSHSessionSummary,
    subagents: [DSHSessionSummary]
  ) -> Bool {
    parent.running || subagents.contains(where: \.running)
  }

  /// Top-level rows only, with each parent's activity widened by its children.
  /// The 5-row preview must treat a parent with a running subagent exactly like
  /// a running session, or an active row would fold away.
  static func runningFlags(
    _ sessions: [DSHSessionSummary],
    subagents: [String: [DSHSessionSummary]]
  ) -> [Bool] {
    sessions.map { showsActivity($0, subagents: subagents[$0.sessionId] ?? []) }
  }

  /// Whether one row carries the selection highlight. Exactly one row is
  /// highlighted at a time: the open child while its row is actually drawn,
  /// and its parent whenever the child rows are collapsed — otherwise opening
  /// a child and folding the list back up would leave nothing selected.
  static func carriesSelection(
    session: DSHSessionSummary,
    subagents: [DSHSessionSummary],
    activeChildSessionId: String?,
    currentSessionId: String?,
    showsSubagentRows: Bool
  ) -> Bool {
    guard let activeChildSessionId else {
      return currentSessionId == session.sessionId
    }
    // The child only has a row while its parent is expanded — a collapsed list
    // paints no child line, so the highlight falls back to the current session.
    let childRowIsDrawn = showsSubagentRows
      && subagents.contains { $0.sessionId == activeChildSessionId }
    return childRowIsDrawn
      ? session.sessionId == activeChildSessionId
      : currentSessionId == session.sessionId
  }

  /// Merges orphaned subagents back into the workspace grouping as top-level
  /// rows, by the same cwd → workspace / directory-name rule the Host grouping
  /// uses, so an archived parent cannot drop its children from the sidebar.
  /// Three passes, in this order: a workspace whose folder is the child's cwd,
  /// then a directory-named bucket, and only then the flat all-sessions bucket.
  /// One pass that falls through per group would let a flat bucket swallow a
  /// child that a folder bucket further down actually names.
  static func groups(
    _ groups: [HarnessController.WorkspaceSessionGroup],
    sessions: [DSHSessionSummary]
  ) -> [HarnessController.WorkspaceSessionGroup] {
    let orphans = rows(sessions).topLevel.filter { $0.origin == "subagent" }
    guard !orphans.isEmpty else { return groups }
    var result = groups
    for orphan in orphans {
      let folder = folderName(orphan.cwd)
      var target = result.firstIndex { $0.workspace?.path == orphan.cwd }
      if target == nil, let folder {
        target = result.firstIndex { $0.workspace == nil && $0.fallbackTitle == folder }
      }
      if target == nil {
        target = result.firstIndex { $0.workspace == nil && $0.fallbackTitle == nil }
      }
      guard let index = target else {
        result.append(HarnessController.WorkspaceSessionGroup(
          workspace: nil,
          sessions: [orphan],
          fallbackTitle: folder))
        continue
      }
      let group = result[index]
      var members = group.sessions
      let insertAt = members.firstIndex { $0.updatedAt < orphan.updatedAt } ?? members.endIndex
      members.insert(orphan, at: insertAt)
      result[index] = HarnessController.WorkspaceSessionGroup(
        workspace: group.workspace,
        sessions: members,
        fallbackTitle: group.fallbackTitle)
    }
    return result
  }

  private static func folderName(_ cwd: String?) -> String? {
    guard let cwd, !cwd.isEmpty else { return nil }
    return URL(fileURLWithPath: cwd).lastPathComponent
  }
}

/// One top-level session row plus its subagent rows and the collapsed
/// 「N 个子会话」 control between them.
struct SidebarSessionTreeRow: View {
  @EnvironmentObject private var harness: HarnessController
  let session: DSHSessionSummary
  let subagents: [DSHSessionSummary]
  @Binding var expandedRows: Set<String>

  private var isExpanded: Bool { expandedRows.contains(session.sessionId) }

  private var activeChildSessionId: String? { harness.activeSubagentAddress?.childSessionId }

  /// Only the row that actually holds the selection is highlighted — and while
  /// the child rows are collapsed the parent takes it, so the list never ends
  /// up with no selected row at all.
  private func carriesSelection(_ row: DSHSessionSummary) -> Bool {
    DSHSidebarSubagentLayout.carriesSelection(
      session: row,
      subagents: subagents,
      activeChildSessionId: activeChildSessionId,
      currentSessionId: harness.hostCurrentSessionID,
      showsSubagentRows: isExpanded)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      SidebarSessionRow(
        session: session,
        showsActivity: DSHSidebarSubagentLayout.showsActivity(session, subagents: subagents),
        showsSelection: carriesSelection(session))
      if !subagents.isEmpty {
        Button(action: toggleExpanded) {
          HStack(spacing: 6) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
              .font(.system(size: 8, weight: .semibold))
            Text("\(subagents.count) 个子会话")
              .font(.system(size: 11.5, weight: .medium))
          }
          .foregroundStyle(DSHTheme.inkFaint)
          .padding(.leading, 26)
          .padding(.vertical, 3)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "收起子会话" : "展开子会话")
        .accessibilityLabel(isExpanded ? "收起子会话" : "展开子会话")
        .accessibilityValue("\(subagents.count) 个子会话")
        if isExpanded {
          ForEach(subagents) { child in
            SidebarSessionRow(
              session: child,
              onOpen: { harness.openSidebarSubagent(child) },
              showsSelection: carriesSelection(child))
              .padding(.leading, DSHSpace.s3)
          }
        }
      }
    }
  }

  private func toggleExpanded() {
    if isExpanded { expandedRows.remove(session.sessionId) }
    else { expandedRows.insert(session.sessionId) }
  }
}

extension HarnessController {
  /// Opens a subagent row: the parent session first, then the child transcript.
  /// `openSubagent` takes a catalogue entry, so this reads the parent's catalogue
  /// (the same `subagent.list` call `loadSubagents` makes) and hands the entry
  /// over — no child state is written here.
  func openSidebarSubagent(_ child: DSHSessionSummary) {
    guard let parentSessionId = child.parentSessionId, !parentSessionId.isEmpty,
          parentSessionId != child.sessionId
    else { return }
    if hostCurrentSessionID != parentSessionId {
      guard let parent = hostSessions.first(where: { $0.sessionId == parentSessionId }) else {
        status = "主会话不在列表中，无法打开子会话"
        return
      }
      openHostSession(parent)
    }
    guard let hostClient else { return }
    // Leaving a previously-opened child behind would show it on top of the new
    // parent if the catalogue read fails — drop the presentation first.
    invalidateSubagentPresentationLoad()
    activeSubagentAddress = nil
    subagentPath = []
    subagentTranscript = nil
    // Clicking A then B under the same parent issues two reads; the generation
    // guard makes the later click win and drops A's late reply.
    let generation = beginSubagentCatalogLoad(parentSessionID: parentSessionId)
    let childSessionId = child.sessionId
    Task {
      do {
        let catalog = try await hostClient.subagents(parentSessionId: parentSessionId)
        await MainActor.run {
          guard self.hostCurrentSessionID == parentSessionId,
                self.acceptsSubagentCatalogLoad(
                  parentSessionID: parentSessionId,
                  generation: generation)
          else { return }
          guard let entry = catalog.entries.first(where: { $0.id == childSessionId }) else {
            self.status = "子会话已不在主会话目录中"
            return
          }
          self.openSubagent(entry)
        }
      } catch {
        await MainActor.run {
          guard self.hostCurrentSessionID == parentSessionId,
                self.acceptsSubagentCatalogLoad(
                  parentSessionID: parentSessionId,
                  generation: generation)
          else { return }
          self.status = "读取子会话目录失败：\(error.localizedDescription)"
        }
      }
    }
  }
}
