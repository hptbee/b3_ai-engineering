param(
    [switch]$Fast
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $repoRoot
$timings = @()

function Invoke-PreflightStep {
    param(
        [string]$Name,
        [scriptblock]$Action
    )
    Write-Host "=== $Name ==="
    $t0 = Get-Date
    & $Action
    $code = $LASTEXITCODE
    $sec = [math]::Round(((Get-Date) - $t0).TotalSeconds, 2)
    $script:timings += [pscustomobject]@{ Step = $Name; Sec = $sec; Exit = $code }
    if ($code -ne 0) {
        $script:timings | Format-Table -AutoSize
        throw "Preflight step failed: $Name (exit $code)"
    }
}

try {
    Invoke-PreflightStep 'cargo fmt --check' { cargo fmt --check }
    Invoke-PreflightStep 'cargo clippy --all-targets -- -D warnings' { cargo clippy --all-targets -- -D warnings }

    if ($Fast) {
        Invoke-PreflightStep 'cargo build --bin b3' { cargo build --bin b3 }
        $b3Bin = Join-Path $repoRoot 'target\debug\b3.exe'
        Invoke-PreflightStep 'b3 context measure --strict' { & $b3Bin context measure --strict }
        Invoke-PreflightStep 'cargo test --lib --test eval_contracts' { cargo test --lib --test eval_contracts }
    } else {
        Invoke-PreflightStep 'cargo build --release' { cargo build --release }
        $b3Bin = Join-Path $repoRoot 'target\release\b3.exe'
        Invoke-PreflightStep 'b3 context measure --strict' { & $b3Bin context measure --strict }
        Invoke-PreflightStep 'cargo test' { cargo test }
    }

    Write-Host "`n=== Preflight Summary ==="
    $timings | Format-Table -AutoSize
} finally {
    Pop-Location
}
