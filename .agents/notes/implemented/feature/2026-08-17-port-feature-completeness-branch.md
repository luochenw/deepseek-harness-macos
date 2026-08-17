# Agent Note: 移植 macos-feature-completeness-review 分支能力

Status: implemented

## Problem

`claude/macos-feature-completeness-review-d7200d` 分支（16 commits，51 文件，
+5524/-1879）独立于海域视觉重构（见 [[2026-08-17-ocean-design-system]] /
[[2026-08-17-reconcile-parallel-redesigns]]）开发，包含 main 当时没有的能力：

- 语音输入/朗读（`VoiceController`、唤醒词、`VoiceInputButton`）
- Typert Gateway 原生客户端（`/api/<namespace>/<method>`）：斜杠命令面板、
  消息反馈（点赞/点踩）、插件清单
- 真正的 Host 驱动计划模式（当时 main 的 `planMode` 只是一个本地布尔开关，
  不产生任何 RPC）
- 目标（goal）的可视化：`goal.*` 投影数据当时已在拉取，但没有任何 UI 渲染
- 技能（skill）目录的可视化：同上，`skill.list` 数据已在拉取但未渲染
- 会话归档列表 / 导出会话日志 / Preset 管理器 / 模型发现 UI
- 若干 `HarnessController` 核心 bug：遗留一次性 CLI 执行栈残留、
  `isRunning` 在 Host 路径下永不重置（每轮结束后"停止/排队"按钮卡死）、
  排队消息 `queueDraft()` 写入一个没有任何代码再读取的死数组、
  纯装饰性的 `PermissionMode` 选择器（未接入任何真实 RPC）

同时该分支自己也带了一套设计语言（与海域主题冲突）、一套不同的会话身份模型
（`hostSessionId` 为中心重构 `Session`，与已上线的 `hostSessions` /
`sessionGroups` 侧栏分组机制冲突），以及本仓库已有、该分支却没有的两个功能：
子代理整树浏览（`DSHSubagentTree.swift`）与工作区会话分组
（`WorkspaceSessionGroup`/`sessionGroups`）。

## Decision

按子系统逐个手工移植到当前 `main.swift`，而不是整支 `git merge`：

- **零主题耦合的文件整体照搬**：`DSHTypertGateway.swift`、`DSHVoice.swift`、
  `DSHProjections.swift`、`DSHSessionOps.swift` —— 纯 RPC/wire 类型 +
  `HarnessController` extension，与 UI 无关，直接复制。
- **含 UI 的文件复制后重新套用 `DSHTheme`**：`SessionOpsViews.swift`、
  `VoiceInputView.swift`、`NativeToolPresentationView.swift` 升级、新增的
  `SkillsGoalView.swift`（技能卡片 + 目标条）——参照
  `NativeDashboard.swift`/`QueueDockView` 已有的卡片/徽标/按钮样式手工改写，
  不使用源分支自带的配色。
- **`HarnessController` 核心改动逐行手工整合进 `main.swift`**：不采用
  merge/cherry-pick，以确保子代理整树浏览和工作区会话分组这两个当前
  main 已有、源分支没有的功能不被覆盖或丢失（已在本次代码审查中专项验证，
  两者均完整保留）。
- **显式不移植**源分支的单会话存储架构重构（与已上线侧栏冲突）、源分支自己的
  设计系统（已被海域主题取代）、以及"composer-transcript-ux"子系统
  （Enter 发送、滚动锁定到底部、草稿历史召回、工具详情钉住/跟随最新、内联
  transcript 工具行、`foldHistory` 为压缩/工作流事件扩容）——这是一个更大、
  独立的功能面，留作后续单独的 Agent Note 处理。

移植过程中代码审查（8 路并行 finder + 逐条核实）额外发现并修复：

- `send()` 的斜杠命令分支未设置 `isRunning`，命令回退为普通 prompt 时用户
  可在轮次进行中重复发送，造成并发轮次
- `NativeAlerts.setRunning`/`clearAttention` 是移植时新增的方法，但从未被
  实际调用——`isRunning` 变化和审批/问题解决后菜单栏图标状态不会更新
- `answerApproval` 直接读取 `pendingApproval` 而非校验调用方传入的具体
  审批项 id（`answerQuestionBatch` 已有该校验，两者实现不对称）——审批队列
  在用户点击的瞬间被服务端推进后，会误答到新的当前项而非用户实际看到的那个
- `tokenUsage`/`contextPressure`/`sessionStats` 三个投影字段已解码入
  `@Published` 状态，但没有任何 UI 消费者，`applyProjection` 的文档注释却
  声称"composer 状态条"会读取它们——补齐了源分支原有但移植时漏掉的
  `StatusStrip`（上下文占用/token 用量/轮次统计），套用海域主题字号与配色
- `VoiceSettingsView.swift` 移植时保留了源分支的系统原生样式（`Divider()`、
  `.roundedBorder`），是本次唯一未套用 `DSHTheme` 的设置页——已重新套壳
- 一处代码注释引用了一份从未真正写过的 Agent Note 文件名（本文件之前的
  占位引用）——已改为指向本文件

## Alternatives considered

- **整支 `git merge`/cherry-pick**：会静默带回源分支自己的设计语言，且该
  分支缺少子代理整树浏览与工作区分组两个当前 main 已有的能力，直接合并
  会造成大量深层冲突且有丢失现有功能的风险——放弃。
- **从零按当前 `main.swift` 重写这些能力**：源分支的 RPC/wire 类型代码本身
  正确且零主题耦合，重写是纯浪费——只有视图层需要手工改写，采用"整体照搬
  + 视图层重做"的折中方案。
- **顺带移植源分支的单会话存储架构**（追求"完整对齐"）：其会话身份模型与
  已上线的 `hostSessions`/`sessionGroups` 侧栏结构冲突，移植它需要重新设计
  侧栏——超出本次范围，放弃，留待后续视是否真有必要再单独评估。
- **保留 `VoiceSettingsView.swift` 原生样式**（理由："语音是独立子系统，
  样式隔离影响小"）：代码审查指出这是新用户很可能第一个打开的设置页，
  与其余每个设置 tab 的视觉不一致会立刻可见——放弃，改为套壳。

## Consequences

- `macos/WEB_PARITY.md` 第 15/18 行（Todo/plan/goal、Skills）与第 46 行
  （"Typert Gateway 无原生客户端"的表述）已更新以反映本次移植后的真实状态。
- Composer 底部新增 `StatusStrip`（上下文占用 / 累计 token / 轮次步骤），
  依赖的三个投影字段现在会在 `openHostSession` 时随 `summary.projections`
  一并回填（此前只回填了 todos/plan/goal，token 相关三个字段遗漏）。
- 已知遗留 gap（未在本次处理，供后续参考）：composer-transcript-ux 子系统
  （见上）未移植；`openHostSession` 重新打开一个已跟踪会话时提前 return，
  不会刷新 `messageFeedback`/`hostCommands`/todos/plan/goal/token 等投影
  字段——这是移植前就存在于 todos/plan/goal 三个字段上的既有行为，本次未
  改变其语义，仅指出供后续统一修正。
