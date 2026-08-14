# Agent Note: Whole-subagent-tree view, walked client-side from the existing one-level API

Status: implemented

## Problem

`macos/WEB_PARITY.md` named "whole-tree (descendants) viewing beyond
one-level-at-a-time breadcrumb navigation" as open. The only way to see
what subagents exist below the current level was `SubagentCard`'s flat list
of the immediate children of `currentSubagentParentID` — finding a subagent
three levels down meant opening each intermediate level one at a time and
remembering where you'd been.

The upstream model tool `list_agents` supports a `descendants` scope (a
whole-tree walk with parent/depth annotations) per earlier research, but
that research also could not confirm the client-facing `subagent.list` RPC
this app actually calls exposes an equivalent scope parameter — and the
local reference checkout used to verify wire types against source
(`work/deepseek-harness-reference`, always `.gitignore`d and never part of
this repo) was removed from disk between that research and this change
(this directory is shared with another, unrelated in-progress session; its
scratch space is its own to manage). Rather than guess at an unverified RPC
parameter — the same mistake avoided for the workflow status vocabulary
fix earlier today — this implements the tree using only the exact
`subagent.list(parentSessionId:)` call already in production use.

## Decision

Added `HarnessController.SubagentTreeNode` (entry, depth, and the
`ancestorPath: [SubagentNavigationNode]` needed to re-enter
`subagentPath`/`openSubagent`'s existing navigation machinery at any tree
node) and `loadSubagentTree()`, which walks the catalog breadth-first from
the current parent via repeated `hostClient.subagents(parentSessionId:)`
calls — the same method `loadSubagents` already uses — following only
entries with `kind == "child" && hasChildren == true`. Capped at depth 6 /
200 visited nodes (`subagentTreeMaxDepth` / `subagentTreeMaxNodes`) to bound
an unexpectedly wide or deep tree; hitting either cap sets
`subagentTreeTruncated` and the view surfaces it explicitly rather than
silently showing a partial tree as if it were complete.

`SubagentTreeView` (new sheet, opened via a "查看完整子代理树" button next
to `SubagentCard`'s existing 返回上级) flattens the tree into an indented
list (`depth`-proportional leading padding) rather than a recursive SwiftUI
view hierarchy — simpler to reason about and avoids the type-checking cost
recursive `View` bodies can hit. Tapping a node sets `subagentPath =
node.ancestorPath` and calls the existing `openSubagent(node.entry)` — since
`currentSubagentParentID` is computed from `subagentPath.last`, this
correctly re-enters the current one-level-at-a-time navigation exactly as
if the user had clicked through each intermediate level by hand, so no
second navigation code path was needed.

## Alternatives considered

- **Recursive SwiftUI view (`OutlineGroup` or a self-referential `View`
  struct) instead of a flattened list.** `OutlineGroup` would give
  free native disclosure triangles, but the tree is fully computed
  up front (not lazily expandable against the Host), so a flat,
  depth-indented `List` shows the same information with less risk of
  SwiftUI's type-checker struggling on a recursive generic view — matching
  the existing house style of preferring dense, direct view code over
  building new abstractions (see AGENTS.md).
- **Wait until the RPC scope question can be re-verified, rather than
  ship the client-side walk now.** Rejected: the client-side walk is
  strictly correct today regardless of whether a server-side `descendants`
  scope exists later — it only makes more Host round-trips than a
  hypothetical single-call version would. If a `descendants` scope is
  confirmed later, swapping the implementation is a pure optimization, not
  a behavior fix, so there's no reason to block the feature on it.

## Consequences

A deep or wide subagent tree can now be searched from one sheet instead of
manual level-by-level drilling, with explicit truncation disclosure instead
of a silent partial view. Cost: opening the tree issues one Host round-trip
per non-leaf node in the (capped) tree rather than one — acceptable for an
on-demand, user-triggered action, not something that runs automatically.
