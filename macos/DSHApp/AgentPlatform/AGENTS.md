# AgentPlatform — agent rules
Scope: the Agent Profile/Batch/Run wire models and state, the pure policy decisions, the execution and Profile management UI, and the Composer `@` mention. Does not implement Host-side orchestration or isolation, and performs no merge/cherry-pick itself.
Key files: `DSHAgentPlatform.swift` (wire models and run state), `DSHAgentPlatformPolicy.swift` (pure decision functions), `AgentPlatformView.swift` (profiles and execution UI).
Invariants (each must cite a Note or test):
- Once a batch capability snapshot is frozen, any missing field fails closed so a Profile cannot borrow the root agent's powers — source: `feature/2026-08-17-unified-agent-platform.md`.
- Routing, retry, integration and discard decisions are pure functions shared by the UI and the standalone fixture — source: `scripts/test-agent-platform-ui.sh` ("agent-platform-policy-check").
- Retry is forbidden when a Profile was deleted or is outside the active set, even if the run is marked retryable — source: `macos/DSHTests/DSHAgentPlatformTests.swift` ("Agent policy forbids retry after deletion").
- An integration request that is already in flight or already requested/integrating/adopted/discarded must not be reissued — source: `macos/DSHTests/DSHAgentPlatformTests.swift` ("Agent policy blocks duplicate integration request").
- Switching sessions clears all Agent execution state: batches, selected run, logs and integration requests — source: `macos/DSHTests/DSHAgentPlatformTests.swift` ("Session switch clears Agent execution state").
Before reporting done: `bash scripts/test-agent-platform-ui.sh`, `./scripts/test-agent-platform-runtime-script.sh`, `./scripts/test-macos-native.sh --unit`.
Pitfalls:
- The Profile/Batch wire contract is maintained on both sides; field drift is caught by the compile fixture and schema tests — source: `feature/2026-08-17-unified-agent-platform.md`.
- The workbench is only a container and routing layer; a migration must not use it as an excuse to rewrite the platform logic — source: `feature/2026-08-27-right-workbench-tabs.md`.
