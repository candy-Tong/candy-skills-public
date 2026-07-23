# Diagnostics

## Expected Topology

```text
local browser
  -> local Playwright MCP 127.0.0.1:8931
  -> SSH reverse tunnel
  -> remote 127.0.0.1:8931
  -> selected remote Agent
```

There is no remote-IP bridge and no CDP endpoint.

## Healthy Offline State

When reusing existing Chrome, Chrome may be closed after login. In that state:

- The MCP service remains running.
- The reverse tunnel remains running.
- MCP `initialize` succeeds.
- A browser tool may report that the extension/browser is unavailable.

Record `waiting for browser`. Do not start Chrome or restart the MCP service
solely because the extension is disconnected.

## Layer Ownership

- Local `8931` down: repair the local MCP login task.
- Local MCP up but `browser_tabs` fails: check Chrome, extension installation,
  extension approval, and `PLAYWRIGHT_MCP_EXTENSION_TOKEN`.
- Remote `8931` down: use `$remote-port-mapping` to inspect the tunnel and a
  stale remote listener.
- Remote MCP works but the Agent has no tools: inspect that Agent's actual MCP
  configuration and reload behavior.

## Secret Handling

The extension token allows the MCP client to reconnect to the browser. Store it
only in the local user task configuration or restricted launcher file. Never
place it in remote Agent configuration; the remote Agent connects to the MCP
HTTP endpoint on remote loopback.

## Codex Non-Interactive Approval

If `codex exec` loads the `playwright` server but returns
`user cancelled MCP tool call`, separate approval handling from transport:

1. Run `verify-mcp.mjs --browser --navigate <url>` on the remote machine. If it
   succeeds, the browser, MCP server, and tunnel are healthy.
2. Use an interactive Codex session and approve the exact MCP browser action
   for normal operation.
3. For a narrowly scoped unattended verification only, use an approval bypass
   only after the user has explicitly authorized the exact browser action.
   Never persist that bypass in Codex configuration.

Treat unrelated Codex startup warnings, such as a malformed hooks file, as a
separate Agent configuration problem. Back up that file before changing it.
