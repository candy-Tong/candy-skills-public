# Operations

## Generated State

macOS:

- `~/Library/LaunchAgents/com.user.remote-port.<name>-<port>.tunnel.plist`
- `~/Library/LaunchAgents/com.user.remote-port.<name>-<port>.watchdog.plist`
- `~/.local/share/remote-port-mapping/<name>-<port>/`
- `~/Library/Logs/remote-port-mapping/`

Windows:

- `%LOCALAPPDATA%\RemotePortMapping\<name>-<port>\`
- Task Scheduler tasks `RemotePortMapping-<name>-<port>-Tunnel` and
  `RemotePortMapping-<name>-<port>-Watchdog`

Remote-IP mode adds a `PublicBridge` task. The reverse tunnel still binds only
to remote loopback; a remote `socat` process owns the specific remote-IP
listener.

## Health Semantics

The watchdog checks the local target first, then probes the service through the
remote endpoint. A failed remote probe restarts the tunnel task. It does not
kill a listener on the remote machine.

Use:

- TCP: complete a TCP connection.
- HTTP: require a successful HTTP response from the configured path.
- WebSocket: require an HTTP `101` upgrade response.
- MCP: POST an `initialize` request to `/mcp`.

Logs rotate to one `.1` file after reaching approximately 1 MiB.

## Stale Remote Listener

An old SSH server process can keep a reverse-forward listener after the local
network changes. Diagnose before cleanup:

```bash
ssh <target> 'ss -ltnp | grep -E ":<port>[[:space:]]" || true'
ssh <target> 'ss -tnp | grep sshd || true'
```

Stop the locally managed tunnel first. If the listener remains, do not infer
ownership from the port number alone. Ask the user before terminating an exact
remote process.

## Remote-IP Bridge

Check each layer independently:

```text
local target
  -> remote 127.0.0.1:<port>
  -> remote <specific-ip>:<port>
```

Only one task may own the remote `socat` process. Do not combine a remote
startup service with a local task that also launches the same bridge.
