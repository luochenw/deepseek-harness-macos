import assert from "node:assert/strict";
import test from "node:test";
import {
  normalizedBrowserURL,
  normalizedMarkdownRequest,
  workbenchToolDefinitions,
} from "../lib/core.js";

test("workbench tools expose stable model-callable contracts", () => {
  const tools = workbenchToolDefinitions();
  assert.deepEqual(tools.map((tool) => tool.name), [
    "open_workbench_browser",
    "open_workbench_markdown",
  ]);
  assert.equal(tools[0].parameters.url.required, true);
  assert.equal(tools[1].parameters.path.required, true);
  assert.match(tools[0].description, /cannot read the DOM/u);
  assert.match(tools[1].description, /does not return its contents/u);
});

test("browser requests accept only normalized HTTP(S) URLs", () => {
  assert.equal(normalizedBrowserURL("localhost:5173"), "http://localhost:5173/");
  assert.equal(normalizedBrowserURL("example.com/docs"), "https://example.com/docs");
  assert.equal(normalizedBrowserURL("https://example.com/docs"), "https://example.com/docs");
  assert.equal(normalizedBrowserURL("//example.com/a"), "https://example.com/a");
  assert.throws(() => normalizedBrowserURL("file:///tmp/readme.md"), /HTTP or HTTPS/u);
  assert.throws(() => normalizedBrowserURL("mailto:test@example.com"), /HTTP or HTTPS/u);
});

test("Markdown requests require a supported extension and preserve anchors", () => {
  assert.deepEqual(
    normalizedMarkdownRequest("docs/guide.md", "api-surface"),
    { path: "docs/guide.md", anchor: "api-surface" });
  assert.deepEqual(
    normalizedMarkdownRequest("README.markdown", " "),
    { path: "README.markdown" });
  assert.deepEqual(
    normalizedMarkdownRequest(" README.md "),
    { path: "README.md" });
  assert.throws(() => normalizedMarkdownRequest("notes.txt"), /Markdown file/u);
});

test("tool execute returns a request receipt without page or file contents", async () => {
  const [browser, markdown] = workbenchToolDefinitions();
  assert.deepEqual(
    await browser.execute({ url: "localhost:3000" }, { agent: {} }),
    { requested: true, url: "http://localhost:3000/" });
  assert.deepEqual(
    await markdown.execute({ path: "README.md", anchor: "setup" }, { agent: {} }),
    { requested: true, path: "README.md", anchor: "setup" });
  await assert.rejects(
    () => browser.execute({ url: "https://example.com" }, {}),
    /requires a calling Agent/u);
});
