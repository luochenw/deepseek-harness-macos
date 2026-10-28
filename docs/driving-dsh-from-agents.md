# 用其他模型驱动本机 DSH（DeepSeek）协作开发

本文写给任何能执行 shell 命令的 AI 编码助手，例如 Claude、Codex、Cursor 或其他模型。目标是让你像一名「监工」那样，把编码任务派给本机的 DeepSeek Harness（下称 DSH），并控制质量和速度。
- 内容基于 2026-10-27 一整天的实际协作，所有命令和参数都已在本机验证过。
- 凡是写着「必须」或「绝不」的条款，都来自真实踩过的坑。

## 1. 分工

| 角色 | 负责什么 |
|---|---|
| **DSH / DeepSeek（执行者）** | 写代码、写探针、跑测试、修 bug |
| **你（监工）** | 界定范围、写任务说明（brief）、派发、监控、裁决审查意见、独立验收 |
| **用户** | 确认需求和方向，批准每一轮修复、合并、提交、清理 |

- **你是用户的唯一联系人。**DeepSeek 的汇报和交叉审查的结论，都只是你和用户沟通的素材，不是决定。新一轮修复、范围变化、合并、提交、删除 worktree，都要先问用户。
- **派出去以后，不要自己动手实现。**发现问题，就作为新一轮修复派回去。你自己只写决策记录（Agent Note）和 README，以及做验收。

## 2. 调用入口：`scripts/ds-agent`

```bash
cd <你的项目目录>            # 在用户现有项目里派活，不要新建目录
scripts/ds-agent --json - < brief.md > run.ndjson 2> run.err
```

**两种运行方式，自动选择**
- **Host 模式（优先）**：DeepSeek Harness.app 正在运行时，会发布 `<DSH_HOME>/host.json`（权限 0600）。任务跑在 App 的 Host 上，会话会**实时出现在 App 侧边栏**，用户能看到。
- **headless 模式（回退）**：App 没有运行时，用 App 包里打包好的运行时单独跑。会话不会出现在侧边栏。
- 模型和凭据都来自 App 自己的配置（`~/Library/Application Support/DeepSeek Harness/dsh`），**不需要、也不允许你另外配置**。

**常用参数**

| 参数 | 作用 |
|---|---|
| `--json` | 每行一个事件。首行是 `session`，末行是 `final`；中间可能有 `prompt` 等事件，**不要按行号取结果** |
| `-` | 从标准输入读取任务说明，长 brief 一律用这种方式 |
| `--session-id <id>` | 接着已有会话跑，保留它的上下文。修复轮优先用这个 |
| `--host` / `--headless` | 强制使用某一种方式 |
| `--timeout 30m` | 客户端最多等多久。默认不限。超时只是不再等，回合在 Host 上会继续跑 |
| `--attach <id> [--request-id <id>]` | 不发新任务，接回某个会话正在跑的回合（只能走 Host） |
| 环境变量 | `DSH_HOME`、`DSH_APP`，以及 `DS_PROVIDER`/`DS_MODEL`/`DS_EFFORT`（一般不要动） |

**事件**
- `session`：会带上 `sessionId`、`cwd`，Host 模式还带 `via:"host"`。
- `status`：`phase` 取 `turn_start`、`step_start` 或 `step_end`，其中 `step_end` 带 `usage.inputTokens`，可以用它估算上下文大小。
- `text`、`thinking`、`tool_call`、`tool_result`：过程事件。
- `final`：`text` 是最终回复。
- `error`：出错。

**退出码**
- `0`：完成；
- `1`：失败，或者回合不是正常结束，stderr 会打印「本轮结束原因」；
- `2`：参数错误；
- `127`：找不到 App 运行时。

**中断**
- 对 `ds-agent` 按 Ctrl-C：如果任务还在排队，就撤回它；如果已经在跑，只会取消**属于自己的**回合。

**注意**
- headless 模式**不能**用 `--session-id` 接着跑 Host 创建的会话：会被拒绝，因为两边的预设不同。这种情况要新开一个 headless 会话，在 brief 前面补一段上下文。
- 跑在后台的 `ds-agent` 一定要把 stdout 重定向到文件。派出后**立刻**检查 `run.err` 和第一行：参数写错会马上失败。
- **headless 建的会话没有标题**，在 App 侧边栏里很难找到。真实发生过：用户看不到任务在哪里跑。用 Host 的 `session/rename {request:{sessionId,title}}` 补上标题，带上【改代码】这类标签。会话正被 headless 进程占用时会返回 `session/writer-held`，等那一轮结束后再改名。反过来，Host **可以**用 `--session-id` 接着跑 headless 建的会话，这样它就会实时出现在侧边栏里。

## 3. 标准流程

1. **界定范围。**
   - 在用户已有的项目里做，每个新 cwd 都会在 App 里变成一个新的「项目」，用户不希望这样。
   - 先保存一份 `git status --porcelain` 和 `git diff` 作为基线，列出允许改的文件。
   - 两个同时写代码的任务不能碰同一批文件。
   - 原因不明的 bug 要分阶段：先分析，只出报告；用户确认方向后再实现；最后验证。**不要把「查原因」和「修复」放在同一次派发里。**
