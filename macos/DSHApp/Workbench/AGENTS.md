# Workbench — agent rules
Scope: the per-session multi-tab dock (execution / agent / tool / browser / Markdown), tab lifecycle, browser and read-only document rendering, and the related menu commands. Does not rewrite Agent-platform business logic, offers no file editing, and never hands page bodies to the model.
Key files: `DSHWorkbench.swift` (tab state and lifecycle), `WorkbenchView.swift` (dock composition), `NativeBrowserView.swift` (stable `WKWebView` host), `NativeMarkdownDocumentView.swift` (read-only document reader), `WorkbenchCommands.swift` (menu commands).
Invariants (each must cite a Note or test):
- Tabs are isolated per top-level session, and switching sessions restores that session's tabs — source: `feature/2026-08-27-right-workbench-tabs.md`.
- Every browser tab owns a stable `WKWebView`; it must not be rebuilt on body recomputation or tab switch — source: `feature/2026-08-27-right-workbench-tabs.md`.
- Model-requested browser tabs stay restricted to HTTP(S); `file://` is never used to read workspace files — source: `feature/2026-08-27-right-workbench-tabs.md`.
- Model documents and local images are validated and read through one `O_NOFOLLOW` descriptor, confined to the originating session's cwd — source: `bug-fix/2026-08-27-session-workbench-lifecycle-hardening.md`.
- Model tool calls open a tab only after a successful settlement; failures, cancellations and history replay open none — source: `macos/DSHTests/DSHWorkbenchTests.swift` ("Model workbench events open only after successful settlement").
Before reporting done: `./scripts/test-workbench-ui.sh` and `./scripts/test-macos-native.sh --unit`.
Pitfalls:
- A `WKWebView` rebuilt by SwiftUI silently loses page state — source: `feature/2026-08-27-right-workbench-tabs.md`.
- Downloads must write a sibling temp file and then replace; deleting the target first can lose the user's original — source: `bug-fix/2026-08-27-session-workbench-lifecycle-hardening.md`.
- In a narrow window the three-column minimum widths overflow, so the workbench is hidden while its tab state is kept — source: `bug-fix/2026-08-28-responsive-workbench-window.md`.
