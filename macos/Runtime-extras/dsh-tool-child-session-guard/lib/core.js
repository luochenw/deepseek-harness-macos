/**
 * Decisions behind the child-session confirmation gate, kept free of cordis so
 * they can be tested directly.
 *
 * Opening a child session is the one tool call that creates a whole new
 * conversation, and dsh never asks: the model decides on its own. This gate
 * turns the two child-session tools into an approval question, which the
 * native app renders as a card in the transcript.
 *
 * @module @dsh-app/dsh-tool-child-session-guard/core
 */

/** The tools that start a new child session. Nothing else is gated. */
export const CHILD_SESSION_TOOLS = ["subagent", "subagent_fork"];

/**
 * Model-facing result of a refusal. The model must continue in the current
 * session instead of retrying; the generic `the user rejected tool` text does
 * not say that, so a refused call is rewritten to this.
 */
export const REJECT_TEXT = "用户选择在当前会话完成，不要再开子会话。";

/** Longest description the reason line carries; the card shows it in full. */
export const MAX_DESCRIPTION = 120;

/**
 * Whether a tool name is one that opens a child session.
 * @param name - registered tool name.
 * @returns whether this gate owns that call.
 */
export function isChildSessionTool(name) {
  return typeof name === "string" && CHILD_SESSION_TOOLS.includes(name);
}

function firstLine(text) {
  if (typeof text !== "string") return "";
  return text.trim().split(/\r?\n/u, 1)[0].trim();
}

/**
 * The model's own label for the work, falling back to the prompt's first line
 * so the question is never anonymous.
 * @param exec - the pre-execute execution (arguments already materialized).
 * @returns a one-line description, possibly empty.
 */
export function descriptionOf(exec) {
  const args = exec?.arguments;
  const description = firstLine(args?.description);
  return (description || firstLine(args?.prompt)).slice(0, MAX_DESCRIPTION);
}

/**
 * Whether this call should ask, given the session's approval policy. `never`
 * (full access) means the user does not want to be interrupted, and an `ask`
 * under that policy would be rejected outright — the child session could then
 * never start.
 * @param name - the tool being executed.
 * @param policy - the session's effective approval policy.
 * @returns whether to route this call through the approval seam.
 */
export function shouldAsk(name, policy) {
  return isChildSessionTool(name) && policy !== "never";
}

/**
 * The reason shown to the user (and carried on the approval request).
 * @param description - the model's label, possibly empty.
 * @returns one Chinese sentence naming what the model wants to start.
 */
export function askReason(description) {
  const label = description.trim();
  return label === ""
    ? "模型想新开一个子会话，等你确认后才创建。"
    : `模型想新开一个子会话：${label}。确认后才创建。`;
}

/**
 * The corrective result text for a refused child-session call.
 * @returns model-facing refusal content.
 */
export function rejectionText() {
  return REJECT_TEXT;
}
