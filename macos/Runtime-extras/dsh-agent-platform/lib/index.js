import path from "node:path";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";
import { Remote, TypertRemoteService } from "@deepseek-ai/dsh-typert-protocol";
import { createUserMessage, boundContextSummary } from "@deepseek-ai/dsh-llm";
import { defineTool } from "@deepseek-ai/dsh-tools";
import { z } from "zod";
import { AgentPlatformState, contextIdentity, NONTERMINAL, renderIntegrationPrompt, TERMINAL } from "./core.js";
import { deliverDurableAgentMessage, KeyedSingleFlight } from "./delivery.js";
import {
  closeManagedContext,
  disposeManagedChild,
  recoverPendingContextCloses,
  runDurableIntegrationCompletion,
  shouldCleanupAdoptedRun,
  shouldCloseContextOnAdoption,
  shouldInspectContextBeforeClose,
  shouldInspectWorkspaceBeforeCleanup,
} from "./lifecycle.js";
import { recoverRootSessions } from "./recovery.js";
import { LaneScheduler } from "./scheduler.js";
import { WorkspaceManager } from "./workspace.js";
import {
  adapterCommand,
  confineExternalCommand,
  dshAgentOptions,
  dshChildCwd,
  dshRecoveryDecision,
  dshRunSettlement,
  dshRunPrompt,
  dshToolRestriction,
  externalSandboxPolicy,
  hasCompleteInitiatingCapabilitySnapshot,
  inheritedToolAllowlist,
  initiatingCapabilitySnapshot,
  ownsManagedContext,
  reusableDshContext,
  runCancellationRequested,
  runtimeStatusRows,
  startOrResumeReservedContinuable,
} from "./runtime.js";
import { RunLogStore } from "./logs.js";

export const name = "agent-platform";
export const inject = [
  "agents", "apiProxy", "sandbox", "sandboxPolicy", "sessions",
  "sessionPersistence", "subagents", "tools", "typert", "sessionProjections",
];

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const WORKER_PATH = path.join(__dirname, "worker.js");
const PLATFORM_CHILD_LABEL_PREFIX = "__dsh_agent_platform__:";
const ANALYSIS_SAFE_TOOLS = [
  "read", "read_image", "glob", "grep", "web_search", "web_fetch",
  "skill", "ask_user_question", "get_goal",
];

function remoteInitializers(klass, methods) {
  const initializers = [];
  for (const [method, exportName] of Object.entries(methods)) {
    Remote(exportName)(klass.prototype[method], {
      kind: "method",
      name: method,
      static: false,
      private: false,
      access: {
        has: (object) => method in object,
        get: (object) => object[method],
      },
      addInitializer(initializer) {
        initializers.push(initializer);
      },
    });
  }
  return initializers;
}

function initializeRemotes(instance, initializers) {
  for (const initializer of initializers) initializer.call(instance);
}

function rootAgent(ctx, agent) {
  let current = agent;
  const seen = new Set([current.id]);
  while (current.session.header.parentSession !== undefined) {
    const parent = ctx.agents.get(current.session.header.parentSession);
    if (parent === undefined || seen.has(parent.id)) break;
    current = parent;
    seen.add(current.id);
  }
  return current;
}

function visibleToolNames(ctx, agent) {
  const direct = ctx.tools.schemas(agent);
  const sdk = typeof ctx.tools.sdkSchemas === "function"
    ? ctx.tools.sdkSchemas(agent)
    : [];
  return [...new Set([...direct, ...sdk]
    .map((schema) => schema.name)
    .filter((name) => typeof name === "string" && name !== "run_code"))];
}

async function inheritableToolNames(ctx, initiator, agentPreset) {
  const sourceVisible = visibleToolNames(ctx, initiator);
  const presets = initiator.ctx.get("agentPresets");
  const compositionScope = agentPreset === undefined || presets === undefined
    ? undefined
    : await presets.standingKeyFor(agentPreset);
  return inheritedToolAllowlist(
    sourceVisible,
    visibleToolNames(ctx, compositionScope));
}

function dshToolFilter(ctx, parent, mode, binding, sourceToolAllowlist) {
  const candidates = new Set([
    ...ANALYSIS_SAFE_TOOLS,
    ...sourceToolAllowlist ?? [],
    ...(binding.toolAllowlist ?? []),
    ...(binding.toolDenylist ?? []),
  ]);
  const available = sourceToolAllowlist
    ?? [...candidates].filter((name) => ctx.tools.get(name, parent) !== undefined);
  return dshToolRestriction(
    mode,
    binding,
    available,
    sourceToolAllowlist);
}

function extractExternalOutput(raw) {
  let best = "";
  for (const line of raw.split(/\r?\n/u)) {
    if (!line.trim()) continue;
    try {
      const value = JSON.parse(line);
      const candidates = [
        value.result, value.text, value.message,
        value.item?.text, value.item?.content,
        value.data?.text, value.data?.message,
      ];
      for (const candidate of candidates) {
        if (typeof candidate === "string" && candidate.trim()) best = candidate.trim();
      }
    } catch {
      best = line.trim();
    }
  }
  return best || raw.trim().slice(-32_000);
}

class AgentPlatformCoordinator {
  ctx;
  state;
  scheduler = new LaneScheduler(3);
  workspaces;
  logs;
  activeExternal = new Map();
  pendingDshByChild = new Map();
  acceptedDshMessages = new Map();
  currentTurnBySession = new Map();
  pendingCreationLabels = new Map();
  stopRequested = new Set();
  scheduledRuns = new Set();
  summaryDeliveries = new KeyedSingleFlight();
  integrationDeliveries = new KeyedSingleFlight();
  integrationCompletions = new KeyedSingleFlight();
  disposed = false;

  static async create(ctx, config) {
    const root = typeof config?.root === "string" && config.root.length > 0
      ? config.root
      : path.join(process.env.DSH_HOME ?? process.cwd(), "agent-platform");
    const coordinator = new AgentPlatformCoordinator(ctx, await AgentPlatformState.open(root));
    coordinator.workspaces = new WorkspaceManager(path.join(root, "workspaces"));
    coordinator.logs = new RunLogStore(path.join(root, "logs"));
    await coordinator.workspaces.reconcileOrphans(coordinator.state.retainedWorkspaceRoots());
    coordinator.installListeners();
    coordinator.installProjection();
    coordinator.installTools();
    await coordinator.recoverRoots();
    await coordinator.resumePendingIntegrationCompletions();
    await coordinator.resumePendingContextCloses();
    await coordinator.publishAll();
    coordinator.scheduleQueued();
    return coordinator;
  }

  constructor(ctx, state) {
    this.ctx = ctx;
    this.state = state;
  }

  installProjection() {
    const schema = z.object({ items: z.array(z.unknown()) });
    this.ctx.sessionProjections.register({
      key: "agent-platform/batches",
      schema,
      stateSchema: schema,
      stateVersion: 1,
      init: () => ({ items: [] }),
      apply: (state, event) => event.type === "agent-platform/batches" ? event.data : state,
      view: (state) => state,
      wire: { viewSchema: schema, view: (state) => state },
    });
  }

