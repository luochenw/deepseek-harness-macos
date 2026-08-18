# Agent Note: 质量债修复计划 —— 规范补强 + 验证深度 + main.swift 拆分

Status: implemented — Phase 0/1/2 全部完成，main.swift 3364 → 504 行

## Problem

外部质量评审指出两类真实短板，已逐条核实（2026-08-18）：

1. **验证深度不足**：0 单元测试、0 UI 测试；"契约测试"只是编译时 fixture（`NativeContractCheck.swift`，能编译 ≠ 行为正确）；smoke 只覆盖只读 API（`verify-native-host-api.sh`），prompt / settings.update / subagent 等读写路径零覆盖；CI（`.github/workflows/ci.yml`）只跑 typecheck，不构建、不冒烟。
2. **main.swift 是架构债**：3364 行单文件 = HarnessController（69 个 `@Published`——外部评审截图原话是"68 个"，Phase 2 批次 7 时顺手核实过是 69，此后统一用核实过的数字）+ 30 个顶层 view struct 混在一起，零 `// MARK:` 分区、零 `extension`。AGENTS.md 写了 "rather than growing main.swift further"，但同一文件又允许 "inline in main.swift for core flows"，且没有任何强制手段——规范落空的制度性原因。
3. 次要：主 checkout 的 `dist/` 里有构建中断残留的 stage 目录；`.agents/notes/proposed/simplification/` 是空目录（均为未跟踪本地产物，不在 git 里）。

根因：CLAUDE.md 管住了**流程**（先想清楚、写 Note、验证命令、提交纪律），但没有**质量规范**——没有测试要求、没有文件结构约束、没有 CI 深度要求，且唯一一条 main.swift 约束没有 gate。

## Decision

按"冲突面从小到大"分三阶段，兼容当时两个在途功能 session：

### Phase 0 — 立规矩 + 止血（本 session，纯文档/脚本，零冲突，立即）✅ 已完成

1. ✅ CLAUDE.md 新增「质量规范」节；AGENTS.md 同步修订：
   - **main.swift 冻结令**：即日起任何新 view / 新 `@Published` / 新方法禁止进 `main.swift`；新 view 一律独立 `<Feature>View.swift`，新状态与逻辑一律 `DSH<Feature>.swift` 的 `extension HarnessController`。删除 AGENTS.md 中 "inline in main.swift for core flows" 的许可、改写 When-adding-a-feature 第 3 条、修正 State management pattern 里"subagent 方法已经在 extension 里"的失实描述（实际仍在 main.swift，作为迁移债在此记录，不是可复制的范例）。
   - **行为改动必须带验证**：短期用现有手段（契约 fixture + smoke），Phase 1 落地后升级为"新逻辑必须带单测"（已写入 CLAUDE.md 质量规范）。
2. ✅ **给冻结令配 gate**：`test-macos-native.sh` 加了一条检查——`main.swift` 行数（基线 3364）超限直接 `exit 1`，报错信息指向 AGENTS.md/CLAUDE.md。验证：typecheck / build / smoke 三条命令本次全过；手工模拟增行触发过一次失败退出确认 gate 生效。
3. ✅ 琐碎清理：`build-macos-app.sh` 开工前清掉 `dist/` 里的 `.DeepSeek-Harness-stage-*.app` 残留和 `$APP.previous`（用模拟的孤儿目录验证过确实被清掉，且不影响正常构建产物）；顺手清了主 checkout `dist/` 里已经存在的 11 个历史残留目录。`proposed/simplification/` 经核实是未跟踪的本地空目录，不在 git 里，无需处理。

### Phase 1 — 验证深度（新文件为主，与功能 session 并行安全）✅ 已完成

1. ✅ **单测基建**：`test-macos-native.sh` 加了 `--unit`。实测踩了一个真实的架构坑再解决——main.swift 有 `@main struct DSHNativeApp: App`，两个 `@main` 没法链进同一个可执行文件。解法：生产源码用 `swiftc -parse-as-library -enable-testing -emit-library -emit-module` 编成 `DSHAppLib` 库（不产生可执行文件，main.swift 的 `@main` 不会被链接，不冲突），`macos/DSHTests/*.swift` 单独编成可执行文件、`@testable import DSHAppLib` 拿到 `internal` 可见性、`-l`/`-L`/`-I` 链接那个库。零新依赖、零第二套生产源码列表，`macos/DSHTests/DSHTestSupport.swift` 是极简 assert harness（`expect`/`expectEqual` + 显式列表驱动，没有反射式自动发现）。
   - 副产物：实测证实 `HarnessController()` 不能脱离真实 App bundle 实例化（初始化路径里的 `NativeAlerts.attach()` 调用 `UNUserNotificationCenter.currentNotificationCenter()`，裸命令行进程里 `bundleProxyForCurrentProcess` 是 nil，直接崩），印证了下面第 2 条"不碰 main.swift／不测 HarnessController 实例"的范围选择不是随便定的，是这个架构下唯一可行的选择。
