import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var harness: HarnessController
  var body: some View {
    GeometryReader { geometry in
      let layout = DSHMainWindowLayout.resolve(totalWidth: geometry.size.width)
      HStack(spacing: 0) {
        Sidebar().frame(width: layout.sidebarWidth)
        ConversationWorkbenchLayout(compact: layout.compact)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    // 果冻海：窗口底是一整片海水渐变，上面的侧栏/卡片全是半透明薄层，
    // 让海水透出来 — 见 2026-08-17-jelly-sea-theme.md
    .background(DSHTheme.canvasGradient)
    // 设置编辑器/自定义配置抽屉只从设置页打开，挂在 SettingsView 自己
    // 身上（sheet 套 sheet）——挂这里会跟设置 sheet 抢同一个挂载点，
    // 设置开着时编辑抽屉永远弹不出来。
    .sheet(isPresented: $harness.showSettings) { SettingsView() }
    .sheet(isPresented: $harness.showSessionSearch) { SessionSearchView() }
    .sheet(isPresented: $harness.showSubagentTree) { SubagentTreeView() }
    .sheet(isPresented: $harness.showRenameSession) { RenameSessionSheet() }
    .sheet(isPresented: $harness.showArchivedSessions) { ArchivedSessionsView() }
    .sheet(isPresented: $harness.showAgentProfileEditor) {
      AgentProfileEditorSheet(profile: harness.editingAgentProfile)
    }
    .sheet(item: $harness.manualAgentProfile) { profile in
      AgentManualRunSheet(profile: profile)
    }
    .sheet(item: $harness.pendingApproval) { approval in ApprovalSheet(approval: approval) }
    .sheet(item: $harness.pendingQuestion) { question in QuestionBatchSheet(question: question) }
  }
}
