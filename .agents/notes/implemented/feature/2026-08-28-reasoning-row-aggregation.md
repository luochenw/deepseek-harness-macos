# Agent Note: 思考过程按轮聚合与样式重做

Status: implemented — 一轮一条可展开的「思考过程」行（含段数），替掉每步一行的重复平铺，并修掉吞掉正文的重复行身份

## Problem

DSH 的一轮对话里，每个 step 都会产出一条独立的 reasoning 块。原生客户端的 `ConversationView.foldTranscript` 只折叠同名工具行，不折叠思考行，于是：

- 一轮里 10 多个 step 就渲染出 10 多个 `✻ 思考过程` 一行行平铺在工具调用之间，其中大部分下面**没有任何正文**（纯思考 step）。实测这一轮真实事件流：49 条折叠消息里有 **21 条思考行、15 条没有正文**。视觉上就是"思考过程被反复展示了一遍，而且跟上面那条一模一样"。
- 折叠后的行身份直接复用了消息 UUID：思考行和紧随其后的正文行是**同一个 id**。`ForEach` 里 id 重复时 SwiftUI 会静默丢掉其中一行——正文行就是这样消失的（这也是"有时候一致、有时候不对"的来源）。
- 展开态是 `Text(text)` 平铺：12pt 斜体、无段落间距、无容器、左边只加 17pt 缩进；正文又硬编码 `maxWidth: 760`，1100pt 宽的窗口里内容只占左边约 70%，右边一大片空白。

## Decision

1. **每轮一条思考行**。`foldTranscript` 维护 `turnTrace`（当前轮聚合行在 `items` 里的下标）：该轮第一次出现思考时插入一行，之后每个 step 的思考以 `\n\n` 追加进同一行并 `segments += 1`，行位置不动；`user`/`system` 行开启新一轮。只有思考、或只有工具调用的 step 不再产生正文行。行标签显示「N 段」，展开仍能看到每一步原文。
2. **行身份带类型前缀**：`TranscriptItem.id` 从 `UUID` 改为 `String`——`reasoning-<uuid>` / `message-<uuid>` / `tool-<uuid>`。聚合行和它后面的正文行不再撞 id，正文不再被丢。
3. **样式重做**：折叠态是带背景胶囊的 chip（hover/展开加深），展开态是圆角卡（`surfaceTint` 底 + 左侧 accent 竖线 + 参数化圆角），按空行切段落分别渲染（12.5pt rounded / 3pt 行距 / `inkSoft`），可选中复制。
4. **宽度适配**：transcript 列加 `transcriptMeasure = 1040` 的可读测度并水平居中（多余宽度变成两侧留白，而不是全挤在右边），正文与思考卡跟随列宽；用户气泡保留自己的 640 上限。

## Alternatives considered

- **只在视图层按需隐藏重复行**：治不了 id 撞车导致的整行丢失，也无法让"展开仍是全量"。
- **保留每步一行但改成更小的样式**：重复的本质是"同一轮里 N 条几乎一样的行"，缩样式只是把噪音变小。
- **每步只显示最后一条思考（Claude Code 式）**：行会随 step 下移，长轮里不断重排、且悬停展开时看不到历史步骤；按轮聚合位置稳定、内容不丢。
- **把正文测度硬拉到满宽（不设上限）**：超宽显示器上 CJK 行会到 80+ 字，可读性差；居中 + 1040 上限既用满宽度又保住行长。

## Consequences

- 一轮从 N 条「思考过程」变成 1 条（标签带段数），transcript 立刻短了；正文不会再因为行身份撞车而失踪。
- 新增回归门 `scripts/test-reasoning-ui.sh`（已接入 `scripts/test-macos-native.sh`）：`scripts/fixtures/reasoning-snapshot-check.swift` 断言「每轮 1 条聚合行 + 段数正确 + 只含思考的 step 不产正文行 + 工具行仍合并 + 行身份唯一」，并渲染 1100/560 两种宽度的快照。
- `ConversationView.foldTranscript` / `TranscriptItem` / `ReasoningTrace` 由 `private`/`fileprivate` 放宽到 internal，供 `@testable` 夹具断言；纯属可测性放宽，调用方仍只有本文件。
- 已知取舍：思考行固定在该轮第一条思考的位置（不随 step 下移），长轮里展开后它与当前工具调用的时间距离可能较远；用「N 段」标签提示它其实是整轮聚合。
