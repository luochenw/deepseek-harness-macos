import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { cp, mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import {
  patchMarker,
  patchRuntime,
  hasPatchMarker,
  markerVersions,
  supportedPiAiVersion,
  supportedPiTelemetryVersion,
  supportedRuntimeVersion,
} from "./patch-llm-runtime.mjs";

/**
 * Fixtures reproduce the shipped runtime sources around every anchor, so this
 * suite fails when the pinned runtime moves and the patch would silently
 * no-op. The B and C tests exercise the patched code paths (the Anthropic call
 * site loop and the projection fold), not just the anchor text.
 */

const scriptRoot = path.dirname(fileURLToPath(import.meta.url));

const piAiTransform = `const NON_VISION_USER_IMAGE_PLACEHOLDER = "(image omitted: model does not support images)";
const NON_VISION_TOOL_IMAGE_PLACEHOLDER = "(tool image omitted: model does not support images)";
const ERROR_TOOL_IMAGE_PLACEHOLDER = "(image attached after the tool results)";
/**
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
}
function replaceImagesWithPlaceholder(content, placeholder) {
    const result = [];
    let previousWasPlaceholder = false;
    for (const block of content) {
        if (block.type === "image") {
            if (!previousWasPlaceholder) {
                result.push({ type: "text", text: placeholder });
            }
            previousWasPlaceholder = true;
            continue;
        }
        result.push(block);
        previousWasPlaceholder = block.text === placeholder;
    }
    return result;
}
export { replaceImagesWithPlaceholder };
`;

const tokenMeterIndex = `const schemaChain = () => {
	const node = {};
	for (const key of ["int", "positive", "nonnegative", "optional", "strict", "max", "min", "transform", "default"]) {
		node[key] = () => node;
	}
	return node;
};
const z$1 = {
	number: schemaChain,
	boolean: schemaChain,
	object: schemaChain
};
function usageOf(event) {
	return event.type === "assistant/message" ? event.data?.usage : void 0;
}
/** Sum disjoint provider usage buckets without double-counting reasoning output. */
function usageTokens(usage) {
	return usage.inputTokens + (usage.cacheReadTokens ?? 0) + (usage.cacheWriteTokens ?? 0) + usage.outputTokens;
}
/** Prompt-side pressure of one request: input plus cache traffic, no output. */
const pressureFrom = (usage) => usage.inputTokens + (usage.cacheReadTokens ?? 0) + (usage.cacheWriteTokens ?? 0);
const contextPressureStateSchema = z$1.object({
	contextWindow: z$1.number().int().positive().optional(),
	pressureTokens: z$1.number().int().nonnegative().optional(),
	surfaceTokens: z$1.number().int().nonnegative(),
	sampledSurfaceTokens: z$1.number().int().nonnegative().optional(),
	claim: z$1.object({})
});
const contextPressureProjectionDefinition = {
	key: "contextPressure",
	stateVersion: 5,
	stateSchema: contextPressureStateSchema,
	init: () => ({ surfaceTokens: 0 }),
	apply: (state, event) => {
		let next = state;
		const usage = usageOf(event);
		if (usage !== void 0) {
			const pressureTokens = pressureFrom(usage);
			if (pressureTokens !== next.pressureTokens) next = {
				...next,
				pressureTokens
			};
		}
		return next;
	},
	wire: { viewSchema: {}, view: (state) => state }
};
var TokenMeter = class {
	states = /* @__PURE__ */ new WeakMap();
	constructor(ctx) {
		this.ctx = ctx;
		this.name = "tokenMeter";
		ctx.sessionProjections.register(contextPressureProjectionDefinition);
	}
	/** Resolve the routed model's image pricing, when the llm service and route declare one. */
	_routeImagePricing(header) {
		const config = header?.config;
		if (config === void 0) return void 0;
		return this.ctx.get("llm")?.imageRequestPricing(config.provider, config.model);
	}
	/** Catch one session's fold up to the current durable tail. */
	_sync(session) {
		let state = this.states.get(session);
		return state;
	}
};
export { TokenMeter, contextPressureProjectionDefinition, pressureFrom, usageTokens };
`;

const tokenMeterUsageProjection = `const schemaChain = () => {
	const node = {};
	for (const key of ["int", "positive", "nonnegative", "optional", "strict", "max", "min", "transform", "default"]) {
		node[key] = () => node;
	}
	return node;
};
const z = {
	number: schemaChain,
	boolean: schemaChain,
	object: schemaChain
};
function usageOf(event) {
	return event.type === "assistant/message" ? event.data?.usage : void 0;
}
/** Prompt-side pressure of one request: input plus cache traffic, no output. */
const pressureFrom = (usage) => usage.inputTokens + (usage.cacheReadTokens ?? 0) + (usage.cacheWriteTokens ?? 0);
const contextPressureStateSchema = z.object({
    contextWindow: z.number().int().positive().optional(),
    pressureTokens: z.number().int().nonnegative().optional(),
    surfaceTokens: z.number().int().nonnegative(),
    sampledSurfaceTokens: z.number().int().nonnegative().optional(),
    claim: z.object({})
});
export const contextPressureProjectionDefinition = {
    key: 'contextPressure',
    stateVersion: 5,
    stateSchema: contextPressureStateSchema,
    init: () => ({ surfaceTokens: 0 }),
    apply: (state, event) => {
        let next = state;
        const usage = usageOf(event);
        if (usage !== undefined) {
            const pressureTokens = pressureFrom(usage);
            if (pressureTokens !== next.pressureTokens) {
                next = { ...next, pressureTokens };
            }
        }
        return next;
    },
    wire: { viewSchema: {}, view: (state) => state },
};
export { pressureFrom };
`;

const llmIndex = `/** Abstract adapter over one wire protocol. */
var LlmAdapter = class {
	imageRequestPricing(_provider, _model) {}
	imageRequestTarget(_provider, _model, image) {
		return {
			width: image.width,
			height: image.height,
			maxBytes: image.bytes
		};
	}
};
var LlmRuntime = class {
		imageRequestPricing(provider, model) {
			return this.adapters.get(provider)?.adapter.imageRequestPricing(provider, model);
		}
	imageRequestTarget(provider, model, image) {
		return this.adapters.get(provider)?.adapter.imageRequestTarget(provider, model, image);
	}
};
export { LlmAdapter, LlmRuntime };
`;

const piAiIndex = `const schemaChain = () => {
	const node = {};
	for (const key of ["int", "positive", "nonnegative", "optional", "strict", "max", "min", "transform", "default"]) {
		node[key] = () => node;
	}
	return node;
};
const z = {
	number: schemaChain,
	boolean: schemaChain,
	object: schemaChain
};
const COMPAT_GATES = {
	"anthropic-messages": {
		supportsEagerToolInputStreaming: "offer",
		supportsLongCacheRetention: "offer",
		supportsCacheControlOnTools: "offer",
		supportsTemperature: "offer",
		forceAdaptiveThinking: "offer",
		allowEmptySignature: "offer",
		supportsStrictTools: "offer"
	}
};
const compatProfile = z.object({
	supportsLongCacheRetention: z.boolean(),
	supportsEagerToolInputStreaming: z.boolean(),
	supportsCacheControlOnTools: z.boolean(),
	supportsTemperature: z.boolean(),
	forceAdaptiveThinking: z.boolean(),
	allowEmptySignature: z.boolean(),
	supportsStrictTools: z.boolean()
});
var PiAiAdapter = class {
	current() { return this.snapshot; }
	modelOf(snapshot, provider, model) { return snapshot.getModel(provider, model); }
	imageRequestTarget(provider, model, image) {
		const snapshot = this.current();
		return { width: image.width, height: image.height, maxBytes: image.bytes };
	}
};
export { PiAiAdapter, COMPAT_GATES, compatProfile };
`;

const fixtureFiles = {
  "node_modules/@earendil-works/pi-ai/dist/api/transform-messages.js": piAiTransform,
  "node_modules/@deepseek-ai/dsh-token-meter/lib/index.js": tokenMeterIndex,
  "node_modules/@deepseek-ai/dsh-token-meter/lib/types/usage-projection.js": tokenMeterUsageProjection,
  "node_modules/@deepseek-ai/dsh-llm/lib/index.js": llmIndex,
  "node_modules/@deepseek-ai/dsh-llm-pi-ai/lib/index.js": piAiIndex,
};
const patchedFiles = Object.keys(fixtureFiles);

async function writeFixtureFile(root, relative, content) {
  await mkdir(path.dirname(path.join(root, relative)), { recursive: true });
  await writeFile(path.join(root, relative), content);
}

async function fixture(prefix = "dsh-llm-patch-") {
  const root = await mkdtemp(path.join(os.tmpdir(), prefix));
  await writeFile(path.join(root, "package.json"), JSON.stringify({ version: supportedRuntimeVersion }));
  for (const name of ["dsh-llm", "dsh-llm-pi-ai", "dsh-token-meter"]) {
    await writeFixtureFile(
      root,
      `node_modules/@deepseek-ai/${name}/package.json`,
      JSON.stringify({ name: `@deepseek-ai/${name}`, version: supportedRuntimeVersion }));
  }
  for (const [name, version] of [
    ["pi-ai", supportedPiAiVersion],
    ["pi-telemetry", supportedPiTelemetryVersion],
  ]) {
    await writeFixtureFile(
      root,
      `node_modules/@earendil-works/${name}/package.json`,
      JSON.stringify({ name: `@earendil-works/${name}`, version }));
  }
  for (const [relative, content] of Object.entries(fixtureFiles)) {
    await writeFixtureFile(root, relative, content);
  }
  return root;
}

const read = (root, relative) => readFile(path.join(root, relative), "utf8");
const patchedPath = (root, relative) => path.join(root, relative);

/** Import a patched module by absolute path, bypassing the fixture's package graph. */
async function importPatched(file) {
  return import(`${file}?v=${Math.random()}`);
}

const sample = { inputTokens: 16781, outputTokens: 12, cacheReadTokens: 16768, cacheWriteTokens: 0 };
const image = (data, mimeType = "image/png") => ({ type: "image", data, mimeType });

test("patching twice is idempotent and every patched file carries the versioned marker", async () => {
  const root = await fixture();
  await patchRuntime(root, { verifyLock: false });
  const afterFirst = await Promise.all(patchedFiles.map((relative) => read(root, relative)));
  await patchRuntime(root, { verifyLock: false });
  for (const [index, relative] of patchedFiles.entries()) {
    assert.equal(await read(root, relative), afterFirst[index], `${relative} must not change on a second run`);
    assert.match(await read(root, relative), new RegExp(patchMarker), `${relative} must carry the marker`);
  }
});

/**
 * The exact `toolResult` branch of pi-ai's `anthropic-messages.js`. The test
 * extracts the same region from a real installed runtime and fails when the two
 * disagree: a copy that silently drifted from the shipped call site would let B
 * regress while the fixture still passed.
 */
const anthropicToolResultLoop = `        else if (msg.role === "toolResult") {
            // Collect all consecutive toolResult messages, needed for z.ai Anthropic endpoint.
            const toolResults = [];
            // Anthropic rejects error tool results that contain anything but text, so their images follow
            // all tool results of the turn, which must come first in the user message (#10794).
            const errorImages = [];
            let j = i;
            while (j < transformedMessages.length && transformedMessages[j].role === "toolResult") {
                const toolMsg = transformedMessages[j];
                const split = splitErrorToolResultImages(toolMsg);
                toolResults.push(convertToolResult(toolMsg, split?.content));
                if (split) {
                    errorImages.push({ type: "text", text: split.caption }, ...split.images.map(convertImageBlock));
                }
                j++;
            }
            // Skip the messages we've already processed.
            i = j - 1;
            params.push({
                role: "user",
                content: [...toolResults, ...errorImages],
            });
        }`;

/** The installed runtime to compare against: explicit copy first, then the App. */
function realAnthropicMessagesPath() {
  const candidates = [
    process.env.DSH_SOURCE === undefined || process.env.DSH_SOURCE === ""
      ? undefined
      : path.join(process.env.DSH_SOURCE, "node_modules/@earendil-works/pi-ai/dist/api/anthropic-messages.js"),
    "/Applications/DeepSeek Harness.app/Contents/Resources/Runtime/dsh/node_modules/@earendil-works/pi-ai/dist/api/anthropic-messages.js",
  ];
  return candidates.find((candidate) => candidate !== undefined && existsSync(candidate));
}

function extractToolResultLoop(source) {
  const start = source.indexOf(`        else if (msg.role === "toolResult") {`);
  assert.notEqual(start, -1, "anthropic-messages.js must still contain the toolResult branch");
  const end = source.indexOf("    flushPendingSystemMessages();", start);
  assert.notEqual(end, -1, "anthropic-messages.js must still end the branch before flushPendingSystemMessages");
  // `flushPendingSystemMessages()` sits after the enclosing for-loop's closing
  // brace, so drop that brace to keep this the branch alone.
  return source.slice(start, end).trimEnd().replace(/\n    \}$/, "");
}

