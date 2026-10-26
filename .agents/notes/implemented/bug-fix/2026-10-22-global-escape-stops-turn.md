# Agent Note: Make Escape stop the running turn from the main window

Status: implemented - controlled main-window Escape now stops the displayed running turn

## Problem

The Composer handles Escape only while its `TextEditor` has focus. When focus is
on the transcript, sidebar, tool detail, or the right workbench, Escape does
nothing even though the turn is still running. The stop control is therefore
the only reliable termination path outside the composer.

The earlier composer keyboard decision rejected a global event monitor because
an unscoped monitor could steal Escape from dialogs, menus, popovers, and input
method composition. That concern remains valid; the fix must add coverage
without broadening Escape into those contexts.

## Decision

- Install one process-wide local key monitor owned by a shared coordinator.
- Consume plain, non-repeating Escape only when:
  - the app is active and the event belongs to the current main window;
  - no sheet, visible popover/child window, or menu window owns the event;
  - the first responder is not an editable text view;
  - the displayed root or subagent turn is running.
- Call `HarnessController.stop()`, which already routes root cancellation and
  continuable-subagent interruption correctly.
- Keep the existing Composer `.onKeyPress(.escape)` path for editable input so
  slash/mention palettes and IME cancellation retain priority.
- Expose `Esc` in the stop button help and documentation.
- Cover the decision matrix with pure policy tests.

## Alternatives considered

- **Add only a menu command with Escape.** Rejected because focused controls such
  as a WebView or custom workbench can consume the key before menu dispatch.
- **Intercept every Escape unconditionally.** Rejected because it would break
  sheets, popovers, menus, and IME candidate cancellation.
- **Duplicate Escape handling inside every view.** Rejected because coverage
  would drift and the same turn could receive duplicate cancellation requests.
- **Remove the composer-specific handler.** Rejected because it owns the
  slash/mention and IME precedence rules.

## Consequences

- Escape stops a running root turn when focus is outside editable text in the
  main window, including transcript, sidebar, tool detail, and workbench content.
- Escape in an editable text field remains handled by the existing composer
  logic, preserving slash/mention and IME priority.
- Escape in a sheet, popover, menu, or IME composition is not consumed by the
  task monitor.
- Running a continuable subagent routes Escape to subagent interruption through
  the existing `stop()` target routing.
- Repeated key-down events do not flood cancellation RPCs.
- A real running turn was interrupted from workbench focus and rendered
  `本轮已中断`; the complete 176-test unit/snapshot suite and Host smoke passed.

## Risks

- AppKit window classification varies across SwiftUI controls; guarded fallback
  should favor returning the event over stealing it.
- A cancellation request still waits for the Host `turn/end` event before the
  visible running state clears.
