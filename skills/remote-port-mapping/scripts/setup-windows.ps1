[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]*$')]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9._@:-]+$')]
    [string]$Remote,

    [string]$LocalHost = '127.0.0.1',

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 65535)]
    [int]$LocalPort,

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 65535)]
    [int]$RemotePort,

    [Parameter(Mandatory = $true)]
    [ValidateSet('tcp', 'http', 'ws', 'mcp')]
    [string]$Probe,

    [string]$ProbePath = '/',

    [string]$PublicIp = '',

    [ValidateRange(10, 86400)]
    [int]$Interval = 60,

    [string]$OutputRoot = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($ProbePath[0] -ne '/') {
    throw '-ProbePath must start with /.'
}
if ($LocalHost -notmatch '^[A-Za-z0-9.:-]+$') {
    throw 'Invalid -LocalHost.'
}
if ($PublicIp) {
    $parsedPublicIp = $null
    if (
        -not [System.Net.IPAddress]::TryParse(
            $PublicIp,
            [ref]$parsedPublicIp
        ) -or
        $parsedPublicIp.AddressFamily -ne
            [System.Net.Sockets.AddressFamily]::InterNetwork
    ) {
        throw '-PublicIp must be an IPv4 address.'
    }
}

$sshCommand = Get-Command ssh.exe -ErrorAction SilentlyContinue
if (-not $sshCommand) {
    if ($OutputRoot) {
        throw 'OpenSSH Client is required to generate a runnable task.'
    }
    Add-WindowsCapability -Online -Name 'OpenSSH.Client~~~~0.0.1.0' | Out-Null
    $env:Path = "$env:SystemRoot\System32\OpenSSH;$env:Path"
    $sshCommand = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if (-not $sshCommand) {
        throw 'OpenSSH Client installation failed.'
    }
}

$stateId = "$Name-$RemotePort"
$root = if ($OutputRoot) {
    Join-Path $OutputRoot 'RemotePortMapping'
} else {
    Join-Path $env:LOCALAPPDATA 'RemotePortMapping'
}
$stateDir = Join-Path $root $stateId
$logDir = Join-Path $stateDir 'logs'
$tunnelScript = Join-Path $stateDir 'tunnel.ps1'
$watchdogScript = Join-Path $stateDir 'watchdog.ps1'
$bridgeScript = Join-Path $stateDir 'public-bridge.ps1'
$manifestPath = Join-Path $stateDir 'mapping.json'
$tunnelTask = "RemotePortMapping-$stateId-Tunnel"
$watchdogTask = "RemotePortMapping-$stateId-Watchdog"
$bridgeTask = "RemotePortMapping-$stateId-PublicBridge"

New-Item -ItemType Directory -Force -Path $stateDir, $logDir | Out-Null

