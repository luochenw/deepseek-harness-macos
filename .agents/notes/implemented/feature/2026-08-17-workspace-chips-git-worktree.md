# Agent Note: 工作区 chips 与 Git 分支 / worktree 集成

Status: implemented — 工作区从侧栏移到会话上下文位；分支切换与 worktree 创建进入 App

## Problem

工作区展示在左侧栏（`WorkspaceSwitcherButton`），与会话无空间关联；新对话
看不到"接下来要在哪个目录、哪个分支上干活"；顶部还是 macOS 原生标题栏，
放不下任何会话上下文。App 对 Git 一无所知——用户要换分支/开 worktree 得
去终端，回来再手动切工作区。

## Decision

- 参照 Codex 的工作区 chips：`[📁 目录] [⎇ 分支 | worktree] [＋]` 胶囊组。
  **新对话**（transcript 无用户/助手消息）时显示在输入框上方；**已有会话**
  时收进页面顶部的自定义 header。侧栏不再展示工作区。
- 窗口切到 `.hiddenTitleBar`，自定义 header（原 ConversationHeader）成为
  真正的页面顶部；侧栏顶部留出红绿灯按钮的空间。
- 新增 `DSHGitOps`（`Process` 调 `git`，同步调用放后台线程）：读当前分支/
  分支列表/是否 worktree；`checkout` 切分支；`worktree add` 在
  `<repo>-worktrees/<branch>` 创建并通过既有 `registerWorkspace` 切换过去。
- Git 状态是**视图本地**的（chips view 的 `@State` + `.task(id: path)`），
  不进 `HarnessController`——沿用 workspace-add-switch note 的先例，避免
  再往 main.swift 的核心状态里加字段。

## Alternatives considered

- **把 git 状态放进 HarnessController @Published**：所有消费者只有 chips
  一个，进核心状态徒增 main.swift 串行编辑面积。
- **用 libgit2 / SwiftGit**：单 swiftc target 无包管理器（见
  no-xcode-project note），Process 调系统 git 零依赖且行为与用户终端一致。
- **分支切换用弹窗确认**：chips 菜单本身就是显式选择动作，checkout 失败
  （脏工作区等）会以系统消息回报，不静默。
- **保留侧栏工作区入口**：与 chips 双入口互相抢职责；侧栏回归"会话列表"
  单一职责。

## Consequences

- 换分支/开 worktree 不用离开 App；worktree 创建后工作区自动切换，
  新会话即在 worktree 中运行。
- checkout 直接作用于用户仓库（等同终端 `git checkout`），脏树会失败并
  报错——这是特性不是缺陷。
- 非 git 目录 chips 只显示目录名，分支 chip 隐藏。
