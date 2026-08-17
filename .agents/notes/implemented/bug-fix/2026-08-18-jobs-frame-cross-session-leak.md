# Agent Note: session/jobs 帧跨会话泄漏到当前转录

Status: implemented

## Problem

`events.mux` 是全会话聚合流（每帧带 `sessionId`）。[多会话并行](../feature/2026-08-17-per-session-run-state.md)那次已经给 `session/event`（按会话路由）、`session/projection` 和 `session/queue`（按当前会话过滤）加了隔离，但 `session/jobs` 漏了：`consumeMuxFrame` 把**任何**会话的 job 快照直接合并进 `activeTools`。

后果：后台会话（语音唤醒派发的任务、fork、子代理）注册后台 job 时，当前打开的对话的转录里会凭空多出别的会话的工具行。（`session/queue` 在那次改动中已修复，本次核对确认无遗漏。）

## Decision

给 `session/jobs` 补上与 `session/queue` 完全相同的守卫：帧带 `sessionId` 且不等于 `hostCurrentSessionID` 就丢弃。

子代理路径**刻意不**参与：核对过 `applyLiveSubagentEvent` 只往 `subagentTranscript` 追加文本消息和翻转运行标志，子代理转录不渲染工具/job 行；`activeTools` 的所有读点都在主转录。把子代理会话的 job 放进 `activeTools` 反而是往主转录里漏。

## Alternatives considered

- **严格守卫（`guard let sid …, sid == hostCurrentSessionID`，缺 sessionId 即丢弃）**——不选：与相邻 `session/queue` 的宽松写法不一致；协议上每帧必带 sessionId，两种写法行为等价，取一致性。
- **同时接受 `activeSubagentAddress.childSessionId` 的 job**——不选：见上，子代理转录不消费 `activeTools`，接受了就是反向泄漏。
- **按会话缓存各自的 jobs 表**——不选：后台会话不积累转录（见多会话并行 note 的取舍），切回时历史接口补齐，缓存无消费方。

## Consequences

- 后台会话的 job 不再污染当前转录的工具活动区；`session/queue`、`session/projection`、`session/jobs` 三类快照帧现在都按当前会话过滤，`session/event` 按会话路由——mux 消费全部有会话边界。
- 顺带排除了一个衍生错误面：泄漏的队列行如果被操作，`mutateQueue` 会拿 `hostCurrentSessionID` 发变更、打错会话（queue 守卫已在前次修复，本次 jobs 补齐后该入口彻底关闭）。
