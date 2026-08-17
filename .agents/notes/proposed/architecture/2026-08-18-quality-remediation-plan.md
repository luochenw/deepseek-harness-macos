# Agent Note: 质量债修复计划 —— 规范补强 + 验证深度 + main.swift 拆分

Status: proposed — Phase 0/1 已完成，Phase 2 仍待做，需等在途功能 session 合并后串行做

## Problem

外部质量评审指出两类真实短板，已逐条核实（2026-08-18）：

1. **验证深度不足**：0 单元测试、0 UI 测试；"契约测试"只是编译时 fixture（`NativeContractCheck.swift`，能编译 ≠ 行为正确）；smoke 只覆盖只读 API（`verify-native-host-api.sh`），prompt / settings.update / subagent 等读写路径零覆盖；CI（`.github/workflows/ci.yml`）只跑 typecheck，不构建、不冒烟。
2. **main.swift 是架构债**：3364 行单文件 = HarnessController（68 个 `@Published`）+ 30 个顶层 view struct 混在一起，零 `// MARK:` 分区、零 `extension`。AGENTS.md 写了 "rather than growing main.swift further"，但同一文件又允许 "inline in main.swift for core flows"，且没有任何强制手段——规范落空的制度性原因。
3. 次要：主 checkout 的 `dist/` 里有构建中断残留的 stage 目录；`.agents/notes/proposed/simplification/` 是空目录（均为未跟踪本地产物，不在 git 里）。

根因：CLAUDE.md 管住了**流程**（先想清楚、写 Note、验证命令、提交纪律），但没有**质量规范**——没有测试要求、没有文件结构约束、没有 CI 深度要求，且唯一一条 main.swift 约束没有 gate。

## Proposal

按"冲突面从小到大"分三阶段，兼容当前两个在途功能 session：

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
2. **进行中**：HarnessController 方法按域拆成 `extension` 到对应 `DSH<Feature>.swift`（沿用项目既有模式，只是执行彻底）。main.swift 目前 2131 行里，HarnessController 类体还有 91+ 个方法 + 68+ 个 `@Published` 属性没动；已经按名字前缀/主题分好域（设置/凭据、Host 生命周期与事件流、会话管理、历史/消息解析、工作区、发送/队列、模型/preset、子代理/工作流、目标/审批/问题）。
3. `main.swift` 只留 App 入口 + HarnessController 类声明与 `@Published` 属性 + 核心生命周期，目标 < 800 行，配 `// MARK:` 分区——还没到，当前 2131 行。
4. （可选、单独开 Note）68 个 `@Published` 分组为子 ObservableObject——改变刷新语义、风险高，不并入本计划。

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

## Acceptance criteria

- Phase 0：CLAUDE.md/AGENTS.md 规范落地；`test-macos-native.sh` 对 main.swift 增行直接报错；`build-macos-app.sh` 不再累积 stage 残留。
- Phase 1：`--unit` 在本地与 CI 可跑且有第一批真实断言；smoke 覆盖至少一条写路径；CI 包含 build + unit + smoke。
- Phase 2：main.swift < 800 行、有 MARK 分区；全部批次 typecheck + build + smoke 通过；WEB_PARITY.md 与相关 Note 状态同步。

## Risks

- 行数 gate 基线写死数字，功能 session 若在合并前仍向 main.swift 加码会先撞 gate——这是预期行为（止血），但需要用户提前知会那两个 session。
- swiftc 自编 test runner 是非标准方案，断言/报告能力有限；规模长大后可能需要迁移（已在 Alternatives 中预留重评估路径）。
- Phase 2 纯机械搬运仍可能踩到 `private`/`fileprivate` 可见性问题，typecheck 会暴露，逐批处理。

## Phase 0 review notes（多 agent 交叉验证，2026-08-18）

Phase 0 落地后跑了一轮独立 review（4 个维度并行找问题 + 每条发现两票对抗式复核），3 条实锤，已修复并重新验证：

1. **gate 遇到 main.swift 缺失会裸崩**（`scripts/test-macos-native.sh`）——`wc -l < "$MAIN_SWIFT"` 在 `set -euo pipefail` 下如果文件不存在，会在赋值语句上直接触发 `errexit`，跳过整个 if 块，看到的是裸 bash 报错而不是"新状态该去哪"的引导文案。修复：先 `[[ -f "$MAIN_SWIFT" ]]` 判断，给出明确报错。已用 `mv main.swift` 模拟验证。
2. **`wc -l` 在末行缺换行符时少算一行**（同文件，nit 级）——边界情况下 gate 可能"虚假 OK"放过超限一行。修复：`wc -l` 换成 `awk 'END{print NR}'`（已用真实文件对比验证两者输出一致，且 awk 版本在无尾换行的构造用例上仍能算对）。
3. **`build-macos-app.sh` 的孤儿清理和并发构建冲突**——两个 session 同时跑构建脚本时，一方的清理扫描可能删掉另一方正在写入的 stage 目录，或在 swap 窗口内删掉另一方的 `.previous` 备份，造成构建报废甚至丢失上一个可用版本。这条不是假设性风险：CLAUDE.md 自己的「多 Agent 并行」一节明确鼓励多个 session 同时在同一 checkout 里工作，且 Step 1 验证要求每个 session 都跑这个脚本。修复：加了目录锁（`mkdir dist/.build.lock` 原子占锁 + `trap` 释放），后来者等待而不是报错或互相破坏；已用"预置锁 → 确认第二个调用阻塞等待 → 释放锁 → 确认它继续跑完 → 确认无 stage/lock 残留"完整模拟验证。

Review 同时提交了一条 AGENTS.md 文首 repo-layout 图仍写 main.swift 持有"每个顶层 View"的 nit，复核判定这段是既有的目录结构说明、和"新代码不许进 main.swift"的冻结规则不矛盾，不算真实问题，未采纳。
