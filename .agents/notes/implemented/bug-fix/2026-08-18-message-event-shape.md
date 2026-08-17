# Agent Note: 消息事件形态错配——用户消息丢失与注入上下文串场

Status: implemented

## Problem

实测 Host 会话日志（`session.history`）与 mux 流的消息事件是**扁平结构**：`data = {content, id, role, source}`，而 App 的历史重建与活跃事件路径一律按 `data["message"]` 嵌套结构取——取不到就整条丢弃。连锁后果：

- 历史重载后（切换会话、重启挂接）**用户消息全部消失**——用户看到"我的输入不见了"。
- 排队路径（isRunning 时的发送）不落本地气泡，全靠 user/message 事件——事件被丢，消息只出现在队列坞的灰色卡片里（左对齐大灰底），正文里永远不出现。
- Ark 等手工声明的 relay 适配器**只写 chunk、不写 assistant/message**，历史重建里也没有 chunk 折叠——重载后连回答文本都拼不出来。
- Host 以 user *角色*记录的注入上下文（`source.kind` = agent-instructions / plugin / skill-catalog，单条可达 13KB）与真实输入无区分，一旦解析修通就会冒充用户气泡刷屏。

## Decision

- `historyMessage` / `liveMessagePayload`：兼容扁平与嵌套两种形态，一处判断，历史与活跃路径共用同一语义。
- 用户气泡只认 `source.kind == "user"`（或缺省）；注入上下文一律不进转录——与 Web/cc 的 system-reminder 不可见行为一致。
- 历史重建增加 `assistant/chunk` 折叠（text-delta / reasoning-delta，锚定尾部 assistant 气泡，镜像活跃路径）；`assistant/message` 落定时**替换**链尾的聚合稿而不是追加（双写适配器不再出现重复气泡），reasoning 从聚合稿继承。
- 活跃路径 user/message 对 send() 的本地回显做前缀去重（首条消息的出站文本带工作区上下文附录，故用前缀匹配而非全等）；排队消息、斜杠回落、其他客户端提交仍正常落泡。

## Alternatives considered

- **只修历史、不动活跃路径**——不选：排队路径的消息丢失完全发生在活跃流上，是用户可见主诉的一半。
- **注入上下文渲染为可折叠系统行**——不选：13KB 指令快照对用户是纯噪音，Web 端也不作为对话内容展示；先隐藏，未来若做"检查请求上下文"面板再暴露。
- **让 Host 改事件形态**——不选：上游契约不归本仓库管，客户端兼容两种形态是唯一稳妥解。

## Consequences

- 重载后的转录完整：用户消息回来了，relay 适配器的回答从 chunk 重建，双写不再重复。
- 排队消息在被 Host 取走开跑时落入转录，队列坞只承担"待发"展示。
- 首条消息重载后会显示带 [工作区上下文] 附录的出站全文（live 只显示所输入文本）——已知的轻微不一致，接受。
