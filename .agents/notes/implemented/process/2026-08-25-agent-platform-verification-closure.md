# Agent Note: Agent Platform verification closure

Status: implemented — standalone runtime contracts, a pinned build Runtime, and packaged Host smoke now gate the Agent Platform

## Problem

The Agent Platform implementation now spans three independent surfaces:

1. A bundled Node/Cordis plugin with durable scheduler, recovery, workspace,
   runtime, and delivery behavior.
2. A source-shape patch applied to the embedded DSH Runtime during app build.
3. A native SwiftUI control surface and packaged Host smoke path.

The normal native command runs Swift checks and a UI snapshot fixture, while
the packaged Host smoke exercises one Agent Profile and Batch
failure-isolation scenario. It does not explicitly run the plugin's Node test
suite or the runtime-patch fixture. CI likewise does not report those as a
distinct stage. A plugin regression can therefore be hidden behind unrelated
native test output or omitted from a local verification run.

## Decision

`scripts/test-agent-platform-runtime.sh` is the one local command for the
Node portion of the Agent Platform contract. It:

- resolve `NODE_SOURCE` when supplied, otherwise use `node` from `PATH`;
- reject an executable that does not report a valid Node runtime version;
- syntax-check every `macos/Runtime-extras/dsh-agent-platform/lib/*.js`
  module;
- execute the plugin's `node --test` suite;
- execute `scripts/test-agent-platform-runtime-patch.mjs`.

GitHub Actions now has a separately named `Agent Platform runtime contracts`
step after Swift unit tests. The workflow installs the pinned DSH Runtime
before that step, so the patch suite checks both its synthetic legacy fixture
and the real installed package before build. The current pin is
`0.1.1-rc.2`. `scripts/test-agent-platform-runtime-script.sh` runs first in
that stage and proves a non-Node executable and an empty plugin directory fail
clearly. Build plus packaged Host smoke remain the integration proof that the
plugin and patch load inside the actual app Runtime.

## Alternatives considered

- **Only run the plugin tests from `test-macos-native.sh`.** Rejected because
  it hides a Node/Runtime failure inside a command named for native Swift
  checks and gives CI no distinct failure boundary.
- **Only rely on build plus Host smoke.** Rejected because it covers a narrow
  runtime path and cannot replace durable-state, scheduler, recovery, and
  patch-idempotence tests.
- **Install plugin dependencies through npm during each test.** Rejected
  because the plugin deliberately relies on the bundled DSH peer dependency
  surface and its test suite uses Node built-ins; installation would add
  network and lockfile concerns without increasing coverage.
- **Add a SwiftPM test target.** Rejected because the project intentionally
  has no SwiftPM/Xcode target list; the existing direct `swiftc` workflow
  avoids source-list drift.

## Consequences

- The test script can duplicate the package's `scripts.check` file list if new
  modules are added. Using the `lib/*.js` glob prevents that list from
  drifting.
- The patch fixture keeps a synthetic rc.6 source shape for the legacy branch
  and also copies, patches twice, and inspects the installed DSH package. The
  pinned app build and packaged Host smoke remain required to prove complete
  runtime assembly.
- Verification completed on August 25, 2026:
  `test-agent-platform-runtime-script.sh` passed; the runtime suite passed
  91 Node tests plus the patch fixture; native contracts passed; Swift units
  passed 20/20; the app built with embedded DSH `0.1.0-rc.7`; and packaged
  Host smoke passed Profile CRUD plus Batch failure isolation.
