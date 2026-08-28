# Agent Note: 会话轨迹窗口化

Status: implemented — 长会话按上下文维护 240 条消息的滑动渲染窗口

## Problem

`ConversationView` 目前将当前会话的全部 `messages` 传给
`LazyVStack`。虽然 SwiftUI 会惰性创建屏外 View，但每次 body 重算仍会折叠
整段转录，并保留完整的逻辑视图树输入。长会话中的工具行、推理块、图片和
Markdown 会使布局、身份 diff 和滚动锚点成本持续增长。

现有上滚加载历史功能会把更早消息直接 prepend 到 `messages`；现有底部跟随
逻辑则基于 `"transcript-tail"`。窗口化不能破坏这两个行为，也不能让流式
助手、压缩摘要、重试提示或子代理覆盖层丢失。

## Decision

新增 `DSHConversationWindow.swift`，维护每个显示上下文的一段连续 message
range。上下文 key 使用 top-level local session UUID 或当前 child session ID
并带命名空间前缀，避免两类 session ID 碰撞。状态不保存消息副本，只保存：

- 当前 range；
- 最近一次渲染恢复所需的稳定 message UUID；
- 用于调试的可见 item 数、message range 和逻辑总数。

纯 `DSHConversationWindowPlanner` 决定 range：

- 初始/底部跟随：尾部最多 240 条 message；
- 向上或向下靠近区间边缘：每次平移 120 条，同时保持 240 条上限；
- 用户在底部时新的 message 到来：窗口整体滑到新的尾部，仍保持 240 条
  上限；
- 用户不在底部时新 message 到来：保持现有 range，不强制阅读位置跳到新
  内容；
- prepend 更早历史：平移窗口前缘，并记录原 first visible message
  UUID；SwiftUI 更新后 scroll reader 将该 UUID 重新定位到顶部，确保阅读
  位置不跳。

`ConversationView` 只将 window slice 传入既有 transcript folding。顶部和
底部的透明 sentinel 通过 `onAppear` 请求平移到相邻窗口；它们不携带可见文本，
不改变对话语义。根会话的既有“加载更早消息”按钮仍在窗口顶部，并在请求
结束后将新增历史纳入前缘。

工具组仍在 slice 内折叠。一个连续工具组恰好横跨窗口边界时可能暂时分成两
组；这是有界物化的明确取舍，优先保证内存和布局上界。下一次扩展会自然恢复
完整组，不制造或丢失任何 message。

## Alternatives considered

- **只依赖 `LazyVStack`。** 拒绝：它只延迟 child View 创建，不为折叠、
  输入列表和持续增长的 identity/diff 工作建立可测上界。
- **把完整历史从 `sessions[].messages` 移到分页磁盘缓存。** 拒绝：改变
  事件折叠、发送回显和子代理覆盖层的所有权，远超展示层窗口化所需范围。
- **按像素高度而不是 message count 维护窗口。** 拒绝：Markdown、图片和
  展开的工具卡高度不稳定，先以确定性的 message count 建立可验证边界；用户
  阅读时的边缘 sentinel 再补足实际可见需求。
- **让窗口只扩张、不回收远端内容。** 拒绝：长时间浏览后会重新物化整段
  历史，失去白屏修复所需的严格上界。实现使用 120 条重叠区间和稳定消息
  UUID 恢复锚点，移动窗口时仍保持阅读位置。

## Consequences

- 当前转录一次最多物化 240 条 message；底部流式新增和上下边缘浏览都保持
  该上限。
- 根会话与每个子代理分别保存窗口位置；切换上下文不会串用 range。
- 前后平移与 Host 历史 prepend 都通过稳定 message UUID 恢复顶部或底部
  锚点，用户阅读位置不会跳到另一段内容。
- `ConversationView` 的更新触发从整段 messages 数组比较改成轻量 token；
  流式未完成正文使用纯文本，结算后再进入 Markdown 渲染。
- 工具组跨窗口边界时可能暂时分成两组；消息没有丢失，滑到相邻窗口后恢复。
- 单元测试覆盖初始、边缘平移、尾部跟随、prepend 和 context 隔离；真实
  SwiftUI 门禁以 2,000 条混合消息渲染并验证非空画面与 240 条上限。
