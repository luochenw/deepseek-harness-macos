# Agent Note: 展开命令很多的分组时 App 卡死

Status: implemented — 每次布局只分类一次并按输入缓存，正则改为预编译

## Problem

在对话里展开一个「执行了 64 条命令」的分组，App 主线程卡在 100% CPU，一直不恢复，只能强制退出（2026-10-29 02:50，用户实际遇到）。

卡死时录的 sample 里，2461 个主线程采样有 2068 个落在 `ConversationView.requestScrollToTail` → `ScrollViewProxy.scrollTo` → 事务刷新 → `ToolGroupRow.body` 这条链上。在 `ToolGroupRow.body` 里，`digest` 被 `groupTitle`、`mutatingCount` 和两处 `chipText` 分别读一次，每次都对组里每条命令重新跑 `DSHToolCallClassifier` 的十几条正则，而这些正则用 `String.range(of:options: .regularExpression)`，每次调用都要重新编译。

`macos/DSHTests/DSHTranscriptGroupExpansionTests.swift` 在 -Onone 下测得：
- 64 条命令（22.5 KB），一次 body 求值 104.6 ms；
- 103 条命令（52.8 KB），一次 body 求值 209.5 ms；
- 把命令参数置空，让正则跑不起来，64 条只要 1.7 ms。

离屏展开真实会话需要 0.67 s，但生产 App 卡住不恢复。这多出来的放大还没有验证，怀疑是高度变化 → 跟随到底部 → 重新布局 → 高度又变化，形成了自激循环。

## Decision

1. `ConversationView` 每次布局只为一个命令组算一次 digest（`toolGroupDigest`），然后把它传给 `ToolGroupRow`；行的 `signature` 也由同一个 digest 派生，`ToolGroupRow` 不再自己计算。`ToolCallRow` 的多指令路径用同样的方式。
2. digest 存在 `DSHToolGroupDigestStore` 里（最多 256 条，先进先出淘汰）。键是对每条调用原始输入的哈希：消息文本、工具名、arguments、presentation 的标题和路径、状态，运行中的命令再加上解析出的标题。所以内容没变时，重复的布局不再分类；后到的 arguments、标题变化或状态变化都会触发重算；内容完全相同的键，digest 必然也相同，跨会话复用是无害的。
3. `DSHToolCallClassifier` 的全部正则改成 `static let` 预编译的 `NSRegularExpression`，模式文本一字未改。编译失败时按「不匹配」处理，并有单测断言所有模式都能编译。
4. 运行中命令只解析它的标题；已结束命令的标题本来就不显示，不再解析。

## Alternatives considered

- **只缓存 digest，不预编译正则**：首次展开和每次签名变化（例如运行中的组每来一条新命令）仍要付 100 ms 以上，运行中的大组照样会卡。
- **只预编译正则，不缓存**：每帧还要分类三遍，64 条预计仍远超 8 ms 帧预算。
- **在折叠成组时就把每条命令的分类结果存到消息上**：改动面跨到 Host 投影层和消息模型，属于更大的结构调整。等前两步做完、数据证明不够时再考虑。
- **限制展开时显示的命令条数**（比如只显示前 20 条）：只是绕过卡死，用户看不到完整的命令列表，而 body 里的 digest 仍然对全部命令计算。

## Consequences

- 离屏实测（-Onone 单测构建）：64 条命令的组，重复 body 求值从 104.6 ms 降到约 0 ms，首次计算约 14 ms；103 条从 209.5 ms 降到约 0 ms，首次约 27 ms。真实会话展开从 0.67 s 降到 0.15–0.17 s。打开会话：103 条命令的会话 871 ms → 134 ms，长思考会话 805 ms → 64 ms。
- 改动前后，4 份真实会话夹具里共 306 条命令的分类结果逐条一致。
- 「高度变化 → 跟随到底部 → 重新布局」的自激循环没有复现：一次展开只触发 1 次滚到底部。所以 `DSHConversationScrollStability.swift` 没有改。
- 仍然存在：首次计算一个大组（103 条约 27 ms，-Onone）会超过 8 ms 的帧预算，运行中的大组每来一条新命令付一次。特别长的 Markdown 回复首次排版会有 70–120 ms 的单帧，和命令分类无关。两者都是后续工作。
- 测试：`DSHTranscriptGroupExpansionTests` 离屏渲染真实的 `ToolGroupRow`，按分类次数断言（把 bug 改回去，这条测试会失败：64 条命令分类了 320 次）；还覆盖缓存键随运行中标题和后到的 arguments 刷新、所有正则都能编译。依赖本机夹具的计时测试在夹具缺失时记为 SKIP。
