import { randomUUID } from "node:crypto";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";
import { hasCompleteInitiatingCapabilitySnapshot } from "./runtime.js";

const NONTERMINAL = new Set(["queued", "preparing", "running", "stopping"]);
const TERMINAL = new Set(["succeeded", "failed", "cancelled", "interrupted"]);
const MODES = new Set(["analysis", "execution"]);
const INTEGRATION_POLICIES = new Set(["manual", "auto"]);
const SANDBOX_MODES = new Set(["read-only", "workspace-write", "danger-full-access"]);
const MANUAL_INTEGRATION_PATTERNS = [
  /(?:不要|别|无需|不需要).{0,8}(?:自动整合|自动合并|自动采纳)/u,
  /(?:手动整合|手动合并|手动采纳)/u,
  /(?:不要|别|无需|不需要).{0,8}(?:采纳|整合|合并).{0,8}(?:改动|结果|代码)?/u,
];
const AUTO_INTEGRATION_PATTERNS = [
  /(?:自动|直接|请).{0,8}(?:整合|合并|采纳).{0,20}(?:改动|实现|结果|代码)?/u,
  /(?:采纳|整合|合并).{0,20}(?:的改动|的实现|的代码)/u,
];

function clone(value) {
  return structuredClone(value);
}

function now() {
  return Date.now();
}

function requiredString(value, name) {
  if (typeof value !== "string" || value.trim().length === 0) throw new TypeError(`${name} must be a non-empty string`);
  return value.trim();
}

function optionalString(value, name) {
  if (value === undefined || value === null || value === "") return undefined;
  if (typeof value !== "string") throw new TypeError(`${name} must be a string`);
  return value.trim() || undefined;
}

function stringList(value, name) {
  if (value === undefined || value === null) return undefined;
  if (!Array.isArray(value) || value.some((item) => typeof item !== "string")) throw new TypeError(`${name} must be an array of strings`);
  const normalized = [...new Set(value.map((item) => item.trim()).filter(Boolean))];
  return normalized.length === 0 ? undefined : normalized;
}

function stringSet(value, name) {
  if (value === undefined || value === null) return undefined;
  if (!Array.isArray(value) || value.some((item) => typeof item !== "string")) {
    throw new TypeError(`${name} must be an array of strings`);
  }
  return [...new Set(value.map((item) => item.trim()).filter(Boolean))];
}

function agentOptionsSnapshot(value, name) {
  if (value === undefined || value === null) return undefined;
  if (typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError(`${name} must be an object`);
  }
  const provider = optionalString(value.provider, `${name}.provider`);
  const model = optionalString(value.model, `${name}.model`);
  const maxTokens = value.maxTokens;
  if (maxTokens !== undefined
    && (!Number.isSafeInteger(maxTokens) || maxTokens <= 0)) {
    throw new TypeError(`${name}.maxTokens must be a positive integer`);
  }
  const snapshot = {
    ...provider === undefined ? {} : { provider },
    ...model === undefined ? {} : { model },
    ...maxTokens === undefined ? {} : { maxTokens },
  };
  return Object.keys(snapshot).length === 0 ? undefined : snapshot;
}

export function resolveIntegrationPolicy(task, selectedPolicy) {
  if (!INTEGRATION_POLICIES.has(selectedPolicy)) throw new TypeError("integrationPolicy must be manual or auto");
  const text = requiredString(task, "task");
  if (MANUAL_INTEGRATION_PATTERNS.some((pattern) => pattern.test(text))) return "manual";
  if (AUTO_INTEGRATION_PATTERNS.some((pattern) => pattern.test(text))) return "auto";
  return selectedPolicy;
}

function normalizeBinding(binding, index) {
  if (typeof binding !== "object" || binding === null || Array.isArray(binding)) throw new TypeError(`adapters[${index}] must be an object`);
  const runtime = requiredString(binding.runtime, `adapters[${index}].runtime`);
  return {
    id: optionalString(binding.id, `adapters[${index}].id`) ?? runtime,
    runtime,
    enabled: binding.enabled !== false,
    ...optionalString(binding.displayName, `adapters[${index}].displayName`) === undefined ? {} : { displayName: binding.displayName.trim() },
    ...optionalString(binding.model, `adapters[${index}].model`) === undefined ? {} : { model: binding.model.trim() },
    ...stringList(binding.toolAllowlist, `adapters[${index}].toolAllowlist`) === undefined ? {} : { toolAllowlist: stringList(binding.toolAllowlist, `adapters[${index}].toolAllowlist`) },
    ...stringList(binding.toolDenylist, `adapters[${index}].toolDenylist`) === undefined ? {} : { toolDenylist: stringList(binding.toolDenylist, `adapters[${index}].toolDenylist`) },
    ...typeof binding.analysisSupported === "boolean" ? { analysisSupported: binding.analysisSupported } : {},
    ...typeof binding.executionSupported === "boolean" ? { executionSupported: binding.executionSupported } : {},
    ...binding.config !== undefined
      ? {
          config: Object.fromEntries(Object.entries(
            typeof binding.config === "object" && binding.config !== null && !Array.isArray(binding.config)
              ? binding.config
              : (() => { throw new TypeError(`adapters[${index}].config must be an object`); })()
          ).map(([key, val]) => [key, String(val)])),
        }
      : {},
  };
}

export function normalizeProfile(input, currentProfiles, existing) {
  if (typeof input !== "object" || input === null || Array.isArray(input)) throw new TypeError("profile must be an object");
  const id = optionalString(input.id, "profile.id") ?? existing?.id ?? randomUUID();
  const name = requiredString(input.name, "profile.name");
  const mention = requiredString(input.mention, "profile.mention").replace(/^@+/, "");
  if (!/^[A-Za-z0-9_.-]+$/u.test(mention)) throw new TypeError("profile mention may contain only letters, numbers, dot, underscore, and hyphen");
  if (currentProfiles.some((profile) => profile.id !== id && profile.mention.toLowerCase() === mention.toLowerCase())) {
    throw new Error(`profile mention "${mention}" is already in use`);
  }
  const defaultMode = input.defaultMode ?? existing?.defaultMode ?? "analysis";
  if (!MODES.has(defaultMode)) throw new TypeError("profile defaultMode must be analysis or execution");
  const integrationPolicy = input.integrationPolicy ?? existing?.integrationPolicy ?? "manual";
  if (!INTEGRATION_POLICIES.has(integrationPolicy)) throw new TypeError("profile integrationPolicy must be manual or auto");
  const adapters = (input.adapters ?? existing?.adapters ?? []).map(normalizeBinding);
  if (adapters.length === 0 || !adapters.some((binding) => binding.enabled)) throw new Error("profile must enable at least one RuntimeAdapter");
  const duplicate = adapters.find((binding, index) => adapters.findIndex((candidate) => candidate.id === binding.id) !== index);
  if (duplicate !== undefined) throw new Error(`duplicate adapter binding id "${duplicate.id}"`);
  const duplicateRuntime = adapters.find((binding, index) =>
    adapters.findIndex((candidate) => candidate.runtime === binding.runtime) !== index);
  if (duplicateRuntime !== undefined) throw new Error(`duplicate RuntimeAdapter "${duplicateRuntime.runtime}"`);
  return {
    id,
    name,
    mention,
    ...optionalString(input.description, "profile.description") === undefined ? {} : { description: input.description.trim() },
    ...optionalString(input.persona, "profile.persona") === undefined ? {} : { persona: input.persona.trim() },
    ...optionalString(input.defaultTask, "profile.defaultTask") === undefined ? {} : { defaultTask: input.defaultTask.trim() },
    defaultMode,
    allowModelDispatch: input.allowModelDispatch === true,
    integrationPolicy,
    revision: (existing?.revision ?? 0) + 1,
    adapters,
  };
}