2. **写 brief。**见第 4 节。只写**已经核实的**事实；推测要标明是「待查方向」。
3. **后台派发，并持续监控。**见第 5 节。
4. **交叉审查。**开发回合结束后，**新开**一个只读会话审查这次的增量。新会话不会被作者的思路带偏，能抓到真 bug。
5. **独立验收。**见第 7 节。逐条裁决审查意见：要么拿出证据确认，要么说明理由驳回。
6. **修复轮。**确认的问题用 `--session-id` 派回**原来的开发会话**，前提是它的上下文还没超过约 50%。修完后，只针对这次的增量重复第 4、5 步。
7. **收尾。**你来写 Agent Note 和 README。没有用户明确同意，不 commit，不 push。

## 4. Brief 模板

```markdown
# 【改代码】<一句话标题>          ← 首行会成为会话标题。标签：【改代码】【改产出】【只读】【测试】

**上限：25 分钟。8 分钟内必须有文件改动。**到上限时即使没做完也要停下，汇报：已确认的、还没做的、下一步怎么做。

**禁令**：
- 改文件一律用 edit/write 工具，不用 heredoc 或 sed；
- 命令要带显式超时；
- 在未打补丁的运行时上严禁看图片（打过补丁的 Host 上允许，见第 8 节）；
- 不构建 App，不启动或退出 App，不 commit；
- **绝不能杀不是自己启动的进程，也绝不能删除 /tmp/ds-heavy-gate.lock**；
- 重的命令一律套 heavy-gate.sh。

只允许改：<文件清单>。不要碰：<别的任务正在改的文件>。

## 要做的
1. <问题>：现状 <文件:行号 + 粘贴关键代码>；改法 <具体做法>；验收 <可量化的标准>
...

## 验收命令
<精确的命令和期望结果>

## 交付（中文，不超过 N 行）
改了哪些文件、在哪些行；每条验收的数值；命令和退出码；**没有验证到的地方**。
```

**提速要点**
- 推理强度保持 max，**不要降低**。速度要靠减少步数、尽早干预来换。
- 在 max 强度下，每一步要思考 2 到 3 分钟。如果新会话只拿到 `file:line`，它会先读 20 分钟代码才开始动手。所以要**把需要改的代码原文贴进 brief**，并写明「不读其他文件，第一个工具调用就是 edit」。
- 已经有上下文的会话，优先用 `--session-id` 续接。

## 5. 监控与干预

**监控方式**
- **按时间设上限，不按步数。**健康的会话可能 14 分钟就走了 60 多步。步数只作为宽松的上限，大约是预估值的 4 倍。
- **持续巡检，不要干等它跑完**，每次只看这几样：
  - `run.ndjson` 里的 `status` 事件：步数、`step_end.usage.inputTokens`、有没有发生压缩；
  - 允许改的文件是否有变动：可以用 `git diff --stat`；`outputs/` 这类没有纳入 git 的目录，就比较修改时间；
  - 是否在重复做几乎相同的动作。

**出现以下任一情况就干预**
- 上下文超过窗口的约 50%，或者已经发生过压缩；
- 实现阶段 10 分钟以上没有任何文件改动；
- 反复做几乎相同的动作，例如写 probeN、构建循环；
- 到了时间上限。

**怎么正确停下**
1. 用输出文件定位进程：`lsof -t run.ndjson`，会得到 `ds-agent` 和它的子进程 `.../node .../lib/bin.js`。**不要用 `pgrep | head` 猜进程。**
2. 只向 dsh 子进程发送**一次** `SIGTERM`。发第二次信号会被当成「立即强制退出」，那样就不会释放会话写锁。
3. 再用 `--session-id` 排一个**只汇报**的回合：不改文件、不编译、不杀进程，最多 6 到 8 次只读工具调用，汇报已确认的、已排除的、建议怎么改、卡在哪里。
4. 拿着这份汇报去和用户确认，再重新派发。**不要往正在探索的回合里追加任务范围。**

**例外**
- 如果会话正在**排队等测试锁**（见第 6 节），那不算卡住。等锁的时间不计入上限。

## 6. 重型命令要串行：`heavy-gate.sh`

```bash
~/.claude/skills/deepseek-collab/scripts/heavy-gate.sh ./scripts/test-macos-native.sh --unit
```

- 这是一把全机共享的锁：拿到锁才运行，退出码原样透传。
- **必须**套上它的命令：Swift 的 `--unit`、完整门禁、构建、运行时重装、整套源码的 swiftc 编译。
- 原因有两个：多个门禁同时跑会变得很慢；几个任务共用一个工作区时，还会互相报「modified during the build」。
- 每个 `--unit` 排队大约 6 分钟，等锁时队尾可能要等将近 20 分钟。
- **绝不能**为了抢锁去杀持有者，或者删除锁目录。真实发生过：一个只读审查会话 `kill -TERM` 了监工的验收编译。

## 7. 验收清单（质量来自这里）

