import { realpathSync } from "node:fs";
import { readFile, rename, rm, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
export const supportedRuntimeVersion = (
  await readFile(path.join(root, "scripts/dsh-runtime-version.txt"), "utf8")
).trim();

/**
 * Fail-closed runtime patches for model-request image placement (B) and for the
 * context-pressure formula (C). Both target the pinned runtime only; an anchor
 * that no longer matches throws instead of silently shipping an unpatched
 * runtime.
 *
 * ## B — tool-result image placement
 *
 * `splitErrorToolResultImages` in pi-ai's `transform-messages.js` used to split
 * only *error* results. This patch widens it to every tool result, so an image
 * is sent as a sibling block after the tool results instead of being nested
 * inside `tool_result` (where relays price it at raw-payload rates).
 *
 * Scope: only the two call sites that import that function are affected —
 * `anthropic-messages` (the `xpa` route) and Bedrock Claude. `openai-responses`
 * (`openai-responses-shared.js`) and `openai-completions` have their own
 * conversion paths and are **not** covered. Do not assume B fixes those routes.
 *
 * ## C — context pressure
 *
 * A route may declare `compat: { inputTokensIncludeCacheRead: true }` when its
 * `input_tokens` already spans the whole prompt. The pressure fold then omits
 * the cache buckets instead of double-counting them. The flag is folded per
 * session from that session's own `request/header`, never from a module-level
 * global, so interleaved sessions cannot pollute each other and a cold replay
 * reproduces the live value. Only the context-pressure projection changes;
 * `usageTokens` / `totalTokens` keep the original formula.
 *
 * The fold's `stateVersion` moves 5 -> 7. 6 was skipped on purpose: an earlier
 * revision of this patch shipped 6 with a module-level switch that polluted
 * other sessions, and some caches may still hold a 6 row for it, so reusing 6
 * would make those rows look usable. Both 5 and 6 rows are therefore discarded
 * and every session refolds its whole log from seq 0 on its next cold read
 * (slow once, never wrong); installing the unpatched app downgrades the key
 * again and triggers exactly one more full refold.
 */

/** Versioned marker proving a file already carries this patch (idempotency gate). */
export const patchMarker = "dsh-llm-runtime-patch-v2";
/** Marker emitted by previous patch revisions; never reused as a versioned marker. */
const legacyMarker = "dsh-llm-runtime-patch";
/**
 * The only `@earendil-works/pi-ai` release whose `transform-messages.js` anchors
 * this patch matches. `dsh-llm-pi-ai` declares a caret range, so npm can resolve
 * a newer minor; `prepare-dsh-runtime.sh` pins the runtime back to exactly this
 * version instead of widening the gate.
 */
export const supportedPiAiVersions = ["1.3.0"];
/** The pi-telemetry release shipped alongside the pinned pi-ai. */
export const supportedPiTelemetryVersions = ["1.3.0"];
/** The release the pinned runtime resolves to; kept for error text. */
export const supportedPiAiVersion = supportedPiAiVersions[0];
/** The pi-telemetry release this patch pins to. */
export const supportedPiTelemetryVersion = supportedPiTelemetryVersions[0];
/**
 * The five patched files and their pristine digests, read from the lock file.
 * `DSH_RUNTIME_LOCK` lets a caller point at a lock for a non-shipped tree (the
 * tests use it to describe their fixtures); production always uses the pin.
 */
export const runtimeLockPath = process.env.DSH_RUNTIME_LOCK
  ?? path.join(root, "scripts/dsh-runtime-lock.json");
export const runtimeLock = JSON.parse(await readFile(runtimeLockPath, "utf8"));

/** Exact marker match: `-v20` must never be mistaken for `-v2`. */
export function hasPatchMarker(source) {
  return markerVersions(source).includes(patchMarker.slice("dsh-llm-runtime-patch-".length));
}

/** Every patch revision mentioned in `source`, without the shared prefix. */
export function markerVersions(source) {
  const versions = [];
  for (const match of source.matchAll(/dsh-llm-runtime-patch(?:-v(\d+))?(?![\w-])/g)) {
    versions.push(match[1] === undefined ? "" : `v${match[1]}`);
  }
  return versions;
}

function replaceOnce(source, before, after, label) {
  const first = source.indexOf(before);
  if (first < 0) throw new Error(`llm runtime patch: ${label} anchor not found`);
  if (source.indexOf(before, first + before.length) >= 0) {
    throw new Error(`llm runtime patch: ${label} anchor is ambiguous`);
  }
  return source.slice(0, first) + after + source.slice(first + before.length);
}

/**
 * A marker only proves that *some* revision of this patch reached the file, so
 * every patched feature is re-checked textually before the file is accepted.
 * A half-applied file therefore fails closed instead of shipping.
 */
function verifyPatched(spec, source) {
  for (const feature of spec.features) {
    if (!source.includes(feature)) {
      throw new Error(
        `llm runtime patch: ${spec.file} carries ${patchMarker} but is missing the patched `
        + `feature ${JSON.stringify(feature)}; restore a pristine runtime and rerun the patch`,
      );
    }
  }
  for (const original of spec.absent ?? []) {
    if (source.includes(original)) {
      throw new Error(
        `llm runtime patch: ${spec.file} still contains the unpatched fragment `
        + `${JSON.stringify(original)}; restore a pristine runtime and rerun the patch`,
      );
    }
  }
}

/** Write through a sibling temp file so a reader never observes a truncated file. */
async function writeFileAtomic(file, contents) {
  const temp = `${file}.${process.pid}.${Date.now()}.tmp`;
  await writeFile(temp, contents);
  try {
    await rename(temp, file);
  } catch (error) {
    await rm(temp, { force: true });
    throw error;
  }
}

async function patchFile(runtimeRoot, spec) {
  const file = path.join(runtimeRoot, spec.file);
  const original = await readFile(file, "utf8");
  const versions = markerVersions(original);
  if (versions.includes(patchMarker.slice("dsh-llm-runtime-patch-".length))) {
    verifyPatched(spec, original);
    return;
  }
  if (versions.length > 0) {
    throw new Error(
      `llm runtime patch: ${spec.file} carries "${legacyMarker}" revision `
      + `${versions.map((version) => version || "(unversioned)").join(", ")}, not ${patchMarker}; `
      + `restore a pristine runtime`,
    );
  }
  const next = spec.transform(original);
  if (next === original) throw new Error(`llm runtime patch: ${spec.file} did not change`);
  verifyPatched(spec, next);
  await writeFileAtomic(file, next);
}

async function readManifest(manifestPath, label) {
  try {
    return JSON.parse(await readFile(manifestPath, "utf8"));
  } catch (error) {
    throw new Error(`llm runtime patch cannot read ${label} metadata`, { cause: error });
  }
}

async function assertPackageVersion(runtimeRoot, name, expectedVersion) {
  const manifestPath = path.join(runtimeRoot, "node_modules/@deepseek-ai", name, "package.json");
  const manifest = await readManifest(manifestPath, `@deepseek-ai/${name}`);
  if (manifest.version !== expectedVersion) {
    throw new Error(
      `llm runtime patch requires @deepseek-ai/${name} ${expectedVersion}, found ${String(manifest.version)}`,
    );
  }
}

/**
 * pi-ai is pulled in through a caret range by `dsh-llm-pi-ai`, so the installed
 * release is the one variable the anchors cannot pin. Gate it explicitly and
 * name both versions: a drifted pi-ai should fail as "version drift", not as a
 * mysterious missing anchor. Only releases whose affected sources were checked
 * are listed; every transform is still verified feature-by-feature afterwards.
 */
async function assertPiAiVersion(runtimeRoot) {
  for (const name of ["pi-ai", "pi-telemetry"]) {
    const expected = name === "pi-ai" ? supportedPiAiVersion : supportedPiTelemetryVersion;
    const manifestPath = path.join(runtimeRoot, "node_modules/@earendil-works", name, "package.json");
    const manifest = await readManifest(manifestPath, `@earendil-works/${name}`);
    if (manifest.version !== expected) {
      throw new Error(
        `llm runtime patch requires @earendil-works/${name} ${expected}, `
        + `found ${String(manifest.version)}`,
      );
    }
  }
}

/**
 * Compare the runtime with `scripts/dsh-runtime-lock.json`: the dsh version, the
 * two `@earendil-works` releases the anchors depend on, and the pristine digest
 * of every patched file. The digests are only checked while the file is still
 * unpatched — a patched file is verified feature-by-feature instead.
 */
export async function assertRuntimeLock(runtimeRoot, fileStates = new Map()) {
  const manifest = await readManifest(path.join(runtimeRoot, "package.json"), "@deepseek-ai/dsh");
  if (manifest.version !== runtimeLock.dshVersion) {
    throw new Error(
      `llm runtime lock expects @deepseek-ai/dsh ${runtimeLock.dshVersion}, found ${String(manifest.version)}`,
    );
  }
  await assertPiAiVersion(runtimeRoot);
  for (const entry of runtimeLock.patchedFiles) {
    const state = fileStates.get(entry.path);
    if (state === undefined || state.patched) continue;
    if (state.sha256 !== entry.pristineSha256) {
      throw new Error(
        `llm runtime lock expects ${entry.path} sha256 ${entry.pristineSha256}, found ${state.sha256}`,
      );
    }
  }
}

/**
 * B — hoist request images out of `tool_result` content.
 *
 * pi-ai already moves images out of *error* tool results (Anthropic rejects
 * those) and re-emits them as sibling blocks of the same user message, after
 * every tool result of the turn. That is exactly the shape the relay prices
 * correctly, so the smallest correct change widens the existing split from
 * error results to every tool result instead of adding a second conversion
 * path inside the `dsh-llm-pi-ai` adapter (which would have to reproduce
 * pi-ai's turn grouping, caption, and multi-result ordering).
 */
const placeholderAnchor = `const ERROR_TOOL_IMAGE_PLACEHOLDER = "(image attached after the tool results)";`;
const placeholderPatched = `const TOOL_IMAGE_PLACEHOLDER = "[image attached below]"; // ${patchMarker}`;

const splitAnchor = `/**
 * Split the images out of an error tool result, for APIs that reject images in error results
 * (Anthropic, and Claude on Bedrock). Send the returned content as the tool result and the caption and
 * images after all tool results of the turn, in the same user message. Returns undefined for results
 * that need no split (#10794).
 */
export function splitErrorToolResultImages(msg) {
    if (!msg.isError)
        return undefined;
    const images = msg.content.filter((block) => block.type === "image");
    if (images.length === 0)
        return undefined;
    return {
        content: replaceImagesWithPlaceholder(msg.content, ERROR_TOOL_IMAGE_PLACEHOLDER),
        caption: \`Images from the error result of tool call \${msg.toolCallId} (\${msg.toolName}):\`,
        images,
    };
}`;

const splitPatched = `/**
 * Split request images out of one tool result. Anthropic rejects images inside
 * error results, and a nested image is priced at raw-payload rates, so the
 * returned content stays in the tool result while the caption and images move
 * after all tool results of the turn, in the same user message.
 *
 * ${patchMarker}: this now covers every tool result, not only error results.
 * Scope: only the \`anthropic-messages\` (xpa) and Bedrock Claude call sites
 * import this function. \`openai-responses\` and \`openai-completions\` keep their
 * own conversion and are NOT covered by this patch.
 */
export function splitErrorToolResultImages(msg) {
    const images = msg.content.filter((block) => block.type === "image");
    if (images.length === 0)
        return undefined;
    return {
        content: replaceImagesWithPlaceholder(msg.content, TOOL_IMAGE_PLACEHOLDER),
        caption: \`Images from the result of tool call \${msg.toolCallId} (\${msg.toolName}):\`,
        images,
    };
}`;

/**
 * C — context pressure must not add cache traffic twice.
 *
 * The relay reports `input_tokens` as the whole prompt *including* cache reads
 * (measured: two identical requests both report the same input, the second
 * with an equal cache_read). The legacy formula adds the cache buckets on top
 * and reports roughly twice the real prompt. A route opts in with
 * `compat: { inputTokensIncludeCacheRead: true }`.
 *
 * The flag is resolved from each session's own `request/header` event inside
 * the fold and stored on that fold's state. It is deliberately not a
 * module-level switch: `session/event` drives every projection for every
 * session, so a shared switch would let one route's header decide another
 * route's pressure (and replay would depend on event interleaving). A single
 * resolver function is installed once by the TokenMeter service; it reads the
 * header it is handed and touches no per-session state.
 */
const pressureAnchor = `/** Prompt-side pressure of one request: input plus cache traffic, no output. */
const pressureFrom = (usage) => usage.inputTokens + (usage.cacheReadTokens ?? 0) + (usage.cacheWriteTokens ?? 0);`;

const pressurePatched = `// ${patchMarker}: route-declared prompt-size semantics, resolved per fold state
// from that session's own request header. No per-session value lives here.
let routeIncludesCacheReadResolver = () => false;
/** Install the llm-backed resolver that reads one request header's route semantics. */
export function setRouteIncludesCacheReadResolver(resolve) {
    routeIncludesCacheReadResolver = typeof resolve === "function" ? resolve : () => false;
}
/**
 * Prompt-side pressure of one request: input plus cache traffic, no output.
 *
 * Routes whose \`input_tokens\` already spans the whole prompt opt out through
 * \`compat.inputTokensIncludeCacheRead\`; adding the cache buckets there would
 * double-count every cached prompt. The flag travels with the fold state, so
 * two sessions on different routes never share it and replay is reproducible.
 */
const pressureFrom = (usage, includesCacheRead) => includesCacheRead === true
    ? usage.inputTokens
    : usage.inputTokens + (usage.cacheReadTokens ?? 0) + (usage.cacheWriteTokens ?? 0);`;

const stateSchemaAnchor = `\tsampledSurfaceTokens: z$1.number().int().nonnegative().optional(),
\tclaim: z$1.object({`;

const stateSchemaPatched = `\tsampledSurfaceTokens: z$1.number().int().nonnegative().optional(),
\t// ${patchMarker}: folded per session from its own request/header.
\trouteIncludesCacheRead: z$1.boolean().optional(),
\tclaim: z$1.object({`;

const stateVersionAnchor = `const contextPressureProjectionDefinition = {
\tkey: "contextPressure",
\tstateVersion: 5,`;

const stateVersionPatched = `const contextPressureProjectionDefinition = {
\tkey: "contextPressure",
\t// ${patchMarker}: the pressure formula and its per-session flag changed, so folds cached at 5 rebuild.
\tstateVersion: 7,`;

const foldAnchor = `\t\tconst usage = usageOf(event);
\t\tif (usage !== void 0) {
\t\t\tconst pressureTokens = pressureFrom(usage);`;

const foldPatched = `\t\t// ${patchMarker}: remember this route's prompt-size semantics on this fold only.
\t\tif (event.type === "request/header") {
\t\t\tconst includesCacheRead = routeIncludesCacheReadResolver(event.data.header) === true;
\t\t\tif (includesCacheRead !== state.routeIncludesCacheRead) next = {
\t\t\t\t...next,
\t\t\t\trouteIncludesCacheRead: includesCacheRead
\t\t\t};
\t\t}
\t\tconst usage = usageOf(event);
\t\tif (usage !== void 0) {
\t\t\tconst pressureTokens = pressureFrom(usage, next.routeIncludesCacheRead === true);`;

const resolverAnchor = `\t/** Resolve the routed model's image pricing, when the llm service and route declare one. */
\t_routeImagePricing(header) {`;

const resolverPatched = `\t/**
\t* ${patchMarker}: whether the routed model's usage already counts cache reads as input.
\t*
\t* Fail-soft on purpose: a session can outlive its route, and the original
\t* image-pricing lookup never threw for a deleted or misspelled provider/model.
\t* A missing route therefore falls back to the legacy formula instead of making
\t* \`measure()\` unusable.
\t*/
\t_routeIncludesCacheRead(header) {
\t\tconst config = header?.config;
\t\tif (config === void 0) return false;
\t\ttry {
\t\t\treturn this.ctx.get("llm")?.inputTokensIncludeCacheRead(config.provider, config.model) === true;
\t\t} catch {
\t\t\treturn false;
\t\t}
\t}
\t/** Resolve the routed model's image pricing, when the llm service and route declare one. */
\t_routeImagePricing(header) {`;

const installResolverAnchor = `\t\tctx.sessionProjections.register(contextPressureProjectionDefinition);`;

const installResolverPatched = `${installResolverAnchor}
\t\t// ${patchMarker}: the fold asks this resolver about the header it is folding.
\t\tsetRouteIncludesCacheReadResolver((header) => this._routeIncludesCacheRead(header));`;

/** C — the llm seam exposes the switch the adapted route declared. */
const adapterHookAnchor = `\timageRequestPricing(_provider, _model) {}`;
const adapterHookPatched = `${adapterHookAnchor}
\t/** @see ${patchMarker}: whether provider usage already counts cache reads as input. */
\tinputTokensIncludeCacheRead(_provider, _model) {
\t\treturn false;
\t}`;

const runtimeHookAnchor = `\t\timageRequestPricing(provider, model) {
\t\t\treturn this.adapters.get(provider)?.adapter.imageRequestPricing(provider, model);
\t\t}`;
const runtimeHookPatched = `${runtimeHookAnchor}
\t\t/** ${patchMarker}: route-declared prompt-size semantics; absent means keep the old formula. */
\t\tinputTokensIncludeCacheRead(provider, model) {
\t\t\treturn this.adapters.get(provider)?.adapter.inputTokensIncludeCacheRead?.(provider, model) === true;
\t\t}`;

/** C — the pi-ai adapter owns `model.compat`, so it answers the switch. */
const piAiGateAnchor = `\t\tforceAdaptiveThinking: "offer",
\t\tallowEmptySignature: "offer",`;
const piAiGatePatched = `${piAiGateAnchor}
\t\tinputTokensIncludeCacheRead: "offer", // ${patchMarker}`;

const piAiSchemaAnchor = `\tforceAdaptiveThinking: z.boolean(),
\tallowEmptySignature: z.boolean(),`;
const piAiSchemaPatched = `${piAiSchemaAnchor}
\tinputTokensIncludeCacheRead: z.boolean(), // ${patchMarker}`;

const piAiAdapterAnchor = `\timageRequestTarget(provider, model, image) {
\t\tconst snapshot = this.current();`;
const piAiAdapterPatched = `\t/** @see ${patchMarker}: the routed model's declared prompt-size semantics. */
\tinputTokensIncludeCacheRead(provider, model) {
\t\tconst snapshot = this.current();
\t\treturn this.modelOf(snapshot, provider, model).compat?.inputTokensIncludeCacheRead === true;
\t}
\timageRequestTarget(provider, model, image) {
\t\tconst snapshot = this.current();`;

const transformSpec = {
  file: "node_modules/@earendil-works/pi-ai/dist/api/transform-messages.js",
  transform(source) {
    let next = replaceOnce(source, placeholderAnchor, placeholderPatched, "tool image placeholder");
    return replaceOnce(next, splitAnchor, splitPatched, "tool result image split");
  },
  features: [
    `const TOOL_IMAGE_PLACEHOLDER = "[image attached below]";`,
    "export function splitErrorToolResultImages(msg) {\n    const images = msg.content.filter",
    "caption: `Images from the result of tool call ",
    patchMarker,
  ],
  absent: ["ERROR_TOOL_IMAGE_PLACEHOLDER", "if (!msg.isError)"],
};

/**
 * The live bundle. `usageTokens` is intentionally left at the original formula:
 * it feeds `measure()`'s baseline gate and `totalTokens`, which are totals, not
 * prompt pressure. Only the context-pressure fold follows the route flag.
 */
const tokenMeterSpec = {
  file: "node_modules/@deepseek-ai/dsh-token-meter/lib/index.js",
  transform(source) {
    let next = replaceOnce(source, pressureAnchor, pressurePatched, "pressure formula");
    next = replaceOnce(next, stateSchemaAnchor, stateSchemaPatched, "context pressure state schema");
    next = replaceOnce(next, stateVersionAnchor, stateVersionPatched, "context pressure stateVersion");
    next = replaceOnce(next, foldAnchor, foldPatched, "context pressure fold");
    next = replaceOnce(next, resolverAnchor, resolverPatched, "route cache-read resolver");
    return replaceOnce(next, installResolverAnchor, installResolverPatched, "token meter resolver install");
  },
  features: [
    "export function setRouteIncludesCacheReadResolver(resolve)",
    "const pressureFrom = (usage, includesCacheRead) => includesCacheRead === true",
    "routeIncludesCacheReadResolver(event.data.header) === true",
    "routeIncludesCacheRead: z$1.boolean().optional()",
    "_routeIncludesCacheRead(header) {",
    "setRouteIncludesCacheReadResolver((header) => this._routeIncludesCacheRead(header));",
    "stateVersion: 7,",
    // C must not move the usage total: `usageTokens` has to stay byte-for-byte
    // the original formula, or the measure baseline and totalTokens shift.
    "function usageTokens(usage) {\n\treturn usage.inputTokens + (usage.cacheReadTokens ?? 0) + (usage.cacheWriteTokens ?? 0) + usage.outputTokens;\n}",
    patchMarker,
  ],
  absent: ["setInputTokensIncludeCacheRead", "const pressureTokens = pressureFrom(usage);"],
};

/**
 * The unbundled module copy kept for detached readers. It mirrors the live
 * bundle's pressure fold (per-session flag + pure `pressureFrom`); both copies
 * keep the original `usageTokens`, so the two no longer disagree.
 */
const usageProjectionSpec = {
  file: "node_modules/@deepseek-ai/dsh-token-meter/lib/types/usage-projection.js",
  transform(source) {
    let next = replaceOnce(source, pressureAnchor, pressurePatched, "usage-projection pressure formula");
    next = replaceOnce(
      next,
      `    sampledSurfaceTokens: z.number().int().nonnegative().optional(),
    claim: z.object({`,
      `    sampledSurfaceTokens: z.number().int().nonnegative().optional(),
    // ${patchMarker}: folded per session from its own request/header.
    routeIncludesCacheRead: z.boolean().optional(),
    claim: z.object({`,
      "usage-projection state schema",
    );
    next = replaceOnce(
      next,
      `export const contextPressureProjectionDefinition = {
    key: 'contextPressure',
    stateVersion: 5,`,
      `export const contextPressureProjectionDefinition = {
    key: 'contextPressure',
    // ${patchMarker}: the pressure formula and its per-session flag changed, so folds cached at 5 rebuild.
    stateVersion: 7,`,
      "usage-projection stateVersion",
    );
    return replaceOnce(
      next,
      `        const usage = usageOf(event);
        if (usage !== undefined) {
            const pressureTokens = pressureFrom(usage);`,
      `        // ${patchMarker}: remember this route's prompt-size semantics on this fold only.
        if (event.type === 'request/header') {
            const includesCacheRead = routeIncludesCacheReadResolver(event.data.header) === true;
            if (includesCacheRead !== state.routeIncludesCacheRead) {
                next = { ...next, routeIncludesCacheRead: includesCacheRead };
            }
        }
        const usage = usageOf(event);
        if (usage !== undefined) {
            const pressureTokens = pressureFrom(usage, next.routeIncludesCacheRead === true);`,
      "usage-projection fold",
    );
  },
  features: [
    "export function setRouteIncludesCacheReadResolver(resolve)",
    "const pressureFrom = (usage, includesCacheRead) => includesCacheRead === true",
    "routeIncludesCacheReadResolver(event.data.header) === true",
    "routeIncludesCacheRead: z.boolean().optional()",
    "stateVersion: 7,",
    patchMarker,
  ],
  absent: ["setInputTokensIncludeCacheRead", "const pressureTokens = pressureFrom(usage);"],
};

const llmSpec = {
  file: "node_modules/@deepseek-ai/dsh-llm/lib/index.js",
  transform(source) {
    let next = replaceOnce(source, adapterHookAnchor, adapterHookPatched, "llm adapter hook");
    return replaceOnce(next, runtimeHookAnchor, runtimeHookPatched, "llm runtime hook");
  },
  features: [
    "inputTokensIncludeCacheRead(_provider, _model) {",
    "inputTokensIncludeCacheRead(provider, model) {",
    "?.adapter.inputTokensIncludeCacheRead?.(provider, model) === true",
    patchMarker,
  ],
};

const piAiSpec = {
  file: "node_modules/@deepseek-ai/dsh-llm-pi-ai/lib/index.js",
  transform(source) {
    let next = replaceOnce(source, piAiGateAnchor, piAiGatePatched, "pi-ai compat gate");
    next = replaceOnce(next, piAiSchemaAnchor, piAiSchemaPatched, "pi-ai compat schema");
    return replaceOnce(next, piAiAdapterAnchor, piAiAdapterPatched, "pi-ai adapter hook");
  },
  features: [
    `inputTokensIncludeCacheRead: "offer",`,
    "inputTokensIncludeCacheRead: z.boolean(),",
    "compat?.inputTokensIncludeCacheRead === true",
    patchMarker,
  ],
};

export const patchSpecs = [
  transformSpec,
  tokenMeterSpec,
  usageProjectionSpec,
  llmSpec,
  piAiSpec,
];

/** Patched files and whether each already carries this patch marker. */
export async function patchedFileStates(runtimeRoot) {
  const states = new Map();
  for (const spec of patchSpecs) {
    const source = await readFile(path.join(runtimeRoot, spec.file), "utf8");
    states.set(spec.file, {
      patched: hasPatchMarker(source),
      sha256: createHash("sha256").update(source).digest("hex"),
    });
  }
  return states;
}

/**
 * @param runtimeRoot - an installed `Runtime/dsh`.
 * @param options.verifyLock - compare with `dsh-runtime-lock.json` first; tests
 *   that build synthetic fixtures opt out because their file contents are not
 *   the shipped bytes.
 */
export async function patchRuntime(runtimeRoot, options = {}) {
  const { verifyLock = true } = options;
  const manifestPath = path.join(runtimeRoot, "package.json");
  const manifest = await readManifest(manifestPath, "@deepseek-ai/dsh");
  if (manifest.version !== supportedRuntimeVersion) {
    throw new Error(
      `llm runtime patch requires @deepseek-ai/dsh ${supportedRuntimeVersion}, found ${String(manifest.version)}`,
    );
  }
  for (const name of ["dsh-llm", "dsh-llm-pi-ai", "dsh-token-meter"]) {
    await assertPackageVersion(runtimeRoot, name, manifest.version);
  }
  if (verifyLock) await assertRuntimeLock(runtimeRoot, await patchedFileStates(runtimeRoot));
  else await assertPiAiVersion(runtimeRoot);

  for (const spec of patchSpecs) await patchFile(runtimeRoot, spec);
}

if (process.argv[1] !== undefined
    && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) {
  const args = process.argv.slice(2);
  if (args[0] === "--check-lock") {
    const runtimeRoot = args[1];
    if (!runtimeRoot) throw new Error("usage: patch-llm-runtime.mjs --check-lock <Runtime/dsh>");
    await assertRuntimeLock(runtimeRoot, await patchedFileStates(runtimeRoot));
  } else {
    const runtimeRoot = args[0];
    if (!runtimeRoot) throw new Error("usage: patch-llm-runtime.mjs <Runtime/dsh>");
    await patchRuntime(runtimeRoot);
  }
}
