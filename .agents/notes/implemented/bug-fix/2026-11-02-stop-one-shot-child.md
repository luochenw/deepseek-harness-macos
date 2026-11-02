# Agent Note: 停止按钮停不下一次性子会话，停止失败也没有任何提示

Status: implemented — 停止对所有运行中的子会话生效；停止失败、无法发出或 Host 仍在运行时，都写进对话

## Problem

用户反馈：「现在session 依旧无法终止」，随后又说「主会话就不能停止……现在按esc以及停止按钮都没反应，不能按」（2026-11-02）。

一，一次性子会话停不下来。打开一个一次性（one-shot）子会话时，它若在运行，输入框照样显示停止按钮，Esc 也照样被接住，因为两者看的都是子会话自己的运行状态。但 `stop()` 按 `displayedExecutionTarget` 分流，而一次性子会话在这里是 `.none`，所以按下停止既不发请求，也没有任何提示。仪表盘出于同样原因，只给可续聊（continuable）子会话显示停止按钮。

看上去的理由是 `subagents/interruptByParent` 的 `mode` 必须是 `"continuable"`。但打包的 Host（`dsh-subagent`）里，这个字段只是请求 schema 中写死的字面量；真正的中断调用 `manager.interrupt(child, {kind: "user", parentSessionId})`，不检查子会话类型。网页端对所有子会话地址都发 `interruptByParent`，而它的地址会带上真实类型，包括 `one-shot`。

二，停止的结果在主窗口里看不到。`stop()` 把“已请求取消”和“取消失败：原因”写进 `status`，但 `status` 只在设置页显示。所以 Host 拒绝、连接失败、没有可停的目标，在用户眼里都是“按了没反应”。

主会话停不下来这一点没有复现出来。用接了假模型的临时 Host 驱动真实控制器测过：模型输出中、`run_code` 执行中两种情况下，Stop 都在 250ms 内让这一轮结束、按钮复原，main（`54a3851`）和本分支结果相同。输入框获得焦点时按 Esc，在挂了真实 `ContentView` 的窗口里也能停。鼠标点击停止按钮在无界面进程里模拟不出来（对照的发送按钮也点不动），所以没有验证。

## Decision

- 停止有单独的目标 `displayedStopTarget`：只要打开的是子会话，不论类型都是 `.subagent(address)`；否则沿用 `displayedExecutionTarget`。
- `displayedExecutionTarget` 不变。它仍然决定能否发消息、输入框里按目标区分的控件和工作台上下文；在这些场景里，一次性子会话确实不是可操作的目标。
- `interruptSubagent(_:)` 和仪表盘的停止按钮不再要求 `mode == "continuable"`，只要求 `kind == "child"`。
- 停止不能完成的每种情况都写一条系统消息进对话：Host 未连接、会话还没连上 Host、取消请求失败（带原因）、子代理中断失败；请求被接受后，如果约 2.75 秒的轮询结束时这一轮还没确认结束，也写一条，并区分“Host 仍报告在运行”和“会话列表里没能确认”两种情况，免得把排查引向错的一边。

## Alternatives considered

- **让 `displayedExecutionTarget` 对一次性子会话也返回 `.subagent`**：不选。发消息和输入框控件会因此对 Host 拒绝续聊的子会话开放续聊，而 `subagents/prompt` 确实只接受可续聊子会话。
- **一次性子会话不显示停止按钮**：不选。子会话正在运行，Host 也能停下它，藏起按钮只是拿走了用户唯一的出口。
- **在主窗口加一条状态栏显示 `status`**：不选。这会改动界面的样子，需要先问用户；而停止失败是少见事件，写进对话已经足够，也会留在记录里。

## Consequences

- 停止一次性子会话会结束它这一轮；父会话里对应的工具调用以“已中断”返回，父会话继续往下走，和网页端一致。
- 停止成功时，对话里本来就会出现“本轮已中断”；现在失败时也有明确的一行。如果点了停止之后什么都没出现，说明点击或 Esc 根本没有走到 `stop()`，排查应转向输入层。
- 一轮停得慢（例如正在结束一个子进程）时，可能先看到“Host 仍显示这一轮在运行”，随后才出现“本轮已中断”。
- 测试：`macos/DSHTests/DSHSubagentProjectionTests.swift`（"Stop interrupts a one-shot child through its parent"），`macos/DSHTests/DSHPermissionAndSubmissionTests.swift`（"Stop reports a failure in the conversation"）。
