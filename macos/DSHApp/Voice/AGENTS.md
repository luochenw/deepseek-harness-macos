# Voice — agent rules
Scope: the speech engine and wake word, dictation routing, background task dispatch sessions, the voice settings page, the input button and the floating bubble. Does not pull browser/workbench state into voice and keeps no floating-bubble state in the core controller.
Key files: `DSHVoice.swift` (engine, tap installation, wake word), `DSHVoiceDispatch.swift` (routing snapshot and background dispatch), `FloatingBubble.swift` (floating ring), `VoiceInputView.swift` (mic button), `VoiceSettingsView.swift` (voice settings page).
Invariants (each must cite a Note or test):
- Dictation snapshots its route at start: foreground goes to the current session, background dispatches a separate session, and switching windows mid-way does not flip it — source: `feature/2026-08-17-voice-dispatch.md`.
- Background dispatch neither switches the UI nor occupies the input field — source: `feature/2026-08-17-voice-dispatch.md`.
- With wake-word auto-send off, foreground and background dictation results both stay in the Composer — source: `macos/DSHTests/DSHVoiceTests.swift` ("VoiceRoute preserves text when auto-send is off").
- Before installing a tap it must pass `VoiceTapGate` format/buffer validation; a running engine is not a reason to skip it — source: `bug-fix/2026-10-28-voice-tap-nsexception-root-cause.md`.
- The floating bubble adds no state to `HarnessController`; its red dot is derived from `$isRunning` — source: `feature/2026-08-17-floating-bubble.md`.
Before reporting done: `./scripts/test-macos-native.sh --unit` and `./scripts/test-settings-ui.sh`.
Pitfalls:
- `installTap` raises an ObjC exception rather than a Swift error, so it can only be guarded up front, never caught — source: `bug-fix/2026-10-28-voice-tap-nsexception-root-cause.md`.
- Ad-hoc signing makes every refresh look like a new app, so TCC re-prompts for the microphone — source: `bug-fix/2026-10-22-voice-permission-stability.md`.
- `voice-diag.log` still has no rotation — source: `bug-fix/2026-10-28-voice-tap-nsexception-root-cause.md`.
