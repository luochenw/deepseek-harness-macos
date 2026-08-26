import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  AgentPlatformState,
  normalizeProfile,
  renderIntegrationPrompt,
  resolveIntegrationPolicy,
} from "../lib/core.js";

function profile(overrides = {}) {
  return {
    name: "实现助手",
    mention: "implementer",
    defaultMode: "analysis",
    allowModelDispatch: false,
    integrationPolicy: "manual",
    adapters: [{ id: "dsh", runtime: "dsh", enabled: true }],
    ...overrides,
  };
}

function createBatch(state, input, onlyBinding) {
  return state.createBatch({
    rootCwd: "/workspace",
    sourceCwd: "/workspace",
    sandboxMode: "workspace-write",
    sourceAgentOptions: { provider: "relay", model: "source-model" },
    sourceToolAllowlist: [],
    sourceAgentPreset: "code",
    ...input,
  }, onlyBinding);
}

test("profile defaults and tool filters are persisted in immutable batch snapshots", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-state-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile({
    adapters: [{
      id: "dsh",
      runtime: "dsh",
      enabled: true,
      toolAllowlist: ["read_file"],
      toolDenylist: ["bash"],
    }],
  }));
  const batch = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    rootCwd: "/workspace",
    sourceCwd: "/workspace/feature",
    sandboxMode: "workspace-write",
    sourceAgentOptions: { provider: "relay", model: "source-model", maxTokens: 4096 },
    sourceToolAllowlist: ["read", "grep"],
    sourceAgentPreset: "code",
    task: "inspect",
    mode: "analysis",
    integrationPolicy: "manual",
    source: "manual",
  });

  await state.removeProfile(saved.id);
  const historical = state.batch(batch.id);
  assert.equal(historical.profileName, "实现助手");
  assert.equal(historical.profileDeleted, true);
  assert.deepEqual(historical.profileSnapshot.adapters[0].toolDenylist, ["bash"]);
  assert.deepEqual(historical.dispatch, {
    rootSessionId: "root",
    initiatorSessionId: "root",
    rootCwd: "/workspace",
    sourceCwd: "/workspace/feature",
    sandboxMode: "workspace-write",
    sourceAgentOptions: { provider: "relay", model: "source-model", maxTokens: 4096 },
    sourceToolAllowlist: ["read", "grep"],
    sourceAgentPreset: "code",
    task: "inspect",
    mode: "analysis",
    integrationPolicy: "manual",
    source: "manual",
    profile: historical.profileSnapshot,
  });
  assert.equal(historical.coordination.status, "waiting");
  await assert.rejects(() => state.retryRun(historical.runs[0].id), /deleted/);

  const disk = JSON.parse(await readFile(path.join(root, "state.json"), "utf8"));
  assert.equal(disk.batches[0].profileSnapshot.mention, "implementer");
});

test("mentions are unique and profile defaults are deterministic", () => {
  const normalized = normalizeProfile(profile({
    name: "  实现助手 ",
    mention: " @implementer ",
    defaultTask: "  检查改动并运行测试  ",
  }), []);
  assert.equal(normalized.name, "实现助手");
  assert.equal(normalized.mention, "implementer");
  assert.equal(normalized.defaultTask, "检查改动并运行测试");
  assert.equal(normalized.defaultMode, "analysis");
  assert.equal(normalized.integrationPolicy, "manual");
  assert.equal(normalized.allowModelDispatch, false);
  assert.throws(() => normalizeProfile(profile(), [{ id: "other", mention: "implementer" }]), /mention/);
});

test("explicit natural language overrides the selected integration policy", () => {
  assert.equal(resolveIntegrationPolicy("这次不要自动整合，只保留结果", "auto"), "manual");
  assert.equal(resolveIntegrationPolicy("请手动整合这些建议", "auto"), "manual");
  assert.equal(resolveIntegrationPolicy("采纳 Codex 的改动", "manual"), "auto");
  assert.equal(resolveIntegrationPolicy("直接整合 Claude Code 的实现", "manual"), "auto");
  assert.equal(resolveIntegrationPolicy("检查实现", "auto"), "auto");
  assert.equal(resolveIntegrationPolicy("不要采纳任何改动", "manual"), "manual");
});

test("Batch persists the task-level natural-language integration override", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-natural-policy-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile({ integrationPolicy: "auto" }));
  const batch = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    task: "这次不要自动整合，只保留 worktree",
    mode: "execution",
    integrationPolicy: "auto",
    source: "composer",
  });

  assert.equal(batch.integrationPolicy, "manual");
  assert.equal(batch.integrationState, "manualPending");
  assert.equal(batch.dispatch.integrationPolicy, "manual");
});

test("new Batches refuse incomplete initiating capability snapshots", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-incomplete-new-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile());
  await assert.rejects(
    () => state.createBatch({
      profileId: saved.id,
      rootSessionId: "root",
      initiatorSessionId: "root",
      rootCwd: "/workspace",
      sourceCwd: "/workspace",
      sandboxMode: "workspace-write",
      sourceAgentOptions: { provider: "relay", model: "source-model" },
      sourceToolAllowlist: [],
      task: "unsafe",
      mode: "execution",
      integrationPolicy: "manual",
      source: "manual",
    }),
    /complete initiating capability snapshot/i);
});

test("restart recovers DSH work but interrupts every external nonterminal run", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-recover-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile({
    adapters: [
      { id: "dsh", runtime: "dsh", enabled: true },
      { id: "cc", runtime: "claude-code", enabled: true },
    ],
  }));
  const batch = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    rootCwd: "/workspace",
    task: "work",
    mode: "execution",
    integrationPolicy: "manual",
    source: "manual",
  });
  await state.updateRun(batch.runs[0].id, {
    status: "running",
    dshMessageId: "message-reserved",
  });
  await state.updateRun(batch.runs[1].id, { status: "queued" });

  const reopened = await AgentPlatformState.open(root);
  const recovered = reopened.batch(batch.id);
  assert.equal(recovered.runs.find((run) => run.adapter === "dsh").status, "queued");
  assert.equal(recovered.runs.find((run) => run.adapter === "dsh").resumeAfterRestart, true);
  assert.equal(recovered.runs.find((run) => run.adapter === "dsh").dshMessageId, "message-reserved");
  assert.equal(recovered.runs.find((run) => run.adapter === "claude-code").status, "interrupted");
  assert.deepEqual(reopened.recoveryRoots(), [{ sessionId: "root", cwd: "/workspace" }]);
});

