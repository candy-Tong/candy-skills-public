---
name: remote-port-mapping
description: Create, repair, or inspect a durable SSH reverse port mapping from a macOS or Windows local computer to a remote development machine. Use when a user asks to expose a local TCP, HTTP, WebSocket, MCP, browser, or plugin service on a remote machine, make the mapping start after user login and recover after reboot, diagnose a stale reverse tunnel, or validate remote loopback and optional remote-IP reachability.
---

# Remote Port Mapping

Create a user-login service, an SSH reverse tunnel, and a 60-second
application-level watchdog. Support macOS with LaunchAgent and Windows with
Task Scheduler. Use system OpenSSH; do not require `autossh`.

## Required Inputs

Resolve these values before changing state:

- A short mapping name.
- Local target host and port.
- Remote SSH target, such as an SSH config alias or `user@host`, that works as
  `ssh <target>`. Put custom ports and options in SSH config rather than passing
  an arbitrary shell command.
- Remote port.
- Probe type: `tcp`, `http`, `ws`, or `mcp`.
- Remote exposure: loopback by default, or a specific remote-machine IP only
  when the user explicitly requests it.

The first version supports a macOS or Windows local computer and a Linux/POSIX
remote development machine with `bash`, `ss`, and `curl`.

Require direct, non-interactive SSH login. Test it immediately before the
remote phase with `BatchMode=yes`. Do not configure passwords, keys, agents, or
interactive authentication.

## Safety Rules

- Bind the reverse tunnel to remote `127.0.0.1`.
- Never bind a reverse tunnel to `0.0.0.0`.
- Do not choose another port when the requested port is occupied.
- Stop this skill's existing task before checking ownership. If the remote port
  remains occupied, show the listener and ask before terminating anything.
- Never kill an unknown local or remote process.
- Keep generated state idempotent. Re-running the same setup must update the
  same files and task names, not create duplicates.
- Treat listener checks as diagnostics, not proof. Finish with an
  application-level probe through the remote endpoint.
- Do not implement automatic rollback. Preserve partial state and report the
  exact failed stage.

## Configure

Determine the local OS, then run the matching bundled script:

```bash
"$SKILL_DIR/scripts/setup-macos.sh" \
  --name <name> \
  --remote <ssh-target> \
  --local-port <local-port> \
  --remote-port <remote-port> \
  --probe <tcp|http|ws|mcp>
```

```powershell
& "$SkillDir\scripts\setup-windows.ps1" `
  -Name <name> `
  -Remote <ssh-target> `
  -LocalPort <local-port> `
  -RemotePort <remote-port> `
  -Probe <tcp|http|ws|mcp>
```

Use `--probe-path` or `-ProbePath` for HTTP. Use `--public-ip` or
`-PublicIp` with a specific IPv4 address only after the user explicitly requests
remote-IP access. That mode requires `socat` on the remote machine; install
missing dependencies using the available package manager without a separate
confirmation prompt.

The scripts intentionally refuse to replace an unknown remote listener. If that
happens, inspect it with:

```bash
ssh <ssh-target> 'ss -ltnp | grep -E ":<remote-port>[[:space:]]" || true'
```

Ask for authorization before cleaning it up, then rerun the setup.

## Verify

Require all applicable checks:

1. The local target passes the selected probe.
2. The login-start tunnel task is loaded or registered and running.
3. Remote `127.0.0.1:<remote-port>` passes the selected probe.
4. When enabled, the specific remote IP also passes the selected probe.
5. Re-running the setup produces the same task names and a healthy mapping.

For MCP, send an `initialize` JSON-RPC request. A listening port or a plain GET
to `/mcp` is not sufficient.

For WebSocket, require an HTTP `101` upgrade response rather than a plain TCP
connection.

Read [references/operations.md](references/operations.md) when diagnosing task
ownership, logs, a stale SSH listener, or a remote-IP bridge.