2. ✅ **先测天然可测的部分**（不碰 main.swift，不实例化 HarnessController）：`macos/DSHTests/DSHVoiceTests.swift`（`VoiceSettings` 的唤醒词/结束语/取消指令匹配——git log 里"唤醒听写三修"证明这类纯字符串逻辑真的会出回归）、`DSHHostProtocolTests.swift`（`DSHJSONPatchValue`/`DSHJSONPatch` 手搓递归 JSON 编码、`DSHRPCEnvelope`/`DSHRPCServerResponse` 编解码）、`DSHProjectionsTests.swift`（`DSHProjectionDecoder.decode` + `DSHTokenUsage.totalInputTokens`）。12 个断言，本地验证过：全绿；也故意改错一处断言确认会报 `FAIL <name>: file:line` 且退出码非 0，不是摆设。
3. ✅ **smoke 扩展到读写路径**：`verify-native-host-api.sh` 加了 `settings.update`（写 `ui-theme` namespace 的 `preference`）+ 后续 `settings.describe`（读回校验）。namespace/初始值/revision 都是先手工起一个临时 `DSH_HOME` 的真实 Host、`curl` 实测出来的（`ui-theme` 在全新配置目录下就是 `{"preference":"system"}`、revision 0），不是猜的。同样故意改错期望值验证过失败路径会报错退出。prompt/queue 路径这次没做，读写覆盖的第一条打通即可，多轮 prompt 涉及流式事件更复杂，留给后续按需扩展。
4. ✅ **CI 升级**：`ci.yml` 的 `native-contract` job 从"只 typecheck"扩成 typecheck → `--unit` → `npm install -g @deepseek-ai/dsh` → `build-macos-app.sh` → `--smoke` 五步，本地按相同顺序完整跑过一遍全绿。

### Phase 2 — main.swift 拆分（高冲突，等两个功能 session 合并后串行）

每批一个 commit、行为零改动、typecheck + build + smoke 全过，gate 基线随之下调：

1. ✅ **已完成**：30 个顶层 view struct 按功能域搬到既有/新建 `<Feature>View.swift`——`ContentView.swift`（根组合视图，30 行）、`SidebarView.swift`（Sidebar 及其 6 个子组件，243 行）、`ConversationView.swift`（对话流 16 个组件，646 行）、`ComposerView.swift`（输入框 3 个组件，295 行）、`DetailsPanel` 并入既有 `NativeDashboard.swift`（它本来就嵌套调用 `NativeDashboard()`，天然同源）、`SessionSearchView` 并入既有 `SessionOpsViews.swift`（同类会话操作视图的既有归宿）。main.swift：3364 → 2101 行（-1263，-37.5%）。
   - 迁移方式：用 `sed -n 'START,ENDp'` 按顶层闭合大括号精确切界（先用 `awk '/^}$/{print NR}'` 找出所有顶层 `}` 的行号，两两配对验证过界限——6 处 cluster 边界都手工核对过没有夹带下一个 struct 的文档注释），逐块搬到新文件后从 main.swift 里删掉同样的行区间（从文件尾部往头部删，避免行号错位）。
   - 踩了两个坑：① 一开始用 `{ echo ...; cat ...; } > file` 往文件里塞内容，shell 的交互式包装层把终端转义序列也写进了文件——4 个新文件全部损坏，靠 diff 比对原始 sed 提取的内容才发现，改用 `cat headerfile bodyfile > target`（无 echo、无花括号分组）之后每个文件都逐字节 diff 验证过和原文件一致。② 6 个顶层组件（`Sidebar`/`ConversationHeader`/`ConversationView`/`Composer`/`DetailsPanel`/`SessionSearchView`）在原 main.swift 里是 `private`——同文件内没问题，拆到不同文件后 `ContentView.swift` 跨文件引用不到，typecheck 直接报错抓出来了，改成默认的 `internal`（去掉 `private`）即可，其余只在同一新文件内部使用的子组件保持 `private` 不变。
   - 验证：typecheck + `--unit`（12/12）+ `build-macos-app.sh` + `--smoke`（含写路径）全过；额外用 `open` 启动过打包后的 app 确认能正常拉起进程（非交互式，只验证不崩溃，没有做交互式 UI 走查）。
   - Gate 基线跟着下调到 2101（`test-macos-native.sh` / CLAUDE.md / AGENTS.md 三处同步）——随后 rebase 到最新 main 又变成 2131，见下面「rebase 冲突」小节。
