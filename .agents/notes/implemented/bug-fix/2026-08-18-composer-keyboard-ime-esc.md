# Agent Note: Composer keyboard — Enter 在输入法组合中误发送，Esc 不能停止对话

Status: implemented

## Problem

原生 Composer（macOS/DSHApp/ComposerView.swift）的 TextEditor 键盘处理有两个问题：

1. **输入法组合中按回车直接发送。** 输入框用
   `.onKeyPress(.return, phases: .down)` 拦截回车来"回车发送"。SwiftUI 的这个
   modifier 在文本输入管道拿到按键之前就会触发，因此当输入法（拼音等）正在组合
   未确认候选（marked text）时，用户按回车想确认候选，事件已经先被
   `.onKeyPress` 吃掉并直接 `submitComposer()` 发送了草稿——用户还没输完。
   组合中的 marked text 又不会进入 `harness.draft`（见 Composer 里 placeholder
   的注释），所以无法用草稿状态判断。

2. **Esc 不能停止正在进行的对话。** `.onKeyPress(.escape)` 只处理 slash 面板
   和 @ 提及面板的关闭；agent 正在运行（`harness.isRunning`）时按 Esc 什么也
   不做。停止只能靠点击输入框旁的停止按钮。

## Decision

在 `Composer` 的按键处理里加了两处守卫：

1. 回车发送前先判断当前焦点文本框是否处于 IME 组合态：通过
   `NSApp.keyWindow?.firstResponder as? NSTextView` 取到焦点文本框，若
   `hasMarkedText()` 为 true 则 `.ignored`，让回车落回文本输入系统去确认候选，
   不发送。`.ignored` 保证事件继续向下传递，不会破坏 Shift+回车换行等路径。
   判定抽成 `editorHasMarkedText` 私有计算属性，随文件加了 `import AppKit`。

2. Esc 处理在（a）提及面板、（b）slash 面板之后追加：若文本框仍处于 IME
   组合态则 `.ignored`，交给输入法取消候选；否则若
   `harness.displayedIsRunning` 则 `harness.stop()` 并 `.handled`。面板优先
   的语义保持不变——先关弹层，再按 Esc 才停止。

## Alternatives considered

- **用 NSEvent 全局事件监视器监听 Esc 停止。** 放弃——作用域过宽，会抢走其他
  控件/对话框里的 Esc，且需要一个生命周期管理（onAppear/onDisappear）和一个
  状态位；composer 级别的 `.onKeyPress` 与停止按钮的作用域一致，更安全。
- **用 `press.characters` 或 keyCode 判断 IME。** 放弃——不同输入法对回车
  键的 characters/keyCode 表现不一致，不如直接查文本框的 marked text 可靠。
- **改用 `.onSubmit` 触发发送。** 放弃——`.onSubmit` 在 macOS TextEditor
  上同样在回车时触发，遇到同样的 IME 问题，而且没法干净地拦截 Shift+回车
  换行和面板选中项执行。
- **用 NSTextInputContext 的 markedTextDidChange 通知维护组合态标志。**
  放弃——引入额外状态和订阅生命周期；在按键同步时刻查 `hasMarkedText()`
  已经覆盖"回车确认候选"这个时点。

## Consequences

- 中文输入法组合中按回车：只确认候选，不发送草稿；确认后再按回车正常发送。
- agent 运行中在输入框按 Esc：停止当前对话；IME 组合中则仍由输入法处理。
- 面板打开时 Esc 仍先关面板；Shift+回车仍换行；`AppPrefs.enterToSend` 关闭时
  `⌘回车` 仍发送。
- `./scripts/test-macos-native.sh` 类型检查、`./scripts/build-macos-app.sh`
  构建、`--smoke` 冒烟均通过。
