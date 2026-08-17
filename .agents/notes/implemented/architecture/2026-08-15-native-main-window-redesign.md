# Agent Note: 主窗口原生化重构

Status: implemented

## Problem

跟 [native-settings-ui-redesign](2026-08-15-native-settings-ui-redesign.md) 同一个问题的第二个现场：主窗口（`ContentView`，main.swift:1445）挂的 6 个 View——`Sidebar`（1481）、`ConversationHeader`（1526）、`ConversationView`/`MessageBubble`（1549/1559）、`Composer`（1570）、`DetailsPanel`（1590）——全是同款单行分号堆砌，`Composer.body` 尤其重（1584 一行塞了附件菜单/图片 chip/占位文案/推理强度菜单四样东西）。跟 Settings 不同，主窗口是日常高频看到的界面，问题更显眼：会话列表没有图标、没有空状态（新工作区零会话时列表就是空白）；顶部三个 Menu（preset/权限/模型）是裸 `.menuStyle(.borderlessButton)`，其中 preset 菜单点了就直接调 `selectCurrentPreset` RPC——会话开始后 Host 端会拒绝（`agent-preset-locked`），但 UI 没有任何禁用/提示，用户体感就是"点了报错"（这次任务里用户实际报的两条错之一）。

`NativeToolPresentationView.swift`、`DSHSubagentTree.swift`、`NativeDashboard.swift` 的 `WorkflowCard`/`SubagentCard`、`NativeAttachmentPreview.swift` 的灯箱已经是精心做过的（图标、状态色、`DisclosureGroup`），不在这次范围内。

用户明确要求"一套完整统一的 UI 标准"，不只是主窗口这一处——所以先把已经在这几个界面里稳定使用的约定（`NativeToolPresentationView.swift` 的 `Card`/`Badge`、`NativeDashboard.swift` 的卡片配色、`DSHSubagentTree.swift` 的空/loading 态、这轮 Settings 重构的反馈态写法）和这轮新加的约定（侧栏图标、少用 `Divider()`）一起写成 [macos/DESIGN_SYSTEM.md](../../../../macos/DESIGN_SYSTEM.md)，主窗口这几个 View、以及其余几个小 Sheet（`WorkspaceManagerView`/`QueueDockView`/`ApprovalSheet`/`QuestionBatchSheet`/`RenameSessionSheet`）都按这份标准一起重写，而不是各写各的。

## Decision

按功能域拆成 4 个新文件（不是最初设想的单一 `DSHMainWindowViews.swift`——6 个 View 按耦合度分组更符合"按功能域拆文件"的约定），`ContentView` 本身（纯组合 + 7 个 `.sheet`）留在 main.swift 不动，全部对照 `DESIGN_SYSTEM.md`：

- `DSHSidebarView.swift` —— `Sidebar`
- `DSHConversationView.swift` —— `ConversationHeader` + `ConversationView` + `MessageBubble`（三者耦合紧密，一起挪）
- `DSHComposerView.swift` —— `Composer`
- `DSHDetailsPanelView.swift` —— `DetailsPanel`

同时顺手对齐了 `WorkspaceManagerView.swift`/`QueueDockView.swift`/`DSHInteractionsView.swift`/`QuestionBatchSheet.swift`/`DSHSessionActionsView.swift` 这 5 个小 Sheet 文件的格式，跟 `DESIGN_SYSTEM.md` 保持一致（原地编辑，没有拆新文件，因为它们本来就是独立文件）。

用 Workflow 工具起了 6 个并行 agent 分别处理这 6 个目标（4 个抽取 + 2 组小文件），每个 agent 只读 main.swift（不写）、只写自己负责的目标文件，规避了 main.swift 并发写冲突；main.swift 里 6 个旧 View 定义的删除由发起改动的 agent 在全部 6 个子任务完成后统一做单次删除。

