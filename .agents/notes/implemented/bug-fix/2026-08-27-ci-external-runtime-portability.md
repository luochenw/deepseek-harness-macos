# Agent Note: CI external Runtime discovery must not gate command-shape tests

Status: implemented — Agent Platform contracts no longer depend on external CLIs installed on the runner

## Problem

The Agent Platform Node contract suite tests generated command arguments for
Claude Code, Codex, and ZCode. `adapterCommand` first resolves an executable,
so the tests implicitly depended on the local development machine's installed
CLIs. GitHub's macOS runner has none of those programs, causing otherwise
pure command-shape tests to fail with `runtime-unavailable` before they
reached their assertions.

An earlier hosted-runner failure also showed that the runner-provided Node can
be dynamically linked to a sibling `libnode.*.dylib`. Copying only the Node
executable into the app bundle left the packaged binary unable to start.

## Decision

The runtime command-shape test file explicitly points every external Runtime
resolver environment variable at `process.execPath`. The tests only inspect
the generated command and never launch that path, so Node is a safe portable
stand-in and real runtime availability remains covered by `runtimeStatusRows`
and production execution paths.

`test-agent-platform-runtime-script.sh` now runs the full Node contract suite
with an isolated `HOME` and missing external-runtime paths. It also asserts
that the build script detects and stages `libnode*.dylib` when the selected
Node distribution supplies one.

The app build script copies any sibling dynamic Node libraries from
`<node>/../lib` into `Contents/lib`; static Node distributions remain a
no-op.

## Alternatives considered

- **Install Claude Code, Codex, and ZCode in CI.** Rejected: these are
  credentialed product CLIs, not test dependencies, and installing them
  would make the contract suite slower, less reproducible, and dependent on
  external authentication/release availability.
- **Skip all external Runtime tests on CI.** Rejected: command construction
  and safety restrictions are portable pure behavior that CI should enforce.
- **Remove runtime availability checks from production code.** Rejected:
  real dispatch must still fail clearly when an external Runtime is absent.
- **Assume Node is always statically linked.** Rejected: GitHub's hosted
  Node previously demonstrated that this is not universally true.

## Consequences

- Local developer installations no longer mask missing CI dependencies.
- CI will catch a future reintroduction of external-CLI coupling before build
  or smoke stages.
- Packaged Node is portable across both static and sibling-library Node
  distributions, subject to the existing macOS code-signing verification.
- Verification on August 27, 2026: the isolated Runtime contract check
  passed; all 91 Node tests passed; Swift units passed 72/72; the app built;
  packaged Host smoke, plist lint, code-sign verification, and diff checks
  passed.
