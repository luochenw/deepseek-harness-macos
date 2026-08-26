import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const ANALYSIS_TOOLS = {
  dsh: ["read", "read_image", "glob", "grep", "web_search", "web_fetch", "skill", "ask_user_question", "get_goal"],
  "claude-code": ["Read", "Grep", "Glob", "WebFetch", "WebSearch"],
  zcode: ["Read", "Grep", "Glob", "WebFetch", "WebSearch"],
};
const SANDBOX_MODES = new Set(["read-only", "workspace-write", "danger-full-access"]);

export function hasCompleteInitiatingCapabilitySnapshot(value, requireRootCwd = false) {
  return value?.capabilitySnapshotVersion === 1
    && (!requireRootCwd || (typeof value.rootCwd === "string" && value.rootCwd.length > 0))
    && typeof value.sourceCwd === "string"
    && value.sourceCwd.length > 0
    && SANDBOX_MODES.has(value.sandboxMode)
    && typeof value.sourceAgentOptions?.provider === "string"
    && value.sourceAgentOptions.provider.length > 0
    && typeof value.sourceAgentOptions?.model === "string"
    && value.sourceAgentOptions.model.length > 0
    && Array.isArray(value.sourceToolAllowlist)
    && typeof value.sourceAgentPreset === "string"
    && value.sourceAgentPreset.length > 0;
}

export function analysisToolAllowlist(runtime, configured, denied = []) {
  const safe = ANALYSIS_TOOLS[runtime] ?? [];
  const requested = configured ?? safe;
  const allowed = new Set(safe);
  const blocked = new Set(denied);
  return requested.filter((tool) => allowed.has(tool) && !blocked.has(tool));
}

export function dshToolRestriction(mode, binding, availableTools, inheritedTools) {
  const available = new Set(availableTools);
  const inherited = inheritedTools === undefined
    ? undefined
    : new Set(inheritedTools.filter((name) => available.has(name)));
  if (mode === "analysis") {
    const configured = binding.toolAllowlist ?? ANALYSIS_TOOLS.dsh;
    return {
      allow: analysisToolAllowlist("dsh", configured, binding.toolDenylist)
        .filter((name) => available.has(name) && (inherited === undefined || inherited.has(name))),
    };
  }
  const hasAllowlist = binding.toolAllowlist !== undefined;
  const allow = (binding.toolAllowlist ?? [...inherited ?? []])
    .filter((name) => available.has(name) && (inherited === undefined || inherited.has(name)));
  const deny = [...new Set((binding.toolDenylist ?? [])
    .filter((name) => available.has(name) && (inherited === undefined || inherited.has(name))))];
  if (inherited === undefined && !hasAllowlist && deny.length === 0) return undefined;
  return {
    ...hasAllowlist || inherited !== undefined ? { allow } : {},
    ...deny.length > 0 ? { deny } : {},
  };
}

export function dshAgentOptions(source, binding) {
  const options = {
    ...source?.provider === undefined ? {} : { provider: source.provider },
    ...source?.model === undefined ? {} : { model: source.model },
    ...source?.maxTokens === undefined ? {} : { maxTokens: source.maxTokens },
  };
  if (binding.model) {
    const slash = binding.model.indexOf("/");
    if (slash <= 0) options.model = binding.model;
    else {
      options.provider = binding.model.slice(0, slash);
      options.model = binding.model.slice(slash + 1);
    }
  }
  return Object.keys(options).length === 0 ? undefined : options;
}

export function inheritedToolAllowlist(sourceVisible, compositionVisible) {
  const composition = new Set(compositionVisible);
  return [...new Set(sourceVisible)].filter((name) => composition.has(name));
}

export function initiatingCapabilitySnapshot(agentOptions, agentPreset, toolAllowlist) {
  const provider = agentOptions?.provider;
  const model = agentOptions?.model;
  if (typeof provider !== "string" || provider.length === 0
    || typeof model !== "string" || model.length === 0) {
    throw new Error("initiating Agent model route is unavailable; dispatch requires explicit provider and model snapshots");
  }
  if (typeof agentPreset !== "string" || agentPreset.length === 0) {
    throw new Error("initiating Agent Preset is unavailable; dispatch cannot fall back to the root Agent");
  }
  if (!Array.isArray(toolAllowlist)) {
    throw new Error("initiating Agent tool snapshot is unavailable");
  }
  return {
    sourceAgentOptions: {
      provider,
      model,
      ...agentOptions.maxTokens === undefined ? {} : { maxTokens: agentOptions.maxTokens },
    },
    sourceAgentPreset: agentPreset,
    sourceToolAllowlist: [...toolAllowlist],
  };
}