test("B hoists every tool-result image at the anthropic-messages call site, keeping result order", async (t) => {
  const realPath = realAnthropicMessagesPath();
  if (realPath === undefined) {
    t.diagnostic("no installed runtime to compare against; the shipped-call-site check is skipped");
  } else {
    assert.equal(
      extractToolResultLoop(await readFile(realPath, "utf8")),
      anthropicToolResultLoop,
      `the copied anthropic-messages toolResult branch drifted from ${realPath}`);
  }
  const root = await fixture("dsh-llm-patch-callsite-");
  await patchRuntime(root, { verifyLock: false });
  const transformPath = patchedPath(root, "node_modules/@earendil-works/pi-ai/dist/api/transform-messages.js");
  // Execute the shipped branch verbatim (minus its `else`) inside the same
  // bindings the real call site supplies.
  const callSite = path.join(root, "anthropic-call-site.mjs");
  await writeFile(callSite, `import { splitErrorToolResultImages } from ${JSON.stringify(transformPath)};
const convertImageBlock = (block) => ({ type: "image", source: block.data });
const convertToolResult = (msg, content) => ({ type: "tool_result", content: content ?? msg.content });
export function convertToolResults(transformedMessages) {
    const params = [];
    for (let i = 0; i < transformedMessages.length; i += 1) {
        const msg = transformedMessages[i];
${anthropicToolResultLoop.replace(/^        else /, "        ")}
    }
    return params;
}
`);

  const { convertToolResults } = await import(`${callSite}?v=${Math.random()}`);
  const messages = [
    { role: "toolResult", isError: false, toolCallId: "toolu_1", toolName: "bash", content: [{ type: "text", text: "ok" }] },
    { role: "toolResult", isError: false, toolCallId: "toolu_2", toolName: "view_image", content: [image("AA")] },
    { role: "toolResult", isError: true, toolCallId: "toolu_3", toolName: "view_image", content: [image("BB")] },
  ];
  const [{ content }] = convertToolResults(messages);
  assert.deepEqual(
    content.map((block) => block.type),
    ["tool_result", "tool_result", "tool_result", "text", "image", "text", "image"]);
  // The three results stay first and no result keeps an image nested inside it.
  assert.equal(content[0].content[0].text, "ok");
  for (const result of content.slice(0, 3)) {
    assert.equal(result.content.some((block) => block.type === "image"), false);
  }
  assert.match(content[3].text, /Images from the result of tool call toolu_2 \(view_image\):/);
  assert.match(content[5].text, /Images from the result of tool call toolu_3 \(view_image\):/);
  assert.equal(content[4].source, "AA");
  assert.equal(content[6].source, "BB");
});