2. **进行中**：HarnessController 方法按域拆成 `extension` 到对应 `DSH<Feature>.swift`（沿用项目既有模式，只是执行彻底）。
   - ✅ **批次 2 已完成**：工作区管理 10 个成员（`renameWorkspace`/`deleteWorkspace`/`importWorkspaceFolder`/`registerWorkspace`/`chooseWorkspace`/`resolveWorkspacePath`/`openDeliveredFile`/`revealDeliveredFile`/`openHostPath`/`openWorkspace`，110 行）搬进既有 `DSHWorkspaceActions.swift`（之前只有 wire types，现在加了 `extension HarnessController`）。main.swift：2131 → 2020 行。
     - 踩了两个新坑（跟批次 1 的"struct 是 private"不是同一类）：① 顶层 `private let workspaceKey = "dsh.workspace"`（main.swift 文件作用域常量）被 `registerWorkspace` 用到，挪去别的文件看不见，去掉 `private`（只改这一个常量，`modelKey`/`providerKey`/`reasoningEffortKey`/`presetKey` 留给以后动到对应方法时再改，不预先扩大改动面）。② `@Published private(set) var workspace` / `sessions` 的 setter 是 `private(set)`——同文件内是 var 一样能写，跨文件的 extension 看不到 setter，报"setter is inaccessible"，去掉 `private(set)` 变普通 `var`（这本来就是这个"拆到 extension 里改状态"架构必然要付的代价：状态只让 main.swift 写的封装假设从"多文件按功能域拆分"那天起就不成立了）。`DSHWorkspaceActions.swift` 原来只 `import Foundation`，`NSOpenPanel`/`NSWorkspace` 需要 `import AppKit`，补上。
     - 验证：typecheck + `--unit`（12/12）+ build + `--smoke` 全过。
   - ✅ **批次 3 已完成**：会话管理 16 个成员（`searchSessions`/`openHostSessionID`/`beginRenameCurrentSession`/`renameCurrentSession`/`forkCurrentSession`/`forkSession`/`copySessionID`/`deleteSession`/`archiveCurrentSession`/`newSession`/`insertLocalSessionRow`/`clearToDefaultPage`/`attachHostSessionToCurrentPlaceholder`/`selectSession`/`openHostSession`/`syncSessionScopedState`，265 行）搬进既有 `DSHSessionActions.swift`（之前只有 wire types）。main.swift：2131 → 1752 行（含批次 2）。
     - 这批的可见性坑比批次 2 更多、且是两个方向都有：① 搬走的方法里，`copySessionID` 用 `NSPasteboard`，补 `import AppKit`。② `@Published private(set) var isRunning`（带 `didSet`）、`hostCurrentSessionID` 的 setter 跨文件不可见，去掉 `private(set)`（`isRunning` 的 `didSet` 观察者本身不受影响，只是访问级别变了）。③ 反方向的新坑——搬走的方法反过来调用**留在 main.swift 里**的私有方法：`openHostSession` 调 `loadHistory`、`syncSessionScopedState` 调 `loadSubagents`/`loadSkills`，这三个是 private，都留在 main.swift（属于"历史/消息解析"以后的批次），去掉它们的 `private`——不代表它们已经不是"内部实现细节"，只是这个多文件架构下 `private` 已经没法表达"仅这个功能域内部用"这层意思了，只能靠文件组织本身来体现。④ 搬走的 `insertLocalSessionRow` 原来是 private，但 main.swift 里 `send()` 还在调它（不在这批范围内），也要去掉 private——这是批次 2 没遇到的方向：不仅"移走的方法调用留下的 private 方法"要修，"留下的方法调用移走的 private 方法"也要修，两个方向都得靠 typecheck 逐条抓。
     - 验证：typecheck + `--unit`（12/12）+ build + `--smoke` 全过。
   - ✅ **批次 4 已完成**：历史/消息解析 20 个成员（`loadSkills`/`loadCommands`/`refreshSlashCatalog`/`loadMessageFeedback`/`loadPluginInventory`/`setFeedback`/`loadSubagents`/`loadHistory`/`loadOlderHistory`/`foldHistory`/`reasoningFromMessage`/`historyPresentation`/`attachmentFromMessage`/`textFromMessage`/`historyMessage`/`messageSourceKind`/`historyIsRelayMessage`/`userDisplayText`/`anyValue`/`textFromValue`，271 行）搬进既有 `DSHHistory.swift`（之前只有 wire types：`DSHJSONValue`/`DSHHistoryEntry`/`DSHHistoryPage`/`DSHHistoryPayload`）。main.swift：1752 → 1479 行。这批不少成员（`loadSubagents`/`loadSkills`/`loadHistory`）在批次 3 时就已经因为"被移走的方法调用"而提前去掉了 `private`，这批真正移动它们时反而没再踩这方面的坑，纯粹是搬运；新踩的两个是同一种模式的延续——`foldHistory`（`loadSubagentTranscript` 在 main.swift 里调）、`userDisplayText`（`consumeMuxFrame` 在 main.swift 里调）搬走后也各去掉一次 `private`。
     - 验证：typecheck + `--unit`（12/12）+ build + `--smoke` 全过。
   - ✅ **批次 5 已完成**：子代理/工作流 7 个成员（`currentSubagentParentID`/`openSubagent`/`navigateUpSubagent`/`loadSubagentTranscript`/`selectWorkflow`/`openWorkflowMember`/`interruptSubagent`，71 行）搬进既有 `DSHSubagents.swift`（之前只有 wire types）。main.swift：1479 → 1405 行。这批第一次没有跨文件可见性问题——typecheck 一次过，没有一处需要去掉 `private`/`private(set)`；引用的 `foldHistory`/`loadSubagents` 都已经在前两批放开过。
     - 验证：typecheck + `--unit`（12/12）+ build + `--smoke` 全过；额外用隔离的（`isolation: 'worktree'`）对抗式 review workflow 复核过这批 diff——代码本身逐字节比对确认是纯移动、跨代码库 grep 确认没有遗漏的调用点，抓到的唯一一条是这份 Note 自己数错数（写"6 个成员"实际列了 7 个，漏数了 `currentSubagentParentID` 这个 computed property；顺带发现批次 2 也有同样的错，"9 个成员"实际是 10 个，一并改了）——纯文档计数问题，不是代码 bug，已修正。这次 review 全程隔离在独立 worktree 里，没有再重演 Phase 1 review 那次污染实时工作目录的事故。
   - ✅ **批次 6 已完成**：目标/审批/问题 9 个成员（`performGoalAction`/`alwaysAllowKey`（static）/`answerApproval`/`deferPendingQuestion`/`presentDeferredQuestion`/`answerQuestionBatch`/`applyProjectedTitle`/`refreshAttentionBadge`/`appendSystem`，89 行）搬进既有 `DSHGoalActions.swift`（之前只有 goal 相关 wire types）。main.swift：1405 → 1315 行。范围比域名更宽一点——`appendSystem`/`refreshAttentionBadge` 严格说是"系统消息/提醒角标"工具方法，不是 goal 专属，但和 goal/approval/question 这几个方法搭配 `appendSystem` 一起用，拆开放会更零碎，就一起搬了（`appendSystem` 本身是全代码库共用的工具方法，实测 `macos/DSHApp/` 下真实调用点有 38 处、分布在 8 个文件里，这批只占 5 处——不是"深度耦合、大半在这批"，只是搬运时顺手把这几个耦合最紧的方法带过去）。`refreshAttentionBadge` 也被 main.swift 里留下的 `consumeMuxFrame`（Host 事件流批次还没做）调用，一样去掉 `private`。`appendSystem` 本来就是特意标了"Internal, not private"（`NativeWorkspaceChips.swift` 也要用），这批不用再改。
     - 验证：typecheck + `--unit`（12/12）+ build + `--smoke` 全过；隔离 worktree 的对抗式 review 复核过——代码本身干净（纯移动，无遗漏调用点），抓到的是这份 Note 自己写错的 `appendSystem` 调用点统计（原文声称"17 处、大半在这批"，实测 38 处、这批只占 5 处），已按上面改法修正——把这次教训直接吸取进正文措辞，不是简单改个数字了事。这也是把这个 review 脚本从批次 5 那次的一次性写法改成了参数化、可复用的通用脚本（`ds-harness-phase2-batch-review`），后续批次可以直接传目标文件/符号列表/行数变化复用，不用每次重写 prompt。
   - ✅ **批次 7 已完成**：模型/preset 4 个成员（`selectCurrentModel`/`setPreset`/`nativeProviderDisplayName`/`toolDetail`，49 行）搬进既有 `DSHModels.swift`（之前只有模型目录 wire types）。main.swift：1315 → 1263 行。踩坑跟批次 2 同类——`providerKey`/`modelKey`/`reasoningEffortKey`/`presetKey` 这 4 个文件作用域 `private let` 常量（`workspaceKey` 批次 2 时已经放开，这 4 个当时留着没动）被 `selectCurrentModel`/`setPreset` 用到，一起去掉 `private`，5 个 UserDefaults key 常量现在全部是模块内可见。
     - 顺手核实了一件事：`@Published` 真实数量是 **69**，不是六个批次以来一直在报的"68"——那是外部评审截图给的数字，从第一份 Note 起没人重新数过，是和批次 6 那次 appendSystem 调用数写错同一类问题（抄了个没验证的数字）。这次是自己核实出来的，已经把本 Note 里所有提到这个数字的地方都改成 69。
     - 验证：typecheck + `--unit`（12/12）+ build + `--smoke` 全过；隔离 worktree 的对抗式 review 复核过——纯移动无遗漏调用点，唯一一条发现是 `toolDetail(_:)` 在全代码库里零调用点（`grep` 确认，含 `dist/`/`DSHTests/`）——这是移动前就存在的死代码，不是这次搬运引入的，先如实记录，留给以后专门的死代码清理批次处理，不在这批顺手删（范围外改动）。
   - ✅ **批次 8 已完成**：设置/凭据 6 个成员（`openProviderAuthoring`/`openSettingsEditor`/`saveSettings`/`saveCredential`/`unsetCredential`/`advertisedEffort`，37 行）搬进既有 `DSHSettingsActions.swift`（之前已有 `openHostSettingsDocument`/`mutateSettings`，这批新增第二个 `extension HarnessController` 块，没有合并进第一个，避免打乱已验证过的既有内容）。main.swift：1263 → 1226 行。这批比较特殊：分属两处不相邻的位置（`openProviderAuthoring`…`unsetCredential` 在 282-307 行，中间隔着一大段 `@Published` 属性声明 + `init()` + 计算属性 + `WorkspaceSessionGroup` 结构体；`advertisedEffort` 单独在 456-465 行），逐块用 `sed -n 'START,ENDp'` 精确切界搬出、再从原位置分别删除（先删后面那块、再删前面那块，避免行号错位）。第一次没有触发任何跨文件可见性错误——`mutateSettings`/`refreshModelConfiguration` 早就不是 `private`（前者是 `DSHSettingsActions.swift` 本来就有的方法，后者在批次 3/4 期间就因为别的原因放开过），typecheck 一次过。
     - 再现了一次 Note 里记录过的批次 1 教训：用 `{ printf ...; cat ...; printf ...; cat ...; } > file` 拼接新 extension 块时，shell 交互式包装层又把终端转义序列写进了文件（`grep -c 033` 命中、Read 工具看到文件内容混入了命令回显文本）——同一个坑踩了第二次。这次没有污染任何生产文件：损坏只发生在中间产物（先写到临时文件再 diff 校验，发现问题时 `DSHSettingsActions.swift` 还没被覆盖），改用「Write 工具写纯文本 header/footer 文件 + 只用 `cat file1 file2 file3` 拼接真实文件（不用 printf/echo，不用花括号分组）」重做一遍，diff 校验干净后才落盘。教训作为经验记录在这里而不是重开一条——本质和批次 1 是同一条规则，这次只是没有严格执行到位。
     - 验证：typecheck + `--unit`（12/12）+ build + `--smoke` 全过；隔离 worktree 对抗式 review 待跑。
   - ✅ **批次 9 已完成**：发送/队列 7 个成员（`loadAttachment`/`pickImage`/`send`/`mutateQueue`/`queueDraft`/`stop`/`stopForTermination`，190 行，main.swift 里原本连续的一整块 1018-1210 行）按子域拆到三个文件，不是单一文件——这批第一次没有沿用"整块搬进一个既有文件"的模式：`loadAttachment`/`pickImage` 搬进既有 `DSHAttachments.swift`（本来就有 `DSHAttachmentRef`/`DSHAttachmentStore`，附件读取/选择自然同源）；`mutateQueue`/`queueDraft` 搬进既有 `DSHQueue.swift`（本来就有 `DSHQueueItem`/`DSHQueueAction` 等 wire types）；`send`/`stop`/`stopForTermination` 三个没有天然既有归宿（没有"发送" wire-type 文件），新建 `DSHSendActions.swift`——这是 Phase 2 第一次为方法迁移新建文件而非并入既有文件，符合 CLAUDE.md "新状态/新逻辑写成 DSH<Feature>.swift" 的既定约定，不是破例。main.swift：1263 → 1032 行（含批次 8）。
     - `send()` 是这批里最大最核心的一个方法（~130 行，覆盖懒建会话、slash 命令分发、图片附件编码、Host prompt 提交等全部发送路径），也是全项目目前搬得最长的单个方法。踩了两个新的跨文件可见性坑：① `isCreatingFirstSession`（`private var`，`send()` 内部用于防止懒建会话期间重复触发，读写都要跨文件）——去掉 `private`。② `hostRuntime`（`stopForTermination()` 需要调 `hostRuntime?.stop()`，只读不写）——最初直接去掉 `private` 改成普通 `var`，被隔离 worktree 对抗式 review 抓到：`stopForTermination()` 只读不写，普通 `var` 却把写权限也一并放开给了全模块任何一个 `DSH<Feature>.swift`，跟这份 Note 当时写的"只是放开读取权限"这句话对不上——已改成 `private(set) var`（setter 仍私有、只有同文件内的 `startPersistentHost` 能赋值，getter 放开供跨文件读），补过一轮 typecheck + `--unit` + build + `--smoke` 全绿。
     - 又踩了一次这份 Note 记录过的批次 1 教训：用 `{ printf ...; cat ...; } > file` 拼接新 extension 块时 shell 交互式包装层又把终端转义序列写进了文件——这是第二次踩同一个坑（第一次是批次 8）。没有污染生产文件（中间产物阶段就用 `grep 0x1b` 查出来并作废），改用「Write 工具写 header/footer 纯文本文件 + 只用 `cat 真实文件` 拼接（不掺 printf/echo/花括号分组）」重做，这次还加了一步 Python 逐字节扫描 `\x1b`（比批次 8 单纯目测更可靠的验证手段）确认干净后才落盘。这条坑目前已经踩了两次，以后每批的拼接步骤都必须走这个「纯 cat + 逐字节扫描」流程，不能再凭记忆手写 printf。
     - 验证：typecheck + `--unit`（12/12）+ build + `--smoke`（含写路径）全过；隔离 worktree 对抗式 review 待跑。这批是纯搬运、零行为改动——`send()` 本身逻辑一字未改，只是换了文件；写路径的运行时验证仍然只到 `settings.update` 这一条（Phase 1 就有的已知覆盖缺口），没有专门为这批新增 `prompt`/`send` 的运行时 smoke，评估后认为对等价的纯移动改动不需要新增测试基建，风险由"逐字节 diff 确认搬运前后代码完全一致"这一步兜底。
   - ✅ **批次 10 已完成（最后一批）**：Host 生命周期与事件流 18 个成员——`seedConfigurationFromUserDSHIfNeeded`/`startPersistentHost`/`consumeMuxFrame`/`applyLiveEvent`/`applyLiveSubagentEvent`/`liveMessagePayload`/`liveSourceKind`/`liveIsRelayMessage`/`liveMessageText`/`consumeHostFrame`（10 个，事件流/帧消费子域）+ `refreshPresets`/`selectCurrentPreset`/`activePresetLabel`/`refreshSettings`/`refreshSessionModels`/`refreshModelConfiguration`/`reconnectHostStreams`/`refreshHostSnapshots`（8 个，Host 状态刷新子域，比原计划成员列表多了 `activePresetLabel`——一个和 `selectCurrentPreset`/`refreshPresets` 紧耦合的 computed property，物理位置就夹在两者中间，一起搬比拆开更连贯），main.swift 里原本连续的一整块 527 行（490-1016 行）。事件流子域并入既有 `DSHEventSocket.swift`（本来就是这个流的传输层类，消费逻辑搬进来后主题更完整）；状态刷新子域新建 `DSHHostSync.swift`（没有天然既有归宿）。main.swift：1032 → 504 行。这是全部 10 个批次里最大的一批，也是耦合最深的一批——`main.swift` 的历史债拆分到此为止，17 个批次（其中 10 个是方法搬运）全部完成。
     - 可见性坑是目前最多的一批，因为这批第一次触碰到"写者搬出去、@Published 状态还留在原地"的情况：① `hostStatus`/`hostSessions`/`hostWorkspaces` 三个 `@Published private(set)` 属性——写者（`startPersistentHost`/`consumeMuxFrame`/`consumeHostFrame`/`refreshHostSnapshots`）全部搬出 main.swift，去掉 `private(set)`。② `hostRuntime`——批次 9 时刚改成 `private(set)`（因为当时只有 main.swift 内的 `startPersistentHost` 写它），这批 `startPersistentHost` 本身也搬出去了，`private(set)` 的"同文件可写"条件不再成立，改回普通 `var`（这次不是重复批次 9 的错误：批次 9 时"只放开读权限"是准确的，这批因为写者本身也换了文件，`private(set)` 才变得不再适用——用途不同，不是同一个坑踩两次）。③ `hostEvents`/`muxEvents`（`private var`）——`startPersistentHost`/`reconnectHostStreams` 都要写，两者都搬出主 main.swift，去掉 `private`。④ `resources`/`runtime`/`bundledNode`/`bundledDSH`（`private var` 计算属性，只有 `startPersistentHost` 用）——写者搬出，去掉 `private`；`dshHome` 本来就不是 private（批次 8 之前就有别的文件在用）不用动。⑤ `consumeMuxFrame`/`consumeHostFrame`（原来是 `private func`）——`reconnectHostStreams`（搬进了另一个文件 `DSHHostSync.swift`）需要把它们注册进新建的 `DSHEventSocket` 回调闭包里，跨文件调用，去掉 `private`。⑥ `seedConfigurationFromUserDSHIfNeeded`/`startPersistentHost`（原来是 `private func`）——main.swift 里留下的 `init()` 仍然要调这两个方法，跨文件调用，去掉 `private`。
     - 这批也是拼接步骤第一次严格照着批次 8/9 教训里定下的流程走（Write 工具写 header/footer 纯文本、只用 `cat 真实文件` 拼接、落盘前 Python 逐字节扫描 `\x1b`），两个新文件（`DSHEventSocket.swift` 追加、`DSHHostSync.swift` 新建）都一次成功，没有再踩第三次转义污染的坑。
     - 验证：typecheck（0 error）+ `--unit`（12/12）+ build + `--smoke` 全过——这批尤其看重 `--smoke`：它启动打包后的真实 Host 并通过 `DSHHostClient` 建立连接、拉设置快照，这条路径正是 `startPersistentHost`/`DSHEventSocket` 消费逻辑搬运后要保持能跑通的东西，不是碰巧顺带覆盖，是这批最相关的运行时信号。隔离 worktree 对抗式 review 待跑。
