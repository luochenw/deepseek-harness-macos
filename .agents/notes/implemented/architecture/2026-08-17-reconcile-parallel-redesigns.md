# Agent Note: 调和两条并行的原生 UI 重构分支

Status: implemented

## Problem

同一时间段内，两个独立会话各自对 macOS 客户端做了一次全面视觉/交互重构：

1. `claude/app-visual-redesign-f3dedc`（本会话）——"赤道海域"设计令牌体系
   （`DSHTheme.swift`），主窗口/详情面板/工具卡片全部套用新配色，会话按
   工作区分组，推理过程拆成独立区域，见
   [ocean-design-system](2026-08-17-ocean-design-system.md)。
2. `sweet-solomon-f1f932`（并行会话，4 个提交已推到 `origin/main`）——
   `macos/DESIGN_SYSTEM.md` + 把 `main.swift` 里的 6 个主窗口 View 拆成
   `DSHSidebarView.swift`/`DSHConversationView.swift`/`DSHComposerView.swift`/
   `DSHDetailsPanelView.swift`/`DSHSettingsView.swift` 五个新文件，**刻意
   不引入新配色**（沿用系统语义色），见
   [native-main-window-redesign](2026-08-15-native-main-window-redesign.md)、
   [native-settings-ui-redesign](2026-08-15-native-settings-ui-redesign.md)、
   [multi-workspace-default-and-grouping](../feature/2026-08-17-multi-workspace-default-and-grouping.md)。

两条分支在 `main.swift` 及 6 个小 Sheet 文件上大范围重叠，直接 `git merge`
会在这些文件上产生结构性冲突（不是措辞级别的小冲突，是两套完全不同的
`Sidebar`/`ConversationHeader`/`MessageBubble`/`DetailsPanel`/`SettingsView`
实现互相覆盖）。用户看过两边构建产物对比后明确决定：以海域配色这条为主，
但 `sweet-solomon-f1f932` 那边独立发现的三处行为修复要保留。

## Decision

`git merge --no-commit --no-ff claude/app-visual-redesign-f3dedc`，7 个冲突
文件（`main.swift` 及 `DSHInteractionsView.swift`/`DSHSessionActionsView.swift`/
`DSHSettingsEditor.swift`/`QuestionBatchSheet.swift`/`QueueDockView.swift`/
`WorkspaceManagerView.swift`）全部取 `claude/app-visual-redesign-f3dedc`
一侧（`git checkout --theirs`）。`sweet-solomon-f1f932` 独有的 5 个拆分文件
（`DSHSidebarView.swift`/`DSHConversationView.swift`/`DSHComposerView.swift`/
`DSHDetailsPanelView.swift`/`DSHSettingsView.swift`）和 `macos/DESIGN_SYSTEM.md`
一并删除——它们描述/实现的是被放弃的方向，留着会误导后续开发。三个记录了
那条分支决策过程的 Agent Note（above 链接的三篇）保留不动，作为历史记录；
它们描述的具体实现已经不在代码里了，但决策本身（尤其是
`sessionIds` 不可靠的实测发现）仍然成立且已被吸收。

在删除前，把 `sweet-solomon-f1f932` 独立发现的三处行为价值移植进
`claude/app-visual-redesign-f3dedc`（视觉上套用海域令牌，逻辑照搬）：

- 会话分组依据从 `DSHWorkspaceView.sessionIds`（实测为空数组，不可靠）
  改成 `DSHSessionSummary.cwd == DSHWorkspaceView.path`。
- `HarnessController.init()` 里，未选过工作区时自动创建
  `~/Documents/DeepSeek Harness` 当默认工作区，而不是逼用户先手动选一个
  文件夹才能发第一条消息。
- `ConversationHeader` 的 preset 菜单在会话已有历史（`hostPresets` 非空且
  `DSHSessionSummary.blank == false`）时改成禁用态 + 说明 tooltip，不再是
  点了才报 `agent-preset-locked` 的可点控件。
- 侧栏零会话、对话区零消息两处补上引导型空状态（图标 + 文案 +
  行动按钮），套海域令牌重做，不是照抄系统语义色版本。

配色本身在这一轮之前又根据用户反馈（"颜色还是太重了"）整体降了一档
饱和度，见 `DSHTheme.swift` 的改动——消息气泡不再用品牌色区分角色/发送方，
纯靠对齐方向 + 背景深浅。

## Alternatives considered

- **保留 `sweet-solomon-f1f932` 那套（系统语义色 + 拆文件），放弃海域配色**：
  Rejected——用户对比过两边构建产物后明确选择海域配色这条作为主线，理由
  是"那套什么配色"（没有品牌辨识度）。
- **两套都保留，做成可切换的主题**：Rejected——超出这次任务范围，且两套
  在文件组织上（`main.swift` 内联 vs. 拆五个新文件）不兼容，做成运行时
  可切换主题需要重新抽象一层，成本远超收益。
- **保留 `sweet-solomon-f1f932` 的文件拆分方式（`DSHSidebarView.swift` 等），
  只把颜色令牌换成 `DSHTheme`**：Rejected——两条分支对同一批 View
  各自做了完整重写（不只是换色），把颜色令牌塞进对方的文件结构里等于
  要重新逐个 diff 校对两套实现的每一处交互细节是否等价，风险和工作量
  都高于"整体保留海域分支的完整实现 + 手动移植三处独立价值"。
- **`git rebase` 而不是 `git merge`**：Rejected——`claude/app-visual-redesign-f3dedc`
  已经推过一次（虽然只是本地 commit，未 push），且这是两条完全独立的
  重构线合流，用 `merge` 记录"两条线在这里汇合"比 `rebase` later
  伪装成线性历史更诚实。
- **保留 `sweet-solomon-f1f932` 的三篇 Agent Note 描述的具体实现细节段落**
  （比如文件拆分方案）：Rejected 但只是部分——决策记录本身保留（历史
  真实发生过，且部分发现如 `sessionIds` 不可靠仍然成立），但不去反向
  编辑那三篇 note 去匹配新现实（没有"superseded"生命周期阶段，见
  `.agents/notes/README.md`），保持它们作为写作时刻的真实记录。

## Consequences

- `./scripts/test-macos-native.sh`、`./scripts/build-macos-app.sh`、
  `./scripts/test-macos-native.sh --smoke` 三层验证在合并后的 `main` 上
  全部重跑通过。
- `main.swift` 及 6 个小 Sheet 文件恢复成单一实现（海域配色版本 +
  移植进来的三处行为修复），不再有两套并存的风险。
- `macos/DESIGN_SYSTEM.md` 和 5 个拆分文件被删除；未来如果要恢复
  "把主窗口 View 拆成独立文件"这个组织方式，`git log` 里
  `sweet-solomon-f1f932` 分支的提交仍然可查，不是彻底丢失。
- 三个描述已删除文件的 Agent Note 现在"名不副实"（决策记录还在，但对应
  代码已经不在仓库里）——留作历史记录是刻意选择，见上面 Alternatives，
  以后翻这几篇 note 找代码位置时要注意这一点。
- 未验证项：`sweet-solomon-f1f932` 那边的 Consequences 部分提到"GUI 截图
  验证未能完成"（同样的环境限制这次也存在）——preset 锁定态、默认工作区
  首次启动体验、两处新空状态，都只做了机械验证（编译/构建/API 冒烟），
  实际视觉效果需要用户在真机上手动确认。