function batchStatus(runs) {
  if (runs.some((run) => NONTERMINAL.has(run.status))) return "running";
  const succeeded = runs.filter((run) => run.status === "succeeded").length;
  if (succeeded === runs.length) return "succeeded";
  if (succeeded > 0) return "partial";
  if (runs.every((run) => run.status === "cancelled")) return "cancelled";
  return "failed";
}

function renderSummary(batch) {
  const lines = batch.runs.map((run) => {
    const detail = run.output ?? run.error ?? run.status;
    return `- ${run.label ?? run.adapter}: ${run.status}${detail ? ` — ${detail}` : ""}`;
  });
  return [
    `Agent Batch ${batch.id} · ${batch.profileName} (${batch.mode}) 已结束。`,
    `原始任务：${batch.task}`,
    ...lines,
  ].join("\n");
}

function renderRunEvidence(run) {
  const adoption = run.adopted === true || run.workspaceOutcome === "adopted"
    ? "adopted"
    : run.discarded === true || run.workspaceOutcome === "discarded"
      ? "discarded"
      : undefined;
  return [
    `${run.label ?? run.adapter} (${run.id})`,
    run.worktreePath ? `worktree=${run.worktreePath}` : "no worktree",
    adoption ? `adoption=${adoption}` : "",
    run.workspaceCleaned === true ? `workspace=cleaned:${run.workspaceOutcome ?? "unknown"}` : "",
    run.diffSummary ? `diff=${run.diffSummary}` : "",
    run.testSummary ? `tests=${run.testSummary}` : "",
    run.output ? `result=${run.output}` : run.error ? `error=${run.error}` : "",
  ].filter(Boolean).join(" · ");
}

function integrationEligible(run) {
  if (run.adopted === true
    || run.discarded === true
    || run.workspaceCleaned === true
    || run.workspaceOutcome === "adopted"
    || run.workspaceOutcome === "discarded") return false;
  return run.worktreePath !== undefined
    || (typeof run.output === "string" && run.output.trim().length > 0)
    || TERMINAL.has(run.status);
}

export function renderIntegrationPrompt(batch, contextHistory = [batch]) {
  const contextIds = new Set((batch.mode === "execution" ? batch.runs : [])
    .filter((run) => run.adapter === "dsh" && run.contextId !== undefined)
    .map((run) => run.contextId));
  const eligible = batch.runs.filter(integrationEligible);
  const preferred = (batch.preferredRunIds ?? [])
    .filter((id) => eligible.some((run) => run.id === id));
  const historyLines = contextIds.size === 0 ? [] : [
    "Shared DSH context history (the worktree is cumulative across these Batches):",
    ...contextHistory.flatMap((candidate) => {
      const runs = candidate.runs.filter((run) =>
        run.contextId !== undefined && contextIds.has(run.contextId));
      if (runs.length === 0) return [];
      return [
        `Batch ${candidate.id}: ${candidate.task}`,
        ...runs.map((run) => `- ${renderRunEvidence(run)}`),
      ];
    }),
    "Adopting any listed DSH Run adopts the cumulative shared context and every DSH Run that used it.",
  ];
  return [
    `Agent Batch ${batch.id} requests selective integration.`,
    `Original task: ${batch.task}`,
    batch.runs.map(renderRunEvidence).join("\n"),
    preferred.length === 0 ? "" : `Preferred Runs for this request: ${preferred.join(", ")}`,
    `Remaining eligible Runs: ${eligible.length === 0 ? "none" : eligible.map((run) => run.id).join(", ")}`,
    ...historyLines,
    "Use inspect_agent_run when more workspace detail is needed.",
    "Inspect member outputs and any available worktrees, then integrate only the changes justified by the user's current natural-language intent.",
    "Do not blindly git merge or cherry-pick. Validate the resulting parent workspace, then call complete_agent_integration with adoptedRunIds and test evidence.",
  ].filter(Boolean).join("\n\n");
}

function contextIdentity(parentSessionId, profileId, mode) {
  return `dsh:${parentSessionId}:${profileId}:${mode}`;
}

function createRun(batchId, profile, binding, mode, attempt = 1, retryOfRunId) {
  return {
    id: randomUUID(),
    batchId,
    adapter: binding.runtime,
    adapterBindingId: binding.id,
    adapterSnapshot: clone(binding),
    runtimeProfileSnapshot: clone(profile),
    label: binding.displayName ?? binding.runtime,
    mode,
    status: "queued",
    attempt,
    queuedAt: now(),
    retryable: false,
    ...retryOfRunId === undefined ? {} : { retryOfRunId },
  };
}

export class AgentPlatformState {
  #root;
  #file;
  #data;
  #write = Promise.resolve();

  static async open(root) {
    await mkdir(root, { recursive: true });
    const file = path.join(root, "state.json");
    let data;
    try {
      data = JSON.parse(await readFile(file, "utf8"));
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
      data = { version: 1, profiles: [], batches: [], contexts: [] };
    }
    const state = new AgentPlatformState(root, file, data);
    await state.#recover();
    return state;
  }