test("legacy nonterminal Batches without capability snapshots fail closed on upgrade", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-legacy-capability-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile({
    adapters: [
      { id: "dsh", runtime: "dsh", enabled: true },
      { id: "cc", runtime: "claude-code", enabled: true },
    ],
  }));
  const batch = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "restricted-child",
    rootCwd: "/root-workspace",
    sourceCwd: "/child-workspace",
    sandboxMode: "read-only",
    sourceToolAllowlist: ["read"],
    task: "legacy work",
    mode: "execution",
    integrationPolicy: "auto",
    source: "model",
  });
  await state.updateRun(batch.runs[0].id, { status: "running" });
  await state.updateRun(batch.runs[1].id, { status: "queued" });
  const file = path.join(root, "state.json");
  const disk = JSON.parse(await readFile(file, "utf8"));
  delete disk.batches[0].capabilitySnapshotVersion;
  delete disk.batches[0].sourceCwd;
  delete disk.batches[0].sandboxMode;
  delete disk.batches[0].sourceAgentOptions;
  delete disk.batches[0].sourceToolAllowlist;
  delete disk.batches[0].sourceAgentPreset;
  await writeFile(file, JSON.stringify(disk));

  const reopened = await AgentPlatformState.open(root);
  const legacy = reopened.batch(batch.id);
  for (const run of legacy.runs) {
    assert.equal(run.status, "interrupted");
    assert.equal(run.retryable, false);
    assert.equal(run.recoveryBlocked, true);
    assert.match(run.error, /capability snapshot/i);
  }
  assert.equal(legacy.integrationPolicy, "manual");
  assert.equal(legacy.integrationState, "manualPending");
  assert.deepEqual(reopened.queuedRuns(), []);
  await assert.rejects(() => reopened.retryRun(batch.runs[0].id), /capability snapshot/);
});

test("versioned but incomplete capability snapshots also fail closed on upgrade", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-incomplete-capability-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile());
  const batch = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "restricted-child",
    rootCwd: "/root-workspace",
    sourceCwd: "/child-workspace",
    sandboxMode: "read-only",
    sourceAgentOptions: { provider: "relay", model: "source-model" },
    sourceToolAllowlist: ["read"],
    sourceAgentPreset: "code",
    task: "incomplete work",
    mode: "execution",
    integrationPolicy: "manual",
    source: "model",
  });
  await state.updateRun(batch.runs[0].id, { status: "running" });
  const file = path.join(root, "state.json");
  const disk = JSON.parse(await readFile(file, "utf8"));
  delete disk.batches[0].sourceAgentPreset;
  await writeFile(file, JSON.stringify(disk));

  const reopened = await AgentPlatformState.open(root);
  const recovered = reopened.batch(batch.id);
  assert.equal(recovered.capabilitySnapshotVersion, 1);
  assert.equal(recovered.recoveryBlocked, true);
  assert.equal(recovered.runs[0].status, "interrupted");
  assert.equal(recovered.runs[0].retryable, false);
  assert.deepEqual(reopened.queuedRuns(), []);
});

test("legacy terminal Batches cancel pending automatic integration on upgrade", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-legacy-integration-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile({ integrationPolicy: "auto" }));
  const requested = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "restricted-child",
    sourceCwd: "/child-workspace",
    sandboxMode: "read-only",
    sourceToolAllowlist: ["read"],
    task: "legacy requested work",
    mode: "analysis",
    integrationPolicy: "auto",
    source: "model",
  });
  const failed = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "restricted-child",
    sourceCwd: "/child-workspace",
    sandboxMode: "read-only",
    sourceToolAllowlist: ["read"],
    task: "legacy failed work",
    mode: "analysis",
    integrationPolicy: "auto",
    source: "model",
  });
  await state.updateRun(requested.runs[0].id, { status: "succeeded", output: "requested result" });
  await state.updateRun(failed.runs[0].id, { status: "succeeded", output: "failed result" });
  await state.markIntegrationFailed(failed.id, new Error("delivery failed"));
  await state.prepareIntegrationDelivery(requested.id, { text: "stale integration" });

  const file = path.join(root, "state.json");
  const disk = JSON.parse(await readFile(file, "utf8"));
  for (const batch of disk.batches) {
    delete batch.capabilitySnapshotVersion;
    delete batch.sourceCwd;
    delete batch.sandboxMode;
    delete batch.sourceToolAllowlist;
  }
  await writeFile(file, JSON.stringify(disk));

  const reopened = await AgentPlatformState.open(root);
  for (const batchId of [requested.id, failed.id]) {
    const legacy = reopened.batch(batchId);
    assert.equal(legacy.recoveryBlocked, true);
    assert.equal(legacy.integrationPolicy, "manual");
    assert.equal(legacy.integrationState, "manualPending");
    assert.equal(legacy.integrationDelivery, undefined);
    assert.equal(legacy.runs[0].status, "succeeded");
    assert.equal(legacy.runs[0].retryable, false);
    assert.equal(legacy.runs[0].recoveryBlocked, true);
    assert.equal(await reopened.prepareIntegrationDelivery(batchId, { text: "must not deliver" }), undefined);
    await assert.rejects(
      () => reopened.requestIntegration(batchId),
      /capability snapshot/i);
    await assert.rejects(
      () => reopened.setIntegration(batchId, "auto"),
      /capability snapshot/i);
  }
  assert.deepEqual(reopened.readyIntegrationBatchIds("root"), []);
});

