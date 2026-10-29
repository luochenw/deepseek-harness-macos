# Agent Note: 按功能域拆子目录，并给每个域配一份 AGENTS.md

Status: implemented — 102 个 Swift 文件按 14 个功能域搬进子目录（纯重命名），每个域配一份 AGENTS.md 和一行 CLAUDE.md，加了三条布局卡口

## Problem
- `macos/DSHApp/` 下平铺了 102 个 Swift 文件。功能域只能靠文件名前缀区分：`DSHVoice*`、`DSHHost*`、`Native*` 等。
- 两边加载规则的方式都依赖目录：
  - DeepSeek（dsh 运行时）只认目录。它加载的是 根目录 → 当前目录 → 被改文件所在目录 这条链上的 `AGENTS.md`/`CLAUDE.md`，不支持按文件名 glob 加载规则；
  - Claude Code 也是按目录懒加载子目录里的 `CLAUDE.md`。
- 结果是功能域的不变量只能写进根文件，或者靠派任务时人工指定，「改到哪块就自动读到哪块的规则」做不到。
- 2026-10-27/28 这两天的返工，相当一部分来自不知道某个域的不变量。例如：
  - 转录区「行高不能依赖悬停」；
  - 语音「`installTap` 会抛 ObjC 异常」。
- 根 `CLAUDE.md` 原先「不拆子目录」那一节的理由，是「按文件拆域、拆目录收益小」。这个前提已经不成立：项目在扩展，执行方又只认目录。

## Decision
**纯搬家**：不改任何 Swift 代码的内容，只移动文件、修正路径引用、新增规则文件。

### 1. 目录映射
`Info.plist`、`AppIcon.icns` 留在 `macos/DSHApp/` 根目录。

| 子目录 | 文件 |
|---|---|
| `App/` | ContentView, DSHAppLifecycle, DSHTaskEscapeMonitor, NativeContractCheck, main |
| `Design/` | DSHTheme, NativeScrollbars, NativeSeaArt |
| `System/` | DSHExceptionDiagnostics, NativeAlerts |
| `Host/` | DSHAssistantStreamProjection, DSHEventSocket, DSHExternalAgentBridge, DSHHistory, DSHHostClientExtensions, DSHHostGateway, DSHHostProtocol, DSHHostSessionFollow, DSHHostSupervisor, DSHHostSync, DSHHostWorkspaceStream, DSHInteractions, DSHOpenPath, DSHProjections, DSHTurnTiming, DSHTypertGateway |
| `Transcript/` | ConversationLoadingView, ConversationView, DSHConversationPresentation, DSHConversationScrollStability, DSHToolCallClassification, DSHToolPresentationSupport, DSHTranscriptPerf, NativeAttachmentPreview, NativeMarkdownText, NativeToolPresentationView, StreamingAssistantText |
| `Composer/` | ComposerView, DSHAttachments, DSHComposerSubmission, DSHQueue, DSHSendActions, DraftImagePasteMonitor, DraftImageStrip, NativeCommandPalette, QueueDockView |
| `Sessions/` | DSHGoalActions, DSHInteractionsView, DSHPermissions, DSHPresets, DSHSessionActions, DSHSessionActionsView, DSHSessionLifecycle, DSHSessionModel, DSHSessionModels, DSHSessionOps, DSHSessionSearch, DSHSkills, NativeDashboard, PermissionViews, QuestionBatchSheet, SessionOpsViews, SkillsGoalView |
| `Sidebar/` | SidebarSessionGroupView, SidebarView |
| `Workspace/` | DSHGitOps, DSHWorkspaceActions, NativeWorkspaceChips, WorkspaceManagerView |
| `Settings/` | DSHAppPrefs, DSHCredentialRead, DSHCredentialReferences, DSHCredentialWrite, DSHModelUsage, DSHModels, DSHProviderActions, DSHProviderAuthoring, DSHProviderProfileValues, DSHProviders, DSHSessionRelaySettings, DSHSettings, DSHSettingsActions, DSHSettingsEditor, DSHSettingsMutate, DSHSettingsView, ModelUsageSettingsView |
| `Voice/` | DSHVoice, DSHVoiceDispatch, FloatingBubble, VoiceInputView, VoiceSettingsView |
| `Workbench/` | DSHWorkbench, NativeBrowserView, NativeMarkdownDocumentView, WorkbenchCommands, WorkbenchView |
| `AgentPlatform/` | AgentPlatformView, DSHAgentPlatform, DSHAgentPlatformPolicy |
| `Subagents/` | DSHSubagentProjection, DSHSubagentTree, DSHSubagents |

