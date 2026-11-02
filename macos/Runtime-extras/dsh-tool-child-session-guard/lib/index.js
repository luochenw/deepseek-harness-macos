import { askReason, descriptionOf, rejectionText, shouldAsk } from "./core.js";

export const name = "tool-child-session-guard";
export const inject = ["approval", "tools"];

/**
 * Ask the user before the model opens a child session.
 *
 * The approval is requested here rather than returned as `kind: "ask"` because
 * the outcome decides the model-facing text: dsh-tools renders a rejection as
 * "the user rejected tool ...", which reads like a retry hint, while a refusal
 * must tell the model to finish in the current session instead. Asking through
 * the approval seam directly keeps the `approval/asked` + `approval/decided`
 * audit pair and lets this gate choose the denial reason.
 */
export function apply(ctx) {
  ctx.on("tools/pre-execute", async (exec, next) => {
    const agent = exec.agent;
    if (agent === undefined) return next();
    const policy = ctx.approval.effectivePolicy(agent.session);
    if (!shouldAsk(exec.name, policy)) return next();
    const outcome = await ctx.approval.request({
      agent,
      toolName: exec.name,
      callId: exec.callId,
      reason: askReason(descriptionOf(exec)),
      // Read by the app (the approval seam ignores extra fields): the model's
      // own label for the card title, and the task text so a delegation the
      // user already sent is recognised instead of asked about twice.
      description: descriptionOf(exec),
      prompt: typeof exec.arguments?.prompt === "string" ? exec.arguments.prompt : "",
      signal: exec.signal,
    });
    if (outcome === "allowed-once") return next();
    if (outcome === "rejected") return { kind: "deny", reason: rejectionText() };
    return {
      kind: "deny",
      reason: `approval for tool "${exec.name}" was ${outcome}`,
    };
  }, { prepend: true });
}
