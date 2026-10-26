# Agent Note: Stabilize voice permission identity and request fan-in

Status: implemented - stable signing and one shared permission request prevent repeated microphone prompts

## Problem

The installed app is ad-hoc signed. Its designated requirement is the current
build's cdhash, so every native refresh looks like a different application to
TCC and can invalidate microphone and speech-recognition grants.

TCC logs also show several microphone authorization requests from the same
process within one second. Multiple `WakeWordListener` instances can be created
by SwiftUI windows, and both the resident listener and manual dictation request
speech and microphone authorization independently. When registration status is
still undetermined, those concurrent calls can stack multiple system dialogs.

## Decision

- Select an installed Apple Development signing identity for local in-place
  refreshes when available. This produces a stable designated requirement based
  on bundle ID and signing certificate instead of the changing cdhash.
- Keep `CODESIGN_IDENTITY` overridable and retain ad-hoc signing as the fallback
  when no development identity exists.
- Make the resident wake listener process-wide rather than one object per
  composer/window.
- Add one shared permission coordinator that checks status first and coalesces
  concurrent speech/microphone requests into one in-flight operation.

## Alternatives considered

- **Ask users to re-approve after every refresh.** Rejected because it treats a
  signing-identity defect as expected behavior.
- **Use an identifier-only designated requirement with an ad-hoc signature.**
  Rejected because it would weaken TCC identity to a claim any ad-hoc executable
  could make; a real development certificate provides a stable trust anchor.
- **Suppress duplicate dialogs only in the view.** Rejected because permission
  requests can originate from both the talk controller and resident listener.
- **Keep one wake listener per view.** Rejected because concurrent observers can
  still create multiple audio engines and recognizers.

## Consequences

- Fast refreshes now auto-select an Apple Development identity when available;
  ad-hoc fallback remains explicit.
- Two consecutive refreshes produced different executable hashes but the same
  designated requirement, bound to bundle ID and the installed Apple
  Development certificate (Team ID `GAQVR7BQA7`).
- Concurrent permission requests from multiple voice components resolve through
  one operation, and already-authorized status does not call the OS request API
  again.
- The resident wake listener is process-wide, preventing multiple observers
  from starting competing audio engines.
- After the signing change, repeated refreshes produced one `[wake] start`
  record per launch. The latest launch issued one microphone access check,
  returned an authorized TCC value, and did not fan out into the previous
  several-requests-per-second pattern.
- The existing `CODESIGN_IDENTITY=-` / no-identity path remains operational.
- Full native tests, app build, Host smoke, bundle verification, and two live
  in-place refreshes passed.

## Risks

- The first launch after changing from ad-hoc to certificate signing may require
  one final microphone/speech approval.
- Development signing is suitable for local builds; public release signing and
  notarization remain separate work.
- TCC behavior is controlled by macOS. The stable requirement was verified;
  resetting the user's live privacy record solely for a test was deliberately
  avoided.