test("C resolves the cache-read flag per fold: two interleaved sessions never share it", async () => {
  const root = await fixture("dsh-llm-patch-fold-");
  await patchRuntime(root, { verifyLock: false });
  const meter = await importPatched(patchedPath(root, "node_modules/@deepseek-ai/dsh-token-meter/lib/index.js"));
  assert.equal(typeof meter.setRouteIncludesCacheReadResolver, "function");
  // The resolver reads the header it is handed; it holds no session state.
  meter.setRouteIncludesCacheReadResolver(
    (header) => header?.config?.provider === "xpa");
  const events = [
    { session: "a", event: { type: "request/header", data: { header: { config: { provider: "xpa", model: "m" } } } } },
    { session: "b", event: { type: "request/header", data: { header: { config: { provider: "openai-responses", model: "m" } } } } },
    { session: "a", event: { type: "assistant/message", data: { usage: sample } } },
    { session: "b", event: { type: "assistant/message", data: { usage: sample } } },
    { session: "b", event: { type: "request/header", data: { header: { config: { provider: "xpa", model: "m2" } } } } },
    { session: "b", event: { type: "assistant/message", data: { usage: sample } } },
  ];
  const live = { a: meter.contextPressureProjectionDefinition.init(), b: meter.contextPressureProjectionDefinition.init() };
  for (const { session, event } of events) {
    live[session] = meter.contextPressureProjectionDefinition.apply(live[session], event);
  }
  assert.equal(live.a.pressureTokens, sample.inputTokens, "xpa route must not add cache reads twice");
  assert.equal(live.b.pressureTokens, sample.inputTokens, "b switched to xpa on its latest header");
  // Replay the same log from scratch: cold and live values must agree.
  const cold = { a: meter.contextPressureProjectionDefinition.init(), b: meter.contextPressureProjectionDefinition.init() };
  for (const { session, event } of events) {
    cold[session] = meter.contextPressureProjectionDefinition.apply(cold[session], event);
  }
  assert.deepEqual(cold, live, "replayed folds must reproduce the live values");
  // A session whose header predates any header event keeps the legacy formula.
  const legacy = meter.contextPressureProjectionDefinition.apply(
    meter.contextPressureProjectionDefinition.init(),
    { type: "assistant/message", data: { usage: sample } });
  assert.equal(legacy.pressureTokens, sample.inputTokens + sample.cacheReadTokens);
  assert.equal(meter.pressureFrom(sample, false), sample.inputTokens + sample.cacheReadTokens);
  assert.equal(meter.pressureFrom(sample, true), sample.inputTokens);
  assert.equal(
    meter.contextPressureProjectionDefinition.stateVersion,
    7,
    "pressure folds cached at 5 or 6 must rebuild");
});

