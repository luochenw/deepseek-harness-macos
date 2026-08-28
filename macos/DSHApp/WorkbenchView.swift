import AppKit
import SwiftUI

struct DSHMainWindowLayout: Equatable {
  static let defaultWidth: CGFloat = 1180
  static let defaultHeight: CGFloat = 760
  static let minimumWidth: CGFloat = 1000
  static let minimumHeight: CGFloat = 680
  static let compactThreshold: CGFloat = 1180
  static let regularSidebarWidth: CGFloat = 290
  static let compactSidebarWidth: CGFloat = 260

  let sidebarWidth: CGFloat
  let compact: Bool

  static func resolve(totalWidth: CGFloat) -> Self {
    let compact = totalWidth < compactThreshold
    return Self(
      sidebarWidth: compact ? compactSidebarWidth : regularSidebarWidth,
      compact: compact)
  }
}

struct DSHWorkbenchSplitLayout: Equatable {
  static let resizeHandleWidth: CGFloat = 7
  static let regularConversationMinimum: CGFloat = 500
  static let compactConversationMinimum: CGFloat = 420
  static let regularWorkbenchMinimum: CGFloat = 360
  static let compactWorkbenchMinimum: CGFloat = 300
  static let workbenchMaximum: CGFloat = 900

  let conversationWidth: CGFloat
  let workbenchWidth: CGFloat?
  let maximumWorkbenchWidth: CGFloat
  let minimumWorkbenchWidth: CGFloat

  static func resolve(
    availableWidth: CGFloat,
    compact: Bool,
    workbenchVisible: Bool,
    preferredWorkbenchWidth: CGFloat
  ) -> Self {
    let conversationMinimum = compact
      ? compactConversationMinimum
      : regularConversationMinimum
    let workbenchMinimum = compact
      ? compactWorkbenchMinimum
      : regularWorkbenchMinimum
    let required = conversationMinimum + resizeHandleWidth + workbenchMinimum
    guard workbenchVisible, availableWidth >= required else {
      return Self(
        conversationWidth: max(0, availableWidth),
        workbenchWidth: nil,
        maximumWorkbenchWidth: 0,
        minimumWorkbenchWidth: workbenchMinimum)
    }
    let maximumWorkbenchWidth = min(
      workbenchMaximum,
      availableWidth - conversationMinimum - resizeHandleWidth)
    let workbenchWidth = min(
      maximumWorkbenchWidth,
      max(workbenchMinimum, preferredWorkbenchWidth))
    return Self(
      conversationWidth: max(
        conversationMinimum,
        availableWidth - resizeHandleWidth - workbenchWidth),
      workbenchWidth: workbenchWidth,
      maximumWorkbenchWidth: maximumWorkbenchWidth,
      minimumWorkbenchWidth: workbenchMinimum)
  }
}

struct ConversationWorkbenchLayout: View {
  @EnvironmentObject private var harness: HarnessController
  @AppStorage("dsh.workbench.width") private var storedWidth = 520.0
  @State private var dragOrigin: CGFloat?
  var compact = false

  var body: some View {
    GeometryReader { geometry in
      let layout = DSHWorkbenchSplitLayout.resolve(
        availableWidth: geometry.size.width,
        compact: compact,
        workbenchVisible: harness.showDetails,
        preferredWorkbenchWidth: storedWidth)
      HStack(spacing: 0) {
        VStack(spacing: 0) {
          ConversationHeader()
          ConversationView().frame(maxWidth: .infinity, maxHeight: .infinity)
          Composer(compactControls: DSHComposerLayout.usesStackedControls(
            availableWidth: layout.conversationWidth))
        }
        .frame(width: layout.conversationWidth)
        .frame(maxHeight: .infinity)
        .clipped()

        if let workbenchWidth = layout.workbenchWidth {
          WorkbenchResizeHandle()
            .gesture(DragGesture(minimumDistance: 0)
              .onChanged { value in
                let origin = dragOrigin ?? workbenchWidth
                if dragOrigin == nil { dragOrigin = origin }
                storedWidth = min(
                  layout.maximumWorkbenchWidth,
                  max(layout.minimumWorkbenchWidth, origin - value.translation.width))
              }
              .onEnded { _ in dragOrigin = nil })
          WorkbenchView()
            .frame(width: workbenchWidth)
            .transition(.opacity)
        }
      }
    }
  }
}

