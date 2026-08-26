import assert from "node:assert/strict";
import test from "node:test";
import {
  adapterCommand,
  confineExternalCommand,
  dshAgentOptions,
  dshChildCwd,
  dshRunSettlement,
  dshRunPrompt,
  dshRecoveryDecision,
  dshToolRestriction,
  externalSandboxPolicy,
  inheritedToolAllowlist,
  initiatingCapabilitySnapshot,
  ownsManagedContext,
  reusableDshContext,
  isMissingContinuable,
  runCancellationRequested,
  runtimeCapabilities,
  startOrResumeReservedContinuable,
} from "../lib/runtime.js";

test("analysis mode is hard-filtered or explicitly unsupported", () => {
  assert.deepEqual(runtimeCapabilities("codex").analysisSupported, false);
  const claude = adapterCommand("claude-code", {
    mode: "analysis",
    task: "review",
    cwd: "/tmp/work",
    binding: {},
  });
  assert.ok(claude.args.includes("--tools"));
  assert.ok(claude.args.includes("--safe-mode"));
  assert.ok(!claude.args.join(" ").includes("Bash"));
  const zcode = adapterCommand("zcode", {
    mode: "analysis",
    task: "review",
    cwd: "/tmp/work",
    binding: {},
  });
  assert.ok(zcode.args.includes("--allowed-tools"));
  assert.throws(() => adapterCommand("codex", {
    mode: "analysis",
    task: "review",
    cwd: "/tmp/work",
    binding: {},
  }), /unsupported-mode/);
});

test("analysis allowlists cannot re-enable mutation or terminal tools", () => {
  const claude = adapterCommand("claude-code", {
    mode: "analysis",
    task: "review",
    cwd: "/tmp/work",
    binding: { toolAllowlist: ["Read", "Bash", "Write", "Grep"] },
  });
  const claudeTools = claude.args[claude.args.indexOf("--tools") + 1];
  assert.equal(claudeTools, "Read,Grep");

  const zcode = adapterCommand("zcode", {
    mode: "analysis",
    task: "review",
    cwd: "/tmp/work",
    binding: { toolAllowlist: ["Read", "Bash", "Write", "WebSearch"] },
  });
  const zcodeTools = zcode.args[zcode.args.indexOf("--allowed-tools") + 1];
  assert.equal(zcodeTools, "Read,WebSearch");

  const empty = adapterCommand("claude-code", {
    mode: "analysis",
    task: "review",
    cwd: "/tmp/work",
    binding: { toolAllowlist: ["Bash", "Write"] },
  });
  assert.ok(empty.args.includes("--tools"));
  assert.equal(empty.args[empty.args.indexOf("--tools") + 1], "");
});

test("current Codex execution uses supported approval configuration", () => {
  const codex = adapterCommand("codex", {
    mode: "execution",
    task: "implement",
    cwd: "/tmp/work",
    binding: {},
  });
  assert.ok(!codex.args.includes("-a"));
  assert.deepEqual(
    codex.args.slice(codex.args.indexOf("-c"), codex.args.indexOf("-c") + 2),
    ["-c", 'approval_policy="never"']);
});

test("Profile persona reaches every external Runtime", () => {
  const claude = adapterCommand("claude-code", {
    mode: "execution",
    task: "implement",
    persona: "Review before editing.",
    cwd: "/tmp/work",
    binding: {},
  });
  assert.deepEqual(
    claude.args.slice(claude.args.indexOf("--append-system-prompt"), claude.args.indexOf("--append-system-prompt") + 2),
    ["--append-system-prompt", "Review before editing."]);

  for (const runtime of ["codex", "zcode"]) {
    const command = adapterCommand(runtime, {
      mode: "execution",
      task: "implement",
      persona: "Review before editing.",
      cwd: "/tmp/work",
      binding: {},
    });
    assert.match(command.args.join("\n"), /Agent Profile persona:\nReview before editing\./);
  }
});

test("Claude Code execution bypasses interactive permissions inside its isolated worktree", () => {
  const claude = adapterCommand("claude-code", {
    mode: "execution",
    task: "implement",
    cwd: "/tmp/worktree",
    binding: {},
  });

  assert.ok(claude.args.includes("--dangerously-skip-permissions"));
  assert.ok(!claude.args.includes("--safe-mode"));
  assert.ok(!claude.args.includes("plan"));
});

