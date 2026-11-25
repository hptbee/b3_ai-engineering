# Thin PowerShell shim for scripts/lib/b3-pr-github.mjs (GitHub PR feedback adapter).
$ErrorActionPreference = 'Stop'

$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if (-not $nodeCmd) {
    [Console]::Out.WriteLine('{"status":"PR_API_ERROR","error":"node is required to run b3-pr-github"}')
    exit 1
}

$scriptPath = Join-Path (Join-Path $PSScriptRoot 'lib') 'b3-pr-github.mjs'
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    [Console]::Out.WriteLine('{"status":"PR_API_ERROR","error":"Missing scripts/lib/b3-pr-github.mjs"}')
    exit 1
}

& $nodeCmd.Source $scriptPath @args
exit $LASTEXITCODE