3. ✅ `main.swift` 现在只剩 App 入口 + `HarnessController` 类声明 + `@Published` 属性 + `init()`/`deinit` + 少量计算属性（`sessionGroups`/`dshHome` 等），504 行，远低于 < 800 行的目标。没有额外加 `// MARK:` 分区——剩下的内容本身已经是单一连贯的"状态声明 + 生命周期"区块，不再有多个不同功能域混杂在一起需要用注释分区导航，加分区反而是为了加而加。
4. （可选、单独开 Note）69 个 `@Published` 分组为子 ObservableObject——改变刷新语义、风险高，不并入本计划。

### Phase 2 rebase 冲突：合并进 main 前重新对齐

批次 1 提交后 rebase 到最新 origin/main（这期间 main 又推进了 8 个提交，包含一个新落地的跨会话消息中继功能 `feat(session-relay)`），main.swift 撞上一处真实的内容冲突：中继功能同时改了 `MessageBubble`（.user 分支加"来自其他会话"标签）和 `Composer`（`onCommit` 里加一行 `voiceDiag` 调试日志）——这两个 struct 恰好是批次 1 刚搬进 `ConversationView.swift` / `ComposerView.swift` 的。Git 没法把"改某个 struct"的 patch 自动重定向到它被搬去的新文件，冲突整块摊在 main.swift 里（`<<<<<<< HEAD` 側是 main 上完整未拆分的版本，`>>>>>>>` 側是空——我这边整段删掉了）。