test("restart migrates persisted DSH children to established while preserving explicit reservations", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-child-migration-"));
  await writeFile(path.join(root, "state.json"), JSON.stringify({
    version: 1,
    profiles: [],
    batches: [],
    contexts: [
      { id: "legacy", childSessionId: "legacy-child" },
      { id: "reserved", childSessionId: "reserved-child", childEstablished: false },
    ],
  }));

  const state = await AgentPlatformState.open(root);

  assert.equal(state.context("legacy").childEstablished, true);
  assert.equal(state.context("reserved").childEstablished, false);
});

test("restart preserves a DSH stop request as cancelled instead of resuming it", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-stop-recover-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile());
  const batch = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    task: "work",
    mode: "execution",
    integrationPolicy: "manual",
    source: "manual",
  });
  await state.updateRun(batch.runs[0].id, { status: "stopping" });

  const reopened = await AgentPlatformState.open(root);
  const recovered = reopened.run(batch.runs[0].id);
  assert.equal(recovered.status, "cancelled");
  assert.equal(recovered.retryable, true);
  assert.equal(recovered.resumeAfterRestart, undefined);
  assert.deepEqual(reopened.recoveryRoots(), [{ sessionId: "root", cwd: "/workspace" }]);
});

test("recovery roots are unique across queued DSH batches", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-root-recover-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile());
  for (const task of ["one", "two"]) {
    await createBatch(state, {
      profileId: saved.id,
      rootSessionId: "root",
      initiatorSessionId: "root",
      rootCwd: "/workspace",
      task,
      mode: "execution",
      integrationPolicy: "manual",
      source: "manual",
    });
  }
  assert.deepEqual(state.recoveryRoots(), [{ sessionId: "root", cwd: "/workspace" }]);
});

test("undelivered summary and integration outboxes also recover their root Agent", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-outbox-root-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile({
    adapters: [{ id: "missing", runtime: "missing-runtime", enabled: true }],
  }));
  const batch = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    rootCwd: "/workspace",
    task: "fail",
    mode: "analysis",
    integrationPolicy: "auto",
    source: "manual",
  });
  await state.updateRun(batch.runs[0].id, { status: "failed" });
  assert.deepEqual(state.recoveryRoots(), [{ sessionId: "root", cwd: "/workspace" }]);
});

test("a batch settles once after all members become terminal", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-settle-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile({
    adapters: [
      { id: "dsh", runtime: "dsh", enabled: true },
      { id: "codex", runtime: "codex", enabled: true },
    ],
  }));
  const batch = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    task: "compare",
    mode: "analysis",
    integrationPolicy: "manual",
    source: "manual",
  });
  await state.updateRun(batch.runs[0].id, { status: "succeeded", output: "ok" });
  assert.equal(state.batch(batch.id).summary, undefined);
  await state.updateRun(batch.runs[1].id, { status: "failed", error: "unsupported-mode" });
  const settled = state.batch(batch.id);
  assert.equal(settled.status, "partial");
  assert.equal(settled.summaryRevision, 1);
  await state.updateRun(batch.runs[1].id, { error: "same terminal update" });
  assert.equal(state.batch(batch.id).summaryRevision, 1);
});

test("integration completion rejects run ids outside the batch", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-integrate-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile());
  const batch = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    task: "integrate",
    mode: "execution",
    integrationPolicy: "manual",
    source: "manual",
  });
  await state.updateRun(batch.runs[0].id, { status: "succeeded" });
  await assert.rejects(
    () => state.completeIntegration(batch.id, ["not-a-member"], "done"),
    /does not belong to batch/);
});

test("a Profile cannot bind the same RuntimeAdapter twice", () => {
  assert.throws(() => normalizeProfile(profile({
    adapters: [
      { id: "cc-fast", runtime: "claude-code", enabled: true, model: "fast" },
      { id: "cc-deep", runtime: "claude-code", enabled: true, model: "deep" },
    ],
  }), []), /duplicate RuntimeAdapter/);
});

test("one failed Run can create only one retry Batch", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-retry-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile({
    adapters: [{ id: "codex", runtime: "codex", enabled: true }],
  }));
  const batch = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    task: "implement",
    mode: "execution",
    integrationPolicy: "manual",
    source: "manual",
  });
  await state.updateRun(batch.runs[0].id, {
    status: "failed",
    worktreePath: "/tmp/shared-worktree",
  });

  const retry = await state.retryRun(batch.runs[0].id);
  await assert.rejects(() => state.retryRun(batch.runs[0].id), /already retried/);
  assert.equal(state.run(batch.runs[0].id).retryable, false);
  assert.equal(retry.runs[0].retryOfRunId, batch.runs[0].id);
});

test("retryable follows terminal outcome instead of being enabled while running or succeeded", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-retryable-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile());
  const succeededBatch = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    task: "succeed",
    mode: "analysis",
    integrationPolicy: "manual",
    source: "manual",
  });
  assert.equal(succeededBatch.runs[0].retryable, false);
  await state.updateRun(succeededBatch.runs[0].id, { status: "succeeded" });
  assert.equal(state.run(succeededBatch.runs[0].id).retryable, false);

  const failedBatch = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    task: "fail",
    mode: "analysis",
    integrationPolicy: "manual",
    source: "manual",
  });
  await state.updateRun(failedBatch.runs[0].id, { status: "failed" });
  assert.equal(state.run(failedBatch.runs[0].id).retryable, true);
});

test("a workspace cannot be cleaned while a retry Run sharing it is active", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-workspace-active-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile({
    adapters: [{ id: "codex", runtime: "codex", enabled: true }],
  }));
  const batch = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    task: "implement",
    mode: "execution",
    integrationPolicy: "manual",
    source: "manual",
  });
  await state.updateRun(batch.runs[0].id, {
    status: "failed",
    worktreePath: "/tmp/shared-worktree",
  });
  const retry = await state.retryRun(batch.runs[0].id);
  await state.updateRun(retry.runs[0].id, { status: "running" });
  assert.throws(
    () => state.assertRunWorkspaceClosable(batch.runs[0].id),
    /workspace still has active runs/);
});

