import SwiftUI

struct WorkbenchCommands: Commands {
  let controller: HarnessController

  var body: some Commands {
    CommandMenu("工作台") {
      Button("显示或隐藏工作台") { controller.toggleWorkbench() }
        .keyboardShortcut("b", modifiers: [.command, .option])
      Button("新建浏览器标签") { controller.newBrowserWorkbench() }
        .keyboardShortcut("b", modifiers: [.command, .shift])
      Button("打开 Markdown…") { controller.chooseMarkdownWorkbench() }
        .keyboardShortcut("m", modifiers: [.command, .shift])
      Button("聚焦浏览器地址栏") { controller.focusWorkbenchBrowserAddress() }
        .keyboardShortcut("l", modifiers: .command)
      Divider()
      Button("上一个工作台标签") { controller.selectNeighborWorkbenchTab(offset: -1) }
        .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
      Button("下一个工作台标签") { controller.selectNeighborWorkbenchTab(offset: 1) }
        .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
    }
  }
}