  installListeners() {
    this.ctx.on("agent/created", ({ agent }) => {
      const descriptor = agent.session.events.find((event) => event.type === "subagent/descriptor")?.data;
      const pending = descriptor?.label && this.pendingCreationLabels.get(descriptor.label);
      const existing = this.state.contexts().find((context) => context.childSessionId === agent.id && context.closedAt === undefined);
      if ((pending?.mode ?? existing?.mode) === "analysis") {
        try {
          agent.ctx.tools.presentAs("native");
        } catch (error) {
          this.ctx.logger.warn(`agent-platform: failed to force native analysis tools for "${agent.id}": ${String(error)}`);
        }
      }
      for (const batch of this.state.allBatches()) {
        if (batch.rootSessionId === agent.id || batch.initiatorSessionId === agent.id) this.scheduleBatch(batch);
      }
      this.deliverReadyIntegrations(agent.id).catch((error) =>
        this.ctx.logger.warn(`agent-platform integration delivery failed: ${String(error)}`));
      if (this.state.allBatches().some((batch) => batch.rootSessionId === agent.id)) {
        this.publishRoot(agent.id).catch((error) => this.ctx.logger.warn(`agent-platform projection publish failed: ${String(error)}`));
      }
      this.deliverSettlements().catch((error) => this.ctx.logger.warn(`agent-platform settlement delivery failed: ${String(error)}`));
    });

    this.ctx.on("agent/inbox/claimed", ({ message, turn }) => {
      const accepted = this.acceptedDshMessages.get(message.id);
      if (accepted === undefined) return;
      accepted.turn = turn;
      const pending = this.pendingDshByChild.get(accepted.childId);
      if (pending !== undefined) pending.turn = turn;
      this.updateRun(accepted.runId, { status: "running", claimedTurn: turn }).catch((error) => {
        this.ctx.logger.warn(`agent-platform: failed to mark DSH run running: ${String(error)}`);
      });
    });

    this.ctx.on("session/event", (session, event) => {
      if (event.type === "turn/start") {
        this.currentTurnBySession.set(session.id, event.data.turn);
        return;
      }
      if (event.type === "user/message") {
        const accepted = this.acceptedDshMessages.get(event.data.id);
        if (accepted !== undefined) {
          accepted.turn = this.currentTurnBySession.get(session.id);
          const pending = this.pendingDshByChild.get(accepted.childId);
          if (pending !== undefined) pending.turn = accepted.turn;
        }
        this.reconcileRootDeliveries(session.id);
        return;
      }
      if (event.type !== "turn/end") return;
      const pending = this.pendingDshByChild.get(session.id);
      if (pending === undefined) return;
      const settlement = dshRunSettlement(session.events, pending.messageId);
      if (settlement === undefined) return;
      this.settleDsh(settlement, pending).catch((error) => {
        pending.reject(error);
      });
    });

    this.ctx.on("agent/pre-step", async ({ messages }, next) => {
      const managed = messages.filter((message) =>
        message.source?.kind === "subagent-settled"
        && this.state.isManagedChild(message.source.senderSessionId));
      const decision = await next();
      if (decision.kind === "reject") return decision;
      const filtered = decision.messages.filter((message) => {
        return message.source?.kind !== "subagent-settled"
          || !this.state.isManagedChild(message.source.senderSessionId);
      });
      if (managed.length === 0) return decision;
      if (managed.length === messages.length) return { kind: "reject" };
      return { kind: "enter", messages: filtered };
    });
  }

  reconcileRootDeliveries(sessionId) {
    this.deliverSettlements().catch((error) => {
      this.ctx.logger.warn(`agent-platform settlement reconciliation failed: ${String(error)}`);
    });
    this.deliverReadyIntegrations(sessionId).catch((error) =>
      this.ctx.logger.warn(`agent-platform integration reconciliation failed: ${String(error)}`));
  }

