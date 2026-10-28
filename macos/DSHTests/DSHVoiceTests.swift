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
    VoiceRoute.dialog.commitAction(viaWake: true, autoSend: true, canSubmit: true, canSteer: false, canQueue: false),
    .submitCurrent)
  try expectEqual(
    VoiceRoute.dialog.commitAction(viaWake: true, autoSend: true, canSubmit: false, canSteer: true, canQueue: false),
    .steerCurrent)
  try expectEqual(
    VoiceRoute.dialog.commitAction(viaWake: true, autoSend: true, canSubmit: false, canSteer: false, canQueue: true),
    .queueCurrent)
  try expectEqual(
    VoiceRoute.background.commitAction(viaWake: true, autoSend: true, canSubmit: false, canSteer: false, canQueue: false),
    .dispatchBackground)
}

private func testVoiceRoute_commitActionKeepsTextWhenAutoSendIsOff() throws {
  try expectEqual(
    VoiceRoute.background.commitAction(viaWake: true, autoSend: false, canSubmit: false, canSteer: false, canQueue: false),
    .fillComposer)
  try expectEqual(
    VoiceRoute.dialog.commitAction(viaWake: false, autoSend: true, canSubmit: true, canSteer: false, canQueue: false),
    .fillComposer)
  try expectEqual(
    VoiceRoute.dialog.commitAction(viaWake: true, autoSend: true, canSubmit: false, canSteer: false, canQueue: false),
    .fillComposer)
}

// VoiceTapGate exists because `AVAudioNode.installTap` raises an ObjC
// NSException (not a Swift error) when the bus already holds a tap; one of those
// unwinding through a @MainActor job corrupts the executor tracking and the app
// later dies at an unrelated isCurrentExecutor check. A running engine is NOT a
// reason to skip (review measured stop → remove → install as safe), so these
// pin the format/buffer decisions and the restart backoff instead.

private func testVoiceTapGateRefusesUnusableFormats() throws {
  try expect(!VoiceTapGate.formatIsUsable(sampleRate: 0, channels: 2))
  try expect(!VoiceTapGate.formatIsUsable(sampleRate: 44100, channels: 0))
  try expect(!VoiceTapGate.formatIsUsable(sampleRate: .nan, channels: 2))
  try expect(!VoiceTapGate.formatIsUsable(sampleRate: -48000, channels: 2))
  // 1 Hz / 300 channels looks non-zero but is not a real device.
  try expect(!VoiceTapGate.formatIsUsable(sampleRate: 1, channels: 2))
  try expect(!VoiceTapGate.formatIsUsable(sampleRate: 48000, channels: 300))
  guard case .skip = VoiceTapGate.decide(sampleRate: 0, channels: 2, engineIsRunning: false, bufferSize: 1024) else {
    throw TestFailure.message("zero-rate format must not reach installTap")
  }
}

private func testVoiceTapGateInstallsUsableFormat() throws {
  try expect(VoiceTapGate.formatIsUsable(sampleRate: 48000, channels: 1))
  guard case .install(let plan) = VoiceTapGate.decide(sampleRate: 48000, channels: 2, engineIsRunning: false, bufferSize: 2048) else {
    throw TestFailure.message("a healthy idle format should install")
  }
  try expectEqual(plan.sampleRate, 48000)
  try expectEqual(plan.channels, 2)
  // 2048 frames at 48 kHz is 43 ms; the plan clamps into the documented
  // 100–400 ms window instead of installing an out-of-range buffer.
  try expectEqual(plan.bufferSize, 4800)
}

private func testVoiceTapGateInstallsWhileRunning() throws {
  // A running engine with a stale tap is the dangerous case. Stop → remove →
  // install is safe, so the gate must NOT refuse it any more: refusing used to
  // strand the wake listener until the user toggled it off and on.
  guard case .install = VoiceTapGate.decide(sampleRate: 48000, channels: 2, engineIsRunning: true, bufferSize: 2048) else {
    throw TestFailure.message("a running engine must be torn down, not refused")
  }
}

private func testVoiceTapGateKeepsBufferInsideDocumentedWindow() throws {
  for rate in [8_000.0, 44_100.0, 48_000.0, 96_000.0, 192_000.0] {
    try expectEqual(VoiceTapGate.milliseconds(forFrames: VoiceTapGate.frames(forMilliseconds: 10, sampleRate: rate), sampleRate: rate), 100)
    try expectEqual(VoiceTapGate.milliseconds(forFrames: VoiceTapGate.frames(forMilliseconds: 900, sampleRate: rate), sampleRate: rate), 400)
  }
  try expectEqual(VoiceTapGate.frames(forMilliseconds: 200, sampleRate: 48_000), 9_600)
}