private struct WorkbenchResizeHandle: View {
  @State private var hovering = false

  var body: some View {
    Rectangle()
      .fill(hovering ? DSHTheme.accentSoft : Color.clear)
      .frame(width: 7)
      .overlay {
        Capsule()
          .fill(hovering ? DSHTheme.accent : DSHTheme.fieldStroke)
          .frame(width: hovering ? 2 : 1, height: 44)
      }
      .contentShape(Rectangle())
      .onHover { active in
        hovering = active
        (active ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
      }
      .onDisappear { NSCursor.arrow.set() }
      .accessibilityLabel("调整工作台宽度")
  }
}

struct WorkbenchView: View {
  @EnvironmentObject private var harness: HarnessController

  var body: some View {
    VStack(spacing: 0) {
      WorkbenchTabBar()
      if let selected = harness.selectedWorkbenchTab {
        WorkbenchTabContent(tab: selected)
      } else {
        WorkbenchEmptyState()
      }
    }
    .background(DSHTheme.surfaceTint)
    .clipShape(RoundedRectangle(cornerRadius: DSHRadius.lg, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: DSHRadius.lg, style: .continuous)
        .strokeBorder(DSHTheme.fieldStroke.opacity(0.65), lineWidth: 1)
    }
    .padding(.vertical, DSHSpace.s2)
    .padding(.trailing, DSHSpace.s2)
  }
}

private struct WorkbenchTabBar: View {
  @EnvironmentObject private var harness: HarnessController

