# Agent Note: 统一 Agent Profile、Runtime 与 Batch 平台

Status: implemented — Host 编排、Runtime 隔离与 macOS 原生控制面已落地

## Problem

当前原生客户端只能浏览已经由模型创建的 DSH Subagent，不能维护可复用
Agent Profile，也不能从 Composer、手动面板或模型工具统一派发 DSH、
Claude Code、Codex 和 ZCode。外部 Runtime 的运行状态、独立 workspace、
重试和日志没有共同模型，现有 continuable Subagent 又会逐个向父会话投递
settlement，无法满足一个 Batch 只汇总一次的产品语义。

## Decision

在 bundled Host 中增加统一的
`AgentProfile -> RuntimeAdapter -> RuntimeContext -> AgentRun -> AgentBatch`
编排层。Host 负责持久化、全局三成员并发、同 context FIFO、Runtime
进程、workspace、重启恢复、settlement 聚合和整合状态；macOS App 通过
Typert Gateway 读写同一份状态。

原生 App 在左栏增加 Agent 入口，并将现有右侧 DetailsPanel 扩展为
“执行 / Agent”双视图。Agent 视图管理全局 Profile，复杂编辑使用宽
Sheet；执行视图展示当前根会话及后代发起的 Batch、成员、日志、停止、
重试和汇总。Composer 支持单个 `@Profile` 标签，并允许逐次覆盖
analysis/execution 与 manual/auto。

每个 Batch 在创建时冻结实际发起 Agent/Subagent 的 cwd、sandbox mode、
provider/model/maxTokens、可继承工具集合和 Agent Preset。Profile 只在这份
能力快照上覆盖 persona、model 和工具过滤，不能借根 Agent 扩大权限。
Batch 创建、恢复、重试和 Runtime 执行都要求这些字段完整；即使状态已经
写有快照版本号，缺任一字段也会 fail-closed。平台管理 child 冷恢复时从
持久 context 恢复同一 provider/model/maxTokens、Preset、sandbox 和工具面，
禁止缺省字段回退到 durable direct parent 的当前配置。
DSH execution context 按 `initiatorSession + profile + execution` 复用同一个
continuable child 和 worktree，直到明确 adopted 或 discarded；analysis
使用独立 continuable context，整合结果不会隐式关闭它，只能显式重置。
child 的 durable direct parent 仍是 root Agent，供 Host 重启后自动恢复和
最终汇总；embedded Runtime 用不可变快照重建发起者的 preset、模型、工具和
sandbox，所以 root 只承担生命周期所有权，不提供权限。
共享同一 execution context 的多个 Batch 作为一个 workspace 生命周期处理：
整合会等待该 context 的全部 Run 终态，采纳或丢弃会同步更新所有关联
Run/Batch，整合指令包含累积任务历史。Profile 删除立即禁止新运行，但
历史 Batch 保存不可变 Profile 快照。

平台管理的 child 使用保留 descriptor 标签，并在 embedded Runtime
中拒绝普通 `subagent.prompt` / `send_message` 旁路；每次继续执行都必须
创建新的 Run。Batch 全终态后，Host 通过持久 outbox 只向根 Agent
投递一次汇总。自动整合由根 Agent 基于自然语言、diff 与测试选择性完成，
Host 不执行盲目 merge/cherry-pick。整合选择和 workspace/context cleanup
先写 durable intent，再执行幂等清理并提交终态；Host 重启会继续未完成
事务，已投递但尚未开始 cleanup 的 integrating Batch 会重新投递。独立
discard/reset 的 context close intent 同样自动恢复；close intent 存在时，
调度、context 选择和 Run 绑定三层都会阻止下一代 DSH Run 复用正在关闭的
child/worktree。

## Alternatives considered

- **只在 Swift 中维护 Profile 和运行队列。** Rejected：App 重启、切换
  会话或后台运行时会丢失所有权，模型工具也无法访问同一注册表。
