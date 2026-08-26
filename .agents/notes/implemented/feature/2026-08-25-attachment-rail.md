# Agent Note: Session attachment rail

Status: implemented — expose image-bearing native transcript messages through a session-authorized rail

## Problem

The native client renders one currently modeled image only inside the message
that owns it.
Long sessions with screenshots, diagrams, and generated images require
scrolling through the full transcript to compare or reopen an earlier image.
The web-parity matrix explicitly lists the cross-message attachment rail as
open.

The existing `AttachmentPreview` also asks `session.attachment` using only
`hostCurrentSessionID`. That is correct for a root transcript but not for an
open subagent transcript: the Host authorizes an attachment by scanning the
exact session ID's durable events and rejects an image not referenced there.
The rail must therefore carry the correct source session, not only an
attachment ID.

## Decision

`DSHAttachmentRailItem` values are derived from
`HarnessController.displayedSession.messages`. Each item retains the message
occurrence ID, attachment reference, and authorization session ID. The
controller resolves that ID as the active subagent child session when a
subagent transcript overlays the conversation, otherwise the root
`hostCurrentSessionID`. No additional `@Published` attachment list is used.

The native UI renders a horizontal, lazy thumbnail strip below
`ConversationHeader` whenever
the derived item list is nonempty. A thumbnail opens the existing zoomable
lightbox, now parameterized by its attachment reference and source session.
Inline previews use the same source session and observe `DSHAttachmentStore`
directly so a completed asynchronous fetch redraws the image. The store
single-flights concurrent loads by immutable content-addressed attachment ID
and exposes an explicit retry action after a failed read.

History attachment decoding lives in shared `DSHAttachmentRef` helpers with a
matching live-message decoder. `applyLiveEvent` and
`applyLiveSubagentEvent` will preserve image references for settled user and
assistant messages, including local user-echo de-duplication. Pending local
user echoes and streaming assistant placeholders have explicit internal
markers, so relay messages and consecutive settled assistant messages cannot
overwrite unrelated transcript rows.

## Alternatives considered

- **Keep only message-local previews.** Rejected because it leaves the
  documented cross-message discovery gap unchanged and makes image-heavy
  transcripts expensive to navigate.
- **Store a second `@Published` attachment array on `HarnessController`.**
  Rejected because it can drift from history pagination, session switching,
  and subagent overlays; the messages already form the durable source of
  truth.
- **Always fetch using the root session ID.** Rejected because the Host's
  `session.attachment` route checks references in the exact requested
  session's durable event stream; child images can be rejected as
  unreferenced.
- **Build a new gallery-only screen.** Rejected for this slice because the
  existing lightbox already provides zoom, pan, and Escape dismissal. The
  rail only needs to make every image directly reachable.

## Consequences

- The rail can contain many images in a long transcript. `LazyHStack` ensures
  only visible thumbnails begin image fetches; the rail does not eagerly
  materialize decoded bitmaps.
- `DSHAttachmentStore` is keyed by DSH's immutable `sha256:` content-addressed
  attachment ID, verified from the bundled local attachment backend. Source
  session selection remains load-bearing because the Host authorizes each
  read against that session's durable event log.
- `HarnessController.Message` currently retains one attachment reference, so
  a Host message with multiple image blocks contributes its first image only.
  Modeling message attachments as an array remains a separate data-model
  change.
- Verification on August 25, 2026: native contracts and the red/blue
  attachment-rail offscreen snapshot passed; Swift units passed 36/36;
  Agent Platform Node contracts passed 91/91; the app built with DSH
  `0.1.0-rc.7`; and packaged Host smoke passed.
