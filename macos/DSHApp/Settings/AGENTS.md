# Settings — agent rules
Scope: the settings window's sections, revisioned settings writes, provider and credential editing, the model catalogue and usage display, and local UI preferences. Never writes `settings.yaml` directly, never lets credential plaintext into app state, and does not own session, workbench or voice logic.
Key files: `DSHSettingsView.swift` (settings window sections), `DSHSettingsMutate.swift` (revisioned patch writes), `DSHCredentialRead.swift` / `DSHCredentialWrite.swift` (credential read/write), `DSHProviderAuthoring.swift` (provider editing drawer), `ModelUsageSettingsView.swift` (usage panel).
Invariants (each must cite a Note or test):
- Settings writes carry the revision they read, and a conflict recovers in place instead of stalling silently — source: `feature/2026-08-14-settings-conflict-recovery-ui.md`.
- Credential values never enter app state: the protocol returns only a `configured` boolean and the echo comes from reading `.credentials.yaml` locally — source: `feature/2026-08-18-api-settings-visible-values.md`.
- The edit drawer must not auto-select any credential reference — source: `scripts/test-settings-ui.sh` ("references.count").
- The usage panel shows only the Host's projection for this session and infers no balance or cost — source: `feature/2026-08-28-settings-model-usage.md`.
- Local UI preferences live in UserDefaults with one semantic: "never written = on" — source: `feature/2026-08-17-general-settings-fillout.md`.
Before reporting done: `./scripts/test-settings-ui.sh` and `./scripts/test-macos-native.sh`.
Pitfalls:
- A `ForEach` wrapping a `Button` with conditional branches makes the type checker mis-pick a generic overload — source: `architecture/2026-08-15-native-settings-ui-redesign.md`.
- The line-level `.credentials.yaml` parser only handles flat `KEY: value`; nested YAML reads as missing — source: `feature/2026-08-18-api-settings-visible-values.md`.
- A toggle backed by a file write must roll the UI back to the write result — source: `feature/2026-08-17-cross-session-relay.md`.
