# Agent Note: Gate AVAudioEngine tap installs, and log swallowed NSExceptions

Status: implemented — tap installs are gated, plus a non-crashing exception logger; ROOT CAUSE NOT CONFIRMED

## Problem

On macOS 27 beta the App always dies inside
`swift_task_isCurrentExecutorWithFlagsImpl → SerialExecutorRef::isMainExecutor()`
with a tiny fault address (`0x7c8`, `0x1`, `0x62100`, …). Two stacks dominate:
`MenuBarClientCore` via `__CFRunLoopDoBlocks`, and
`NSViewResponder.platformCurrentEvent → MainActor.assumeIsolated`.

All 16 `DSH-*.ips` reports carry a parked thread named
`HIE: M_ …` (an HIServices/AppKit helper thread) whose frame list contains the
sentinel `SOME_OTHER_THREAD_SWALLOWED_AT_LEAST_ONE_EXCEPTION`. That sentinel is
exactly what the swift runtime emits from `ExecutorTrackingInfo::leave()` when an
**Objective-C exception unwound through a Swift concurrency job**: the leave
bookkeeping has no landing pad, so the tracking info is left unbalanced.

From then on every `@MainActor` isolation check reads the stale executor record
and faults — the crash location is a *symptom*, and it can be any framework call
that happens to run a `MainActor.assumeIsolated` (menu validation, hover
hit-testing, `.help` tooltip bridging). This matches swiftlang/swift#89197 and
the identically-shaped reports on the same OS build (cmux#8952,
Looped Whisper#72, SuperCmd#202, UTM#8006, CodexBar#2250).

**What is NOT established: which exception was swallowed, or that the voice
engine raised it.** All 16 `DSH-*.ips` reports list neither `AVFAudio` nor
`AVFoundation` nor `Speech` in `usedImages`, and none has an
`com.apple.audio.IOThread.client` thread — so no recording graph was alive at
crash time. The audio path below is a real raise hazard that can produce the
same *shape* of corruption, but it is not the proven source. The exception
logger added here exists to find the actual one.

What *is* measured: `AVAudioNode.installTap(onBus:bufferSize:format:)` raises
`NSException` (`required condition is false: nullptr == Tap()`) when bus 0 still
holds a tap. `engine.start()` and `prepare()` do **not** raise on an
already-running engine (measured by the cross-review; an earlier draft of this
note claimed otherwise — that was wrong).

`WakeWordListener` is the highest-risk caller: it is `@MainActor`, restarts on a
50 s timer, and every restart ran `removeTap` + `installTap` + `start()` with
whatever `inputNode.outputFormat(forBus: 0)` returned — including 0 Hz — and a
fixed 1.5 s retry that could re-enter `beginRecognition()` while the previous
engine was still live. `AppleSpeechTranscriber` and `LocalServerTranscriber` had
the same unguarded install.

## Decision

**Root cause is not confirmed.** Everything below is either a measured raise
hazard closed off, or instrumentation to find the real exception. Nothing here
should be described as "the crash is fixed".

- Add `VoiceTapGate` (pure Swift, no AVFoundation objects): `formatIsUsable`
  rejects NaN/out-of-range sample rates (accepted band 8–192 kHz) and channel
  counts outside 1–8; `bufferSize` is converted through a 100–400 ms window
  (AVAudioNode.h's documented range) instead of a fixed frame count that is out
  of range at 8 kHz or 192 kHz. A *running* engine is no longer a reason to
  skip — the review measured stop → remove → install as safe, and refusing it
  stranded the listener until the user toggled it.
- Add `installVoiceTap(_:bufferSize:onSkip:block:)`: reads the format once,
  consults the gate, then stops, removes and installs. On skip it logs and calls
  `onSkip` without touching the engine.
- Add `removeVoiceTap(_:)`: `stop()` then `removeTap(onBus: 0)`,
  **unconditionally** — neither call needs an input device. The earlier version
  returned early without one, which left the engine running with its tap
  attached whenever the default input vanished mid-recording (mic indicator
  stuck on, next install refused forever).
- Add `voiceInputDeviceAvailable` / `voiceInputFormat`: probes
  `kAudioHardwarePropertyDefaultInputDevice` through `AudioObjectGetPropertyData`
  — CoreAudio's own idea of the default input. **Not** `AVCaptureDevice` (an
  earlier draft used it): capture's list omits aggregate devices and virtual
  sound cards (BlackHole, Loopback) that the HAL records from fine, which would
  have disabled dictation for those users.
- Wake listener state machine: a failed install now clears `isActive`, bumps the
  failure streak and schedules a retry instead of silently stopping; `start()`
  is followed by an `isRunning` check that tears the graph down again on failure.
  **Rotation and backoff are separate**: the ~50 s SFSpeech rotation is a plain
  timer (`scheduleRestart(regularInterval:)`) that is never multiplied by
  failures, while recovery after a real failure uses
  `nextRestartDelay(failures:…)` (1.5 s base, doubling, capped at 300 s) and is
  refused outright once the streak reaches `failureBreakerLimit`. Failures are
  only counted for install/start/isRunning and *real* task errors;
  `isTearingDown` makes the listener ignore the error callback its own
  `endAudio()`/`cancel()` produces (the old counting walked a quiet, healthy
  listener into the breaker). `start()` and `stop()` reset the streak, so the
  UI's "重开唤醒词开关可重试" is true.
- `NativeAlerts.attach` only touches `UNUserNotificationCenter` when a bundle
  identifier exists (the framework raises `bundleProxyForCurrentProcess is nil`
  without one) — same swallowed-exception shape on a `@MainActor` path.
- **`Info.plist` has NO `NSApplicationCrashOnExceptions` key.** An earlier draft
  added one; the cross-review measured that AppKit never reads it from
  Info.plist, so it was dead. `Info.plist` is unchanged by this work.

### Exception diagnostics (non-crashing)

`DSHExceptionDiagnostics` overrides `reportException(_:)` on
`object_getClass(NSApp)` — SwiftUI builds `SwiftUI.AppKitApplication`, so an
`NSPrincipalClass` subclass is never instantiated and its override never runs
(measured by the cross-review).

Installation uses `class_addMethod` on that subclass and falls back to
`method_setImplementation` when it already carries the selector, **never**
`method_exchangeImplementations`. Exchange would mutate `NSApplication` itself
(the subclass does not override the selector; `class_getInstanceMethod` reaches
up the hierarchy), affect every instance in the process, and a second install
would swap the hook back out while the log still claimed it was on. The original
IMP is saved and invoked directly, `isInstalled` compares the live IMP against
ours, and repeated installs are idempotent.

On every call it appends name, reason, the first 40 stack frames, thread and
timestamp to `~/Library/Application Support/DeepSeek Harness/dsh/exception-diag.log`,
emits an `os_log` (`subsystem com.github.deepseek-harness-macos.app`, category
`exception`), and then calls the original implementation — control flow is
unchanged. It is installed from `DSHAppDelegate.applicationWillFinishLaunching`,
re-attempted in `applicationDidFinishLaunching`, and writes
`installed on <class> (implementation from <owner>)` on success so the log proves
the hook took and says which class actually owned the method.

Safety: one record per second (suppressed counts are reported on the next
accepted line), rotation to `exception-diag.log.1` past 1 MB, file mode 0600
(`reason` can contain user paths/URLs), and the file append is dispatched to a
serial background queue so the caller does not pay the ~8 ms open/seek/write.
`os_log` stays synchronous. Every filesystem error is dropped.

The re-entrancy guard is a **monotonic deadline** (`isLoggingUntil`), not a
`defer`-reset flag: `defer` does not run when an Objective-C exception unwinds
through the frame, so a Bool could latch forever. Even so, the guarantee is
"best effort", not "never raises": the logger's own Win32-free calls
(`format`, `callStackSymbols`, a dispatch enqueue) are not expected to raise, but
nothing can prove a raise inside a raise handler is survivable.

**Limits, stated plainly:** it only sees exceptions that reach
`reportException`. Exceptions caught *inside* SwiftUI/AppKit (including the
`MenuBarClientCore` and `NSViewResponder` paths in our own reports) never arrive,
and logging does not prevent the executor-tracking corruption — it only names
the exception after the fact.

### Diagnostic switch: the only one that works

`defaults write com.github.deepseek-harness-macos.app NSApplicationCrashOnExceptions -bool YES`
then launch the app, reproduce, and read the crash report's
`lastExceptionBacktrace`. Afterwards:

`defaults delete com.github.deepseek-harness-macos.app NSApplicationCrashOnExceptions`

Cost: **every** swallowed exception becomes an immediate crash (SIGTRAP in
`+[NSApplication _crashOnException:]`). With this switch on, a machine that
currently limps through several swallowed exceptions will crash on the first
one — that is the point, but it makes the app unusable for normal work, so turn
it on only for a reproduction run and delete the default right after. The plist
key does **not** work; do not put it in `Info.plist`.

## Alternatives considered

- **Catch the NSException.** Not possible: Swift has no `@catch`, and an
  `NSException` that unwinds through a concurrency job is exactly the corruption
  we are trying to avoid — catching it at the crash site is too late.
- **Only wrap the calls in `try?`/do-catch.** They are not Swift-throwing APIs;
  `installTap` raises an ObjC exception. Guarding the *inputs* is the only way to
  keep it from raising.
- **Only debounce the wake listener.** Fixes one caller; the STT engines had the
  same unguarded install path and would keep the bug reachable.
- **Set `SWIFT_IS_CURRENT_EXECUTOR_LEGACY_MODE_OVERRIDE=legacy`.** Turns the
  crash into a warning but does not fix the unbalanced executor tracking, is an
  environment variable that cannot ship, and is ignored by restricted processes.
- **Build with `-O` / newer minos / `-swift-version 6`.** A 12–15 instance
  A–E matrix (plain swiftc, `-O`, `minos 27`, Swift 6, Xcode defaults) ran
  8–10 min each with zero crashes; build flags only change which check path is
  taken, not whether the tracking info is corrupted. `-O` additionally has its
  own hop regression (swiftlang/swift#92915).
- **Change deployment target to 27.** The legacy-vs-crash branch is chosen by
  `dyld_program_sdk_at_least(fall2024)` on the linked SDK, not by minos
  (swift/Bincompat.cpp), so this cannot help.
- **A custom `NSApplication` subclass as `NSPrincipalClass`.** Dead code under
  SwiftUI: `App.main()` instantiates `SwiftUI.AppKitApplication` itself and
  ignores `NSPrincipalClass` (measured by the cross-review), so the override is
  never called. Replaced by the `reportException` swizzle above.
- **`NSApplicationCrashOnExceptions` in `Info.plist`.** Measured to be ignored —
  AppKit reads that key from the defaults domain only. Removed; the `defaults
  write` form is documented instead.
- **Remove all `.help()` on macOS 27.** A workaround for one *symptom* path
  (notebook#3); it hides the tooltip feature and leaves every other
  `assumeIsolated` call site exposed.

## Consequences

- **The crash root cause is still unknown.** 16 `.ips` reports contain no
  AVFAudio/AVFoundation/Speech image and no audio IO thread, so this work covers
  one measured raise path (tap install) and one state machine, not the reported
  failure. Do not describe a release as fixing it.
- The three audio paths can no longer raise from `installTap`, and an unusable
  format surfaces as a status line + `voice-diag.log` entry instead.
- Device changes mid-recording are still unhandled: no
  `AVAudioEngineConfigurationChange` observer exists, so a stale tap format is
  only cleaned up on the next restart.
- `VoiceTapGate` (including traps on NaN/∞/1e300 in the skip message) and
  `WakeWordListener.nextRestartDelay` are pure logic and unit-tested;
  `DSHExceptionDiagnostics`'s rate limit, rotation, formatting and path are too.
  None of this drives a real `AVAudioEngine`, so the install sequence itself is
  only covered by the cross-review's manual measurements.
- The exception logger is the actual next step: it will name the swallowed
  exception the first time it reaches `reportException`. Exceptions swallowed
  inside SwiftUI/AppKit stay invisible — for those the only tool is the
  `defaults write … NSApplicationCrashOnExceptions -bool YES` run, which turns
  each swallow into an immediate crash so the report carries
  `lastExceptionBacktrace`.
- Verified in a throwaway SwiftUI app (not the product): the hook installs on
  `SwiftUI.AppKitApplication` (implementation owned by `NSApplication`), four
  consecutive `install()` calls keep `isInstalled == true` and leave
  `NSApplication`'s own IMP untouched; a caught-then-reported exception lands in
  `exception-diag.log` with name, reason and 33 frames; three reports in one
  second collapse to one line plus `suppressed=2` on the next accepted record; a
  report from a GCD worker is recorded as `thread=background`; the log is 0600;
  the process stays alive.
- Not verified on the user's machine: whether the wake listener was actually
  running during the crashes. `voice-diag.log` shows `[wake] start` twice after
  the last restart (02:37Z / 03:35Z local 22:37 / 23:35), so the resident
  listener was live across the 23:34 crash, but no per-restart entries existed.
  `scheduleRestart` now logs `[wake] restart in <n>s failures=<k> active=<bool>`
  on every cycle so the next report can be matched against it.

## Known follow-ups (not done in this round)

- **HAL probe is coarse** (review [重要-5]): `kAudioHardwarePropertyDefaultInputDevice`
  answers "who is the default input", not "can it record now". Adding
  `kAudioDevicePropertyDeviceIsAlive` + an input-scope stream count would close
  the gap where an exclusive/aggregate device passes the gate.
- **`voice-diag.log` still has no rotation** and is 0644; only
  `exception-diag.log` was hardened (review [建议-4]).
- **`installVoiceTap` has no integration test** — a fake `AudioTapHosting` that
  asserts call order (stop before remove before install, `inputNode` untouched
  when `tapInstalled == false`) is the missing seam (review [建议-1]).
- **`AVAudioEngineConfigurationChange` has no observer**, so a mid-recording
  device switch is only cleaned up on the next restart (review [建议-2]).
- **`DSHBrowserRuntime.deinit`'s KVO invalidate is belt-and-braces**, not a bug
  fix: the token deinit already unregisters (review [建议-1]).