function Write-Utf8File {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    [System.IO.File]::WriteAllText(
        $Path,
        $Content,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Escape-SingleQuoted {
    param([string]$Value)
    return $Value.Replace("'", "''")
}

$sshPath = Escape-SingleQuoted $sshCommand.Source
$escapedRemote = Escape-SingleQuoted $Remote
$escapedLocalHost = Escape-SingleQuoted $LocalHost
$escapedProbePath = Escape-SingleQuoted $ProbePath
$escapedPublicIp = Escape-SingleQuoted $PublicIp
$escapedTunnelTask = Escape-SingleQuoted $tunnelTask
$escapedBridgeTask = Escape-SingleQuoted $bridgeTask
$escapedLogDir = Escape-SingleQuoted $logDir

$tunnelTemplate = @'
$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest
$log = '__LOG_DIR__\tunnel.log'

function Rotate-Log {
    if ((Test-Path $log) -and (Get-Item $log).Length -ge 1MB) {
        Move-Item -Force $log "$log.1"
    }
}

while ($true) {
    Rotate-Log
    & '__SSH__' -N -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -R '127.0.0.1:__REMOTE_PORT__:__LOCAL_HOST__:__LOCAL_PORT__' '__REMOTE__' *>> $log
    Start-Sleep -Seconds 5
}
'@
$tunnelContent = $tunnelTemplate
$tunnelContent = $tunnelContent.Replace('__LOG_DIR__', $escapedLogDir)
$tunnelContent = $tunnelContent.Replace('__SSH__', $sshPath)
$tunnelContent = $tunnelContent.Replace('__REMOTE_PORT__', [string]$RemotePort)
$tunnelContent = $tunnelContent.Replace('__LOCAL_HOST__', $escapedLocalHost)
$tunnelContent = $tunnelContent.Replace('__LOCAL_PORT__', [string]$LocalPort)
$tunnelContent = $tunnelContent.Replace('__REMOTE__', $escapedRemote)
Write-Utf8File -Path $tunnelScript -Content $tunnelContent

$bridgeTemplate = @'
$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest
$log = '__LOG_DIR__\public-bridge.log'

function Rotate-Log {
    if ((Test-Path $log) -and (Get-Item $log).Length -ge 1MB) {
        Move-Item -Force $log "$log.1"
    }
}

while ($true) {
    Rotate-Log
    & '__SSH__' -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 '__REMOTE__' 'exec socat TCP-LISTEN:__REMOTE_PORT__,bind=__PUBLIC_IP__,reuseaddr,fork TCP:127.0.0.1:__REMOTE_PORT__' *>> $log
    Start-Sleep -Seconds 5
}
'@
$bridgeContent = $bridgeTemplate
$bridgeContent = $bridgeContent.Replace('__LOG_DIR__', $escapedLogDir)
$bridgeContent = $bridgeContent.Replace('__SSH__', $sshPath)
$bridgeContent = $bridgeContent.Replace('__REMOTE__', $escapedRemote)
$bridgeContent = $bridgeContent.Replace('__REMOTE_PORT__', [string]$RemotePort)
$bridgeContent = $bridgeContent.Replace('__PUBLIC_IP__', $escapedPublicIp)
if ($PublicIp) {
    Write-Utf8File -Path $bridgeScript -Content $bridgeContent
}

$watchdogTemplate = @'
$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest
$ssh = '__SSH__'
$remote = '__REMOTE__'
$localHost = '__LOCAL_HOST__'
$localPort = __LOCAL_PORT__
$remotePort = __REMOTE_PORT__
$probe = '__PROBE__'
$probePath = '__PROBE_PATH__'
$publicIp = '__PUBLIC_IP__'
$interval = __INTERVAL__
$tunnelTask = '__TUNNEL_TASK__'
$bridgeTask = '__BRIDGE_TASK__'
$log = '__LOG_DIR__\watchdog.log'
$mcpPayload = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"remote-port-watchdog","version":"1"}}}'

function Rotate-Log {
    if ((Test-Path $log) -and (Get-Item $log).Length -ge 1MB) {
        Move-Item -Force $log "$log.1"
    }
}

function Write-HealthLog {
    param([string]$Message)
    Rotate-Log
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss K'), $Message
    Out-File -InputObject $line -FilePath $log -Append -Encoding utf8
}