test("external execution inherits the parent sandbox mode around its isolated worktree", () => {
  const calls = [];
  const command = {
    command: "/usr/local/bin/claude",
    args: ["-p", "implement"],
    cwd: "/tmp/member-worktree",
  };
  const policy = externalSandboxPolicy("execution", {
    mode: "workspace-write",
    workspaceRoot: "/tmp/parent-checkout",
    sessionId: "root-session",
  }, command.cwd);
  const confined = confineExternalCommand(command, policy, {
    confine(argv, policy) {
      calls.push({ argv, policy });
      return {
        argv: ["/usr/bin/sandbox-exec", "-p", "profile", "--", ...argv],
        enforcement: "full",
      };
    },
  });

  assert.deepEqual(calls, [{
    argv: ["/usr/local/bin/claude", "-p", "implement"],
    policy: {
      mode: "workspace-write",
      workspaceRoot: "/tmp/member-worktree",
      sessionId: "root-session",
    },
  }]);
  assert.equal(confined.command, "/usr/bin/sandbox-exec");
  assert.deepEqual(confined.args.slice(-3), ["/usr/local/bin/claude", "-p", "implement"]);
  assert.equal(confined.sandboxMode, "workspace-write");
  assert.equal(confined.sandboxEnforcement, "full");
});

test("external analysis is read-only and full-access execution stays inherited", () => {
  const modes = [];
  const sandbox = {
    confine(argv, policy) {
      modes.push(policy.mode);
      return { argv: ["/sandbox", "--", ...argv], enforcement: "full" };
    },
  };
  const command = {
    command: "/usr/local/bin/zcode",
    args: ["--mode", "plan"],
    cwd: "/tmp/work",
  };

  const analysis = confineExternalCommand(command, {
    ...externalSandboxPolicy("analysis", {
      mode: "danger-full-access",
      workspaceRoot: "/tmp/parent",
    }, command.cwd),
  }, sandbox);
  assert.equal(analysis.command, "/sandbox");
  assert.deepEqual(modes, ["read-only"]);

  const execution = confineExternalCommand(
    command,
    externalSandboxPolicy("execution", {
      mode: "danger-full-access",
      workspaceRoot: "/tmp/parent",
    }, command.cwd),
    sandbox);
  assert.equal(execution.command, command.command);
  assert.deepEqual(execution.args, command.args);
  assert.equal(execution.sandboxMode, "danger-full-access");
  assert.deepEqual(modes, ["read-only"]);
});

test("DSH restart continuation prompt requires an existing durable child", () => {
  assert.equal(dshRunPrompt("implement", true, undefined), "implement");
  assert.equal(dshRunPrompt("implement", false, "child-1"), "implement");
  assert.match(dshRunPrompt("implement", true, "child-1"), /Continue the interrupted task/);
});

test("reserved DSH child ids are created only after a missing-continuation result", () => {
  assert.equal(isMissingContinuable({ code: "NOT_RESUMABLE" }), true);
  assert.equal(isMissingContinuable(new Error("network failure")), false);
});

test("reserved DSH child delivery resumes first and creates only the same missing id", async () => {
  const calls = [];
  const resumed = await startOrResumeReservedContinuable({
    childId: "child-existing",
    messageId: "message-reserved",
    established: false,
    followup: async (childId, messageId) => {
      calls.push(["followup", childId, messageId]);
      return messageId;
    },
    start: async (childId, messageId) => {
      calls.push(["start", childId, messageId]);
      return { childId, messageId };
    },
  });
  assert.deepEqual(resumed, {
    childId: "child-existing",
    messageId: "message-reserved",
    created: false,
  });
  assert.deepEqual(calls, [["followup", "child-existing", "message-reserved"]]);

  calls.length = 0;
  const created = await startOrResumeReservedContinuable({
    childId: "child-reserved",
    messageId: "message-reserved",
    established: false,
    followup: async (childId, messageId) => {
      calls.push(["followup", childId, messageId]);
      throw { code: "NOT_RESUMABLE" };
    },
    start: async (childId, messageId) => {
      calls.push(["start", childId, messageId]);
      return { childId, messageId };
    },
  });
  assert.deepEqual(created, {
    childId: "child-reserved",
    messageId: "message-reserved",
    created: true,
  });
  assert.deepEqual(calls, [
    ["followup", "child-reserved", "message-reserved"],
    ["start", "child-reserved", "message-reserved"],
  ]);
});

