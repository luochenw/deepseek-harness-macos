import { realpathSync } from "node:fs";
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

function replaceOnce(source, before, after, label) {
  const first = source.indexOf(before);
  if (first < 0) throw new Error(`agent-platform runtime patch: ${label} anchor not found`);
  if (source.indexOf(before, first + before.length) >= 0) throw new Error(`agent-platform runtime patch: ${label} anchor is ambiguous`);
  return source.slice(0, first) + after + source.slice(first + before.length);
}

async function patchFile(file, transform) {
  const original = await readFile(file, "utf8");
  const next = transform(original);
  if (next !== original) await writeFile(file, next);
}

async function assertPackageVersion(runtimeRoot, name, expectedVersion) {
  const manifestPath = path.join(runtimeRoot, "node_modules/@deepseek-ai", name, "package.json");
  let manifest;
  try {
    manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  } catch (error) {
    throw new Error(`agent-platform runtime patch cannot read @deepseek-ai/${name} metadata`, { cause: error });
  }
  if (manifest.version !== expectedVersion) {
    throw new Error(
      `agent-platform runtime patch requires @deepseek-ai/${name} ${expectedVersion} with `
      + `@deepseek-ai/dsh ${expectedVersion}, found ${String(manifest.version)}`);
  }
}

export async function patchRuntime(runtimeRoot) {
  const manifestPath = path.join(runtimeRoot, "package.json");
  const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  const legacyRuntime = ["0.1.0-rc.6", "0.1.0-rc.7"].includes(manifest.version);
  if (!legacyRuntime && manifest.version !== "0.1.1-rc.2") {
    throw new Error(`agent-platform runtime patch does not support @deepseek-ai/dsh ${manifest.version}`);
  }
  for (const name of ["dsh-subagent", "dsh-session", "dsh-web-app"]) {
    await assertPackageVersion(runtimeRoot, name, manifest.version);
  }

  const subagentRoot = path.join(runtimeRoot, "node_modules/@deepseek-ai/dsh-subagent");
  await patchFile(path.join(subagentRoot, "lib/index.js"), (source) => {
    let next = source;
    if (!next.includes("MessageId,") || !next.includes("freezeMessage")) {
      next = replaceOnce(
        next,
        'import { HarnessError, boundContextSummary, createUserMessage, errorChain } from "@deepseek-ai/dsh-llm";',
        'import { HarnessError, MessageId, boundContextSummary, createUserMessage, errorChain, freezeMessage } from "@deepseek-ai/dsh-llm";',
        "continuable reserved message imports");
    }
    if (!next.includes("const childCwd = cwd ?? parentHeader.cwd;")) {
      next = replaceOnce(
        next,
        "function childSessionMeta(parent, childDepth, lineageSeedLength) {\n\tconst parentHeader = parent.session.header;",
        "function childSessionMeta(parent, childDepth, lineageSeedLength, cwd, agentPreset) {\n\tconst parentHeader = parent.session.header;\n\tconst childCwd = cwd ?? parentHeader.cwd;",
        "childSessionMeta signature");
      next = replaceOnce(
        next,
        '\tconst agentPreset = parent.ctx.get("agentPresets")?.composedPreset(parent.ctx);',
        '\tconst inheritedAgentPreset = parent.ctx.get("agentPresets")?.composedPreset(parent.ctx);\n\tconst childAgentPreset = agentPreset ?? inheritedAgentPreset;',
        "child preset override");
      next = replaceOnce(
        next,
        "\t\t...parentHeader.cwd !== void 0 ? { cwd: parentHeader.cwd } : {},",
        "\t\t...childCwd !== void 0 ? { cwd: childCwd } : {},",
        "child cwd metadata");
      next = replaceOnce(
        next,
        "\t\t...agentPreset === void 0 ? {} : { agentPreset },",
        "\t\t...childAgentPreset === void 0 ? {} : { agentPreset: childAgentPreset },",
        "child preset metadata");
      next = replaceOnce(
        next,
        "\t\t\t\t\t\tmeta: childSessionMeta(parent, childDepth, lineageSeedLength),",
        "\t\t\t\t\t\tmeta: childSessionMeta(parent, childDepth, lineageSeedLength, spec.cwd, spec.agentPreset),",
        "continuable cwd forwarding");
    }
    if (legacyRuntime && !next.includes("const childId = spec.childId ?? SessionId(randomUUID());")) {
      next = replaceOnce(
        next,
        "\t\tconst childId = SessionId(randomUUID());",
        "\t\tconst childId = spec.childId ?? SessionId(randomUUID());",
        "continuable child id reservation");
    }
    if (!next.includes("spec.sandboxMode !== void 0 ? { sandboxMode: spec.sandboxMode } : {}")) {
      next = replaceOnce(
        next,
        "\t\tconst delegatedPolicies = captureDelegatedPolicyOverrides(parent);",
        "\t\tconst delegatedPolicies = {\n\t\t\t...captureDelegatedPolicyOverrides(parent),\n\t\t\t...spec.sandboxMode !== void 0 ? { sandboxMode: spec.sandboxMode } : {}\n\t\t};",
        "continuable sandbox override");
    }
    if (!next.includes("inputs.composition.agentPreset !== void 0")) {
      next = replaceOnce(
        next,
        '\tchildCtx.get("agentPresets")?.composeFrom(childCtx, parent.ctx);',
        '\tif (composition.agentPreset === void 0) childCtx.get("agentPresets")?.composeFrom(childCtx, parent.ctx);',
        "conditional child preset inheritance");
      next = replaceOnce(
        next,
        "\t\tconst setup = (childCtx) => {\n\t\t\tif (create !== void 0) appendDelegatedPolicyOverrides(childCtx.agent.session, create.delegatedPolicies);\n\t\t\tapplyChildComposition(childCtx, parent, inputs.composition);",
        '\t\tconst setup = async (childCtx) => {\n\t\t\tif (create !== void 0) appendDelegatedPolicyOverrides(childCtx.agent.session, create.delegatedPolicies);\n\t\t\tif (inputs.composition.agentPreset !== void 0) await childCtx.get("agentPresets")?.mount(childCtx, inputs.composition.agentPreset);\n\t\t\tapplyChildComposition(childCtx, parent, inputs.composition);',
        "continuable explicit preset setup");
      next = replaceOnce(
        next,
        "\t\t\t\tcomposition: {\n\t\t\t\t\tpersona: descriptor.persona,\n\t\t\t\t\ttoolFilter: descriptor.toolFilter\n\t\t\t\t},",
        '\t\t\t\tcomposition: {\n\t\t\t\t\t...descriptor.label.startsWith("__dsh_agent_platform__:") && loaded.meta.agentPreset !== void 0 ? { agentPreset: loaded.meta.agentPreset } : {},\n\t\t\t\t\tpersona: descriptor.persona,\n\t\t\t\t\ttoolFilter: descriptor.toolFilter\n\t\t\t\t},',
        "cold platform preset restore");
      next = replaceOnce(
        next,
        "\t\t\t\t\tcomposition: {\n\t\t\t\t\t\tpersona: request.persona,\n\t\t\t\t\t\ttoolFilter: request.toolFilter\n\t\t\t\t\t},",
        "\t\t\t\t\tcomposition: {\n\t\t\t\t\t\t...spec.agentPreset !== void 0 ? { agentPreset: spec.agentPreset } : {},\n\t\t\t\t\t\tpersona: request.persona,\n\t\t\t\t\t\ttoolFilter: request.toolFilter\n\t\t\t\t\t},",
        "initial platform preset setup");
    }
    if (!next.includes("function assertAgentPlatformFollowup(descriptor, source, childId)")) {
      next = replaceOnce(
        next,
        "function foldSubagentDescriptor(events) {\n\tconst event = events.find((candidate) => candidate.type === \"subagent/descriptor\");\n\tif (event === void 0) return void 0;\n\treturn parseSubagentDescriptor(event.data);\n}",
        `function foldSubagentDescriptor(events) {
\tconst event = events.find((candidate) => candidate.type === "subagent/descriptor");
\tif (event === void 0) return void 0;
\treturn parseSubagentDescriptor(event.data);
}
function assertAgentPlatformFollowup(descriptor, source, childId) {
\tif (descriptor?.mode !== "continuable" || !descriptor.label.startsWith("__dsh_agent_platform__:")) return;
\tif (source.kind === "plugin" && source.plugin === "agent-platform") return;
\tthrow new SubagentError(\`subagent "\${childId}" is managed by the Agent Platform and only accepts platform-coordinated follow-ups\`, "UNAUTHORIZED");
}`,
        "managed continuable guard");
      next = replaceOnce(
        next,
        "\t\t\t\tconst activation = this.activations.get(childId);\n\t\t\t\tif (activation === void 0) return this.coldResume(parent, childId, content, options);",
        "\t\t\t\tconst activation = this.activations.get(childId);\n\t\t\t\tif (activation === void 0) return this.coldResume(parent, childId, content, options);\n\t\t\t\tconst descriptor = foldSubagentDescriptor(activation.handle.agent.session.events.slice(activation.handle.agent.session.header.seedLength ?? 0));\n\t\t\t\tassertAgentPlatformFollowup(descriptor, options.source, childId);",
        "resident managed followup guard");
      next = replaceOnce(
        next,
        "\t\tconst descriptor = foldSubagentDescriptor(loaded.events.slice(loaded.meta.seedLength ?? 0));\n\t\tif (descriptor === void 0 || descriptor.mode !== \"continuable\") throw new SubagentError",
        "\t\tconst descriptor = foldSubagentDescriptor(loaded.events.slice(loaded.meta.seedLength ?? 0));\n\t\tif (descriptor === void 0 || descriptor.mode !== \"continuable\") throw new SubagentError",
        "cold descriptor anchor");
      next = replaceOnce(
        next,
        "\t\tif (descriptor === void 0 || descriptor.mode !== \"continuable\") throw new SubagentError(`subagent \"${childId}\" has no supported continuation state and cannot be resumed; do not retry send_message with this id`, \"NOT_RESUMABLE\");\n\t\tlet activation;",
        "\t\tif (descriptor === void 0 || descriptor.mode !== \"continuable\") throw new SubagentError(`subagent \"${childId}\" has no supported continuation state and cannot be resumed; do not retry send_message with this id`, \"NOT_RESUMABLE\");\n\t\tassertAgentPlatformFollowup(descriptor, options.source, childId);\n\t\tif (options.messageId !== void 0 && loaded.events.some((event) => event.type === \"user/message\" && event.data?.id === options.messageId)) return MessageId(options.messageId);\n\t\tlet activation;",
        "cold managed followup guard");
    }
    if (!next.includes("options.agentOptions?.maxTokens")) {
      next = replaceOnce(
        next,
        "\t\t\t\tagentOptions: {\n\t\t\t\t\t...descriptor.agentProvider !== void 0 ? { provider: descriptor.agentProvider } : {},\n\t\t\t\t\t...descriptor.agentModel !== void 0 ? { model: descriptor.agentModel } : {}\n\t\t\t\t},",
        "\t\t\t\tagentOptions: {\n\t\t\t\t\t...descriptor.agentProvider !== void 0 ? { provider: descriptor.agentProvider } : {},\n\t\t\t\t\t...descriptor.agentModel !== void 0 ? { model: descriptor.agentModel } : {},\n\t\t\t\t\t...descriptor.label.startsWith(\"__dsh_agent_platform__:\") && options.agentOptions?.maxTokens !== void 0 ? { maxTokens: options.agentOptions.maxTokens } : {}\n\t\t\t\t},",
        "cold platform maxTokens restore");
    }
    if (!next.includes("function createContinuableMessage(content, source, messageId)")) {
      next = replaceOnce(
        next,
        "function assertAgentPlatformFollowup(descriptor, source, childId) {\n\tif (descriptor?.mode !== \"continuable\" || !descriptor.label.startsWith(\"__dsh_agent_platform__:\")) return;\n\tif (source.kind === \"plugin\" && source.plugin === \"agent-platform\") return;\n\tthrow new SubagentError(`subagent \"${childId}\" is managed by the Agent Platform and only accepts platform-coordinated follow-ups`, \"UNAUTHORIZED\");\n}",
        `function assertAgentPlatformFollowup(descriptor, source, childId) {
\tif (descriptor?.mode !== "continuable" || !descriptor.label.startsWith("__dsh_agent_platform__:")) return;
\tif (source.kind === "plugin" && source.plugin === "agent-platform") return;
\tthrow new SubagentError(\`subagent "\${childId}" is managed by the Agent Platform and only accepts platform-coordinated follow-ups\`, "UNAUTHORIZED");
}
function createContinuableMessage(content, source, messageId) {
\tif (messageId === void 0) return createUserMessage({ content, source });
\treturn freezeMessage({
\t\tid: MessageId(messageId),
\t\trole: "user",
\t\tcontent,
\t\tsource
\t});
}`,
        "reserved continuable message helper");
      next = replaceOnce(
        next,
        "return this.submitMaterialized(activation, request.prompt, { kind: \"user\" }, parent, spec.signal);",
        "return this.submitMaterialized(activation, request.prompt, { kind: \"user\" }, parent, spec.signal, spec.messageId);",
        "initial continuable message id forwarding");
      next = replaceOnce(
        next,
        "return this.submitAdmitted(activation, content, options.source, parent, options.signal);",
        "return this.submitAdmitted(activation, content, options.source, parent, options.signal, options.messageId);",
        "resident continuable message id forwarding");
      next = replaceOnce(
        next,
        "return this.submitMaterialized(activation, content, options.source, parent, options.signal);",
        "return this.submitMaterialized(activation, content, options.source, parent, options.signal, options.messageId);",
        "cold continuable message id forwarding");
      next = replaceOnce(
        next,
        "async submitMaterialized(activation, content, source, parent, signal) {\n\t\ttry {\n\t\t\treturn this.submitAdmitted(activation, content, source, parent, signal);",
        "async submitMaterialized(activation, content, source, parent, signal, messageId) {\n\t\ttry {\n\t\t\treturn this.submitAdmitted(activation, content, source, parent, signal, messageId);",
        "materialized continuable message id forwarding");
      next = replaceOnce(
        next,
        "\tsubmit(activation, content, source, parent) {\n\t\tthis.acquireOwnership(parent, activation.childId);\n\t\tconst message = createUserMessage({\n\t\t\tcontent,\n\t\t\tsource\n\t\t});",
        `\tsubmit(activation, content, source, parent, messageId) {
\t\tthis.acquireOwnership(parent, activation.childId);
\t\tconst message = createContinuableMessage(content, source, messageId);
\t\tif (activation.handle.agent.session.events.some((event) => event.type === "user/message" && event.data?.id === message.id)) {
\t\t\tactivation.announced = true;
\t\t\treturn message.id;
\t\t}
\t\tactivation.handle.agent.inbox.remove(message.id);`,
        "idempotent continuable submit");
      next = replaceOnce(
        next,
        "submitAdmitted(activation, content, source, parent, signal) {",
        "submitAdmitted(activation, content, source, parent, signal, messageId) {",
        "admitted continuable message id signature");
      next = replaceOnce(
        next,
        "return this.submit(activation, content, source, parent);",
        "return this.submit(activation, content, source, parent, messageId);",
        "admitted continuable message id forwarding");
    }
    if (legacyRuntime && !next.includes("async disposeContinuable(targetSessionId, authority)")) {
      next = replaceOnce(
        next,
        "\t/**\n\t* Deliver explicitly selected content from one resident continuable child to",
        `\t/**
\t* Dispose one exact resident continuable child after validating the same
\t* authority accepted by interrupt(). An absent target is an idempotent no-op.
\t*/
\tasync disposeContinuable(targetSessionId, authority) {
\t\tif (authority.kind === "ancestor") {
\t\t\tconst caller = authority.agent;
\t\t\tif (this.ctx.agents.get(caller.id) !== caller) throw new SubagentError(\`disposing "\${targetSessionId}" requires the exact live ancestor agent\`, "UNAUTHORIZED");
\t\t\tif (caller.id === targetSessionId) throw new SubagentError(\`agent "\${caller.id}" cannot dispose itself\`, "UNAUTHORIZED");
\t\t}
\t\tawait this.locks.run(targetSessionId, async () => {
\t\t\tconst activation = this.activations.get(targetSessionId);
\t\t\tif (activation === void 0) return;
\t\t\tif (authority.kind === "user") {
\t\t\t\tif (activation.handle.agent.session.header.parentSession !== authority.parentSessionId) throw new SubagentError(\`subagent "\${targetSessionId}" belongs to another parent session\`, "UNAUTHORIZED");
\t\t\t} else if (!activation.ancestry.has(authority.agent)) throw new SubagentError(\`subagent "\${targetSessionId}" is not a live descendant of agent "\${authority.agent.id}"\`, "UNAUTHORIZED");
\t\t\tawait this.dispose(activation);
\t\t});
\t}
\t/**
\t* Deliver explicitly selected content from one resident continuable child to`,
        "continuation exact disposal");
      next = replaceOnce(
        next,
        "\t/**\n\t* Deliver selected content from one live continuable child to its durable",
        `\t/** Dispose one exact resident continuable child under interrupt-equivalent authority. */
\tasync disposeContinuable(targetSessionId, authority) {
\t\treturn this.continuations?.disposeContinuable(targetSessionId, authority);
\t}
\t/**
\t* Deliver selected content from one live continuable child to its durable`,
        "SubagentRuntime disposal forwarding");
    }
    return next;
  });

  await patchFile(path.join(subagentRoot, "lib/types/continuation.d.ts"), (source) => {
    let next = source;
    if (!next.includes("AgentOptions")) {
      next = replaceOnce(
        next,
        "import type { Agent } from '@deepseek-ai/dsh-agent';",
        "import type { Agent, AgentOptions } from '@deepseek-ai/dsh-agent';",
        "continuation AgentOptions type import");
    }
    if (!next.includes("readonly cwd?: string;")) {
      next = replaceOnce(
        next,
        "export interface ContinuableStartSpec {\n",
        "export interface ContinuableStartSpec {\n    /** Optional absolute working-directory override for this durable child. */\n    readonly cwd?: string;\n",
        "ContinuableStartSpec cwd type");
    }
    if (!next.includes("readonly childId?: SessionId;")) {
      next = replaceOnce(
        next,
        "export interface ContinuableStartSpec {\n",
        "export interface ContinuableStartSpec {\n    /** Optional durable identity reserved by a coordinating Host plugin. */\n    readonly childId?: SessionId;\n",
        "ContinuableStartSpec child id type");
    }
    if (!next.includes("Optional stable inbox identity reserved before delivery.")) {
      next = replaceOnce(
        next,
        "export interface ContinuableStartSpec {\n",
        "export interface ContinuableStartSpec {\n    /** Optional stable inbox identity reserved before delivery. */\n    readonly messageId?: MessageId;\n",
        "ContinuableStartSpec message id type");
    }
    if (!next.includes("Optional fixed sandbox mode captured by a coordinating Host plugin.")) {
      next = replaceOnce(
        next,
        "export interface ContinuableStartSpec {\n",
        "export interface ContinuableStartSpec {\n    /** Optional fixed sandbox mode captured by a coordinating Host plugin. */\n    readonly sandboxMode?: \"read-only\" | \"workspace-write\" | \"danger-full-access\";\n",
        "ContinuableStartSpec sandbox mode type");
    }
    if (!next.includes("Optional fixed Agent Preset captured by a coordinating Host plugin.")) {
      next = replaceOnce(
        next,
        "export interface ContinuableStartSpec {\n",
        "export interface ContinuableStartSpec {\n    /** Optional fixed Agent Preset captured by a coordinating Host plugin. */\n    readonly agentPreset?: string;\n",
        "ContinuableStartSpec agent preset type");
    }
    if (!next.includes("Optional stable inbox identity used for idempotent retry.")) {
      next = replaceOnce(
        next,
        "export interface SubagentFollowupOptions {\n",
        "export interface SubagentFollowupOptions {\n    /** Optional stable inbox identity used for idempotent retry. */\n    readonly messageId?: MessageId;\n",
        "SubagentFollowupOptions message id type");
    }
    if (!next.includes("Optional platform-managed options restored during cold resume.")) {
      next = replaceOnce(
        next,
        "export interface SubagentFollowupOptions {\n",
        "export interface SubagentFollowupOptions {\n    /** Optional platform-managed options restored during cold resume. */\n    readonly agentOptions?: AgentOptions;\n",
        "SubagentFollowupOptions agent options type");
    }
    if (legacyRuntime && !next.includes("disposeContinuable(targetSessionId: SessionId")) {
      next = replaceOnce(
        next,
        "    interrupt(targetSessionId: SessionId, authority: SubagentInterruptAuthority): void;\n",
        "    interrupt(targetSessionId: SessionId, authority: SubagentInterruptAuthority): void;\n    /** Dispose one exact resident continuable child under interrupt-equivalent authority. */\n    disposeContinuable(targetSessionId: SessionId, authority: SubagentInterruptAuthority): Promise<void>;\n",
        "continuation disposal type");
    }
    return next;
  });

  if (legacyRuntime) {
    await patchFile(path.join(subagentRoot, "lib/types/index.d.ts"), (source) => {
      if (source.includes("disposeContinuable(targetSessionId: SessionId")) return source;
      return replaceOnce(
        source,
        "    interrupt(targetSessionId: SessionId, authority: SubagentInterruptAuthority): void;\n",
        "    interrupt(targetSessionId: SessionId, authority: SubagentInterruptAuthority): void;\n    /** Dispose one exact resident continuable child under interrupt-equivalent authority. */\n    disposeContinuable(targetSessionId: SessionId, authority: SubagentInterruptAuthority): Promise<void>;\n",
        "SubagentRuntime disposal type");
    });
  }

  await patchFile(path.join(subagentRoot, "lib/types/child-agent.d.ts"), (source) => {
    let next = source;
    if (!next.includes("lineageSeedLength: number, cwd?: string, agentPreset?: string")) {
      next = replaceOnce(
        next,
        "export declare function childSessionMeta(parent: Agent, childDepth: number, lineageSeedLength: number):",
        "export declare function childSessionMeta(parent: Agent, childDepth: number, lineageSeedLength: number, cwd?: string, agentPreset?: string):",
        "childSessionMeta override types");
    }
    if (!next.includes("readonly agentPreset?: string | undefined;")) {
      next = replaceOnce(
        next,
        "export interface ChildComposition {\n",
        "export interface ChildComposition {\n    /** Optional fixed Agent Preset for a platform-managed durable child. */\n    readonly agentPreset?: string | undefined;\n",
        "ChildComposition agent preset type");
    }
    return next;
  });

  const sessionRoot = path.join(runtimeRoot, "node_modules/@deepseek-ai/dsh-session");
  for (const relative of ["lib/index.js", "lib/types/known-event-types.js"]) {
    await patchFile(path.join(sessionRoot, relative), (source) => {
      if (source.includes('"agent-platform/batches"') || source.includes("'agent-platform/batches'")) return source;
      const quote = relative.endsWith("known-event-types.js") ? "'" : "\"";
      const anchor = `${quote}agent-preset/selected${quote},`;
      return replaceOnce(source, anchor, `${quote}agent-platform/batches${quote},\n\t${anchor}`, `${relative} known event`);
    });
  }

  const webPatch = path.join(runtimeRoot, "node_modules/@deepseek-ai/dsh-web-app/cordis.patch.yml");
  await patchFile(webPatch, (source) => {
    if (source.includes("@dsh-app/dsh-agent-platform")) return source;
    return `${source.trimEnd()}

# Native macOS unified Agent Profile / Runtime / Batch coordinator.
- insert:
    - id: dsh-agent-platform
      name: '@dsh-app/dsh-agent-platform'
      config:
        root: !!js dshHomePath('agent-platform')
`;
  });
}

if (process.argv[1] !== undefined
    && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) {
  const runtimeRoot = process.argv[2];
  if (!runtimeRoot) throw new Error("usage: patch-agent-platform-runtime.mjs <Runtime/dsh>");
  await patchRuntime(runtimeRoot);
}