  constructor(root, file, data) {
    this.#root = root;
    this.#file = file;
    this.#data = {
      version: 1,
      profiles: Array.isArray(data.profiles) ? data.profiles : [],
      batches: Array.isArray(data.batches) ? data.batches : [],
      contexts: Array.isArray(data.contexts) ? data.contexts : [],
    };
  }

  get root() {
    return this.#root;
  }

  profiles() {
    return clone(this.#data.profiles);
  }

  batch(id) {
    const batch = this.#data.batches.find((candidate) => candidate.id === id);
    if (batch === undefined) throw new Error(`batch "${id}" not found`);
    return clone(batch);
  }

  batches(rootSessionId) {
    return clone(this.#data.batches.filter((batch) => batch.rootSessionId === rootSessionId));
  }

  allBatches() {
    return clone(this.#data.batches);
  }

  contexts() {
    return clone(this.#data.contexts);
  }

  retainedWorkspaceRoots() {
    const retained = new Set();
    for (const context of this.#data.contexts) {
      if (context.closedAt !== undefined) continue;
      const workspace = context.worktreeRoot ?? context.workspacePath;
      if (workspace !== undefined) retained.add(workspace);
    }
    for (const run of this.#data.batches.flatMap((batch) => batch.runs)) {
      if (run.workspaceCleaned === true) continue;
      const workspace = run.worktreeRoot ?? run.worktreePath;
      if (workspace !== undefined) retained.add(workspace);
    }
    return [...retained];
  }

  context(id) {
    return clone(this.#data.contexts.find((candidate) => candidate.id === id));
  }

  run(id) {
    for (const batch of this.#data.batches) {
      const run = batch.runs.find((candidate) => candidate.id === id);
      if (run !== undefined) return clone(run);
    }
    throw new Error(`run "${id}" not found`);
  }

  batchForRun(runId) {
    const batch = this.#data.batches.find((candidate) => candidate.runs.some((run) => run.id === runId));
    if (batch === undefined) throw new Error(`run "${runId}" not found`);
    return clone(batch);
  }

  integrationContextHistory(batchId) {
    const batch = this.#batchRef(batchId);
    const contextIds = this.#integrationContextIds(batch);
    if (contextIds.size === 0) return [clone(batch)];
    return clone(this.#data.batches.filter((candidate) =>
      candidate.id === batch.id
      || candidate.runs.some((run) => run.contextId !== undefined && contextIds.has(run.contextId))));
  }

  readyIntegrationBatchIds(rootSessionId) {
    return this.#data.batches
      .filter((batch) =>
        batch.rootSessionId === rootSessionId
        && batch.recoveryBlocked !== true
        && ["requested", "failed"].includes(batch.integrationState)
        && batch.integrationCompletion === undefined
        && this.#integrationRequestReady(batch))
      .map((batch) => batch.id);
  }

  assertIntegrationReady(batchId) {
    const batch = this.#batchRef(batchId);
    this.#assertIntegrationReady(batch);
    return clone(batch);
  }

  async saveProfile(input) {
    const existing = input.id === undefined ? undefined : this.#data.profiles.find((profile) => profile.id === input.id);
    const saved = normalizeProfile(input, this.#data.profiles, existing);
    if (existing === undefined) this.#data.profiles.push(saved);
    else this.#data.profiles[this.#data.profiles.indexOf(existing)] = saved;
    await this.#persist();
    return clone(saved);
  }

  async removeProfile(id) {
    const index = this.#data.profiles.findIndex((profile) => profile.id === id);
    if (index < 0) throw new Error(`profile "${id}" not found`);
    this.#data.profiles.splice(index, 1);
    for (const batch of this.#data.batches) {
      if (batch.profileId === id) batch.profileDeleted = true;
    }
    await this.#persist();
  }

  async createBatch(input, onlyBinding) {
    const profile = this.#data.profiles.find((candidate) => candidate.id === input.profileId);
    if (profile === undefined) throw new Error(`profile "${input.profileId}" is deleted or unavailable`);
    const mode = input.mode ?? profile.defaultMode;
    if (!MODES.has(mode)) throw new TypeError("batch mode must be analysis or execution");
    const task = requiredString(input.task, "task");
    const integrationPolicy = resolveIntegrationPolicy(task, input.integrationPolicy ?? profile.integrationPolicy);
    if (!INTEGRATION_POLICIES.has(integrationPolicy)) throw new TypeError("batch integrationPolicy must be manual or auto");
    const rootSessionId = requiredString(input.rootSessionId, "rootSessionId");
    const initiatorSessionId = requiredString(input.initiatorSessionId, "initiatorSessionId");
    const rootCwd = optionalString(input.rootCwd, "rootCwd");
    const sourceCwd = optionalString(input.sourceCwd, "sourceCwd");
    const sandboxMode = optionalString(input.sandboxMode, "sandboxMode");
    const sourceAgentOptions = agentOptionsSnapshot(input.sourceAgentOptions, "sourceAgentOptions");
    const sourceToolAllowlist = stringSet(input.sourceToolAllowlist, "sourceToolAllowlist");
    const sourceAgentPreset = optionalString(input.sourceAgentPreset, "sourceAgentPreset");
    if (sandboxMode !== undefined && !SANDBOX_MODES.has(sandboxMode)) {
      throw new TypeError("batch sandboxMode is invalid");
    }
    if (!hasCompleteInitiatingCapabilitySnapshot({
      capabilitySnapshotVersion: 1,
      rootCwd,
      sourceCwd,
      sandboxMode,
      sourceAgentOptions,
      sourceToolAllowlist,
      sourceAgentPreset,
    }, true)) {
      throw new Error("batch requires a complete initiating capability snapshot");
    }
    const batchId = randomUUID();
    const bindings = profile.adapters.filter((binding) => binding.enabled && (onlyBinding === undefined || binding.id === onlyBinding.id));
    if (bindings.length === 0) throw new Error("batch has no enabled RuntimeAdapter members");
    const snapshot = clone(profile);
    const batch = {
      id: batchId,
      capabilitySnapshotVersion: 1,
      rootSessionId,
      initiatorSessionId,
      ...rootCwd === undefined ? {} : { rootCwd },
      ...sourceCwd === undefined ? {} : { sourceCwd },
      ...sandboxMode === undefined ? {} : { sandboxMode },
      ...sourceAgentOptions === undefined ? {} : { sourceAgentOptions },
      ...sourceToolAllowlist === undefined ? {} : { sourceToolAllowlist },
      ...sourceAgentPreset === undefined ? {} : { sourceAgentPreset },
      profileId: profile.id,
      profileName: profile.name,
      profileMention: profile.mention,
      profileSnapshot: snapshot,
      task,
      mode,
      integrationPolicy,
      integrationState: integrationPolicy === "auto" ? "requested" : "manualPending",
      integrationRevision: integrationPolicy === "auto" ? 1 : 0,
      status: "running",
      createdAt: now(),
      updatedAt: now(),
      runs: bindings.map((binding) => createRun(batchId, snapshot, binding, mode)),
      summaryRevision: 0,
      source: input.source ?? "manual",
      ...input.initiatorLabel === undefined ? {} : { initiatorLabel: String(input.initiatorLabel) },
      dispatch: {
        rootSessionId,
        initiatorSessionId,
        ...rootCwd === undefined ? {} : { rootCwd },
        ...sourceCwd === undefined ? {} : { sourceCwd },
        ...sandboxMode === undefined ? {} : { sandboxMode },
        ...sourceAgentOptions === undefined ? {} : { sourceAgentOptions },
        ...sourceToolAllowlist === undefined ? {} : { sourceToolAllowlist },
        ...sourceAgentPreset === undefined ? {} : { sourceAgentPreset },
        task,
        mode,
        integrationPolicy,
        source: input.source ?? "manual",
        profile: snapshot,
      },
      coordination: { status: "waiting" },
    };
    this.#data.batches.push(batch);
    await this.#persist();
    return clone(batch);
  }

  async updateRun(runId, patch) {
    const located = this.#locateRun(runId);
    Object.assign(located.run, clone(patch), { updatedAt: now() });
    if (located.run.status === "running" && located.run.startedAt === undefined) located.run.startedAt = now();
    if (TERMINAL.has(located.run.status) && located.run.finishedAt === undefined) located.run.finishedAt = now();
    located.run.retryable = ["failed", "cancelled", "interrupted"].includes(located.run.status)
      && located.run.workspaceCleaned !== true
      && located.run.retriedByRunId === undefined;
    located.batch.updatedAt = now();
    const nextStatus = batchStatus(located.batch.runs);
    located.batch.status = nextStatus;
    if (!located.batch.runs.some((run) => NONTERMINAL.has(run.status)) && located.batch.summaryRevision === 0) {
      located.batch.summary = renderSummary(located.batch);
      located.batch.summaryRevision = 1;
      located.batch.coordination = {
        ...(located.batch.coordination ?? {}),
        status: "ready",
        readyAt: now(),
      };
    }
    await this.#persist();
    return clone(located.run);
  }

  async retryRun(runId) {
    const { batch, run } = this.#locateRun(runId);
    if (batch.capabilitySnapshotVersion !== 1 || batch.recoveryBlocked === true) {
      throw new Error("cannot retry a run whose initiating capability snapshot is unavailable; dispatch a new Batch");
    }
    if (batch.profileDeleted === true || !this.#data.profiles.some((profile) => profile.id === batch.profileId)) {
      throw new Error("cannot retry a run whose Profile was deleted");
    }
    if (!TERMINAL.has(run.status) || run.status === "succeeded") {
      throw new Error("only a failed, interrupted, or cancelled run can be retried");
    }
    if (run.retryable === false || run.retriedByRunId !== undefined) {
      throw new Error("run was already retried");
    }
    if (run.workspaceCleaned === true || run.discarded === true) {
      throw new Error("cannot retry a run whose workspace was discarded");
    }
    const binding = batch.profileSnapshot.adapters.find((candidate) =>
      candidate.id === (run.adapterBindingId ?? run.adapter) && candidate.enabled);
    if (binding === undefined) throw new Error("run adapter binding is unavailable");
    const batchId = randomUUID();
    const profileSnapshot = clone(batch.profileSnapshot);
    const target = {
      id: batchId,
      capabilitySnapshotVersion: 1,
      rootSessionId: batch.rootSessionId,
      initiatorSessionId: batch.initiatorSessionId,
      ...batch.rootCwd === undefined ? {} : { rootCwd: batch.rootCwd },
      ...batch.sourceCwd === undefined ? {} : { sourceCwd: batch.sourceCwd },
      ...batch.sandboxMode === undefined ? {} : { sandboxMode: batch.sandboxMode },
      ...batch.sourceAgentOptions === undefined ? {} : { sourceAgentOptions: clone(batch.sourceAgentOptions) },
      ...batch.sourceToolAllowlist === undefined ? {} : { sourceToolAllowlist: clone(batch.sourceToolAllowlist) },
      ...batch.sourceAgentPreset === undefined ? {} : { sourceAgentPreset: batch.sourceAgentPreset },
      profileId: batch.profileId,
      profileName: batch.profileName,
      profileMention: batch.profileMention,
      profileSnapshot,
      task: batch.task,
      mode: batch.mode,
      integrationPolicy: batch.integrationPolicy,
      integrationState: batch.integrationPolicy === "auto" ? "requested" : "manualPending",
      integrationRevision: batch.integrationPolicy === "auto" ? 1 : 0,
      status: "running",
      createdAt: now(),
      updatedAt: now(),
      runs: [createRun(batchId, profileSnapshot, binding, batch.mode, (run.attempt ?? 1) + 1, run.id)],
      summaryRevision: 0,
      source: "retry",
      dispatch: {
        rootSessionId: batch.rootSessionId,
        initiatorSessionId: batch.initiatorSessionId,
        ...batch.rootCwd === undefined ? {} : { rootCwd: batch.rootCwd },
        ...batch.sourceCwd === undefined ? {} : { sourceCwd: batch.sourceCwd },
        ...batch.sandboxMode === undefined ? {} : { sandboxMode: batch.sandboxMode },
        ...batch.sourceAgentOptions === undefined ? {} : { sourceAgentOptions: clone(batch.sourceAgentOptions) },
        ...batch.sourceToolAllowlist === undefined ? {} : { sourceToolAllowlist: clone(batch.sourceToolAllowlist) },
        ...batch.sourceAgentPreset === undefined ? {} : { sourceAgentPreset: batch.sourceAgentPreset },
        task: batch.task,
        mode: batch.mode,
        integrationPolicy: batch.integrationPolicy,
        source: "retry",
        profile: profileSnapshot,
      },
      coordination: { status: "waiting" },
    };
    if (run.worktreePath !== undefined) target.runs[0].worktreePath = run.worktreePath;
    if (run.worktreeRoot !== undefined) target.runs[0].worktreeRoot = run.worktreeRoot;
    if (run.branch !== undefined) target.runs[0].branch = run.branch;
    if (run.gitRoot !== undefined) target.runs[0].gitRoot = run.gitRoot;
    if (run.baselineCommit !== undefined) target.runs[0].baselineCommit = run.baselineCommit;
    if (run.contextId !== undefined) target.runs[0].contextId = run.contextId;
    run.retryable = false;
    run.retriedByRunId = target.runs[0].id;
    this.#data.batches.push(target);
    await this.#persist();
    return clone(target);
  }

  async setIntegration(batchId, integrationPolicy) {
    if (!INTEGRATION_POLICIES.has(integrationPolicy)) throw new TypeError("integrationPolicy must be manual or auto");
    const batch = this.#batchRef(batchId);
    if (batch.recoveryBlocked === true && integrationPolicy === "auto") {
      throw new Error("cannot enable automatic integration when the initiating capability snapshot is unavailable; dispatch a new Batch");
    }
    if (["adopted", "discarded"].includes(batch.integrationState)) {
      throw new Error(`integration is already ${batch.integrationState}`);
    }
    batch.integrationPolicy = integrationPolicy;
    if (integrationPolicy === "auto") {
      if (batch.integrationCompletion !== undefined) {
        batch.integrationState = "integrating";
        delete batch.integrationError;
      } else if (batch.integrationState !== "requested" && batch.integrationState !== "integrating") {
        batch.integrationRevision = (batch.integrationRevision ?? 0) + 1;
        batch.integrationState = "requested";
      }
    } else if (batch.integrationCompletion !== undefined) {
      delete batch.integrationDelivery;
    } else {
      batch.integrationRevision = (batch.integrationRevision ?? 0) + 1;
      batch.integrationState = "manualPending";
      delete batch.integrationDelivery;
    }
    batch.updatedAt = now();
    await this.#persist();
    return clone(batch);
  }

  async requestIntegration(batchId, preferredRunIds) {
    const batch = this.#batchRef(batchId);
    this.#assertIntegrationRequestable(batch);
    if (["requested", "integrating", "adopted", "discarded"].includes(batch.integrationState)) {
      throw new Error(`integration is already ${batch.integrationState}`);
    }
    if (batch.integrationCompletion !== undefined) {
      batch.integrationState = "integrating";
      batch.updatedAt = now();
      delete batch.integrationError;
      await this.#persist();
      return clone(batch);
    }
    batch.integrationState = "requested";
    batch.integrationRevision = (batch.integrationRevision ?? 0) + 1;
    batch.preferredRunIds = preferredRunIds;
    batch.updatedAt = now();
    delete batch.integrationError;
    await this.#persist();
    return clone(batch);
  }

  validateIntegrationSelection(batchId, adoptedRunIds) {
    const batch = this.#batchRef(batchId);
    this.#assertIntegrationReady(batch);
    const ids = new Set(adoptedRunIds);
    const members = new Map(batch.runs.map((run) => [run.id, run]));
    for (const id of ids) {
      const run = members.get(id);
      if (run === undefined) throw new Error(`run "${id}" does not belong to batch "${batchId}"`);
      if (run.discarded === true || run.workspaceOutcome === "discarded") {
        throw new Error(`run "${id}" was discarded and cannot be adopted`);
      }
    }
    return clone(batch);
  }

  async prepareIntegrationCompletion(batchId, adoptedRunIds, summary, testSummary) {
    const batch = this.validateIntegrationSelection(batchId, adoptedRunIds);
    const completion = {
      batchId,
      adoptedRunIds: [...new Set(adoptedRunIds)],
      summary: requiredString(summary, "summary"),
      ...testSummary === undefined ? {} : { testSummary: String(testSummary) },
    };
    const batchRef = this.#batchRef(batchId);
    if (batchRef.integrationCompletion !== undefined) {
      if (JSON.stringify(batchRef.integrationCompletion) === JSON.stringify(completion)) {
        return { batch, completion: clone(batchRef.integrationCompletion) };
      }
      throw new Error(`integration completion for batch "${batchId}" is already in progress`);
    }
    for (const id of completion.adoptedRunIds) {
      const run = batchRef.runs.find((candidate) => candidate.id === id);
      if (run?.contextId !== undefined) {
        const context = this.#data.contexts.find((candidate) => candidate.id === run.contextId);
        if (context?.closeIntent !== undefined) {
          throw new Error(`context "${context.id}" is closing as ${context.closeIntent.outcome}`);
        }
      }
      if (run?.workspaceCleanupIntent !== undefined) {
        throw new Error(`run "${id}" workspace is closing as ${run.workspaceCleanupIntent.outcome}`);
      }
    }
    batchRef.integrationState = "integrating";
    batchRef.integrationCompletion = clone(completion);
    batchRef.updatedAt = now();
    delete batchRef.integrationDelivery;
    delete batchRef.integrationError;
    await this.#persist();
    return { batch, completion: clone(completion) };
  }

  pendingIntegrationCompletions() {
    return clone(this.#data.batches
      .filter((batch) => batch.integrationCompletion !== undefined)
      .map((batch) => batch.integrationCompletion));
  }

  async completeIntegration(batchId, adoptedRunIds, summary, testSummary) {
    const batch = this.validateIntegrationSelection(batchId, adoptedRunIds);
    const ids = new Set(adoptedRunIds);
    const adoptedContextIds = new Set(batch.runs
      .filter((run) =>
        ids.has(run.id)
        && run.adapter === "dsh"
        && run.mode === "execution"
        && run.contextId !== undefined)
      .map((run) => run.contextId));
    const batchRef = this.#batchRef(batchId);
    const affected = new Set([batchRef]);
    for (const candidate of this.#data.batches) {
      for (const run of candidate.runs) {
        if (ids.has(run.id)
          || (run.contextId !== undefined && adoptedContextIds.has(run.contextId))) {
          run.adopted = true;
          affected.add(candidate);
        }
      }
    }
    const integrationSummary = requiredString(summary, "summary");
    for (const candidate of affected) {
      candidate.integrationState = candidate.runs.every((run) => run.adopted === true)
        ? "adopted"
        : "partiallyAdopted";
      candidate.integrationSummary = integrationSummary;
      if (testSummary !== undefined) candidate.integrationTestSummary = String(testSummary);
      candidate.updatedAt = now();
      delete candidate.integrationDelivery;
      delete candidate.integrationError;
      if (candidate.id === batchId) delete candidate.integrationCompletion;
    }
    await this.#persist();
    return clone(batchRef);
  }

  async markIntegrationFailed(batchId, error) {
    const batch = this.#batchRef(batchId);
    batch.integrationState = "failed";
    batch.integrationError = error instanceof Error ? error.message : String(error);
    batch.updatedAt = now();
    delete batch.integrationDelivery;
    await this.#persist();
    return clone(batch);
  }

  async markSummaryDelivered(batchId) {
    const batch = this.#batchRef(batchId);
    batch.summaryDeliveredRevision = batch.summaryRevision;
    batch.summaryDeliveredAt = now();
    delete batch.summaryDelivery;
    batch.coordination = {
      ...(batch.coordination ?? {}),
      status: "delivered",
      deliveredAt: batch.summaryDeliveredAt,
    };
    await this.#persist();
  }

  async prepareSummaryDelivery(batchId, message) {
    const batch = this.#batchRef(batchId);
    if ((batch.summaryRevision ?? 0) <= (batch.summaryDeliveredRevision ?? 0)) return undefined;
    if (batch.summaryDelivery?.revision === batch.summaryRevision) return clone(batch.summaryDelivery.message);
    batch.summaryDelivery = {
      revision: batch.summaryRevision,
      message: clone(message),
      preparedAt: now(),
    };
    await this.#persist();
    return clone(batch.summaryDelivery.message);
  }

  async prepareIntegrationDelivery(batchId, message) {
    const batch = this.#batchRef(batchId);
    if (batch.recoveryBlocked === true) return undefined;
    if (batch.integrationState !== "requested" && batch.integrationState !== "failed") return undefined;
    if (batch.integrationCompletion !== undefined) return undefined;
    if (!this.#integrationRequestReady(batch)) return undefined;
    const revision = batch.integrationRevision ?? 0;
    if ((batch.integrationDeliveredRevision ?? 0) >= revision) return undefined;
    if (batch.integrationDelivery?.revision === revision) return clone(batch.integrationDelivery);
    batch.integrationDelivery = {
      revision,
      message: clone(message),
      preparedAt: now(),
    };
    await this.#persist();
    return clone(batch.integrationDelivery);
  }

  async markIntegrationRequested(batchId, revision) {
    const batch = this.#batchRef(batchId);
    if (revision !== undefined && revision !== batch.integrationRevision) return clone(batch);
    batch.integrationRequestedAt = now();
    batch.integrationDeliveredRevision = batch.integrationRevision;
    batch.integrationState = "integrating";
    delete batch.integrationDelivery;
    await this.#persist();
    return clone(batch);
  }

  async patchRunWorkspace(runId, workspace) {
    return this.updateRun(runId, {
      worktreePath: workspace.path,
      ...workspace.worktreeRoot === undefined ? {} : { worktreeRoot: workspace.worktreeRoot },
      ...workspace.branch === undefined ? {} : { branch: workspace.branch },
      ...workspace.baselineCommit === undefined ? {} : { baselineCommit: workspace.baselineCommit },
      ...workspace.gitRoot === undefined ? {} : { gitRoot: workspace.gitRoot },
    });
  }

  async markRunWorkspaceCleaned(runId, outcome) {
    const run = this.assertRunWorkspaceClosable(runId);
    if (NONTERMINAL.has(run.status)) throw new Error("cannot clean an active run workspace");
    const identity = run.worktreeRoot ?? run.worktreePath;
    const cleanedAt = now();
    const affected = new Set();
    for (const batch of this.#data.batches) {
      for (const candidate of batch.runs) {
        const candidateIdentity = candidate.worktreeRoot ?? candidate.worktreePath;
        if (candidate.id !== runId && (identity === undefined || candidateIdentity !== identity)) continue;
        candidate.workspaceCleaned = true;
        candidate.workspaceOutcome = outcome;
        candidate.retryable = false;
        if (outcome === "discarded") {
          candidate.discarded = true;
          affected.add(batch);
        }
        candidate.workspaceCleanedAt = cleanedAt;
        delete candidate.workspaceCleanupIntent;
      }
    }
    for (const batch of affected) {
      batch.integrationState = batch.runs.every((candidate) => candidate.discarded === true)
        ? "discarded"
        : "partiallyDiscarded";
      batch.updatedAt = now();
      delete batch.integrationDelivery;
    }
    await this.#persist();
    return this.run(runId);
  }

  async prepareRunWorkspaceCleanup(runId, outcome) {
    const run = this.assertRunWorkspaceClosable(runId);
    if (NONTERMINAL.has(run.status)) throw new Error("cannot clean an active run workspace");
    const identity = run.worktreeRoot ?? run.worktreePath;
    if (outcome !== "adopted" && this.#workspaceIntegrationLocked(identity, runId)) {
      throw new Error("an integration completion is in progress for this workspace");
    }
    const intent = { outcome, preparedAt: now() };
    for (const batch of this.#data.batches) {
      for (const candidate of batch.runs) {
        const candidateIdentity = candidate.worktreeRoot ?? candidate.worktreePath;
        if (candidate.id !== runId && (identity === undefined || candidateIdentity !== identity)) continue;
        if (candidate.workspaceCleanupIntent !== undefined
          && candidate.workspaceCleanupIntent.outcome !== outcome) {
          throw new Error(`workspace cleanup is already prepared as ${candidate.workspaceCleanupIntent.outcome}`);
        }
        candidate.workspaceCleanupIntent = clone(intent);
      }
    }
    await this.#persist();
    return this.run(runId);
  }

  async recordRunInspection(runId, inspection) {
    const { run } = this.#locateRun(runId);
    const identity = run.worktreeRoot ?? run.worktreePath;
    for (const candidate of this.#data.batches.flatMap((batch) => batch.runs)) {
      const candidateIdentity = candidate.worktreeRoot ?? candidate.worktreePath;
      if (candidate.id !== runId && (identity === undefined || candidateIdentity !== identity)) continue;
      if (inspection.diffSummary !== undefined) candidate.diffSummary = inspection.diffSummary;
      if (inspection.files !== undefined) candidate.workspaceFiles = clone(inspection.files);
      if (inspection.testSummary !== undefined) candidate.testSummary = inspection.testSummary;
    }
    await this.#persist();
    return this.run(runId);
  }

  async recordContextInspection(contextId, inspection) {
    for (const batch of this.#data.batches) {
      for (const run of batch.runs) {
        if (run.contextId !== contextId) continue;
        if (inspection.diffSummary !== undefined) run.diffSummary = inspection.diffSummary;
        if (inspection.files !== undefined) run.workspaceFiles = clone(inspection.files);
        if (inspection.testSummary !== undefined) run.testSummary = inspection.testSummary;
      }
    }
    await this.#persist();
  }

  assertRunWorkspaceClosable(runId) {
    const { run } = this.#locateRun(runId);
    const workspaceIdentity = run.worktreeRoot ?? run.worktreePath;
    if (workspaceIdentity === undefined) return run;
    const active = this.#data.batches.flatMap((batch) => batch.runs).some((candidate) => {
      const candidateIdentity = candidate.worktreeRoot ?? candidate.worktreePath;
      return candidate.id !== runId
        && candidateIdentity === workspaceIdentity
        && NONTERMINAL.has(candidate.status);
    });
    if (active) throw new Error("workspace still has active runs");
    return run;
  }

  async upsertContext(context) {
    const index = this.#data.contexts.findIndex((candidate) => candidate.id === context.id);
    if (index < 0) this.#data.contexts.push(clone(context));
    else this.#data.contexts[index] = { ...this.#data.contexts[index], ...clone(context) };
    await this.#persist();
    return this.context(context.id);
  }

  async bindRunToContext(runId, context, dshMessageId) {
    const snapshot = clone(context);
    const closing = this.#data.contexts.find((candidate) =>
      (candidate.id === snapshot.id || candidate.key === snapshot.key)
      && candidate.closedAt === undefined
      && candidate.closeIntent !== undefined);
    if (closing !== undefined || snapshot.closedAt !== undefined || snapshot.closeIntent !== undefined) {
      return undefined;
    }
    const index = this.#data.contexts.findIndex((candidate) => candidate.id === snapshot.id);
    if (index < 0) this.#data.contexts.push(snapshot);
    else this.#data.contexts[index] = { ...this.#data.contexts[index], ...snapshot };
    return this.updateRun(runId, {
      status: "preparing",
      contextId: snapshot.id,
      ...dshMessageId === undefined ? {} : { dshMessageId },
      runtimeProfileSnapshot: snapshot.profileSnapshot,
      adapterSnapshot: snapshot.bindingSnapshot,
      ...snapshot.childSessionId === undefined ? {} : { childSessionId: snapshot.childSessionId },
      ...snapshot.workspacePath === undefined ? {} : {
        worktreePath: snapshot.workspacePath,
        worktreeRoot: snapshot.worktreeRoot,
        branch: snapshot.branch,
        gitRoot: snapshot.gitRoot,
        baselineCommit: snapshot.baselineCommit,
      },
    });
  }

  async closeContext(contextId, outcome) {
    const context = this.assertContextClosable(contextId);
    if (context.closedAt !== undefined) return clone(context);
    context.closedAt = now();
    context.outcome = outcome;
    delete context.closeIntent;
    const affected = new Set();
    for (const batch of this.#data.batches) {
      for (const run of batch.runs) {
        if (run.contextId !== contextId) continue;
        run.workspaceCleaned = context.workspacePath !== undefined;
        run.workspaceOutcome = outcome;
        run.retryable = false;
        if (outcome === "adopted") run.adopted = true;
        if (outcome === "discarded") run.discarded = true;
        run.workspaceCleanedAt = context.closedAt;
        affected.add(batch);
      }
    }
    for (const batch of affected) {
      if (outcome === "adopted") {
        batch.integrationState = batch.runs.every((run) => run.adopted === true)
          ? "adopted"
          : "partiallyAdopted";
      } else if (outcome === "discarded") {
        batch.integrationState = batch.runs.every((run) => run.discarded === true)
          ? "discarded"
          : "partiallyDiscarded";
      }
      batch.updatedAt = now();
      delete batch.integrationDelivery;
    }
    await this.#persist();
    return clone(context);
  }

  async prepareContextClose(contextId, outcome) {
    const context = this.assertContextClosable(contextId);
    if (context.closedAt !== undefined) return clone(context);
    if (outcome !== "adopted" && this.#contextIntegrationLocked(contextId)) {
      throw new Error(`an integration completion is in progress for context "${contextId}"`);
    }
    if (context.closeIntent !== undefined && context.closeIntent.outcome !== outcome) {
      throw new Error(`context close is already prepared as ${context.closeIntent.outcome}`);
    }
    context.closeIntent ??= { outcome, preparedAt: now() };
    await this.#persist();
    return clone(context);
  }

  pendingContextCloses() {
    const completionContextIds = new Set();
    for (const batch of this.#data.batches) {
      const selected = new Set(batch.integrationCompletion?.adoptedRunIds ?? []);
      for (const run of batch.runs) {
        if (selected.has(run.id) && run.contextId !== undefined) {
          completionContextIds.add(run.contextId);
        }
      }
    }
    return clone(this.#data.contexts
      .filter((context) =>
        context.closedAt === undefined
        && context.closeIntent !== undefined
        && !completionContextIds.has(context.id))
      .map((context) => ({
        contextId: context.id,
        outcome: context.closeIntent.outcome,
        rootSessionId: context.rootSessionId,
      })));
  }

  assertContextClosable(contextId) {
    const context = this.#data.contexts.find((candidate) => candidate.id === contextId);
    if (context === undefined) throw new Error(`context "${contextId}" not found`);
    if (context.closedAt !== undefined) return context;
    const active = this.#data.batches.flatMap((batch) => batch.runs)
      .some((run) => run.contextId === contextId && NONTERMINAL.has(run.status));
    if (active) throw new Error("context still has active runs");
    return context;
  }

  isManagedChild(childId) {
    return this.#data.contexts.some((context) => context.childSessionId === childId);
  }

  queuedRuns() {
    return clone(this.#data.batches.flatMap((batch) => batch.runs).filter((run) => run.status === "queued"));
  }

  recoveryRoots() {
    const roots = new Map();
    const closingContexts = new Set(this.#data.contexts
      .filter((context) => context.closedAt === undefined && context.closeIntent !== undefined)
      .map((context) => context.id));
    for (const batch of this.#data.batches) {
      if (typeof batch.rootCwd !== "string" || batch.rootCwd.length === 0) continue;
      const pendingDsh = batch.runs.some((run) => run.adapter === "dsh" && run.status === "queued");
      const pendingSummary = (batch.summaryRevision ?? 0) > (batch.summaryDeliveredRevision ?? 0);
      const pendingIntegration = batch.integrationState === "requested"
        || batch.integrationDelivery !== undefined
        || batch.integrationCompletion !== undefined;
      const pendingContextClose = batch.runs.some((run) =>
        run.contextId !== undefined && closingContexts.has(run.contextId));
      if (!pendingDsh && !pendingSummary && !pendingIntegration && !pendingContextClose) continue;
      roots.set(batch.rootSessionId, {
        sessionId: batch.rootSessionId,
        cwd: batch.rootCwd,
      });
    }
    return clone([...roots.values()]);
  }

  dshIntegrationBlocked(batchId) {
    const index = this.#data.batches.findIndex((batch) => batch.id === batchId);
    if (index < 0) throw new Error(`batch "${batchId}" not found`);
    const current = this.#data.batches[index];
    const lane = contextIdentity(current.initiatorSessionId, current.profileId, current.mode);
    const closing = this.#data.contexts.some((context) =>
      context.key === lane
      && context.closedAt === undefined
      && context.closeIntent !== undefined);
    if (closing) return true;
    if (current.mode !== "execution") return false;
    return this.#data.batches.slice(0, index).some((prior) =>
      prior.initiatorSessionId === current.initiatorSessionId
      && prior.profileId === current.profileId
      && prior.mode === current.mode
      && prior.runs.some((run) => run.adapter === "dsh")
      && (["requested", "integrating"].includes(prior.integrationState)
        || prior.integrationCompletion !== undefined));
  }

  async #recover() {
    let changed = false;
    for (const context of this.#data.contexts) {
      if (context.childSessionId !== undefined && context.childEstablished === undefined) {
        context.childEstablished = true;
        changed = true;
      }
    }
    for (const batch of this.#data.batches) {
      let batchChanged = false;
      const legacyCapabilities = !hasCompleteInitiatingCapabilitySnapshot(batch, true);
      if (legacyCapabilities) {
        batch.recoveryBlocked = true;
        for (const run of batch.runs) {
          run.retryable = false;
          run.recoveryBlocked = true;
          if (!NONTERMINAL.has(run.status)) continue;
          run.status = "interrupted";
          run.error = "This Agent Run predates durable initiating capability snapshots and cannot be resumed safely. Dispatch a new Batch.";
          run.finishedAt = now();
          delete run.resumeAfterRestart;
          batchChanged = true;
        }
        if (batch.integrationCompletion === undefined
          && ["requested", "failed", "integrating"].includes(batch.integrationState)) {
          batch.integrationPolicy = "manual";
          batch.integrationState = "manualPending";
          delete batch.integrationDelivery;
          delete batch.integrationError;
          batchChanged = true;
        }
        changed = true;
      }
      if (batch.integrationState === "integrating" && batch.integrationCompletion === undefined) {
        batch.integrationState = "requested";
        batch.integrationRevision = (batch.integrationRevision ?? 0) + 1;
        delete batch.integrationDelivery;
        changed = true;
        batchChanged = true;
      }
      for (const run of batch.runs) {
        if (legacyCapabilities) continue;
        if (!NONTERMINAL.has(run.status)) continue;
        const previousStatus = run.status;
        if (run.adapter === "dsh" && previousStatus === "stopping") {
          run.status = "cancelled";
          run.error = "Host restarted while stop was requested; the run was not resumed.";
          run.finishedAt = now();
          run.retryable = true;
          delete run.resumeAfterRestart;
        } else if (run.adapter === "dsh") {
          run.status = "queued";
          run.retryable = false;
          if (previousStatus !== "queued") run.resumeAfterRestart = true;
        } else {
          run.status = "interrupted";
          run.error = "Host restarted; external worker was not restarted automatically.";
          run.finishedAt = now();
          run.retryable = true;
        }
        changed = true;
        batchChanged = true;
      }
      if (batchChanged) {
        batch.status = batchStatus(batch.runs);
        batch.updatedAt = now();
        if (!batch.runs.some((run) => NONTERMINAL.has(run.status)) && batch.summaryRevision === 0) {
          batch.summary = renderSummary(batch);
          batch.summaryRevision = 1;
          batch.coordination = {
            ...(batch.coordination ?? {}),
            status: "ready",
            readyAt: now(),
          };
        }
      }
    }
    if (changed) await this.#persist();
  }

  #locateRun(runId) {
    for (const batch of this.#data.batches) {
      const run = batch.runs.find((candidate) => candidate.id === runId);
      if (run !== undefined) return { batch, run };
    }
    throw new Error(`run "${runId}" not found`);
  }

  #batchRef(batchId) {
    const batch = this.#data.batches.find((candidate) => candidate.id === batchId);
    if (batch === undefined) throw new Error(`batch "${batchId}" not found`);
    return batch;
  }

  #integrationContextIds(batch) {
    if (batch.mode !== "execution") return new Set();
    return new Set(batch.runs
      .filter((run) => run.adapter === "dsh" && run.contextId !== undefined)
      .map((run) => run.contextId));
  }

  #integrationReady(batch) {
    if (batch.runs.some((run) => NONTERMINAL.has(run.status))) return false;
    const contextIds = this.#integrationContextIds(batch);
    if (contextIds.size === 0) return true;
    return !this.#data.batches.flatMap((candidate) => candidate.runs)
      .some((run) =>
        run.contextId !== undefined
        && contextIds.has(run.contextId)
        && NONTERMINAL.has(run.status));
  }

  #integrationRequestReady(batch) {
    return this.#integrationReady(batch) && batch.runs.some(integrationEligible);
  }

  #assertIntegrationReady(batch) {
    if (batch.recoveryBlocked === true) {
      throw new Error("cannot integrate a Batch whose initiating capability snapshot is unavailable; dispatch a new Batch");
    }
    if (batch.runs.some((run) => NONTERMINAL.has(run.status))) throw new Error("batch is still running");
    const contextIds = this.#integrationContextIds(batch);
    if (contextIds.size === 0) return;
    const sharedActive = this.#data.batches.flatMap((candidate) => candidate.runs)
      .some((run) =>
        run.contextId !== undefined
        && contextIds.has(run.contextId)
        && NONTERMINAL.has(run.status));
    if (sharedActive) throw new Error("shared DSH context still has active runs");
  }

  #assertIntegrationRequestable(batch) {
    this.#assertIntegrationReady(batch);
    if (!batch.runs.some(integrationEligible)) {
      throw new Error("batch has no eligible Agent Runs to integrate");
    }
  }

  #contextIntegrationLocked(contextId) {
    return this.#data.batches.some((batch) =>
      (batch.integrationCompletion !== undefined
        || ["requested", "integrating", "failed"].includes(batch.integrationState))
      && batch.runs.some((run) => run.contextId === contextId));
  }

  #workspaceIntegrationLocked(identity, runId) {
    if (identity === undefined) return false;
    return this.#data.batches.some((batch) =>
      (batch.integrationCompletion !== undefined
        || ["requested", "integrating", "failed"].includes(batch.integrationState))
      && batch.runs.some((run) => {
        const candidateIdentity = run.worktreeRoot ?? run.worktreePath;
        return run.id === runId || candidateIdentity === identity;
      }));
  }

  #persist() {
    const snapshot = JSON.stringify(this.#data, null, 2) + "\n";
    const temp = `${this.#file}.tmp`;
    this.#write = this.#write.then(async () => {
      await writeFile(temp, snapshot);
      await rename(temp, this.#file);
    });
    return this.#write;
  }
}

export { NONTERMINAL, TERMINAL, contextIdentity };