解法：把冲突 HEAD 側（main 当前的完整视图区块）和批次 1 之前保存的原始区块逐行 diff，精确定位出只有这两处改动，手工把这两处改动分别搬进 `ConversationView.swift`（`MessageBubble`）和 `ComposerView.swift`（`Composer`），main.swift 侧仍然整段删除（拆分意图不变）。Rebase 完成后 main.swift 变成 2131 行（不是原来算的 2101——中继功能也在 HarnessController 类体里加了 `isRelayMessage` 字段、`pendingVoiceTaskFocusID`、`liveIsRelayMessage`/`historyIsRelayMessage` 两个方法，这部分完全在我没碰的区域，rebase 自动合并干净，只是让基线数字往上多长了 30 行）。Gate 基线、CLAUDE.md、这份 Note 三处同步改成 2131。`build-macos-app.sh` 那次也有 upstream 改动（新增 in-house cordis 插件打包逻辑），插入点跟我加的构建锁完全不重叠，rebase 自动合并没冲突。

**教训**：main.swift 分批拆分和"main 分支持续有其他 session 在加功能"这两件事本质上是在赛跑——批次拖得越久，rebase 时踩中"upstream 改了我正在挪的 struct"的概率越高。这次是运气好，只中了两处、且改动本身很小；批次 2 开始前也要重新拉一次 main 再看冲突面。

