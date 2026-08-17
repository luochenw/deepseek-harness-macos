# Agent Note: 启动停在默认页，首条消息才创建会话

Status: implemented — 用户反馈"每次重新打开 app 都会新增一个 session，这不对"

## Problem

init() 无条件 newSession()：先插一个本地占位行，Host 连上后的回调再
把它变成真实的持久 Host 会话（session.create）。结果是**每次启动都
凭空多一个空会话**，会话列表被"新会话"占位行越积越多；归档/删除
当前会话时也会立刻 newSession() 再造一个，同样的问题换个入口再来
一遍。

## Decision

会话只在用户真正需要时诞生：

1. **启动**：init() 不再 newSession()，主区停在既有的空态页
   （"在下方输入内容开始对话"），composer 可直接输入。
2. **懒创建**：send() 在没有选中会话时走首发路径——插入本地行、
   `attachHostSessionToCurrentPlaceholder(onComplete:)` 建 Host 会话，
   成功后重入 send()（草稿原样还在，消息照常发出）。
   `isCreatingFirstSession` 挡住创建期间的重复触发；失败则复位并
   保留草稿。
3. **attach 增加 onComplete 回调**（默认 nil，旧调用方不变）：建会话
   +模型下推完成后在主线程回调成功/失败，首发路径靠它排序。
4. **连接回调收窄**：只有"用户在 Host 起来前就按了 ⌘N"留下的占位行
   才补建 Host 会话；全新启动无选中会话时不再自动建。
5. **归档/删除当前会话**：不再 newSession()，改为 clearToDefaultPage()
   （清空选中状态回到默认页）。
6. 显式 ⌘N/"新会话"按钮的立即创建语义保持不变。

## Alternatives considered

- **保留启动占位行、只是不建 Host 会话**：列表里仍然常驻一个假的
  "新会话"行，视觉上与真实会话混在一起，且删了又回，用户的抱怨
  正是"不要直接新增"。
- **把 send() 重构成 async 全链路**：能更优雅地 await 会话创建，但
  send() 是全 app 最大的分发函数（子代理追问/斜杠命令/普通 prompt
  三条路），整体 async 化改动面太大；onComplete + 重入是等价且
  局部的写法。
- **首发时不插本地行、等 Host 回执再插**：发送瞬间界面毫无反应，
  体感像没点上；先插行能立即给"正在创建持久 DSH 会话…"的反馈。

## Consequences

- 每次冷启动不再产生空会话；会话列表只反映真实发生过对话的会话
  （或用户显式 ⌘N 创建的）。
- 空态页成为常驻的"默认页"：启动后、归档/删除当前会话后都会回到它。
- attach 的 doc comment 已改写（init 不再是它的调用方之一）。
