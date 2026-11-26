param(
    [string]$RepoRoot,
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RepoRoot)

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

$b3Args = @('context', 'measure', "--repo-root=$RepoRoot")
if ($Strict) { $b3Args += '--strict' }
& $b3Candidate @b3Args
exit $LASTEXITCODE