**每次都要做**
- 核对汇报：`git status` 和它声称改过的文件一致；没有碰禁止的文件；主工作区原有的未提交改动没有被覆盖。
- **自己重跑**测试、类型检查、构建、冒烟，只看输出的结尾。
  - DeepSeek 的 headless 沙箱有时编译不了 SwiftUI 宏（`swift-plugin-server` 报 `sandbox-exec: Operation not permitted`），只能加 `-disable-sandbox` 在临时目录跑「等价」测试。**官方 `--unit` 必须由你来跑。**
  - 主树正被别的任务改动时，先 `rsync` 一份快照，在快照上跑。
- 检查凭据：它有没有复制 `DSH_HOME` 或 `.credentials.yaml`，有没有打印 token。用过的临时目录也要查；确认是副本、不是符号链接后再删。
- **要原始证据，不要结论。**
  - 涉及界面或接线的改动，要求它贴出离屏探针的原始日志行，修复前后各一行。
  - 逐行核对日志是否真的支撑它的结论。真实案例：作者说「同一行滚动前后都是 24」，可原始日志里滚动后那一行是 -1，根本没有挂载。
- 看不到的界面，把具体的检查步骤交给用户在真机上确认。

**按风险等级**
- **逐行读**：鉴权和凭据、协议/RPC、并发、持久化、进程生命周期。
- **看 diff、跑测试、抽查**：UI 布局、文案、测试文件、文档。

## 8. 硬性禁令

- 绝不打印、复制或写出凭据和 token。DeepSeek 不能复制 `DSH_HOME` 或 `.credentials.yaml`。
- 不修改 `/Applications` 里的 App。构建只在项目的 `dist/` 里做。**App 正在运行时，不要往它当前运行所在的 dist 里构建。**
- **不调用 `session/selectModel`**：它会改掉 App 的全局默认模型。推理强度保持 max。
- **看图要分运行时版本：**
  - **未打补丁的运行时**：也就是 `/Applications` 里的旧 App，或者从它启动的 `--headless`。**DeepSeek 绝不能看图。**tool result 里的一张图，大约每字节就算一个输入 token：一张 193 KB 的截图，让一步的输入从 88k 涨到 271k，还会触发反复压缩。需要做视觉判断时，由能低成本看图的监工模型来看，再把看到的内容写成具体的修改指令。
  - **打过补丁的运行时**：也就是带 `dsh-llm-runtime-patch-v2` 的 App 构建，经由 App 的 Host 运行。**可以让 DeepSeek 看自己渲染的图来迭代。**同一张图约 1k token，模型也真的能看到。要做到：每轮限制看图次数；它的第一张图要在汇报里写明 token 增量；单张超过 20k 就立即停止看图。
  - 用户的反馈是：只用程序生成、不看图的做法，画面「一点也不写实」。做视觉类任务时，优先用这种方式。
- 不 commit、不 push、不删 worktree、不归档会话，除非用户明确同意。
- 不杀不是自己启动的进程。App 正在运行时，不要再起第二个 Host 去连真实的 DSH home。
- **做实验时绝不能启动真实 App 的副本。**改了名的副本，用的仍然是用户真实的 DSH home。真实发生过：副本覆盖了 `host.json`，导致所有 `ds-agent` 调用和监控都连到了错误的 Host 上。

## 9. 其他已知坑

- **App 崩溃后 Host 残留。**残留的 Host 会占着会话锁，表现为 `session/writer-held`。处理办法：等回合跑完，向它的 Host 发一次 SIGTERM；或者用 `session/fork` 复制一份会话再续。
- **`turnOutline[].response` 只是截断的预览。**完整回复要从 `session/page` 的 `assistant/message` 里取，`ds-agent` 的 `final` 已经处理了这一点。
- **python heredoc 改文件可能卡死。**一律用编辑工具。
- **派发 headless 时不要带不存在的参数。**比如旧版没有 `--headless`，进程会立即退出；派出后马上看 `run.err`。
- **`await` 一个刚排队的回合时，要先确认它真的开始了**：看到 running 状态，或者 outline 变长。否则会把它误判成已经结束。

## 10. 现成的辅助脚本

本机路径：`~/.claude/skills/deepseek-collab/scripts/`。任何模型都可以通过 shell 调用。

| 脚本 | 用途 |
|---|---|
| `heavy-gate.sh <cmd>` | 全机重型命令锁（见第 6 节） |
| `monitor-run.sh <ndjson> <repo> <base> [max_steps] [max_secs] [max_ctx] [nodiff_steps]` | 盯一个 headless 回合；遇到完成、超时、上下文过大、发生压缩时，退出并打印 `DONE …` 或 `ALERT …` |
| `monitor-host.mjs <sessionId> <repo> <base> [maxMin] …` | 盯一个 Host 回合 |
| `await-turn.mjs <sessionId> <out.json>` | 等 Host 上的回合结束，取完整回复 |
| `host-status.mjs <sessionId>…` | 一次性查看：是否在运行、轮数、步数、LLM 耗时 |
| `references/brief-template.md`、`references/review-template.md` | brief 模板和交叉审查模板 |

监工流程本身（Claude 版）记录在 `~/.claude/skills/deepseek-collab/SKILL.md`，本文是去掉工具绑定之后的通用版本。
