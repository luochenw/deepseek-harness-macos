import { defineTool } from "@deepseek-ai/dsh-tools";
import { workbenchToolDefinitions } from "./core.js";

export const name = "tool-workbench";
export const inject = ["tools"];

export function apply(ctx) {
  for (const definition of workbenchToolDefinitions()) {
    ctx.tools.register(defineTool(definition));
  }
}
