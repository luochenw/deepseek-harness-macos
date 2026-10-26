import AppKit

enum DSHTaskEscapePolicy {
  static func shouldStop(
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags,
    isRepeat: Bool,
    isAppActive: Bool,
    isRunning: Bool,
    eventBelongsToMainWindow: Bool,
    hasBlockingOverlay: Bool,
    editableTextFocused: Bool
  ) -> Bool {
    let disallowed: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    return keyCode == 53
      && modifiers.intersection(disallowed).isEmpty
      && !isRepeat
      && isAppActive
      && isRunning
      && eventBelongsToMainWindow
      && !hasBlockingOverlay
      && !editableTextFocused
  }
}

/// Main-window fallback for task cancellation after focus leaves the composer.
/// Editable text keeps the Composer's informed Escape handling, while windows
/// owned by sheets, menus, or popovers never reach `stop()`.
@MainActor
final class DSHTaskEscapeMonitorCoordinator {
  static let shared = DSHTaskEscapeMonitorCoordinator()

  private weak var controller: HarnessController?
  private var monitor: Any?

  func attach(_ controller: HarnessController) {
    self.controller = controller
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      self?.handle(event) ?? event
    }
  }

  private func handle(_ event: NSEvent) -> NSEvent? {
    guard let controller, let mainWindow = NSApp.mainWindow else { return event }
    let responder = mainWindow.firstResponder
    let editableTextFocused = (responder as? NSTextView)?.isEditable == true
    let childWindowsVisible = mainWindow.childWindows?.contains(where: \.isVisible) ?? false
    let hasBlockingOverlay = mainWindow.attachedSheet != nil || childWindowsVisible
    let shouldStop = DSHTaskEscapePolicy.shouldStop(
      keyCode: event.keyCode,
      modifiers: event.modifierFlags,
      isRepeat: event.isARepeat,
      isAppActive: NSApp.isActive,
      isRunning: controller.displayedIsRunning,
      eventBelongsToMainWindow: event.window === mainWindow,
      hasBlockingOverlay: hasBlockingOverlay,
      editableTextFocused: editableTextFocused)
    guard shouldStop else { return event }
    controller.stop()
    return nil
  }
}