  installTools() {
    this.ctx.tools.register(defineTool({
      name: "list_agent_profiles",
      description: "List Agent Profiles that the user explicitly allowed models to dispatch.",
      parameters: {},
      output: {
        schema: {
          type: "object",
          additionalProperties: false,
          properties: {
            profiles: {
              type: "array",
              required: true,
              items: {
                type: "object",
                additionalProperties: false,
                properties: {
                  id: { type: "string", required: true },
                  name: { type: "string", required: true },
                  mention: { type: "string", required: true },
                  defaultMode: { type: "string", required: true },
                  integrationPolicy: { type: "string", required: true },
                  runtimes: { type: "array", required: true, items: { type: "string" } },
                },
              },
            },
          },
        },
        render: (_args, value) => value.profiles.length === 0
          ? [{ type: "text", text: "No Agent Profiles allow model dispatch." }]
          : value.profiles.map((profile) => ({
            type: "text",
            text: `@${profile.mention} · ${profile.defaultMode} · ${profile.runtimes.join(", ")}`,
          })),
      },
      execute: async () => ({
        profiles: this.state.profiles()
          .filter((profile) => profile.allowModelDispatch)
          .map((profile) => ({
            id: profile.id,
            name: profile.name,
            mention: profile.mention,
            defaultMode: profile.defaultMode,
            integrationPolicy: profile.integrationPolicy,
            runtimes: profile.adapters.filter((binding) => binding.enabled).map((binding) => binding.runtime),
          })),
      }),
    }));

    this.ctx.tools.register(defineTool({
      name: "delegate_agent_profile",
      description: "Delegate one task to an Agent Profile that the user explicitly enabled for model dispatch. The Profile's saved default mode and integration policy are used.",
      parameters: {
        profile: { type: "string", required: true, description: "Profile name or @mention." },
        task: { type: "string", required: true, description: "Complete task to delegate." },
      },
      output: {
        schema: {
          type: "object",
          additionalProperties: false,
          properties: {
            batchId: { type: "string", required: true },
            members: { type: "number", required: true },
          },
        },
        render: (_args, value) => [{ type: "text", text: `Started Agent Batch ${value.batchId} with ${value.members} member(s).` }],
      },
      execute: async (args, exec) => {
        if (!exec.agent) throw new Error("delegate_agent_profile requires a calling Agent");
        const query = args.profile.replace(/^@/u, "").toLowerCase();
        const profile = this.state.profiles().find((candidate) =>
          candidate.allowModelDispatch
          && (candidate.id === args.profile || candidate.mention.toLowerCase() === query || candidate.name.toLowerCase() === query));
        if (profile === undefined) throw new Error("Profile is unavailable or does not allow model dispatch");
        const root = rootAgent(this.ctx, exec.agent);
        const batch = await this.startBatch(
          profile.id, root.id, exec.agent.id, args.task,
          profile.defaultMode, profile.integrationPolicy, "model");
        return { batchId: batch.id, members: batch.runs.length };
      },
    }));

    this.ctx.tools.register(defineTool({
      name: "inspect_agent_run",
      description: "Inspect one Agent Run's immutable result and isolated workspace before deciding what to integrate or discard.",
      parameters: {
        runId: { type: "string", required: true },
      },
      output: {
        schema: {
          type: "object",
          additionalProperties: false,
          properties: {
            runId: { type: "string", required: true },
            status: { type: "string", required: true },
            adapter: { type: "string", required: true },
            output: { type: "string" },
            error: { type: "string" },
            worktreePath: { type: "string" },
            branch: { type: "string" },
            diffSummary: { type: "string" },
            testSummary: { type: "string" },
            files: { type: "array", required: true, items: { type: "string" } },
          },
        },
        render: (_args, value) => [{
          type: "text",
          text: [
            `${value.adapter} ${value.runId}: ${value.status}`,
            value.worktreePath ? `worktree=${value.worktreePath}` : "",
            value.diffSummary ? `diff=${value.diffSummary}` : "",
            value.testSummary ? `tests=${value.testSummary}` : "",
            value.output ? `result=${value.output}` : value.error ? `error=${value.error}` : "",
          ].filter(Boolean).join("\n"),
        }],
      },
      execute: async (args, exec) => {
        const batch = this.state.batchForRun(args.runId);
        this.authorizeBatchAgent(batch.id, exec.agent);
        const run = this.state.run(args.runId);
        const inspection = await this.inspectWorkspace(args.runId);
        return {
          runId: run.id,
          status: run.status,
          adapter: run.adapter,
          ...run.output === undefined ? {} : { output: run.output },
          ...run.error === undefined ? {} : { error: run.error },
          ...inspection.worktreePath === undefined ? {} : { worktreePath: inspection.worktreePath },
          ...inspection.branch === undefined ? {} : { branch: inspection.branch },
          ...inspection.diffSummary === undefined ? {} : { diffSummary: inspection.diffSummary },
          ...inspection.testSummary === undefined ? {} : { testSummary: inspection.testSummary },
          files: inspection.files ?? [],
        };
      },
    }));

    this.ctx.tools.register(defineTool({
      name: "discard_agent_context",
      description: "Discard one completed DSH Agent execution context and clean its isolated worktree. This is irreversible and never integrates its changes.",
      parameters: {
        contextId: { type: "string", required: true },
      },
      output: {
        schema: {
          type: "object",
          additionalProperties: false,
          properties: { contextId: { type: "string", required: true }, discarded: { type: "boolean", required: true } },
        },
        render: (_args, value) => [{ type: "text", text: `Discarded Agent context ${value.contextId}.` }],
      },
      execute: async (args, exec) => {
        const context = this.state.context(args.contextId);
        if (context === undefined) throw new Error(`context "${args.contextId}" not found`);
        if (!ownsManagedContext(context, exec.agent?.id)) {
          throw new Error("the calling Agent does not own this context");
        }
        await this.closeContext(args.contextId, "discarded");
        return { contextId: args.contextId, discarded: true };
      },
    }));

    this.ctx.tools.register(defineTool({
      name: "discard_agent_run",
      description: "Discard one completed Agent Run. External workspaces are cleaned directly; DSH runs close their shared continuable context.",
      parameters: {
        runId: { type: "string", required: true },
      },
      output: {
        schema: {
          type: "object",
          additionalProperties: false,
          properties: { runId: { type: "string", required: true }, discarded: { type: "boolean", required: true } },
        },
        render: (_args, value) => [{ type: "text", text: `Discarded Agent Run ${value.runId}.` }],
      },
      execute: async (args, exec) => {
        const batch = this.state.batchForRun(args.runId);
        this.authorizeBatchAgent(batch.id, exec.agent);
        await this.discardRun(args.runId);
        return { runId: args.runId, discarded: true };
      },
    }));

    this.ctx.tools.register(defineTool({
      name: "set_agent_batch_integration",
      description: "Override whether one existing Agent Batch waits for manual integration or asks the root Agent to integrate automatically.",
      parameters: {
        batchId: { type: "string", required: true },
        integrationPolicy: { type: "string", required: true, enum: ["manual", "auto"] },
      },
      output: {
        schema: { type: "object", additionalProperties: false, properties: { batchId: { type: "string", required: true }, integrationPolicy: { type: "string", required: true } } },
        render: (_args, value) => [{ type: "text", text: `Batch ${value.batchId} integration policy is now ${value.integrationPolicy}.` }],
      },
      execute: async (args, exec) => {
        this.authorizeBatchAgent(args.batchId, exec.agent);
        const batch = await this.setIntegration(args.batchId, args.integrationPolicy);
        return { batchId: batch.id, integrationPolicy: batch.integrationPolicy };
      },
    }));

    this.ctx.tools.register(defineTool({
      name: "request_agent_batch_integration",
      description: "Ask the root DSH Agent to inspect and selectively integrate completed member worktrees. This never performs a blind git merge or cherry-pick.",
      parameters: {
        batchId: { type: "string", required: true },
        preferredRunIds: { type: "array", items: { type: "string" } },
      },
      output: {
        schema: { type: "object", additionalProperties: false, properties: { batchId: { type: "string", required: true }, requested: { type: "boolean", required: true } } },
        render: (_args, value) => [{ type: "text", text: `Requested root-Agent integration for Batch ${value.batchId}.` }],
      },
      execute: async (args, exec) => {
        this.authorizeBatchAgent(args.batchId, exec.agent);
        await this.requestIntegration(args.batchId, args.preferredRunIds);
        return { batchId: args.batchId, requested: true };
      },
    }));

    this.ctx.tools.register(defineTool({
      name: "complete_agent_integration",
      description: "Record that the root DSH Agent finished selective integration, including adopted member ids and test evidence. Adopted workspaces are cleaned after this succeeds.",
      parameters: {
        batchId: { type: "string", required: true },
        adoptedRunIds: { type: "array", required: true, items: { type: "string" } },
        summary: { type: "string", required: true },
        testSummary: { type: "string" },
      },
      output: {
        schema: { type: "object", additionalProperties: false, properties: { batchId: { type: "string", required: true }, integrationState: { type: "string", required: true } } },
        render: (_args, value) => [{ type: "text", text: `Recorded ${value.integrationState} integration for Batch ${value.batchId}.` }],
      },
      execute: async (args, exec) => {
        const batch = this.state.batch(args.batchId);
        if (!exec.agent || exec.agent.id !== batch.rootSessionId) throw new Error("only the live root Agent may complete integration");
        const settled = await this.completeIntegration(args.batchId, args.adoptedRunIds, args.summary, args.testSummary);
        return { batchId: settled.id, integrationState: settled.integrationState };
      },
    }));
  }