test("reserved DSH child delivery does not hide non-resume failures", async () => {
  await assert.rejects(
    () => startOrResumeReservedContinuable({
      childId: "child-reserved",
      messageId: "message-reserved",
      established: false,
      followup: async () => {
        throw new Error("persistence unavailable");
      },
      start: async () => ({ childId: "child-reserved", messageId: "unexpected" }),
    }),
    /persistence unavailable/);
});

test("DSH settlement is reconstructed from the reserved message id", () => {
  const events = [
    { type: "turn/start", data: { turn: 7 } },
    { type: "user/message", data: { id: "message-reserved" } },
    {
      type: "assistant/message",
      data: {
        turn: 7,
        message: { content: [{ type: "text", text: "implemented" }] },
      },
    },
    { type: "turn/end", data: { turn: 7, reason: { kind: "completed" } } },
  ];

  assert.deepEqual(dshRunSettlement(events, "message-reserved"), {
    turn: 7,
    status: "succeeded",
    output: "implemented",
  });
  assert.equal(dshRunSettlement(events, "another-message"), undefined);
});

test("DSH settlement preserves interrupted and failed terminal reasons", () => {
  const interrupted = [
    { type: "turn/start", data: { turn: 2 } },
    { type: "user/message", data: { id: "message-reserved" } },
    { type: "turn/end", data: { turn: 2, reason: { kind: "interrupted" } } },
  ];
  assert.deepEqual(dshRunSettlement(interrupted, "message-reserved"), {
    turn: 2,
    status: "cancelled",
    error: "interrupted",
  });

  const failed = interrupted.map((event) => event.type === "turn/end"
    ? { ...event, data: { ...event.data, reason: { kind: "provider-error" } } }
    : event);
  assert.deepEqual(dshRunSettlement(failed, "message-reserved"), {
    turn: 2,
    status: "failed",
    error: "provider-error",
  });
});

test("DSH restart resumes only synthetic interrupted turns", () => {
  assert.equal(dshRecoveryDecision(undefined, true), "deliver");
  assert.equal(dshRecoveryDecision({
    turn: 3,
    status: "cancelled",
    error: "interrupted",
  }, true), "continue");
  assert.equal(dshRecoveryDecision({
    turn: 3,
    status: "succeeded",
    output: "done",
  }, true), "settle");
  assert.equal(dshRecoveryDecision({
    turn: 3,
    status: "failed",
    error: "provider-error",
  }, true), "settle");
  assert.equal(dshRecoveryDecision({
    turn: 3,
    status: "cancelled",
    error: "interrupted",
  }, false), "settle");
});

test("external preparation observes queued cancellation before spawning", () => {
  assert.equal(runCancellationRequested("queued", false), false);
  assert.equal(runCancellationRequested("stopping", true), true);
  assert.equal(runCancellationRequested("cancelled", false), true);
});

test("ZCode execution forwards tool policy and rejects unsupported model overrides", () => {
  const zcode = adapterCommand("zcode", {
    mode: "execution",
    task: "implement",
    cwd: "/tmp/work",
    binding: {
      toolAllowlist: ["Read", "Edit"],
      toolDenylist: ["Bash"],
    },
  });
  assert.equal(zcode.args[zcode.args.indexOf("--allowed-tools") + 1], "Read,Edit");
  assert.equal(zcode.args[zcode.args.indexOf("--disallowed-tools") + 1], "Bash");
  assert.throws(() => adapterCommand("zcode", {
    mode: "execution",
    task: "implement",
    cwd: "/tmp/work",
    binding: { model: "glm-custom" },
  }), /unsupported-config.*model/);
});

test("Codex rejects unsupported per-tool filtering instead of ignoring it", () => {
  assert.throws(() => adapterCommand("codex", {
    mode: "execution",
    task: "implement",
    cwd: "/tmp/work",
    binding: { toolDenylist: ["bash"] },
  }), /unsupported-config.*tool filtering/);
});

