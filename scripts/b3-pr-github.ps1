# Thin PowerShell shim for scripts/lib/b3-pr-github.mjs (GitHub PR feedback adapter).
$ErrorActionPreference = 'Stop'

function ConvertTo-Win32Arg([string]$Arg) {
    if ($null -eq $Arg -or $Arg.Length -eq 0) { return '""' }
    if ($Arg -notmatch '[\s"]') { return $Arg }
    return '"' + ($Arg -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

$nodeCmd = Get-Command node -CommandType Application -ErrorAction SilentlyContinue |
    Where-Object { $_.Source -and (($_.Source -replace '/', '\') -inotmatch '\\microsoft\\windowsapps\\') } |
    Select-Object -First 1
if (-not $nodeCmd) {
    [Console]::Out.WriteLine('{"status":"PR_API_ERROR","error":"node is required to run b3-pr-github"}')
    exit 1
}

$scriptPath = Join-Path (Join-Path $PSScriptRoot 'lib') 'b3-pr-github.mjs'
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    [Console]::Out.WriteLine('{"status":"PR_API_ERROR","error":"Missing scripts/lib/b3-pr-github.mjs"}')
    exit 1
}

$allArgs = New-Object System.Collections.Generic.List[string]
[void]$allArgs.Add([string]$scriptPath)
foreach ($a in $args) {
    [void]$allArgs.Add($(if ($null -eq $a) { '' } else { [string]$a }))
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $nodeCmd.Source
$psi.WorkingDirectory = (Get-Location -PSProvider FileSystem).ProviderPath
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $false
$psi.RedirectStandardError = $false
$psi.RedirectStandardInput = $false
if ($psi.PSObject.Properties['ArgumentList']) {
    foreach ($na in $allArgs) { [void]$psi.ArgumentList.Add($na) }
} else {
    $psi.Arguments = ($allArgs | ForEach-Object { ConvertTo-Win32Arg $_ }) -join ' '
}

$proc = [System.Diagnostics.Process]::Start($psi)
$proc.WaitForExit()
$exitCode = $proc.ExitCode
$proc.Dispose()
exit $exitCode
