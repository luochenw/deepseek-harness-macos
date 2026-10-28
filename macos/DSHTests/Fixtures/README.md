# 真实会话夹具（transcript golden）

这四份 JSON 由本机运行中的 Host 通过 `session/page` 采集，用于
`macos/DSHTests/DSHTranscriptGoldenTests.swift` 的离屏回归检查。第五份
`scripts/fixtures/transcript-interrupted-turn19.json` 由同一会话的 turn 19 采集，
服务于 `macos/DSHTests/DSHTranscriptRowHeightTests.swift`，采集与脱敏流程相同。

| 文件 | 来源会话 | 内容 | 记录数 / 命令数 |
|---|---|---|---|
| `session-84f7c0cb-turn1.json` | `session-84f7c0cb-a591-44e2-90aa-c987561a1cd9` | 画图会话第 1 轮，命令最多的一轮（用户报「命令行整行看不见」的那一类会话） | 521 / 103 |
| `session-c19df847-turn19.json` | `session-c19df847-b49a-4463-a185-f2b8eed542c4` | 被中断的第 19 轮 | 35 / 6 |
| `session-c19df847-turn15-long-reasoning.json` | 同上 | 长思考过程的一轮（原始 reasoning 66k 字） | 287 / 55 |
| `session-84f7c0cb-turn2-live.json` | 同上（画图会话） | 直播增长序列：第 2 轮逐事件回放 | 50 / 9 |

## 只在本机，不进仓库

这些夹具是**本机产物，永远不入库**：`.gitignore` 忽略了
`macos/DSHTests/Fixtures/*.json` 与 `scripts/fixtures/*.json`。同目录的
`README.md`、`scrub-fixtures.py` 和 `scripts/fixtures/` 下的 `*.swift` 卡口照常入库。

于是新克隆的仓库里没有夹具。用到夹具的测试在这种情况下**跳过而不是失败**，
并且跳过是看得见的——`./scripts/test-macos-native.sh --unit` 会打印一行
`SKIP <测试名>: fixture <文件> is not on this machine …`，末尾汇总也把跳过数单列：

```
Ran 298 test(s): 292 passed, 6 skipped, 0 failed
  SKIP Golden: command-heavy real turn stays compact: fixture session-84f7c0cb-turn1.json is not on this machine …
```

夹具**在但内容坏了**（解码失败、字段缺失、断言不过）仍然算失败，不会被当成"跳过"。

## 怎么重新生成

1. 从本机 DSH_Home 里挑一个有代表性的会话（命令密集 / 长思考 / 一轮被中断），
   记下 `sessionId`。
2. 用下面这段握手 + `session/page` 取那一轮的事件（`turnWindow` 保证拿到完整的一轮）。
3. 按「采集与脱敏」的五条规则裁剪、截断、脱敏，写到本目录
   `session-<会话前缀>-turn<N>.json`（第 4 份是逐事件回放，命名 `-turn2-live`）。
   第 5 份写到 `scripts/fixtures/transcript-interrupted-turn19.json`。
4. 跑 `python3 macos/DSHTests/Fixtures/scrub-fixtures.py --check`，退出码 0 才收工。
5. 跑一次 `--unit` 确认测试从 SKIP 变回 PASS——**如果还是 SKIP，说明文件名或位置
   没对上**，测试没有真正加载它。

## 采集与脱敏

```js
// 握手拿 cookie，然后：
await call('session/page', { request: {
  address: { kind: 'session', sessionId },
  throughSeq: projections.value.asOfSeq,
  maxMessages: 400,
  turnWindow: { minMessages: 200, minTurns: 2 },
} });
```

生成脚本做了五件事（脱敏部分见同目录 `scrub-fixtures.py`，可用
`python3 macos/DSHTests/Fixtures/scrub-fixtures.py --check` 复核，退出码非 0
即还有残留）：

1. **只保留会影响渲染的事件类型**（`turn/start`、`assistant/message`、
   `tool/call`、`tool/result`、`user/message`…）。`request/header`（每轮几十 KB
   的工具 schema）、`job/*`、`request/context`、`image/offload`、`llm/retry`
   永远不进行，留着只会让夹具无法评审。
2. **长文本截断到 4000 字**，超出部分替换成 `…[clipped N chars]`。行高仍由
   真实内容量决定，但文件从 2.5 MB 降到 200 KB～2 MB。
3. **去掉凭据形状的字符串**：`sk-…`、`Bearer …`、`token: "…"` 一律替换成
   `[redacted]`。夹具里不含 cookie、token、api key、邮箱。
4. **抹掉操作者的用户名与本机目录**：`/Users/<任何人>` → `/Users/developer`；
   `/private/tmp/claude-501/-Users-<name>-…` 这类 scratch 路径（用户名被转义
   成连字符形式也一样）→ `/private/tmp/scratch`；`$USER`、`$HOME` 的末段，
   以及本地不入库的 `scrub-local.txt` 里列出的词（每行一个）→ `exampleco`；
   `127.0.0.1:<端口>` / `localhost:<端口>` → `127.0.0.1:0000` /
   `localhost:0000`。脚本本身不含任何账号或公司名。
5. **剥掉模型系统提示与技能清单**：`You are an AI agent powered by DeepSeek
   Harness…` 与 `# Available skills…` 这两段整段替换成
   `[redacted system prompt]` / `[redacted skill catalogue]`（它们只是用户消息
   的引用内容，不影响行高）。

上一版 README 只声明了第 3 条，实际上第 4、5 条**没有做**——夹具里当时有 735
处未脱敏的家目录路径和完整系统提示。现在这两条由脚本执行并带 `--check` 复核。

`meta` 字段记录了来源会话、那一轮是什么、以及上面这些处理，方便以后核对。

## 为什么用真实数据

6c/6d 的两个 bug 都没被合成测试抓到：一个是折叠行把
`行高 × 命令数` 当成 `minHeight`（103 条命令 ⇒ 2 447pt 空白），另一个是
`Equatable` 的版本哈希没覆盖行真正渲染的东西。这类问题只有在「真实形状的
一轮」上才暴露——命令密集、思考很长、事件带 `view`、行在直播中一点点长大。
