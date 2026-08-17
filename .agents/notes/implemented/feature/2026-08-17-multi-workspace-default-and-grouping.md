# Agent Note: 多工作区切换、会话按工作区分组、默认工作区

Status: implemented

## Problem

原生客户端目前把"工作区"当成单一全局状态：`HarnessController.workspace: URL?`，只能通过侧栏一个"选择工作区"按钮弹 `NSOpenPanel` 来设置，没有列出/切换到已经注册过的其他工作区的入口——即使 Host 早就支持多工作区（`workspace.list`/`workspace.create`/`workspace.rename`/`workspace.delete` 全套 RPC，`DSHWorkspaceView` 还自带 `sessionIds: [String]` 字段），`WorkspaceManagerView.swift` 目前只用这份数据做重命名/删除列表，从没用来"切换当前工作区"。

`workspace == nil` 时 `canSend` 直接为 false（main.swift:381），发送按钮全灰——新用户第一次打开必须先手动选一个文件夹才能发第一条消息，没有默认工作区兜底。

会话列表（Sidebar `sessionSection`）是纯平铺的 `hostSessions`，不管有几个工作区，所有会话混在一起，找不出哪条消息属于哪个项目。

## Decision

- **默认工作区**：`HarnessController.init()` 里，UserDefaults 没有保存过工作区路径时，自动创建并使用 `~/Documents/DeepSeek Harness`（`FileManager` 的 `.documentDirectory`），跟从 UserDefaults 恢复走同一条轻量路径（只设置本地 `workspace` + 写 UserDefaults，不在 `init()` 里调 Host RPC——这时候 `hostClient` 还没建好）。真正在 Host 侧登记这个工作区，交给已有的 `newSession()` → `createSession(cwd:)` 流程自然完成（Host 按 cwd 自动关联/创建工作区，这条路径原本就是这么工作的，恢复用户上次工作区时也没有另外调 `registerWorkspace`）。`canSend` 的判断条件不用改——`workspace` 现在几乎不会是 nil。
- **工作区切换**：`HarnessController` 新增 `selectWorkspace(_ ws: DSHWorkspaceView)`，只切本地 `workspace` 指针 + 写 UserDefaults（不需要重新注册，因为它已经在 `hostWorkspaces` 里，说明 Host 那边已经存在）。
- **Sidebar 工作区区域**：原来的单个"选择工作区"按钮换成 `Menu`——列出 `harness.hostWorkspaces` 每一项（点了调 `selectWorkspace`），加一条"添加工作区…"（原来的 `chooseWorkspace()`，还是走文件选择器）。`WorkspaceManagerView`（重命名/删除）保留不动，两者分工不同：一个管"切到哪个"，一个管"改名/删除"。
- **会话按工作区分组**：用 `DSHWorkspaceView.sessionIds` 反查每条 `hostSessions` 属于哪个工作区，渲染成按工作区分小节的列表（小节标题用 caption/secondary，不用 Divider，跟 DESIGN_SYSTEM.md 一致）；找不到归属工作区的会话（比如早于工作区功能存在的旧会话）归到一个不带标题的"其他"兜底分组，如果全部会话都没有工作区归属（`hostWorkspaces` 为空或没匹配上任何一条），就不显示任何小节标题，退化成原来的平铺列表，不为了分组而分组。
- 本地（非 Host）会话列表 `harness.sessions` 那条 fallback 分支不做分组——那是 Host 未连接时的占位列表，本来就没有工作区概念。

## Alternatives considered

- **默认工作区指向 app 沙盒/DSH_HOME 目录**（比如 `dshHome` 底下建个子目录）：更"隐蔽"、用户在 Finder 里翻不到，不如 `~/Documents/DeepSeek Harness` 直观、跟其他 app 的常见默认目录约定一致，用户还能随时在 Finder 里直接找到、扔文件进去。
- **在 `init()` 里直接调 `registerWorkspace`/Host RPC 建默认工作区**：`hostClient` 在 `init()` 阶段还没建好（`startPersistentHost()` 是 init 最后一步，异步启动），调了也是空跑；交给已有的 `newSession()` 流程自然处理，不用额外重复一遍注册逻辑。
- **用一个单独的 Workflow 多 agent 来并行做 Sidebar 改造和 WorkspaceManagerView 改造**：评估过，这两块 UI 决策耦合太紧（工作区"切换"这个概念到底该长在哪个控件上，两个文件的设计如果分头做很容易互相打架、出来两套不一致的交互），比起 Settings/主窗口那两轮"每个 View 互相独立、只要保绑定不丢"的情形不一样,这次核心逻辑改动也在 main.swift（`HarnessController`），按仓库约定本来就要串行做，就没有拆并行 agent，自己写完这一整块。

## Consequences

- `./scripts/test-macos-native.sh`、`./scripts/build-macos-app.sh`、`./scripts/test-macos-native.sh --smoke` 三层验证全过。
- 全新用户（UserDefaults 里没有工作区记录）打开 app，`workspace` 自动指向 `~/Documents/DeepSeek Harness`（首次用 `FileManager` 创建），发送按钮不再需要先手动选文件夹才能用。
- 侧栏"工作区"从单个按钮换成 `Menu`：列出 `harness.hostWorkspaces` 每一项（当前选中的带 checkmark），"添加工作区…"复用原有的 `chooseWorkspace()` 文件选择器流程，不用重新实现。`WorkspaceManagerView`（改名/删除）原样保留，两者分工清楚。
- 会话列表按 `DSHWorkspaceView.sessionIds` 反查分组，小节标题用 caption2/tertiary 文字，没有用 `Divider()`；只有一组且是"其他"兜底分组时自动隐藏所有标题，退化成原来的平铺列表。
- 本地 `harness.sessions` fallback 分支（Host 未连接时）没有分组，保持原样——那条路径本来就没有工作区概念。
- **实现中途改正一处**：最初分组用的是 `DSHWorkspaceView.sessionIds` 反查，写完之后直接看了本机 `~/Library/Application Support/DeepSeek Harness/dsh/storages/workspace.json`，发现一个已经有会话在跑的工作区，`sessionIds` 字段实际是空数组——Host 并没有像预期那样维护这个列表。改成用 `DSHSessionSummary.cwd` 直接比对 `DSHWorkspaceView.path`（在 `session_projcache.json` 里确认了 `cwd` 字段确实逐会话记录的），这个信号是可靠的。

## Risks

- 默认工作区目录如果被用户手动删除（不通过 app），下次启动 `workspace` 还是指向那个不存在的路径——跟原来"从 UserDefaults 恢复但目录已被删"的边界情况是同一个已有风险，没有变得更糟，暂不额外处理。
- 会话到工作区的归属完全依赖 `DSHWorkspaceView.sessionIds` 这个字段的准确性，这是 Host 维护的数据，客户端只读不写；如果 Host 端这个字段有延迟/不同步，分组可能短暂不准，但比完全不分组还是更有信息量。
