#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DASHBOARD="$ROOT/macos/DSHApp/NativeDashboard.swift"
CONVERSATION="$ROOT/macos/DSHApp/ConversationView.swift"
GOAL_VIEW="$ROOT/macos/DSHApp/SkillsGoalView.swift"
COMPOSER="$ROOT/macos/DSHApp/ComposerView.swift"
GOAL_ACTIONS="$ROOT/macos/DSHApp/DSHGoalActions.swift"
QUEUE="$ROOT/macos/DSHApp/DSHQueue.swift"
QUEUE_DOCK="$ROOT/macos/DSHApp/QueueDockView.swift"
PROJECTIONS="$ROOT/macos/DSHApp/DSHSubagentProjection.swift"

grep -q 'harness.displayedTodos' "$DASHBOARD" || {
  echo "subagent-context-ui: dashboard Todo card is still root-scoped" >&2
  exit 1
}
grep -q 'harness.displayedTools' "$DASHBOARD" || {
  echo "subagent-context-ui: dashboard tool card is still root-scoped" >&2
  exit 1
}
grep -q 'harness.displayedTools.last' "$CONVERSATION" || {
  echo "subagent-context-ui: transcript tool lookup is still root-scoped" >&2
  exit 1
}
grep -q 'harness.displayedGoal' "$GOAL_VIEW" || {
  echo "subagent-context-ui: goal bar is still root-scoped" >&2
  exit 1
}
grep -q 'harness.canMutateDisplayedGoal' "$GOAL_VIEW" || {
  echo "subagent-context-ui: one-shot subagent goals expose mutation controls" >&2
  exit 1
}
grep -q 'GoalBar()' "$COMPOSER" || {
  echo "subagent-context-ui: read-only child composer does not retain goal context" >&2
  exit 1
}
grep -q 'harness.displayedPlanActive' "$COMPOSER" || {
  echo "subagent-context-ui: composer plan indicator is still root-scoped" >&2
  exit 1
}
grep -q 'harness.displayedQueuedItems' "$COMPOSER" || {
  echo "subagent-context-ui: composer queue indicator is still root-scoped" >&2
  exit 1
}
grep -q 'harness.canUseRootSlashCatalog' "$COMPOSER" || {
  echo "subagent-context-ui: child composer still exposes the root slash catalog" >&2
  exit 1
}
MORE_MENU="$(awk '
  /Menu \{/ { capture = 1 }
  capture { print }
  capture && /help\("更多操作"\)/ { exit }
' "$COMPOSER")"
printf '%s\n' "$MORE_MENU" | grep -q 'if harness.canUseRootSlashCatalog' || {
  echo "subagent-context-ui: child composer menu still exposes root plan actions" >&2
  exit 1
}
grep -q 'canMutateDisplayedGoal' "$GOAL_ACTIONS" || {
  echo "subagent-context-ui: child goal mutation guard is missing" >&2
  exit 1
}
grep -q 'func enterPlanMode() { guard canMutateDisplayedPlan else { return };' "$GOAL_ACTIONS" || {
  echo "subagent-context-ui: enter plan mode lacks a child-context guard" >&2
  exit 1
}
grep -q 'func exitPlanMode() { guard canMutateDisplayedPlan else { return };' "$GOAL_ACTIONS" || {
  echo "subagent-context-ui: exit plan mode lacks a child-context guard" >&2
  exit 1
}
grep -q 'hostCurrentSessionID' "$GOAL_ACTIONS" || {
  echo "subagent-context-ui: root goal action routing is missing" >&2
  exit 1
}
grep -q 'harness.displayedQueuedItems' "$QUEUE_DOCK" || {
  echo "subagent-context-ui: queue dock is still root-scoped" >&2
  exit 1
}
grep -q 'displayedQueueItems.filter' "$PROJECTIONS" || {
  echo "subagent-context-ui: queued/steering filters bypass displayed child context" >&2
  exit 1
}
grep -q 'harness.canMutateDisplayedQueue' "$QUEUE_DOCK" || {
  echo "subagent-context-ui: child queue mutation controls are still visible" >&2
  exit 1
}
grep -q 'canMutateDisplayedQueue' "$QUEUE" || {
  echo "subagent-context-ui: child queue mutation guard is missing" >&2
  exit 1
}
grep -q 'struct DSHSubagentPresentationContext' "$PROJECTIONS" || {
  echo "subagent-context-ui: child presentation context is missing" >&2
  exit 1
}
grep -q 'applySubagentProjection' "$PROJECTIONS" || {
  echo "subagent-context-ui: child projection sequencing is missing" >&2
  exit 1
}
grep -q 'beginSubagentCatalogLoad' "$PROJECTIONS" || {
  echo "subagent-context-ui: stale subagent catalog responses are not guarded" >&2
  exit 1
}

echo "subagent-context-ui: OK"