test("C leaves usage totals and the measure baseline on the original formula", async () => {
  const root = await fixture("dsh-llm-patch-usage-");
  await patchRuntime(root, { verifyLock: false });
  const meter = await importPatched(patchedPath(root, "node_modules/@deepseek-ai/dsh-token-meter/lib/index.js"));
  meter.setRouteIncludesCacheReadResolver(() => true);
  assert.equal(meter.usageTokens(sample), sample.inputTokens + sample.cacheReadTokens + sample.outputTokens);
  const projection = await importPatched(
    patchedPath(root, "node_modules/@deepseek-ai/dsh-token-meter/lib/types/usage-projection.js"));
  projection.setRouteIncludesCacheReadResolver(() => true);
  assert.equal(projection.pressureFrom(sample, true), sample.inputTokens);
  assert.equal(
    projection.contextPressureProjectionDefinition.apply(
      projection.contextPressureProjectionDefinition.init(),
      { type: "request/header", data: { header: { config: { provider: "xpa", model: "m" } } } },
    ).routeIncludesCacheRead,
    true);
  assert.equal(projection.contextPressureProjectionDefinition.stateVersion, 7);
});

test("C resolves through the llm seam and the pi-ai adapter, absent routes included", async () => {
  const root = await fixture("dsh-llm-patch-seam-");
  await patchRuntime(root, { verifyLock: false });
  const llm = await importPatched(patchedPath(root, "node_modules/@deepseek-ai/dsh-llm/lib/index.js"));
  assert.equal(new llm.LlmAdapter().inputTokensIncludeCacheRead("xpa", "m"), false);
  const runtime = new llm.LlmRuntime();
  runtime.adapters = new Map([["xpa", { adapter: { inputTokensIncludeCacheRead: () => true } }]]);
  assert.equal(runtime.inputTokensIncludeCacheRead("xpa", "m"), true);
  runtime.adapters = new Map([["xpa", { adapter: {} }]]);
  assert.equal(runtime.inputTokensIncludeCacheRead("xpa", "m"), false);

  const piAi = await importPatched(patchedPath(root, "node_modules/@deepseek-ai/dsh-llm-pi-ai/lib/index.js"));
  const adapter = new piAi.PiAiAdapter({});
  adapter.snapshot = { getModel: () => ({ compat: { inputTokensIncludeCacheRead: true } }) };
  assert.equal(adapter.inputTokensIncludeCacheRead("xpa", "m"), true);
  adapter.snapshot = { getModel: () => ({ compat: {} }) };
  assert.equal(adapter.inputTokensIncludeCacheRead("xpa", "m"), false);
});

