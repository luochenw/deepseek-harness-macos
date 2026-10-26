import { realpathSync } from "node:fs";
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
export const supportedRuntimeVersion = (
  await readFile(path.join(root, "scripts/dsh-runtime-version.txt"), "utf8")
).trim();

function replaceOnce(source, before, after, label) {
  const first = source.indexOf(before);
  if (first < 0) throw new Error(`runtime patch: ${label} anchor not found`);
  if (source.indexOf(before, first + before.length) >= 0) {
    throw new Error(`runtime patch: ${label} anchor is ambiguous`);
  }
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
    throw new Error(`runtime patch cannot read @deepseek-ai/${name} metadata`, { cause: error });
  }
  if (manifest.version !== expectedVersion) {
    throw new Error(
      `runtime patch requires @deepseek-ai/${name} ${expectedVersion}, found ${String(manifest.version)}`,
    );
  }
}

export async function patchRuntime(runtimeRoot) {
  const manifestPath = path.join(runtimeRoot, "package.json");
  const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  if (manifest.version !== supportedRuntimeVersion) {
    throw new Error(
      `runtime patch requires @deepseek-ai/dsh ${supportedRuntimeVersion}, found ${String(manifest.version)}`,
    );
  }
  for (const name of ["dsh-session", "dsh-web-app"]) {
    await assertPackageVersion(runtimeRoot, name, manifest.version);
  }

  // The plugin's replayable projection event predates DSH's plugin-prefixed
  // event convention and must remain registered to read existing logs.
  const sessionRoot = path.join(runtimeRoot, "node_modules/@deepseek-ai/dsh-session");
  for (const relative of ["lib/index.js", "lib/types/known-event-types.js"]) {
    await patchFile(path.join(sessionRoot, relative), (source) => {
      if (source.includes('"agent-platform/batches"') || source.includes("'agent-platform/batches'")) {
        return source;
      }
      const quote = relative.endsWith("known-event-types.js") ? "'" : '"';
      const anchor = `${quote}agent-preset/selected${quote},`;
      return replaceOnce(
        source,
        anchor,
        `${quote}agent-platform/batches${quote},\n\t${anchor}`,
        `${relative} known event`,
      );
    });
  }

  const webPatch = path.join(runtimeRoot, "node_modules/@deepseek-ai/dsh-web-app/cordis.patch.yml");
  await patchFile(webPatch, (source) => {
    const additions = [];
    if (!source.includes("@dsh-app/dsh-agent-platform")) {
      additions.push(`# Native macOS unified Agent Profile / Runtime / Batch coordinator.
- insert:
    - id: dsh-agent-platform
      name: '@dsh-app/dsh-agent-platform'
      config:
        root: !!js dshHomePath('agent-platform')`);
    }
    if (!source.includes("@dsh-app/dsh-tool-workbench")) {
      additions.push(`# Model-facing requests for native workbench browser and Markdown tabs.
- insert:
    - id: dsh-tool-workbench
      name: '@dsh-app/dsh-tool-workbench'`);
    }
    if (additions.length === 0) return source;
    return `${source.trimEnd()}

${additions.join("\n\n")}
`;
  });
}

if (process.argv[1] !== undefined
    && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) {
  const runtimeRoot = process.argv[2];
  if (!runtimeRoot) throw new Error("usage: patch-agent-platform-runtime.mjs <Runtime/dsh>");
  await patchRuntime(runtimeRoot);
}
