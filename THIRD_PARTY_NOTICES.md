# Third-Party Notices

This repository's own Swift/SwiftUI/AppKit source (`macos/DSHApp/`) is
licensed under the MIT License — see [LICENSE](LICENSE).

A **built app** (`./scripts/build-macos-app.sh`) additionally embeds two
third-party components, unmodified, as its local execution backend. Neither
is redistributed in this git repository — the build script copies them from
your local machine at build time — but anyone distributing a *built* `.app`
is redistributing them and should keep this notice (and the embedded
`Contents/Resources/Runtime/dsh/LICENSE` file that DSH's own package ships)
alongside it.

## `@deepseek-ai/dsh` (DeepSeek Harness)

- **What**: the agent runtime, tools, MCP client, sandboxing, subagents and
  plugin system this app is a native UI for.
- **Source**: <https://github.com/deepseek-ai/deepseek-harness>
- **License**: MIT, Copyright (c) 2026 DeepSeek.
- **How it's embedded**: `scripts/build-macos-app.sh` copies the installed
  npm package verbatim into `Contents/Resources/Runtime/dsh` (`ditto`, no
  modification, `LICENSE` file included). Its own transitive npm
  dependencies are covered by deepseek-ai/deepseek-harness's own
  `THIRD_PARTY_NOTICES.md` in that repository.
- **Relationship**: this project is an independent, community-built native
  client. It is **not** affiliated with or endorsed by DeepSeek AI.

## Node.js

- **What**: the JavaScript runtime `dsh` runs on. Bundled so the app works
  without a system-wide Node install.
- **Source**: <https://nodejs.org>, <https://github.com/nodejs/node>
- **License**: MIT-style, Copyright Node.js contributors. Node.js itself
  bundles several further open-source components (V8, ICU, OpenSSL, zlib,
  c-ares, etc.) each under their own license — see
  <https://github.com/nodejs/node/blob/main/LICENSE> for the complete,
  aggregated text.
- **How it's embedded**: `scripts/build-macos-app.sh` copies a single `node`
  executable into `Contents/MacOS/node`, unmodified.

## Reporting a licensing concern

If you believe this project's bundling of the above components is missing
required attribution, please open a GitHub issue.
