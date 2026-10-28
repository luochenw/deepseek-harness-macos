# Agent Note: 设置中的模型用量面板

Status: implemented — 设置 → 模型现已提供当前会话用量，并可控制 Composer 摘要

## Problem

原生客户端已经消费了 `tokenUsage`、`contextPressure` 与 `sessionStats` 投影，但仅在 Composer 顶部以一行紧凑数字显示。用户无法在设置内查看输入、输出、缓存读写、上下文占用和会话耗时的完整拆分，也无法选择是否在输入框旁保留简要用量提示。

Host 的 token-meter 只提供当前会话的累计 provider usage 与上下文参考值；它没有账户额度、账单金额或跨会话聚合 API。因此界面必须明确呈现为“当前会话用量”，不能伪造剩余额度或费用。

## Decision

- 在设置侧栏新增“用量”页面，显示当前模型与当前会话的上下文占用、累计输入/输出、缓存读写、缓存命中率，以及轮次、步骤、LLM 与工具耗时。
- 上下文进度使用 Host 的 `projectedTokens`（回退 `pressureTokens`）与 `contextWindow`；没有 Host 数据时解释为尚未完成可计量请求，而不是显示零。
- 添加仅影响原生 Composer 的本地开关，用于显示或隐藏其紧凑会话用量摘要。偏好保存在 `UserDefaults`，因为它不改变 Host 设置、模型路由或计费。
- 从 Composer 中复用同一格式化和语义定义，避免两个表面把缓存或上下文解释成不同含义。
- 兼容 token-meter 的新旧投影 schema：既接受扁平 usage，也接受当前
  `{totals,last}` 包装；打开已有会话时额外读取一次 exact projections，
  避免 sidebar list 快照陈旧导致数据缺失。

## Alternatives considered

- **把用量继续只放在 Composer 旁**：适合快速扫读，但没有空间解释缓存、上下文和耗时，也不满足“设置中展示”的发现路径。
- **显示账户余额、剩余 token 或金额**：当前 Host API 不提供这些数据；估算会误导用户，尤其是自定义兼容端点的计费规则不同。
- **将显示开关写入 Host settings.yaml**：这只是本地原生 UI 的布局偏好，写进共享 Host 配置会无意义地影响其他客户端。

## Acceptance criteria

- 设置内可读取真实 Host 会话投影并明确标记为当前会话累计数据。
- 未收到用量投影时显示可理解的空态，不把未知数据当作零。
- 只在上下文容量可用时显示进度和百分比，并在接近容量时提示风险。
- Composer 的简要用量摘要可由本地设置开关即时控制。

## Risks

- token-meter 的上下文占用是用户参考值而不是账单/门控值；界面会在说明中保留这个限定。
- 新创建或尚未完成模型请求的会话没有投影，面板会显示空态直到 Host 推送数据。

## Consequences

- Composer 与设置页共用同一套用量格式化和语义，只展示 Host 实际提供的当前会话数据。
- 设置页提供完整拆分；Composer 顶部只是一条可关闭的紧凑摘要。
- 未知用量显示空态，不伪装成零，也不推断账户余额或费用。
- 上下文和缓存命中使用同一套动画比例条；数值变化使用数字滚动，运行中的
  上下文摘要显示低强度活动波形，并遵循 macOS Reduce Motion。
- 上下文依次回退 `projectedTokens`、`pressureTokens` 和新版
  `surfaceTokens`；指标文字使用高对比前景，浅海蓝只承担图标和比例条。
