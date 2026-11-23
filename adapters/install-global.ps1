# Unified global installer dispatcher for B3 AI Engineering (Cursor and Antigravity).
# Dispatches to adapters/cursor/install-global.ps1 and adapters/antigravity/install-plugin.ps1 without duplicating host logic.
# Usage: .\adapters\install-global.ps1 [-HostName cursor|antigravity|all] [-Action install|update|verify|uninstall] [-B3Home <dir>] [-CursorHome <dir>] [-AntigravityPluginRoot <dir>] [-UserHome <dir>] [-DryRun] [-Force]
param(
    [Parameter(Position = 0)]
    [ValidateSet('install', 'update', 'verify', 'uninstall')]
    [string]$Action = 'install',
    [ValidateSet('cursor', 'antigravity', 'all')]
    [string]$HostName = 'all',
    [string]$B3Home = '',
    [string]$CursorHome = '',
    [string]$AntigravityPluginRoot = '',
    [string]$UserHome = '',
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

$scriptRoot = $PSScriptRoot
if (-not $B3Home) {
    $B3Home = Split-Path -Parent $scriptRoot
}
if (-not (Test-Path -LiteralPath $B3Home -PathType Container)) {
    Fail "B3Home directory not found: $B3Home"
}
$B3Home = (Resolve-Path -LiteralPath $B3Home).Path.TrimEnd('\', '/')

$cursorScript = Join-Path $scriptRoot 'cursor\install-global.ps1'
$antigravityScript = Join-Path $scriptRoot 'antigravity\install-plugin.ps1'

if (($HostName -in @('cursor', 'all')) -and -not (Test-Path -LiteralPath $cursorScript -PathType Leaf)) {
    Fail "missing Cursor global installer: $cursorScript"
}
if (($HostName -in @('antigravity', 'all')) -and -not (Test-Path -LiteralPath $antigravityScript -PathType Leaf)) {
    Fail "missing Antigravity plugin installer: $antigravityScript"
}

$psExe = try { (Get-Process -Id $PID).Path } catch { $null }
if (-not $psExe) {
    $psExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
}

function Invoke-HostInstaller([string]$TargetHost, [string]$ScriptPath, [string[]]$ChildArgs) {
    $invArgs = New-Object System.Collections.Generic.List[string]
    $invArgs.Add('-NoProfile')
    if ($env:OS -eq 'Windows_NT') {
        $invArgs.Add('-ExecutionPolicy')
        $invArgs.Add('Bypass')
    }
    $invArgs.Add('-File')
    $invArgs.Add($ScriptPath)
    foreach ($a in $ChildArgs) { $invArgs.Add($a) }

    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & $psExe @invArgs 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevPref
    }
    $lines = @($raw | ForEach-Object { [string]$_ })
    return [PSCustomObject]@{
        Host  = $TargetHost
        Code  = [int]$exitCode
        Lines = $lines
    }
}

$overallExit = 0
$results = New-Object System.Collections.Generic.List[object]

if ($HostName -in @('cursor', 'all')) {
    Write-Output "=== [cursor] action=$Action ==="
    $cArgs = New-Object System.Collections.Generic.List[string]
    $cArgs.Add('-Action'); $cArgs.Add($Action)
    $cArgs.Add('-B3Home'); $cArgs.Add($B3Home)
    if ($CursorHome) { $cArgs.Add('-CursorHome'); $cArgs.Add($CursorHome) }
    if ($UserHome) { $cArgs.Add('-UserHome'); $cArgs.Add($UserHome) }
    if ($DryRun) { $cArgs.Add('-DryRun') }
    if ($Force) { $cArgs.Add('-Force') }
    $res = Invoke-HostInstaller 'cursor' $cursorScript $cArgs.ToArray()
    foreach ($ln in $res.Lines) { Write-Output $ln }
    if ($res.Code -ne 0) { $overallExit = 1 }
    $results.Add([PSCustomObject]@{ Host = 'cursor'; Code = $res.Code })
}

if ($HostName -in @('antigravity', 'all')) {
    Write-Output "=== [antigravity] action=$Action ==="
    $aArgs = New-Object System.Collections.Generic.List[string]
    $aArgs.Add('-Action'); $aArgs.Add($Action)
    $aArgs.Add('-B3Home'); $aArgs.Add($B3Home)
    if ($AntigravityPluginRoot) { $aArgs.Add('-PluginRoot'); $aArgs.Add($AntigravityPluginRoot) }
    if ($UserHome) { $aArgs.Add('-UserHome'); $aArgs.Add($UserHome) }
    if ($DryRun) { $aArgs.Add('-DryRun') }
    if ($Force) { $aArgs.Add('-Force') }
    $res = Invoke-HostInstaller 'antigravity' $antigravityScript $aArgs.ToArray()
    foreach ($ln in $res.Lines) { Write-Output $ln }
    if ($res.Code -ne 0) { $overallExit = 1 }
    $results.Add([PSCustomObject]@{ Host = 'antigravity'; Code = $res.Code })
}

foreach ($r in $results) {
    $st = if ($r.Code -eq 0) { 'OK' } else { 'FAIL' }
    Write-Output "host=$($r.Host) status=$st exit=$($r.Code)"
}

if ($overallExit -ne 0) {
    Write-Output "GLOBAL_FAIL: host=$HostName action=$Action"
    exit 1
}
Write-Output "GLOBAL_OK: host=$HostName action=$Action"
exit 0
