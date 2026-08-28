# Agent Note: 右侧多标签开发工作台

Status: implemented — 会话级多标签工作台、WebKit 浏览器和原生 Markdown 阅读器已落地

## Problem

当前主窗口右侧只有一个固定 330pt 的 `DetailsPanel`。它在“执行 / Agent /
工具”之间切换，适合短信息检查，但不能承载需要持续状态和更大阅读面积的
开发对象，例如本地网页、公共网页、工作区 Markdown 文档以及后续的终端、
代码或差异预览。

开发者因此需要频繁在 App、外部浏览器、Finder 和文档应用之间切换。右栏
也被绑定成 Agent 结果详情入口，用户无法把它当作自主打开内容的常驻工作区。

## Decision

现有右侧详情栏升级为会话级 `Workbench`。它仍是主窗口内的右侧 dock，
但拥有可调宽的分栏、多标签页和按内容类型变化的工具栏。首版支持：

- 内置浏览器；
- 原生只读 Markdown 文档阅读器；
- 现有执行详情；
- Agent Profile 管理；
- 工具调用详情。

工作台不是 Agent 产物抽屉。用户可以通过标签栏的 `+`、菜单命令、快捷键、
Markdown 链接或文件上下文菜单主动打开内容。关闭右栏只折叠 dock，不销毁
标签与运行状态。

## Product model

### Scope

标签按顶层会话隔离。切换会话时恢复该会话在当前 App 进程中的标签、选中项、
Markdown 滚动位置和浏览器页面状态；查看 Subagent 时继续使用所属顶层会话
的工作台，子代理工具详情标签额外记录 child session id。

首条消息发送前的默认页使用本地 placeholder session key。Host session 创建
成功后，把该上下文迁移到 durable session id。关闭标签、删除或归档会话时释放对应
`WKWebView`，避免后台页面和媒体继续占用资源。

首版不跨 App 重启恢复标签列表。这样可以避免把带 token/query 的 URL
持久化到明文配置，也避免重启时自动重放可能有副作用的网页请求。面板宽度
可全局持久化；浏览器 cookie 使用 App 自己的 WebKit 数据存储，与系统
浏览器隔离。后续若增加标签恢复，需要先定义 URL 脱敏和懒加载策略。

### Tab kinds

`DSHWorkbenchTab.Kind` 使用有限枚举，而不是运行时插件协议：

- `execution`：当前根会话的 Batch 与运行详情，每个会话最多一个；
- `agents`：全局 Agent Profile 管理，每个会话最多一个入口；
- `tool(sessionID, callID)`：指定根会话或 child 的工具详情；
- `browser`：由 tab id 关联一个持有稳定 `WKWebView` 的浏览上下文；
- `markdown(path)`：标准化绝对路径对应的只读文档。

内置单例标签重复打开时直接聚焦。Markdown 以标准化路径去重。工具行单击
复用一个未固定的预览标签，点击固定按钮后变成独立标签，避免长会话
被每个 tool call 填满。浏览器 `+` 每次创建新标签。

### Entry points

- 对话头部现有 `sidebar.right` 按钮改为显示/隐藏工作台；首次打开且没有标签
  时创建“执行”标签。
- 标签栏 `+` 菜单提供“新建浏览器”“打开 Markdown…”“执行”“Agent”。
- `showAgentManagement()` 聚焦或创建“Agent”标签。
- `openExecutionWorkbench()` 聚焦或创建“执行”标签。
- `toolDetail(_:)` 打开工具预览标签，不再覆盖整个右栏模式。
- `.md` 文件交付卡、Markdown 相对链接和文件选择器提供“在工作台打开”。
- `Command-Shift-B` 新建浏览器标签；地址栏获得焦点后支持 `Command-L`。
- Host 常驻注册 `open_workbench_browser` 与 `open_workbench_markdown` 两个
  模型工具。原生端只消费实时事件：普通调用缓存 `tool/call`，等成功
  `tool/result` 后打开；Code Mode 使用成功的 `tool/code-dispatch`。失败、
  取消、断线与历史回放都不会打开标签。

