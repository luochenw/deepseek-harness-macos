# Agent Note: 侧栏按协议隐藏已归档会话

Status: implemented — 归档不再"看起来像没删掉"

## Problem

`session.list` 按协议返回**每一个持久化会话**（summary schema 根本没有
archived 字段）；归档集合单独存在于 workspace registry
（`workspace.list` 的 `archivedSessionIds`，变更走
`host/archived-sessions-changed` 事件）。上游契约（workspace.d.ts）：
"Archived sessions stay in their workspace's sessionIds account; **grouping
surfaces hide them**" —— 隐藏是列表面板的职责。

macOS App 的 `refreshHostSnapshots()` 直接 `hostSessions = session.list`，
从不减去归档集合。于是用户把所有会话归档后，侧栏刷新时它们全部原样回来——
看起来"删除完全没生效"。（归档本身是成功的：workspace.json 里 35 个
archivedSessionIds 都在。）

## Decision

`refreshHostSnapshots()` 改为拉完整 `workspace.list` 快照（原本就有
`workspaceSnapshot()` 包装），用 `archivedSessionIds` 过滤 `session.list`
结果再赋给 `hostSessions`。既有的 `host/archived-sessions-changed` →
`refreshHostSnapshots()` 事件链不变，归档操作现在会实时从侧栏消失。
归档视图（`loadArchivedSessions`）逻辑不受影响，仍列归档集合。

## Alternatives considered

- **让 Host 的 session.list 排除归档**：协议明确把隐藏定为 grouping surface
  的职责（web 端也是客户端过滤）；改 Host 语义会破坏"归档视图需要 join
  session.list 元数据"的用法。
- **在 `workspaceSessionGroups` 计算属性里过滤**：也可行，但 `hostSessions`
  还被搜索、状态栏计数等处直接消费，源头过滤一次即可全局一致。

## Consequences

- 归档会话即时从侧栏与计数中消失，仅在「查看归档会话」里可见。
- 协议未提供 unarchive 与物理删除；"彻底删除"目前只能手动清理
  App home（`~/Library/Application Support/DeepSeek Harness/dsh/sessions/`）
  的对应目录并同步 registry——未提供 UI，属有意范围外。
