import SwiftUI
import AppKit

struct Sidebar: View {
  @EnvironmentObject var harness: HarnessController
  @State private var collapsedSessionGroups: Set<String> = []
  @State private var expandedSessionGroups: Set<String> = []

  private var brandIcon: NSImage {
    if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
       let image = NSImage(contentsOf: url) {
      return image
    }
    return NSApp.applicationIconImage
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DSHSpace.s5) {
      HStack {
        HStack(spacing: DSHSpace.s2) {
          // Load the bundle resource directly. NSApp.applicationIconImage can
          // lag behind an in-place refresh and return a color-shifted cached
          // copy, which makes the brand mark disagree with DSHBrandPalette.
          Image(nsImage: brandIcon)
            .resizable().interpolation(.high).frame(width: 22, height: 22)
          Text("DeepSeek Harness")
            .font(DSHType.brand)
            .foregroundStyle(DSHTheme.ink)
        }
        Spacer()
      }
      // Room for the traffic lights, which float over the sidebar now that
      // the native title bar is hidden.
      .padding(.top, 26)
      Button(action: harness.newSession) { Label("新会话", systemImage: "plus").frame(maxWidth: .infinity) }.buttonStyle(.dshPrimary)
      Button(action: harness.showAgentManagement) {
        Label("Agent", systemImage: "person.3.sequence").frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.dshSecondary)

      // Workspace lives with the conversation now (WorkspaceChips above the
      // composer / in the header), not in the sidebar — single job: sessions.
      VStack(alignment: .leading, spacing: DSHSpace.s2) {
        HStack {
          Text("会话").dshSectionLabel()
          Spacer()
          Button(action: { harness.showSessionSearch = true }) { Image(systemName: "magnifyingglass") }.buttonStyle(.dshGhost)
          Button(action: harness.refreshHostSnapshots) { Image(systemName: "arrow.clockwise") }.buttonStyle(.dshGhost)
          Text("\(harness.hostSessions.count > 0 ? harness.hostSessions.count : harness.sessions.count)")
            .font(DSHType.micro)
            .foregroundStyle(DSHTheme.inkFaint)
        }
        if harness.hostSessions.isEmpty && harness.sessions.isEmpty {
          SidebarEmptySessionState()
        } else {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: DSHSpace.s4) {
              if !harness.hostSessions.isEmpty {
                let groups = harness.sessionGroups
                // Degrade to a flat list with no section labels when every
                // session landed in one bucket with no name to show — with
                // directory-derived fallback titles that's nearly never, so
                // the分类 headers stay visible regardless of registry churn.
                let showHeaders = !(groups.count == 1 && groups[0].workspace == nil && groups[0].fallbackTitle == nil)
                ForEach(groups) { group in
                  SidebarSessionGroupView(
                    group: group,
                    showsHeader: showHeaders,
                    collapsedGroups: $collapsedSessionGroups,
                    expandedGroups: $expandedSessionGroups)
                }
              } else {
                ForEach(harness.sessions) { session in SidebarLocalSessionRow(session: session) }
              }
            }
            .dshThinScrollers()
          }
        }
      }.frame(maxHeight: .infinity)

      VStack(alignment: .leading, spacing: 6) {
        Button(action: { harness.showSettings = true }) { Label("设置", systemImage: "gearshape") }.buttonStyle(.dshGhost)
        if let hostStatus = DSHSidebarHostStatus.visible(harness.hostStatus) {
          HStack(spacing: 6) {
            DSHStatusDot(kind: harness.hostClient == nil ? .idle : .live, diameter: 6)
            Text(hostStatus)
              .font(DSHType.micro)
              .foregroundStyle(DSHTheme.inkFaint)
              .lineLimit(2)
          }
        }
      }
    }
    .padding(DSHSpace.s4)
    .background(DSHTheme.sidebarBg)
  }
}

enum DSHSidebarHostStatus {
  private static let visibleMarkers = [
    "失败",
    "错误",
    "无法",
    "不匹配",
    "断裂",
  ]

  static func visible(_ status: String) -> String? {
    visibleMarkers.contains(where: status.contains) ? status : nil
  }
}