### Phase 2 执行事故：非隔离 review workflow 的并发写入

Phase 1 的 adversarial review workflow（`wams8yndi`）没加 `isolation: 'worktree'`，agent 对同一份工作目录有实时读写权限，而它还在跑的时候我已经开始动手做 Phase 2——期间连续两次撞见它的 agent 直接改了我正在编辑的文件：一次把 `DSHProjectionsTests.swift` 里的期望值改成明显错误的 999（大概率是在验证"这条断言是不是重言式"时的副作用，后来又自己改回了 17）；一次是 `NativeDashboard.swift`/`SessionOpsViews.swift` 被加了 `.bak` 备份文件、`DetailsPanel`/`SessionSearchView` 的 `private` 被顺手去掉（凑巧是我下一步正要做的修改，但发生的时间点和方式都不受控），外加一个我从没写过的 `macos/DSHTests/DSHZZZScratchTests.swift` 冒出来。发现后用 `TaskStop` 把这个 workflow 直接停了，删掉 `.bak` 和 scratch 文件，逐文件 diff 核对没有其他污染，才继续往下做。

**教训**：以后任何会长时间跑、且没有明确"纯只读"保证的 review/analysis workflow，只要主 session 打算在它跑完之前继续碰同一批文件，必须传 `isolation: 'worktree'`——"review workflow 不会写文件"是一个假设，不是这个 workflow 框架给的保证（agent 可能为了验证假设去复现、去改、去建 scratch 文件）。Phase 0 那次 review workflow 没出这个问题是运气好（那次没有和它并发做其他编辑）。

