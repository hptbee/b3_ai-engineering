param(
    [switch]$Fast,
    [switch]$SkipSecurity
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
        Invoke-PreflightStep 'cargo test --lib' { cargo test --lib }
        Invoke-PreflightStep 'measure-context.ps1 -Strict' {
            powershell -NoProfile -ExecutionPolicy Bypass -File scripts/measure-context.ps1 -Strict
        }
    } else {
        Invoke-PreflightStep 'cargo build --release' { cargo build --release }
        $env:B3_BIN = Join-Path $repoRoot 'target\release\b3.exe'
        Invoke-PreflightStep 'cargo test' { cargo test }
        Invoke-PreflightStep 'measure-context.ps1 -Strict' {
            powershell -NoProfile -ExecutionPolicy Bypass -File scripts/measure-context.ps1 -Strict
        }
        foreach ($suite in @(
            'scripts/smoke-ship-product.ps1',
            'scripts/validate-pr-feedback.ps1',
            'scripts/validate-research-ship.ps1',
            'scripts/validate-ship-behavior.ps1',
            'scripts/validate-standalone-commands.ps1',
            'scripts/validate-cursor-global.ps1',
            'scripts/validate-antigravity-global.ps1',
            'scripts/validate-model-preferences.ps1',
            'scripts/validate-tshirt-hierarchical.ps1',
            'scripts/validate-context-routing.ps1'
        )) {
            Invoke-PreflightStep $suite {
                powershell -NoProfile -ExecutionPolicy Bypass -File $suite
            }
        }
        if (-not $SkipSecurity) {
            $bash = (Get-Command bash -ErrorAction SilentlyContinue | Select-Object -First 1).Source
            if ($bash) {
                Invoke-PreflightStep 'validate-merge-security.sh' { & $bash ./scripts/validate-merge-security.sh }
                Invoke-PreflightStep 'validate-evals.sh' { & $bash ./scripts/validate-evals.sh }
            }
        }
    }

    Write-Host "`n=== Preflight Summary ==="
    $timings | Format-Table -AutoSize
} finally {
    Pop-Location
}