private func testVoiceTapGateDescribesNonFiniteRatesWithoutTrapping() throws {
  // These values used to reach `Int(sampleRate)` while building the skip
  // message, which traps (SIGTRAP, uncatchable) — the defensive branch itself
  // killed the process. Formatting must be trap-free for every non-finite input.
  for rate in [Double.nan, .infinity, -.infinity, 1e300, -1e300] {
    guard case .skip = VoiceTapGate.decide(sampleRate: rate, channels: 2, engineIsRunning: false, bufferSize: 1024) else {
      throw TestFailure.message("rate \(rate) must be skipped")
    }
    try expect(!VoiceTapGate.describeSampleRate(rate).isEmpty)
  }
  try expectEqual(VoiceTapGate.describeSampleRate(48_000), "48000")
  // The duration helpers must not trap on absurd rates either.
  try expect(VoiceTapGate.frames(forMilliseconds: 200, sampleRate: .nan) > 0)
  try expect(VoiceTapGate.milliseconds(forFrames: 1024, sampleRate: .infinity) <= 400)
}

private func testWakeRestartPolicySeparatesRotationFromBackoff() throws {
  // A quiet room: no failures → the plain 50 s rotation, never multiplied.
  try expectEqual(WakeWordListener.nextRestartDelay(
    failures: 0, regularInterval: 50, failureBase: 1.5, cap: 300), 50)
  // Real failures back off from the 1.5 s base.
  let first = WakeWordListener.nextRestartDelay(failures: 1, regularInterval: 50, failureBase: 1.5, cap: 300)
  let second = WakeWordListener.nextRestartDelay(failures: 2, regularInterval: 50, failureBase: 1.5, cap: 300)
  try expect((first ?? 0) > 1.5 && (second ?? 0) > (first ?? 0))
  // Breaker: no delay at all, so scheduleRestart stops instead of extending.
  for failures in WakeWordListener.failureBreakerLimit...8 {
    try expect(WakeWordListener.nextRestartDelay(
      failures: failures, regularInterval: 50, failureBase: 1.5, cap: 300) == nil,
      "failures=\(failures) must not reschedule")
  }
  // Backoff never exceeds the cap.
  try expect((WakeWordListener.nextRestartDelay(
    failures: 8, regularInterval: 50, failureBase: 1.5, cap: 300) ?? 0) <= 300)
}

let dshVoiceTests: [NamedTest] = [
  ("VoiceSettings.normalizedForWakeMatch folds fullwidth/case/punctuation", testNormalizedForWakeMatch_foldsFullwidthPunctuationAndCase),
  ("VoiceSettings.strippingTrailingEndPhrase strips known phrase", testStrippingTrailingEndPhrase_stripsKnownPhraseAndPunctuation),
  ("VoiceSettings.strippingTrailingEndPhrase leaves non-matching text alone", testStrippingTrailingEndPhrase_noMatchReturnsOriginalUnchanged),
  ("VoiceSettings.isCancelCommand matches whole-utterance phrase", testIsCancelCommand_matchesWholeUtteranceCancelPhrase),
  ("VoiceSettings.isCancelCommand rejects embedded phrase", testIsCancelCommand_rejectsEmbeddedCancelPhrase),
  ("VoiceRoute routes foreground and background auto-send", testVoiceRoute_commitActionRespectsForegroundAndAutoSend),
  ("VoiceRoute preserves text when auto-send is off", testVoiceRoute_commitActionKeepsTextWhenAutoSendIsOff),
  ("VoiceTapGate refuses zero/NaN sample rates", testVoiceTapGateRefusesUnusableFormats),
  ("VoiceTapGate installs a usable format", testVoiceTapGateInstallsUsableFormat),
  ("VoiceTapGate installs while the engine runs", testVoiceTapGateInstallsWhileRunning),
  ("VoiceTapGate clamps the tap buffer into 100-400ms", testVoiceTapGateKeepsBufferInsideDocumentedWindow),
  ("VoiceTapGate describes NaN/infinite rates without trapping", testVoiceTapGateDescribesNonFiniteRatesWithoutTrapping),
  ("Wake restart policy splits rotation from backoff", testWakeRestartPolicySeparatesRotationFromBackoff),
]