/// Shared chrome for a sidebar session row — both the Host-backed list and
/// the local fallback list render through this so their layout/selection
/// treatment can't drift apart.
private struct SidebarRowChrome: View {
  let title: String
  let date: Date
  let statusKind: DSHStatusDot.Kind
  let isActive: Bool
  let action: () -> Void
  /// Parent rows that float controls above this chrome (the ⋮ overlay)
  /// pass their own whole-row hover here — the overlay swallows pointer
  /// events, so the chrome's local onHover alone would drop the wash the
  /// moment the cursor reaches the button.
  var forceHover: Bool = false
  @State private var hovering = false
  private var hoverActive: Bool { hovering || forceHover }
  var body: some View {
    Button(action: action) {
      HStack(spacing: DSHSpace.s2) {
        if statusKind == .live {
          DSHRunningBars(
            color: isActive ? DSHTheme.sessionSelectedForeground : DSHTheme.accent,
            height: 11)
        } else if isActive {
          Circle()
            .fill(DSHTheme.sessionSelectedForeground)
            .frame(width: 7, height: 7)
        } else {
          DSHStatusDot(kind: statusKind)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(DSHType.body)
            .foregroundStyle(isActive ? DSHTheme.sessionSelectedForeground : DSHTheme.ink)
            .lineLimit(1)
          Text(Self.compactTime(date))
            .font(DSHType.caption)
            .foregroundStyle(
              isActive
                ? DSHTheme.sessionSelectedForeground.opacity(0.72)
                : DSHTheme.inkFaint)
        }
        Spacer(minLength: 0)
        if statusKind == .live {
          Text("运行中")
            .font(DSHType.micro)
            .foregroundStyle(
              isActive
                ? DSHTheme.sessionSelectedForeground.opacity(0.76)
                : DSHTheme.accent)
            .fixedSize()
        }
      }
      .padding(.horizontal, DSHSpace.s2).padding(.vertical, 7)
      .frame(maxWidth: .infinity, alignment: .leading)
      // contentShape makes the whole row hit-testable — a plain-style Button
      // only responds where content draws, so the trailing blank half of the
      // row was otherwise dead space.
      .contentShape(Rectangle())
      // Hover is structure feedback, not state — neutral wash; only the
      // selected row keeps the accent-tinted background.
      .background(
        isActive ? DSHTheme.sessionSelected : hoverActive ? DSHTheme.surfaceTint2 : .clear,
        in: RoundedRectangle(cornerRadius: DSHRadius.sm, style: .continuous))
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .animation(.easeOut(duration: 0.12), value: hoverActive)
  }
  /// Minute-granularity timestamp — `Text(_, style: .relative)` ticks with
  /// seconds, which reads as visual noise in a static list.
  private static func compactTime(_ date: Date) -> String {
    let interval = Date().timeIntervalSince(date)
    if interval < 60 { return "刚刚" }
    if interval < 3600 { return "\(Int(interval / 60)) 分钟前" }
    if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
    if Calendar.current.isDateInYesterday(date) { return "昨天 " + date.formatted(date: .omitted, time: .shortened) }
    return date.formatted(.dateTime.month().day())
  }
}

struct SidebarSessionRow: View {
  @EnvironmentObject var harness: HarnessController
  let session: DSHSessionSummary
  @State private var hovering = false
  var body: some View {
    // Host sessions carry no "seen/unread" flag (unlike the local fallback
    // `Session.hasUnread` below) — only the running state is real signal
    // here, so a finished session gets no dot rather than a misleading
    // `.unread` amber one.
    SidebarRowChrome(
      title: session.needsMigration ? "\(session.title) · 待升级" : session.title,
      date: Date(timeIntervalSince1970: session.updatedAt / 1000),
      statusKind: session.running ? .live : .idle,
      isActive: harness.hostCurrentSessionID == session.sessionId,
      action: { harness.openHostSession(session) },
      forceHover: hovering
    )
    // Hover-revealed ⋯ trigger; clicking opens an app-styled action panel
    // (popover with our own rows) rather than a system NSMenu, which can't
    // be themed. Right-click keeps a system context menu as a shortcut.
    .overlay(alignment: .trailing) {
      if hovering || showActions {
        Button(action: { showActions.toggle() }) {
          Image(systemName: "ellipsis")
            .rotationEffect(.degrees(90))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(DSHTheme.inkSoft)
            .frame(width: 24, height: 22)
            .background(DSHTheme.surface, in: RoundedRectangle(cornerRadius: DSHRadius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showActions, arrowEdge: .bottom) {
          SessionActionPanel(session: session) { showActions = false }
        }
        .padding(.trailing, 6)
      }
    }
    .onHover { hovering = $0 }
    .contextMenu { rowActions }
  }
  @State private var showActions = false
  @ViewBuilder private var rowActions: some View {
    Button("创建分支") { harness.forkSession(session.sessionId) }
    Button("复制会话 ID") { harness.copySessionID(session.sessionId) }
    Divider()
    Button("删除", role: .destructive) { harness.deleteSession(session.sessionId) }
  }
}

/// App-styled row-action panel for a sidebar session — same type scale,
/// hover treatment, and palette as the rest of the chrome.
private struct SessionActionPanel: View {
  @EnvironmentObject var harness: HarnessController
  let session: DSHSessionSummary
  let dismiss: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      PanelActionRow(icon: "arrow.triangle.branch", title: "创建分支") { dismiss(); harness.forkSession(session.sessionId) }
      PanelActionRow(icon: "doc.on.doc", title: "复制会话 ID") { dismiss(); harness.copySessionID(session.sessionId) }
      PanelActionRow(icon: "trash", title: "删除", destructive: true) { dismiss(); harness.deleteSession(session.sessionId) }
    }
    .padding(6)
    .frame(width: 172)
  }
}

private struct PanelActionRow: View {
  let icon: String
  let title: String
  var destructive = false
  let action: () -> Void
  @State private var hovering = false
  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: icon).font(.system(size: 11.5)).frame(width: 16)
        Text(title).font(DSHType.label)
        Spacer(minLength: 0)
      }
      .foregroundStyle(destructive ? DSHTheme.coral : DSHTheme.ink)
      .padding(.horizontal, 8).padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .background(hovering ? DSHTheme.sidebarSelected : .clear, in: RoundedRectangle(cornerRadius: DSHRadius.sm, style: .continuous))
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
  }
}

private struct SidebarLocalSessionRow: View {
  @EnvironmentObject var harness: HarnessController
  let session: HarnessController.Session
  var body: some View {
    SidebarRowChrome(
      title: session.title,
      date: session.updatedAt,
      statusKind: session.isRunning ? .live : session.hasUnread ? .unread : .idle,
      isActive: harness.selectedSessionID == session.id,
      action: { harness.selectSession(session.id) }
    )
  }
}

private struct SidebarEmptySessionState: View {
  var body: some View {
    VStack(spacing: DSHSpace.s2) {
      Image(systemName: "bubble.left").font(.title2).foregroundStyle(DSHTheme.inkFaint)
      Text("还没有会话").font(.caption).foregroundStyle(DSHTheme.inkFaint)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, DSHSpace.s6)
  }
}
