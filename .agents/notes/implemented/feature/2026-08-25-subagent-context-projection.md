# Agent Note: 子代理上下文投影

Status: implemented — 子代理转录显示独立投影，并拒绝过期导航与历史结果

## Problem

子代理转录已经能作为根会话之上的独立覆盖层显示历史和实时文本，但右侧
Dashboard 与 GoalBar 仍然读取根会话的 `activeTools`、`todos` 和 `goal`。
因此用户打开一个正在执行工具、维护 Todo 或推进目标的子代理时，看到的是
父会话的工具、任务和目标，转录内容与辅助信息不一致。

当前实现还有一个状态污染问题：`loadSubagentTranscript` 调用
`foldHistory`，后者会将折叠出的工具数组写入根会话的 `activeTools`。打开
子代理历史可能因此改写根会话的工具状态；而实时子代理事件又只折叠消息，
有意忽略工具、Todo 和 Goal。

上游 rc.7 `subagent.history` 返回与 `session.history` 相同的尾页
`projections` 基线，mux 会为所有会话广播带 `sessionId` 和 `seq` 的
`session/projection` 帧。因此该信息不需要猜测协议或引入新的 Host API。

## Decision

`DSHSubagentProjection.swift` 定义按 child session ID 隔离的
`DSHSubagentPresentationContext`：

- 结构化工具活动；
- Todo 列表；
- Goal 投影；
- Plan 与 queue 投影；
- 每个 projection key 的最后应用序号。

状态由功能域内的注册表懒创建并以弱引用关联 `HarnessController`。它不是
第二个 `ObservableObject`：每次上下文发生变化时只转发
`HarnessController.objectWillChange`，保持现有环境对象和 `main.swift`
冻结约束不变。

`subagent.history` 的 `projections` 作为 child context 的初始快照；
其 `asOfSeq` 建立每个 key 的基线。后续 `session/projection` 只在序号不
早于已保存值时更新。根会话继续由既有 `activeTools`、`todos` 和 `goal`
驱动，绝不被 child 历史或 child mux 帧覆盖。

`displayedTools`、`displayedTodos`、`displayedGoal`、
`displayedPlanActive` 和 `displayedQueueItems` 是唯一供 Dashboard、
转录工具行、GoalBar、Composer 和 QueueDock 使用的显示选择器。子代理
Goal、plan 和 queue 是只读投影：上游 Goals API 规定 session-backed
subagent mutation 会以 `agent-busy` 拒绝，因此只有根会话显示可变更操作。

加载中的 child mux events/jobs 会缓冲，history baseline 生效后只重放更高
序号的 event。child navigation、child catalog 与工作流成员跳转均有代际
校验；根会话 history 也绑定 `(sessionID, localSessionID, generation)`，
只会在该根会话仍是当前显示上下文时更新工具与分页状态。子代理不会再展示
或执行根会话的 Slash catalog、`/goal`、`/plan`、`/export` 或 `/model`。
continuable child 的普通追问和停止仍分别路由为 `subagent.prompt` 与
`subagent.interrupt`。

## Alternatives considered

- **在 `main.swift` 直接增加 child context 的 `@Published` 字典。**
  拒绝：违反被冻结的文件边界，也会扩大 `HarnessController` 已经很大的
  存储状态面。
- **打开子代理时暂存根状态，再复用 `activeTools` / `todos` / `goal`。**
  拒绝：根会话和子代理可同时收到 mux 帧；单一可变槽会重新引入状态覆盖
  和事件错路由。
- **只在每次切换子代理时重新请求 history，不消费实时 projection。**
  拒绝：子代理运行期间 Dashboard 会过期，且上游已经提供序号化实时投影。
- **把工作流卡片也改为 child-scoped。**
  拒绝：当前 Host 事件的工作流关联仍按根会话建模；先只实现有明确 session
  投影和事件归属的工具、Todo、Goal。
- **把 Goal mutation 路由到 continuable child。** 拒绝：rc.7 Goals API
  明确规定 session-backed subagent mutation 以 `agent-busy` 拒绝；展示
  child Goal 状态不等于它拥有独立的可变 Goal 控制面。

## Consequences

- `subagent.history` 的 projection block 是可选能力；缺失时 child UI
  保持空状态，不展示根会话或过期 child 状态。
- child context 的注册表只为实际打开过的 child 创建记录，并在后续访问时
  清除已释放 controller 的弱引用条目。
- `subagent.history` 仍只加载最近 100 条消息；分页能力保留为后续 parity
  工作。
- `session/queue` 和 `session/jobs` 快照目前不携带可比较序号，因此无法像
  projection/event 一样防御晚到的旧快照；Host 单 mux 的顺序保证是当前
  前提，显式快照版本化仍是后续改进项。
- Verification on August 26, 2026: `./scripts/test-macos-native.sh` passed
  child-context source contracts; `./scripts/test-macos-native.sh --unit`
  passed 72/72 Swift tests; `./scripts/test-agent-platform-runtime-script.sh`
  passed; `./scripts/test-agent-platform-runtime.sh` passed 91 Node tests;
  the app built with DSH `0.1.0-rc.7`; packaged Host smoke passed; and
  `git diff --check` passed.
