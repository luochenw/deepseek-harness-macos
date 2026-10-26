# Agent Note: Keep the reasoning effort picker open

Status: implemented - the stable model/effort popover no longer closes during hover

## Problem

The composer model picker uses a nested SwiftUI `Menu` for reasoning effort.
While the parent composer is receiving Host updates, the native submenu can
close after roughly one second, before the user reaches the `Max` row. Model
and effort selection are both frequent session controls, so a mouse-only path
that depends on a short native submenu tracking window is not reliable.

The repository already has `ModelPickerPanel`, a stable popover containing the
live model catalog and the selected model's advertised effort rows. It is only
opened programmatically by `/model`.

## Decision

- Make the composer model label a normal button that toggles the existing
  `showModelPicker` binding.
- Use `ModelPickerPanel` for both direct clicks and `/model`.
- Remove the nested native reasoning `Menu`; effort rows remain derived from
  the selected model's advertised levels and selecting one still calls
  `session.selectModel`.
- Keep the current popover styling, selection checkmarks, and automatic close
  after a successful model or effort selection.

## Alternatives considered

- **Inline all effort rows in the outer native menu.** Rejected because it
  removes the timed submenu but makes the model menu unnecessarily long and
  still leaves selection inside a transient native menu.
- **Delay Host-driven published-state updates while a menu is open.** Rejected
  because it would stall unrelated session status and require global menu
  lifetime tracking.
- **Build a custom AppKit NSMenu delegate.** Rejected because the existing
  SwiftUI popover already provides the required interaction without another
  menu implementation.

## Consequences

- Clicking the composer model label opens the model/effort panel directly.
- Model and effort choices are ordinary rows in one stable popover; there is no
  nested hover submenu to time out while the composer updates.
- `/model` continues to open the same panel.
- Selecting `Max` updates the composer label without dismissing the app before
  the click can be completed.
- The permission/composer snapshot suite now includes a populated model picker
  panel.

## Risks

- The popover is taller than the former compact menu because effort rows are
  visible directly; the live catalog currently remains within the window.
- A model catalog refresh while the popover is open can reorder rows, but the
  panel itself remains mounted and does not auto-dismiss.

## Verification

In the refreshed installed app, the popover remained present after more than
two seconds, selecting `xhigh` closed it normally, reopening and selecting
`max` updated the composer label to `· max`. The permission/composer snapshot
suite and complete native contract suite passed.