## Layout

左侧会话栏维持 290pt。对话列与工作台之间使用原生可拖拽分隔条：

- 对话列最小 500pt；
- 工作台最小 360pt、理想 520pt、最大 900pt；
- 打开工作台时优先保住对话列最小宽度，再使用上次宽度；
- 当前窗口最小宽度下仍保留可用对话列和至少 360pt 工作台；
- 关闭后对话列立即占满剩余空间，重新打开恢复宽度。

工作台从上到下只有三层：

1. 36–40pt 标签栏：横向滚动标签、`+`、全部标签菜单、折叠按钮；
2. 内容工具栏：随 Browser / Markdown / Execution 类型变化；
3. 内容区：不再套额外外层卡片。

标签使用图标、单行标题和 hover 时出现的关闭按钮。选中标签使用
`DSHTheme.sidebarSelected` 的轻微青绿洗色和清晰前景色；未选中标签保持
中性透明。标签不是胶囊，不给每个标签独立阴影。工作台不引入新的圆角
数值：外层使用 `DSHRadius.lg`，输入与主要控件使用 `DSHRadius.md`，标签和
紧凑图标按钮使用 `DSHRadius.sm`，只有状态和模式 chip 使用胶囊。工作台
边缘使用细描边和现有半透明层级表达果冻厚度，不在内部内容区重复套卡片。

## Browser

每个 Browser 标签拥有一个长期存活的 `WKWebView`，由工作台状态对象缓存，
不能在 SwiftUI `body` 重算或标签切换时重建。否则页面 JS、表单、滚动位置、
前进后退栈和登录状态都会丢失。

Browser 工具栏包含后退、前进、停止/刷新、地址栏和在默认浏览器打开。
地址输入会补全缺失 scheme：`localhost:*` 与 IP 默认使用 `http`，
其他主机默认使用 `https`。`target=_blank` 在工作台中新建 Browser 标签。

Browser 是用户操控的独立浏览器；模型只能请求把地址展示给用户：

- 网页正文不会自动加入 prompt 或 Agent 上下文；
- Agent 不能注入脚本、点击页面、读取 DOM 或获得页面正文；
- `file://` 不用于工作区文件阅读，本地文件交给原生预览器；
- 用户主动创建的 Browser 标签可把非 HTTP(S) scheme 交给 `NSWorkspace`；
- 模型请求创建的 Browser 标签把初始地址、重定向、新窗口和下载持续限制为
  HTTP(S)，不能升级为 `file:` 或外部应用 scheme；
- 本地 HTTP 只增加最窄的 local-network ATS 能力，不启用全局任意明文加载；
- TLS 证书失败不做“全部信任”旁路，错误页提供在系统浏览器打开；
- Web content process 退出时显示可恢复错误并提供重新载入；
- 下载使用原生保存面板，不静默写入工作区。

未来若让 Agent 操控浏览器，必须另立功能域，增加按 host 显式授权、可见的
控制状态、随时停止入口和“不把网页指令当系统指令”的内容边界。

## Markdown reader

Markdown 使用 SwiftUI/AppKit 原生渲染，不把整个 App 或文档阅读器变成
WebView。现有 `NativeMarkdownText.swift` 的解析和 block view 会抽成可复用
层，保留 transcript 的紧凑模式，并新增 document 模式。

首版 document 模式覆盖标题、段落、强调、链接、列表、任务列表、引用、
围栏代码、表格和本地相对图片。行为如下：

- 相对 `.md` 链接在新 Markdown 标签打开；
- `http/https` 链接在新 Browser 标签打开；
- `#anchor` 在当前文档滚动；
- 其他本地文件走工作台未来的通用文件预览或系统默认应用；
- 相对资源以文档目录为基准解析；
- 模型请求的文档、后续重载、相对文档链接与本地图片都在解析符号链接后
  限制于事件来源会话的 cwd；用户手动打开的文档不受这条模型边界影响；
