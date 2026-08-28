# Third-Party Notices

This repository's own Swift/SwiftUI/AppKit source (`macos/DSHApp/`) is
licensed under the MIT License — see [LICENSE](LICENSE).

A **built app** (`./scripts/build-macos-app.sh`) additionally embeds two
third-party components as its local execution backend. Neither is
redistributed in this git repository — the build script copies them from your
local machine at build time — but anyone distributing a *built* `.app` is
redistributing them. The build embeds this notice plus the project, Node.js,
and DSH license texts under `Contents/Resources/Licenses` and
`Contents/Resources/Runtime/dsh/LICENSE`.

## `@deepseek-ai/dsh` (DeepSeek Harness)

- **What**: the agent runtime, tools, MCP client, sandboxing, subagents and
  plugin system this app is a native UI for.
- **Source**: <https://github.com/deepseek-ai/deepseek-harness>
- **License**: MIT, Copyright (c) 2026 DeepSeek.
- **How it's embedded**: `scripts/build-macos-app.sh` copies the installed npm
  package into `Contents/Resources/Runtime/dsh` with its `LICENSE` file, adds
  this app's local Host plugins, and applies
  `scripts/patch-agent-platform-runtime.mjs`. That patch is restricted to
  DSH `0.1.0-rc.6`, `0.1.0-rc.7`, and `0.1.1-rc.2`, and fails closed when
  source anchors drift;
  it extends continuable-child cwd, identity, preset/sandbox inheritance,
  follow-up authorization, exact disposal, and Host plugin mounting. The
  original DSH copyright and MIT license remain unchanged. The copied npm
  dependency tree retains its package-level license and notice files.
- The embedded DSH dependency tree includes the prebuilt
  `@img/sharp-libvips-*` distribution. Its Apache-2.0 build-script license and
  upstream third-party notice matrix are copied into
  `Contents/Resources/Licenses/sharp-libvips-LICENSE` and
  `sharp-libvips-THIRD-PARTY-NOTICES.md`; the referenced GNU GPLv3 and LGPLv3
  texts are included beside them. The corresponding source and build scripts
  are available from the package repository declared in its `package.json`:
  `https://github.com/lovell/sharp-libvips`.
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
  executable into `Contents/MacOS/node`, unmodified, and embeds the exact
  runtime version's upstream license as
  `Contents/Resources/Licenses/Node.js-LICENSE`.

## Reporting a licensing concern

If you believe this project's bundling of the above components is missing
required attribution, please open a GitHub issue.
