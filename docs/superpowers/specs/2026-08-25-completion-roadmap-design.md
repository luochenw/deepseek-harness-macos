# Completion Roadmap Design

## Goal

Turn the native macOS client from a broad set of implemented feature domains
into a sequence of independently verifiable deliveries. The first delivery
closes the Agent Platform integration already present in the worktree; later
deliveries address the explicit gaps in `macos/WEB_PARITY.md`.

## Current State

The worktree contains an uncommitted Agent Platform implementation:

- A bundled Cordis plugin persists Agent Profiles, Runtime adapters, Runs,
  Batches, worktrees, recovery state, and integration state.
- The SwiftUI client exposes Profile management, Composer `@Profile`
  selection, Batch controls, logs, and workspace evidence.
- The build script injects the plugin into the embedded DSH Runtime and applies
  a version-gated DSH patch.
- Existing checks cover Swift typechecking, unit tests, a visual snapshot
  fixture, a patch-shape fixture, and a packaged Host smoke path.

The missing delivery discipline is that the plugin's Node test suite and the
patch-shape fixture are not represented as an explicit local verification
command or CI stage. A regression in the plugin can therefore be missed by a
developer who only runs the normal native command, and a failed check is not
isolated in CI output.

## Delivery Architecture

### Phase 1: Agent Platform Verification Closure (Implemented)

Create one executable verification entry point:

`scripts/test-agent-platform-runtime.sh`

It runs the following checks in order:

1. Syntax-check every Agent Platform plugin module with the same Node binary
   used by the build.
2. Run the plugin's Node test suite.
3. Run the patch fixture that verifies idempotence and the expected wire
   surface against its synthetic rc.6 source shape.

The normal native typecheck remains responsible for Swift compilation and
visual/contract checks. CI adds the new script as a separate named stage before
building the app, then installs `@deepseek-ai/dsh@0.1.0-rc.7`, the latest
version supported by the patch. The existing build and smoke stages remain the
integration boundary: they prove that the exact packaged Runtime loads the
plugin and exposes Agent Profile and Batch RPC paths.

This phase does not change Agent Platform behavior, profiles, runtime
selection, persistence, or UI. It makes the current behavior verifiable in a
repeatable and visible way. It completed on August 25, 2026 with the
standalone shell/runtime contracts, 91 plugin tests, 20 Swift units, a fresh
rc.7 app build, and packaged Host smoke.

### Phase 2: Tool Presentation Parity

Refactor tool render-intent display behind a small presentation model that
maps each Host intent to a native card. The initial target is terminal, diff,
read, search, web results, and code dispatch. Every long payload gets an
expand/collapse affordance with stable row height constraints. Diff and source
payloads use syntax-aware attributed text where the host supplies a language,
with a plaintext fallback.

Attachment history gains a session-level image rail. It is derived from
durable message attachments rather than duplicated local state, so image
opening and lightbox navigation stay correct after history pagination and
session switching.

### Phase 3: Windowed Conversation Trajectory

Replace unbounded presentation of folded conversation items with a windowed
data source. The controller owns a contiguous logical range around the visible
anchor; older and newer ranges are materialized only when needed. The
implementation preserves:

- top and bottom scroll anchors,
- history pagination,
- in-progress assistant streaming,
- compaction summaries,
- retry notices remaining transient,
- subagent transcript overlays.

Instrumentation records visible item count and window bounds in debug builds
so the performance contract can be tested rather than inferred from
`LazyVStack`.

### Phase 4: Subagent Context Projection

Introduce a view-context selector that resolves either the top-level session
or the currently viewed subagent. The Dashboard's tool activities, Todo list,
and Goal read through that selector. Event ingestion still maintains
per-session projections, so switching a transcript changes only which
projection is displayed; it never overwrites the root session's state.

The implementation begins with message, Todo, tool, and Goal state. Workflow
cards stay root-scoped until the Host's per-child workflow association is
verified from upstream wire types.

### Phase 5: Real App Accessibility and UI Automation

Add an executable App-level test target without introducing a second source
list. The test harness launches the built `.app` against an isolated
`DSH_HOME`, drives accessibility identifiers, and asserts visible Host-driven
state transitions for:

- creating and selecting a session,
- receiving an approval or question,
- opening a subagent transcript,
- switching Agent Platform Profile and Batch panels,
- showing terminal/diff/read cards,
- keyboard navigation of the slash and Profile palettes.

The test data uses deterministic Host fixtures or a local test plugin. It does
not require a real model provider or network access.

### Phase 6: Deferred Architecture and Protocol Work

Two intentionally deferred items remain outside the product feature phases:

- `dynamicCordisRunner` support is a new Host self-modification boundary. It
  requires separate protocol research, permission design, and recovery tests.
- Splitting the remaining 69 `@Published` properties into child observable
  objects changes SwiftUI invalidation semantics. It needs a dedicated
  performance and regression plan, not opportunistic refactoring.

## Alternatives Considered

- **Build all parity gaps in one branch.** Rejected because tool rendering,
  virtualization, context projection, and UI automation have different
  correctness boundaries and would make failures hard to localize.
- **Treat the existing build smoke as the only Agent Platform test.** Rejected
  because it exercises one failure-isolation path but does not run the
  plugin's durable-state and scheduler tests or prove patch fixture
  idempotence.
- **Add a SwiftPM project for UI and plugin validation.** Rejected because the
  repository intentionally compiles the production glob directly with
  `swiftc`; another source list would create drift risk.
- **Start by decomposing all `HarnessController` state.** Rejected because it
  is a high-blast-radius change with no immediate user-facing parity gain.

## Acceptance Criteria

Phase 1 is complete when:

1. A developer can run one documented script to syntax-check and test the
   Agent Platform plugin plus its runtime patch fixture.
2. CI exposes that script as its own named stage.
3. The existing native checks, unit suite, packaged build, and Host smoke all
   pass against the same worktree.
4. The Agent Note records the verification boundary and moves to
   `implemented/` only after those commands pass.

Later phases each require a separate Agent Note and implementation plan before
changing production behavior.