- 模型文档与本地图片使用同一只 `O_NOFOLLOW` 文件描述符完成类型、大小、
  `F_GETPATH` 边界校验和读取，避免校验与读取之间被替换；
- 大文件和不可解码文件显示明确错误，不阻塞主线程；
- 文件删除、移动、权限变化分别显示可操作状态。

每个 Markdown 标签监听文档所在目录的文件系统变化，短暂 debounce 后后台
重读；标签状态显式保存滚动位置。工具栏提供路径、目录大纲、
刷新、在 Finder 显示和用默认应用打开。阅读器不编辑文件，因此不存在未保存
状态，也不与 Agent 的写入产生冲突。

## State and ownership

`main.swift` 保持冻结，不增加状态、方法或 View。新增：

- `DSHWorkbench.swift`：tab/content/context 模型、controller registry、
  会话上下文迁移与打开/关闭 API；
- `WorkbenchView.swift`：dock、标签栏、空态和内容路由；
- `NativeBrowserView.swift`：`WKWebView` bridge、navigation/download
  delegate 和 Browser 工具栏；
- `NativeMarkdownDocumentView.swift`：文件加载、监听、document renderer；
- 必要时把 `NativeMarkdownText.swift` 的 parser/block renderer 抽成共享类型。

`DSHWorkbenchState` 使用与 `DSHSubagentProjection` 相同的
`ObjectIdentifier(HarnessController)` registry 模式，并通过 controller 的
`objectWillChange` 通知 SwiftUI。这样遵守 main freeze，又不会把工作台状态
错误塞进 `DSHAgentPlatformState`。

现有 `showDetails` 只作为 dock visibility 兼容位；所有新入口通过
`openExecutionWorkbench`、`openAgentsWorkbench`、`openToolWorkbench`、
`newBrowserWorkbench`、`openMarkdownWorkbench` 和 `toggleWorkbench` 操作。
旧的 `detailsPanelMode` 与 `selectedTool` 状态已经移除。

## Existing details migration

旧 `AgentPlatformDetailsPanel` 和顶部 segmented picker 已拆除：

- `AgentPlatformExecutionView` 直接成为 Execution tab 内容；
- `AgentPlatformProfilesView` 直接成为 Agent tab 内容；
- `NativeDashboard` 与 `NativeToolPresentationView` 成为 Tool tab 内容。

Agent 平台的 Host RPC、选中 Batch/Run、日志和 workspace inspection 状态不
改变。工作台只是新的容器和路由层，不能借此重写 Agent 平台业务逻辑。

## Key states

- **无标签**：显示两个紧凑入口“浏览器”“打开 Markdown”，不放功能说明卡。
- **标签溢出**：标签栏可水平滚动，“全部标签”菜单始终可达。
- **Browser loading**：地址栏显示真实 URL，刷新按钮变停止，顶部细进度线。
- **Browser error/crash**：错误原因、重试、在系统浏览器打开。
- **Markdown loading**：轻量骨架；文件读取不阻塞 UI。
- **Markdown changed**：自动刷新并短暂显示“已更新”。
- **Markdown missing/denied/too large**：显示路径和对应恢复动作。
- **会话切换**：原会话页面状态保留，新会话上下文原子切换。
- **关闭 dock**：标签保持；Browser 可继续加载，但音视频页面在后台暂停。
- **关闭 tab**：选择右侧相邻标签，否则左侧；最后一个关闭后进入空态。

## Accessibility and keyboard

- `Command-Option-Left/Right` 切换标签；
- 图标按钮都有中文 accessibility label 和 help；
- Browser 保留网页自身 Tab 顺序；
- Markdown 正文支持选择，目录菜单可跳转标题。

## Implementation

1. **Workbench shell**：实现 session-scoped tab state、可调宽 dock，并把现有
   Execution / Agent / Tool 迁入标签。
2. **Browser**：实现稳定 WebView 生命周期、地址导航、local HTTP、错误恢复、
   新窗口和下载。