export function dshChildCwd(sourceCwd, workspacePath) {
  return workspacePath ?? sourceCwd;
}

export function ownsManagedContext(context, sessionId) {
  return sessionId !== undefined
    && [context.rootSessionId, context.parentSessionId, context.ownerSessionId]
      .some((candidate) => candidate === sessionId);
}

export function reusableDshContext(context, key) {
  return context.key === key
    && hasCompleteInitiatingCapabilitySnapshot(context)
    && context.closedAt === undefined
    && context.closeIntent === undefined;
}

export function dshRunPrompt(task, resumeAfterRestart, childSessionId) {
  if (resumeAfterRestart !== true || childSessionId === undefined) return task;
  return [
    "The Host restarted before this Agent Run reached a terminal state.",
    "Continue the interrupted task in this same durable child session and isolated workspace.",
    "Inspect the existing session context and current files first; do not redo work that is already complete.",
    `Original task: ${task}`,
  ].join("\n");
}

function textContent(content) {
  if (!Array.isArray(content)) return "";
  return content
    .filter((block) => block?.type === "text" && typeof block.text === "string")
    .map((block) => block.text)
    .join("\n");
}

export function dshRunSettlement(events, messageId) {
  let turn;
  let matched = false;
  for (const event of events) {
    if (event.type === "turn/start") turn = event.data?.turn;
    if (event.type === "user/message" && event.data?.id === messageId) {
      matched = true;
      break;
    }
  }
  if (!matched || turn === undefined) return undefined;
  const ended = events.find((event) =>
    event.type === "turn/end" && event.data?.turn === turn);
  if (ended === undefined) return undefined;
  const reason = ended.data?.reason?.kind;
  const output = [...events].reverse().find((event) =>
    event.type === "assistant/message" && event.data?.turn === turn);
  const text = textContent(output?.data?.message?.content);
  if (reason === "completed") {
    return { turn, status: "succeeded", ...text ? { output: text } : {} };
  }
  if (reason === "aborted" || reason === "interrupted") {
    return { turn, status: "cancelled", error: reason };
  }
  return { turn, status: "failed", error: reason ?? "unknown turn failure" };
}

export function dshRecoveryDecision(settlement, resumeAfterRestart) {
  if (settlement === undefined) return "deliver";
  if (resumeAfterRestart === true
    && settlement.status === "cancelled"
    && settlement.error === "interrupted") {
    return "continue";
  }
  return "settle";
}

export function runCancellationRequested(status, stopRequested) {
  return stopRequested || status === "stopping" || status === "cancelled";
}

export function externalSandboxPolicy(mode, parentPolicy, workspaceRoot) {
  return {
    mode: mode === "analysis" ? "read-only" : parentPolicy.mode,
    workspaceRoot,
    ...parentPolicy.sessionId === undefined ? {} : { sessionId: parentPolicy.sessionId },
  };
}

export function confineExternalCommand(command, policy, sandbox) {
  if (policy.mode === "danger-full-access") {
    return { ...command, sandboxMode: policy.mode };
  }
  const confined = sandbox.confine([command.command, ...command.args], policy);
  const [wrappedCommand, ...wrappedArgs] = confined.argv;
  if (wrappedCommand === undefined) throw new Error("sandbox returned an empty command");
  return {
    ...command,
    command: wrappedCommand,
    args: wrappedArgs,
    sandboxMode: policy.mode,
    sandboxEnforcement: confined.enforcement,
  };
}

export function isMissingContinuable(error) {
  return error?.code === "NOT_RESUMABLE";
}

export async function startOrResumeReservedContinuable({
  childId,
  messageId,
  established,
  followup,
  start,
}) {
  const accept = (value, created) => {
    if (value.messageId !== messageId) {
      throw new Error(`reserved message id mismatch: expected ${messageId}, got ${value.messageId}`);
    }
    return { ...value, created };
  };
  if (established === true) {
    return accept({
      childId,
      messageId: await followup(childId, messageId),
    }, false);
  }
  try {
    return accept({
      childId,
      messageId: await followup(childId, messageId),
    }, false);
  } catch (error) {
    if (!isMissingContinuable(error)) throw error;
    const created = await start(childId, messageId);
    if (created.childId !== childId) {
      throw new Error(`reserved child id mismatch: expected ${childId}, got ${created.childId}`);
    }
    return accept(created, true);
  }
}

