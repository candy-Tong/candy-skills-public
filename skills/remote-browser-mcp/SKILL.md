---
name: remote-browser-mcp
description: Configure Playwright MCP on a macOS or Windows local computer, keep it running after user login and reboot, map its fixed port 8931 to a remote development machine, and configure a user-selected remote coding agent to use the MCP endpoint. Use when a user wants a remote Codex, Claude Code, Cursor, IDE, or other agent to control a local browser through Playwright MCP.
---

# Remote Browser MCP

Expose a local Playwright MCP server to an agent running on a remote machine.
Use port `8931` for every layer. Do not support CDP or silently choose another
port.

This skill has a hard dependency on `$remote-port-mapping`. Before starting the
remote phase, confirm that the current Agent has discovered or loaded that
skill. A sibling source directory alone does not count as available. If it is
missing, stop and tell the user to install `remote-port-mapping` from the same
skill package with the Vercel `skills` CLI:

```bash
npx skills add <skill-package> --skill remote-port-mapping
```

Do not recreate its tunnel logic.

## Phase 1: Configure Local MCP

This phase does not require remote-machine information.

Ask the user to choose exactly one browser mode:

1. Reuse an existing Google Chrome profile.
2. Let Playwright MCP use its default new browser.

### Existing Chrome

Show the official extension link:

<https://chromewebstore.google.com/detail/playwright-extension/mmlmfjhmonkocbjadbfplnigmagldckm>

Require the user to install and enable the extension, then provide the value
shown by the extension:

```text
PLAYWRIGHT_MCP_EXTENSION_TOKEN=...
```

Treat the token as a secret. Do not echo it in commands, logs, summaries, or
final output. Pass it to the setup script through a mode-`0600` temporary file
or the current process environment, then delete the temporary file immediately
after setup. Use Playwright MCP's `--extension` mode.

Do not add Chrome itself to login items. When Chrome is closed, report
`waiting for browser`; do not start Chrome and do not restart MCP repeatedly.

### Playwright Default Browser

Do not install the Chrome extension. Do not specify `--extension`,
`--user-data-dir`, CDP options, or a custom browser profile. Let Playwright MCP
use its defaults.

### Run Local Setup

On macOS:

```bash
"$SKILL_DIR/scripts/setup-macos.sh" --mode <extension|managed> \
  [--token-file <mode-0600-file>]
```

On Windows:

```powershell
& "$SkillDir\scripts\setup-windows.ps1" -Mode <extension|managed> `
  [-TokenFile <restricted-file>]
```

The setup must use the current machine pattern:

```text
npx -y @playwright/mcp@latest --host 127.0.0.1 --port 8931 ...
```

It creates a user-login service and a 60-second watchdog. The watchdog verifies
MCP `initialize` but does not require the browser to be connected.

Finish the phase with:

```bash
node "$SKILL_DIR/scripts/verify-mcp.mjs" \
  --url http://127.0.0.1:8931/mcp --browser
```

This must pass `initialize`, `tools/list`, and `browser_tabs`. For extension
mode, keep Chrome open and approve the initial extension connection if needed.
When the user asks for a real navigation check, add `--navigate <url>` to call
`browser_navigate` through the same MCP session.

## Phase 2: Configure Remote Access

Begin asking for remote inputs only after Phase 1 completes. Do not begin this
phase until the user has supplied both:

- A direct SSH target that works non-interactively as `ssh <target>`. Put
  custom ports and options in SSH config.
- The exact remote Agent or IDE to configure.

If either is missing, ask for it and stop. Local setup remains useful and does
not depend on this phase.

Immediately before remote changes:

1. Verify direct SSH login with `BatchMode=yes`.
2. Confirm `$remote-port-mapping` is available.
3. Invoke it with:
   - name: `playwright-mcp`
   - local host: `127.0.0.1`
   - local port: `8931`
   - remote port: `8931`
   - remote exposure: loopback only
   - probe: `mcp`

After the mapping passes its application-level probe, provide this connection
contract:

```text
MCP name: playwright
Transport: Streamable HTTP
URL: http://127.0.0.1:8931/mcp
```

Then inspect the selected Agent's installed version, help, documentation, and
existing remote configuration. Determine its actual MCP schema at runtime; do
not rely on a built-in Agent list or fixed config path.

When modifying the selected Agent:

- Add the server only after the user has named that Agent.
- Use the name `playwright`.
- Merge structured configuration without removing other MCP servers.
- Do nothing when the existing entry is identical.
- If a conflicting `playwright` entry exists, show the difference and ask
  before replacing it.
- Do not configure unselected Agents.
- Do not implement automatic rollback.

## Completion Criteria

Report success only after all requested layers pass:

1. Local MCP `initialize` and `tools/list`.
2. Local `browser_tabs`.
3. Remote `http://127.0.0.1:8931/mcp` `initialize`.
4. The selected remote Agent loads the `playwright` server and exposes its
   browser tools.

Read [references/diagnostics.md](references/diagnostics.md) for expected
offline states and failure ownership.
