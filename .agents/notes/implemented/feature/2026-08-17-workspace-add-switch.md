# Agent Note: 工作区新增 / 切换 / 管理入口

Status: implemented — 侧栏工作区菜单：切换 / 添加现有目录 / 新建 / 管理

## Problem

Host 侧的工作区能力（workspace.create / rename / delete、workspace 列表
快照）协议对接早已完成，但 UI 入口残缺：

- 侧栏"工作区"只有一个按钮，点了直接弹系统目录选择器（chooseWorkspace），
  唯一的另一入口是菜单栏 ⌘W。没有任何地方能看到 Host 里已注册的
  工作区列表，也不能一键切换——想换回上一个工作区还得在文件系统里
  重新找一遍目录。
- 没有"从零新建一个工作区"的流程（起个名字、选个父目录、建目录并
  注册）；NSOpenPanel 虽然带"新建文件夹"按钮，但藏得深，不成其为
  功能。
- `WorkspaceManagerView`（列出 Host 工作区、重命名、删除）写完后
  从未被任何视图引用，是死代码。

## Decision

侧栏的工作区按钮升级为菜单（新视图 `WorkspaceSwitcherButton`，与
sheet 一起放在 WorkspaceManagerView.swift——工作区功能域文件）：

1. **切换**：菜单顶部列出 `hostWorkspaces`（当前项打勾），点击即
   `registerWorkspace(path)`——对已注册路径 Host 幂等返回 created:false，
   等价于选中。
2. **添加现有目录…**：走既有 chooseWorkspace 面板。
3. **新建工作区…**：本地 sheet——父目录（默认当前工作区的父目录或
   用户主目录，可用面板另选）+ 名称输入 + 完整路径预览；确认后
   FileManager 建目录（withIntermediateDirectories）再 registerWorkspace。
   建目录失败在 sheet 内联报错。
4. **管理工作区…**：sheet 包一层标题/关闭按钮，内嵌既有
   WorkspaceManagerView（重命名/删除），死代码就地复活。

sheet 状态全部用视图本地 @State，不给 HarnessController 加 @Published
（main.swift 只需要把侧栏那一个 Button 换成 `WorkspaceSwitcherButton()`，
一行改动，避开并行会话的高冲突区）。

## Alternatives considered

- **给 HarnessController 加 showNewWorkspace @Published + 菜单栏命令**：
  菜单栏命令必须经 controller 状态中转，要改 main.swift 的核心状态区；
  侧栏入口已覆盖需求，不值得为一个次要入口去碰高冲突文件。
- **只加"新建"不做切换列表**：hostWorkspaces 数据现成，列表+打勾是
  这个菜单的自然形态；只做新建会让"已注册了哪些工作区"继续不可见，
  下次还得再开一轮。
- **切换时直连 workspace 状态（不走 registerWorkspace）**：会绕过
  UserDefaults 持久化和 status 反馈，重复一遍同样的逻辑；Host 的
  create 对已存在路径本就是幂等选中语义。

## Consequences

- main.swift 那一行替换被并行会话的 commit d471765 顺带扫入，本次
  commit 补齐它引用的 WorkspaceSwitcherButton 实现，使 main 恢复自洽。

## Acceptance criteria

- 侧栏工作区菜单能列出所有 Host 工作区并切换，当前项有标记。
- "新建工作区…"能在选定父目录下创建新目录并注册为工作区，非法名称
  （空、含路径分隔符）被拦住，失败有内联错误提示。
- "管理工作区…"能重命名/删除 Host 工作区。
- `./scripts/test-macos-native.sh` 与构建、冒烟全过。

## Risks

- 并行会话正在改 main.swift：把 main.swift 接触面压到单行替换，落笔
  前重读该区域。
- 删除工作区的确认交互沿用 WorkspaceManagerView 现状（直接删），
  不在本次加确认框——如需要另起一轮。
