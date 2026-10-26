# Agent Note: Consolidate the app on a native workbench design system

Status: implemented - the app now uses one native workbench visual language

## Problem

The app centralizes colors and spacing, but the visual language still mixes:

- a decorative translucent sea gradient and layered glass washes;
- large rounded cards and pill-shaped labels used for unrelated semantics;
- SF Rounded transcript/composer text beside default and monospaced text;
- many hard-coded font sizes and non-zero tracking values;
- button styles with pressed feedback but no hover treatment;
- one brand hue plus multiple tinted surfaces competing for hierarchy.

The result reads as several locally designed components rather than one native
macOS workbench. The latest product direction is a refined, unified interface
without generic “AI UI” signals, while retaining a restrained product-blue brand
identity.

## Decision

- Replace the decorative canvas gradient with one neutral canvas and mostly
  opaque structural surfaces.
- Keep the original Logo unchanged and use its rendered aqua background
  (`#A2E4E0`) as the single primary color for emphasis and primary actions with
  white text;
  amber and coral remain semantic only.
- Add shared `DSHType` roles and migrate core surfaces to those roles. Use native
  SF default typography rather than Rounded for transcript and controls.
- Remove positive letter tracking from body and UI text.
- Tighten the shared radius scale and default cards to a compact native
  workbench geometry.
- Replace text pills with small rounded rectangles; reserve circles for dots,
  avatars, and icon-only controls.
- Give primary, secondary, and ghost buttons shared hover, pressed, disabled,
  and minimum-hit-area behavior.
- Apply the system to the sidebar, header, transcript, reasoning panel, composer,
  workbench chrome, badges, and Markdown body so the app reads as one product.

## Alternatives considered

- **Keep jelly-sea and only polish individual screens.** Rejected because the
  fragmentation comes from the shared tokens and component defaults.
- **Replace SF with a bundled display font.** Rejected because a native coding
  workbench benefits from macOS typography, dynamic sizing, accessibility, and
  predictable rendering; a branded font would add dependency and maintenance.
- **Remove all color.** Rejected because the product still needs a recognizable
  accent and clear running/error semantics.
- **Flatten every surface into plain backgrounds.** Rejected because editor,
  composer, selection, and overlays still require controlled depth.

## Acceptance criteria

- Core screens use one neutral palette and one interactive accent.
- Structural surfaces are mostly opaque; no decorative app-wide gradient.
- Core text roles come from shared typography tokens with zero tracking.
- Shared radii are tighter and consistent across cards, fields, and overlays.
- Primary/secondary/ghost buttons have consistent hover and pressed behavior.
- Transcript, reasoning, composer, sidebar, and workbench snapshots remain
  readable in light and dark appearance.
- Existing behavior and keyboard flows are unchanged.

## Risks

- Existing screenshots and pixel-color assertions will change.
- Making surfaces more opaque reduces the previous glass effect; this is
  intentional to improve hierarchy and reduce visual noise.
- Some feature-specific DSL panels may still retain local spacing until the next
  design-system pass; they must not introduce new tokens or font families.

## Consequences

- The decorative app-wide gradient and translucent layered surfaces are gone;
  hierarchy now comes from a cool neutral canvas, near-opaque surfaces, and one
  restrained product-blue accent.
- Typography is centralized through shared SF roles, with rounded display fonts
  and non-zero tracking removed from core surfaces.
- Card and field radii are tighter, and pill labels are replaced by compact
  rounded rectangles except for dots and circular icon controls.
- Shared primary, secondary, ghost, and icon buttons now expose hover, pressed,
  disabled, and minimum-hit-area behavior consistently.
- Sidebar, conversation header, transcript, reasoning status, composer,
  workbench chrome, settings, and Markdown text now read from the same system.

## Verification

The native typecheck, all light/dark UI snapshots, browser smoke, and
`native-contract` suite passed after the migration. A real non-tool turn
retained the collapsed live status, the final answer contained no reasoning
text, and the installed app was refreshed through the fast in-place path.
`scripts/test-design-system.sh` now blocks rounded core type, manual tracking,
the legacy app gradient, and removal of the shared typography/icon-button
tokens.
