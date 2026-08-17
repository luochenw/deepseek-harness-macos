# 工作规约（Claude）

本项目由 **Claude 全程负责**开发闭环：读 Host RPC 协议、设计原生功能、写 Swift、编译验证、自测、收尾。代码风格与架构约定见同目录 [AGENTS.md](AGENTS.md)。

## 角色

- **Claude（你）**：从 spec 到落地全包——读 [macos/WEB_PARITY.md](macos/WEB_PARITY.md) 认领一项差距或新功能、写决策记录（Agent Note）、实现、编译验证、自测、收尾。

## Spec-Coding 方法论

这个项目的上游 [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) 有一套自己的 **Agent Notes**（`.agents/notes/`）——把每个非平凡决策的 Problem / Decision / Alternatives considered / Consequences 写成一份短文档，而不是只留在 commit message 或聊天记录里。本仓库借用同一套约定（简化版，规模匹配这个项目），放在 [`.agents/notes/`](.agents/notes/)：

- **动手写代码前**：先确认这个改动是否"非平凡"——改变行为、改协议对接方式、新增/删除一个功能域、改变状态管理方式。非平凡就先写一份 Agent Note 到 `.agents/notes/proposed/<class>/`（新功能／`feature`，bug 修复／`bug-fix`，简化删除／`simplification`，结构决策／`architecture`）。琐碎改动（改一个字符串、修一处笔误、调整间距）不需要。
- **Note 里必须讲清楚**：
  - `## Problem` —— 现状缺什么 / 哪里错了，独立于方案也能看懂
  - `## Proposal`（`proposed/`）或 `## Decision`（做完后移到 `implemented/`，改成现在时）—— 具体要做什么
  - `## Alternatives considered` —— **必填**，每个被放弃的方案配一句"为什么不选它"。没有这一节等于给未来的自己（或另一个模型）埋了一个"要不要重新做一遍"的坑
  - `## Consequences`（implemented）或 `## Acceptance criteria` + `## Risks`（proposed）
- **完工后**：把文件从 `proposed/` 移到 `implemented/`，`## Proposal` 改写成现在时的 `## Decision`，`Status:` 行同步。
- **格式**：文件头三行固定
  ```markdown
  # Agent Note: <标题>

  Status: proposed | implemented | rejected — <一句话原因>
  ```
- 完整格式细节见上游 [`.agents/notes/README.md`](.agents/notes/README.md)（本仓库直接复用其文件头 + body 骨架约定，去掉了上游为大型团队设计的自动化 gate 脚本和 archived/ 生命周期，这两块对当前规模不必要）。

写 Agent Note 不是额外负担——它就是"写代码前先想清楚"的产出物，比脑子里想一遍更抗遗忘，也是让另一个 agent（或人类贡献者）接手时不用重新逆向工程一遍决策原因的唯一办法。

## 写代码前先想清楚

1. 读清楚相关 Swift 源码和 Host RPC 协议（`macos/DSHApp/DSHHostProtocol.swift` 定义了 envelope + client；具体某个 RPC method 的语义去 `work/deepseek-harness-reference`——本机的上游 monorepo 只读参考副本——的 `packages/` 里找，或 `docs/`）。范围大就起 `Explore` 子 agent 并行探。
2. 复杂功能先写 Agent Note（见上）想清楚目标、约束、验收标准。
3. 对照 [macos/WEB_PARITY.md](macos/WEB_PARITY.md) 确认这个改动完成后要不要更新那张表。

别"想都没想就开干"。

## 多 Agent 并行

这个代码库是**按功能域拆文件**的（见 AGENTS.md），天然适合并行：

- **只读 / 探查**：读 RPC 协议、读上游 `work/deepseek-harness-reference` 参考副本、方案调研——大胆并行用 `Explore` / `general-purpose` 子 agent，互不冲突。
- **写代码并行**：不同功能域（比如"补 diff 渲染卡片"和"补 workflow 详情钻取"）分属不同的 `DSH<Feature>.swift` / `Native<Feature>View.swift` 文件 → 可以并行改，互不覆盖。**`main.swift` 不再是"例外可以碰"，而是冻结**——新状态/新逻辑/新 View 一律不进这个文件，规则见下面「质量规范」。这同时也解决了并行冲突：大家都不往同一个文件里写，天然没有冲突面。
- 一律直接在当前分支上改（这是个人维护的开源项目，不强制 worktree/PR 流程），但落笔前 `git status` 确认没有别的改动会被覆盖。

## 质量规范

- **main.swift 冻结**：`main.swift` 只保留 App 入口、`HarnessController` 类声明与核心生命周期——新的 `@Published` 状态、controller 方法、顶层 View **一律不再**写进这个文件，哪怕是"核心流程"。新状态/新逻辑写成 `DSH<Feature>.swift` 里的 `extension HarnessController`（没有对应文件就新建一个）；新界面写成独立的 `<Feature>View.swift` / `Native<Feature>View.swift`。这条规则配了 gate，不是口头约定：`./scripts/test-macos-native.sh` 会检查 `main.swift` 行数不超过基线，超了直接报错退出。
- `main.swift` 的历史债正在分批拆分中（拆一批、gate 基线跟着下调一批，当前 2020 行），进度与决策见 [Agent Note](.agents/notes/proposed/architecture/2026-08-18-quality-remediation-plan.md)。
- 改行为的代码（不是纯文档/纯 UI 文案）优先带上能验证的手段——现阶段是契约 fixture（`NativeContractCheck.swift`）+ smoke（`--smoke`），单测基建落地后（见上面 Note 的 Phase 1）新逻辑改动要带对应单测。

