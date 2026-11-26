[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Mode = '',
    [string]$RepoRoot = '',
    [string]$Repo = '',
    [string]$PrNumber = '',
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ExtraArgs = @()
)

$ErrorActionPreference = 'Stop'

$b3Home = Split-Path -Parent $PSScriptRoot
$b3BinName = if ([IO.Path]::DirectorySeparatorChar -eq '\') { 'b3.exe' } else { 'b3' }
if ($env:B3_BIN) {
    if (-not (Test-Path -LiteralPath $env:B3_BIN -PathType Leaf)) {
        [Console]::Error.WriteLine("GH_VERIFY_UNAVAILABLE: b3_binary_unavailable (build with 'cargo build --release' or set B3_BIN)")
        exit 2
    }
    $b3Candidate = $env:B3_BIN
} else {
    $b3Candidate = $null
    foreach ($rel in @([IO.Path]::Combine('target', 'release', $b3BinName), [IO.Path]::Combine('target', 'debug', $b3BinName))) {
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
    [Console]::Error.WriteLine("GH_VERIFY_UNAVAILABLE: b3_binary_unavailable (build with 'cargo build --release' or set B3_BIN)")
    exit 2
}

$fwdArgs = New-Object System.Collections.Generic.List[string]
[void]$fwdArgs.Add('pr')
[void]$fwdArgs.Add('verify')
if ($PSBoundParameters.ContainsKey('Mode')) { [void]$fwdArgs.Add("--mode=$Mode") }
if ($PSBoundParameters.ContainsKey('RepoRoot')) { [void]$fwdArgs.Add("--repo-root=$RepoRoot") }
if ($PSBoundParameters.ContainsKey('Repo')) { [void]$fwdArgs.Add("--repo=$Repo") }
if ($PSBoundParameters.ContainsKey('PrNumber')) { [void]$fwdArgs.Add("--pr-number=$PrNumber") }
foreach ($ea in @($ExtraArgs)) { [void]$fwdArgs.Add([string]$ea) }

$psiB = New-Object System.Diagnostics.ProcessStartInfo
$psiB.FileName = $b3Candidate
$psiB.WorkingDirectory = (Get-Location -PSProvider FileSystem).ProviderPath
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