function candidates(runtime) {
  const home = os.homedir();
  if (runtime === "claude-code") return [
    process.env.CLAUDE_CODE_PATH,
    path.join(home, ".local/bin/claude"),
    path.join(home, ".npm-global/bin/claude"),
    "/opt/homebrew/bin/claude",
    "/usr/local/bin/claude",
  ];
  if (runtime === "codex") return [
    process.env.CODEX_PATH,
    path.join(home, ".npm-global/bin/codex"),
    path.join(home, ".local/bin/codex"),
    "/opt/homebrew/bin/codex",
    "/usr/local/bin/codex",
  ];
  if (runtime === "zcode") return [
    process.env.ZCODE_PATH,
    "/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs",
  ];
  return [];
}

export function resolveRuntime(runtime) {
  if (runtime === "dsh") return { available: true, command: "embedded", version: "embedded" };
  for (const candidate of candidates(runtime)) {
    if (candidate && fs.existsSync(candidate)) {
      return {
        available: true,
        command: runtime === "zcode" ? process.execPath : candidate,
        prefix: runtime === "zcode" ? [candidate] : [],
      };
    }
  }
  return { available: false };
}

export function runtimeCapabilities(runtime) {
  if (runtime === "dsh" || runtime === "claude-code" || runtime === "zcode") {
    return { analysisSupported: true, executionSupported: true };
  }
  if (runtime === "codex") return { analysisSupported: false, executionSupported: true };
  return { analysisSupported: false, executionSupported: false };
}

export function adapterCommand(runtime, { mode, task, persona, cwd, binding }) {
  const resolved = resolveRuntime(runtime);
  if (!resolved.available) throw new Error(`runtime-unavailable: ${runtime}`);
  const capabilities = runtimeCapabilities(runtime);
  if (mode === "analysis" && !capabilities.analysisSupported) throw new Error(`unsupported-mode: ${runtime} cannot hard-disable terminal and mutation tools`);
  if (mode === "execution" && !capabilities.executionSupported) throw new Error(`unsupported-mode: ${runtime} does not support execution`);
  if (runtime === "zcode" && binding.model) {
    throw new Error("unsupported-config: zcode headless CLI does not expose a model override");
  }
  if (runtime === "codex" && (binding.toolAllowlist !== undefined || binding.toolDenylist !== undefined)) {
    throw new Error("unsupported-config: codex CLI does not expose per-tool filtering");
  }
  const modelArgs = binding.model ? ["--model", binding.model] : [];
  const allowList = mode === "analysis"
    ? analysisToolAllowlist(runtime, binding.toolAllowlist, binding.toolDenylist)
    : binding.toolAllowlist;
  const allow = allowList?.join(",");
  const deny = binding.toolDenylist?.join(",");
  const taskedPrompt = persona
    ? `Agent Profile persona:\n${persona}\n\nTask:\n${task}`
    : task;
  if (runtime === "claude-code") {
    return {
      command: resolved.command,
      args: [
        "-p", task,
        "--output-format", "stream-json",
        "--verbose",
        ...mode === "analysis" ? ["--safe-mode", "--permission-mode", "plan"] : [],
        ...mode === "execution" ? ["--dangerously-skip-permissions"] : [],
        ...modelArgs,
        ...persona ? ["--append-system-prompt", persona] : [],
        ...mode === "analysis" ? ["--tools", allow ?? ""] : allow ? ["--tools", allow] : [],
        ...deny ? ["--disallowed-tools", deny] : [],
      ],
      cwd,
    };
  }
  if (runtime === "codex") {
    return {
      command: resolved.command,
      args: [
        "exec", "--json", "-C", cwd, "-s", "workspace-write",
        "-c", 'approval_policy="never"',
        ...modelArgs,
        taskedPrompt,
      ],
      cwd,
    };
  }
  if (runtime === "zcode") {
    return {
      command: resolved.command,
      args: [
        ...resolved.prefix,
        "--prompt", taskedPrompt,
        "--cwd", cwd,
        "--json",
        "--mode", mode === "analysis" ? "plan" : "build",
        ...mode === "analysis" ? ["--allowed-tools", allow ?? ""] : allow !== undefined ? ["--allowed-tools", allow] : [],
        ...deny ? ["--disallowed-tools", deny] : [],
      ],
      cwd,
    };
  }
  throw new Error(`unknown runtime: ${runtime}`);
}

export function runtimeStatusRows() {
  return ["dsh", "claude-code", "codex", "zcode"].map((runtime) => {
    const resolved = resolveRuntime(runtime);
    return {
      runtime,
      displayName: runtime === "dsh" ? "DSH" : runtime === "claude-code" ? "Claude Code" : runtime === "codex" ? "Codex" : "ZCode",
      available: resolved.available,
      ...runtimeCapabilities(runtime),
      ...resolved.version ? { version: resolved.version } : {},
      ...resolved.available ? {} : { detail: "Runtime executable was not found." },
    };
  });
}