test("C fails soft when the routed provider or model no longer exists", async () => {
  const root = await fixture("dsh-llm-patch-stale-");
  await patchRuntime(root, { verifyLock: false });
  const meter = await importPatched(patchedPath(root, "node_modules/@deepseek-ai/dsh-token-meter/lib/index.js"));
  const ctx = {
    get: (name) => name === "llm"
      ? { inputTokensIncludeCacheRead: () => { throw new Error("UNKNOWN_MODEL"); } }
      : undefined,
  };
  const meterService = new meter.TokenMeter({ sessionProjections: { register() {} } });
  meterService.ctx = ctx;
  assert.equal(
    meterService._routeIncludesCacheRead({ config: { provider: "gone", model: "typo" } }),
    false,
    "a stale route must fall back to the legacy formula instead of throwing");
  assert.equal(meterService._routeIncludesCacheRead(undefined), false);
  assert.equal(meterService._routeIncludesCacheRead({}), false);
});

test("an ambiguous anchor fails closed", async () => {
  const root = await fixture("dsh-llm-patch-ambiguous-");
  const relative = "node_modules/@deepseek-ai/dsh-token-meter/lib/index.js";
  const duplicated = `/** Prompt-side pressure of one request: input plus cache traffic, no output. */
const pressureFrom = (usage) => usage.inputTokens + (usage.cacheReadTokens ?? 0) + (usage.cacheWriteTokens ?? 0);`;
  await writeFile(path.join(root, relative), `${tokenMeterIndex}\n${duplicated}\n`);
  await assert.rejects(() => patchRuntime(root, { verifyLock: false }), /pressure formula anchor is ambiguous/);
});

