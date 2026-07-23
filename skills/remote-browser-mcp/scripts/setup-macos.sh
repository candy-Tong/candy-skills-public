#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  setup-macos.sh --mode extension|managed [options]

Options:
  --token-file FILE       File containing PLAYWRIGHT_MCP_EXTENSION_TOKEN.
                          Required for extension mode unless the environment
                          variable is already set.
  --interval SECONDS      Watchdog interval. Default: 60
  --output-root DIR       Generate under DIR without loading LaunchAgents.
  -h, --help              Show this help.
EOF
}

mode=""
token_file=""
interval=60
output_root=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) mode="${2:-}"; shift 2 ;;
    --token-file) token_file="${2:-}"; shift 2 ;;
    --interval) interval="${2:-}"; shift 2 ;;
    --output-root) output_root="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

fail() {
  echo "remote-browser-mcp: $*" >&2
  exit 1
}

[[ "$mode" == "extension" || "$mode" == "managed" ]] ||
  fail "--mode must be extension or managed"
[[ "$interval" =~ ^[0-9]+$ && "$interval" -ge 10 ]] ||
  fail "--interval must be at least 10 seconds"

ensure_npx() {
  if command -v npx >/dev/null 2>&1; then
    return
  fi
  [[ -z "$output_root" ]] || fail "npx is required to generate a runnable task"
  command -v brew >/dev/null 2>&1 || fail "npx is missing and Homebrew is unavailable"
  brew install node
  command -v npx >/dev/null 2>&1 || fail "npx is still unavailable after installing Node.js"
}

ensure_npx
command -v node >/dev/null 2>&1 || fail "node is required"
command -v curl >/dev/null 2>&1 || fail "curl is required"

token="${PLAYWRIGHT_MCP_EXTENSION_TOKEN:-}"
if [[ -n "$token_file" ]]; then
  [[ -f "$token_file" ]] || fail "token file does not exist"
  [[ "$(stat -f '%Lp' "$token_file")" == "600" ]] ||
    fail "token file permissions must be 0600"
  token="$(<"$token_file")"
fi
token="${token#PLAYWRIGHT_MCP_EXTENSION_TOKEN=}"
token="${token//$'\r'/}"
token="${token//$'\n'/}"
if [[ "$mode" == "extension" && -z "$token" ]]; then
  fail "extension mode requires PLAYWRIGHT_MCP_EXTENSION_TOKEN or --token-file"
fi

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  value="${value//\'/&apos;}"
  printf '%s' "$value"
}

home_root="${output_root:-${HOME:?HOME is required}}"
state_dir="$home_root/.local/share/remote-browser-mcp"
launch_agents_dir="$home_root/Library/LaunchAgents"
log_dir="$home_root/Library/Logs/remote-browser-mcp"
service_label="com.user.playwright-mcp-8931"
watchdog_label="com.user.playwright-mcp-8931-local-keepalive"
service_plist="$launch_agents_dir/$service_label.plist"
watchdog_plist="$launch_agents_dir/$watchdog_label.plist"
watchdog_script="$state_dir/watchdog.sh"
verifier_source="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/verify-mcp.mjs"
verifier="$state_dir/verify-mcp.mjs"
domain="gui/$(id -u)"
npx_path="$(command -v npx)"
node_path="$(command -v node)"

mkdir -p "$state_dir" "$launch_agents_dir" "$log_dir"
cp "$verifier_source" "$verifier"
chmod 0755 "$verifier"

write_atomic() {
  local path="$1"
  local mode_bits="$2"
  local temp
  temp="$(mktemp "${path}.tmp.XXXXXX")"
  cat >"$temp"
  chmod "$mode_bits" "$temp"
  mv "$temp" "$path"
}

arguments=(
  "-y"
  "@playwright/mcp@latest"
)
if [[ "$mode" == "extension" ]]; then
  arguments+=("--extension")
fi
arguments+=(
  "--host" "127.0.0.1"
  "--port" "8931"
  "--allowed-hosts" "localhost:8931,127.0.0.1:8931,[::1]:8931"
)

