# Agent Note: 支持显式选择无工作区

Status: implemented — 工作区菜单可持久选择“无工作区”，普通会话以空 cwd 创建

## Problem

普通会话创建已经允许 `cwd == nil`，发送逻辑也不再要求先选择工作区，但
原生界面的工作区菜单只能切换或添加目录，不能显式回到“无工作区”。

此外，启动逻辑在没有可用的 `dsh.workspace` 路径时总会创建并选择
`~/Documents/DeepSeek Harness`。即使只把当前内存里的 `workspace` 清空，
下次启动也会重新选中默认目录，用户的选择无法持久化。

## Decision

- 在工作区偏好中增加独立的“显式无工作区”标记。首次安装仍使用现有默认
  目录；只有用户主动选择“无工作区”时才跳过默认目录，并跨重启保留。
- 将工作区偏好的加载/保存逻辑放进 `DSHWorkspaceActions.swift`，让冻结的
  `main.swift` 只调用恢复入口。
- 在当前 workspace chip 菜单和备用的 workspace switcher 菜单中加入
  “无工作区”，当前为空时显示勾选状态。
- 普通会话在无工作区状态下不附加已注册目录清单，确保空选择不会隐式把
  其他项目目录注入首条消息。
- 增加单元测试，覆盖首次默认目录、显式空选择跨启动恢复、重新选择目录
  清除空选择标记，以及空选择不产生额外目录上下文。

## Alternatives considered

- **删除默认工作区行为，让所有新用户首次启动都为空。** 不选：这会改变
  已有首次使用体验；当前问题只需要让用户能主动退出默认工作区。
- **把空字符串写进 `dsh.workspace` 当哨兵。** 不选：空字符串同时可能被
  当成缺失或无效路径，语义含混，也会让旧的失效路径恢复逻辑难以区分。
- **只在菜单里把 `workspace` 设为 nil，不持久化。** 不选：重启后默认目录
  会再次被选中，用户仍然无法稳定选择“无工作区”。
- **同时放开 Agent Profile composer 的工作区门槛。** 不选：Agent
  Platform Runtime 明确拒绝没有 cwd 的根会话（`Agent Batch requires a
  root session cwd`）。普通对话可使用“无工作区”，Agent Batch 仍需选择
  工作区，这是 Host 能力边界而不是客户端残留门槛。

## Consequences

- workspace chip 菜单和备用的 workspace switcher 菜单都提供“无工作区”，
  当前为空时显示勾选和 `folder.badge.minus` 图标。
- 显式空选择通过独立 UserDefaults 标记跨启动保留；重新选择目录会清除
  标记。首次安装仍创建并使用 `~/Documents/DeepSeek Harness`。
- 普通新会话省略 `cwd`，且不会显示或注入已注册目录作为当前上下文。
  Agent Profile 保留工作区门槛，因为 Runtime 明确要求根会话有 cwd。
- `main.swift` 从 508 行降到 489 行，工作区恢复和偏好逻辑位于
  `DSHWorkspaceActions.swift`；冻结 gate 同步收紧到 489 行。
- `./scripts/test-macos-native.sh --unit` 通过：78 tests passed。
- `./scripts/build-macos-app.sh` 通过，生成最终
  `dist/DeepSeek Harness.app`。
- `./scripts/test-macos-native.sh --smoke` 通过；smoke 新增省略 cwd 的
  `session.create` 实际 Host 断言。
- `plutil -lint` 和 `codesign --verify --deep --strict` 均通过。

## Risks

- “无工作区”只控制新建根会话的 cwd；已经创建的 Host 会话不会被迁移到
  其他目录，这与现有工作区切换行为一致。
- Host 在空 cwd 时使用自己的默认目录，因此“无工作区”表示客户端不指定
  项目目录，不表示进程不存在工作目录。