test("a missing anchor fails closed in every patched file", async () => {
  const cases = [
    ["node_modules/@earendil-works/pi-ai/dist/api/transform-messages.js",
      `const ERROR_TOOL_IMAGE_PLACEHOLDER = "(image attached after the tool results)";`,
      "tool image placeholder"],
    ["node_modules/@deepseek-ai/dsh-token-meter/lib/index.js",
      `const pressureFrom = (usage) => usage.inputTokens + (usage.cacheReadTokens ?? 0) + (usage.cacheWriteTokens ?? 0);`,
      "pressure formula"],
    ["node_modules/@deepseek-ai/dsh-token-meter/lib/types/usage-projection.js",
      `const pressureFrom = (usage) => usage.inputTokens + (usage.cacheReadTokens ?? 0) + (usage.cacheWriteTokens ?? 0);`,
      "usage-projection pressure formula"],
    ["node_modules/@deepseek-ai/dsh-llm/lib/index.js",
      `imageRequestPricing(_provider, _model) {}`,
      "llm adapter hook"],
    ["node_modules/@deepseek-ai/dsh-llm-pi-ai/lib/index.js",
      `forceAdaptiveThinking: z.boolean(),\n\tallowEmptySignature: z.boolean(),`,
      "pi-ai compat schema"],
  ];
  for (const [relative, anchor, label] of cases) {
    const root = await fixture("dsh-llm-patch-missing-");
    const source = await read(root, relative);
    assert.ok(source.includes(anchor), `fixture must contain the ${label} anchor`);
    await writeFile(path.join(root, relative), source.replace(anchor, "/* moved */"));
    await assert.rejects(
      () => patchRuntime(root, { verifyLock: false }),
      new RegExp(`${label} anchor not found`),
      `${relative} must fail closed when ${label} moves`);
  }
});

test("a marker without every patched feature fails closed", async () => {
  const root = await fixture("dsh-llm-patch-partial-");
  await patchRuntime(root, { verifyLock: false });
  const relative = "node_modules/@deepseek-ai/dsh-token-meter/lib/index.js";
  const source = await read(root, relative);
  await writeFile(path.join(root, relative), source.replace("stateVersion: 7,", "stateVersion: 5,"));
  await assert.rejects(
    () => patchRuntime(root, { verifyLock: false }),
    /carries dsh-llm-runtime-patch-v2 but is missing the patched feature "stateVersion: 7,"/);
});

test("a file carrying the old unversioned marker is rejected", async () => {
  const root = await fixture("dsh-llm-patch-legacy-");
  const relative = "node_modules/@earendil-works/pi-ai/dist/api/transform-messages.js";
  await writeFile(path.join(root, relative), `// dsh-llm-runtime-patch\n${piAiTransform}`);
  await assert.rejects(
    () => patchRuntime(root, { verifyLock: false }),
    /carries "dsh-llm-runtime-patch" revision \(unversioned\), not dsh-llm-runtime-patch-v2/);
});