  var body: some View {
    HStack(spacing: DSHSpace.s1) {
      ScrollView(.horizontal) {
        HStack(spacing: DSHSpace.s1) {
          ForEach(harness.workbenchTabs) { tab in WorkbenchTabItem(tab: tab) }
        }
        .padding(.horizontal, DSHSpace.s1)
      }
      .scrollIndicators(.hidden)

      Menu {
        Button("新建浏览器") { harness.newBrowserWorkbench() }
        Button("打开 Markdown…", action: harness.chooseMarkdownWorkbench)
        Divider()
        Button("执行") { harness.openExecutionWorkbench() }
        Button("Agent", action: harness.openAgentsWorkbench)
      } label: {
        Image(systemName: "plus").frame(width: 24, height: 24)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .help("新建工作台标签")
      .accessibilityLabel("新建工作台标签")

      Menu {
        ForEach(harness.workbenchTabs) { tab in
          Button(action: { harness.selectWorkbenchTab(tab.id) }) {
            Label(tab.title, systemImage: tab.systemImage)
          }
        }
      } label: {
        Image(systemName: "list.bullet").frame(width: 24, height: 24)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .disabled(harness.workbenchTabs.isEmpty)
      .help("全部标签")
      .accessibilityLabel("全部标签")

      Button(action: {
        harness.showDetails = false
        harness.pauseWorkbenchMedia()
      }) {
        Image(systemName: "sidebar.right").frame(width: 24, height: 24)
      }
      .buttonStyle(.dshGhost)
      .help("收起工作台")
      .accessibilityLabel("收起工作台")
    }
    .padding(.horizontal, DSHSpace.s2)
    .frame(height: 42)
    .background(DSHTheme.surface)
    .overlay(alignment: .bottom) { Rectangle().fill(DSHTheme.fieldStroke.opacity(0.55)).frame(height: 1) }
  }
}

private struct WorkbenchTabItem: View {
  @EnvironmentObject private var harness: HarnessController
  let tab: DSHWorkbenchTab
  @State private var hovering = false

  private var selected: Bool { harness.selectedWorkbenchTab?.id == tab.id }

  var body: some View {
    HStack(spacing: 6) {
      Button(action: { harness.selectWorkbenchTab(tab.id) }) {
        HStack(spacing: 6) {
          Image(systemName: tab.systemImage).font(.system(size: 11))
          Text(tab.title).font(.system(size: 11.5, weight: selected ? .medium : .regular)).lineLimit(1)
          if tab.preview { Image(systemName: "circle.dashed").font(.system(size: 8)) }
        }
        .foregroundStyle(selected ? DSHTheme.ink : DSHTheme.inkSoft)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      Button(action: { harness.closeWorkbenchTab(tab.id) }) {
        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 16, height: 16)
      }
      .buttonStyle(.plain)
      .foregroundStyle(DSHTheme.inkFaint)
      .opacity(hovering || selected ? 1 : 0)
      .allowsHitTesting(hovering || selected)
      .accessibilityHidden(!(hovering || selected))
      .help("关闭标签")
    }
    .padding(.leading, DSHSpace.s2)
    .padding(.trailing, DSHSpace.s1)
    .frame(minWidth: 96, maxWidth: 190, minHeight: 30)
    .background(
      selected ? DSHTheme.sidebarSelected : hovering ? DSHTheme.surfaceTint2 : .clear,
      in: RoundedRectangle(cornerRadius: DSHRadius.sm, style: .continuous))
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .accessibilityLabel(tab.title)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

private struct WorkbenchTabContent: View {
  @EnvironmentObject private var harness: HarnessController
  let tab: DSHWorkbenchTab

  var body: some View {
    switch tab.kind {
    case .execution:
      AgentPlatformExecutionView()
        .padding(DSHSpace.s4)
    case .agents:
      AgentPlatformProfilesView()
        .padding(DSHSpace.s4)
    case .tool:
      WorkbenchToolDetail(tab: tab)
    case .browser:
      NativeBrowserTabView(tabID: tab.id)
    case .markdown:
      NativeMarkdownDocumentView(tabID: tab.id)
    }
  }
}

private struct WorkbenchToolDetail: View {
  @EnvironmentObject private var harness: HarnessController
  let tab: DSHWorkbenchTab

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: DSHSpace.s2) {
        Image(systemName: "wrench.and.screwdriver").foregroundStyle(DSHTheme.inkSoft)
        Text(tab.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DSHTheme.ink).lineLimit(1)
        Spacer()
        if tab.preview {
          Button(action: { harness.pinWorkbenchTab(tab.id) }) { Image(systemName: "pin") }
            .buttonStyle(.dshGhost).help("固定标签")
        }
      }
      .padding(.horizontal, DSHSpace.s4)
      .frame(height: 42)
      .background(DSHTheme.surface)

      if let tool = harness.toolActivity(for: tab) {
        ScrollView {
          VStack(alignment: .leading, spacing: DSHSpace.s3) {
            NativeDashboard()
            NativeToolPresentationView(tool: tool)
          }
          .padding(DSHSpace.s4)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .dshThinScrollers()
      } else {
        VStack(spacing: DSHSpace.s2) {
          Image(systemName: "wrench.and.screwdriver").font(.title2).foregroundStyle(DSHTheme.inkFaint)
          Text("工具详情不可用").font(.headline).foregroundStyle(DSHTheme.ink)
          Text("该工具调用已不在当前会话快照中。").font(.caption).foregroundStyle(DSHTheme.inkFaint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }
}

private struct WorkbenchEmptyState: View {
  @EnvironmentObject private var harness: HarnessController

  var body: some View {
    VStack(spacing: DSHSpace.s3) {
      Image(systemName: "rectangle.split.3x1").font(.title2).foregroundStyle(DSHTheme.inkFaint)
      HStack(spacing: DSHSpace.s2) {
        Button(action: { harness.newBrowserWorkbench() }) { Label("浏览器", systemImage: "globe") }.buttonStyle(.dshSecondary)
        Button(action: harness.chooseMarkdownWorkbench) { Label("打开 Markdown", systemImage: "doc.richtext") }.buttonStyle(.dshSecondary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
