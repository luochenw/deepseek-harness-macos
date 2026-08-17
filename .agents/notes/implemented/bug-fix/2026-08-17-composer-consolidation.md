# Agent Note: 合并式输入框与模型选择真正落到 Host

Status: implemented — 界面上的模型/推理强度选择此前从未影响 Host 会话，现在会话创建即推送、切换即生效

## Problem

App 里存在三处"看起来能选模型、实际不生效"的断层，叠加出用户可见的经典故障：composer 标签显示
「Relay / GPT-5.6 Terra · high」，Host 却报
`provider "relay" model "ark/deepseek-v4-flash" does not support reasoning effort "high"`。

1. **设置页的提供方/模型 Picker 只改本地 `@Published` 状态**，从不调
   `session.selectModel` RPC —— 选了等于没选。
2. **`session.create` 不携带模型**，Host 用它自己的
   `agent-default-model`（App 专属 DSH home 里的 `settings.yaml`，被首次启动的
   seeder 写成了 `relay / ark/deepseek-v4-flash` + `reasoningEffort: high`，而
   ark/deepseek-v4-flash 不支持 high）。App 端的 provider/model/effort 只是
   本地默认值（`relay / gpt-5.6-terra / high`），从未与 Host 对过账，composer
   标签因此长期展示一个 Host 不知情的"假选择"。
3. **`selectCurrentModel` 在尚无 Host 会话时静默 `return`**，选择被丢弃。
4. **推理强度菜单硬编码 关闭/高/最大**，与 adapter 实际宣告无关。pi-ai 的规则：
   手工声明（`cordis.patch.yml` providers）的模型若不带 `reasoningEfforts`，
   `getSupportedThinkingLevels` 只返回 `["off"]` —— 对这种模型选 high/max
   必然抛 `UNSUPPORTED_REASONING_EFFORT`，跟选哪个模型无关。上游 Web 端
   （dsh-client-ui-model-selection）的契约是"effort 行只列 exact model 宣告
   的档位；无元数据则整行不出现"。

另有一个容易踩的运维暗坑（本次一并记录）：App 内置 Host 的配置根在
`~/Library/Application Support/DeepSeek Harness/dsh/`，**不是** `~/.dsh`；
`~/.dsh` 只在首次启动（App home 尚无凭据时）被一次性拷贝。用户后续改
`~/.dsh/settings.yaml` 不会有任何效果。

## Decision

- composer 底部合并为单一边框盒（输入框 + 附件/语音/模型菜单/发送），模型菜单
  `ComposerModelMenu` 从 Host 的 `llm.models` 目录动态列出提供方与模型（真实
  provider id），不再硬编码。
- 设置页两个 Picker 改用自定义 `Binding`，set 时走 `selectCurrentModel` →
  `session.selectModel`，选择即刻推送 Host。
- `newSession()` 在 `session.create` 成功后立刻用本地选择调
  `session.selectModel`，随后 `refreshSessionModels()` 从 Host 回读，保证
  composer 标签显示的是会话真实模型；推送失败会以系统消息显式暴露。
- `selectCurrentModel` 把 provider/model/effort 三元组整体持久化到
  UserDefaults（此前只读不写，且 effort 不持久化——只恢复 model 不恢复 effort
  会在重启后重现"模型 × 不支持的 effort"组合）。无会话时保留本地选择，由下一次
  `newSession()` 推送。
- seeder 写入 headless profile 的默认模型改为与 `defaultProvider`/`defaultModel`
  常量对齐（gpt-5.6-terra），不再埋入会拒绝 high effort 的 ark 模型。
- 目录解码补上 apiproxy `modelReasoningSchema`（`DSHModelReasoning{Effort}`），
  composer 的推理强度子菜单改为按当前模型宣告的档位动态渲染（无元数据则整个
  子菜单隐藏，标签也不再拼 `· high` 后缀）；`advertisedEffort` 把待推送的
  effort 钳制到宣告集合（未宣告→按 pi-ai 语义整个省略字段）。
- 本机 App home 配置同步修正：`agent-default-model` 改为
  `relay / gpt-5.6-terra / high`，并给 relay 的 gpt-5.6-terra 声明
  `reasoningEfforts: {off: null, low, medium, high}` 使 high 真正合法
  （ark/deepseek-v4-flash 保持无宣告 = 不提供 effort 选择）。原文件留有
  `.bak-*` 备份。

## Alternatives considered

- **`session.create` 直接带上模型参数**：协议侧 `session.create` payload 没有
  模型字段，扩 Host 协议成本高且上游语义如此；create 后紧跟 selectModel 等价
  且零协议改动。
- **只做"从 Host 回读"（标签永远显示 Host 真相），不推送本地选择**：诚实但
  违背用户直觉——用户在 UI 里选了模型，期望新会话就用它；只回读等于把选择器
  降级成只读指示器。
- **App 直接监听/改写 `~/.dsh` 而不是 App 专属 home**：会和用户本机 CLI 的
  dsh 状态互相踩踏（sessions/storages 混写），当初分离 home 正是为了隔离；
  保留分离，靠"创建即推送"让 UI 成为事实来源，配置文件默认值只做兜底。
- **在 seeder 里同步 `reasoningEffort: off` 保住 ark 模型**：治标——默认模型
  与 App 端默认常量不一致的根因还在，标签仍会说谎。

## Consequences

- 界面选择成为会话模型的事实来源：新会话创建即生效，切换即生效，重启后恢复。
- composer 标签在 create/selectModel 往返后与 Host 对齐，不再出现"标签一个
  模型、报错另一个模型"。
- 既有旧会话仍保留它们已存储的模型选择（含坏组合），打开后可用 composer 菜单
  当场切换（此时会话已存在，RPC 必达）。
- 首次安装 seeder 不再制造非法默认组合；已被污染的存量 App home 配置需手工
  修一次（本次已顺手把该机器上的 `settings.yaml` 与 headless patch 改为
  gpt-5.6-terra）。
