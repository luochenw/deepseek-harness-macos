# Agent Note: Composer 斜杠指令菜单对齐 cc/codex（键盘交互 + 技能组）

Status: implemented

## Problem

composer 此前已有 `/` 行的发送分发（`commands/execute`，未解析回落普通 prompt）和一个 `CommandPaletteView` 面板，但体验远落后于 Claude Code / Codex 的输入框：

- 面板只能鼠标点击，没有任何键盘交互——↑/↓ 选择、Tab 补全、回车执行选中、Esc 关闭全都没有；回车会把半截的 `/comp` 直接当整行发出去。
- 匹配用 `contains`，上游 Web 端是「有序子序列模糊匹配 + 前缀优先排序」（`dsh-client-ui-commands`）。
- 技能（skills）完全不出现在菜单里。上游 Web 端把 skill source 挂在同一个 `/` 触发器下（`dsh-client-ui-skill`），用户在 App 里无法发现 `/技能名` 用法。
- 面板在整行任意阶段（含已带参数时）都显示，上游菜单只跟随 leading token（名字输入阶段）。

原生指令清单（从 App 自带 Runtime 的注册方逐个确认，`commands/list` 即全集）：
`/compact`、`/export`（无参）；`/feedback <text>`、`/goal [...]`、`/plan [off|message]`、`/permission <preset>`（带参）。dsh-cmdline 没有注册表之外的 TUI 专属指令。Web 端另有一个纯客户端 `/model`（popup 选择器，不在 host 注册表里）。

## Decision

- `NativeCommandPalette.swift` 承载统一的菜单条目模型（指令组 + 本地指令 + 技能组）、匹配器、面板视图、pick 分发（`extension HarnessController`）和 `/model` 的模型选择 popover。
  - 指令匹配 = 大小写不敏感的有序子序列，前缀命中排在前（上游 fuzzy-discovery 的简化版，组内保持目录序）；技能匹配 = 前缀（上游 skill source 就是 `startsWith`）；与指令重名的技能被指令遮蔽（上游明确「a name shared with a host command still resolves to the command」）。总行数封顶 10，面板不出内滚。
  - 面板渲染选中高亮、组标题（两组同时存在才显示）、参数 hint、`modelInvocable: false` 技能的「仅手动」徽标、快捷键提示行。
- `Composer`（main.swift）键盘：↑/↓ 循环选中，Tab 补全名字（落 `/name `），回车按 Web 的三类分发处理选中项——无参指令直接执行、带 hint 指令落 `/name `、技能落 `/name `（上游「a pick lands the literal `/name ` text」，展开由 Host 的 `dsh-tool-skill` pre-step 手势边界完成）；Esc 关闭面板至下次编辑。
- 面板只在「裸 token」阶段显示（`/xxx` 且无空白），出现空白即收起；发送路径不动。
- 两条原生特判（`send()` 入口 + pick 分发双覆盖，仅裸行）：`/export` 走 carrier 的 `GET /api/session.export` 原生下载——注册表里的 export handler 是 Web 插件桩，只回一句固定文本，真下载是浏览器效果；`/model` 打开 composer 模型选择 popover（`HarnessController.showModelPicker`）。

## Alternatives considered

- **未知 `/` 行拒绝提交**（`dsh-commands` README 表述「rejected by shipped adapters」）——不选。读了 Web 输入机实际代码：`onAdjudicated` 收到 undefined 走 `default-sink`，未认领行按普通 prompt 提交；而且技能调用恰恰依赖这条通道（Host 端识别 prompt 里的字面 `/name` token 注入技能内容），拒绝会直接弄坏技能。既有回落行为就是对的，保留。
- **`/export` 照走 `commands/execute`**——不选。handler 是 Web 桩，原生侧会显示「成功」但什么都不发生；`GET /api/session.export` 下载路径已存在（`DSHSessionOps.swift`）。已知微偏差：带参数的 `/export foo` 仍会进 `commands/execute`（Web 端此时不认领、会落成 prompt），极边缘，不为它加解析。
- **不做 `/model`**——不选。它是 Web 端 `/` 菜单的常驻项（`dsh-client-ui-model-selection` 的 popupSelect），用户肌肉记忆里有；原生已有完整模型目录数据，popover 形态 30 行搞定。
- **技能选中立即发送**（cc 风格）——不选。上游 Web 是落字待编辑，保持一致，也留出补参数的机会。
- **菜单状态放进 HarnessController**——不选。选中索引、Esc 关闭是纯视图态，放 Composer 的 `@State`；只有 `/model` popover 的 `showModelPicker` 进控制器（`send()` 需要触发它）。
- **钻到 NSTextView 拦 keyDown**——不选。项目已用 SwiftUI `.onKeyPress(.return)`，同一机制加 ↑/↓/Tab/Esc 就够，无需 AppKit 层。

## Consequences

- 输入 `/` 出现可键盘操作的菜单：6 条原生指令 + `/model` + 当前会话技能；`/comp` 子序列命中 compact；空格后菜单收起，回车发送整行仍走 `commands/execute` → 回落 prompt 的既有通路。
- 面板数据源仍是会话挂接时拉的 `hostCommands` / `skills`——空白新会话（尚未懒建）里 `/` 菜单为空，与 Web 端「目录按会话预热」一致。
- 中文输入法组字阶段文本不进 SwiftUI binding（与 placeholder 已知限制同源），组字中不触发菜单。
- Tab 默认行为仅在面板打开时被覆盖，关闭时 `.ignored` 放行。
- WEB_PARITY.md 的 Slash commands 行已更新为现状描述。
