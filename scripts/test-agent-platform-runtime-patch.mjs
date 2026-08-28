import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { cp, mkdtemp, mkdir, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { patchRuntime } from "./patch-agent-platform-runtime.mjs";

const root = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-patch-"));
await mkdir(path.join(root, "node_modules/@deepseek-ai/dsh-subagent/lib/types"), { recursive: true });
await mkdir(path.join(root, "node_modules/@deepseek-ai/dsh-session/lib/types"), { recursive: true });
await mkdir(path.join(root, "node_modules/@deepseek-ai/dsh-web-app"), { recursive: true });
await writeFile(path.join(root, "package.json"), JSON.stringify({ version: "0.1.0-rc.6" }));
for (const name of ["dsh-subagent", "dsh-session", "dsh-web-app"]) {
  await writeFile(
    path.join(root, "node_modules/@deepseek-ai", name, "package.json"),
    JSON.stringify({ name: `@deepseek-ai/${name}`, version: "0.1.0-rc.6" }));
}
await writeFile(path.join(root, "node_modules/@deepseek-ai/dsh-subagent/lib/index.js"), `
import { HarnessError, MessageId, boundContextSummary, createUserMessage, errorChain, freezeMessage } from "@deepseek-ai/dsh-llm";
function childSessionMeta(parent, childDepth, lineageSeedLength) {
\tconst parentHeader = parent.session.header;
\tconst agentPreset = parent.ctx.get("agentPresets")?.composedPreset(parent.ctx);
\treturn {
\t\t...parentHeader.cwd !== void 0 ? { cwd: parentHeader.cwd } : {},
\t\t...agentPreset === void 0 ? {} : { agentPreset },
\t};
}
function applyChildComposition(childCtx, parent, composition) {
\tchildCtx.get("agentPresets")?.composeFrom(childCtx, parent.ctx);
}
function foldSubagentDescriptor(events) {
\tconst event = events.find((candidate) => candidate.type === "subagent/descriptor");
\tif (event === void 0) return void 0;
\treturn parseSubagentDescriptor(event.data);
}
\t\t\t\t\t\tmeta: childSessionMeta(parent, childDepth, lineageSeedLength),
\tasync followup(parent, childId, content, options) {
\t\tthis.assertAdmitting(parent);
\t\twhile (true) {
\t\t\tconst live = await this.locks.run(childId, async () => {
\t\t\t\tconst activation = this.activations.get(childId);
\t\t\t\tif (activation === void 0) return this.coldResume(parent, childId, content, options);
\t\t\t\treturn this.submitAdmitted(activation, content, options.source, parent, options.signal);
\t\t\t});
\t\t\tif (live !== void 0) return live;
\t\t}
\t}
\tasync coldResume(parent, childId, content, options) {
\t\tconst loaded = await persistence.inspect(childId, options.signal);
\t\tconst descriptor = foldSubagentDescriptor(loaded.events.slice(loaded.meta.seedLength ?? 0));
\t\tif (descriptor === void 0 || descriptor.mode !== "continuable") throw new SubagentError(\`subagent "\${childId}" has no supported continuation state and cannot be resumed; do not retry send_message with this id\`, "NOT_RESUMABLE");
\t\tlet activation;
\t\tactivation = await this.materialize({
\t\t\tchildId,
\t\t\tprovider: descriptor.provider,
\t\t\tparent,
\t\t\t\tagentOptions: {
\t\t\t\t\t...descriptor.agentProvider !== void 0 ? { provider: descriptor.agentProvider } : {},
\t\t\t\t\t...descriptor.agentModel !== void 0 ? { model: descriptor.agentModel } : {}
\t\t\t\t},
\t\t\t\tcomposition: {
\t\t\t\t\tpersona: descriptor.persona,
\t\t\t\t\ttoolFilter: descriptor.toolFilter
\t\t\t\t},
\t\t\tsignal: options.signal
\t\t});
\t\treturn this.submitMaterialized(activation, content, options.source, parent, options.signal);
\t}
\tasync submitMaterialized(activation, content, source, parent, signal) {
\t\ttry {
\t\t\treturn this.submitAdmitted(activation, content, source, parent, signal);
\t\t} catch (error) {
\t\t\tthrow error;
\t\t}
\t}
\tsubmit(activation, content, source, parent) {
\t\tthis.acquireOwnership(parent, activation.childId);
\t\tconst message = createUserMessage({
\t\t\tcontent,
\t\t\tsource
\t\t});
\t\treturn message.id;
\t}
\tsubmitAdmitted(activation, content, source, parent, signal) {
\t\treturn this.submit(activation, content, source, parent);
\t}
\tasync startContinuable(spec) {
\t\tconst childId = SessionId(randomUUID());
\t\tconst delegatedPolicies = captureDelegatedPolicyOverrides(parent);
\t\tconst activation = {};
\t\tconst parent = {};
\t\tconst request = { prompt: [] };
\t\tconst materialized = {
\t\t\t\t\tcomposition: {
\t\t\t\t\t\tpersona: request.persona,
\t\t\t\t\t\ttoolFilter: request.toolFilter
\t\t\t\t\t},
\t\t};
\t\treturn this.submitMaterialized(activation, request.prompt, { kind: "user" }, parent, spec.signal);
\t}
\tasync materializeTracked(inputs, parentLineage) {
\t\tconst { childId, provider, parent, create } = inputs;
\t\tconst setup = (childCtx) => {
\t\t\tif (create !== void 0) appendDelegatedPolicyOverrides(childCtx.agent.session, create.delegatedPolicies);
\t\t\tapplyChildComposition(childCtx, parent, inputs.composition);
\t\t\treturn this.setupRegistry.apply(childCtx);
\t\t};
\t}
\tinterrupt(targetSessionId, authority) {
\t\tif (authority.kind === "ancestor") {
\t\t\tconst caller = authority.agent;
\t\t\tif (this.ctx.agents.get(caller.id) !== caller) throw new SubagentError("bad", "UNAUTHORIZED");
\t\t}
\t\tconst activation = this.activations.get(targetSessionId);
\t\tif (activation === void 0) return;
\t}
\t/**
\t* Deliver explicitly selected content from one resident continuable child to
\t*/
\tasync reportFrom(child, content, options) {}
\tinterrupt(targetSessionId, authority) {
\t\tthis.continuations?.interrupt(targetSessionId, authority);
\t}
\t/**
\t* Deliver selected content from one live continuable child to its durable
\t*/
\tasync reportFrom(child, content, options) {}
`);
await writeFile(path.join(root, "node_modules/@deepseek-ai/dsh-subagent/lib/types/continuation.d.ts"), `
import { SessionId } from '@deepseek-ai/dsh-session';
import { MessageId } from '@deepseek-ai/dsh-llm';
import type { Agent } from '@deepseek-ai/dsh-agent';
export interface ContinuableStartSpec {
}
export interface SubagentFollowupOptions {
}
export type SubagentInterruptAuthority = unknown;
export declare class SubagentContinuationManager {
    interrupt(targetSessionId: SessionId, authority: SubagentInterruptAuthority): void;
}
`);
await writeFile(path.join(root, "node_modules/@deepseek-ai/dsh-subagent/lib/types/child-agent.d.ts"), `
export declare function childSessionMeta(parent: Agent, childDepth: number, lineageSeedLength: number): X;
export interface ChildComposition {
    readonly persona?: string | undefined;
    readonly toolFilter?: ToolRestriction | undefined;
}
`);
await writeFile(path.join(root, "node_modules/@deepseek-ai/dsh-subagent/lib/types/index.d.ts"), `
import type { SessionId } from '@deepseek-ai/dsh-session';
import type { SubagentInterruptAuthority } from './continuation.ts';
export declare class SubagentRuntime {
    interrupt(targetSessionId: SessionId, authority: SubagentInterruptAuthority): void;
}
`);
await writeFile(path.join(root, "node_modules/@deepseek-ai/dsh-session/lib/index.js"), 'const x = [\n\t"agent-preset/selected",\n];\n');
await writeFile(path.join(root, "node_modules/@deepseek-ai/dsh-session/lib/types/known-event-types.js"), "const x = [\n    'agent-preset/selected',\n];\n");
await writeFile(path.join(root, "node_modules/@deepseek-ai/dsh-web-app/cordis.patch.yml"), "[]\n");

await patchRuntime(root);
await patchRuntime(root);

const subagent = await readFile(path.join(root, "node_modules/@deepseek-ai/dsh-subagent/lib/index.js"), "utf8");
assert.match(subagent, /childCwd = cwd \?\? parentHeader\.cwd/);
assert.match(subagent, /spec\.cwd/);
assert.match(subagent, /childAgentPreset = agentPreset \?\? inheritedAgentPreset/);
assert.match(subagent, /spec\.agentPreset/);
assert.match(subagent, /const childId = spec\.childId \?\? SessionId\(randomUUID\(\)\)/);
assert.match(subagent, /spec\.sandboxMode !== void 0 \? \{ sandboxMode: spec\.sandboxMode \} : \{\}/);
assert.match(subagent, /inputs\.composition\.agentPreset !== void 0\) await childCtx\.get\("agentPresets"\)\?\.mount/);
assert.match(subagent, /descriptor\.label\.startsWith\("__dsh_agent_platform__:"\).*loaded\.meta\.agentPreset/s);
assert.match(subagent, /function createContinuableMessage\(content, source, messageId\)/);
assert.match(subagent, /spec\.signal, spec\.messageId/);
assert.match(subagent, /options\.messageId/);
assert.match(subagent, /activation\.handle\.agent\.session\.events\.some\(\(event\) => event\.type === "user\/message" && event\.data\?\.id === message\.id\)/);
assert.match(subagent, /activation\.handle\.agent\.inbox\.remove\(message\.id\)/);
assert.match(subagent, /async disposeContinuable\(targetSessionId, authority\)/);
assert.match(subagent, /return this\.continuations\?\.disposeContinuable\(targetSessionId, authority\)/);
assert.match(subagent, /function assertAgentPlatformFollowup\(descriptor, source, childId\)/);
assert.match(subagent, /source\.kind === "plugin" && source\.plugin === "agent-platform"/);
assert.match(subagent, /assertAgentPlatformFollowup\(descriptor, options\.source, childId\)/);
assert.match(subagent, /descriptor\.label\.startsWith\("__dsh_agent_platform__:"\).*options\.agentOptions\?\.maxTokens/s);
const continuationTypes = await readFile(path.join(root, "node_modules/@deepseek-ai/dsh-subagent/lib/types/continuation.d.ts"), "utf8");
assert.match(continuationTypes, /readonly childId\?: SessionId/);
assert.match(continuationTypes, /readonly messageId\?: MessageId/);
assert.match(continuationTypes, /readonly sandboxMode\?: "read-only" \| "workspace-write" \| "danger-full-access"/);
assert.match(continuationTypes, /readonly agentPreset\?: string/);
assert.match(continuationTypes, /readonly agentOptions\?: AgentOptions/);
assert.match(continuationTypes, /disposeContinuable\(targetSessionId: SessionId, authority: SubagentInterruptAuthority\): Promise<void>/);
const childAgentTypes = await readFile(path.join(root, "node_modules/@deepseek-ai/dsh-subagent/lib/types/child-agent.d.ts"), "utf8");
assert.match(childAgentTypes, /lineageSeedLength: number, cwd\?: string, agentPreset\?: string/);
assert.match(childAgentTypes, /readonly agentPreset\?: string \| undefined/);
const session = await readFile(path.join(root, "node_modules/@deepseek-ai/dsh-session/lib/index.js"), "utf8");
assert.match(session, /agent-platform\/batches/);
const web = await readFile(path.join(root, "node_modules/@deepseek-ai/dsh-web-app/cordis.patch.yml"), "utf8");
assert.equal(web.match(/@dsh-app\/dsh-agent-platform/g)?.length, 1);
assert.equal(web.match(/@dsh-app\/dsh-tool-workbench/g)?.length, 1);

