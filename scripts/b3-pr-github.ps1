# Thin PowerShell shim forwarding to native `b3 pr`.
$ErrorActionPreference = 'Stop'

function ConvertTo-Win32Arg([string]$Arg) {
    if ($null -eq $Arg -or $Arg.Length -eq 0) { return '""' }
    if ($Arg -notmatch '[\s"]') { return $Arg }
    return '"' + ($Arg -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

$b3Home = Split-Path -Parent $PSScriptRoot
$b3BinName = if ([IO.Path]::DirectorySeparatorChar -eq '\') { 'b3.exe' } else { 'b3' }
if ($env:B3_BIN) {
    if (-not (Test-Path -LiteralPath $env:B3_BIN -PathType Leaf)) {
        [Console]::Error.WriteLine("b3 native binary not found; build with 'cargo build --release' or set B3_BIN")
        exit 1
    }
    $b3Candidate = $env:B3_BIN
} else {
    $b3Candidate = $null
    foreach ($rel in @("target\release\$b3BinName", "target\debug\$b3BinName")) {
        $cand = Join-Path $b3Home $rel
        if (Test-Path -LiteralPath $cand -PathType Leaf) { $b3Candidate = $cand; break }
    }
    if (-not $b3Candidate) {
        $cmdBin = Get-Command b3 -CommandType Application -ErrorAction SilentlyContinue |
            Where-Object { $_.Source -and (($_.Source -replace '/', '\') -inotmatch '\\microsoft\\windowsapps\\') } |
            Select-Object -First 1
        if ($cmdBin) { $b3Candidate = $cmdBin.Source }
    }
}
if (-not $b3Candidate) {
    [Console]::Error.WriteLine("b3 native binary not found; build with 'cargo build --release' or set B3_BIN")
    exit 1
}

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
if (-not $procB) { exit 1 }
try {
    $procB.WaitForExit()
    exit ([int]$procB.ExitCode)
} finally {
    $procB.Dispose()
}