**映射已定稿**：A 阶段由执行方逐个文件做了依赖分析（定义了什么、被谁用、用了谁），Claude 据此调整了 7 个文件的归属（例如 `DSHAssistantStreamProjection`、`DSHTurnTiming`、`DSHOpenPath` 归 `Host/`，`NativeScrollbars` 归 `Design/`）。上表即最终映射，与 `move-map-final.tsv` 一致。
**`macos/DSHTests/` 保持平铺**：测试文件靠前缀已经能和功能域对上，测试注册表 `DSHTestsMain.swift` 是手写的，搬进子目录收益很小。

### 2. 每个子目录两个规则文件
- `AGENTS.md`：固定 5 节，实际每份 13–17 行（卡口上限 60 行）：
  1. 这个域负责什么、不负责什么；
  2. 关键文件；
  3. 不变量，每条都注明来源（Agent Note 或者测试名）；
  4. 改完必须跑的检查；
  5. 踩过的坑。
- `CLAUDE.md`：只有一行 `@AGENTS.md`。这样 Claude Code 能读到同一份内容，dsh 也只会多读到这一行字面文本，内容不会重复。
- 内容只取自已有的 Agent Note 和测试，不新编规则。根文件里已有的通用规则不在域文件里重复。

### 3. 路径引用一起改
- 16 个构建、测试脚本：`macos/DSHApp/*.swift` 通配改为 `macos/DSHApp/*/*.swift`，写死的单文件路径按新目录改；`MAIN_SWIFT` 指向 `App/main.swift`，上限仍是 489 行；
- 根 `AGENTS.md` 的 Repository layout 改成分目录树；根 `CLAUDE.md` 的「多 Agent 并行」「质量规范」改成按域目录描述，原来「不拆子目录」一节改写为「规则文件组织方式：每个域目录一份」；
- `README.md`、`README.en.md` 的通配，以及 `scripts/generate-app-icon.swift` 的一行注释；
- CI 和 `macos/WEB_PARITY.md` 里没有这类路径，未改；
- 历史 Agent Note 和 `docs/superpowers/plans/` 是当时的记录，**不改**，旧路径只留在这两处。

### 4. 新增卡口
`test-macos-native.sh` 里有三条：
- `macos/DSHApp/` 根目录下不允许再出现 `.swift` 文件；
- 每个含 `.swift` 的子目录都必须有 `AGENTS.md` 和 `CLAUDE.md`；
- 每份 `AGENTS.md` 不超过 60 行。

## Alternatives considered
- **根 `AGENTS.md` 加功能域索引，由任务指定先读哪份文档**：不选。它依赖派任务的人每次记得指定，漏一次就等于没有；项目扩展以后，索引会越来越长。
- **用 `.claude/rules/*.md` 加 `paths:` glob 按文件名匹配**：不选。dsh 不支持，执行方 DeepSeek 读不到。
- **把功能域打成 dsh skills，按需加载**：不选。触发方式不确定，比放在目录里重；规则也会和代码分开存放。
- **不拆**：不选。用户明确要「一次性到位」，而且执行方只认目录，不拆的话以后每个域的规则都没有落点。
- **测试也一起镜像搬进子目录**：这次不做。理由见上，以后需要时再单独做一轮。

## Consequences
- 改到哪个域的文件，dsh 和 Claude Code 都会按目录加载那个域的 `AGENTS.md`，派任务时不必再手动指定先读哪份规则。
- 执行过程：A 阶段由 DeepSeek 只读核对映射、列出全部路径引用、按域摘出有出处的不变量；B 阶段由 DeepSeek 纯搬家，只准动清单内的文件，`macos/` 下的 Swift 内容一个字符都不许改。Claude 定稿映射、审阅 14 份 `AGENTS.md`（逐条核对 90 处 Note 引用和 31 处原文引用都存在），并在沙箱外重跑全部验收。
- 验收结果：102 个文件全部 R100；typecheck 和卡口通过，故意在根目录放一个 `.swift` 时卡口报错；`--unit` 298/298；10 个专项 UI 脚本和 Agent 平台运行时检查全部通过；在临时副本里构建和 `--smoke` 通过（含 host-handshake、native-host-api-smoke）。
- 新增一个域目录时，必须同时建 `AGENTS.md` 和 `CLAUDE.md`，否则卡口不过。
- 已知缺口：构建通配只匹配一层子目录，域目录里再嵌一层的 `.swift` 会被构建漏掉，目前没有卡口拦截。
- `macos/DSHTests/` 仍是平铺；以后测试多到前缀对不上时，再单独做一轮。