for (const [name, existing, expected] of [
  ["platform-only", "@dsh-app/dsh-agent-platform", "@dsh-app/dsh-tool-workbench"],
  ["workbench-only", "@dsh-app/dsh-tool-workbench", "@dsh-app/dsh-agent-platform"],
]) {
  const variant = await mkdtemp(path.join(os.tmpdir(), `dsh-agent-patch-${name}-`));
  await cp(root, variant, { recursive: true });
  const patchFile = path.join(variant, "node_modules/@deepseek-ai/dsh-web-app/cordis.patch.yml");
  await writeFile(patchFile, `- insert:\n    - id: existing\n      name: '${existing}'\n`);
  await patchRuntime(variant);
  const patched = await readFile(patchFile, "utf8");
  assert.equal(patched.match(new RegExp(existing.replaceAll("/", "\\/"), "g"))?.length, 1);
  assert.equal(patched.match(new RegExp(expected.replaceAll("/", "\\/"), "g"))?.length, 1);
}

const mismatchedRoot = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-patch-mismatch-"));
await cp(root, mismatchedRoot, { recursive: true });
await writeFile(
  path.join(mismatchedRoot, "node_modules/@deepseek-ai/dsh-subagent/package.json"),
  JSON.stringify({ name: "@deepseek-ai/dsh-subagent", version: "0.1.1-rc.2" }));
