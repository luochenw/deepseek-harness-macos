# Agent Note: Remove unreachable single-item QuestionSheet and other dead code found during the architecture sweep

Status: implemented

## Problem

`DSHInteractionsView.swift` defined `QuestionSheet`, a single-item question
UI, and `main.swift` defined the `HarnessController.answerQuestion(_:selected:custom:)`
method it called. Neither is reachable: `ContentView`'s
`.sheet(item: $harness.pendingQuestion)` (`main.swift:1375`) presents
`QuestionBatchSheet`, not `QuestionSheet` — `QuestionSheet` is never
instantiated anywhere. `answerQuestion(_:selected:custom:)` is only called
from within `QuestionSheet`'s own body, so it's equally unreachable.

The dead method also carries a latent bug: it applies the caller's
`selected`/`custom` answer only to `question.items.first`, submitting an
empty answer for every other item in a multi-item batch
(`item.id == question.items.first?.id ? selected : []`). Fixing that bug in
unreachable code would be wasted effort; the correct move per the "no
half-finished implementations" / delete-what's-unused rule is to remove it.

Separately, `DSHSettingsWrite.swift` contained nothing but `import Foundation`
and a pointer comment ("Settings write encoders live in
DSHHostProtocol.swift") — an organizational leftover, not code.

## Decision

Deleted `QuestionSheet` (`DSHInteractionsView.swift`) and
`HarnessController.answerQuestion(_:selected:custom:)` (`main.swift`).
`QuestionBatchSheet` (`QuestionBatchSheet.swift`) — which correctly answers
every item in a batch via `answerQuestionBatch` — remains the sole
question-answering UI, matching what was already live. Also deleted the
empty `DSHSettingsWrite.swift` file.

## Alternatives considered

- **Fix the multi-item bug and keep `QuestionSheet` as an alternate/simpler
  UI for single-item questions.** Rejected — no call site chooses between
  `QuestionSheet` and `QuestionBatchSheet`; `pendingQuestion` always renders
  `QuestionBatchSheet`, which already handles the single-item case fine (a
  batch of one item). Keeping a second, unreachable UI adds maintenance
  surface (i18n strings, style consistency) with no behavior it uniquely
  provides.

## Consequences

Removes ~19 lines of unreachable Swift and one embedded correctness bug (the
first-item-only answer routing) that could not currently manifest but would
have on any future call site added without noticing the bug. No behavior
change to the live `QuestionBatchSheet` path.
