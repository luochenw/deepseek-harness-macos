# Composer — agent rules
Scope: draft editing and keyboard policy, draft images, the queue display and its mutation RPC, the busy-submit decision and the slash-command panel. Does not own session lifecycle or history paging, and holds no transcript state outside `HarnessController`.
Key files: `ComposerView.swift` (draft field and keyboard wiring), `DSHComposerSubmission.swift` (busy/steer submit decision), `DSHQueue.swift` (queue snapshots and mutation RPC), `DSHAttachments.swift` (draft image model), `NativeCommandPalette.swift` (slash panel), `QueueDockView.swift` (queue chrome).
Invariants (each must cite a Note or test):
- The submit mode while running is computed once by a pure policy: an empty queue steers directly and shows no queue chrome — source: `bug-fix/2026-10-23-direct-running-send-without-queue.md`.
- Queue chrome appears only after the snapshot settles (300ms debounce) — source: `macos/DSHTests/DSHPermissionAndSubmissionTests.swift` ("Queue chrome waits for a stable queue snapshot").
- Enter must be passed through while an IME composition is active (`.ignored`); only Esc stops the current turn — source: `bug-fix/2026-08-18-composer-keyboard-ime-esc.md`.
- Draft images stay ordered, are deduplicated by path, cap at 20, and a successful submit removes only the submitted IDs — source: `macos/DSHTests/DSHAttachmentTests.swift` ("Draft attachments deduplicate and enforce maximum").
- The slash panel appears only for a bare token, and picking while running must go through the busy submit path — source: `feature/2026-08-17-composer-slash-command-menu.md`.
- Global Esc only acts in the main window, outside editable text and with no modal on screen — source: `macos/DSHTests/DSHTaskEscapeTests.swift` ("Task Escape policy only stops plain main-window Escape").
Before reporting done: `./scripts/test-permission-composer-ui.sh` and `./scripts/test-macos-native.sh --unit`.
Pitfalls:
- The empty-queue direct-send rule means a running composer can no longer create the first queued message — source: `bug-fix/2026-10-23-direct-running-send-without-queue.md`.
- Large images enter the prompt as base64 — source: `feature/2026-10-21-multi-image-composer-attachments.md`.
- Pasted PNGs land in the user cache and are never garbage-collected — source: `feature/2026-10-21-multi-image-composer-attachments.md`.
