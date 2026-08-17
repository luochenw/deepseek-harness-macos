# Agent Note: 工具执行结束后状态点仍在闪烁（run_code）

Status: implemented — 用户反馈"run_code 都执行结束了，还在动"

## Problem

转录里的工具行（尤其 run_code）执行完成后状态点仍无限脉冲。两个
叠加成因：

1. `session/jobs` 快照处理是**整表覆盖** `activeTools`，且状态映射
   只认识 `failed`——其余状态（包括 `completed`）一律映射 `.running`。
   run_code 会进入后台 job 快照，于是每来一帧快照，已完成的工具
   全部被打回"运行中"，同时转录行按 callId 的活动查找也被 job 条目
   洗掉。
2. 没有兜底：任何一个工具若没等到能对上 callId 的 `tool/result`，
   `.running` 状态就永远留在那里。

## Decision

1. `session/jobs` 改为**按 id 合并更新**：已有条目只更新 state/摘要,
   新 job 追加；状态映射修正——`failed → .failed`，`running/pending/
   in-progress → .running`，其余（completed 等）→ `.succeeded`。
2. `turn/end` 时把所有仍为 `.running` 的工具落定为 `.succeeded`：
   turn 已结束就不可能还有转录工具在跑；真正仍在运行的后台 job 会被
   下一帧 session/jobs 快照重新标回 running，不受兜底影响。

## Alternatives considered

- **只修状态映射、保留整表覆盖**：覆盖本身还会丢掉转录工具行的
  presentation/output（job 条目没有这些），行内展开会退化；合并才
  同时保住两边。
- **给 jobs 单独开一个列表、与 activeTools 彻底分离**：更干净，但
  涉及所有消费方（详情面板、仪表盘）的改造，超出本次 bug 修复范围;
  若后续 job 面板需求变复杂再做。
- **兜底放在 tool/result 的 callId 模糊匹配上（匹配不到就取最后一个
  running）**：掩盖错配而不是收尾，可能把结果写到错误的工具行上。

## Consequences

- run_code 等后台型工具完成后状态点正确熄灭；转录行的展开内容不再
  被 job 快照洗掉。
- turn 结束即视为所有转录工具已收尾，这是一个语义断言；长命后台
  job 依赖快照帧纠正（现状即如此）。
