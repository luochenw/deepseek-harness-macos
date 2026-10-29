import AppKit

/// App-level delegate: the only place that knows launch finished / reopen / terminate.
@MainActor
final class DSHAppDelegate: NSObject, NSApplicationDelegate {
  func applicationWillFinishLaunching(_ notification: Notification) {
    DSHExceptionDiagnostics.install()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    DSHExceptionDiagnostics.install()
    DSHAppLifecycle.markLaunchedAndAttach()
  }

  /// The only way back after the last window closes.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    DSHAppLifecycle.handleReopen()
  }

  func applicationWillTerminate(_ notification: Notification) {
    DSHAppLifecycle.terminate()
  }
}

/// Routes launch/reopen/quit through `NativeAlerts`.
@MainActor
enum DSHAppLifecycle {
  /// Never inferred from `NSApp.isRunning`, which is already true while scenes are built.
  private static var didLaunch = false
  private static weak var alerts: NativeAlerts?
  /// Strong: the controller must survive SwiftUI tearing its scene down.
  private static var terminationTarget: HarnessController?
  /// Unit tests assert the Host stops at most once across both quit paths.
  private(set) static var terminationStopCount = 0
  static var existingWindowActivator: (() -> Bool)?
  /// Controllers whose termination already ran, so the two quit paths cannot double-stop.
  private final class WeakController {
    weak var value: HarnessController?
    init(_ value: HarnessController) { self.value = value }
  }
  private static var terminated: [WeakController] = []

  static func install(_ alerts: NativeAlerts, terminationOwner: HarnessController) {
    Self.alerts = alerts
    // First owner wins: a throwaway test controller must not strand the quit hook.
    if terminationTarget == nil { terminationTarget = terminationOwner }
    alerts.facts = terminationOwner
    if didLaunch {
      alerts.attach()
      return
    }
    // Launch hasn't finished: `markLaunchedAndAttach()` will attach.
  }

  static func markLaunchedAndAttach() {
    didLaunch = true
    alerts?.attach()
  }

  /// True when AppKit should still create a new window (the `WindowGroup` default).
  static func handleReopen() -> Bool {
    let activate = existingWindowActivator ?? activateExistingWindow
    if activate() { return false }
    NSApp.activate(ignoringOtherApps: true)
    return true
  }

  /// Hidden or minimised main window → bring it back (skips panels).
  private static func activateExistingWindow() -> Bool {
    guard let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeKey }) else {
      return false
    }
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    return true
  }

  /// Still runs after the last window closes, unlike the view-level `.onReceive`.
  static func terminate() {
    terminationTarget?.stopForTermination()
  }

  /// True exactly once per controller, so `stopForTermination` stays idempotent.
  static func claimTermination(_ controller: HarnessController) -> Bool {
    terminated.removeAll { $0.value == nil }
    if terminated.contains(where: { $0.value === controller }) { return false }
    terminated.append(WeakController(controller))
    terminationStopCount += 1
    return true
  }

  /// Unit tests exercise both `install` branches; production never calls this.
  static func resetForTesting() {
    didLaunch = false
    alerts = nil
    terminationTarget = nil
    terminationStopCount = 0
    existingWindowActivator = nil
    terminated.removeAll()
  }
}