test("DSH execution preserves an explicit empty allowlist", () => {
  assert.deepEqual(
    dshToolRestriction("execution", { toolAllowlist: ["missing"] }, ["read", "bash"]),
    { allow: [] });
  assert.equal(dshToolRestriction("execution", {}, ["read", "bash"]), undefined);
});

test("DSH execution cannot widen the initiating Agent tool surface", () => {
  assert.deepEqual(
    dshToolRestriction(
      "execution",
      {},
      ["read", "grep", "bash", "write"],
      ["read", "grep"]),
    { allow: ["read", "grep"] });
  assert.deepEqual(
    dshToolRestriction(
      "execution",
      { toolAllowlist: ["read", "bash"], toolDenylist: ["grep"] },
      ["read", "grep", "bash", "write"],
      ["read", "grep"]),
    { allow: ["read"], deny: ["grep"] });
  assert.deepEqual(
    dshToolRestriction(
      "analysis",
      { toolAllowlist: ["read", "grep", "bash"] },
      ["read", "grep", "bash"],
      ["read"]),
    { allow: ["read"] });
});

test("DSH model options inherit the initiator before Profile overrides", () => {
  assert.deepEqual(
    dshAgentOptions(
      { provider: "relay", model: "source-model", maxTokens: 4096 },
      {}),
    { provider: "relay", model: "source-model", maxTokens: 4096 });
  assert.deepEqual(
    dshAgentOptions(
      { provider: "relay", model: "source-model", maxTokens: 4096 },
      { model: "openai/gpt-5.6" }),
    { provider: "openai", model: "gpt-5.6", maxTokens: 4096 });
});

test("initiating capability snapshots reject missing model routes or Agent Presets", () => {
  assert.deepEqual(
    initiatingCapabilitySnapshot(
      { provider: "relay", model: "source-model", maxTokens: 4096 },
      "code",
      ["read", "grep"]),
    {
      sourceAgentOptions: { provider: "relay", model: "source-model", maxTokens: 4096 },
      sourceAgentPreset: "code",
      sourceToolAllowlist: ["read", "grep"],
    });
  assert.throws(
    () => initiatingCapabilitySnapshot({ provider: "relay" }, "code", ["read"]),
    /model route/i);
  assert.throws(
    () => initiatingCapabilitySnapshot({ provider: "relay", model: "source-model" }, undefined, ["read"]),
    /Agent Preset/i);
});

test("DSH tool snapshots exclude initiator-local capabilities", () => {
  assert.deepEqual(
    inheritedToolAllowlist(
      ["read", "grep", "report_to_parent", "read"],
      ["read", "grep", "bash"]),
    ["read", "grep"]);
});

test("DSH analysis uses the initiating workspace while execution uses its worktree", () => {
  assert.equal(dshChildCwd("/initiator/worktree", undefined), "/initiator/worktree");
  assert.equal(dshChildCwd("/initiator/worktree", "/managed/worktree"), "/managed/worktree");
});

test("managed contexts are owned by their root or initiating Agent", () => {
  const context = {
    rootSessionId: "root",
    parentSessionId: "root",
    ownerSessionId: "child",
  };
  assert.equal(ownsManagedContext(context, "root"), true);
  assert.equal(ownsManagedContext(context, "child"), true);
  assert.equal(ownsManagedContext(context, "sibling"), false);
  assert.equal(ownsManagedContext(context, undefined), false);
});

test("legacy DSH contexts without capability snapshots are never reused", () => {
  const key = "dsh:child:profile:execution";
  const complete = {
    key,
    capabilitySnapshotVersion: 1,
    sourceCwd: "/workspace",
    sandboxMode: "workspace-write",
    sourceAgentOptions: { provider: "relay", model: "source-model" },
    sourceToolAllowlist: [],
    sourceAgentPreset: "code",
  };
  assert.equal(reusableDshContext(complete, key), true);
  assert.equal(reusableDshContext({ key }, key), false);
  assert.equal(reusableDshContext({
    ...complete,
    closeIntent: { outcome: "discarded" },
  }, key), false);
  for (const field of [
    "sourceCwd",
    "sandboxMode",
    "sourceAgentOptions",
    "sourceToolAllowlist",
    "sourceAgentPreset",
  ]) {
    const incomplete = { ...complete };
    delete incomplete[field];
    assert.equal(reusableDshContext(incomplete, key), false, field);
  }
});