await assert.rejects(
  () => patchRuntime(mismatchedRoot),
  /requires @deepseek-ai\/dsh-subagent 0\.1\.0-rc\.6/);

const installedRoot = process.env.DSH_SOURCE;
if (installedRoot !== undefined
    && installedRoot !== ""
    && existsSync(path.join(installedRoot, "package.json"))) {
  const installedManifest = JSON.parse(await readFile(path.join(installedRoot, "package.json"), "utf8"));
  const installedFixture = await mkdtemp(path.join(os.tmpdir(), "dsh-agent-patch-installed-"));
  await mkdir(path.join(installedFixture, "node_modules/@deepseek-ai"), { recursive: true });
  await writeFile(path.join(installedFixture, "package.json"), JSON.stringify({ version: installedManifest.version }));
  for (const name of ["dsh-subagent", "dsh-session", "dsh-web-app"]) {
    await cp(
      path.join(installedRoot, "node_modules/@deepseek-ai", name),
      path.join(installedFixture, "node_modules/@deepseek-ai", name),
      { recursive: true, dereference: true });
  }
  await patchRuntime(installedFixture);
  await patchRuntime(installedFixture);
  const installedSubagent = await readFile(
    path.join(installedFixture, "node_modules/@deepseek-ai/dsh-subagent/lib/index.js"),
    "utf8");
  assert.match(installedSubagent, /function createContinuableMessage\(content, source, messageId\)/);
  assert.match(installedSubagent, /childCwd = cwd \?\? parentHeader\.cwd/);
  assert.match(installedSubagent, /assertAgentPlatformFollowup\(descriptor, options\.source, childId\)/);
  if (installedManifest.version === "0.1.1-rc.2") {
    assert.doesNotMatch(installedSubagent, /async disposeContinuable\(targetSessionId, authority\)/);
    assert.match(installedSubagent, /async drainContinuableChildren\(parent, childIds\)/);
  }
}

console.log("agent-platform-runtime-patch: OK");
