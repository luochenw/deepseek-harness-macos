# DSH macOS 原生 UI 设计标准

这份文档是 macOS 客户端所有 SwiftUI 界面遵循的统一视觉/交互约定。写新界面或重排旧界面时先查这里，不要每次重新发明一套间距/圆角/配色。

不是从零发明的——大半条目是从这个仓库里已经写得好的文件里反向提炼出来的（`NativeToolPresentationView.swift` 的 `Card`/`Badge`、`NativeDashboard.swift` 的卡片、`DSHSubagentTree.swift` 的空/loading 态），少数几条（侧栏图标导航、`Form` 分组、"少用分割线"）是这一轮重构新加的约定，后续要反向把老代码也扶正到这几条上。

## 1. 分组：卡片 + 间距，少用 `Divider()`

**默认用留白和卡片背景分组，不用硬线分割。** 这是用户在这轮重构里明确提的反馈（"整理尽量不用使用线的样式"）。

- 卡片背景：`(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))`——`NativeDashboard.swift` 里所有卡片（`TodoCard`/`JobCard`/`SubagentCard`）的标准写法，直接照抄。
- 需要强调"这张卡跟某个语义相关"（比如工作流、告警）时用色调背景：`(.teal.opacity(0.08), ...)`、`(.orange.opacity(0.1), ...)`、`(.blue.opacity(0.1), ...)`——颜色跟第 4 节的状态色对应，不要另起一套配色。
- 另一种更轻的卡片（`NativeToolPresentationView.swift` 的 `Card`）用双层：`.background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))` + `.overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.08)))`。两种圆角（10 / 12）都在用，按现有惯例：独立信息卡（工具展示）用 10，仪表盘汇总卡（todo/job/workflow）用 12。
- 系统级 `Form`/`.formStyle(.grouped)` 场景（设置类多字段表单，见 `DSHSettingsView.swift`）交给 SwiftUI 原生分组，不用手写卡片——`Form`/`Section` 本身就是"用留白+系统背景分组"，不需要额外处理。

**`Divider()` 什么时候还能用**：只用来标记窗口级别的结构性边界——主窗口侧栏╱对话区╱详情栏之间的三栏分割（`ContentView`）、设置页侧栏与内容区的分割（`SettingsView`）。**不要**用来分隔同一个面板/卡片内部的子区块（比如"标题"和"内容"之间、一组 Menu 之间）——用 `spacing`/`padding` 或换成独立卡片。已有代码里个别历史用法（比如 `NativeToolPresentationView` 终端卡片里命令回显和输出之间那条 `Divider()`）保留不追溯修改，但新写的界面照这条来。

## 2. 圆角与内边距

| 用途 | 圆角 | 内边距 |
|---|---|---|
| 仪表盘汇总卡（Todo/Job/Workflow/Subagent） | 12 | 12 |
| 工具展示卡（终端/diff/read/search/web） | 10 | 11 |
| 徽章/Badge/Pill | `Capsule()`（全圆） | 水平 6 / 垂直 3 |
| 设置页 Form 分组 | 系统默认（`.formStyle(.grouped)`） | 系统默认 |
| 弹出 Sheet 整体 | 不需要圆角（系统窗口自带） | 16-24（按内容密度） |

## 3. 排版

沿用系统字体（San Francisco），不要引入自定义字体。已有的分级：

- `.title2.weight(.bold)`——窗口/Sheet 标题（"编辑配置：xxx"、"子代理树"）
- `.headline`——分区/卡片主标题
- `.caption.weight(.bold)` 或 `.weight(.semibold)`——卡片内的小节标签（"任务"、"运行与工具"）
- `.caption`——正文/行内容
- `.caption2`——次要元信息（时间戳、行号、"共 N 条"这类计数）
- 等宽字体（`.monospaced()`）——路径、凭据引用名、代码/终端输出

句末不加句号（跟 Host 状态提示的既有风格一致，比如"凭据已保存"而不是"凭据已保存。"）；说明性 footer 文本可以是完整句子。

## 4. 状态语义色

已有代码里稳定在用的一套，不要在新界面里另起配色：