{
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$service_label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml_escape "$npx_path")</string>
EOF
  for argument in "${arguments[@]}"; do
    printf '    <string>%s</string>\n' "$(xml_escape "$argument")"
  done
  cat <<EOF
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>StandardOutPath</key><string>$log_dir/playwright-mcp-8931.log</string>
  <key>StandardErrorPath</key><string>$log_dir/playwright-mcp-8931.err</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$(xml_escape "$(dirname "$node_path"):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")</string>
EOF
  if [[ "$mode" == "extension" ]]; then
    printf '    <key>PLAYWRIGHT_MCP_EXTENSION_TOKEN</key><string>%s</string>\n' "$(xml_escape "$token")"
  fi
  cat <<'EOF'
  </dict>
</dict>
</plist>
EOF
} | write_atomic "$service_plist" 0600

write_atomic "$watchdog_script" 0755 <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

DOMAIN="gui/\$(id -u)"
SERVICE_LABEL="$service_label"
NODE="$node_path"
VERIFIER="$verifier"
LOG_FILE="$log_dir/playwright-mcp-8931-watchdog.log"

rotate_log() {
  if [[ -f "\$LOG_FILE" ]] && [[ "\$(wc -c <"\$LOG_FILE")" -ge 1048576 ]]; then
    mv -f "\$LOG_FILE" "\$LOG_FILE.1"
  fi
}

log() {
  rotate_log
  printf '[%s] %s\n' "\$(date '+%F %T %z')" "\$*" >>"\$LOG_FILE"
}

if "\$NODE" "\$VERIFIER" --url http://127.0.0.1:8931/mcp --timeout 5000 >/dev/null 2>&1; then
  log "healthy: MCP initialize and tools/list succeeded"
  exit 0
fi

log "MCP unhealthy; restarting \$SERVICE_LABEL"
launchctl kickstart -k "\$DOMAIN/\$SERVICE_LABEL" >/dev/null 2>&1 || true
sleep 3

if "\$NODE" "\$VERIFIER" --url http://127.0.0.1:8931/mcp --timeout 5000 >/dev/null 2>&1; then
  log "healthy after restart"
  exit 0
fi

log "MCP remains unhealthy after restart"
exit 1
EOF

write_atomic "$watchdog_plist" 0644 <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$watchdog_label</string>
  <key>ProgramArguments</key><array><string>$watchdog_script</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>$interval</integer>
  <key>StandardOutPath</key><string>$log_dir/playwright-mcp-8931-watchdog.out</string>
  <key>StandardErrorPath</key><string>$log_dir/playwright-mcp-8931-watchdog.err</string>
</dict>
</plist>
EOF

plutil -lint "$service_plist" "$watchdog_plist" >/dev/null
bash -n "$watchdog_script"

if [[ -n "$output_root" ]]; then
  printf 'Generated Playwright MCP state under %s\n' "$output_root"
  exit 0
fi

for label in "$watchdog_label" "$service_label"; do
  launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
done

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

bootstrap_with_retry "$service_plist"
launchctl enable "$domain/$service_label" >/dev/null 2>&1 || true
launchctl kickstart -k "$domain/$service_label" >/dev/null

wait_for_mcp() {
  for _ in {1..60}; do
    if "$node_path" "$verifier" \
      --url http://127.0.0.1:8931/mcp \
      --timeout 2000 >/dev/null 2>&1; then
      return
    fi
    sleep 0.5
  done

  fail "Playwright MCP did not become ready within 30 seconds"
}

wait_for_mcp
bootstrap_with_retry "$watchdog_plist"
launchctl enable "$domain/$watchdog_label" >/dev/null 2>&1 || true

"$node_path" "$verifier" \
  --url http://127.0.0.1:8931/mcp \
  --browser

cat <<EOF
Local Playwright MCP ready:
  mode:      $mode
  endpoint:  http://127.0.0.1:8931/mcp
  service:   $service_label
  watchdog:  $watchdog_label
EOF