  authorizeBatchAgent(batchId, agent) {
    if (!agent) throw new Error("this tool requires a calling Agent");
    const batch = this.state.batch(batchId);
    if (agent.id !== batch.rootSessionId && agent.id !== batch.initiatorSessionId) {
      throw new Error("the calling Agent does not own this Batch");
    }
  }

  profiles() {
    return this.state.profiles();
  }

  async saveProfile(profile) {
    const saved = await this.state.saveProfile(profile);
    this.ctx.emit("agent-platform/profiles-updated");
    return saved;
  }

  async removeProfile(profileId) {
    await this.state.removeProfile(profileId);
    await this.publishAll();
    this.ctx.emit("agent-platform/profiles-updated");
    return { removed: true };
  }

  runtimeStatus() {
    return runtimeStatusRows();
  }

  async recoverRoots() {
    await recoverRootSessions(
      this.state.recoveryRoots(),
      (request) => this.ctx.apiProxy.sessions.create(request),
      (root, error) => {
        this.ctx.logger.warn(`agent-platform: failed to recover root "${root.sessionId}": ${String(error)}`);
      });
  }

  async startBatch(profileId, rootSessionId, initiatorSessionId, task, mode, integrationPolicy, source) {
    const root = this.ctx.agents.get(rootSessionId);
    const initiator = this.ctx.agents.get(initiatorSessionId);
    if (root === undefined) throw new Error(`root session "${rootSessionId}" is not live`);
    if (initiator === undefined) throw new Error(`initiator session "${initiatorSessionId}" is not live`);
    const rootCwd = root.session.header.cwd;
    if (rootCwd === undefined) throw new Error("Agent Batch requires a root session cwd");
    const sourceCwd = initiator.session.header.cwd ?? rootCwd;
    const sandboxMode = this.ctx.sandboxPolicy.resolve({ session: initiator.session }).mode;
    const sourceAgentPreset = initiator.ctx.get("agentPresets")?.composedPreset(initiator.ctx);
    const sourceToolAllowlist = await inheritableToolNames(
      this.ctx,
      initiator,
      sourceAgentPreset);
    const capabilities = initiatingCapabilitySnapshot(
      initiator.options,
      sourceAgentPreset,
      sourceToolAllowlist);
    const batch = await this.state.createBatch({
      profileId, rootSessionId, initiatorSessionId, rootCwd, sourceCwd, sandboxMode,
      ...capabilities,
      task, mode, integrationPolicy, source,
      initiatorLabel: initiatorSessionId === rootSessionId ? "主 Agent" : `Subagent ${initiatorSessionId}`,
    });
    await this.publishRoot(rootSessionId);
    this.scheduleBatch(batch);
    return batch;
  }

  listBatches(rootSessionId) {
    return this.state.batches(rootSessionId);
  }

  batch(batchId) {
    return this.state.batch(batchId);
  }

  async stopBatch(batchId) {
    const batch = this.state.batch(batchId);
    for (const run of batch.runs) {
      if (!NONTERMINAL.has(run.status)) continue;
      this.stopRequested.add(run.id);
      if (run.status === "queued") {
        await this.updateRun(run.id, { status: "cancelled", error: "cancelled before start" });
      } else if (run.adapter === "dsh") {
        const context = this.state.context(run.contextId);
        if (context?.childSessionId !== undefined) {
          this.ctx.subagents.interrupt(context.childSessionId, {
            kind: "user",
            parentSessionId: batch.rootSessionId,
          });
        }
        await this.state.updateRun(run.id, { status: "stopping" });
      } else {
        await this.state.updateRun(run.id, { status: "stopping" });
        this.activeExternal.get(run.id)?.stdin.end();
      }
    }
    await this.afterMutation(batch.rootSessionId);
    return {};
  }

  async retryRun(runId) {
    const batch = await this.state.retryRun(runId);
    await this.publishRoot(batch.rootSessionId);
    this.scheduleBatch(batch);
    return {};
  }

  async setIntegration(batchId, integrationPolicy) {
    const batch = await this.state.setIntegration(batchId, integrationPolicy);
    await this.afterMutation(batch.rootSessionId);
    if (integrationPolicy === "auto" && batch.integrationCompletion !== undefined) {
      await this.runIntegrationCompletion(batch);
    } else if (integrationPolicy === "auto") {
      await this.deliverReadyIntegrations(batch.rootSessionId);
    }
    if (integrationPolicy === "manual") this.scheduleQueued();
    return batch;
  }

  async requestIntegration(batchId, preferredRunIds) {
    const batch = await this.state.requestIntegration(batchId, preferredRunIds);
    await this.afterMutation(batch.rootSessionId);
    if (batch.integrationCompletion !== undefined) await this.runIntegrationCompletion(batch);
    else await this.deliverIntegration(batch.id);
    return {};
  }

  async completeIntegration(batchId, adoptedRunIds, summary, testSummary) {
    if (typeof summary !== "string" || summary.trim().length === 0) {
      throw new Error("integration summary must be non-empty");
    }
    const { batch } = await this.state.prepareIntegrationCompletion(
      batchId, adoptedRunIds, summary, testSummary);
    await this.afterMutation(batch.rootSessionId);
    await this.runIntegrationCompletion(batch);
    await this.afterMutation(batch.rootSessionId);
    this.scheduleQueued();
    return this.state.batch(batchId);
  }

  async resumePendingIntegrationCompletions() {
    for (const completion of this.state.pendingIntegrationCompletions()) {
      const batch = this.state.batch(completion.batchId);
      try {
        await this.runIntegrationCompletion(batch);
      } catch (error) {
        this.ctx.logger.warn(`agent-platform integration recovery failed for "${completion.batchId}": ${String(error)}`);
      }
    }
  }

  async resumePendingContextCloses() {
    await recoverPendingContextCloses(
      this.state.pendingContextCloses(),
      (contextId, outcome) => this.closeContext(contextId, outcome),
      (pending, error) => {
        this.ctx.logger.warn(
          `agent-platform context close recovery failed for "${pending.contextId}": ${String(error)}`);
      });
  }

  runIntegrationCompletion(batch) {
    return runDurableIntegrationCompletion({
      batchId: batch.id,
      rootSessionId: batch.rootSessionId,
      resume: (id) => this.resumeIntegrationCompletion(id),
      markFailed: (id, error) => this.state.markIntegrationFailed(id, error),
      publish: (rootSessionId) => this.afterMutation(rootSessionId),
    });
  }

