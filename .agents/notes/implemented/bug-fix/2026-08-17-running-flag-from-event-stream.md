# Agent Note: 运行标志从事件流置位（turn/start + 挂接快照）

Status: implemented

## Problem

全局运行标志 `isRunning` 只有本地 `send()` / `queueDraft()` 会置 true；事件流只处理 `turn/end`（清标志），从不置位。后果：重启 App 后挂接一个正在运行的会话、Host 自主开启的 turn（排队消息落地、goal 轮次推进、plan 确认）期间，UI 全程按"已结束"渲染——转录末尾显示静态落款而非运行动画（用户报告"执行过程的动画没了，变成静态了"），composer 也不给停止按钮。隔离帧对比测试证实动画机制（TimelineView + WaveIconArt）本身正常，问题纯粹是标志没亮。

## Decision

- `applyLiveEvent` 增加 `turn/start`：置全局与会话行的 `isRunning`，清 `runNotice`。上游 `dsh-agent-loop` 每轮模型回合都成对追加 `turn/start`/`turn/end`，以此为准绳，Host 自主开的 turn 一样点亮。
- 挂接会话（`attachHostSession` 建本地行）时把 host 快照的 `summary.running` 同步进全局 `isRunning`，不再只设会话行。
- 子代理转录事件镜像同样补 `turn/start` → `subagentTranscript?.isRunning = true`。

## Alternatives considered

- **只修挂接路径，不加 turn/start**——不选：排队消息驱动的新 turn、goal 轮次仍然全程"假结束"；turn/start 是 Host 权威信号，一处覆盖所有来源。
- **轮询 session.list 的 running 快照**——不选：已有实时事件流，轮询既慢又费；快照只用于挂接时的初值。

## Consequences

- 任何来源开启的 turn（本地发送、排队、goal 轮次、重启后续跑）动画与停止按钮一致点亮；`turn/end` 语义不变。
- 本地 send() 的先行置位保留——事件回来前 UI 不闪烁。
