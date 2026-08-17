import SwiftUI

struct Sidebar: View {
  @EnvironmentObject var harness: HarnessController

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      newSessionButton
      workspaceSection
      sessionSection
      Spacer()
      WorkspaceManagerView()
      Button(action: { harness.showSettings = true }) {
        Label("设置", systemImage: "gearshape")
      }
      Text(harness.hostStatus)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(2)
      Text("本机运行 · \(harness.permission.label)")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(16)
  }

  private var header: some View {
    HStack {
      Label("DeepSeek Harness", systemImage: "sparkles")
        .font(.headline)
      Spacer()
      Button(action: harness.newSession) {
        Image(systemName: "square.and.pencil")
      }
      .help("新会话")
    }
  }

  private var newSessionButton: some View {
    Button(action: harness.newSession) {
      Label("新会话", systemImage: "plus")
    }
    .buttonStyle(.borderedProminent)
    .frame(maxWidth: .infinity)
  }

  private var workspaceSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("工作区")
          .font(.caption.weight(.bold))
          .foregroundStyle(.secondary)
        Spacer()
        Button(action: { harness.showSessionSearch = true }) {
          Image(systemName: "magnifyingglass")
        }
        .buttonStyle(.borderless)
      }
      Menu {
        ForEach(harness.hostWorkspaces) { ws in
          Button(action: { harness.selectWorkspace(ws) }) {
            if ws.path == harness.workspace?.path {
              Label(ws.title, systemImage: "checkmark")
            } else {
              Text(ws.title)
            }
          }
        }
        if !harness.hostWorkspaces.isEmpty {
          Divider()
        }
        Button("添加工作区…", action: harness.chooseWorkspace)
      } label: {
        Label(harness.workspaceName, systemImage: "folder")
          .lineLimit(1)
      }
      .help(harness.workspace?.path ?? "选择工作区")
    }
  }

  private var sessionSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("会话")
          .font(.caption.weight(.bold))
          .foregroundStyle(.secondary)
        Spacer()
        Button(action: harness.refreshHostSnapshots) {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        Text("\(harness.hostSessions.count > 0 ? harness.hostSessions.count : harness.sessions.count)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.top, 4)

      if harness.hostSessions.isEmpty && harness.sessions.isEmpty {
        emptySessionState
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 10) {
            if !harness.hostSessions.isEmpty {
              let groups = groupedHostSessions
              let showGroupHeaders = !(groups.count == 1 && groups[0].workspace == nil)
              ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 2) {
                  if showGroupHeaders {
                    Text(group.workspace?.title ?? "其他")
                      .font(.caption2.weight(.semibold))
                      .foregroundStyle(.tertiary)
                      .padding(.horizontal, 4)
                  }
                  ForEach(group.sessions) { session in
                    hostSessionRow(session)
                  }
                }
              }
            } else {
              ForEach(harness.sessions) { session in
                localSessionRow(session)
              }
            }
          }
        }
      }
    }
  }

  /// One row per host session-summary, bucketed by matching the session's own
  /// working directory (`DSHSessionSummary.cwd`) against each workspace's
  /// folder path. Not `DSHWorkspaceView.sessionIds` — checked against a real
  /// workspace.json on disk and found it empty even for a workspace with
  /// sessions under it, so the Host isn't maintaining that list in practice;
  /// cwd is populated per-session and is the reliable signal. Sessions whose
  /// cwd doesn't match any known workspace (e.g. created before this session
  /// ever chose one, or run at some other path) fall into a headerless "其他"
  /// bucket. If every session ends up in that one bucket, headers are skipped
  /// entirely and the list reads exactly as it did before grouping existed.
  private struct SessionGroup: Identifiable {
    let workspace: DSHWorkspaceView?
    let sessions: [DSHSessionSummary]
    var id: String { workspace?.workspaceId ?? "ungrouped" }
  }

  private var groupedHostSessions: [SessionGroup] {
    let sessions = harness.hostSessions.filter { $0.origin != "subagent" }
    var groups: [SessionGroup] = []
    var assigned = Set<String>()
    for ws in harness.hostWorkspaces {
      let matched = sessions.filter { $0.cwd == ws.path }
      guard !matched.isEmpty else { continue }
      groups.append(SessionGroup(workspace: ws, sessions: matched))
      assigned.formUnion(matched.map(\.sessionId))
    }
    let ungrouped = sessions.filter { !assigned.contains($0.sessionId) }
    if !ungrouped.isEmpty {
      groups.append(SessionGroup(workspace: nil, sessions: ungrouped))
    }
    return groups
  }

  private var emptySessionState: some View {
    VStack(spacing: 8) {
      Spacer()
      Image(systemName: "bubble.left")
        .font(.title)
        .foregroundStyle(.secondary)
      Text("还没有会话")
        .font(.caption)
        .foregroundStyle(.secondary)
      Button(action: harness.newSession) {
        Label("新会话", systemImage: "plus")
      }
      .buttonStyle(.bordered)
      Spacer()
    }
    .frame(maxWidth: .infinity)
  }

  private func hostSessionRow(_ session: DSHSessionSummary) -> some View {
    Button(action: { harness.openHostSession(session) }) {
      HStack(spacing: 8) {
        Image(systemName: "bubble.left")
          .font(.caption)
          .foregroundStyle(.secondary)
        Circle()
          .fill(session.running ? Color.blue : session.blank ? Color.clear : Color.green)
          .frame(width: 7, height: 7)
        VStack(alignment: .leading, spacing: 3) {
          Text(session.title)
            .lineLimit(1)
          Text(Date(timeIntervalSince1970: session.updatedAt / 1000), style: .relative)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(.vertical, 4)
      .padding(.horizontal, 4)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func localSessionRow(_ session: HarnessController.Session) -> some View {
    Button(action: { harness.selectSession(session.id) }) {
      HStack(spacing: 8) {
        Image(systemName: "bubble.left")
          .font(.caption)
          .foregroundStyle(.secondary)
        Circle()
          .fill(session.isRunning ? Color.blue : session.hasUnread ? Color.green : Color.clear)
          .frame(width: 7, height: 7)
        VStack(alignment: .leading, spacing: 3) {
          Text(session.title)
            .lineLimit(1)
          Text(session.updatedAt, style: .relative)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(.vertical, 4)
      .padding(.horizontal, 4)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