  async resumeIntegrationCompletion(batchId) {
    return this.integrationCompletions.run(batchId, async () => {
      const completion = this.state.pendingIntegrationCompletions()
        .find((candidate) => candidate.batchId === batchId);
      if (completion === undefined) return this.state.batch(batchId);
      const batch = this.state.batch(batchId);
      const adopted = new Set(completion.adoptedRunIds);
      const cleanedContexts = new Set();
      for (const run of batch.runs) {
        if (!adopted.has(run.id) || !shouldCleanupAdoptedRun(run)) continue;
        if (shouldCloseContextOnAdoption(run)) {
          if (!cleanedContexts.has(run.contextId)) {
            cleanedContexts.add(run.contextId);
            await this.closeContext(run.contextId, "adopted");
          }
        } else {
          this.state.assertRunWorkspaceClosable(run.id);
          if (shouldInspectWorkspaceBeforeCleanup(run, "adopted")) {
            const inspection = await this.workspaces.inspect(run.worktreePath, run.baselineCommit);
            await this.state.recordRunInspection(run.id, inspection);
            await this.state.prepareRunWorkspaceCleanup(run.id, "adopted");
          }
          await this.workspaces.cleanup({
            path: run.worktreePath,
            worktreeRoot: run.worktreeRoot,
            branch: run.branch,
            gitRoot: run.gitRoot,
          });
          await this.state.markRunWorkspaceCleaned(run.id, "adopted");
        }
      }
      await this.state.completeIntegration(
        batchId,
        completion.adoptedRunIds,
        completion.summary,
        completion.testSummary);
      await this.afterMutation(batch.rootSessionId);
      this.scheduleQueued();
      return this.state.batch(batchId);
    });
  }

  async runLog(runId, before, limit) {
    this.state.run(runId);
    return this.logs.page(runId, before, limit);
  }

  async inspectWorkspace(runId) {
    const run = this.state.run(runId);
    if (run.worktreePath === undefined) return {};
    if (run.workspaceCleaned === true) {
      return {
        worktreePath: run.worktreePath,
        branch: run.branch,
        diffSummary: run.diffSummary,
        testSummary: run.testSummary,
        files: run.workspaceFiles ?? [],
        workspaceCleaned: true,
        workspaceOutcome: run.workspaceOutcome,
      };
    }
    return {
      ...(await this.workspaces.inspect(run.worktreePath, run.baselineCommit)),
      ...run.testSummary === undefined ? {} : { testSummary: run.testSummary },
    };
  }

  async closeContext(contextId, outcome) {
    const context = this.state.context(contextId);
    if (context === undefined) throw new Error(`context "${contextId}" not found`);
    if (context.closedAt !== undefined) return {};
    if (context.workspacePath !== undefined && shouldInspectContextBeforeClose(context, outcome)) {
      const inspection = await this.workspaces.inspect(context.workspacePath, context.baselineCommit);
      await this.state.recordContextInspection(contextId, inspection);
    }
    await this.state.prepareContextClose(contextId, outcome);
    await closeManagedContext({
      context,
      outcome,
      disposeChild: (childSessionId, parentSessionId) => disposeManagedChild({
        subagents: this.ctx.subagents,
        agents: this.ctx.agents,
        childSessionId,
        parentSessionId,
      }),
      cleanupWorkspace: (workspace) => this.workspaces.cleanup(workspace),
      closeState: (id, result) => this.state.closeContext(id, result),
      assertClosable: (id) => this.state.assertContextClosable(id),
    });
    await this.afterMutation(context.rootSessionId);
    this.scheduleQueued();
    return {};
  }

  async discardRun(runId) {
    const run = this.state.run(runId);
    if (NONTERMINAL.has(run.status)) throw new Error("cannot discard an active Agent Run");
    if (run.adapter === "dsh") {
      if (run.contextId === undefined) throw new Error("DSH run has no managed context");
      return this.closeContext(run.contextId, "discarded");
    }
    this.state.assertRunWorkspaceClosable(runId);
    if (run.worktreePath !== undefined && run.workspaceCleaned !== true) {
      if (shouldInspectWorkspaceBeforeCleanup(run, "discarded")) {
        const inspection = await this.workspaces.inspect(run.worktreePath, run.baselineCommit);
        await this.state.recordRunInspection(runId, inspection);
        await this.state.prepareRunWorkspaceCleanup(runId, "discarded");
      }
      await this.workspaces.cleanup({
        path: run.worktreePath,
        worktreeRoot: run.worktreeRoot,
        branch: run.branch,
        gitRoot: run.gitRoot,
      });
    }
    await this.state.markRunWorkspaceCleaned(runId, "discarded");
    const batch = this.state.batchForRun(runId);
    await this.afterMutation(batch.rootSessionId);
    return {};
  }

  async resetAnalysis(profileId, parentSessionId) {
    const key = contextIdentity(parentSessionId, profileId, "analysis");
    const context = this.state.contexts().find((candidate) => candidate.key === key && candidate.closedAt === undefined);
    if (context !== undefined) await this.closeContext(context.id, "reset");
    return {};
  }

  scheduleQueued() {
    for (const batch of this.state.allBatches()) this.scheduleBatch(batch);
  }

  scheduleBatch(batch) {
    for (const run of batch.runs) {
      if (run.status === "queued") this.scheduleRun(batch, run);
    }
  }

  scheduleRun(batch, run) {
    if (this.scheduledRuns.has(run.id)) return;
    if (this.ctx.agents.get(batch.rootSessionId) === undefined) return;
    if (run.adapter === "dsh" && this.state.dshIntegrationBlocked(batch.id)) return;
    this.scheduledRuns.add(run.id);
    const lane = run.adapter === "dsh"
      ? contextIdentity(batch.initiatorSessionId, batch.profileId, batch.mode)
      : `external:${run.id}`;
    this.scheduler.enqueue(lane, async () => {
      const current = this.state.run(run.id);
      if (current.status !== "queued") return;
      if (current.adapter === "dsh" && this.state.dshIntegrationBlocked(batch.id)) return;
      if (current.adapter === "dsh") await this.executeDsh(batch.id, current.id);
      else await this.executeExternal(batch.id, current.id);
    }).catch(async (error) => {
      const latest = this.state.run(run.id);
      if (!TERMINAL.has(latest.status)) await this.updateRun(run.id, { status: "failed", error: String(error) });
    }).finally(() => {
      this.scheduledRuns.delete(run.id);
    });
  }

  findBatchForRun(runId) {
    try {
      return this.state.batchForRun(runId);
    } catch {
      return undefined;
    }
  }