test("cleaning a shared retry workspace updates every historical Run", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-workspace-clean-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile({
    adapters: [{ id: "codex", runtime: "codex", enabled: true }],
  }));
  const batch = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    task: "implement",
    mode: "execution",
    integrationPolicy: "manual",
    source: "manual",
  });
  await state.updateRun(batch.runs[0].id, {
    status: "failed",
    worktreePath: "/tmp/shared-worktree",
    worktreeRoot: "/tmp/shared-worktree",
  });
  const retry = await state.retryRun(batch.runs[0].id);
  await state.updateRun(retry.runs[0].id, { status: "succeeded" });
  await state.recordRunInspection(retry.runs[0].id, {
    diffSummary: "1 file changed",
    files: ["src/app.js"],
  });
  await state.markRunWorkspaceCleaned(retry.runs[0].id, "adopted");

  for (const runId of [batch.runs[0].id, retry.runs[0].id]) {
    const run = state.run(runId);
    assert.equal(run.workspaceCleaned, true);
    assert.equal(run.workspaceOutcome, "adopted");
    assert.equal(run.diffSummary, "1 file changed");
    assert.deepEqual(run.workspaceFiles, ["src/app.js"]);
  }
});

test("discarding the final external workspace moves its Batch to discarded", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-workspace-discard-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile({
    adapters: [{ id: "codex", runtime: "codex", enabled: true }],
  }));
  const batch = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    task: "implement",
    mode: "execution",
    integrationPolicy: "manual",
    source: "manual",
  });
  await state.updateRun(batch.runs[0].id, {
    status: "succeeded",
    worktreePath: "/tmp/external-worktree",
  });

  await state.markRunWorkspaceCleaned(batch.runs[0].id, "discarded");

  assert.equal(state.run(batch.runs[0].id).discarded, true);
  assert.equal(state.batch(batch.id).integrationState, "discarded");
});

test("binding a DSH Run makes its context ownership visible before persistence completes", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-context-bind-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile());
  const batch = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    task: "implement",
    mode: "execution",
    integrationPolicy: "manual",
    source: "manual",
  });
  const context = {
    id: "context-1",
    key: "shared",
    runtime: "dsh",
    rootSessionId: "root",
    parentSessionId: "root",
    profileId: saved.id,
    profileSnapshot: batch.profileSnapshot,
    bindingSnapshot: batch.runs[0].adapterSnapshot,
    mode: "execution",
    workspacePath: "/tmp/context-1",
  };

  const pending = state.bindRunToContext(batch.runs[0].id, context);
  assert.equal(state.context(context.id)?.id, context.id);
  assert.equal(state.run(batch.runs[0].id).contextId, context.id);
  assert.equal(state.run(batch.runs[0].id).status, "preparing");
  await pending;
});

test("binding refuses a DSH context that started closing after scheduling", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-bind-closing-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile());
  const batch = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    task: "implement",
    mode: "execution",
    integrationPolicy: "manual",
    source: "manual",
  });
  const context = {
    id: "context-1",
    key: `dsh:root:${saved.id}:execution`,
    runtime: "dsh",
    rootSessionId: "root",
    parentSessionId: "root",
    profileId: saved.id,
    mode: "execution",
  };
  await state.upsertContext(context);
  await state.prepareContextClose(context.id, "discarded");

  assert.equal(await state.bindRunToContext(batch.runs[0].id, context), undefined);
  assert.equal(state.run(batch.runs[0].id).status, "queued");
  assert.equal(state.run(batch.runs[0].id).contextId, undefined);
});

test("requested execution integration blocks later DSH batches on the same context lane", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-integration-barrier-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile());
  const first = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    rootCwd: "/workspace",
    task: "first",
    mode: "execution",
    integrationPolicy: "auto",
    source: "manual",
  });
  const second = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    rootCwd: "/workspace",
    task: "second",
    mode: "execution",
    integrationPolicy: "manual",
    source: "manual",
  });
  assert.equal(state.dshIntegrationBlocked(second.id), true);
  await state.updateRun(first.runs[0].id, { status: "succeeded" });
  assert.equal(state.dshIntegrationBlocked(second.id), true);
  await state.completeIntegration(first.id, [], "Do not adopt this result.");
  assert.equal(state.dshIntegrationBlocked(second.id), false);
});

test("a failed DSH cleanup transaction keeps later Batches blocked on the same lane", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-integration-failed-barrier-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile());
  const first = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    task: "first",
    mode: "execution",
    integrationPolicy: "manual",
    source: "manual",
  });
  const second = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    task: "second",
    mode: "execution",
    integrationPolicy: "manual",
    source: "manual",
  });
  await state.updateRun(first.runs[0].id, {
    status: "succeeded",
    contextId: "context-1",
  });
  await state.upsertContext({
    id: "context-1",
    key: "shared",
    runtime: "dsh",
    rootSessionId: "root",
    parentSessionId: "root",
    profileId: saved.id,
    mode: "execution",
  });
  await state.prepareIntegrationCompletion(first.id, [first.runs[0].id], "adopt");
  await state.markIntegrationFailed(first.id, new Error("context cleanup failed"));

  assert.equal(state.dshIntegrationBlocked(second.id), true);
  await state.closeContext("context-1", "adopted");
  assert.equal(state.dshIntegrationBlocked(second.id), true);
  await state.completeIntegration(first.id, [first.runs[0].id], "adopt");
  assert.equal(state.dshIntegrationBlocked(second.id), false);
});

