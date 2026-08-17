# Agent Note: 设置窗口原生化重构

Status: implemented

## Problem

`SettingsView`（main.swift:1627-1637）是全项目里唯一一处把整块 UI 写成单行分号
堆砌的代码：5 个分区（通用/模型/提供方/插件/Agent 预设）的 `settingsBody` 是
一个 `switch` 塞进一行，控件之间没有分组、侧栏 `List` 是纯文字没有图标、保存
凭据/设置后也没有即时反馈（只能瞥一眼窗口外主界面状态栏）。功能全部接对了
（Picker/SecureField/Button 都绑在正确的 harness 状态上），纯粹是表现层缺失
——用户原话是"毛坯房"。

`main.swift` 目前 1637 行，`SettingsView` 是文件里最后一块、也是唯一还没有
按功能域拆出去的大 View（对照 AGENTS.md"按功能域拆文件"的约定，
`DSHSettingsEditor.swift`/`DSHProviderAuthoring.swift` 都已经独立成文件，唯独
承载这两者入口的顶层 `SettingsView` 还留在 main.swift 里）。

## Decision

新建 `macos/DSHApp/DSHSettingsView.swift`，把 `SettingsView` 从 main.swift
移出，按 macOS 系统设置（System Settings）的惯用范式重写：

- 侧栏 `List(selection:)` 每行加 SF Symbol 图标（`gearshape`/`cpu`/`network`/
  `puzzlepiece`/`square.stack`），而不是纯文字
- 每个分区拆成独立的私有 View（`GeneralSettingsSection`/
  `ModelSettingsSection`/`ProviderSettingsSection`/`PluginSettingsSection`/
  `PresetSettingsSection`），用 `Form` + `.formStyle(.grouped)`（macOS 13+，
  Info.plist 的 `LSMinimumSystemVersion` 已经是 13.0）分组，配 `Section`
  header/footer 承载原本散落的说明文字和状态提示
- 凭据/配置可写状态用 SF Symbol + 语义色（`checkmark.circle.fill` 绿 /
  `lock.fill` 或 `exclamationmark.triangle.fill` 橙）替代纯文字颜色提示
- 不新增任何 RPC 调用或状态字段——所有绑定（`harness.preset`/
  `harness.apiKey`/`harness.configurableProviders`/…)和动作方法
  （`saveCredential`/`openProviderAuthoring`/`openSettingsEditor`/…)照抄原样，
  这是一次纯表现层重排，不改变任何行为

## Alternatives considered

- **就地在 main.swift 里格式化现有单行 switch（只加换行不改结构）**：改动最
  小，但保留的还是"字符串开关加 VStack"的手写布局，侧栏依旧没有图标、控件
  依旧没有分组视觉——不解决用户反馈的根本问题（看起来像草稿，不像成品）。
- **完全自定义卡片式布局（不用 `Form`/`.formStyle(.grouped)`，手写
  `RoundedRectangle` 分组卡片）**：视觉上更有产品个性，但要重新实现原生
  `Form` 已经免费提供的间距/对齐/明暗模式适配，维护成本更高，也偏离 macOS
  系统设置的用户心智模型。这个 app 的定位是"原生但不刻意标新立异"（对照
  WEB_PARITY.md"Deliberate architecture"一节：不复刻 Web UI 外观，走原生
  路线），`Form` 分组是最贴合这个定位的选择。
- **用 `TabView(.tabViewStyle(.automatic))` 顶部分页代替侧栏 `List`**：5 个
  分区标签太多，顶部 Tab 一行放不下且不支持图标+文字两行展示，System
  Settings 本身用侧栏而非顶部 Tab 正是因为分区数量和文字长度不适合横向排列。

## Consequences

- `./scripts/test-macos-native.sh` 通过（全量 typecheck，跨全部 `macos/DSHApp/*.swift`）。
- `./scripts/build-macos-app.sh` 构建通过，`./scripts/test-macos-native.sh --smoke`
  的 Host API 冒烟测试通过。
- 原 5 个分区的每一个控件和绑定都原样搬到了新文件里，没有功能丢失；main.swift
  不再有 `SettingsView`/`settingsBody` 的定义。main.swift 净减少约 11 行。
- 实现中踩到一处 Swift 类型检查器的已知坑：`PresetSettingsSection` 里
  `ForEach(...) { Button { } label: { if isSelected { Image(...) } ... } }`
  这种"`ForEach` 套一个内含条件分支和多层修饰符链的 `Button`"写法，会让类型
  检查器把 `ForEach` 误判成 `Binding`-泛型的重载（报 `Cannot find type`/
  `generic parameter could not be inferred` 一类看似无关的错误）。解决办法是
  把行内容拆成独立的 `PresetRow: View` 子结构体，而不是死磕报错信息——这类
  级联误报的标准修法就是拆小 View，注释里留了一句避免下次重踩。
- GUI 截图验证未能完成：这次执行所在的 Bash 环境没有真正的 WindowServer/GUI
  session（`osascript` 发按键被拒"不允许发送按键"，`screencapture` 只能拍到
  全黑），既不能给 Accessibility 权限做按键自动化，也不能截图看渲染效果。
  已完成的是构建/类型检查/Host API 冒烟这三层机械验证；侧栏图标切换、
  Form 分组的实际视觉效果需要用户在真机上手动 Cmd+, 打开设置窗口自查。
- `Form`/`.formStyle(.grouped)` 在 macOS 13+ 上的分组间距由系统决定，不能像
  手写 VStack 那样逐像素控制——如果后续还有间距上的具体意见，在 `.formStyle`
  基础上加 padding 微调即可，不需要推倒重来。