  async executeDsh(batchId, runId) {
    const batch = this.state.batch(batchId);
    if (!hasCompleteInitiatingCapabilitySnapshot(batch, true)) {
      throw new Error("initiating capability snapshot is unavailable; dispatch a new Batch");
    }
    const run = this.state.run(runId);
    const parent = this.ctx.agents.get(batch.rootSessionId);
    if (parent === undefined) throw new Error(`DSH root "${batch.rootSessionId}" is not live`);
    const binding = run.adapterSnapshot
      ?? batch.profileSnapshot.adapters.find((candidate) => candidate.id === run.adapterBindingId && candidate.enabled)
      ?? batch.profileSnapshot.adapters.find((candidate) => candidate.runtime === "dsh" && candidate.enabled);
    if (binding === undefined) throw new Error("DSH adapter binding is unavailable");
    const key = contextIdentity(batch.initiatorSessionId, batch.profileId, batch.mode);
    const contexts = this.state.contexts();
    if (contexts.some((candidate) =>
      candidate.key === key
      && candidate.closedAt === undefined
      && candidate.closeIntent !== undefined)) return;
    let context = contexts.find((candidate) =>
      reusableDshContext(candidate, key));
    if (context === undefined) {
      const generation = Math.max(0, ...this.state.contexts().filter((candidate) => candidate.key === key).map((candidate) => candidate.generation ?? 0)) + 1;
      context = {
        id: `${key}:g${generation}`,
        capabilitySnapshotVersion: 1,
        key,
        generation,
        runtime: "dsh",
        rootSessionId: batch.rootSessionId,
        parentSessionId: batch.rootSessionId,
        ownerSessionId: batch.initiatorSessionId,
        profileId: batch.profileId,
        profileSnapshot: batch.profileSnapshot,
        bindingSnapshot: binding,
        mode: batch.mode,
        sandboxMode: batch.mode === "analysis" ? "read-only" : batch.sandboxMode,
        sourceAgentOptions: batch.sourceAgentOptions,
        sourceToolAllowlist: batch.sourceToolAllowlist,
        sourceAgentPreset: batch.sourceAgentPreset,
        sourceCwd: batch.sourceCwd,
        createdAt: Date.now(),
      };
      if (batch.mode === "execution") {
        const sourcePath = batch.sourceCwd ?? parent.session.header.cwd;
        if (sourcePath === undefined) throw new Error("DSH execution requires a parent project cwd");
        const workspace = await this.workspaces.allocate({ sourcePath, identity: context.id });
        Object.assign(context, {
          workspacePath: workspace.path,
          worktreeRoot: workspace.worktreeRoot,
          branch: workspace.branch,
          gitRoot: workspace.gitRoot,
          baselineCommit: workspace.baselineCommit,
        });
      }
    }
    if (context.childSessionId === undefined) {
      context.childSessionId = randomUUID();
      context.childEstablished = false;
    }
    const dshMessageId = run.dshMessageId ?? randomUUID();
    const bound = await this.state.bindRunToContext(runId, context, dshMessageId);
    if (bound === undefined) return;
    await this.afterMutation(batch.rootSessionId);
    if (this.stopRequested.has(runId)) {
      this.stopRequested.delete(runId);
      await this.updateRun(runId, { status: "cancelled", error: "cancelled before child start" });
      return;
    }

    const toolFilter = dshToolFilter(
      this.ctx,
      parent,
      batch.mode,
      context.bindingSnapshot,
      context.sourceToolAllowlist);
    const childAgentOptions = dshAgentOptions(
      context.sourceAgentOptions,
      context.bindingSnapshot);
    const prompt = [{
      type: "text",
      text: dshRunPrompt(batch.task, run.resumeAfterRestart, context.childSessionId),
    }];
    const label = `${PLATFORM_CHILD_LABEL_PREFIX}${context.id}`;
    const childId = context.childSessionId;
    let reservedMessageId = dshMessageId;
    if (run.resumeAfterRestart === true && context.childEstablished === true) {
      let settlement;
      try {
        const live = this.ctx.sessions.get(childId);
        const events = live?.events ?? (await this.ctx.sessionPersistence.inspect(childId)).events;
        settlement = dshRunSettlement(events, reservedMessageId);
      } catch {
        settlement = undefined;
      }
      const decision = dshRecoveryDecision(settlement, true);
      if (decision === "settle") {
        await this.applyDshSettlement(runId, settlement);
        return;
      }
      if (decision === "continue") {
        reservedMessageId = randomUUID();
        await this.state.updateRun(runId, { dshMessageId: reservedMessageId });
      }
    }
    const delivery = await startOrResumeReservedContinuable({
      childId,
      messageId: reservedMessageId,
      established: context.childEstablished,
      followup: (reservedId, reservedMessageId) => this.ctx.subagents.followup(parent, reservedId, prompt, {
        messageId: reservedMessageId,
        agentOptions: childAgentOptions,
        source: {
          kind: "plugin",
          plugin: "agent-platform",
          form: "relay",
        },
        signal: new AbortController().signal,
      }),
      start: async (reservedId, reservedMessageId) => {
        this.pendingCreationLabels.set(label, { mode: batch.mode });
        try {
          return await this.ctx.subagents.startContinuable({
            childId: reservedId,
            messageId: reservedMessageId,
            ...context.sandboxMode === undefined ? {} : { sandboxMode: context.sandboxMode },
            ...context.sourceAgentPreset === undefined ? {} : { agentPreset: context.sourceAgentPreset },
            provider: "spawn",
            label,
            ...dshChildCwd(
              context.sourceCwd ?? batch.sourceCwd ?? parent.session.header.cwd,
              context.workspacePath) === undefined
              ? {}
              : {
                  cwd: dshChildCwd(
                    context.sourceCwd ?? batch.sourceCwd ?? parent.session.header.cwd,
                    context.workspacePath),
                },
            request: {
              prompt,
              parent,
              ...childAgentOptions === undefined ? {} : { agentOptions: childAgentOptions },
              ...batch.profileSnapshot.persona === undefined ? {} : { persona: batch.profileSnapshot.persona },
              ...toolFilter === undefined ? {} : { toolFilter },
            },
            signal: new AbortController().signal,
          });
        } finally {
          this.pendingCreationLabels.delete(label);
        }
      },
    });
    const messageId = delivery.messageId;
    context.childEstablished = true;
    await this.state.upsertContext(context);
    if (this.stopRequested.has(runId)) {
      this.ctx.subagents.interrupt(childId, {
        kind: "user",
        parentSessionId: batch.rootSessionId,
      });
    }
    if (run.resumeAfterRestart === true) {
      await this.state.updateRun(runId, { resumeAfterRestart: false });
    }
    await this.logs.append(runId, "system", `DSH child ${childId} accepted message ${messageId}`);
    try {
      await this.waitForDshRun(runId, childId, messageId);
    } finally {
      const pending = this.pendingDshByChild.get(childId);
      if (pending?.runId === runId) this.pendingDshByChild.delete(childId);
      this.acceptedDshMessages.delete(messageId);
      this.stopRequested.delete(runId);
    }
  }

  waitForDshRun(runId, childId, messageId) {
    return new Promise((resolve, reject) => {
      const pending = { runId, childId, messageId, turn: undefined, resolve, reject };
      this.pendingDshByChild.set(childId, pending);
      this.acceptedDshMessages.set(messageId, pending);
      const agent = this.ctx.agents.get(childId);
      if (agent !== undefined) {
        this.reconcileDsh(agent.session, pending).catch(reject);
      } else {
        this.reconcilePersistedDsh(pending).catch(reject);
      }
    });
  }

  async reconcileDsh(session, pending) {
    const settlement = dshRunSettlement(session.events, pending.messageId);
    if (settlement === undefined) return false;
    await this.settleDsh(settlement, pending);
    return true;
  }

