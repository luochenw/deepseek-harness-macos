# Agent Note: Patch the bundled LLM runtime for tool-result images and context pressure

Status: implemented — build-time patch of the pinned dsh 0.2.1-rc.2 runtime

## Problem

Two runtime behaviours made long sessions compact far too early on the
Anthropic-protocol relay route (`xpa`):

- **Images inside `tool_result` (B).** The relay bills an image nested in a
  `tool_result` block as base64 text, about one input token per byte, and the
  model cannot see it. One screenshot took a step from 88k to 271k input
  tokens. The same image as a top-level user block costs about 1k tokens.
- **Context pressure double-counted cache reads (C).** The token meter computed
  pressure as `inputTokens + cacheRead`. On this relay `input_tokens` already
  includes cache reads, so pressure ran at roughly twice the real value
  (33,549 vs 16,781 measured) and compaction fired early.

## Decision

`scripts/patch-llm-runtime.mjs` patches the runtime cache during
`prepare-dsh-runtime.sh`. The patch:

- is anchor-checked;
- carries a versioned marker (`dsh-llm-runtime-patch-v2`), matched exactly;
- is verified feature by feature;
- is written atomically, under the prepare lock.

What it changes:

- **B**: in the `anthropic-messages` / Bedrock-Claude converter, images in tool
  results are hoisted to top-level image blocks after all `tool_result` blocks
  of that message, with a text placeholder left in place. Measured: 172,427 →
  1,004 tokens for the same image, and the model now sees it.
- **C**: a per-route opt-in `compat.inputTokensIncludeCacheRead`. It is folded
  per session from the `request/header` event, so cold replay equals live and
  sessions do not leak into each other. When it is set, pressure is
  `inputTokens`. A route that cannot be resolved falls back to the old formula
  instead of throwing. `usageTokens` (the total) is unchanged.
  `contextPressure.stateVersion` 5 → 7 (6 was written by an earlier global-flag
  draft and must be invalidated too). This costs one full re-fold per session
  on first read, and another after a downgrade.
- **Reproducibility**: `scripts/dsh-runtime-lock.json` pins dsh 0.2.1-rc.2,
  `@earendil-works/pi-ai` 1.3.0 and `pi-telemetry` 1.3.0, plus the pristine
  sha256 of every patched file. Prepare pins the two packages after install and
  fails with expected and actual values on drift.
- **`DSH_SOURCE`**: an explicit source is copied into the cache
  (`<version>-src-<hash>`) and only the copy is patched. A signed app's runtime
  is never modified in place.
- Tests: `scripts/test-llm-runtime-patch.mjs` (14), run by
  `scripts/test-llm-runtime.sh` and CI.

## Alternatives considered

- **Patch upstream / wait for a runtime release**: not under our control, and
  the effect on cost and compaction is immediate.
- **Change the relay**: the user chose not to report it; the client-side fix
  covers our route.
- **A process-wide flag for C** (first draft): leaked across sessions and broke
  cold replay; replaced by the per-session fold.
- **Allow both pi-ai 1.3.0 and 1.4.0**: the anchors were only verified at
  runtime on 1.3.0, and allowing a range makes builds depend on registry timing.
- **Patch `DSH_SOURCE` in place**: reproduced breaking the app bundle's code
  signature seal on a test bundle.

## Consequences

- B covers `anthropic-messages` and Bedrock Claude only. The `relay` provider
  (`openai-responses`) is out of scope, including its DeepSeek model entry.
- C takes effect only after `compat.inputTokensIncludeCacheRead: true` is added
  under the `xpa` route in `cordis.patch.yml`. Whether the relay's input also
  includes cache *writes* still needs one real usage sample.
- The pin copies only the two `@earendil-works` package folders. Other
  dependencies still resolve by npm semver: 24 differ in minor or patch version
  from the shipped app, mostly `@aws-sdk/*`. A full runtime lockfile is a
  follow-up.
- The machine's internal npm mirror could not resolve `pi-telemetry@1.3.0`; the
  pin used the public registry with `DSH_NPM_CACHE`.
- Left for later: resolver unavailability during fold still records `false`
  (three-state handling), and the detached `lib/types` twin has no resolver
  wired.
