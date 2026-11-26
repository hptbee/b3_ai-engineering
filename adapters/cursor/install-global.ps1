# Global Cursor installer for B3 AI Engineering (Windows PowerShell / pwsh).
# Usage: .\adapters\cursor\install-global.ps1 [-Action install|update|verify|uninstall] [-CursorHome <dir>] [-B3Home <dir>] [-UserHome <dir>] [-DryRun] [-Force]
param(
    [Parameter(Position = 0)]
    [ValidateSet('install', 'update', 'verify', 'uninstall')]
    [string]$Action = 'install',
    [string]$CursorHome = '',
    [string]$B3Home = '',
    [string]$UserHome = '',
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$b3RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
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
        $cand = Join-Path $b3RepoRoot $rel
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

$effectiveHome = if ($B3Home) { $B3Home } else { $b3RepoRoot }
$fwdArgs = New-Object System.Collections.Generic.List[string]
[void]$fwdArgs.Add('install')
[void]$fwdArgs.Add('cursor')
[void]$fwdArgs.Add("--action=$Action")
[void]$fwdArgs.Add("--b3-home=$effectiveHome")
if ($CursorHome) { [void]$fwdArgs.Add("--cursor-home=$CursorHome") }
if ($UserHome) { [void]$fwdArgs.Add("--user-home=$UserHome") }
if ($DryRun) { [void]$fwdArgs.Add('--dry-run') }
if ($Force) { [void]$fwdArgs.Add('--force') }

$psiB = New-Object System.Diagnostics.ProcessStartInfo
$psiB.FileName = $b3Candidate
$psiB.UseShellExecute = $false
$psiB.RedirectStandardOutput = $true
$psiB.RedirectStandardError = $true
$psiB.CreateNoWindow = $true
$utf8B = New-Object System.Text.UTF8Encoding($false)
$psiB.StandardOutputEncoding = $utf8B
$psiB.StandardErrorEncoding = $utf8B
if ($psiB.PSObject.Properties['ArgumentList']) {
    foreach ($fa in $fwdArgs) { [void]$psiB.ArgumentList.Add($fa) }
} else {
    $psiB.Arguments = (($fwdArgs | ForEach-Object {
        if ($null -eq $_ -or $_.Length -eq 0) { '""' }
        elseif ($_ -match '[\s"]') { '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }
        else { $_ }
    }) -join ' ')
}
$pB = [System.Diagnostics.Process]::Start($psiB)
if (-not $pB) { exit 1 }
try {
    $eBTask = $pB.StandardError.ReadToEndAsync()
    $oBTask = $pB.StandardOutput.ReadToEndAsync()
    $pB.WaitForExit()
    $oBTxt = $oBTask.GetAwaiter().GetResult()
    $eBTxt = $eBTask.GetAwaiter().GetResult()
    $ecB = [int]$pB.ExitCode
    if ($oBTxt) {
        $linesB = $oBTxt -split "\r?\n"
        $endB = $linesB.Length
        if ($endB -gt 0 -and $linesB[$endB - 1] -eq '') { $endB-- }
        for ($ib = 0; $ib -lt $endB; $ib++) { Write-Output $linesB[$ib] }
    }
    if ($eBTxt) {
        [Console]::Error.Write($eBTxt)
        [Console]::Error.Flush()
    }
    exit $ecB
} finally {
    $pB.Dispose()
}
