const HTTP_SCHEMES = new Set(["http:", "https:"]);
const MARKDOWN_EXTENSION = /\.(?:md|markdown|mdown|mkd)$/iu;

function nonEmptyString(value, field) {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new Error(`${field} must be a non-empty string`);
  }
  return value.trim();
}

export function normalizedBrowserURL(raw) {
  const input = nonEmptyString(raw, "url");
  const hostWithPort = /^(?:localhost|(?:\d{1,3}\.){3}\d{1,3}|(?:[A-Za-z0-9-]+\.)+[A-Za-z0-9-]+):\d+(?:\/|$)/u.test(input);
  const explicitScheme = /^([A-Za-z][A-Za-z0-9+.-]*):/u.exec(input)?.[1]?.toLowerCase();
  if (!hostWithPort
      && explicitScheme !== undefined
      && explicitScheme !== "http"
      && explicitScheme !== "https") {
    throw new Error("url must use HTTP or HTTPS");
  }
  const candidate = input.startsWith("//")
    ? `https:${input}`
    : /^[A-Za-z][A-Za-z0-9+.-]*:\/\//u.test(input)
    ? input
    : /^(?:localhost|(?:\d{1,3}\.){3}\d{1,3}|\[[0-9A-Fa-f:]+\])(?::\d+)?(?:\/|$)/u.test(input)
      ? `http://${input}`
      : `https://${input}`;
  let url;
  try {
    url = new URL(candidate);
  } catch {
    throw new Error("url must be a valid HTTP(S) address");
  }
  if (!HTTP_SCHEMES.has(url.protocol) || url.hostname.length === 0) {
    throw new Error("url must use HTTP or HTTPS");
  }
  return url.href;
}

export function normalizedMarkdownRequest(rawPath, rawAnchor) {
  const path = nonEmptyString(rawPath, "path");
  if (!MARKDOWN_EXTENSION.test(path)) {
    throw new Error("path must name a Markdown file (.md, .markdown, .mdown, or .mkd)");
  }
  const anchor = typeof rawAnchor === "string" && rawAnchor.trim().length > 0
    ? rawAnchor.trim()
    : undefined;
  return { path, ...(anchor === undefined ? {} : { anchor }) };
}

export function workbenchToolDefinitions() {
  return [
    {
      name: "open_workbench_browser",
      description:
        "Request that the native macOS app open an HTTP(S) URL in a visible right-workbench browser tab. " +
        "This tool only opens the page for the user; it cannot read the DOM, inspect page contents, click, type, or run scripts. " +
        "Use web_fetch or web_search when you need page contents.",
      parameters: {
        url: {
          type: "string",
          required: true,
          description: "HTTP(S) URL to show. localhost addresses without a scheme are accepted.",
        },
      },
      output: {
        schema: {
          type: "object",
          additionalProperties: false,
          properties: {
            requested: { type: "boolean", required: true },
            url: { type: "string", required: true },
          },
        },
        render: (_args, value) => [{
          type: "text",
          text: `Requested the native workbench browser to open ${value.url}.`,
        }],
      },
      execute: async (args, exec) => {
        if (!exec.agent) throw new Error("open_workbench_browser requires a calling Agent");
        return {
          requested: true,
          url: normalizedBrowserURL(args.url),
        };
      },
      presentCall: (args) => ({
        card: "generic",
        title: `Open browser ${args.url}`,
        kind: "other",
      }),
    },
    {
      name: "open_workbench_markdown",
      description:
        "Request that the native macOS app open an existing Markdown file from this session's working directory in a visible right-workbench tab. " +
        "Relative paths resolve from the session cwd. The native app resolves symlinks and rejects files outside that cwd. " +
        "This tool opens the document for the user but does not return its contents; use read when you need to inspect the file.",
      parameters: {
        path: {
          type: "string",
          required: true,
          description: "Relative or absolute path to a Markdown file inside the current session cwd.",
        },
        anchor: {
          type: "string",
          description: "Optional Markdown heading anchor to reveal after opening.",
        },
      },
      output: {
        schema: {
          type: "object",
          additionalProperties: false,
          properties: {
            requested: { type: "boolean", required: true },
            path: { type: "string", required: true },
            anchor: { type: "string" },
          },
        },
        render: (_args, value) => [{
          type: "text",
          text: `Requested the native workbench to open ${value.path}${value.anchor ? `#${value.anchor}` : ""}.`,
        }],
      },
      execute: async (args, exec) => {
        if (!exec.agent) throw new Error("open_workbench_markdown requires a calling Agent");
        return {
          requested: true,
          ...normalizedMarkdownRequest(args.path, args.anchor),
        };
      },
      presentCall: (args) => ({
        card: "generic",
        title: `Open Markdown ${args.path}`,
        kind: "read",
        locations: [{ path: args.path }],
      }),
    },
  ];
}
