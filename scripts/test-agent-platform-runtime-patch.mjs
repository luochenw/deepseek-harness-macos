import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { cp, mkdtemp, mkdir, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { patchRuntime, supportedRuntimeVersion } from "./patch-agent-platform-runtime.mjs";

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
  await writeFile(path.join(root, "node_modules/@deepseek-ai/dsh-web-app/cordis.patch.yml"), "[]\n");
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

for (const [name, existing, expected] of [
  ["platform-only", "@dsh-app/dsh-agent-platform", "@dsh-app/dsh-tool-workbench"],
  ["workbench-only", "@dsh-app/dsh-tool-workbench", "@dsh-app/dsh-agent-platform"],
]) {
  const variant = await fixture(`dsh-agent-patch-${name}-`);
  const patchFile = path.join(variant, "node_modules/@deepseek-ai/dsh-web-app/cordis.patch.yml");
  await writeFile(patchFile, `- insert:\n    - id: existing\n      name: '${existing}'\n`);
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