3. **Markdown**：扩展共享 parser，增加文档模式、任务列表、标题目录、文件监听、
   相对链接与本地图片。
4. **Integration polish**：增加交付文件入口、菜单快捷键、工具预览固定、浅色/
   深色/多宽度 UI snapshot 和本地 HTTP server WebKit smoke。

## Alternatives considered

- **继续扩展单一 DetailsPanel mode。** Rejected：Browser 和文档需要长期状态，
  mode 切换会不断覆盖用户上下文，也无法同时保留多个对象。
- **把 Browser / Markdown 做成独立窗口或 Sheet。** Rejected：它们无法与对话
  并排持续查看，窗口管理成本也违背“Codex 式右侧工作区”目标。
- **使用系统默认浏览器和 Markdown App。** Rejected：仍然需要频繁切换应用，
  也无法建立会话级标签上下文和统一链接路由。
- **全部内容都用 WKWebView。** Rejected：项目是原生 macOS 客户端；执行详情
  和本地文档没有必要进入 Web 渲染层，文件访问与主题也更难控制。
- **把新状态加入 HarnessController/main.swift。** Rejected：main 已冻结且有
  自动 gate；registry 模式已在会话投影中验证可用。
- **首版直接加入终端、代码编辑器、PDF、图片和 diff。** Rejected：会同时引入
  PTY、编辑保存、Quick Look 和大型资源生命周期，先把可扩展宿主和两个核心
  内容类型做稳，再逐项增加。
- **启动时恢复所有 Browser 标签并立即加载。** Rejected：URL 可能含敏感参数，
  自动重放页面也可能产生副作用；首版只做进程内会话恢复。

## Consequences

- 右侧工作台可收起、恢复和拖动宽度；宽度保存在 `dsh.workbench.width`，并在
  窗口最小尺寸下优先保留 500pt 对话区域。
- 同一会话可同时保留至少 10 个混合标签，切换后 Browser 页面状态和 Markdown
  阅读位置不重置。
- 切换顶层会话不会串用标签；切回后恢复原状态；首次 Host session 创建时
  placeholder 上下文无损迁移。
- `localhost` 开发页可在 Browser 中加载、刷新、前进后退；新窗口打开为新标签；
  页面崩溃、加载失败和下载都有原生恢复路径。
- Markdown 可主动选择，不依赖 Agent 产物；磁盘更新后自动刷新，相对文档链接、
  Web 链接和本地图片按规则路由。
- 模型可通过两个真实 Host 工具请求打开 Browser / Markdown 标签；原生端在
  成功结果后执行，后台会话不会抢当前焦点，重复或历史事件不会重放；子会话
  元数据晚于工具结果到达时会缓存并在 Host/Batch 刷新后重试。
- Execution / Agent / Tool 现有能力和 RPC 行为不回归。
- `main.swift` 不增长；新增 Swift 文件自动进入现有 `swiftc` glob。
- `main.swift` 保持在 489 行 freeze gate 内，没有放宽门禁。
- 新增 19 个工作台单测、360/520/760pt 浅色快照、520pt 深色快照、1180pt
  完整窗口快照，以及本地 HTTP server 的真实 `WKWebView` smoke。

## Residual risks

- `WKWebView` 若被 SwiftUI 重建会静默丢状态，必须用稳定 runtime cache 验证。
- 多个活跃网页可能消耗大量内存和音视频资源，需要后台暂停与 tab 关闭释放策略。
- 外部编辑器的特殊保存策略仍可能产生多次短时事件；文件与父目录双监听会
  debounce 重读，但不承诺捕获网络文件系统的全部非标准通知行为。
- 工作台宽度增加后，现有 1180pt 最小窗口可能使对话过窄；布局测试必须覆盖
  最小、常用和宽屏尺寸。
- Browser 未来若接入 Agent 控制会引入 prompt injection 和站点权限边界；本
  Proposal 明确不把该能力混进首版。