## CLAUDE.md 组织方式：不拆子目录

新功能不要另开一份子目录 CLAUDE.md（比如 `macos/DSHApp/CLAUDE.md`）。原因：

- Claude Code 的子目录 CLAUDE.md 是**按文件所在目录懒加载**的（读到那个目录下的文件才加载），不是按文件名。这个仓库恰恰是"按功能域拆*文件*、不拆*目录*"（见上面「多 Agent 并行」）——`NativeDashboard.swift`、`NativeAttachmentPreview.swift`、`main.swift` 全在同一个 `macos/DSHApp/` 目录下，放一份目录级 CLAUDE.md 起不到"只在改这个功能时才加载"的效果，跟直接写进根 CLAUDE.md 没区别，纯增加维护成本。
- 官方按目录拆分是给真正的 monorepo/多包仓库用的（`packages/api`、`packages/web` 各自有独立构建/测试栈），参考 [Set up Claude Code in a monorepo or large codebase](https://code.claude.com/docs/en/large-codebases)。这个项目是单一 Swift target，没有这种边界。
- 这份文件目前 100 出头行，远低于官方建议的 200 行拆分阈值（[Write effective instructions](https://code.claude.com/docs/en/memory#write-effective-instructions)），没有"太长导致遵从率下降"的压力，不需要为了拆而拆。

以后如果真要拆，按这个优先级：

1. **先考虑 `.claude/rules/*.md` + `paths:` frontmatter**——按 glob 匹配文件而非目录，更贴合这个项目"按文件名前缀分功能域"的组织方式（比如给 `Native*.swift` 单开一份规则）。
2. **只有新增一个真正独立的子系统**（新 target、独立 CLI 工具、单独的 docs 站点，有自己的构建/测试流程）才值得为它开一份子目录 CLAUDE.md——这才对得上 monorepo 那套场景。

## 开发与收尾流程

**规则**：直接在 `main` 分支开发，不强制 feature 分支（外部贡献者提 PR 除外，见 README 的 Contributing）。

任务做完，**验证 → 自查 就停下**，把改动报告给用户，**等用户明确说「提交」/「推送」再走提交 → 推送**。改完一件事先停，用户没说提交就只改不提交。

#### Step 1 — 本地验证（必须过）

```bash
./scripts/test-macos-native.sh          # swiftc -typecheck 全部生产源码 + Info.plist lint
./scripts/build-macos-app.sh            # 实际构建（涉及运行时行为的改动才需要）
./scripts/test-macos-native.sh --smoke  # 启动打包后的 Host，验证只读 API（构建后才需要）
```

- 纯文档（`*.md`、Agent Note）改动可跳过构建
- 任何一步报错 → 停，修完再重跑这一步

#### Step 2 — 自查（闸门，别跳）

1. `git diff` 通读改动
2. 跨功能域 / 新协议对接 / 改了 `HarnessController` 核心状态时，跑 `/code-review` 做一遍审查
3. 确认对应 Agent Note 状态已经从 `proposed` 挪到 `implemented`（如果适用），[macos/WEB_PARITY.md](macos/WEB_PARITY.md) 已更新

#### Step 3 — 提交（等用户发话）

- Commit message 前缀：`feat / fix / refactor / chore / docs`，`<type>(<scope>): ...`，scope 用功能域名（`subagents`、`settings`、`build`…）
- 一次任务一个 commit，不 amend
- HEREDOC 形式传 message，带 `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`

#### Step 4 — 推送（等用户发话）

```bash
git push origin main
```

### 硬禁区

- ❌ 不要 `--no-verify` 跳过任何 hook
- ❌ 不要 `git push --force`，除非用户明说
- ❌ 自查有 blocking 问题时不要提交/推
- ❌ 不要把 `work/`、`outputs/`、`wb_*`、`lark_doc.*` 等散件加入 git —— 这些是这个目录里遗留的、和 app 项目无关的临时文件，`.gitignore` 已排除，别用 `git add -A`/`git add .` 把它们捡回来；一律按文件名精确 `git add`

## 发布（GitHub Release）

这是个开源项目，发布指"打一个 tag + GitHub Release"，不是内部部署平台。

```bash
cd dist && ditto -c -k --keepParent "DeepSeek Harness.app" "DeepSeek-Harness-<version>-arm64.zip" && cd ..
gh release create v<version> \
  --title "v<version>" \
  --notes-file <release-notes.md> \
  "dist/DeepSeek-Harness-<version>-arm64.zip"
```

- Release **附带 ad-hoc 签名的 zip**（arm64，未 notarize）——决策见 [Agent Note](.agents/notes/implemented/architecture/2026-08-17-adhoc-release-distribution.md)。Release notes 必须写清 Gatekeeper 首次打开步骤（隐私与安全性 → 仍要打开，或 `xattr -rd com.apple.quarantine`），并给出「从源码构建」替代路径。
- 以后拿到 Developer ID 后升级为签名 + notarize + DMG，并补 Homebrew cask；流程不变，只换打包一步。
- 每次发版前确认 Step 1 的三条验证命令都过。

## 速查

| 场景 | 命令 |
|------|------|
| 类型检查（无需构建） | `./scripts/test-macos-native.sh` |
| 构建 | `./scripts/build-macos-app.sh` |
| 构建后冒烟测试 | `./scripts/test-macos-native.sh --smoke` |
| 自查代码 | `git diff` / `/code-review` |
| 提交 | `git commit`（等用户发话） |
| 推送 | `git push origin main`（等用户发话） |
| 发布 | `gh release create`（仅用户说「发布」时） |
