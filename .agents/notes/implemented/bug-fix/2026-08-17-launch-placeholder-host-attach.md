# Agent Note: 启动占位会话在 Host 连接后自动接入

Status: implemented — 首屏"新会话"不再永远"Host 未连接"

## Problem

`HarnessController.init()` 先调 `newSession()` 再调 `startPersistentHost()`。
`newSession()` 里 `guard let hostClient else { return }` —— 启动时 hostClient
必然还是 nil，所以首屏占位会话永远没有对应的 Host 会话；Host 连上之后也没有
任何补建逻辑。结果：每次打开 App，在默认会话里发送必报
「Host 未连接，无法发送；请点击重新连接后再试」，除非用户手动 ⌘N 再建一个。

## Decision

把 `newSession()` 的"创建 Host 会话 + 推送所选模型 + 回读"的后半段抽成
`attachHostSessionToCurrentPlaceholder()`；`startPersistentHost` 的连接成功
回调在 `hostCurrentSessionID == nil` 时调用它，给启动占位会话补建 Host 会话。

## Alternatives considered

- **把 init 里的 `newSession()` 挪到连接回调之后**：启动窗口会先呈现"没有任何
  会话"的空态，视觉上像坏了；占位先出现、连接后接入的现状体验更平滑。
- **send() 里发现无会话时现场创建**：把生命周期修补藏进发送路径，发送第一条
  消息要先等 create+selectModel 两个 RPC，失败语义也混进发送错误里，不如在
  连接点一次性补建清晰。

## Consequences

- 冷启动后首屏会话在 Host 连接完成的瞬间变为可发送，无需 ⌘N。
- 连接回调触发时目录可能未加载，此时模型推送按"无宣告 effort"处理（省略
  字段），随后的 `refreshSessionModels()` 会与 Host 对齐。