test("a closing DSH context blocks new Runs on the same analysis or execution lane", async () => {
  for (const mode of ["analysis", "execution"]) {
    const root = await mkdtemp(path.join(os.tmpdir(), `dsh-agent-context-closing-${mode}-`));
    const state = await AgentPlatformState.open(root);
    const saved = await state.saveProfile(profile());
    const batch = await createBatch(state, {
      profileId: saved.id,
      rootSessionId: "root",
      initiatorSessionId: "root",
      task: "next",
      mode,
      integrationPolicy: "manual",
      source: "manual",
    });
    await state.upsertContext({
      id: `context-${mode}`,
      key: `dsh:root:${saved.id}:${mode}`,
      runtime: "dsh",
      rootSessionId: "root",
      parentSessionId: "root",
      profileId: saved.id,
      mode,
      closeIntent: { outcome: mode === "analysis" ? "reset" : "discarded", preparedAt: Date.now() },
    });

    assert.equal(state.dshIntegrationBlocked(batch.id), true);
  }
});

test("DSH context lanes are isolated by the actual initiating parent session", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-parent-lanes-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile());
  const first = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "child-a",
    task: "first",
    mode: "execution",
    integrationPolicy: "manual",
    source: "model",
  });
  const second = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "child-b",
    task: "second",
    mode: "execution",
    integrationPolicy: "manual",
    source: "model",
  });
  await state.upsertContext({
    id: "context-a",
    key: `dsh:child-a:${saved.id}:execution`,
    runtime: "dsh",
    rootSessionId: "root",
    parentSessionId: "root",
    ownerSessionId: "child-a",
    profileId: saved.id,
    mode: "execution",
    closeIntent: { outcome: "discarded", preparedAt: Date.now() },
  });

  assert.equal(state.dshIntegrationBlocked(first.id), true);
  assert.equal(state.dshIntegrationBlocked(second.id), false);
});

test("adopting one DSH Run adopts every Run sharing its continuable context", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-context-adopt-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile({
    adapters: [
      { id: "dsh", runtime: "dsh", enabled: true },
      { id: "codex", runtime: "codex", enabled: true },
    ],
  }));
  const first = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    task: "first",
    mode: "execution",
    integrationPolicy: "manual",
    source: "manual",
  });
  const second = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    task: "second",
    mode: "execution",
    integrationPolicy: "manual",
    source: "manual",
  });
  const firstDsh = first.runs.find((run) => run.adapter === "dsh");
  const secondDsh = second.runs.find((run) => run.adapter === "dsh");
  const secondCodex = second.runs.find((run) => run.adapter === "codex");
  for (const run of first.runs) {
    await state.updateRun(run.id, {
      status: "succeeded",
      ...run.adapter === "dsh" ? { contextId: "context-1" } : {},
    });
  }
  for (const run of second.runs) {
    await state.updateRun(run.id, {
      status: "succeeded",
      ...run.adapter === "dsh" ? { contextId: "context-1" } : {},
    });
  }

  await state.completeIntegration(
    second.id,
    [secondDsh.id, secondCodex.id],
    "Adopt the accumulated DSH context and the second Codex result.",
    "tests passed");

  assert.equal(state.run(firstDsh.id).adopted, true);
  assert.equal(state.run(secondDsh.id).adopted, true);
  assert.equal(state.batch(first.id).integrationState, "partiallyAdopted");
  assert.equal(state.batch(second.id).integrationState, "adopted");
  assert.equal(state.batch(first.id).integrationSummary, "Adopt the accumulated DSH context and the second Codex result.");
});

test("integration requests reject while a shared DSH context still has an active Run", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-context-request-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile());
  const first = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    task: "first",
    mode: "execution",
    integrationPolicy: "manual",
    source: "manual",
  });
  const second = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    task: "second",
    mode: "execution",
    integrationPolicy: "manual",
    source: "manual",
  });
  await state.updateRun(first.runs[0].id, { status: "succeeded", contextId: "context-1" });
  await state.updateRun(second.runs[0].id, { status: "running", contextId: "context-1" });

  await assert.rejects(
    () => state.requestIntegration(first.id),
    /shared DSH context still has active runs/);
});

test("integration delivery stays deferred until every shared DSH context Run settles", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-context-delivery-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile());
  const first = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    task: "first",
    mode: "execution",
    integrationPolicy: "auto",
    source: "manual",
  });
  const second = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    task: "second",
    mode: "execution",
    integrationPolicy: "manual",
    source: "manual",
  });
  await state.updateRun(first.runs[0].id, { status: "succeeded", contextId: "context-1" });
  await state.updateRun(second.runs[0].id, { status: "running", contextId: "context-1" });

  assert.equal(await state.prepareIntegrationDelivery(first.id, { text: "integrate" }), undefined);
  assert.deepEqual(state.readyIntegrationBatchIds("root"), []);

  await state.updateRun(second.runs[0].id, { status: "succeeded" });
  assert.deepEqual(state.readyIntegrationBatchIds("root"), [first.id]);
  assert.notEqual(await state.prepareIntegrationDelivery(first.id, { text: "integrate" }), undefined);
});

test("integration completion rejects while a shared DSH context still has an active Run", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-context-complete-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile());
  const first = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    task: "first",
    mode: "execution",
    integrationPolicy: "manual",
    source: "manual",
  });
  const second = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    task: "second",
    mode: "execution",
    integrationPolicy: "manual",
    source: "manual",
  });
  await state.updateRun(first.runs[0].id, { status: "succeeded", contextId: "context-1" });
  await state.updateRun(second.runs[0].id, { status: "running", contextId: "context-1" });

  await assert.rejects(
    () => state.completeIntegration(first.id, [first.runs[0].id], "adopt"),
    /shared DSH context still has active runs/);
});

