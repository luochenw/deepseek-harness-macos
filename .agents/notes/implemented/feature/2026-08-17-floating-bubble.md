# Agent Note: 悬浮圈 —— 置顶的圆形收起态

Status: implemented — 用户需求："把现在的 icon 变成一个收起的悬浮按钮，有 session 运行是动态的，完成后有个红色小点，然后变成静态，一直置顶"

## Problem

会话在跑的时候用户往往切去别的 app 干别的事。此时既看不到运行进度
（Dock 图标不会动），也感知不到"跑完了"——只能定时切回来看。缺一个
最小面积的、悬浮于一切窗口之上的运行状态外化物。

## Decision

新文件 FloatingBubble.swift，三部分：

1. **FloatingBubbleManager**（@MainActor 单例）：
   - 持有一个无边框 `NSPanel`（`.borderless + .nonactivatingPanel`，
     `level = .floating`，`canJoinAllSpaces + fullScreenAuxiliary`，
     背景透明、内容投影、`isMovableByWindowBackground` 拖动，
     `setFrameAutosaveName` 记住位置，首次出现在主屏右上角）。
   - 不往 HarnessController 加任何状态：订阅 `$isRunning` 的
     true→false 沿推导"完成未读"（红点）；app 处于前台时完成不点红点
     （用户正看着，不需要提醒），新一轮开始/激活 app/点击悬浮圈清除。
   - 开关持久化（UserDefaults，默认开启），菜单栏「显示/隐藏悬浮圈」
     ⌥⌘Y。
2. **FloatingBubbleView**（SwiftUI）：44pt 圆形海景 + 右上角红点
   （红点带白描边，只在"完成未读且当前无运行"时出现）。单击 →
   激活 app、主窗口前置、清红点。
3. **SeaBubbleScene**：与转录里 WaitingWaveIndicator 同一套视觉常量
   （海水渐变、三层 WaveBand、月亮升落弧线 + 海平面遮罩）按 44pt
   重排：运行中走 TimelineView 逐帧动画；静止态渲染一张固定帧——
   月亮停在弧线顶点、浪形定格，红点负责传达"有结果"。

main.swift 只动三处：WaveBand 去掉 `private`（复用波形）、菜单栏加
一个开关命令、WindowGroup 的 ContentView `.onAppear` 挂载 manager。

## Alternatives considered

- **NSStatusItem（菜单栏图标）代替悬浮窗**：菜单栏图标面积太小放不下
  动画场景，且会被刘海/隐藏工具收走；用户点名要"悬浮按钮"。
- **红点常亮（前台完成也点）**：用户正盯着主窗口时完成，红点会一直
  挂到下次点击，变成噪音；"前台完成不提醒、后台完成才提醒"符合
  通知语义。
- **把状态放进 HarnessController（@Published hasUnseenCompletion）**：
  main.swift 是多 agent 高冲突区，且"未读"纯属悬浮圈自己的展示状态,
  用 Combine 从 $isRunning 推导即可，零核心侵入。
- **静止态继续跑 TimelineView 只是画同一帧**：白白吃 30fps 的重绘;
  静止就渲染普通视图。

## Consequences

- 悬浮圈是独立小窗，主窗口最小化/被遮挡时依然可见；随 app 退出。
- 运行判定为 `isRunning || sessions.any(isRunning)`，多会话并行时
  任一会话在跑都算"动态"。
- WaveBand 从 private 提为 internal，被两处共用；改浪形常量时两处
  视觉同步变化（本就该如此——同一枚图标）。