- **不用 `Divider()` 做区块分隔**——按用户明确反馈（见 memory `feedback-avoid-divider-lines`），改用间距 + `.background`/圆角卡片分组。`Sidebar` 里"工作区"到"会话"之间、`DetailsPanel` 里工具详情标题到内容之间的 `Divider()` 都换成留白。侧栏与对话区、对话区与详情栏之间的主分割线保留——那是窗口级别的结构分界，不是这次反馈针对的"区块内乱加线"。
- **Sidebar**：会话行加空状态（`hostSessions`/`sessions` 都为空时显示引导文案+新建按钮，而不是一片空白 `List`）；其余绑定原样保留。
- **ConversationHeader**：preset 菜单加锁定态——当 `harness.hostPresets` 非空（走 `selectCurrentPreset` 实时切换分支）且当前 Host 会话 `blank == false`（已经有过一轮，`DSHSessionSummary.blank` 现成字段）时，菜单换成禁用的 `Label(... , systemImage: "lock.fill")` 而不是可点的 `Menu`——从根源上不再让用户点出 `agent-preset-locked` 报错。`hostPresets` 为空时走的本地 `setPreset`（新会话默认值，不影响当前会话）分支不受影响,那个从来不会被 Host 拒绝。
- **Composer**：把 1584 那一整行拆成清楚的多行结构,不改变任何绑定/action。
- 其余（`ConversationView`/`MessageBubble`/`DetailsPanel`）纯格式化 + 间距分组,不改行为。

## Alternatives considered

- **只格式化不加空状态/锁定态**：更省事,但用户这轮明确要求"注意对齐这些问题"——preset 锁定报错是这次任务本身发现的真实可复现体验问题,只重排版不修等于假装没看见。
- **preset 锁定态放到 Settings 里处理**（比如设置页禁止选非当前 preset）：不对症——报错触发点是主窗口顶部菜单,不是设置页,设置页的 preset picker 本来就只影响"下一个新会话"、从不触发这条 RPC。
- **保留 `Divider()` 做区块分隔,只加图标/空状态**：用户在草图确认后追加了明确反馈"整理尽量不用使用线的样式",这次直接照办,不用再问一遍。

## Consequences

- `./scripts/test-macos-native.sh`、`./scripts/build-macos-app.sh`、`./scripts/test-macos-native.sh --smoke` 三层验证全部一次通过（main.swift 清理后首次跑就是干净的，各 agent 在写完时用隔离的 scratch 副本自查过 typecheck）。
- 原 6 个 View 的每个控件/绑定/action 都在新文件里保留，main.swift 净减少约 120 行（1481-1600 整块删除），不再有这 6 个 View 的定义。
- preset 菜单在会话已开始（`blank == false` 且 `hostPresets` 非空）时不再是可点的 `Menu`，换成橙色锁形图标的 `Label` + `.help()` 提示 `agent-preset-locked` 的原因；`hostPresets` 为空时的本地 `setPreset` 分支未受影响。
- 4 个抽取文件（`Sidebar`/`Composer`/`ConversationHeader`+`ConversationView`+`MessageBubble`/`DetailsPanel`）全部不含 `Divider()`，符合设计标准第 1 条；Sidebar 和 ConversationView 各加了一个空状态（零会话 / 零消息），此前完全是空白。
- 6 个并行 agent 各自独立跑通了隔离验证但彼此不知道对方的结果，实际把 main.swift 里对应旧代码删除、跑一次真正的全量 `swiftc -typecheck` 是本次任务里唯一一次"合并点"——顺利通过，说明每个 agent 报告的行号边界（1481-1524 / 1526-1568 / 1570-1588 / 1590-1600）互相之间以及和 main.swift 实际内容都精确吻合，没有一个需要事后校正。
- `DSHSessionSummary.blank` 之前只在 Sidebar 的状态点渲染里用过，这次是第二处消费——如果 Host 端对"已开始"的定义和这个字段语义有出入（比如空消息但已经创建过 turn 记录），锁定态判断可能不完全精确，但比"完全不判断，点了才报错"是净改善。
