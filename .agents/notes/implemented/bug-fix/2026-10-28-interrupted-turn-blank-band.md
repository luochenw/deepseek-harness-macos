# Agent Note: Interrupted turn leaves a blank band under the command row

Status: implemented — root cause found and fixed with an off-screen fixture from the real session

## Problem

After a turn is interrupted (App crash / `turn/end` with `reason.kind ==
"interrupted"`), the transcript shows ~135pt of empty space between the folded
command row ("执行了 6 条命令 · 其中 3 条修改了文件 ›") and the 「本轮已中断」 note.

Reproduced off-screen with the real Host events of turn 19 of
`session-c19df847-b49a-4463-a185-f2b8eed542c4` (fixture:
`scripts/fixtures/transcript-interrupted-turn19.json`). Rendering `ConversationView`
at 900pt wide, the measured row frames were:

| row | before | after |
| --- | --- | --- |
| user prompt | 1238.0 | 1238.0 |
| ✻ 思考过程 | 23.0 | 23.0 |
| 执行了 6 条命令 | 25.0 | 25.0 |
| gap to 本轮已中断 | **135.0** | **16.0** |
| 本轮已中断 → 本轮用时 | 43.0 | 16.0 |

Three independent defects stacked up to produce it — all of them from the
`DSHTranscriptHeightCache` added in round 6 (`DSHTranscriptPerf.swift`):

1. **The group's estimate was multiplied by the command count.**
   `transcriptRow(.toolGroup:)` passed
   `toolStatusRowHeight(accessory: false) * max(1, group.count)` as the row's
   `minHeight` estimate. A folded group is ONE collapsed line regardless of how
   many commands it holds, so a 6-command group claimed 6 × 24 = 144pt for a
   25pt row — 119pt of unconditional blank. `minHeight` only ever grows a row,
   so the `minHeight` can never shrink back.
2. **Live/collapsible rows used the cache.** A streaming reply and a
   collapsed/expanded row change height under a stable row id (and stable
   content version, because the version hashes text + reasoning + toolCallId,
   not the fold state or the running flag). Remembering the tall
   expanded/streaming measurement and replaying it as `minHeight` pinned those
   rows at their largest height forever.
3. **An empty reply kept a placeholder height.** A reply whose body had been
   emptied (interrupted mid-stream, or a settled `assistant/message` with only
   tool-call blocks) still got `DSHTranscriptRowEstimate2.messageHeight`, and
   `remember()` never invalidated an entry when the row measured ~0.

A fourth, smaller contributor: the system-note estimate claimed 44pt
(`lines * 20 + 24`) for a row that renders 17pt, adding another ~27pt of blank
under every system row.

## Decision

- `DSHTranscriptRowHeightPolicy` (in `DSHTranscriptPerf.swift`) is the single
  pure decision point: a row is `off` (collapsible → no cache at all), `live`
  (streaming/running → never read or write the cache) or `cached`. Plus
  `minHeight(cached:estimate:isEmpty:)`, which returns 0 for a row with no
  content, and `shouldReadCache`/`shouldWriteCache`.
- `DSHTranscriptHeightCache.remember` now REMOVES the entry when the measured
  height is ≤1pt, and a new `invalidate(id:)` drops one row explicitly. Skipping
  the write was not enough: a stale tall entry stays resolvable.
- `dshTranscriptCachedHeight` grew `isLive:` / `isCollapsible:` / `isEmpty:`.
- `transcriptRow` passes them: reasoning rows are always collapsible (their
  header already pins to the exact font metrics) and live while the turn runs;
  a message row is live while it is the streaming placeholder and empty when it
  has no text, no reasoning and no attachment; tool groups are collapsible and
  use the SINGLE-line estimate, with the running accessory only when one of
  their calls is still running.
- `DSHTranscriptRowEstimate2.messageHeight` estimates the system row from the
  real 14pt font line height plus its 3pt inter-line spacing (no bubble padding),
  and the tool row from `toolStatusRowHeight`.

## Alternatives considered

- **Bump the content version when the fold/running state changes.** This would
  invalidate correctly, but it re-measures a row on every streamed chunk and
  every running-state flip — the exact cost the cache exists to avoid — and it
  still pads the row while it is tall.
- **Keep `minHeight` but clamp it to the measured height afterwards.** SwiftUI
  re-evaluates the modifier body on its own schedule; there is no "after
  measurement" hook that reliably removes a min-height, so the tall value wins
  permanently.
- **Store the estimate in the cache and compare it on lookup.** A second key
  dimension doubles the state for information the version already covers.
- **Drop the cache entirely.** It is what makes fast scrolling cheap
  (p95 10–15 ms/frame); the fix has to keep it for settled rows.

## Consequences

- Interrupted turns, streaming replies and collapsed/expanded rows no longer
  reserve stale height. Measured gap under the command row: 16pt (one
  `DSHSpace.s4`), which is the transcript's normal row spacing.
- Settled rows keep the cache hit path unchanged, so fast scrolling is
  unaffected (see the perf numbers in the delivery report).
- `macos/DSHTests/DSHTranscriptRowHeightTests.swift` covers the policy and the
  empty-content invalidation.
- The end-to-end render of the real turn-19 fixture asserting the gap equals
  one row spacing lives in the same file, but **until 2026-10-29 it never ran**:
  its fixture path was resolved by deleting exactly two components from
  `#filePath`, which stops at `macos/`, so it looked for
  `macos/scripts/fixtures/…` and threw "no such file" on every invocation. The
  claim above ("covers … an end-to-end render") was therefore wrong, and the
  test could not have caught a regression. The path now walks up to the repo
  root (same rule as the golden fixtures, with `DSH_GOLDEN_FIXTURES` override)
  and the test asserts the fixture exists before decoding, so a missing file
  fails loudly instead of silently skipping the render.

## Follow-ups (deliberately not done here)

- **Viewport compensation for a non-pinned reader.** Rows that go from estimate
  to measured height change the content height above a reader who has scrolled
  up; only a pinned reader follows the tail. Compensating via the measurement
  store's anchor row is a separate change.
- **Interrupted turns and tool-only turns have no rating anchor.** A turn whose
  last assistant step carries no text has nothing to rate, so `feedbackAnchorID`
  returns nil. This is a deliberate trade-off, not an oversight.
- **`ToolGroupRow.==` now compares a `signature` the parent computes.** The
  first attempt read `@EnvironmentObject` inside `==`, which crashes with "No
  ObservableObject of type HarnessController found" because `==` can run before
  the environment is installed. Keep the comparison a pure value check.
- **`DSHTranscriptPerf.isEnabled` / `forceRowFrames` are `#if DEBUG`.** Release
  builds see `let false`, so measurement cannot be turned on from shipping code.
  The unit-test script passes `-D DEBUG`; the app build does not.
- **The golden tests are inherently brittle on CI** (offscreen window, fixed
  1.8s run loop, `.aqua` appearance, colour thresholds). If CI proves flaky,
  gate them behind an environment variable and run them locally.