test("discarding a DSH context updates every affected Batch and preserves its task history", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-context-discard-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile({
    adapters: [
      { id: "dsh", runtime: "dsh", enabled: true },
      { id: "codex", runtime: "codex", enabled: true },
    ],
  }));
  const batches = [];
  for (const task of ["first task", "second task"]) {
    const batch = await createBatch(state, {
      profileId: saved.id,
      rootSessionId: "root",
      initiatorSessionId: "root",
      task,
      mode: "execution",
      integrationPolicy: "manual",
      source: "manual",
    });
    for (const run of batch.runs) {
      await state.updateRun(run.id, {
        status: "succeeded",
        ...run.adapter === "dsh" ? { contextId: "context-1" } : {},
      });
    }
    batches.push(batch);
  }
  await state.upsertContext({
    id: "context-1",
    key: "shared",
    runtime: "dsh",
    rootSessionId: "root",
    parentSessionId: "root",
    profileId: saved.id,
    mode: "execution",
    workspacePath: "/tmp/context-1",
  });

  assert.deepEqual(
    state.integrationContextHistory(batches[0].id).map((batch) => batch.task),
    ["first task", "second task"]);
  await state.closeContext("context-1", "discarded");

  for (const batch of batches) {
    const updated = state.batch(batch.id);
    assert.equal(updated.runs.find((run) => run.adapter === "dsh").discarded, true);
    assert.equal(updated.integrationState, "partiallyDiscarded");
  }
});

test("resetting an analysis context preserves historical Run integration state", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-analysis-reset-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile());
  const batch = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    task: "review",
    mode: "analysis",
    integrationPolicy: "manual",
    source: "manual",
  });
  await state.updateRun(batch.runs[0].id, {
    status: "succeeded",
    contextId: "analysis-context",
  });
  await state.upsertContext({
    id: "analysis-context",
    key: "analysis",
    runtime: "dsh",
    rootSessionId: "root",
    parentSessionId: "root",
    profileId: saved.id,
    mode: "analysis",
  });
  await state.completeIntegration(batch.id, [batch.runs[0].id], "adopt review");
  await state.closeContext("analysis-context", "reset");

  const historical = state.batch(batch.id);
  assert.equal(historical.integrationState, "adopted");
  assert.equal(historical.runs[0].adopted, true);
  assert.equal(historical.runs[0].discarded, undefined);
  assert.equal(state.context("analysis-context").outcome, "reset");
});

test("integration instructions expose every task accumulated in a shared DSH context", () => {
  const contextId = "context-1";
  const first = {
    id: "batch-1",
    task: "first task",
    mode: "execution",
    runs: [{
      id: "run-1",
      adapter: "dsh",
      label: "DSH",
      status: "succeeded",
      contextId,
      worktreePath: "/tmp/shared",
    }],
  };
  const second = {
    id: "batch-2",
    task: "second task",
    mode: "execution",
    runs: [{
      id: "run-2",
      adapter: "dsh",
      label: "DSH",
      status: "succeeded",
      contextId,
      worktreePath: "/tmp/shared",
      diffSummary: "2 files changed",
    }],
  };

  const prompt = renderIntegrationPrompt(second, [first, second]);

  assert.match(prompt, /Original task: second task/);
  assert.match(prompt, /Shared DSH context history/);
  assert.match(prompt, /Batch batch-1: first task/);
  assert.match(prompt, /run-1/);
  assert.match(prompt, /Batch batch-2: second task/);
  assert.match(prompt, /cumulative/);
});

test("analysis integration instructions do not claim a cumulative worktree lifecycle", () => {
  const batch = {
    id: "analysis-batch",
    task: "review",
    mode: "analysis",
    runs: [{
      id: "analysis-run",
      adapter: "dsh",
      label: "DSH",
      status: "succeeded",
      contextId: "analysis-context",
      output: "review result",
    }],
  };

  const prompt = renderIntegrationPrompt(batch, [batch]);

  assert.doesNotMatch(prompt, /Shared DSH context history/);
  assert.doesNotMatch(prompt, /worktree is cumulative/);
  assert.match(prompt, /review result/);
});

test("integration instructions identify preferred and remaining eligible Runs", () => {
  const batch = {
    id: "preferred-batch",
    task: "compare",
    mode: "execution",
    preferredRunIds: ["run-2"],
    runs: [
      {
        id: "run-1",
        adapter: "claude-code",
        label: "Claude",
        status: "succeeded",
        adopted: true,
        workspaceCleaned: true,
        workspaceOutcome: "adopted",
      },
      {
        id: "run-2",
        adapter: "codex",
        label: "Codex",
        status: "succeeded",
        worktreePath: "/tmp/codex",
      },
    ],
  };

  const prompt = renderIntegrationPrompt(batch, [batch]);

  assert.match(prompt, /Preferred Runs for this request: run-2/);
  assert.match(prompt, /Remaining eligible Runs: run-2/);
  assert.match(prompt, /run-1.*adopted/);
});

test("integration completion cannot adopt a Run whose workspace was discarded", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-discarded-adopt-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile());
  const batch = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    task: "discard then integrate",
    mode: "execution",
    integrationPolicy: "manual",
    source: "manual",
  });
  await state.updateRun(batch.runs[0].id, { status: "succeeded", contextId: "context-1" });
  await state.upsertContext({
    id: "context-1",
    key: "shared",
    runtime: "dsh",
    rootSessionId: "root",
    parentSessionId: "root",
    profileId: saved.id,
    mode: "execution",
    workspacePath: "/tmp/context-1",
  });
  await state.closeContext("context-1", "discarded");

  await assert.rejects(
    () => state.completeIntegration(batch.id, [batch.runs[0].id], "too late"),
    /discarded/);
});

test("integration selection validates discarded Runs before cleanup begins", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-integration-selection-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile({
    adapters: [{ id: "codex", runtime: "codex", enabled: true }],
  }));
  const batch = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    task: "validate first",
    mode: "execution",
    integrationPolicy: "manual",
    source: "manual",
  });
  await state.updateRun(batch.runs[0].id, {
    status: "succeeded",
    worktreePath: "/tmp/discarded-worktree",
  });
  await state.markRunWorkspaceCleaned(batch.runs[0].id, "discarded");

  assert.throws(
    () => state.validateIntegrationSelection(batch.id, [batch.runs[0].id]),
    /discarded/);
  assert.equal(state.batch(batch.id).integrationState, "discarded");
});

