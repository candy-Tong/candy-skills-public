#!/usr/bin/env node

const args = process.argv.slice(2);

function readArg(name, fallback = undefined) {
  const index = args.indexOf(name);
  if (index === -1) return fallback;
  if (index + 1 >= args.length) throw new Error(`Missing value for ${name}`);
  return args[index + 1];
}

const url = readArg("--url", "http://127.0.0.1:8931/mcp");
const verifyBrowser = args.includes("--browser");
const navigateUrl = readArg("--navigate");
const timeoutMs = Number(readArg("--timeout", "10000"));

if (!Number.isFinite(timeoutMs) || timeoutMs < 1000) {
  throw new Error("--timeout must be at least 1000 milliseconds");
}

function parseResponse(contentType, text) {
  if (!text.trim()) return undefined;
  if (!contentType.includes("text/event-stream")) return JSON.parse(text);

  const messages = [];
  for (const line of text.split(/\r?\n/)) {
    if (!line.startsWith("data:")) continue;
    const data = line.slice(5).trim();
    if (data && data !== "[DONE]") messages.push(JSON.parse(data));
  }
  return messages.at(-1);
}

async function post(payload, sessionId) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const headers = {
    Accept: "application/json, text/event-stream",
    "Content-Type": "application/json",
  };
  if (sessionId) headers["Mcp-Session-Id"] = sessionId;

  try {
    const response = await fetch(url, {
      method: "POST",
      headers,
      body: JSON.stringify(payload),
      signal: controller.signal,
    });
    const text = await response.text();
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}: ${text.slice(0, 300)}`);
    }
    return {
      body: parseResponse(response.headers.get("content-type") ?? "", text),
      sessionId: response.headers.get("mcp-session-id") ?? sessionId,
    };
  } finally {
    clearTimeout(timer);
  }
}

const initialized = await post({
  jsonrpc: "2.0",
  id: 1,
  method: "initialize",
  params: {
    protocolVersion: "2025-03-26",
    capabilities: {},
    clientInfo: { name: "remote-browser-mcp-verifier", version: "1" },
  },
});

if (!initialized.body?.result) {
  throw new Error("MCP initialize did not return a result");
}

await post(
  {
    jsonrpc: "2.0",
    method: "notifications/initialized",
    params: {},
  },
  initialized.sessionId,
);

const tools = await post(
  { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} },
  initialized.sessionId,
);
const toolNames = tools.body?.result?.tools?.map((tool) => tool.name) ?? [];
if (!toolNames.includes("browser_tabs")) {
  throw new Error("MCP tools/list does not contain browser_tabs");
}

if (verifyBrowser) {
  const tabs = await post(
    {
      jsonrpc: "2.0",
      id: 3,
      method: "tools/call",
      params: { name: "browser_tabs", arguments: { action: "list" } },
    },
    initialized.sessionId,
  );
  if (tabs.body?.error || tabs.body?.result?.isError) {
    throw new Error("browser_tabs returned an error");
  }
}

let navigationVerified = false;
if (navigateUrl) {
  if (!toolNames.includes("browser_navigate")) {
    throw new Error("MCP tools/list does not contain browser_navigate");
  }

  const navigation = await post(
    {
      jsonrpc: "2.0",
      id: 4,
      method: "tools/call",
      params: { name: "browser_navigate", arguments: { url: navigateUrl } },
    },
    initialized.sessionId,
  );
  if (navigation.body?.error || navigation.body?.result?.isError) {
    const detail = JSON.stringify(
      navigation.body?.error ?? navigation.body?.result,
    ).slice(0, 500);
    throw new Error(`browser_navigate returned an error: ${detail}`);
  }
  navigationVerified = true;
}

console.log(
  JSON.stringify({
    ok: true,
    url,
    protocolVersion: initialized.body.result.protocolVersion,
    toolCount: toolNames.length,
    browserVerified: verifyBrowser,
    navigationVerified,
  }),
);
