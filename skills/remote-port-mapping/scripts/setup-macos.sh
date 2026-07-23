#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  setup-macos.sh --name NAME --remote SSH_TARGET --local-port PORT \
    --remote-port PORT --probe tcp|http|ws|mcp [options]

Options:
  --local-host HOST       Local target host. Default: 127.0.0.1
  --probe-path PATH       HTTP probe path. Default: /
  --public-ip IPV4        Also expose the specific remote-machine IPv4 via socat.
  --interval SECONDS      Watchdog interval. Default: 60
  --output-root DIR       Generate under DIR without loading LaunchAgents.
  -h, --help              Show this help.
EOF
}

name=""
remote=""
local_host="127.0.0.1"
local_port=""
remote_port=""
probe=""
probe_path="/"
public_ip=""
interval=60
output_root=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) name="${2:-}"; shift 2 ;;
    --remote) remote="${2:-}"; shift 2 ;;
    --local-host) local_host="${2:-}"; shift 2 ;;
    --local-port) local_port="${2:-}"; shift 2 ;;
    --remote-port) remote_port="${2:-}"; shift 2 ;;
    --probe) probe="${2:-}"; shift 2 ;;
    --probe-path) probe_path="${2:-}"; shift 2 ;;
    --public-ip) public_ip="${2:-}"; shift 2 ;;
    --interval) interval="${2:-}"; shift 2 ;;
    --output-root) output_root="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

fail() {
  echo "remote-port-mapping: $*" >&2
  exit 1
}

