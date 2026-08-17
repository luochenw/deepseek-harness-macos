# Agent Note: 多会话并行——运行态按会话隔离 + 侧栏实时标记

Status: implemented

## Problem

Host 端会话本就相互独立、可并行运行，但 App 的 UI 层把"运行中"当成了全局单例：

- `events.mux` 是全局复用流（每帧带 sessionId、覆盖所有会话），但 App 只消费当前会话/子代理/语音任务的帧，**其他会话的事件整帧丢弃**——后台会话的运行状态在 UI 里永远停在挂接那一刻。
- 新建对话（`clearToDefaultPage`）不清运行标志和会话级状态（用量条、todo、goal、队列），composer 在空白页上还显示上一个会话的停止按钮、发不出消息（`guard !isRunning`）——"新建对话，输入框还是上一个 session 的状态"。
- 切回已打开的会话（`openHostSession` 的早退分支）不同步任何会话级状态，显示的仍是上一个会话的数据。
- 侧栏行的 `.live` 状态点读快照 `summary.running`，只有手动刷新才变——"看不到每个 session 进行中的标记"。
- 本地行与 Host 会话靠 title+workspace 匹配，重名/改名即错乱。

## Decision

- `Session` 本地行增加 `hostSessionId`，挂接/打开时写入；`openHostSession` 匹配优先用 host id，title 匹配只作为无 id 行的回退。
- `consumeMuxFrame` 的 `session/event` 在按当前会话分流**之前**，先对 `turn/start`/`turn/end` 做全量路由：更新 `hostSessions`（侧栏 `.live` 点即刻变化，`running` 字段改 `var`）；非当前会话同时更新对应本地行的 `isRunning`，turn 结束标 `hasUnread`。当前会话仍走原有完整路径（含全局标志）。
- 会话级全局状态（运行标志、todos、goal、用量条、队列、通知条）收进 `syncSessionScopedState(from:rowRunning:)`，`openHostSession` 两个分支都调用；`clearToDefaultPage` 全部清零——空白新对话就是干净的空白。
- `session/queue` 帧按 sessionId 过滤到当前会话，不再让别的会话的队列推送覆盖本会话队列。
- 草稿文本刻意**不**按会话隔离：切换会话保留未发送的输入，避免误丢；被复制到多个会话的场景可接受。

## Alternatives considered

- **全套状态按会话建模**（每行携带 todos/goal/用量等，全局只留 selectedIndex）——不选：正确但侵入面大（几十处读点），当前"切换时重同步 + 事件按会话路由"以小改动覆盖同样的用户可见行为；将来若做会话平铺多窗格再升级。
- **后台会话也全量消费事件（转录、工具行）**——不选：内存与 CPU 随会话数线性上涨，后台会话看不见转录，回来时 `loadHistory` 本来就会补齐；只路由 turn 边界（运行标记）+ 未读标记是最小充分集。
- **侧栏点靠轮询 session.list**——不选：mux 流就在手上，事件驱动零成本且即时。

## Consequences

- 一个会话运行中可以新建对话/切到其他会话并直接发送，互不阻塞；每个会话的停止按钮、动画、末尾落款只反映自己。
- 侧栏所有会话行的绿点实时反映运行状态；后台跑完的会话标未读。
- 后台会话运行期间不积累转录，切回时由历史接口补齐（既有行为）。
