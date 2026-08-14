# Agent Note: Image attachments open in a zoomable lightbox instead of only a fixed inline thumbnail

Status: implemented

## Problem

`AttachmentPreview` rendered a fetched image as `Image(nsImage:).resizable().scaledToFit().frame(maxWidth: 280, maxHeight: 220)` with no way to see it larger — a screenshot with small text, a diagram, or anything denser than the fixed 280×220 inline frame was illegible with no recourse. `macos/WEB_PARITY.md` named this directly: the web client has a lightbox
(`ImageLightbox.tsx`) and cross-message rail; native had neither.

## Decision

Added a click-to-open `AttachmentLightbox` sheet: tapping the inline
thumbnail (now with a pointer-affordance tap gesture) presents a larger view
of the same already-fetched `NSImage` with pinch-to-zoom
(`MagnificationGesture`, clamped 0.2×–8×), scroll/drag panning (`ScrollView`
in both axes once zoomed past the fit size), explicit 缩小/适应窗口/放大
buttons for users who don't trackpad-pinch, and Escape-to-close
(`.onExitCommand`) alongside the close button. Scoped to a single-image
lightbox for the image being viewed — not the cross-message attachment
*rail* the web client also has (a strip of every image sent/received across
the whole session), which is a separate, larger feature left open in
`macos/WEB_PARITY.md`.

## Alternatives considered

- **`QLPreviewPanel` (system Quick Look).** More "free" native chrome (space
  bar to preview, system-standard zoom/pan) but requires wiring
  `QLPreviewPanelDataSource`/`Delegate` and `acceptsPreviewPanelControl`/
  `beginPreviewPanelControl`/`endPreviewPanelControl` into the app's
  responder chain — SwiftUI has no first-class integration point for this,
  and doing it via an `NSViewRepresentable` shim is a known source of
  flaky focus/lifecycle bugs when the hosting SwiftUI view is inside a
  `LazyVStack`/`ScrollView` (exactly this attachment's container). A plain
  SwiftUI sheet is self-contained or less error prone here; revisit
  `QLPreviewPanel` if the app later has other non-image attachment types
  that would benefit from Quick Look's broader format support.

## Consequences

An attachment the user needs to actually read (not just glance at) is now
reachable without leaving the app or resorting to macOS's own screenshot
tools. The cross-message attachment rail and non-image attachment types
remain open, tracked in `macos/WEB_PARITY.md`.