[[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail "--name must match [a-z0-9][a-z0-9-]*"
[[ "$remote" =~ ^[A-Za-z0-9._@:-]+$ ]] || fail "--remote must be an SSH alias or user@host without shell syntax"
[[ "$local_host" =~ ^[A-Za-z0-9.:-]+$ ]] || fail "invalid --local-host"
[[ "$local_port" =~ ^[0-9]+$ && "$local_port" -ge 1 && "$local_port" -le 65535 ]] || fail "invalid --local-port"
[[ "$remote_port" =~ ^[0-9]+$ && "$remote_port" -ge 1 && "$remote_port" -le 65535 ]] || fail "invalid --remote-port"
[[ "$probe" == "tcp" || "$probe" == "http" || "$probe" == "ws" || "$probe" == "mcp" ]] ||
  fail "--probe must be tcp, http, ws, or mcp"
[[ "$probe_path" == /* && "$probe_path" != *$'\n'* ]] || fail "--probe-path must start with /"
[[ "$interval" =~ ^[0-9]+$ && "$interval" -ge 10 ]] || fail "--interval must be at least 10 seconds"
if [[ -n "$public_ip" ]]; then
  [[ "$public_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail "--public-ip must be an IPv4 address"
  IFS=. read -r public_a public_b public_c public_d <<<"$public_ip"
  for octet in "$public_a" "$public_b" "$public_c" "$public_d"; do
    ((10#$octet <= 255)) || fail "--public-ip must be an IPv4 address"
  done
fi

command -v ssh >/dev/null 2>&1 || fail "OpenSSH client is required"
command -v curl >/dev/null 2>&1 || fail "curl is required"

ssh_path="$(command -v ssh)"
curl_path="$(command -v curl)"
nc_path="$(command -v nc || true)"
home_root="${output_root:-${HOME:?HOME is required}}"
state_id="${name}-${remote_port}"
state_dir="$home_root/.local/share/remote-port-mapping/$state_id"
launch_agents_dir="$home_root/Library/LaunchAgents"
log_dir="$home_root/Library/Logs/remote-port-mapping"
tunnel_label="com.user.remote-port.${state_id}.tunnel"
watchdog_label="com.user.remote-port.${state_id}.watchdog"
bridge_label="com.user.remote-port.${state_id}.public-bridge"
tunnel_plist="$launch_agents_dir/$tunnel_label.plist"
watchdog_plist="$launch_agents_dir/$watchdog_label.plist"
bridge_plist="$launch_agents_dir/$bridge_label.plist"
watchdog_script="$state_dir/watchdog.sh"
domain="gui/$(id -u)"

mkdir -p "$state_dir" "$launch_agents_dir" "$log_dir"

write_atomic() {
  local path="$1"
  local mode="$2"
  local temp
  temp="$(mktemp "${path}.tmp.XXXXXX")"
  cat >"$temp"
  chmod "$mode" "$temp"
  mv "$temp" "$path"
}

shell_quote() {
  printf '%q' "$1"
}

plist_header() {
  cat <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
EOF
}

write_atomic "$tunnel_plist" 0644 <<EOF
$(plist_header)
<dict>
  <key>Label</key><string>$tunnel_label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$ssh_path</string>
    <string>-N</string>
    <string>-o</string><string>BatchMode=yes</string>
    <string>-o</string><string>ServerAliveInterval=30</string>
    <string>-o</string><string>ServerAliveCountMax=3</string>
    <string>-o</string><string>ExitOnForwardFailure=yes</string>
    <string>-R</string><string>127.0.0.1:$remote_port:$local_host:$local_port</string>
    <string>$remote</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>StandardOutPath</key><string>$log_dir/$state_id-tunnel.log</string>
  <key>StandardErrorPath</key><string>$log_dir/$state_id-tunnel.err</string>
</dict>
</plist>
EOF

if [[ -n "$public_ip" ]]; then
  write_atomic "$bridge_plist" 0644 <<EOF
$(plist_header)
<dict>
  <key>Label</key><string>$bridge_label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$ssh_path</string>
    <string>-o</string><string>BatchMode=yes</string>
    <string>-o</string><string>ServerAliveInterval=30</string>
    <string>-o</string><string>ServerAliveCountMax=3</string>
    <string>$remote</string>
    <string>exec socat TCP-LISTEN:$remote_port,bind=$public_ip,reuseaddr,fork TCP:127.0.0.1:$remote_port</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>StandardOutPath</key><string>$log_dir/$state_id-public-bridge.log</string>
  <key>StandardErrorPath</key><string>$log_dir/$state_id-public-bridge.err</string>
</dict>
</plist>
EOF
fi

write_atomic "$watchdog_script" 0755 <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

REMOTE=$(shell_quote "$remote")
LOCAL_HOST=$(shell_quote "$local_host")
LOCAL_PORT=$(shell_quote "$local_port")
REMOTE_PORT=$(shell_quote "$remote_port")
PROBE=$(shell_quote "$probe")
PROBE_PATH=$(shell_quote "$probe_path")
PUBLIC_IP=$(shell_quote "$public_ip")
INTERVAL=$(shell_quote "$interval")
DOMAIN="gui/\$(id -u)"
TUNNEL_LABEL=$(shell_quote "$tunnel_label")
BRIDGE_LABEL=$(shell_quote "$bridge_label")
LOG_FILE=$(shell_quote "$log_dir/$state_id-watchdog.log")
SSH=$(shell_quote "$ssh_path")
CURL=$(shell_quote "$curl_path")
NC=$(shell_quote "$nc_path")

rotate_log() {
  if [[ -f "\$LOG_FILE" ]] && [[ "\$(wc -c <"\$LOG_FILE")" -ge 1048576 ]]; then
    mv -f "\$LOG_FILE" "\$LOG_FILE.1"
  fi
}

log() {
  rotate_log
  printf '[%s] %s\n' "\$(date '+%F %T %z')" "\$*" >>"\$LOG_FILE"
}

tcp_probe() {
  local host="\$1"
  local port="\$2"
  [[ -n "\$NC" ]] || return 1
  "\$NC" -z -G 3 "\$host" "\$port" >/dev/null 2>&1 ||
    "\$NC" -z -w 3 "\$host" "\$port" >/dev/null 2>&1
}

http_probe() {
  local url="\$1"
  "\$CURL" --noproxy '*' --fail --silent --show-error --max-time 5 "\$url" >/dev/null
}

ws_probe() {
  local url="\$1"
  local headers
  headers="\$("\$CURL" --noproxy '*' --http1.1 --silent --show-error --max-time 3 \
    -H 'Connection: Upgrade' \
    -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    --dump-header - --output /dev/null "\$url" 2>/dev/null || true)"
  grep -Eq '^HTTP/[0-9.]+ 101([[:space:]]|$)' <<<"\$headers"
}

mcp_probe() {
  local url="\$1"
  "\$CURL" --noproxy '*' --fail --silent --show-error --max-time 5 \
    -H 'Accept: application/json, text/event-stream' \
    -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"remote-port-watchdog","version":"1"}}}' \
    "\$url" >/dev/null
}

local_ok() {
  case "\$PROBE" in
    tcp) tcp_probe "\$LOCAL_HOST" "\$LOCAL_PORT" ;;
    http) http_probe "http://\$LOCAL_HOST:\$LOCAL_PORT\$PROBE_PATH" ;;
    ws) ws_probe "http://\$LOCAL_HOST:\$LOCAL_PORT\$PROBE_PATH" ;;
    mcp) mcp_probe "http://\$LOCAL_HOST:\$LOCAL_PORT/mcp" ;;
  esac
}

remote_ok() {
  "\$SSH" -o BatchMode=yes -o ConnectTimeout=5 "\$REMOTE" \
    bash -s -- "\$PROBE" "\$REMOTE_PORT" "\$PROBE_PATH" <<'REMOTE_PROBE'
set -Eeuo pipefail
probe="\$1"
port="\$2"
path="\$3"
case "\$probe" in
  tcp)
    if command -v nc >/dev/null 2>&1; then
      nc -z -w 3 127.0.0.1 "\$port"
    else
      timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/\$port"
    fi
    ;;
  http)
    curl --noproxy '*' --fail --silent --show-error --max-time 5 \
      "http://127.0.0.1:\$port\$path" >/dev/null
    ;;
  ws)
    headers="\$(curl --noproxy '*' --http1.1 --silent --show-error --max-time 3 \
      -H 'Connection: Upgrade' \
      -H 'Upgrade: websocket' \
      -H 'Sec-WebSocket-Version: 13' \
      -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
      --dump-header - --output /dev/null \
      "http://127.0.0.1:\$port\$path" 2>/dev/null || true)"
    grep -Eq '^HTTP/[0-9.]+ 101([[:space:]]|$)' <<<"\$headers"
    ;;
  mcp)
    curl --noproxy '*' --fail --silent --show-error --max-time 5 \
      -H 'Accept: application/json, text/event-stream' \
      -H 'Content-Type: application/json' \
      --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"remote-port-watchdog","version":"1"}}}' \
      "http://127.0.0.1:\$port/mcp" >/dev/null
    ;;
esac
REMOTE_PROBE
}

public_ok() {
  [[ -n "\$PUBLIC_IP" ]] || return 0
  "\$SSH" -o BatchMode=yes -o ConnectTimeout=5 "\$REMOTE" \
    bash -s -- "\$PROBE" "\$PUBLIC_IP" "\$REMOTE_PORT" "\$PROBE_PATH" <<'PUBLIC_PROBE'
set -Eeuo pipefail
probe="\$1"
host="\$2"
port="\$3"
path="\$4"
case "\$probe" in
  tcp) nc -z -w 3 "\$host" "\$port" ;;
  http) curl --noproxy '*' --fail --silent --show-error --max-time 5 "http://\$host:\$port\$path" >/dev/null ;;
  ws)
    headers="\$(curl --noproxy '*' --http1.1 --silent --show-error --max-time 3 \
      -H 'Connection: Upgrade' \
      -H 'Upgrade: websocket' \
      -H 'Sec-WebSocket-Version: 13' \
      -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
      --dump-header - --output /dev/null \
      "http://\$host:\$port\$path" 2>/dev/null || true)"
    grep -Eq '^HTTP/[0-9.]+ 101([[:space:]]|$)' <<<"\$headers"
    ;;
  mcp)
    curl --noproxy '*' --fail --silent --show-error --max-time 5 \
      -H 'Accept: application/json, text/event-stream' \
      -H 'Content-Type: application/json' \
      --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"remote-port-watchdog","version":"1"}}}' \
      "http://\$host:\$port/mcp" >/dev/null
    ;;
esac
PUBLIC_PROBE
}

kickstart() {
  launchctl kickstart -k "\$DOMAIN/\$1" >/dev/null 2>&1 || true
}

if ! local_ok; then
  log "local target unhealthy: \$LOCAL_HOST:\$LOCAL_PORT probe=\$PROBE"
  exit 1
fi

if ! remote_ok; then
  log "remote loopback unhealthy; restarting \$TUNNEL_LABEL"
  kickstart "\$TUNNEL_LABEL"
  sleep 3
fi

if [[ -n "\$PUBLIC_IP" ]] && ! public_ok; then
  log "remote public endpoint unhealthy; restarting \$BRIDGE_LABEL"
  kickstart "\$BRIDGE_LABEL"
  sleep 3
fi

if remote_ok && public_ok; then
  log "healthy: local=\$LOCAL_HOST:\$LOCAL_PORT remote=127.0.0.1:\$REMOTE_PORT public=\${PUBLIC_IP:-disabled} probe=\$PROBE"
  exit 0
fi

log "unhealthy after restart"
exit 1
EOF

write_atomic "$watchdog_plist" 0644 <<EOF
$(plist_header)
<dict>
  <key>Label</key><string>$watchdog_label</string>
  <key>ProgramArguments</key>
  <array><string>$watchdog_script</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>$interval</integer>
  <key>StandardOutPath</key><string>$log_dir/$state_id-watchdog.out</string>
  <key>StandardErrorPath</key><string>$log_dir/$state_id-watchdog.err</string>
</dict>
</plist>
EOF

plutil -lint "$tunnel_plist" "$watchdog_plist" >/dev/null
[[ -z "$public_ip" ]] || plutil -lint "$bridge_plist" >/dev/null
bash -n "$watchdog_script"

if [[ -n "$output_root" ]]; then
  printf 'Generated mapping state under %s\n' "$output_root"
  exit 0
fi

ssh -o BatchMode=yes -o ConnectTimeout=5 "$remote" true ||
  fail "direct non-interactive SSH login failed: ssh $remote"

labels=("$tunnel_label" "$watchdog_label")
if [[ -n "$public_ip" ]]; then
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$remote" 'command -v socat >/dev/null' ||
    fail "remote-IP mode requires socat on the remote machine"
  labels+=("$bridge_label")
fi

for label in "${labels[@]}"; do
  launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
done
sleep 1

occupied="$(
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$remote" \
    "ss -ltnp 2>/dev/null | awk '\$4 ~ /:${remote_port}\$/ {print}'" || true
)"
if [[ -n "$occupied" ]]; then
  printf 'Remote port %s remains occupied after stopping this mapping:\n%s\n' "$remote_port" "$occupied" >&2
  fail "refusing to replace an unknown remote listener"
fi

bootstrap_with_retry() {
  local plist="$1"
  local output=""

  for _ in {1..50}; do
    if output="$(launchctl bootstrap "$domain" "$plist" 2>&1)"; then
      return
    fi
    sleep 0.2
  done

  printf '%s\n' "$output" >&2
  fail "launchctl could not bootstrap $(basename "$plist") after 10 seconds"
}

wait_for_remote_listener() {
  for _ in {1..30}; do
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "$remote" \
      "ss -ltn 2>/dev/null | awk '\$4 ~ /:${remote_port}\$/ {found=1} END {exit !found}'"; then
      return
    fi
    sleep 0.5
  done

  fail "remote listener 127.0.0.1:$remote_port did not appear"
}

bootstrap_with_retry "$tunnel_plist"
launchctl enable "$domain/$tunnel_label" >/dev/null 2>&1 || true
launchctl kickstart -k "$domain/$tunnel_label" >/dev/null
wait_for_remote_listener

if [[ -n "$public_ip" ]]; then
  bootstrap_with_retry "$bridge_plist"
  launchctl enable "$domain/$bridge_label" >/dev/null 2>&1 || true
  launchctl kickstart -k "$domain/$bridge_label" >/dev/null
fi

"$watchdog_script"
bootstrap_with_retry "$watchdog_plist"
launchctl enable "$domain/$watchdog_label" >/dev/null 2>&1 || true

cat <<EOF
Mapping ready:
  local target:    $local_host:$local_port
  remote endpoint: 127.0.0.1:$remote_port
  remote public:   ${public_ip:-disabled}
  probe:           $probe
  tunnel task:     $tunnel_label
  watchdog task:   $watchdog_label
EOF
