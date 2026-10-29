import AppKit
import Dispatch
import UserNotifications
import os

/// Anything that can answer "is a user response still owed somewhere?".
@MainActor
protocol DSHBadgeFactsSource: AnyObject {
  /// True while ANY session has an unanswered approval or question (the "!" badge).
  var hasPendingUserAction: Bool { get }
  /// True while a wake-dispatched voice session still runs in the background.
  var hasBackgroundRunningWork: Bool { get }
}

/// The controller is the cross-session owner of both facts.
extension HarnessController: DSHBadgeFactsSource {
  var hasPendingUserAction: Bool {
    pendingApproval != nil || pendingQuestion != nil
      || !queuedApprovals.isEmpty || !queuedQuestions.isEmpty
  }
  var hasBackgroundRunningWork: Bool { !voiceTaskSessions.isEmpty }
}

/// The three Dock-badge states, in priority order.
enum DSHDockBadge: Equatable {
  case idle
  case running
  case attention

  var label: String? {
    switch self {
    case .idle: nil
    case .running: "•"
    case .attention: "!"
    }
  }
}

/// Dock badge and system notifications — native capability a WebView-based
/// client cannot provide. See
/// .agents/notes/implemented/feature/2026-08-14-native-menu-bar-and-notifications.md.
///
/// Writes are coalesced and only happen after `attach`, because
/// `NSApp.dockTile` must not be touched while SwiftUI builds scenes.
@MainActor
final class NativeAlerts: NSObject {
  private static let log = Logger(subsystem: "com.github.deepseek-harness-macos.app", category: "menubar")

  /// Written to the Dock, not merely requested.
  private var appliedBadge: DSHDockBadge?
  private var pendingBadge: DSHDockBadge?
  private var flushScheduled = false
  /// Bumped by `attach`/`detach` so a stale flush is dropped.
  private var generation = 0

  /// Logical attach state, set even in tests where no Dock is reachable.
  private(set) var isAttached = false
  /// Test seam: keeps badge writes and `UNUserNotificationCenter` away from the unit runner.
  var badgeWriter: ((_ label: String?) -> Void)?
  /// Unit tests poll this instead of sleeping.
  var hasScheduledFlush: Bool { flushScheduled }

  func attach() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !isAttached else {
      Self.log.debug("attach skipped: already attached in this process")
      return
    }
    isAttached = true
    generation &+= 1
    flushScheduled = false
    appliedBadge = nil
    // UNUserNotificationCenter raises "bundleProxyForCurrentProcess is nil" without a bundle.
    if badgeWriter == nil, Bundle.main.bundleIdentifier != nil {
      UNUserNotificationCenter.current().delegate = self
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    Self.log.notice("attach: dock badge enabled")
    // Replay the live state: nothing was written before attach.
    recomputeBadge()
  }

  /// Stops badge writes and clears the Dock badge.
  func detach() {
    dispatchPrecondition(condition: .onQueue(.main))
    generation &+= 1
    flushScheduled = false
    isAttached = false
    pendingBadge = nil
    appliedBadge = nil
    writeDockBadge(nil)
    Self.log.notice("detach: dock badge cleared")
  }

  private var isRunning = false
  private var needsAttention = false

  /// Records the wanted badge and schedules at most one write per runloop turn.
  func setBadge(running: Bool, needsAttention: Bool) {
    let wasAttention = self.needsAttention
    isRunning = running
    self.needsAttention = needsAttention
    let wanted: DSHDockBadge = needsAttention ? .attention : running ? .running : .idle
    guard pendingBadge != wanted || appliedBadge != wanted else { return }
    pendingBadge = wanted
    if wanted == .attention, !wasAttention {
      flushBadge(generation: generation)
      return
    }
    guard !flushScheduled else { return }
    flushScheduled = true
    let scheduledGeneration = generation
    // Next turn, not now: the caller may still be publishing state inside a turn/end handler.
    DispatchQueue.main.async { [weak self] in self?.flushBadge(generation: scheduledGeneration) }
  }

  private func flushBadge(generation flushGeneration: Int) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard flushGeneration == generation else {
      Self.log.debug("flush discarded: stale attach generation")
      return
    }
    flushScheduled = false
    guard let wanted = pendingBadge else { return }
    pendingBadge = nil
    guard appliedBadge != wanted else { return }
    guard isAttached else {
      Self.log.debug("flush skipped: not attached")
      return
    }
    appliedBadge = wanted
    writeDockBadge(wanted.label)
    Self.log.debug("flush: dock badge written badge=\(wanted.label ?? "nil", privacy: .public)")
  }

  private func writeDockBadge(_ label: String?) {
    if let badgeWriter {
      badgeWriter(label)
      return
    }
    NSApp?.dockTile.badgeLabel = label
  }

  /// Single source of truth for "!": any session still waiting on an approval or a question.
  weak var facts: (any DSHBadgeFactsSource)?
  private var hasPendingUserAction: Bool { facts?.hasPendingUserAction ?? false }

  /// Live turn state, so the badge tracks running rather than only notification moments.
  func setRunning(_ running: Bool) {
    isRunning = running
    recomputeBadge()
  }

  func recomputeBadge() {
    setBadge(
      running: isRunning || (facts?.hasBackgroundRunningWork ?? false),
      needsAttention: hasPendingUserAction)
  }

  /// Pending approval/question was answered — drop the attention badge and
  /// fall back to the live running state.
  func clearAttention() {
    recomputeBadge()
  }

  private func post(id: String, title: String, body: String) {
    guard Bundle.main.bundleURL.pathExtension == "app" else { return }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
  }

  // 横幅可在 设置→通用 里关掉（AppPrefs）；Dock 角标不受开关影响，始终 反映实时状态。

  func notifyApprovalNeeded(toolName: String) {
    recomputeBadge()
    guard !NSApp.isActive, AppPrefs.notifyAttention else { return }
    NSApp.requestUserAttention(.informationalRequest)
    post(id: "approval", title: "DSH 需要你的许可", body: "请求执行：\(toolName)")
  }

  func notifyQuestionNeeded() {
    recomputeBadge()
    guard !NSApp.isActive, AppPrefs.notifyAttention else { return }
    NSApp.requestUserAttention(.informationalRequest)
    post(id: "question", title: "DSH 有问题要问你", body: "点击查看并回答")
  }

  func notifyTurnFinished(summary: String) {
    recomputeBadge()
    guard !NSApp.isActive, AppPrefs.notifyTurnEnd else { return }
    post(id: "turn-end", title: "DSH 已完成", body: summary)
  }
}

extension NativeAlerts: UNUserNotificationCenterDelegate {
  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
    // 与悬浮圈点击同一直达通道：有刚派发的语音任务就直接进那条会话。
    Task { @MainActor in
      // Same reopen path as the Dock icon: build a window instead of no-op'ing.
      _ = DSHAppLifecycle.handleReopen()
      FloatingBubbleManager.shared.bubbleClicked()
    }
    completionHandler()
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    completionHandler([.banner, .sound])
  }
}
