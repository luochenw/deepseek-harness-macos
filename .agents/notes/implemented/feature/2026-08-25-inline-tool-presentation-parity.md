# Agent Note: Inline tool presentation parity

Status: implemented — transcript and DetailsPanel share structured tool cards with bounded long output

## Problem

The native app already decodes DSH's structured `ToolPresentation` render
intents and renders detailed terminal, diff, read, search, and web cards in
the right DetailsPanel. The inline transcript `ToolCallRow` instead owns a
second, partial renderer: diff/read/search have simplified branches while
terminal, web, and generic/code-dispatch output fall back to a generic code
block. Long-content folding is also inconsistent across terminal, source
read, search, and diff surfaces.

This creates visible parity drift: a user sees different information depending
on whether they expand the transcript row or open the right panel. It also
leaves the explicit Web parity gap for tool render intents, syntax-aware
source display, and collapse/expand behavior incomplete.

## Decision

`ToolPresentationContent` is the shared semantic body used by both
`NativeToolPresentationView` and transcript `ToolCallRow`. The transcript
keeps its compact row header and DetailsPanel button, while terminal, diff,
read, search, web, and generic/code-dispatch cards render the same structured
fields in either location:

- `terminal`: command context, cwd, output, exit/signal state;
- `diff`: contextual +/- rows;
- `read`: numbered source lines and language-aware token styling;
- `search`: grouped matches or paths with truncation disclosure;
- `web`: fetch summaries or citation sources;
- `generic`: code-dispatch and unknown-tool fallback text.

`DSHDisclosureWindow` is the pure folding helper shared by terminal output,
source reads, search rows, and diffs. It preserves the first and last halves
of a long payload with an explicit hidden-count control.

`DSHSourceTokenizer` provides a lightweight source treatment rather than a
full editor engine. It recognizes comments, strings, numbers, and language
keyword sets for common source hints
(`swift`, `ts`, `tsx`, `js`, `jsx`, `python`, `json`, `bash`, `yaml`, `md`);
unknown hints render as plaintext. The disclosure and tokenizer helpers remain
pure and independently tested, while the offscreen snapshot fixture renders
each inline card kind.

## Alternatives considered

- **Keep transcript rendering separate from DetailsPanel rendering.** Rejected:
  the current duplication is the source of missing terminal/web parity and
  divergent folding behavior.
- **Embed the full DetailsPanel card in every transcript row.** Rejected:
  it duplicates headers and creates card-in-card visual density in the
  conversation stream.
- **Adopt a third-party syntax-highlighting framework.** Rejected: this
  direct-`swiftc` project has no package manager target and only needs a
  readable, deterministic token layer for Host-supplied language hints.
- **Implement a complete parser for every language.** Rejected: it would
  exceed the presentation feature's scope. A conservative tokenizer with a
  plaintext fallback gives useful hierarchy without claiming compiler-grade
  highlighting.

## Consequences

- Search and diff cards can contain many grouped rows, so folding caps logical
  render rows instead of only raw text lines.
- The tokenizer is presentation-only and deliberately conservative; it never
  changes source text and falls back to plaintext for unsupported languages.
- Unknown or malformed Host card shapes continue through the generic fallback
  rather than failing the transcript.
- Verification on August 26, 2026: `./scripts/test-macos-native.sh` passed
  the source contracts and terminal/diff/read/search/web/generic snapshots;
  `./scripts/test-macos-native.sh --unit` passed 72/72 Swift tests; the app
  built with bundled DSH `0.1.0-rc.7`; and packaged Host smoke passed.