### 并行协调

- 本 session 直接做 Phase 0 + Phase 1（全程不碰 main.swift）。
- Phase 0 合并进 main 后，两个功能 session 重读 CLAUDE.md 自然拿到冻结令；在此之前由用户转告一句："新 view/新状态不要进 main.swift，一律新文件/extension"。
- Phase 2 等它们合并后单独 session 做，冻结令保证冲突面只缩不涨。

## Alternatives considered

- **一次性大重构（拆分 + 测试一起上）**：与两个在途功能 session 冲突面最大、回归风险集中在一个窗口 → 分阶段，把高冲突的拆分排最后。
- **引入 SwiftPM `Package.swift` 跑 `swift test`**：推翻 [2026-08-14-no-xcode-project](../../implemented/architecture/2026-08-14-no-xcode-project.md) 决策，重新引入双源列表漂移风险 → 先用 swiftc 自编 test runner；若测试规模长到 harness 不够用，再单独开 Note 重新评估。
- **只写规范、不加脚本 gate**：AGENTS.md "avoid growing main.swift further" 已经证明无强制力的规范会失效 → 每条硬规范必须配可执行检查。
- **@Published 拆子 ObservableObject 并入 Phase 2**：改动面从"搬代码"升级为"改刷新语义"，回归风险不同量级 → 拆出去单独决策。
- **UI 自动化测试（XCUITest 等）现在就上**：没有 Xcode 工程，成本最高、收益排最后 → 先把单测和读写 smoke 立起来，UI 自动化另行评估。

## Consequences

