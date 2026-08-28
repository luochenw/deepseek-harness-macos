# Agent Note: 原生权限菜单与运行中追加输入

Status: implemented — 动态权限菜单与运行中 Queue/Steer 已接入并通过验证

## Problem

内置 DSH Host 已经提供权限预设和忙碌会话输入能力，但原生 macOS
客户端没有完整暴露：

- `permissions` 会话投影与 `/permission <preset>` 命令支持
  `read-only`、`workspace-write`、`danger-full-access`，设置命名空间
  `permission.defaultPreset` 负责后续新会话的默认值。
- `session.prompt` 的 `mode` 原生支持 `queue` 与 `steer`。客户端运行中只
  显示停止与排队按钮，键盘提交被 `composerCanSubmit` 拦截，无法把补充内容
  追加到当前轮。
- Web 客户端通过 `ui-conversation.busyEnter` 保存运行中普通 Enter 的
  `queue` / `steer` 偏好，原生客户端尚未读取或写入该 Host 设置。

## Decision

- 新增独立权限域模型与 controller 扩展：
  - 解码 Host 的动态 `permissions` 投影；
  - 从 `permission` Settings schema 提取未来会话可选项；
  - 当前会话通过 `/permission <preset>` 切换，默认页和设置页通过
    revisioned `settings.mutate` 修改 `defaultPreset`；
  - `commands/execute` 对 rc.2 发送必需的空 `images` 数组，并在旧版 Host
    明确拒绝该新增字段时回退到旧载荷；
  - `danger-full-access` 在提交前显示原生风险确认。
- 在 composer 底栏加入紧凑权限菜单，沿用现有 `DSHTheme`、图标按钮和
  borderless menu 视觉；子代理视图不显示该根会话权限控件。
- 把 prompt mode 收紧为类型化的 `queue` / `steer`：
  - 运行中提供停止、插话发送、排队发送三个明确动作；
  - 普通 Enter 按 Host 的 `ui-conversation.busyEnter` 偏好提交，
    Command-Enter 使用另一种投递方式；
  - 当 Command-Enter 对应插话方式时，空草稿会把当前仍排队的消息依次转为
    steering；
  - continuable 子代理保持其协议支持的 Queue-only 行为，并复用相同的图片
    读取、提交锁和成功后清空事务；
  - 根会话运行中输入斜杠命令时，`/export` 与 `/model` 继续走原生客户端动作，
    其余命令优先走 `commands/execute`，未匹配命令才回退为 Queue/Steer
    普通消息。
- 在通用设置中增加“运行中按回车”和“新会话默认权限”两项原生选择器。
- 权限、队列、命令和子代理异步错误写回发起操作的原会话，避免用户切换
  会话后污染当前页或静默丢失反馈。
- 补充纯逻辑/解码/编码测试、真实 SwiftUI 快照、临时 Host smoke，以及
  README / `macos/WEB_PARITY.md`。

## Alternatives considered

- **只在菜单里写死三项，不消费投影或 schema**：不选。DSH 的权限预设表是
  组合级动态配置，客户端应显示 Host 实际提供的选项和当前值。
- **运行中仍只提供 Queue，把“追加”理解为下一轮消息**：不选。Host 明确把
  `steer` 定义为当前轮输入，语义和 Queue 不同。
- **解除 `send()` 的运行中 guard 并继续使用默认 Queue**：不选。这样无法
  表达 steering，也会让普通首轮发送、命令分发和运行中提交纠缠在同一路径。
- **把权限和提交偏好新增为 `main.swift` 的 `@Published` 字段**：不选。
  `main.swift` 已冻结；权限的会话态使用独立 registry，设置态直接读取现有
  `settingsDescription`。

## Consequences

- 默认页读取 `permission.defaultPreset`，普通根会话读取带序号水位保护的
  `permissions` 投影；自定义 composition 缺少能力时菜单自动隐藏。
- 完全访问在当前会话和新会话默认值两条路径上都要求原生风险确认。
- 运行中显式提供停止、插话发送和排队发送；键盘行为与
  `ui-conversation.busyEnter` 同源，Command-Enter 使用另一种方式。
- QueueDock 只展示 next-turn 队列；pending steering 在转录尾部即时显示，
  对应 durable `user/message` 到达时按 message identity 完成交接；队列快照
  按 session 缓存，切换回来不会丢失未变更的队列。
- 含图片等非纯文本内容的队列项保留预览、删除和 steering，但不开放会丢失
  附件的纯文本编辑。
- Host-backed 下拉设置按 namespace 或 session 锁定在途写入，避免相同
  revision 的并发选择使最终值偏离用户最后确认的状态。
- Queue/Steer 与子代理追问在 Host 接纳前保留草稿和附件；共享 composer
  草稿使用全局在途锁，队列批量操作仍按 session 锁定。图片读取失败或 RPC
  失败不会静默丢失输入，切换会话也不会重复发送已接纳的内容。
- Mux 重连的 `session/subscribed.lastSeq` 会截断超出 Host 当前日志水位的旧权限
  缓存，既允许 Host 重启后的低序号基线重新成为权威状态，也保留并发到达的
  有效 session-list 基线。
- 验证覆盖动态权限投影、Settings schema、Steer 编码、键盘提交策略、
  Queue/Steering 分类、投影水位、真实 SwiftUI 快照和打包 Host smoke。