test("a future marker revision like -v20 is not accepted as -v2", async () => {
  const root = await fixture("dsh-llm-patch-v20-");
  const relative = "node_modules/@earendil-works/pi-ai/dist/api/transform-messages.js";
  await writeFile(path.join(root, relative), `// dsh-llm-runtime-patch-v20\n${fixtureFiles[relative]}`);
  await assert.rejects(
    () => patchRuntime(root, { verifyLock: false }),
    /carries "dsh-llm-runtime-patch" revision v20, not dsh-llm-runtime-patch-v2/);
  assert.equal(hasPatchMarker("dsh-llm-runtime-patch-v20"), false);
  assert.equal(hasPatchMarker(`${patchMarker}\ndsh-llm-runtime-patch-v20`), true);
  assert.deepEqual(markerVersions("dsh-llm-runtime-patch-v2 dsh-llm-runtime-patch"), ["v2", ""]);
});

test("pi-ai version drift is reported with expected and actual versions", async () => {
  const root = await fixture("dsh-llm-patch-piai-");
  await writeFile(
    path.join(root, "node_modules/@earendil-works/pi-ai/package.json"),
    JSON.stringify({ name: "@earendil-works/pi-ai", version: "9.9.9" }));
  const expected = [supportedPiAiVersion].map((version) => version.replaceAll(".", "\\.")).join(" or ");
  await assert.rejects(
    () => patchRuntime(root, { verifyLock: false }),
    new RegExp(`requires @earendil-works/pi-ai ${expected}, found 9\\.9\\.9`));
});

/** A lock file describing the synthetic fixture bytes, so prepare can validate. */
async function fixtureLock(root) {
  const digests = await fileDigests(root, patchedFiles);
  return JSON.stringify({
    dshVersion: supportedRuntimeVersion,
    piAiVersion: supportedPiAiVersion,
    piTelemetryVersion: supportedPiTelemetryVersion,
    patchedFiles: patchedFiles.map((relative) => ({ path: relative, pristineSha256: digests[relative] })),
  }, null, 2);
}

/** sha256 of every patched file in `root`, keyed by relative path. */
async function fileDigests(root, relatives) {
  const digests = {};
  for (const relative of relatives) {
    digests[relative] = createHash("sha256").update(await read(root, relative)).digest("hex");
  }
  return digests;
}