function Test-McpEndpoint {
    param([string]$Url)
    $headers = @{
        Accept = 'application/json, text/event-stream'
    }
    $body = @{
        jsonrpc = '2.0'
        id = 1
        method = 'initialize'
        params = @{
            protocolVersion = '2025-03-26'
            capabilities = @{}
            clientInfo = @{ name = 'remote-port-watchdog'; version = '1' }
        }
    } | ConvertTo-Json -Depth 5 -Compress
    try {
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Method Post -Headers $headers -ContentType 'application/json' -Body $body -Uri $Url | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Test-WebSocketEndpoint {
    param([string]$Url)
    $socket = [System.Net.WebSockets.ClientWebSocket]::new()
    $cancellation = [System.Threading.CancellationTokenSource]::new()
    $cancellation.CancelAfter(5000)
    try {
        $socket.ConnectAsync([Uri]$Url, $cancellation.Token).GetAwaiter().GetResult()
        return $socket.State -eq [System.Net.WebSockets.WebSocketState]::Open
    } catch {
        return $false
    } finally {
        $socket.Dispose()
        $cancellation.Dispose()
    }
}

function Test-LocalTarget {
    switch ($probe) {
        'tcp' {
            return (Test-NetConnection -ComputerName $localHost -Port $localPort -InformationLevel Quiet -WarningAction SilentlyContinue)
        }
        'http' {
            try {
                $endpoint = "http://{0}:{1}{2}" -f $localHost, $localPort, $probePath
                Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 -Uri $endpoint | Out-Null
                return $true
            } catch {
                return $false
            }
        }
        'ws' {
            $endpoint = "ws://{0}:{1}{2}" -f $localHost, $localPort, $probePath
            return Test-WebSocketEndpoint $endpoint
        }
        'mcp' {
            $endpoint = "http://{0}:{1}/mcp" -f $localHost, $localPort
            return Test-McpEndpoint $endpoint
        }
    }
}

function Test-RemoteEndpoint {
    $remoteCommand = switch ($probe) {
        'tcp' {
            "if command -v nc >/dev/null 2>&1; then nc -z -w 3 127.0.0.1 {0}; else timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/{0}'; fi" -f $remotePort
        }
        'http' {
            $endpoint = "http://127.0.0.1:{0}{1}" -f $remotePort, $probePath
            "curl --noproxy '*' --fail --silent --max-time 5 '{0}' >/dev/null" -f $endpoint
        }
        'ws' {
            $endpoint = "http://127.0.0.1:{0}{1}" -f $remotePort, $probePath
            "curl --noproxy '*' --http1.1 --silent --max-time 3 -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' --write-out '%{{http_code}}' --output /dev/null '{0}' 2>/dev/null | grep -qx 101" -f $endpoint
        }
        'mcp' {
            $endpoint = "http://127.0.0.1:{0}/mcp" -f $remotePort
            "curl --noproxy '*' --fail --silent --max-time 5 -H 'Accept: application/json, text/event-stream' -H 'Content-Type: application/json' --data '{0}' '{1}' >/dev/null" -f $mcpPayload, $endpoint
        }
    }
    & $ssh -o BatchMode=yes -o ConnectTimeout=5 $remote $remoteCommand | Out-Null
    return $LASTEXITCODE -eq 0
}

function Test-RemotePublicEndpoint {
    if ([string]::IsNullOrWhiteSpace($publicIp)) {
        return $true
    }

    $remoteCommand = switch ($probe) {
        'tcp' {
            "nc -z -w 3 '{0}' {1}" -f $publicIp, $remotePort
        }
        'http' {
            $endpoint = "http://{0}:{1}{2}" -f $publicIp, $remotePort, $probePath
            "curl --noproxy '*' --fail --silent --max-time 5 '{0}' >/dev/null" -f $endpoint
        }
        'ws' {
            $endpoint = "http://{0}:{1}{2}" -f $publicIp, $remotePort, $probePath
            "curl --noproxy '*' --http1.1 --silent --max-time 3 -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' --write-out '%{{http_code}}' --output /dev/null '{0}' 2>/dev/null | grep -qx 101" -f $endpoint
        }
        'mcp' {
            $endpoint = "http://{0}:{1}/mcp" -f $publicIp, $remotePort
            "curl --noproxy '*' --fail --silent --max-time 5 -H 'Accept: application/json, text/event-stream' -H 'Content-Type: application/json' --data '{0}' '{1}' >/dev/null" -f $mcpPayload, $endpoint
        }
    }
    & $ssh -o BatchMode=yes -o ConnectTimeout=5 $remote $remoteCommand | Out-Null
    return $LASTEXITCODE -eq 0
}

while ($true) {
    if (-not (Test-LocalTarget)) {
        Write-HealthLog ("local target unhealthy: {0}:{1} probe={2}" -f $localHost, $localPort, $probe)
        Start-Sleep -Seconds $interval
        continue
    }

    if (-not (Test-RemoteEndpoint)) {
        Write-HealthLog "remote endpoint unhealthy; restarting $tunnelTask"
        Stop-ScheduledTask -TaskName $tunnelTask -ErrorAction SilentlyContinue
        Start-ScheduledTask -TaskName $tunnelTask -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }

    if (-not (Test-RemotePublicEndpoint)) {
        Write-HealthLog "remote public endpoint unhealthy; restarting $bridgeTask"
        Stop-ScheduledTask -TaskName $bridgeTask -ErrorAction SilentlyContinue
        Start-ScheduledTask -TaskName $bridgeTask -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }

    if ((Test-RemoteEndpoint) -and (Test-RemotePublicEndpoint)) {
        $publicStatus = if ($publicIp) { $publicIp } else { 'disabled' }
        Write-HealthLog ("healthy: local={0}:{1} remote=127.0.0.1:{2} public={3} probe={4}" -f $localHost, $localPort, $remotePort, $publicStatus, $probe)
    } else {
        Write-HealthLog 'unhealthy after restart'
    }
    Start-Sleep -Seconds $interval
}
'@
$watchdogContent = $watchdogTemplate
$watchdogContent = $watchdogContent.Replace('__SSH__', $sshPath)
$watchdogContent = $watchdogContent.Replace('__REMOTE__', $escapedRemote)
$watchdogContent = $watchdogContent.Replace('__LOCAL_HOST__', $escapedLocalHost)
$watchdogContent = $watchdogContent.Replace('__LOCAL_PORT__', [string]$LocalPort)
$watchdogContent = $watchdogContent.Replace('__REMOTE_PORT__', [string]$RemotePort)
$watchdogContent = $watchdogContent.Replace('__PROBE__', $Probe)
$watchdogContent = $watchdogContent.Replace('__PROBE_PATH__', $escapedProbePath)
$watchdogContent = $watchdogContent.Replace('__PUBLIC_IP__', $escapedPublicIp)
$watchdogContent = $watchdogContent.Replace('__INTERVAL__', [string]$Interval)
$watchdogContent = $watchdogContent.Replace('__TUNNEL_TASK__', $escapedTunnelTask)
$watchdogContent = $watchdogContent.Replace('__BRIDGE_TASK__', $escapedBridgeTask)
$watchdogContent = $watchdogContent.Replace('__LOG_DIR__', $escapedLogDir)
Write-Utf8File -Path $watchdogScript -Content $watchdogContent

$manifest = [ordered]@{
    name = $Name
    remote = $Remote
    localHost = $LocalHost
    localPort = $LocalPort
    remoteHost = '127.0.0.1'
    remotePort = $RemotePort
    probe = $Probe
    probePath = $ProbePath
    publicIp = $PublicIp
    interval = $Interval
    tasks = [ordered]@{
        tunnel = $tunnelTask
        watchdog = $watchdogTask
        publicBridge = if ($PublicIp) { $bridgeTask } else { $null }
    }
}
Write-Utf8File -Path $manifestPath -Content ($manifest | ConvertTo-Json -Depth 5)

if ($OutputRoot) {
    Write-Output "Generated mapping state under $OutputRoot"
    exit 0
}

& $sshCommand.Source -o BatchMode=yes -o ConnectTimeout=5 $Remote 'true'
if ($LASTEXITCODE -ne 0) {
    throw "Direct non-interactive SSH login failed: ssh $Remote"
}

$taskNames = @($tunnelTask, $watchdogTask)
if ($PublicIp) {
    & $sshCommand.Source -o BatchMode=yes -o ConnectTimeout=5 $Remote 'command -v socat >/dev/null'
    if ($LASTEXITCODE -ne 0) {
        throw 'Remote-IP mode requires socat on the remote machine.'
    }
    $taskNames += $bridgeTask
}

foreach ($taskName in $taskNames) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 1

$listenerCommand = "ss -ltnp 2>/dev/null | awk '`$4 ~ /:$RemotePort`$/ {print}'"
$occupied = & $sshCommand.Source -o BatchMode=yes -o ConnectTimeout=5 $Remote $listenerCommand
if ($occupied) {
    $occupied | Write-Error
    throw "Remote port $RemotePort remains occupied after stopping this mapping."
}

$userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1)

function Register-LoginTask {
    param(
        [string]$TaskName,
        [string]$ScriptPath
    )
    $arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`""
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
}

Register-LoginTask -TaskName $tunnelTask -ScriptPath $tunnelScript
if ($PublicIp) {
    Register-LoginTask -TaskName $bridgeTask -ScriptPath $bridgeScript
}
Register-LoginTask -TaskName $watchdogTask -ScriptPath $watchdogScript

Start-Sleep -Seconds 3
Write-Output @"
Mapping tasks registered:
  local target:    ${LocalHost}:${LocalPort}
  remote endpoint: 127.0.0.1:${RemotePort}
  remote public:   $(if ($PublicIp) { $PublicIp } else { 'disabled' })
  probe:           $Probe
  tunnel task:     $tunnelTask
  watchdog task:   $watchdogTask
"@
