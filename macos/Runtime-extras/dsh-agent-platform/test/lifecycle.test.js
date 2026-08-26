import assert from "node:assert/strict";
import test from "node:test";
import {
  closeManagedContext,
  recoverPendingContextCloses,
  runDurableIntegrationCompletion,
  shouldCleanupAdoptedRun,
  shouldCloseContextOnAdoption,
  shouldInspectContextBeforeClose,
  shouldInspectWorkspaceBeforeCleanup,
} from "../lib/lifecycle.js";

test("closing a DSH context disposes the child before workspace cleanup and state close", async () => {
  const calls = [];
  const context = {
    id: "context-1",
    childSessionId: "child-1",
    parentSessionId: "parent-1",
    workspacePath: "/tmp/work/subdir",
    worktreeRoot: "/tmp/work",
    branch: "dsh-agent/context-1",
    gitRoot: "/tmp/repo",
  };

  await closeManagedContext({
    context,
    outcome: "adopted",
    disposeChild: async (childSessionId, parentSessionId) => {
      calls.push(["dispose", childSessionId, parentSessionId]);
    },
    cleanupWorkspace: async (workspace) => {
      calls.push(["cleanup", workspace.path, workspace.worktreeRoot]);
    },
    closeState: async (contextId, outcome) => {
      calls.push(["close", contextId, outcome]);
    },
  });

  assert.deepEqual(calls, [
    ["dispose", "child-1", "parent-1"],
    ["cleanup", "/tmp/work/subdir", "/tmp/work"],
    ["close", "context-1", "adopted"],
  ]);
});

test("adoption closes execution contexts but preserves continuable analysis contexts", () => {
  assert.equal(shouldCloseContextOnAdoption({
    adapter: "dsh",
    mode: "execution",
    contextId: "execution-context",
  }), true);
  assert.equal(shouldCloseContextOnAdoption({
    adapter: "dsh",
    mode: "analysis",
    contextId: "analysis-context",
  }), false);
});

test("recovery skips physical cleanup already recorded as adopted", () => {
  assert.equal(shouldCleanupAdoptedRun({
    adapter: "codex",
    mode: "execution",
    worktreePath: "/tmp/codex",
  }), true);
  assert.equal(shouldCleanupAdoptedRun({
    adapter: "codex",
    mode: "execution",
    worktreePath: "/tmp/codex",
    workspaceCleaned: true,
    workspaceOutcome: "adopted",
  }), false);
  assert.equal(shouldCleanupAdoptedRun({
    adapter: "dsh",
    mode: "execution",
    contextId: "context-1",
    adopted: true,
  }), false);
});

test("prepared cleanup intents skip inspection on crash recovery", () => {
  assert.equal(shouldInspectWorkspaceBeforeCleanup({
    workspaceCleanupIntent: { outcome: "adopted" },
  }, "adopted"), false);
  assert.equal(shouldInspectWorkspaceBeforeCleanup({}, "adopted"), true);
  assert.equal(shouldInspectContextBeforeClose({
    closeIntent: { outcome: "discarded" },
  }, "discarded"), false);
  assert.equal(shouldInspectContextBeforeClose({}, "discarded"), true);
});

test("pending context close recovery continues after one failure", async () => {
  const calls = [];
  await recoverPendingContextCloses([
    { contextId: "context-1", outcome: "discarded" },
    { contextId: "context-2", outcome: "adopted" },
  ], async (contextId, outcome) => {
    calls.push(["close", contextId, outcome]);
    if (contextId === "context-1") throw new Error("cleanup failed");
  }, (pending, error) => {
    calls.push(["failed", pending.contextId, error.message]);
  });

  assert.deepEqual(calls, [
    ["close", "context-1", "discarded"],
    ["failed", "context-1", "cleanup failed"],
    ["close", "context-2", "adopted"],
  ]);
});

test("durable integration completion failures are persisted and published before rethrow", async () => {
  const calls = [];
  const failure = new Error("cleanup failed again");

  await assert.rejects(
    () => runDurableIntegrationCompletion({
      batchId: "batch-1",
      rootSessionId: "root-1",
      resume: async () => {
        calls.push(["resume", "batch-1"]);
        throw failure;
      },
      markFailed: async (batchId, error) => {
        calls.push(["failed", batchId, error.message]);
      },
      publish: async (rootSessionId) => {
        calls.push(["publish", rootSessionId]);
      },
    }),
    /cleanup failed again/);

  assert.deepEqual(calls, [
    ["resume", "batch-1"],
    ["failed", "batch-1", "cleanup failed again"],
    ["publish", "root-1"],
  ]);
});
