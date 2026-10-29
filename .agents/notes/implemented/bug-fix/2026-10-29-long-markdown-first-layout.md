# Agent Note: 打开会话时长文本回复首次排版掉帧

Status: implemented — 剩下的长帧来自离屏测试窗口首次上屏，不是 Markdown 排版；App 不改，只补了「长回复只解析一次」的回归测试

## Problem

用户反馈：「session 打开会话区域掉帧异常多，特别是展示指令之后」（2026-10-29）。其中命令组的部分已由 `bug-fix/2026-10-29-tool-group-expand-freeze.md` 修复。修复后再测，4 份真实会话夹具里还有超过 50 ms 的单帧（离屏，-Onone）：

- `c19df847-turn15`：展开后最长一帧 121 ms；
- `c19df847-turn19`：打开后 1 秒内最长一帧 71 ms；
- `c19df847-turn15`：打开时首帧 53.7 ms。

这些帧里 `rowEvaluations = 0`，命令组也没有重算；最高的行是单条 assistant 消息（1008pt、1238pt 高）。所以初步判断是长 Markdown 正文的首次排版（`NativeMarkdownText` 的解析、TextKit 排版和行高测量），但还没有拆开每一部分各占多少。

## Decision

不改渲染代码。拆分测量（离屏真实 `ConversationView`，-Onone）表明，剩下的长帧不是 Markdown 造成的：

- 最慢的那一帧里，Markdown 解析和内联构建都是 0 次，`NativeMarkdownText` 的解析缓存已经命中。
- 关掉行帧测量（121.7 ms）、完全不点击（125 ms），长帧都还在；去掉测试窗口的 `orderFrontRegardless` 以后，同一帧降到 27 ms。这一帧是测试窗口第一次上屏的开销（Core Animation 首次提交），App 里打开会话不会新建窗口，所以不受影响。
- 把文本清空、只保留行结构，首帧从 92.5 ms 降到 6.6 ms：时间主要花在第一次排版长文本上，而且只发生一次。

保留的改动只有回归测试：`DSHMarkdownLayoutCountTests` 断言同一条长回复在多次布局中只解析一次，长度相同、内容不同的文本分别解析。为此在 `DSHTranscriptPerf` 里加了三个只在 `#if DEBUG` 且开启测量时才计数的计数器。

## Alternatives considered

- **长回复只渲染前一部分，滚到了再渲染剩下的**：会改变阅读体验和行高估算，跟「一次渲染完整消息数组」的不变量（`simplification/2026-10-22-load-complete-session-history.md`）冲突。
- **把排版挪到后台线程**：TextKit 和 SwiftUI 的线程约束复杂，风险大；先确认是不是重复工作造成的，重复工作去掉就够的话不需要这一步。
- **不修，等 Release 构建自然变快**：最初的考虑是 -Onone 下 121 ms 即使到 Release 也会超预算。拆分后发现这 121 ms 根本不是 App 里的开销，所以不存在要修的东西。
- **给 Markdown 加更多缓存（按宽度缓存排版结果）**：解析已经只做一次，剩下的首次排版也只做一次；多加一层缓存不会让第一次变快，只会增加内存和失效的风险。

## Consequences

- 打开会话的掉帧里，和命令组有关的部分已由 `bug-fix/2026-10-29-tool-group-expand-freeze.md` 修复：103 条命令的会话打开从 871 ms 降到约 125 ms，长思考会话从 805 ms 降到约 62 ms。
- 离屏测量里那一帧 120 ms 左右的长帧，是测试工具本身的开销。以后用 `orderFrontRegardless` 的离屏测量看首帧时间，要扣掉这部分，或者先让窗口上屏再计时。
- 用户在真实 App 里如果仍然感觉打开会话卡，需要在 App 里采样（`sample`）确认，不能再用离屏首帧推断。
- 修复前后，金测和推理区快照逐像素一致（流式夹具的动画相位差异除外，同一构建重跑也有）。
