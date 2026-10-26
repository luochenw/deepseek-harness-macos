# Agent Note: Improve transcript typography and code-block readability

Status: implemented - larger text, calmer spacing, and clearer code/table chrome

## Problem

The conversation transcript defaulted to macOS body/caption sizes and cramped
line spacing. Dense model answers, reasoning text, and long code blocks were
hard to scan or read, especially in the center column. The sidebar session rows
also used smaller type than their surrounding hierarchy, and the status footer
could flicker during a transient reconnect.

## Decision

Increase transcript and sidebar typography without changing content density in
the surrounding application:

- assistant/user prose uses 14.5 pt rounded text with five-point line spacing;
- markdown document prose uses 15.5 pt;
- heading scales and paragraph/list spacing are enlarged;
- reasoning text uses 13.5 pt with more line spacing;
- system rows use 12.5 pt;
- sidebar session titles and timestamps receive a modest size increase;
- list bullets use a small SF Symbol instead of a text glyph;
- quotes include a quote icon;
- tables include a `tablecells` header, stronger grid spacing, and outlined
  surfaces;
- fenced code blocks include a code icon, line count, copy button, larger
  monospaced text, line spacing, and stronger boundary chrome.

Transient Host disconnect/reconnect messages remain internal. The sidebar only
shows statuses that indicate a failure or require user action, preventing
WebSocket retry noise from visually flickering.

## Alternatives considered

- **Increase only the font size.** Rejected because denser prose still feels
  cramped without additional line spacing and block separation.
- **Switch to a serif document font.** Rejected because it would break the
  existing native rounded interface language and make mixed code/prose less
  coherent.
- **Use icons before every prose block.** Rejected because repetitive icons
  add noise; icons are reserved for structural blocks and actions.
- **Show a temporary reconnect banner.** Rejected because normal automatic
  recovery is common and the user explicitly requested removing this flicker.

## Consequences

- Long Chinese and English answers require slightly more vertical space but
  scan substantially better.
- Code and tables have clearer hierarchy and actions.
- Sidebar rows remain compact while matching the larger transcript scale.
- Only persistent connection failures are visible at the bottom of the sidebar.

## Verification

README, English README, and Web Parity were updated. Typography changes are
covered by the native UI snapshot suite; full tests, build, Host smoke, bundle
lint, and signature verification must pass before installation.
