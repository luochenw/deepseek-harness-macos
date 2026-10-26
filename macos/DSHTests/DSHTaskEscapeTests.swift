import AppKit
@testable import DSHAppLib

private func testTaskEscapePolicy_stopsOnlyPlainMainWindowEscape() throws {
  func allowed(
    modifiers: NSEvent.ModifierFlags = [],
    repeatKey: Bool = false,
    appActive: Bool = true,
    running: Bool = true,
    mainWindow: Bool = true,
    overlay: Bool = false,
    editableText: Bool = false
  ) -> Bool {
    DSHTaskEscapePolicy.shouldStop(
      keyCode: 53,
      modifiers: modifiers,
      isRepeat: repeatKey,
      isAppActive: appActive,
      isRunning: running,
      eventBelongsToMainWindow: mainWindow,
      hasBlockingOverlay: overlay,
      editableTextFocused: editableText)
  }

  try expect(allowed())
  try expect(!allowed(modifiers: .command))
  try expect(!allowed(modifiers: .shift))
  try expect(!allowed(repeatKey: true))
  try expect(!allowed(appActive: false))
  try expect(!allowed(running: false))
  try expect(!allowed(mainWindow: false))
  try expect(!allowed(overlay: true))
  try expect(!allowed(editableText: true))
  try expect(
    !DSHTaskEscapePolicy.shouldStop(
      keyCode: 36,
      modifiers: [],
      isRepeat: false,
      isAppActive: true,
      isRunning: true,
      eventBelongsToMainWindow: true,
      hasBlockingOverlay: false,
      editableTextFocused: false))
}

let dshTaskEscapeTests: [NamedTest] = [
  ("Task Escape policy only stops plain main-window Escape", testTaskEscapePolicy_stopsOnlyPlainMainWindowEscape),
]