test("integration execution failures can be explicitly retried", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-integration-failure-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile());
  const batch = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    task: "integrate",
    mode: "execution",
    integrationPolicy: "auto",
    source: "manual",
  });
  await state.updateRun(batch.runs[0].id, { status: "succeeded" });
  await state.markIntegrationFailed(batch.id, new Error("cleanup failed"));
  assert.equal(state.batch(batch.id).integrationState, "failed");
  assert.match(state.batch(batch.id).integrationError, /cleanup failed/);

  await state.requestIntegration(batch.id);
  assert.equal(state.batch(batch.id).integrationState, "requested");
});

test("partially adopted Batches can request integration for remaining members", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-partial-reintegration-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile({
    adapters: [
      { id: "claude", runtime: "claude-code", enabled: true },
      { id: "codex", runtime: "codex", enabled: true },
    ],
  }));
  const batch = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    task: "compare",
    mode: "execution",
    integrationPolicy: "manual",
    source: "manual",
  });
  for (const run of batch.runs) await state.updateRun(run.id, { status: "succeeded" });
  await state.completeIntegration(batch.id, [batch.runs[0].id], "adopt one");
  assert.equal(state.batch(batch.id).integrationState, "partiallyAdopted");

  await state.requestIntegration(batch.id, [batch.runs[1].id]);
  assert.equal(state.batch(batch.id).integrationState, "requested");
  assert.deepEqual(state.batch(batch.id).preferredRunIds, [batch.runs[1].id]);
});

test("integration requests reject when no member remains eligible for adoption", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-empty-integration-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile({
    adapters: [
      { id: "claude", runtime: "claude-code", enabled: true },
      { id: "codex", runtime: "codex", enabled: true },
    ],
  }));
  const batch = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    task: "compare",
    mode: "execution",
    integrationPolicy: "manual",
    source: "manual",
  });
  await state.updateRun(batch.runs[0].id, {
    status: "succeeded",
    worktreePath: "/tmp/claude-worktree",
  });
  await state.updateRun(batch.runs[1].id, {
    status: "succeeded",
    worktreePath: "/tmp/codex-worktree",
  });
  await state.markRunWorkspaceCleaned(batch.runs[0].id, "adopted");
  await state.markRunWorkspaceCleaned(batch.runs[1].id, "discarded");

  await assert.rejects(
    () => state.requestIntegration(batch.id),
    /no eligible Agent Runs/);
  assert.deepEqual(state.readyIntegrationBatchIds("root"), []);
});

test("integration completion intent survives restart until cleanup is finalized", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-integration-intent-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile({
    adapters: [{ id: "codex", runtime: "codex", enabled: true }],
  }));
  const batch = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    rootCwd: "/workspace",
    task: "integrate",
    mode: "execution",
    integrationPolicy: "manual",
    source: "manual",
  });
  await state.updateRun(batch.runs[0].id, {
    status: "succeeded",
    worktreePath: "/tmp/codex-worktree",
  });

  await state.prepareIntegrationCompletion(
    batch.id,
    [batch.runs[0].id],
    "adopt codex",
    "tests passed");
  const reopened = await AgentPlatformState.open(root);
  assert.equal(reopened.batch(batch.id).integrationState, "integrating");
  assert.deepEqual(reopened.pendingIntegrationCompletions(), [{
    batchId: batch.id,
    adoptedRunIds: [batch.runs[0].id],
    summary: "adopt codex",
    testSummary: "tests passed",
  }]);

  await reopened.completeIntegration(batch.id, [batch.runs[0].id], "adopt codex", "tests passed");
  assert.deepEqual(reopened.pendingIntegrationCompletions(), []);
});

test("workspace cleanup intent survives a crash between inspection and physical deletion", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-workspace-cleanup-intent-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile({
    adapters: [{ id: "codex", runtime: "codex", enabled: true }],
  }));
  const batch = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    task: "integrate",
    mode: "execution",
    integrationPolicy: "manual",
    source: "manual",
  });
  await state.updateRun(batch.runs[0].id, {
    status: "succeeded",
    worktreePath: "/tmp/codex-worktree",
  });
  await state.prepareRunWorkspaceCleanup(batch.runs[0].id, "adopted");

  const reopened = await AgentPlatformState.open(root);
  assert.equal(reopened.run(batch.runs[0].id).workspaceCleanupIntent.outcome, "adopted");
  await reopened.markRunWorkspaceCleaned(batch.runs[0].id, "adopted");
  assert.equal(reopened.run(batch.runs[0].id).workspaceCleanupIntent, undefined);
});

test("context close intent survives a crash after child disposal or worktree cleanup", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-context-close-intent-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile());
  const batch = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    task: "integrate",
    mode: "execution",
    integrationPolicy: "manual",
    source: "manual",
  });
  await state.updateRun(batch.runs[0].id, {
    status: "succeeded",
    contextId: "context-1",
  });
  await state.upsertContext({
    id: "context-1",
    key: "shared",
    runtime: "dsh",
    rootSessionId: "root",
    parentSessionId: "root",
    profileId: saved.id,
    mode: "execution",
    workspacePath: "/tmp/context-1",
  });
  await state.prepareContextClose("context-1", "adopted");

  const reopened = await AgentPlatformState.open(root);
  assert.equal(reopened.context("context-1").closeIntent.outcome, "adopted");
  assert.deepEqual(reopened.pendingContextCloses(), [{
    contextId: "context-1",
    outcome: "adopted",
    rootSessionId: "root",
  }]);
  await reopened.closeContext("context-1", "adopted");
  assert.equal(reopened.context("context-1").closeIntent, undefined);
  assert.equal(reopened.context("context-1").outcome, "adopted");
  assert.deepEqual(reopened.pendingContextCloses(), []);
});