- **main.swift**：3364 → 504 行（-2860，-85%）。只剩 App 入口（`DSHNativeApp`）+ `HarnessController` 类声明 + 全部 `@Published` 状态 + `init()`/`deinit` + 少量核心计算属性（`sessionGroups`/`dshHome` 等）。没有加 `// MARK:` 分区——剩下的内容评估后判断已经是单一连贯的"状态声明 + 生命周期"区块，加分区没有实际导航收益。
- **新增/大幅扩充的文件**：`ContentView.swift`/`SidebarView.swift`/`ConversationView.swift`/`ComposerView.swift`（批次 1，view 层）；`DSHWorkspaceActions.swift`/`DSHSessionActions.swift`/`DSHHistory.swift`/`DSHSubagents.swift`/`DSHGoalActions.swift`/`DSHModels.swift`/`DSHSettingsActions.swift`（批次 2-8，既有文件新增 `extension HarnessController`）；`DSHSendActions.swift`/`DSHHostSync.swift`（批次 9-10，全新文件，没有既有 wire-type 文件可并入）；`DSHAttachments.swift`/`DSHQueue.swift`/`DSHEventSocket.swift`（批次 9-10，既有文件扩充）。
- **main.swift 冻结令现在有实质约束力**：gate 基线从 3364 一路下调到 504，新代码想绕开"写进 extension"的规则会立刻被 `test-macos-native.sh` 拦下来，不再是纸面规范。
- **验证深度**：`--unit`（12 个断言）+ 扩展后的 `--smoke`（含 `settings.update` 写路径）+ CI 五步流水线全部落地并在本地跑通；10 个 Phase 2 批次每批都过 typecheck + `--unit` + build + `--smoke`，最后一批的 `--smoke` 还实际验证了这批搬运的 Host 连接建立路径。
- **可见性代价**：`private`/`private(set)` 在这个"按功能域拆文件"架构下已经普遍无法表达"仅内部使用"，只能靠文件组织本身体现意图——这是分批过程中反复验证到的架构性权衡，不是某一批的失误。批次 9→10 之间 `hostRuntime` 从 `private(set)` 又改回普通 `var`（因为写者本身也搬到了另一个文件）是这个权衡的典型例子。
- **已知遗留项**（不在本计划范围内，留给后续按需处理）：`DSHModels.swift` 的 `toolDetail(_:)`、`DSHAttachments.swift` 的 `loadAttachment(_:)` 是两处移动前就存在的死代码（零调用点），批次 7/9 review 各自发现；69 个 `@Published` 属性未拆分为子 `ObservableObject`（见下方 Alternatives，改变刷新语义、风险不同量级，需要单独一份 Note）。
- **过程性收获**：识别并修复了一个会反复复现的 shell 拼接坑（`{ printf ...; cat ...; } > file` 会把终端转义序列写进文件）——最终固化为「Write 工具写 header/footer 纯文本 + 只用 `cat 真实文件` 拼接 + 落盘前逐字节扫描 `\x1b`」的标准流程；也把一次性 review workflow 脚本改造成了参数化、可复用的通用脚本（`ds-harness-phase2-batch-review`）。

## Risks（历史记录，实施期间的风险评估）

- 行数 gate 基线写死数字，功能 session 若在合并前仍向 main.swift 加码会先撞 gate——这是预期行为（止血），已通过用户知会缓解，实施期间未造成阻塞。
- swiftc 自编 test runner 是非标准方案，断言/报告能力有限；目前 12 个断言规模下够用，规模长大后可能需要迁移（已在 Alternatives 中预留重评估路径）。
- Phase 2 纯机械搬运确实反复踩到 `private`/`fileprivate` 可见性问题（10 个批次里 8 个批次都有至少一处），全部靠 typecheck 逐批暴露、逐批修复，没有遗漏到运行时才发现的情况。

## Phase 0 review notes（多 agent 交叉验证，2026-08-18）

Phase 0 落地后跑了一轮独立 review（4 个维度并行找问题 + 每条发现两票对抗式复核），3 条实锤，已修复并重新验证：

1. **gate 遇到 main.swift 缺失会裸崩**（`scripts/test-macos-native.sh`）——`wc -l < "$MAIN_SWIFT"` 在 `set -euo pipefail` 下如果文件不存在，会在赋值语句上直接触发 `errexit`，跳过整个 if 块，看到的是裸 bash 报错而不是"新状态该去哪"的引导文案。修复：先 `[[ -f "$MAIN_SWIFT" ]]` 判断，给出明确报错。已用 `mv main.swift` 模拟验证。
2. **`wc -l` 在末行缺换行符时少算一行**（同文件，nit 级）——边界情况下 gate 可能"虚假 OK"放过超限一行。修复：`wc -l` 换成 `awk 'END{print NR}'`（已用真实文件对比验证两者输出一致，且 awk 版本在无尾换行的构造用例上仍能算对）。
3. **`build-macos-app.sh` 的孤儿清理和并发构建冲突**——两个 session 同时跑构建脚本时，一方的清理扫描可能删掉另一方正在写入的 stage 目录，或在 swap 窗口内删掉另一方的 `.previous` 备份，造成构建报废甚至丢失上一个可用版本。这条不是假设性风险：CLAUDE.md 自己的「多 Agent 并行」一节明确鼓励多个 session 同时在同一 checkout 里工作，且 Step 1 验证要求每个 session 都跑这个脚本。修复：加了目录锁（`mkdir dist/.build.lock` 原子占锁 + `trap` 释放），后来者等待而不是报错或互相破坏；已用"预置锁 → 确认第二个调用阻塞等待 → 释放锁 → 确认它继续跑完 → 确认无 stage/lock 残留"完整模拟验证。

Review 同时提交了一条 AGENTS.md 文首 repo-layout 图仍写 main.swift 持有"每个顶层 View"的 nit，复核判定这段是既有的目录结构说明、和"新代码不许进 main.swift"的冻结规则不矛盾，不算真实问题，未采纳。
