# Design — agent rules
Scope: visual tokens (colour, radius, spacing, typography, button and card styles), brand artwork constants and scroll-indicator chrome. Holds no business state, sends no RPC and makes no split-layout decisions — those belong to the feature domains that own the views.
Key files: `DSHTheme.swift` (the only visual-token source), `NativeSeaArt.swift` (logo and whale artwork constants), `NativeScrollbars.swift` (scroll indicator chrome).
Invariants (each must cite a Note or test):
- `DSHTheme.swift` is the single visual-token source; new views must not invent colours, radii or spacing — source: `architecture/2026-08-17-ocean-design-system.md`.
- The primary accent is the rendered logo aqua, and primary buttons pair it with white labels — source: `scripts/test-design-system.sh` ("static let accentSolid = DSHBrandPalette.logoPrimary").
- The logo artwork and its `0xA2E4E0` background are frozen — source: `scripts/test-design-system.sh` ("0xA2 / 255, 0xE4 / 255, 0xE0 / 255").
- Core text uses the shared `DSHType` roles: no rounded design, no manual tracking, no legacy `canvasGradient` — source: `scripts/test-design-system.sh` ("tracking\\(").
- Amber and coral stay semantic (warning / destructive) and never carry brand emphasis — source: `architecture/2026-10-23-native-workbench-design-system.md`.
Before reporting done: `./scripts/test-design-system.sh` and `./scripts/test-macos-native.sh`.
Pitfalls:
- The artwork constants are shared by three call sites (floating ring, transcript indicator, icon generator); changing one leaves the brand inconsistent — source: `feature/2026-08-27-bubble-whale-daylight.md`.
- The icon generator is a hand-copied AppKit mirror, so any `NativeSeaArt.swift` constant change must be mirrored into `scripts/generate-app-icon.swift` — source: `feature/2026-08-27-bubble-whale-daylight.md`.
- In dark appearance no dark surface may be paired with a dark foreground — source: `architecture/2026-08-17-jelly-sea-theme.md`.