test("prepare-dsh-runtime patches a DSH_SOURCE copy and leaves the source untouched", async () => {
  const sourceRoot = await fixture("dsh-llm-patch-source-");
  await writeFixtureFile(sourceRoot, "lib/bin.js", "");
  for (const dependency of ["dsh-subagent", "dsh-session", "dsh-web-app"]) {
    await writeFixtureFile(
      sourceRoot,
      `node_modules/@deepseek-ai/${dependency}/package.json`,
      JSON.stringify({ name: `@deepseek-ai/${dependency}`, version: supportedRuntimeVersion }));
  }
  const lockFile = path.join(sourceRoot, "fixture-lock.json");
  await writeFile(lockFile, await fixtureLock(sourceRoot));
  const before = await fileDigests(sourceRoot, patchedFiles);
  const cacheRoot = await mkdtemp(path.join(os.tmpdir(), "dsh-llm-patch-cache-"));
  const env = {
    ...process.env,
    DSH_SOURCE: sourceRoot,
    DSH_RUNTIME_CACHE: cacheRoot,
    DSH_RUNTIME_LOCK: lockFile,
  };
  const patched = spawnSync(path.join(scriptRoot, "prepare-dsh-runtime.sh"), {
    env,
    encoding: "utf8",
    timeout: 60_000,
  });
  assert.equal(patched.status, 0, patched.stderr);
  // The printed path is the copy, never the caller's directory.
  const copy = patched.stdout.trim();
  assert.notEqual(copy, sourceRoot, "prepare must not hand back the caller's DSH_SOURCE");
  assert.ok(copy.startsWith(cacheRoot), `the copy must live under the cache: ${copy}`);
  // The source is byte-identical and still carries no patch marker.
  assert.deepEqual(await fileDigests(sourceRoot, patchedFiles), before, "DSH_SOURCE must not be modified");
  for (const relative of patchedFiles) {
    assert.doesNotMatch(await read(sourceRoot, relative), /dsh-llm-runtime-patch/);
    assert.match(await read(copy, relative), new RegExp(patchMarker), `${relative} must be patched in the copy`);
  }
  // usageTokens must stay the original formula in the copy.
  assert.match(
    await read(copy, "node_modules/@deepseek-ai/dsh-token-meter/lib/index.js"),
    /function usageTokens\(usage\) \{\n\treturn usage\.inputTokens \+ \(usage\.cacheReadTokens \?\? 0\) \+ \(usage\.cacheWriteTokens \?\? 0\) \+ usage\.outputTokens;\n\}/);
  // Idempotent: a second prepare leaves the same bytes and the same copy path.
  const copyBefore = await fileDigests(copy, patchedFiles);
  const again = spawnSync(path.join(scriptRoot, "prepare-dsh-runtime.sh"), { env, encoding: "utf8", timeout: 60_000 });
  assert.equal(again.status, 0, again.stderr);
  assert.equal(again.stdout.trim(), copy, "the copy path must be stable across runs");
  assert.deepEqual(await fileDigests(copy, patchedFiles), copyBefore, "the copy must be idempotent");
  assert.deepEqual(await fileDigests(sourceRoot, patchedFiles), before);

  // A DSH_SOURCE whose anchors moved must abort, not ship a pristine runtime.
  const broken = await fixture("dsh-llm-patch-source-broken-");
  await writeFixtureFile(broken, "lib/bin.js", "");
  for (const dependency of ["dsh-subagent", "dsh-session", "dsh-web-app"]) {
    await writeFixtureFile(
      broken,
      `node_modules/@deepseek-ai/${dependency}/package.json`,
      JSON.stringify({ name: `@deepseek-ai/${dependency}`, version: supportedRuntimeVersion }));
  }
  const transform = "node_modules/@earendil-works/pi-ai/dist/api/transform-messages.js";
  const brokenContents = piAiTransform.replace("if (!msg.isError)", "if (msg.isError === true)");
  await writeFile(path.join(broken, transform), brokenContents);
  await writeFile(path.join(broken, "fixture-lock.json"), await fixtureLock(broken));
  const failed = spawnSync(path.join(scriptRoot, "prepare-dsh-runtime.sh"), {
    env: { ...env, DSH_SOURCE: broken, DSH_RUNTIME_LOCK: path.join(broken, "fixture-lock.json") },
    encoding: "utf8",
    timeout: 60_000,
  });
  assert.notEqual(failed.status, 0, "a missing anchor must fail the prepare");
  assert.match(failed.stderr, /tool result image split anchor not found|tool image placeholder anchor not found/);
  for (const relative of patchedFiles) {
    const expected = relative === transform ? brokenContents : fixtureFiles[relative];
    assert.equal(await read(broken, relative), expected, `a failed prepare must not touch the source (${relative})`);
  }
});

test("the real prepared runtime, when DSH_SOURCE points at one, accepts the patch", async () => {
  const installedRoot = process.env.DSH_SOURCE;
  if (installedRoot === undefined || installedRoot === "" || !existsSync(path.join(installedRoot, "package.json"))) {
    return;
  }
  const installedManifest = JSON.parse(await readFile(path.join(installedRoot, "package.json"), "utf8"));
  assert.equal(installedManifest.version, supportedRuntimeVersion);
  const installedFixture = await fixture("dsh-llm-patch-installed-");
  for (const relative of [
    ...patchedFiles,
    "node_modules/@earendil-works/pi-ai/package.json",
    "node_modules/@earendil-works/pi-telemetry/package.json",
  ]) {
    await cp(path.join(installedRoot, relative), path.join(installedFixture, relative), { dereference: true });
  }
  await patchRuntime(installedFixture, { verifyLock: false });
  await patchRuntime(installedFixture, { verifyLock: false });
  assert.match(
    await read(installedFixture, "node_modules/@earendil-works/pi-ai/dist/api/transform-messages.js"),
    /TOOL_IMAGE_PLACEHOLDER/);
  assert.match(
    await read(installedFixture, "node_modules/@deepseek-ai/dsh-token-meter/lib/index.js"),
    /setRouteIncludesCacheReadResolver/);
});