| 语义 | 颜色 | 典型图标 |
|---|---|---|
| 运行中 / 进行中 | `.blue` | `hourglass`、`circle.dotted`、`circle.inset.filled` |
| 成功 / 已完成 / 已配置 / 可写 | `.green` | `checkmark.circle`、`checkmark.circle.fill` |
| 需要关注 / 只读 / 未配置 / 截断 | `.orange` | `exclamationmark.triangle`、`lock.fill`、`exclamationmark.triangle.fill` |
| 失败 / 错误 | `.red` | `xmark.circle.fill`、`exclamationmark.triangle` |
| 已取消 / 中性 / 空 | `.secondary` | `minus.circle.fill`、`circle` |

`Badge`（`NativeToolPresentationView.swift:193`）是标准的状态徽章组件：`Text().font(.caption2.weight(.medium)).foregroundStyle(color).padding(.horizontal,6).padding(.vertical,3).background(color.opacity(0.12), in: Capsule())`。任何地方要展示一个短状态标签（"exit 0"、"HTTP 200"、"已截断"），复用这个模式而不是手写新的。

## 5. 图标

全部用 SF Symbols，不引入自定义图标资源。按功能域约定：

- 导航/侧栏分区：`gearshape`（通用/设置）、`cpu`（模型）、`network`（提供方/连接）、`puzzlepiece`（插件）、`square.stack`（预设）
- 会话/对话：`bubble.left`、`sparkles`（AI/assistant 标识，`Sidebar` 已用在 app 图标上）
- 工作流/子代理/任务：`point.3.connected.trianglepath.dotted`（工作流）、`person.3`（子代理）、`checklist`（todo）、`bolt.horizontal.circle`（运行中的工具/job）
- 文件/终端：`doc.text`（读文件）、`terminal`（终端）、`magnifyingglass`（搜索）、`globe`（网页）、`arrow.left.arrow.right`（diff）
- 凭据/安全：`lock.fill`（锁定/只读）、`lock.shield`（权限）
- 通用动作：`arrow.clockwise`（刷新）、`plus`（新建）、`xmark`（关闭/清除）

## 6. 空状态与加载态

任何列表类界面都要有明确的空状态和（如适用）加载态,不能是"数据没了就一片空白"。参考 `SubagentTreeView`（`DSHSubagentTree.swift:69-94`）：

```swift
if harness.xxxLoading {
  Spacer(); ProgressView("正在…"); Spacer()
} else if let data = harness.xxx, !data.isEmpty {
  // 正常列表
} else {
  Spacer()
  Text("没有 xxx。").foregroundStyle(.secondary)
  Spacer()
}
```

需要引导用户采取行动的空状态（比如侧栏零会话）在文字下面加一个主操作按钮,不要只放一句灰字。

## 7. 反馈状态（配置是否生效／写入是否成功）

用"图标 + 语义色 + 短文案"三件套,不要只用纯文字变色。参照这轮 Settings 重构里的写法：

```swift
Label(condition ? "已配置" : "请提供 API Key",
      systemImage: condition ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
  .font(.caption)
  .foregroundStyle(condition ? .green : .orange)
```

## 8. 交互控件不该在"必然失败"时保持可点

如果一个控件点击后依赖的操作在当前状态下必然被拒绝（比如会话开始后无法切换 preset,Host 会直接回 `agent-preset-locked`）,不要留一个能点、点了才报错的控件——判断条件已知时就直接换成禁用态 + 说明文案（`.help()` tooltip 或旁边一行 caption）,把"操作在这个状态下不可用"这件事在点击之前就说清楚。

## 9. 文件组织

延续 AGENTS.md"按功能域拆文件"的约定：一个界面区域一个文件（`DSHSettingsView.swift`、`DSHSidebarView.swift`……），`main.swift` 只留 `HarnessController` 状态和 `ContentView` 这种纯组合层。改动量大的重写优先拆新文件而不是在 `main.swift` 里原地展开。

## 已知不完全符合、暂不追溯的地方

- `NativeToolPresentationView.swift` 终端卡片内部有一处 `Divider()`（第 30 行）,按第 1 节的新约定不该再这么写,但这个文件本身质量高、不在这轮重构范围内,暂不动。
- 两套卡片圆角（10 / 12）并存是历史遗留而非刻意区分场景,当前先原样记录成约定（见第 2 节表格）,不强行统一成一个值——统一需要动 `NativeToolPresentationView.swift`,超出这轮范围。
