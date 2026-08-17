import AppKit
import UserNotifications

/// Menu-bar presence and system notifications — native capability a
/// WebView-based client cannot provide. See
/// .agents/notes/implemented/feature/2026-08-14-native-menu-bar-and-notifications.md.
@MainActor
final class NativeAlerts: NSObject {
  private var statusItem: NSStatusItem?

  func attach() {
    UNUserNotificationCenter.current().delegate = self
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "DeepSeek Harness")
    let menu = NSMenu()
    let open = NSMenuItem(title: "打开 DeepSeek Harness", action: #selector(activateApp), keyEquivalent: "")
    open.target = self
    menu.addItem(open)
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    item.menu = menu
    statusItem = item
  }

  private var isRunning = false
  private var needsAttention = false

  func setBadge(running: Bool, needsAttention: Bool) {
    isRunning = running
    self.needsAttention = needsAttention
    let symbol = needsAttention ? "exclamationmark.circle.fill" : running ? "circle.fill" : "sparkles"
    statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "DeepSeek Harness")
    statusItem?.button?.contentTintColor = needsAttention ? .systemOrange : running ? .systemBlue : nil
  }

  /// Live turn state from the controller — the status item tracks running
  /// for real, not just at notification moments. Attention state wins until
  /// the pending approval/question is answered.
  func setRunning(_ running: Bool) {
    guard !needsAttention else { isRunning = running; return }
    setBadge(running: running, needsAttention: false)
  }

  /// Pending approval/question was answered — drop the attention badge and
  /// fall back to the live running state.
  func clearAttention() {
    setBadge(running: isRunning, needsAttention: false)
  }

  @objc private func activateApp() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.windows.first?.makeKeyAndOrderFront(nil)
  }

  private func post(id: String, title: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
  }

  // 横幅可在 设置→通用 里关掉（AppPrefs）；菜单栏状态图标不受开关
  // 影响，始终反映实时状态。

  func notifyApprovalNeeded(toolName: String) {
    setBadge(running: true, needsAttention: true)
    guard !NSApp.isActive, AppPrefs.notifyAttention else { return }
    NSApp.requestUserAttention(.informationalRequest)
    post(id: "approval", title: "DSH 需要你的许可", body: "请求执行：\(toolName)")
  }

  func notifyQuestionNeeded() {
    setBadge(running: true, needsAttention: true)
    guard !NSApp.isActive, AppPrefs.notifyAttention else { return }
    NSApp.requestUserAttention(.informationalRequest)
    post(id: "question", title: "DSH 有问题要问你", body: "点击查看并回答")
  }

  func notifyTurnFinished(summary: String) {
    setBadge(running: false, needsAttention: false)
    guard !NSApp.isActive, AppPrefs.notifyTurnEnd else { return }
    post(id: "turn-end", title: "DSH 已完成", body: summary)
  }
}

extension NativeAlerts: UNUserNotificationCenterDelegate {
  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
    // 与悬浮圈点击同一直达通道：有刚派发的语音任务就直接进那条会话。
    Task { @MainActor in FloatingBubbleManager.shared.bubbleClicked() }
    completionHandler()
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    completionHandler([.banner, .sound])
  }
}
