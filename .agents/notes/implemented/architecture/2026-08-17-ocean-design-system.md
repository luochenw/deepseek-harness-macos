# Agent Note: 引入海域设计令牌体系，替换全应用的分割线/散点圆角为色块分区

Status: implemented

## Problem

`macos/DSHApp` 没有任何设计系统层：没有共享的 `ViewModifier`、没有自定义
`ButtonStyle`、没有可复用的 `Card`/`Badge` 组件。每个文件各自定义颜色、圆角、
间距——圆角在 6/7/8/9/10/12/14 之间随意取值，内边距在 8~28 之间随意取值，
颜色全部是内联的 SwiftUI 语义色（`.cyan`/`.mint`/`.orange`/`.teal`/`.secondary`）
叠加随手选的透明度。区域划分（侧栏 / 对话区 / 详情面板）完全依赖
`Divider()`——`ContentView` 里三处竖线分割三栏，`ConversationHeader`/
`ConversationView`/`Composer` 之间再各一条横线，`DetailsPanel` 内部选中工具时
又一条。整体视觉是系统默认灰调，没有品牌辨识度，也没有经过留白/对齐/层级
的整体设计。

此外探查代码时发现两处可顺手改善、用户也确认要做的信息架构问题：

1. `Sidebar` 的会话列表（`main.swift:1491-1516`）是一条不分组的平铺
   `List`，混合了跨工作区的所有会话——多项目并行时无法一眼看出哪些会话
   属于哪个工作区。
2. `MessageBubble`（`main.swift:1559-1568`）把推理过程塞进答案气泡内部的
   `DisclosureGroup`，折叠状态、正文状态视觉上是同一张卡片，用户扫读时
   分不清"模型在想"和"模型说的话"这两类完全不同性质的内容。

## Decision

新增 `DSHTheme.swift`，作为全应用唯一的视觉令牌来源：

- **配色**：赤道海域主题，柔和低饱和版本（第一版样机做了深潟湖靛青侧栏 +
  海沫白画布，用户反馈"方向对，但要更柔和/更浅淡"，第二版据此下调）。
  浅色模式下侧栏不再用深色实色块，改用比画布略深一档的浅海雾绿色调
  （区域仍靠色深区分，但不制造强对比）；深色模式侧栏比画布更深，但整体
  亮度、饱和度同步收窄，避免纯黑/纯高饱和撞色。用 `NSColor(name:
  dynamicProvider:)` 包装出的动态 `Color`，随系统外观自动切换，不依赖
  Asset Catalog（本项目没有 Xcode 工程，见 AGENTS.md）。
- **圆角刻度**：收敛到 `DSHRadius.sm/md/lg/xl`（8/12/16/22）四档，替换现有
  的随意取值。
- **间距刻度**：收敛到 `DSHSpace.s1~s7`，4 的倍数（4/8/12/16/24/32/48）。
- **可复用组件**：`.dshCard(tint:radius:)`（背景色卡片，无描边）、
  `DSHBadge(text:tone:)`（替换 `NativeToolPresentationView.swift` 里私有的
  `Card`/`Badge`）、`DSHStatusDot(kind:)`（`live`/`unread`/`idle`/`success`/
  `failure` 五态）、`.dshSectionLabel()`（分区小标题）、`.dshPrimary`/
  `.dshSecondary`/`.dshGhost` 三档 `ButtonStyle`，以及审查阶段补上的
  `.dshField(tint:radius:)`（单行输入框统一背景，见下方 Consequences）。
  全部供 40 个文件里被改动的 12 个调用，替换掉原本散落在
  `NativeToolPresentationView.swift`、`NativeDashboard.swift`（六个各自
  实现底色的卡片 struct）里重复的实现。
- **区域分区**：`ContentView` 三栏之间、`Composer`/`ConversationHeader`
  与对话区之间的 `Divider()` 全部移除，改由三个区域各自的背景色块自然
  分隔；卡片内部同理用背景色代替描边。

功能性调整（视觉重构过程中一并做，用户已确认）：

- `Sidebar` 会话列表按 `hostWorkspaces[].sessionIds` 对 `hostSessions`
  分组显示（`HarnessController.sessionGroups`），每个工作区一个色块分区，
  当前工作区分区排在最前；不在任何工作区 `sessionIds` 里的会话归入"其他"
  分区；`hostSessions` 为空时保留现有 `sessions`（本地回退）平铺展示，
  不分组。
- `MessageBubble` 拆成两个独立视觉区域：一个用于推理过程的
  `ReasoningBlock`（弱化底色、等宽字体、默认折叠，不再是气泡内部的
  `DisclosureGroup`），渲染在答案气泡上方，同一条消息对齐方式一致但两者
  不共享同一张卡片背景。

## Alternatives considered

