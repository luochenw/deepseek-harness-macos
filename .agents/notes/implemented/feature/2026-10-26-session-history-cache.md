# Agent Note: Reuse complete in-memory session history when its Host version is unchanged

Status: implemented - complete sessions reopen from cache and only attach for new events

## Problem

Switching away from a fully loaded session and then reopening it started the
follow snapshot and complete-history loading path again. The follow snapshot
replaced the in-memory transcript with its small tail window, which made the
conversation disappear and reflow even when the Host session had not changed.

## Decision

- Record a completed-history cache version keyed by Host session id. Use
  `projections.asOfSeq` as the primary version and `updatedAt` only when the
  Host does not expose a sequence.
- Reuse the cached transcript and cached tool details only when the complete
  history was previously marked complete and the cached version is at least
  the Host summary version.
- Still attach the live follow stream when reusing cache so future events,
  approvals, running state, and projections remain current.
- Preserve cached messages through the follow snapshot when its cursor does not
  exceed the completed cache. If the snapshot is newer, fall back to the normal
  complete-history repair path.
- Advance the cached sequence from live events and update cached tool details
  after those events are applied.

## Alternatives considered

- **Never reopen the session stream.** Rejected because the session could still
  change externally or continue running while another session is displayed.
- **Cache only by wall-clock `updatedAt`.** Rejected because the Host exposes a
  durable projection sequence and that is the authoritative history version.
- **Keep the visible transcript but always reload all pages in secret.**
  Rejected because it still performs the expensive transport and folding work
  on every switch.
- **Persist history to disk across app launches.** Deferred because the current
  requirement is avoiding repeated loads while navigation reuses the same
  complete in-memory session; disk persistence needs separate invalidation,
  migration, and storage-bound decisions.

## Consequences

- Reopening an unchanged complete session is immediate and does not show the
  history-loading state or replace the transcript with a tail snapshot.
- Changed sessions still reload through the existing complete-history path.
- Running sessions retain their cached transcript while live events continue
  to append.
- The cache is process-local and automatically disappears when the App exits.
