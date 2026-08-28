@testable import DSHAppLib

// VoiceSettings's wake/end/cancel-phrase matching has recently needed three
// separate fixes (see git log: "唤醒听写三修") — exactly the kind of pure
// string logic that's easy to silently regress, and cheap to pin down here.

private func testNormalizedForWakeMatch_foldsFullwidthPunctuationAndCase() throws {
  try expectEqual(VoiceSettings.normalizedForWakeMatch("小 D，小 D！"), VoiceSettings.normalizedForWakeMatch("小D小D"))
  try expectEqual(VoiceSettings.normalizedForWakeMatch("Ｈｅｌｌｏ"), "hello")
}

private func testStrippingTrailingEndPhrase_stripsKnownPhraseAndPunctuation() throws {
  let result = VoiceSettings.strippingTrailingEndPhrase("帮我写个函数，就这样")
  try expect(result.matched)
  try expectEqual(result.stripped, "帮我写个函数")
}

private func testStrippingTrailingEndPhrase_noMatchReturnsOriginalUnchanged() throws {
  let result = VoiceSettings.strippingTrailingEndPhrase("帮我写个函数")
  try expect(!result.matched)
  try expectEqual(result.stripped, "帮我写个函数")
}

private func testIsCancelCommand_matchesWholeUtteranceCancelPhrase() throws {
  try expect(VoiceSettings.isCancelCommand("算了"))
  try expect(VoiceSettings.isCancelCommand("  算了！ "))
}

private func testIsCancelCommand_rejectsEmbeddedCancelPhrase() throws {
  // The whole utterance must BE a cancel command, not merely contain one —
  // "算了吧，继续写" keeps going after "算了", so it isn't one.
  try expect(!VoiceSettings.isCancelCommand("算了吧，继续写"))
}

private func testVoiceRoute_commitActionRespectsForegroundAndAutoSend() throws {
  try expectEqual(
    VoiceRoute.dialog.commitAction(viaWake: true, autoSend: true, canSubmit: true, canQueue: false),
    .submitCurrent)
  try expectEqual(
    VoiceRoute.dialog.commitAction(viaWake: true, autoSend: true, canSubmit: false, canQueue: true),
    .queueCurrent)
  try expectEqual(
    VoiceRoute.background.commitAction(viaWake: true, autoSend: true, canSubmit: false, canQueue: false),
    .dispatchBackground)
}

private func testVoiceRoute_commitActionKeepsTextWhenAutoSendIsOff() throws {
  try expectEqual(
    VoiceRoute.background.commitAction(viaWake: true, autoSend: false, canSubmit: false, canQueue: false),
    .fillComposer)
  try expectEqual(
    VoiceRoute.dialog.commitAction(viaWake: false, autoSend: true, canSubmit: true, canQueue: false),
    .fillComposer)
  try expectEqual(
    VoiceRoute.dialog.commitAction(viaWake: true, autoSend: true, canSubmit: false, canQueue: false),
    .fillComposer)
}

let dshVoiceTests: [NamedTest] = [
  ("VoiceSettings.normalizedForWakeMatch folds fullwidth/case/punctuation", testNormalizedForWakeMatch_foldsFullwidthPunctuationAndCase),
  ("VoiceSettings.strippingTrailingEndPhrase strips known phrase", testStrippingTrailingEndPhrase_stripsKnownPhraseAndPunctuation),
  ("VoiceSettings.strippingTrailingEndPhrase leaves non-matching text alone", testStrippingTrailingEndPhrase_noMatchReturnsOriginalUnchanged),
  ("VoiceSettings.isCancelCommand matches whole-utterance phrase", testIsCancelCommand_matchesWholeUtteranceCancelPhrase),
  ("VoiceSettings.isCancelCommand rejects embedded phrase", testIsCancelCommand_rejectsEmbeddedCancelPhrase),
  ("VoiceRoute routes foreground and background auto-send", testVoiceRoute_commitActionRespectsForegroundAndAutoSend),
  ("VoiceRoute preserves text when auto-send is off", testVoiceRoute_commitActionKeepsTextWhenAutoSendIsOff),
]
