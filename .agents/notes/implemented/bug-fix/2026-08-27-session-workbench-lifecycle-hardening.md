# Agent Note: 会话与工作台生命周期加固

Status: implemented — 会话切换、异步回调和右侧资源不再跨上下文泄漏

## Problem

右侧工作台引入了长期存活的 Browser、Markdown 和执行详情状态，也暴露了
几处原有异步路径的上下文边界问题：

- 切换会话后，Agent Batch、工具、工作流、技能和日志会在新请求返回前短暂
  保留，用户可能对上一会话的数据执行操作；
- 发送、命令和归档 RPC 完成时使用“当前选择”更新 UI，期间切换会话会写错
  目标；
- Browser callback 和下载生命周期可能阻止 `WKWebView` 释放或提前删除用户
  已有文件；
- Markdown 只监听父目录，原地覆盖写入不会刷新；
- 外部归档会话后，隐藏会话的工作台资源仍会保留。

## Decision

- 会话目标变化时同步清空根会话展示状态；随后所有异步加载都校验目标
  session id，再应用工具、技能、命令、反馈、模型和 Agent Batch。
- 发送和命令回调记录原始 local/Host session id，只修改原会话行；归档回调
  仅在用户仍停留于被归档会话时返回默认页。
- Browser runtime 关闭时清空 callback、取消下载并释放 delegate。下载先写
  同目录临时文件，成功后再替换目标，失败不删除原文件。
- 模型创建的 Browser 标签在初始导航、新窗口、重定向和下载前持续限制为
  HTTP(S)，不会把网页导航升级成任意本地 scheme。
- Markdown 同时监听文件 descriptor 和父目录，覆盖原地写入与原子替换；
  fragment 统一经过标题 slug 规则，并支持跨文档锚点。模型文档及其本地图片
  使用同一只 `O_NOFOLLOW` 文件描述符完成 `fstat`、真实路径校验和读取，避免
  校验后替换文件的竞态。
- 模型工具调用使用 session/turn/step/call id（Code Mode 使用
  root/sub-call id）关联；成功结果到达但子会话元数据尚未同步时保留为 settled
  请求，在 Host snapshot 或 Agent Batch 刷新后重试。
- Host 的归档集合是资源回收权威；归档上下文立即停止 Browser/文件监听。
- 构建产物内嵌项目、第三方、Node.js 和 DSH 许可证，smoke 明确验证其存在。

## Alternatives considered

- **只在 UI 上禁用按钮直到刷新完成。** 放弃：旧数据仍可被其他入口读取，
  且无法解决工具/工作流串会话。
- **把所有根会话展示状态一次性改成完整 per-session store。** 放弃：范围远超
  本次加固；同步清空加异步目标校验已经消除错误操作窗口。
- **下载前直接删除同名目标。** 放弃：网络失败会导致用户原文件丢失。
- **只监听 Markdown 父目录。** 放弃：普通 truncate/write 不保证产生目录事件。
- **在 `host/session-removed` 时销毁工作台。** 放弃：该事件表示运行实例
  detach，不等于持久会话删除；归档集合才是隐藏/回收的持久信号。

## Consequences

- 切换会话后不会显示或操作上一会话的 Agent、工具和工作流状态。
- 迟到的异步响应不会覆盖新会话；错误消息写回原始会话。
- Browser 标签关闭后可释放 WebKit runtime；失败下载保留既有目标文件。
- 模型 Browser 不能通过重定向、下载或新窗口逃逸 HTTP(S) 边界。
- Markdown 对原地保存、原子替换和带 fragment 的链接都能正确更新/跳转，
  模型文档读取和图片解码保持在原会话 cwd 内。
- 子代理首个工作台请求即使早于 Host 会话列表到达，也会在元数据同步后恢复。
- App bundle 自包含运行时所需归属文件，Host smoke 同时验证这些文件。