- **用 Asset Catalog 定义颜色集**：Rejected——本项目刻意不用 Xcode 工程
  （见 `.agents/notes/implemented/architecture/2026-08-14-no-xcode-project.md`），
  引入 `.xcassets` 需要额外的资源打包步骤和 `swiftc` 参数改动，与"零工程
  文件、纯 `*.swift` glob 编译"的既有约定冲突。纯代码定义的动态
  `NSColor` 能达到同样的浅色/深色自动切换效果，零额外构建步骤。
- **保留深色实色侧栏，只是把它也用在浅色模式**：Rejected——用户在样机
  反馈阶段明确要求"更柔和/更浅淡"，深色实色块在浅色模式下对比度过强，
  不符合"高级精致感、注意留白"的要求。
- **推理过程完全移出消息流，做成详情面板里的独立卡片**：Rejected——
  推理过程是这一条回答的上下文，离开消息流单独放到详情面板会让用户失去
  "这段思考对应哪条回答"的空间关联；改成同一条消息流里视觉独立但位置
  相邻的两个区域，兼顾"独立"和"关联"。
- **会话列表按最近使用时间排序、只用图标/前缀区分工作区**：Rejected——
  图标/前缀仍然是平铺列表，多工作区场景下要逐行辨认；真正分组（分区
  标题 + 色块）才是用户确认要的"按工作区分组显示"。
- **一次性重写所有 ~40 个文件、含改动商用状态管理**：Rejected（范围裁剪）
  ——本次只动视觉层（颜色/圆角/间距/分区/组件复用）和上面两处明确批准的
  信息架构调整，不改 RPC 调用方式、不改其余业务逻辑、不新增功能域。

## Consequences

`./scripts/test-macos-native.sh`、`./scripts/build-macos-app.sh`、
`./scripts/test-macos-native.sh --smoke` 均通过。全应用不再有跨区域
`Divider()`，也没有残留的裸圆角数字字面量或系统语义色（`.orange`/`.red`/
`.green`/`.cyan`/`.mint`/`.teal`/`.secondary`）——`DSHTheme`/`DSHRadius`/
`DSHSpace` 是唯一来源，覆盖 `main.swift` 加 11 个功能域文件。

`DSHTheme.swift` 由主会话串行实现，之后 11 个视觉层改造文件通过并行
subagent 独立完成，最后跑一次 `/code-review`（8 路并行 finder + 1-vote
verify）复查合并结果。审查发现并已修复：Sidebar 会话状态点把"有内容但
未在运行"误标成"未读"（`main.swift`）；`TodoCard`/`JobCard`/`WorkflowCard`
的"已完成"状态色被并行改造成同色系正文文字，丢失了成功态视觉提示；
工具卡片的截断徽标从警示色降级成中性色；`RunNoticeCard`/`RetryNoticeCard`
两种不同语义的通知banner变成同一种颜色；`NativeAttachmentPreview.swift`
灯箱工具栏按钮在浅色系统外观下因为用了会跟随主题变化的 `.dshGhost`
而在固定深色画布上对比度不足；`DSHProviderAuthoring.swift` 里的
`dshField()` 是私有的，导致另外 4 个文件各自重新发明了单行输入框样式甚至
完全不加样式——已把 `dshField()` 提升进 `DSHTheme.swift` 并在全部单行输入框
统一调用；`SubagentCard`（`NativeDashboard.swift`）和
`SubagentTreeRow`（`DSHSubagentTree.swift`）对"异常"子代理状态的配色各自
实现、互不一致，已对齐。另有两个低风险项一并修了：`sessionGroups` 的
"当前工作区置顶"排序改成标准化路径比较（原来裸字符串比较，Host 回传路径
可能有尾斜杠差异导致排序静默失效）；`sessionIds` 成员判断从数组线性扫描
换成 `Set`。

两处审查发现但**有意不修**、留作已知取舍：

- **`List` → `ScrollView`/自定义按钮的三处替换**（`SettingsView` 分区列表、
  `Sidebar` 会话列表、`DSHSubagentTree.swift` 树列表）丢失了系统 `List`
  自带的方向键行间导航和列表可访问性语义。这是真实的可访问性回退，但
  补齐需要 `FocusState`/`onMoveCommand` 一类的键盘焦点管理工作，超出"视觉
  重皮"这次的范围，且无法在当前环境里对着真实运行的 macOS 应用做键盘交互
  验证，仓促补上风险比价值大。留给后续一个专门的可访问性任务。
- **`sessionGroups` 在任意 `@Published` 变化时都会重新计算**（不只是
  `hostSessions`/`hostWorkspaces` 变化时）——这是 `HarnessController` 单一
  `ObservableObject` 架构本身的既有特性（全部视图早就是这个模式，不是这次
  redesign 引入的新问题），真要修需要更大的状态管理重构，不在这次范围内。

未做（超出这次范围，留给后续）：`SettingsEditorView`/`ProviderAuthoringView`
之外的 sheet 键盘可访问性补全；侧栏会话分组目前不支持折叠/记忆折叠状态，
工作区会话很多时分区默认全展开，可能需要更多滚动。