  async reconcilePersistedDsh(pending) {
    for (let attempt = 0; attempt < 20; attempt += 1) {
      if (this.pendingDshByChild.get(pending.childId) !== pending) return;
      const live = this.ctx.agents.get(pending.childId);
      if (live !== undefined) {
        await this.reconcileDsh(live.session, pending);
        return;
      }
      const inspected = await this.ctx.sessionPersistence.inspect(pending.childId);
      if (await this.reconcileDsh({ events: inspected.events }, pending)) return;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    throw new Error(`persisted DSH message "${pending.messageId}" has no terminal turn`);
  }

  async settleDsh(settlement, pending) {
    if (this.pendingDshByChild.get(pending.childId) !== pending) return;
    await this.applyDshSettlement(pending.runId, settlement);
    this.pendingDshByChild.delete(pending.childId);
    this.acceptedDshMessages.delete(pending.messageId);
    this.stopRequested.delete(pending.runId);
    pending.resolve();
  }

  async applyDshSettlement(runId, settlement) {
    const status = this.stopRequested.has(runId) ? "cancelled" : settlement.status;
    const output = settlement.output ?? "";
    if (output) await this.logs.append(runId, "assistant", output);
    if (status !== "succeeded") {
      await this.logs.append(runId, "stderr", settlement.error ?? status);
    }
    await this.updateRun(runId, {
      status,
      ...output ? { output } : {},
      ...status === "succeeded" ? {} : { error: settlement.error ?? status },
      resumeAfterRestart: false,
    });
  }

  async executeExternal(batchId, runId) {
    const batch = this.state.batch(batchId);
    let run = this.state.run(runId);
    const binding = run.adapterSnapshot
      ?? batch.profileSnapshot.adapters.find((candidate) => candidate.id === run.adapterBindingId && candidate.enabled)
      ?? batch.profileSnapshot.adapters.find((candidate) => candidate.runtime === run.adapter && candidate.enabled);
    if (binding === undefined) throw new Error(`${run.adapter} adapter binding is unavailable`);
    const root = this.ctx.agents.get(batch.rootSessionId);
    if (root === undefined) throw new Error(`root "${batch.rootSessionId}" is not live`);
    if (!hasCompleteInitiatingCapabilitySnapshot(batch, true)) {
      throw new Error("initiating capability snapshot is unavailable; dispatch a new Batch");
    }
    let cwd = batch.sourceCwd;
    await this.updateRun(run.id, { status: "preparing" });
    if (batch.mode === "execution") {
      if (cwd === undefined) throw new Error(`${run.adapter} execution requires a project cwd`);
      if (run.worktreePath === undefined) {
        const workspace = await this.workspaces.allocate({ sourcePath: cwd, identity: run.id });
        const latest = this.state.run(run.id);
        if (runCancellationRequested(latest.status, this.stopRequested.has(run.id))) {
          this.stopRequested.delete(run.id);
          await this.workspaces.cleanup(workspace);
          if (!TERMINAL.has(latest.status)) await this.updateRun(run.id, { status: "cancelled", error: "cancelled before worker start" });
          return;
        }
        run = await this.state.patchRunWorkspace(run.id, workspace);
        await this.afterMutation(batch.rootSessionId);
      }
      cwd = run.worktreePath;
    }
    if (cwd === undefined) throw new Error(`${run.adapter} analysis requires a project cwd`);
    const beforeCommand = this.state.run(run.id);
    if (runCancellationRequested(beforeCommand.status, this.stopRequested.has(run.id))) {
      this.stopRequested.delete(run.id);
      if (!TERMINAL.has(beforeCommand.status)) await this.updateRun(run.id, { status: "cancelled", error: "cancelled before worker start" });
      return;
    }
    const rawCommand = adapterCommand(run.adapter, {
      mode: batch.mode,
      task: batch.task,
      persona: batch.profileSnapshot.persona,
      cwd,
      binding,
    });
    const command = confineExternalCommand(
      rawCommand,
      externalSandboxPolicy(
        batch.mode,
        {
          mode: batch.sandboxMode,
          workspaceRoot: cwd,
          sessionId: batch.initiatorSessionId,
        },
        cwd),
      this.ctx.sandbox);
    await this.updateRun(run.id, { status: "running" });
    if (this.stopRequested.has(run.id)) {
      this.stopRequested.delete(run.id);
      await this.updateRun(run.id, { status: "cancelled", error: "cancelled before worker start" });
      return;
    }
    await this.logs.append(
      run.id,
      "system",
      `Sandbox ${command.sandboxMode}${command.sandboxEnforcement ? ` (${command.sandboxEnforcement})` : ""} · cwd ${cwd}`);
    const encoded = Buffer.from(JSON.stringify(command), "utf8").toString("base64url");
    await new Promise((resolve, reject) => {
      const worker = spawn(process.execPath, [WORKER_PATH, encoded], {
        cwd,
        stdio: ["pipe", "pipe", "pipe"],
      });
      this.activeExternal.set(run.id, worker);
      let output = "";
      const capture = (stream) => (chunk) => {
        const text = chunk.toString();
        output = (output + text).slice(-128_000);
        this.logs.append(run.id, stream, text).catch((error) => this.ctx.logger.warn(`agent-platform log append failed: ${String(error)}`));
      };
      worker.stdout.on("data", capture("stdout"));
      worker.stderr.on("data", capture("stderr"));
      worker.on("error", reject);
      worker.on("close", async (status, signal) => {
        this.activeExternal.delete(run.id);
        try {
          if (this.stopRequested.has(run.id)) {
            this.stopRequested.delete(run.id);
            await this.updateRun(run.id, { status: "cancelled", error: "cancelled by user" });
          } else if (status === 0) {
            const inspection = run.worktreePath === undefined
              ? {}
              : await this.workspaces.inspect(run.worktreePath, run.baselineCommit);
            if (run.worktreePath !== undefined) await this.state.recordRunInspection(run.id, inspection);
            await this.updateRun(run.id, {
              status: "succeeded",
              output: extractExternalOutput(output),
              ...inspection.diffSummary === undefined ? {} : { diffSummary: inspection.diffSummary },
            });
          } else {
            await this.updateRun(run.id, {
              status: "failed",
              error: `${run.adapter} exited with ${status ?? signal ?? "unknown status"}`,
              output: extractExternalOutput(output),
            });
          }
          resolve();
        } catch (error) {
          reject(error);
        }
      });
    });
  }

  async updateRun(runId, patch) {
    const run = await this.state.updateRun(runId, patch);
    const batch = this.findBatchForRun(runId);
    if (batch !== undefined) {
      await this.afterMutation(batch.rootSessionId);
      if (TERMINAL.has(run.status)) await this.deliverReadyIntegrations(batch.rootSessionId);
    }
    return run;
  }

  async deliverReadyIntegrations(rootSessionId) {
    for (const batchId of this.state.readyIntegrationBatchIds(rootSessionId)) {
      await this.deliverIntegration(batchId);
    }
  }

  async afterMutation(rootSessionId) {
    await this.publishRoot(rootSessionId);
    await this.deliverSettlements();
  }

  async publishRoot(rootSessionId) {
    const session = this.ctx.sessions.get(rootSessionId);
    if (session === undefined) return;
    session.append("agent-platform/batches", { items: this.state.batches(rootSessionId) });
  }

  async publishAll() {
    const roots = new Set();
    for (const agent of this.ctx.agents.roots()) roots.add(agent.id);
    for (const root of roots) await this.publishRoot(root);
  }

  async deliverSettlements() {
    for (const root of this.ctx.agents.roots()) {
      for (const batch of this.state.batches(root.id)) {
        if ((batch.summaryRevision ?? 0) <= (batch.summaryDeliveredRevision ?? 0)) continue;
        await this.summaryDeliveries.run(batch.id, async () => {
          const current = this.state.batch(batch.id);
          if ((current.summaryRevision ?? 0) <= (current.summaryDeliveredRevision ?? 0)) return;
          const recipient = this.ctx.agents.get(current.rootSessionId);
          if (recipient === undefined) return;
          const prepared = await this.state.prepareSummaryDelivery(current.id, createUserMessage({
            content: [{ type: "text", text: current.summary }],
            source: {
              kind: "plugin",
              plugin: "agent-platform",
              form: "notice",
              summary: boundContextSummary(`Agent Batch ${current.profileName} 已结束`),
            },
          }));
          if (prepared === undefined) return;
          const delivery = deliverDurableAgentMessage(recipient, prepared);
          if (delivery !== "logged") return;
          await this.state.markSummaryDelivered(current.id);
          const delivered = this.state.batch(current.id);
          if (delivered.integrationPolicy === "auto" && delivered.integrationState === "requested") {
            await this.deliverReadyIntegrations(delivered.rootSessionId);
          }
        });
      }
    }
  }

  async deliverIntegration(batchId) {
    return this.integrationDeliveries.run(batchId, async () => {
      const batch = this.state.batch(batchId);
      const root = this.ctx.agents.get(batch.rootSessionId);
      if (root === undefined) return;
      if (batch.integrationState !== "requested" && batch.integrationState !== "failed") return;
      if (!this.state.readyIntegrationBatchIds(batch.rootSessionId).includes(batch.id)) return;
      const text = renderIntegrationPrompt(batch, this.state.integrationContextHistory(batch.id));
      const delivery = await this.state.prepareIntegrationDelivery(batch.id, createUserMessage({
        content: [{ type: "text", text }],
        source: {
          kind: "plugin",
          plugin: "agent-platform",
          form: "instructions",
          summary: boundContextSummary(`整合 Agent Batch ${batch.id}`),
        },
      }));
      if (delivery === undefined) return;
      const outcome = deliverDurableAgentMessage(root, delivery.message);
      if (outcome !== "logged") return;
      await this.state.markIntegrationRequested(batch.id, delivery.revision);
      await this.publishRoot(batch.rootSessionId);
    });
  }

  async dispose() {
    this.disposed = true;
    for (const worker of this.activeExternal.values()) worker.stdin.end();
  }
}

class AgentProfilesGateway extends TypertRemoteService {
  static initializers;
  coordinator;
  constructor(ctx, coordinator) {
    super(ctx, "agentProfiles");
    this.coordinator = coordinator;
    initializeRemotes(this, AgentProfilesGateway.initializers);
  }
  list() { return { items: this.coordinator.profiles() }; }
  save(profile) { return this.coordinator.saveProfile(profile); }
  remove(profileId) { return this.coordinator.removeProfile(profileId); }
  runtimeStatus() { return { items: this.coordinator.runtimeStatus() }; }
}
AgentProfilesGateway.initializers = remoteInitializers(AgentProfilesGateway, {
  list: "list", save: "save", remove: "remove", runtimeStatus: "runtimeStatus",
});

class AgentBatchesGateway extends TypertRemoteService {
  static initializers;
  coordinator;
  constructor(ctx, coordinator) {
    super(ctx, "agentBatches");
    this.coordinator = coordinator;
    initializeRemotes(this, AgentBatchesGateway.initializers);
  }
  start(profileId, rootSessionId, initiatorSessionId, task, mode, integrationPolicy, source) {
    return this.coordinator.startBatch(profileId, rootSessionId, initiatorSessionId, task, mode, integrationPolicy, source);
  }
  list(rootSessionId) { return { items: this.coordinator.listBatches(rootSessionId) }; }
  detail(batchId) { return this.coordinator.batch(batchId); }
  stop(batchId) { return this.coordinator.stopBatch(batchId); }
  retryRun(runId) { return this.coordinator.retryRun(runId); }
  setIntegration(batchId, integrationPolicy) { return this.coordinator.setIntegration(batchId, integrationPolicy); }
  requestIntegration(batchId, preferredRunIds) { return this.coordinator.requestIntegration(batchId, preferredRunIds); }
}
AgentBatchesGateway.initializers = remoteInitializers(AgentBatchesGateway, {
  start: "start", list: "list", detail: "detail", stop: "stop",
  retryRun: "retryRun", setIntegration: "setIntegration", requestIntegration: "requestIntegration",
});

class AgentRunsGateway extends TypertRemoteService {
  static initializers;
  coordinator;
  constructor(ctx, coordinator) {
    super(ctx, "agentRuns");
    this.coordinator = coordinator;
    initializeRemotes(this, AgentRunsGateway.initializers);
  }
  log(runId, before, limit) { return this.coordinator.runLog(runId, before, limit); }
  inspectWorkspace(runId) { return this.coordinator.inspectWorkspace(runId); }
  discard(runId) { return this.coordinator.discardRun(runId); }
}
AgentRunsGateway.initializers = remoteInitializers(AgentRunsGateway, {
  log: "log", inspectWorkspace: "inspectWorkspace", discard: "discard",
});

class AgentContextsGateway extends TypertRemoteService {
  static initializers;
  coordinator;
  constructor(ctx, coordinator) {
    super(ctx, "agentContexts");
    this.coordinator = coordinator;
    initializeRemotes(this, AgentContextsGateway.initializers);
  }
  discard(contextId) { return this.coordinator.closeContext(contextId, "discarded"); }
  resetAnalysis(profileId, parentSessionId) { return this.coordinator.resetAnalysis(profileId, parentSessionId); }
}
AgentContextsGateway.initializers = remoteInitializers(AgentContextsGateway, {
  discard: "discard", resetAnalysis: "resetAnalysis",
});

export async function apply(ctx, config) {
  const coordinator = await AgentPlatformCoordinator.create(ctx, config);
  new AgentProfilesGateway(ctx, coordinator);
  new AgentBatchesGateway(ctx, coordinator);
  new AgentRunsGateway(ctx, coordinator);
  new AgentContextsGateway(ctx, coordinator);
  return () => coordinator.dispose();
}

export { AgentPlatformCoordinator };
