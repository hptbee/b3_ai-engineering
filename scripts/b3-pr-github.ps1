# Thin PowerShell shim for native b3 pr (or legacy scripts/lib/b3-pr-github.mjs when B3_USE_LEGACY=1).
$ErrorActionPreference = 'Stop'

function ConvertTo-Win32Arg([string]$Arg) {
    if ($null -eq $Arg -or $Arg.Length -eq 0) { return '""' }
    if ($Arg -notmatch '[\s"]') { return $Arg }
    return '"' + ($Arg -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

if ($env:B3_USE_LEGACY -ne '1') {
    $b3Home = Split-Path -Parent $PSScriptRoot
    $b3BinName = if ([IO.Path]::DirectorySeparatorChar -eq '\') { 'b3.exe' } else { 'b3' }
    $b3Candidate = if ($env:B3_BIN -and (Test-Path -LiteralPath $env:B3_BIN -PathType Leaf)) {
        $env:B3_BIN
    } else {
        $relBin = Join-Path $b3Home "target\release\$b3BinName"
        if (Test-Path -LiteralPath $relBin -PathType Leaf) { $relBin } else { $null }
    }
    if ($b3Candidate) {
        if ($args.Count -eq 0) {
            [Console]::Out.WriteLine('{"status":"PR_INVALID_ARGS","error":"Missing subcommand (expected: fetch, reply, resolve, comment, reconcile)"}')
            exit 1
        }
        $sub = [string]$args[0]
        if ($sub -cnotin @('fetch', 'reconcile', 'reply', 'resolve', 'comment')) {
            [Console]::Out.WriteLine(('{"status":"PR_INVALID_ARGS","error":"Unknown subcommand: ' + ($sub -replace '\\', '\\\\' -replace '"', '\"') + ' (expected: fetch, reply, resolve, comment, reconcile)"}'))
            exit 1
        }
        $fwdArgs = New-Object System.Collections.Generic.List[string]
        [void]$fwdArgs.Add('pr')
        foreach ($a in $args) {
            [void]$fwdArgs.Add($(if ($null -eq $a) { '' } else { [string]$a }))
        }
        $psiB = New-Object System.Diagnostics.ProcessStartInfo
        $psiB.FileName = $b3Candidate
        $psiB.WorkingDirectory = (Get-Location -PSProvider FileSystem).ProviderPath
        $psiB.UseShellExecute = $false
        $psiB.RedirectStandardOutput = $false
        $psiB.RedirectStandardError = $false
        $psiB.RedirectStandardInput = $false
        if ($psiB.PSObject.Properties['ArgumentList']) {
            foreach ($na in $fwdArgs) { [void]$psiB.ArgumentList.Add($na) }
        } else {
            $psiB.Arguments = ($fwdArgs | ForEach-Object { ConvertTo-Win32Arg $_ }) -join ' '
        }
        $procB = [System.Diagnostics.Process]::Start($psiB)
        $procB.WaitForExit()
        $exitCodeB = $procB.ExitCode
        $procB.Dispose()
        exit $exitCodeB
    }
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
