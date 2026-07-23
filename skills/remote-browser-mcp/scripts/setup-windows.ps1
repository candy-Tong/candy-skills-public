[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('extension', 'managed')]
    [string]$Mode,

    [string]$TokenFile = '',

    [ValidateRange(10, 86400)]
    [int]$Interval = 60,

    [string]$OutputRoot = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Resolve-NodeCommands {
    $node = Get-Command node.exe -ErrorAction SilentlyContinue
    $npx = Get-Command npx.cmd -ErrorAction SilentlyContinue
    if ($node -and $npx) {
        return @($node.Source, $npx.Source)
    }

    if ($OutputRoot) {
        throw 'Node.js and npx are required to generate a runnable task.'
    }

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw 'Node.js is missing and winget is unavailable.'
    }
    & $winget.Source install --id OpenJS.NodeJS.LTS --exact --silent `
        --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw 'Node.js installation failed.'
    }

    $env:Path = "$env:ProgramFiles\nodejs;$env:Path"
    $node = Get-Command node.exe -ErrorAction SilentlyContinue
    $npx = Get-Command npx.cmd -ErrorAction SilentlyContinue
    if (-not $node -or -not $npx) {
        throw 'Node.js was installed but node or npx is not available.'
    }
    return @($node.Source, $npx.Source)
}

$commands = Resolve-NodeCommands
$nodePath = $commands[0]
$npxPath = $commands[1]

[string]$token = $env:PLAYWRIGHT_MCP_EXTENSION_TOKEN
if ($TokenFile) {
    if (-not (Test-Path $TokenFile -PathType Leaf)) {
        throw 'Token file does not exist.'
    }
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $allowedIdentities = @(
        $currentUser,
        'NT AUTHORITY\SYSTEM',
        'BUILTIN\Administrators'
    )
    $unsafeAccess = (Get-Acl $TokenFile).Access | Where-Object {
        $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
        $_.IdentityReference.Value -notin $allowedIdentities
    }
    if ($unsafeAccess) {
        throw 'Token file grants access to identities other than the current user, SYSTEM, or Administrators.'
    }
    $token = (Get-Content -Raw $TokenFile).Trim()
}
if ($token.StartsWith('PLAYWRIGHT_MCP_EXTENSION_TOKEN=')) {
    $token = $token.Substring('PLAYWRIGHT_MCP_EXTENSION_TOKEN='.Length)
}
if ($Mode -eq 'extension' -and [string]::IsNullOrWhiteSpace($token)) {
    throw 'Extension mode requires PLAYWRIGHT_MCP_EXTENSION_TOKEN or -TokenFile.'
}

$root = if ($OutputRoot) {
    Join-Path $OutputRoot 'RemoteBrowserMcp'
} else {
    Join-Path $env:LOCALAPPDATA 'RemoteBrowserMcp'
}
$stateDir = Join-Path $root '8931'
$logDir = Join-Path $stateDir 'logs'
$launcherScript = Join-Path $stateDir 'run-mcp.ps1'
$watchdogScript = Join-Path $stateDir 'watchdog.ps1'
$verifier = Join-Path $stateDir 'verify-mcp.mjs'
$serviceTask = 'RemoteBrowserMcp-8931-Service'
$watchdogTask = 'RemoteBrowserMcp-8931-Watchdog'

New-Item -ItemType Directory -Force -Path $stateDir, $logDir | Out-Null
Copy-Item -Force (Join-Path $PSScriptRoot 'verify-mcp.mjs') $verifier

function Write-Utf8File {
    param([string]$Path, [string]$Content)
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

$escapedNpx = Escape-SingleQuoted $npxPath
$escapedNode = Escape-SingleQuoted $nodePath
$escapedToken = Escape-SingleQuoted $token
$escapedLogDir = Escape-SingleQuoted $logDir
$escapedVerifier = Escape-SingleQuoted $verifier
$escapedServiceTask = Escape-SingleQuoted $serviceTask
$extensionArgument = if ($Mode -eq 'extension') { "'--extension'," } else { '' }

$launcherContent = @"
`$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest
`$env:PLAYWRIGHT_MCP_EXTENSION_TOKEN = '$escapedToken'
`$log = '$escapedLogDir\playwright-mcp-8931.log'
`$arguments = @(
    '-y',
    '@playwright/mcp@latest',
    $extensionArgument
    '--host',
    '127.0.0.1',
    '--port',
    '8931',
    '--allowed-hosts',
    'localhost:8931,127.0.0.1:8931,[::1]:8931'
)

function Rotate-Log {
    if ((Test-Path `$log) -and (Get-Item `$log).Length -ge 1MB) {
        Move-Item -Force `$log "`$log.1"
    }
}

while (`$true) {
    Rotate-Log
    & '$escapedNpx' `$arguments *>> `$log
    Start-Sleep -Seconds 5
}
"@
Write-Utf8File -Path $launcherScript -Content $launcherContent

$watchdogContent = @"
`$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest
`$node = '$escapedNode'
`$verifier = '$escapedVerifier'
`$serviceTask = '$escapedServiceTask'
`$interval = $Interval
`$log = '$escapedLogDir\watchdog.log'

function Rotate-Log {
    if ((Test-Path `$log) -and (Get-Item `$log).Length -ge 1MB) {
        Move-Item -Force `$log "`$log.1"
    }
}

function Write-HealthLog {
    param([string]`$Message)
    Rotate-Log
    "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss K'), `$Message |
        Out-File -FilePath `$log -Append -Encoding utf8
}

while (`$true) {
    & `$node `$verifier --url http://127.0.0.1:8931/mcp --timeout 5000 *> `$null
    if (`$LASTEXITCODE -eq 0) {
        Write-HealthLog 'healthy: MCP initialize and tools/list succeeded'
    } else {
        Write-HealthLog "MCP unhealthy; restarting `$serviceTask"
        Stop-ScheduledTask -TaskName `$serviceTask -ErrorAction SilentlyContinue
        Start-ScheduledTask -TaskName `$serviceTask -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds `$interval
}
"@
Write-Utf8File -Path $watchdogScript -Content $watchdogContent

if (-not $OutputRoot) {
    & icacls.exe $launcherScript /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
}

$manifest = [ordered]@{
    mode = $Mode
    endpoint = 'http://127.0.0.1:8931/mcp'
    interval = $Interval
    tasks = [ordered]@{
        service = $serviceTask
        watchdog = $watchdogTask
    }
}
Write-Utf8File -Path (Join-Path $stateDir 'mcp.json') `
    -Content ($manifest | ConvertTo-Json -Depth 4)

if ($OutputRoot) {
    Write-Output "Generated Playwright MCP state under $OutputRoot"
    exit 0
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
    param([string]$TaskName, [string]$ScriptPath)
    $arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`""
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
}

Stop-ScheduledTask -TaskName $watchdogTask -ErrorAction SilentlyContinue
Stop-ScheduledTask -TaskName $serviceTask -ErrorAction SilentlyContinue
Register-LoginTask -TaskName $serviceTask -ScriptPath $launcherScript
Register-LoginTask -TaskName $watchdogTask -ScriptPath $watchdogScript

Start-Sleep -Seconds 3
& $nodePath $verifier --url http://127.0.0.1:8931/mcp --browser
if ($LASTEXITCODE -ne 0) {
    throw 'Playwright MCP browser verification failed.'
}

Write-Output @"
Local Playwright MCP ready:
  mode:      $Mode
  endpoint:  http://127.0.0.1:8931/mcp
  service:   $serviceTask
  watchdog:  $watchdogTask
"@