test("manual context discard cannot race a persisted integration completion", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-context-cleanup-conflict-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile());
  const batch = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    task: "integrate",
    mode: "execution",
    integrationPolicy: "manual",
    source: "manual",
  });
  await state.updateRun(batch.runs[0].id, {
    status: "succeeded",
    contextId: "context-1",
  });
  await state.upsertContext({
    id: "context-1",
    key: "shared",
    runtime: "dsh",
    rootSessionId: "root",
    parentSessionId: "root",
    profileId: saved.id,
    mode: "execution",
  });

  await state.prepareIntegrationCompletion(batch.id, [batch.runs[0].id], "adopt");
  await assert.rejects(
    () => state.prepareContextClose("context-1", "discarded"),
    /integration completion.*in progress/);
  assert.equal(state.context("context-1").closeIntent, undefined);
});

test("integration completion cannot select a context already closing as discarded", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-integration-cleanup-conflict-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile());
  const batch = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    task: "integrate",
    mode: "execution",
    integrationPolicy: "manual",
    source: "manual",
  });
  await state.updateRun(batch.runs[0].id, {
    status: "succeeded",
    contextId: "context-1",
  });
  await state.upsertContext({
    id: "context-1",
    key: "shared",
    runtime: "dsh",
    rootSessionId: "root",
    parentSessionId: "root",
    profileId: saved.id,
    mode: "execution",
  });

  await state.prepareContextClose("context-1", "discarded");
  await assert.rejects(
    () => state.prepareIntegrationCompletion(batch.id, [batch.runs[0].id], "adopt"),
    /closing as discarded/);
  assert.deepEqual(state.pendingIntegrationCompletions(), []);
});

test("a failed cleanup intent is retried directly instead of redelivering integration instructions", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-integration-intent-failed-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile({
    adapters: [{ id: "codex", runtime: "codex", enabled: true }],
  }));
  const batch = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    task: "integrate",
    mode: "execution",
    integrationPolicy: "manual",
    source: "manual",
  });
  await state.updateRun(batch.runs[0].id, {
    status: "succeeded",
    worktreePath: "/tmp/codex-worktree",
  });
  await state.prepareIntegrationCompletion(batch.id, [batch.runs[0].id], "adopt");
  await state.markIntegrationFailed(batch.id, new Error("cleanup failed"));

  assert.deepEqual(state.readyIntegrationBatchIds("root"), []);
  assert.equal(await state.prepareIntegrationDelivery(batch.id, { text: "do not redeliver" }), undefined);
});

test("a different completion cannot replace one cleanup transaction already in progress", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-integration-intent-conflict-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile({
    adapters: [
      { id: "claude", runtime: "claude-code", enabled: true },
      { id: "codex", runtime: "codex", enabled: true },
    ],
  }));
  const batch = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    task: "integrate",
    mode: "execution",
    integrationPolicy: "manual",
    source: "manual",
  });
  for (const run of batch.runs) await state.updateRun(run.id, { status: "succeeded" });
  await state.prepareIntegrationCompletion(batch.id, [batch.runs[0].id], "adopt claude");

  await assert.rejects(
    () => state.prepareIntegrationCompletion(batch.id, [batch.runs[1].id], "adopt codex"),
    /already in progress/);
  assert.deepEqual(state.pendingIntegrationCompletions()[0].adoptedRunIds, [batch.runs[0].id]);
});

test("switching a failed cleanup transaction to auto resumes the existing intent", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-integration-intent-auto-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile({
    adapters: [{ id: "codex", runtime: "codex", enabled: true }],
  }));
  const batch = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    task: "integrate",
    mode: "execution",
    integrationPolicy: "manual",
    source: "manual",
  });
  await state.updateRun(batch.runs[0].id, {
    status: "succeeded",
    worktreePath: "/tmp/codex-worktree",
  });
  await state.prepareIntegrationCompletion(batch.id, [batch.runs[0].id], "adopt");
  await state.markIntegrationFailed(batch.id, new Error("cleanup failed"));

  const resumed = await state.setIntegration(batch.id, "auto");

  assert.equal(resumed.integrationPolicy, "auto");
  assert.equal(resumed.integrationState, "integrating");
  assert.deepEqual(resumed.integrationCompletion.adoptedRunIds, [batch.runs[0].id]);
  assert.deepEqual(state.readyIntegrationBatchIds("root"), []);
});

test("switching an active cleanup transaction to manual preserves its state and intent", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-integration-intent-manual-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile({
    adapters: [{ id: "codex", runtime: "codex", enabled: true }],
  }));
  const batch = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    task: "integrate",
    mode: "execution",
    integrationPolicy: "auto",
    source: "manual",
  });
  await state.updateRun(batch.runs[0].id, {
    status: "succeeded",
    worktreePath: "/tmp/codex-worktree",
  });
  await state.prepareIntegrationCompletion(batch.id, [batch.runs[0].id], "adopt");
  await state.markIntegrationFailed(batch.id, new Error("cleanup failed"));

  const manual = await state.setIntegration(batch.id, "manual");

  assert.equal(manual.integrationPolicy, "manual");
  assert.equal(manual.integrationState, "failed");
  assert.deepEqual(manual.integrationCompletion.adoptedRunIds, [batch.runs[0].id]);
});

test("restart requeues an integrating Batch when no cleanup transaction started", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-integration-requeue-"));
  const state = await AgentPlatformState.open(root);
  const saved = await state.saveProfile(profile({
    adapters: [{ id: "missing", runtime: "missing-runtime", enabled: true }],
  }));
  const batch = await createBatch(state, {
    profileId: saved.id,
    rootSessionId: "root",
    initiatorSessionId: "root",
    rootCwd: "/workspace",
    task: "integrate",
    mode: "analysis",
    integrationPolicy: "auto",
    source: "manual",
  });
  await state.updateRun(batch.runs[0].id, { status: "failed" });
  await state.markIntegrationRequested(batch.id, 1);
  assert.equal(state.batch(batch.id).integrationState, "integrating");

  const reopened = await AgentPlatformState.open(root);
  const recovered = reopened.batch(batch.id);
  assert.equal(recovered.integrationState, "requested");
  assert.equal(recovered.integrationRevision, 2);
  assert.deepEqual(reopened.recoveryRoots(), [{ sessionId: "root", cwd: "/workspace" }]);
});