- **把外部 CLI 任务伪装成顶层 DSH 会话。** Rejected：会失去 Runtime
  原生日志、停止语义和独立适配能力，也无法表达 continuable DSH context。
- **analysis 仅靠提示词要求不要写文件。** Rejected：安全边界必须由工具
  allowlist/restriction 强制；不支持硬过滤的 Runtime 应明确失败。
- **只设置外部 CLI 的 cwd。** Rejected：cwd 不是文件隔离，绝对路径仍可
  越出 worktree；外部 Worker 必须经过 DSH 的跨平台 sandbox provider。
- **完成后自动 merge/cherry-pick。** Rejected：多个成员可能提供互斥或
  局部方案，必须由当前根 DSH Agent结合自然语言、diff 和测试选择性整合。

## Consequences

- Profile 可新增、编辑、删除、手动运行，也可由 Composer `@` 或模型工具
  触发；模型派发开关默认关闭。Profile 还可保存手动运行的默认任务。
- 一个 Profile 可绑定多个不同 Runtime；同一 Runtime 只允许一个 binding。
- 右栏展示当前根会话的 Batch、不可变 Profile/adapter 快照、成员日志、
  发起者 preset/model/sandbox/tool/cwd 快照、baseline diff、停止、一次性
  重试、丢弃、整合总结和测试证据。
- DSH execution 使用独立 worktree 与 continuable child；Profile 编辑只影响
  新 context，复用旧 context 的 Run 会保存并展示实际运行配置快照。
- 所有 execution 都要求 Git repository；非 Git 根目录直接失败，禁止复制
  目录或静默回落父 checkout。外部 CLI 通过 DSH sandbox provider 继承发起
  Session 的 mode，并把 workspace-write 根切到成员 worktree；analysis
  无条件使用 read-only。
- 同一 DSH execution context 跨 Batch 累积变更；任一关联 Run 仍活跃时不能
  请求、投递或完成整合，context 采纳/丢弃后所有关联 Batch 保持一致状态。
- analysis Batch 可直接把文本结果交给根 Agent 整合；analysis continuable
  context 不因采纳而关闭，只有显式重置才使用新的 Profile 配置。
- 部分采纳后可再次选择剩余成员；整合提示明确 preferred/eligible Run，并
  保留失败原因。cleanup 在进程崩溃后从持久事务继续，不会重复投递或访问
  已清理的 worktree。
- 全局并发为 3；Runtime 失败隔离。外部 worker 重启后标记 interrupted，
  DSH 依托持久 child/worktree 恢复，停止中的 DSH Run 不会被重启。DSH
  child/message ID 在投递前保留，runtime retry 按 ID 幂等；启动时还会清理
  durable state 未引用的孤儿 worktree。
- 能力快照带显式版本。升级时，缺少完整 initiator 快照的旧非终态 Batch
  fail-closed 标为 interrupted，所有缺快照旧 Batch 均不可 retry、不可切回
  自动整合或手动请求整合，要求用户重新派发；历史日志和 worktree 保留供
  审阅/丢弃，旧 DSH context 不再复用。
- Profile 删除后不能新建或重试，但历史 Batch、Run、日志、diff 与配置快照
  继续可读。
- 运行时补丁支持 DSH 0.1.0-rc.6、0.1.0-rc.7 与 0.1.1-rc.2；升级时
  源码形状漂移会使构建失败，而不是静默回落父 checkout。rc.2 的 child ID
  与精确 child drain 使用上游实现，其余平台扩展仍由版本门控补丁提供。

## Risks

- bundled DSH continuable-child cwd、reserved ID、sandbox/preset override
  和 exact disposal 属于上游内部实现，升级时必须做版本和行为检查，禁止
  静默回落父 checkout 或 root 权限。
- 外部 CLI 的结构化事件能力不同，Adapter 需要统一最小日志/终态语义，
  不能假设所有 Runtime 都可恢复。
- Profile 与 Batch wire contract 由 Host 与 Swift 两边共同维护，需用
  编译 fixture 和 Host 端 schema 测试防止字段漂移。
