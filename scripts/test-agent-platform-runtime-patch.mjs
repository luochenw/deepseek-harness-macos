import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { cp, mkdtemp, mkdir, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { patchRuntime, supportedRuntimeVersion } from "./patch-agent-platform-runtime.mjs";
import * as childSessionGuard from "../macos/Runtime-extras/dsh-tool-child-session-guard/lib/index.js";

async function fixture(prefix = "dsh-agent-patch-") {
  const root = await mkdtemp(path.join(os.tmpdir(), prefix));
  await mkdir(path.join(root, "node_modules/@deepseek-ai/dsh-session/lib/types"), { recursive: true });
  await mkdir(path.join(root, "node_modules/@deepseek-ai/dsh-web-app"), { recursive: true });
  await writeFile(path.join(root, "package.json"), JSON.stringify({ version: supportedRuntimeVersion }));
  for (const name of ["dsh-session", "dsh-web-app"]) {
    await writeFile(
      path.join(root, "node_modules/@deepseek-ai", name, "package.json"),
      JSON.stringify({ name: `@deepseek-ai/${name}`, version: supportedRuntimeVersion }));
  }
  await writeFile(
    path.join(root, "node_modules/@deepseek-ai/dsh-session/lib/index.js"),
    'const x = [\n\t"agent-preset/selected",\n];\n');
  await writeFile(
    path.join(root, "node_modules/@deepseek-ai/dsh-session/lib/types/known-event-types.js"),
    "const x = [\n    'agent-preset/selected',\n];\n");
  // The patch anchors its rows on the preset registry, so the fixture runtime
  // carries the same anchor a real dsh-web-app ships.
  await writeFile(
    path.join(root, "node_modules/@deepseek-ai/dsh-web-app/cordis.patch.yml"),
    "- insert:\n    - id: agent-preset-registry\n      name: '@deepseek-ai/dsh-agent-preset-registry'\n");
  return root;
}

const root = await fixture();
await patchRuntime(root);
await patchRuntime(root);

const session = await readFile(
  path.join(root, "node_modules/@deepseek-ai/dsh-session/lib/index.js"),
  "utf8");
assert.equal(session.match(/agent-platform\/batches/g)?.length, 1);
assert.match(session, /"agent-platform\/batches",\n\t"agent-preset\/selected"/);
const eventTypes = await readFile(
  path.join(root, "node_modules/@deepseek-ai/dsh-session/lib/types/known-event-types.js"),
  "utf8");
assert.equal(eventTypes.match(/agent-platform\/batches/g)?.length, 1);

const web = await readFile(
  path.join(root, "node_modules/@deepseek-ai/dsh-web-app/cordis.patch.yml"),
  "utf8");
assert.equal(web.match(/@dsh-app\/dsh-agent-platform/g)?.length, 1);
assert.equal(web.match(/@dsh-app\/dsh-tool-workbench/g)?.length, 1);
assert.equal(web.match(/@dsh-app\/dsh-tool-child-session-guard/g)?.length, 1);
// Anchored above the preset registry, not appended after it: the row order is
// what tells a reader (and the loader) this gate belongs to the preset layer.
assert.match(
  web,
  /- id: dsh-tool-child-session-guard\n      name: '@dsh-app\/dsh-tool-child-session-guard'\n\n- insert:\n    - id: agent-preset-registry/);

for (const [name, existing, expected] of [
  ["platform-only", "@dsh-app/dsh-agent-platform", "@dsh-app/dsh-tool-workbench"],
  ["workbench-only", "@dsh-app/dsh-tool-workbench", "@dsh-app/dsh-agent-platform"],
]) {
  const variant = await fixture(`dsh-agent-patch-${name}-`);
  const patchFile = path.join(variant, "node_modules/@deepseek-ai/dsh-web-app/cordis.patch.yml");
  await writeFile(
    patchFile,
    `- insert:\n    - id: existing\n      name: '${existing}'\n`
      + "- insert:\n    - id: agent-preset-registry\n      name: '@deepseek-ai/dsh-agent-preset-registry'\n");
  await patchRuntime(variant);
  const patched = await readFile(patchFile, "utf8");
  assert.equal(patched.match(new RegExp(existing.replaceAll("/", "\\/"), "g"))?.length, 1);
  assert.equal(patched.match(new RegExp(expected.replaceAll("/", "\\/"), "g"))?.length, 1);
}

const mismatchedRoot = await fixture("dsh-agent-patch-mismatch-");
await writeFile(
  path.join(mismatchedRoot, "node_modules/@deepseek-ai/dsh-session/package.json"),
  JSON.stringify({ name: "@deepseek-ai/dsh-session", version: "0.1.0-rc.7" }));
await assert.rejects(
  () => patchRuntime(mismatchedRoot),
  new RegExp(`requires @deepseek-ai/dsh-session ${supportedRuntimeVersion.replaceAll(".", "\\.")}`));

const oldRuntimeRoot = await fixture("dsh-agent-patch-old-runtime-");
await writeFile(path.join(oldRuntimeRoot, "package.json"), JSON.stringify({ version: "0.1.0-rc.7" }));
await assert.rejects(
  () => patchRuntime(oldRuntimeRoot),
  new RegExp(`requires @deepseek-ai/dsh ${supportedRuntimeVersion.replaceAll(".", "\\.")}`));

// A runtime that renamed or dropped the anchor must fail the patch instead of
// silently shipping without the confirmation gate.
const noAnchorRoot = await fixture("dsh-agent-patch-no-anchor-");
const noAnchorFile = path.join(noAnchorRoot, "node_modules/@deepseek-ai/dsh-web-app/cordis.patch.yml");
await writeFile(noAnchorFile, "- insert:\n    - id: some-other-row\n      name: 'x'\n");
await assert.rejects(
  () => patchRuntime(noAnchorRoot),
  /child-session guard row anchor not found/);

// The gate itself: exactly the two tools that open a child session are asked
// about, everything else passes straight through, and a refusal is worded so
// the model continues in the current session instead of retrying.
function guardProbe({ policy = "ask", outcome = "allowed-once" } = {}) {
  const asked = [];
  let handler;
  childSessionGuard.apply({
    approval: {
      // `effectivePolicy` folds the session override and the configured default;
      // `never` (full access) must not ask, or the child could never start.
      effectivePolicy: () => policy,
      request: async (req) => {
        asked.push(req);
        return outcome;
      },
    },
    tools: {},
    on(event, callback) {
      if (event === "tools/pre-execute") handler = callback;
    },
  });
  const run = (name, args = {}) => handler(
    { name, callId: `call-${name}`, agent: {}, arguments: args },
    () => ({ kind: "allow" }));
  return { asked, run };
}

for (const name of ["subagent", "subagent_fork"]) {
  const probe = guardProbe();
  assert.deepEqual(await probe.run(name, { description: "查文档", prompt: "..." }), { kind: "allow" });
  assert.equal(probe.asked.length, 1, `${name} must ask before opening a child session`);
  assert.equal(probe.asked[0].toolName, name);
  assert.equal(probe.asked[0].callId, `call-${name}`);
  assert.match(probe.asked[0].reason, /查文档/);
}

for (const name of ["send_message", "interrupt_agent", "list_agents", "bash", "read"]) {
  const probe = guardProbe();
  assert.deepEqual(await probe.run(name), { kind: "allow" }, `${name} must not be gated`);
  assert.equal(probe.asked.length, 0, `${name} must not ask`);
}

// Full access mode never prompts: an `ask` there is rejected outright, which
// would make the child session impossible to open.
const neverPolicy = guardProbe({ policy: "never" });
assert.deepEqual(await neverPolicy.run("subagent"), { kind: "allow" });
assert.equal(neverPolicy.asked.length, 0);

const refused = guardProbe({ outcome: "rejected" });
const refusal = await refused.run("subagent", { description: "做事" });
assert.equal(refusal.kind, "deny");
assert.match(refusal.reason, /用户选择在当前会话完成，不要再开子会话。/);

const installedRoot = process.env.DSH_SOURCE;
if (installedRoot !== undefined
    && installedRoot !== ""
    && existsSync(path.join(installedRoot, "package.json"))) {
  const installedManifest = JSON.parse(await readFile(path.join(installedRoot, "package.json"), "utf8"));
  assert.equal(installedManifest.version, supportedRuntimeVersion);
  const installedFixture = await fixture("dsh-agent-patch-installed-");
  for (const name of ["dsh-session", "dsh-web-app"]) {
    await cp(
      path.join(installedRoot, "node_modules/@deepseek-ai", name),
      path.join(installedFixture, "node_modules/@deepseek-ai", name),
      { recursive: true, dereference: true });
  }
  await patchRuntime(installedFixture);
  await patchRuntime(installedFixture);
  const installedSession = await readFile(
    path.join(installedFixture, "node_modules/@deepseek-ai/dsh-session/lib/index.js"),
    "utf8");
  assert.match(installedSession, /agent-platform\/batches/);
}

console.log("agent-platform-runtime-patch: OK");
