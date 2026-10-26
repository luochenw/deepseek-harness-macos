# Agent Note: Prevent duplicate app instances from owning one session

Status: implemented - in-place refresh now eliminates duplicate app Hosts before relaunch

## Problem

DSH persistence permits one cross-process write handle per session. The lease is
an empty `session.lock` file locked with the kernel `flock(2)` API for the life
of the writer. A second live Host receives `session/writer-held`; the session is
not corrupt, but it is read-only while the first Host keeps the lock.

Two copies of the macOS app can share the same `DSH_HOME` while having different
bundle paths, for example `/Applications/DeepSeek Harness.app` and a local
`dist/DeepSeek Harness.app`. The in-place refresh script previously stopped only
the target path and then used `open -n`, so a stale development copy could keep
the lock indefinitely.

## Decision

- During in-place refresh, inspect every `DSH`/embedded Host process and resolve
  its enclosing app's bundle identifier.
- Stop every process whose bundle identifier matches
  `com.github.deepseek-harness-macos.app`, not only the selected app path.
- Launch the refreshed target without `open -n`, preserving normal macOS
  single-instance activation behavior.
- Never remove or rewrite a live `session.lock`; the kernel releases it when the
  owning Host exits.

## Alternatives considered

- **Delete `session.lock`.** Rejected because POSIX flock names the inode, not
  the path; replacing it while live forfeits exclusion and can tear a session.
- **Add an expiry timeout.** Rejected because DSH deliberately avoids
  expropriating a live but stalled writer.
- **Allow read-only access when writer-held.** Correct as a fallback, but it does
  not solve the duplicate local app instance that caused this case.
- **Stop only the target app path.** Rejected because another copy of the same
  product shares user state and can retain the same leases.

## Consequences

- A real session lock held by a stale `dist` Host was released when that process
  exited, and the installed Host immediately acquired it.
- In-place refresh resolves each running `DSH`/embedded Host process to its
  enclosing app bundle ID, stops every matching copy, and launches the target
  without `open -n`.
- A live two-copy test stopped both `/Applications` and `dist`, relaunched exactly
  one `/Applications` app family, and preserved session data and the lock inode.

## Risks

- Refreshing terminates any model work running in another copy of the app; this
  is intentional because all copies share the same sessions and credentials.
- A non-DeepSeek process with an unrelated bundle that happens to use `DSH` as
  its executable name remains untouched because matching is by bundle ID.
