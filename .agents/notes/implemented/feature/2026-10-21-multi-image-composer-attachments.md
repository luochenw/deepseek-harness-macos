# Agent Note: Multi-image composer attachments and local preview

Status: implemented - the composer holds, inspects, removes, pastes, and submits several images

## Problem

The native composer stores at most one draft image. Picking files replaces the
previous selection, copied screenshots cannot be pasted into the editor, and the
draft is represented by a filename row with no visual preview or enlarged view.
The Host prompt wire format already accepts an ordered list of image content
blocks, so the limitation is entirely in the native composer and its submission
paths.

## Decision

Represent the composer selection as an ordered `[DraftImage]` with a bounded
maximum of 20 unique file paths. The attachment picker accepts multiple files
(`png`, `jpeg`, `webP`, and `gif`). Image paste accepts either copied image file
URLs or bitmap/TIFF image data; bitmap data is normalized to a temporary PNG so
every later submission path can read one stable local URL.

Render the selection as a horizontal thumbnail strip inside the composer. Each
thumbnail opens an enlarged, zoomable local-file preview, and each has a
separate remove control. The strip stays outside the text editor so deleting an
image never changes caret position or text.

Ordinary sends, running-turn queue/steer submissions, and continuable subagent
prompts all append every image as an ordered `DSHPromptContent.image` block after
the optional text block. The draft is captured by image ID before submission;
successful completion removes only those IDs, preserving images added while the
request was in flight. Agent Batch remains text-only and reports the existing
explicit unsupported-image status.

## Alternatives considered

- **Keep one `draftImage` and replace it on each paste.** Rejected because it
  cannot satisfy multi-image prompts and silently discards the previous image.
- **Attach images directly to the attributed text editor.** Rejected because it
  would couple attachment lifetime and deletion to text/caret semantics, making
  a thumbnail-only control harder to reason about and test.
- **Keep bitmap data only in memory and encode it at send time.** Rejected
  because file picker URLs and pasted screenshots would have different code
  paths and the running-draft capture would also need to clone image data.
- **Use a gallery screen instead of an in-composer preview.** Rejected because
  users need to verify and remove individual images before sending without
  leaving the conversation.
- **Allow Agent Batch to receive images in this change.** Rejected because its
  CLI/task contract accepts a text task and adding binary delivery would widen
  the protocol and persistence scope beyond the composer attachment surface.

## Consequences

- Pasting multiple copied image files adds all supported unique images in the
  pasteboard order.
- Pasting a screenshot/bitmap adds a readable PNG draft.
- Selecting multiple image files adds all of them, de-duplicates by normalized
  path, and enforces the public maximum with an accurate status message.
- Each thumbnail opens a zoomable preview, and its remove control removes only
  that image.
- A textless draft containing images is sendable.
- Root send, queue/steer, and continuable subagent submission preserve image
  order and no longer require `/`-prefixed text with images to use the command
  plane.
- Completion removes only the submitted image IDs; draft text edits and images
  added during submission remain.
- The native typecheck, unit suite, app build, packaged Host API smoke, and
  signature checks pass.

Verification on October 21, 2026: the complete native contract/UI suite and
150 unit tests passed, the packaged Host API smoke passed, and the signed app
bundle verified. In the running app, copying two Finder image selections
produced two removable thumbnails (without pasting their filenames as text),
both the zoomed preview and ordinary text paste worked, and a submitted image
received a real model response.

## Risks

- Very large images are base64-encoded into the prompt request, matching the
  existing Host contract but increasing memory and loopback request size.
- Pasted bitmap PNG files live in the user cache directory and are not eagerly
  garbage-collected.
- The transcript model still retains one attachment reference per durable
  message, so open native history can show only the first image from a
  multi-image Host message. Composer preview and Host submission remain
  multi-image in this scope.
