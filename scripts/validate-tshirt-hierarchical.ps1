# Focused dual-shell wrapper & platform parity tests for T-shirt diff-scope,
# review-inventory, and review-ledger (deterministic core coverage lives in Rust tests).
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate-tshirt-hierarchical.ps1
param(
    [switch]$AllowIncompleteBash
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'lib\global-test-helpers.ps1')
$guardShPosix = (To-PosixPath $root) + '/scripts/b3-guard.sh'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$sandbox = Join-Path $env:TEMP ('b3-tshirt-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox | Out-Null

try {
    # 1. Dual-shell PS vs Bash parity on diff-scope, review-inventory, and review-ledger
    $r1 = Join-Path $sandbox 'parity-repo'
    $r1Posix = $r1 -replace '\\', '/'
    Init-B3TestRepo -RepoPath $r1 -DefaultBranch 'main' -UserEmail 'tshirt-test@example.com' -UserName 'TShirt Test' -InitialCommit
    $base1 = (& git -C $r1 rev-parse HEAD).Trim()

    New-Item -ItemType Directory -Path (Join-Path $r1 'src/auth') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $r1 'src/auth/login.ts'), "export const ok = true;`n", $utf8NoBom)
    & git -C $r1 add src/auth/login.ts
    & git -C $r1 commit -q -m 'auth change'

    $psDs = Invoke-PsGuard @('diff-scope', '-RepoRoot', $r1, '-BaseSha', $base1)
    $shDs = if ($script:HasBash) { Invoke-ShCmd "'$guardShPosix' diff-scope --repo-root '$r1Posix' --base-sha '$base1'" } else { $psDs }
    if ($psDs.Code -eq 0 -and $shDs.Code -eq 0 -and $shDs.Text -ceq $psDs.Text -and $psDs.Text -match 'size_class=XS' -and $psDs.Text -match 'risk_level=CRITICAL') {
        Pass 'tshirt-diff-scope-dual-shell-parity'
    } else {
        FailCheck 'tshirt-diff-scope-dual-shell-parity' "ps=$($psDs.Code) sh=$($shDs.Code)"
    }

    $psInv = Invoke-PsGuard @('review-inventory', '-RepoRoot', $r1, '-BaseSha', $base1)
    $shInv = if ($script:HasBash) { Invoke-ShCmd "'$guardShPosix' review-inventory --repo-root '$r1Posix' --base-sha '$base1'" } else { $psInv }
    if ($psInv.Code -eq 0 -and $shInv.Code -eq 0 -and $shInv.Text -ceq $psInv.Text -and $psInv.Text -match 'unit\|U01\|') {
        Pass 'review-inventory-dual-shell-parity'
    } else {
        FailCheck 'review-inventory-dual-shell-parity' "ps=$($psInv.Code) sh=$($shInv.Code)"
    }

    $lp = '.b3/ship/runs/t1/review-ledger.md'
    $psInit = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r1, '-Action', 'init', '-LedgerPath', $lp, '-BaseSha', $base1)
    $psChk = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r1, '-Action', 'check', '-LedgerPath', $lp, '-BaseSha', $base1)
    $shChk = if ($script:HasBash) { Invoke-ShCmd "'$guardShPosix' review-ledger --repo-root '$r1Posix' --action check --ledger-path '$lp' --base-sha '$base1'" } else { $psChk }
    if ($psInit.Code -eq 0 -and $psChk.Code -eq 2 -and $shChk.Code -eq 2 -and $shChk.Text -ceq $psChk.Text) {
        Pass 'review-ledger-dual-shell-parity'
    } else {
        FailCheck 'review-ledger-dual-shell-parity' "init=$($psInit.Code) psChk=$($psChk.Code) shChk=$($shChk.Code)"
    }

    # 2. Platform-specific: diff.noprefix + diff.mnemonicPrefix + core.quotepath + MSYS '.' resolution
    & git -C $r1 config diff.noprefix true
    & git -C $r1 config diff.mnemonicPrefix true
    & git -C $r1 config core.quotepath true
    $psCfg = Invoke-PsGuard @('diff-scope', '-RepoRoot', $r1, '-BaseSha', $base1)
    $shDot = if ($script:HasBash) { Invoke-ShCmd "cd '$r1Posix' && '$guardShPosix' diff-scope --repo-root . --base-sha '$base1'" } else { $psCfg }
    if ($psCfg.Code -eq 0 -and $shDot.Code -eq 0 -and $shDot.Text -ceq $psCfg.Text) {
        Pass 'git-noprefix-quotepath-and-msys-dot-parity'
    } else {
        FailCheck 'git-noprefix-quotepath-and-msys-dot-parity' "ps=$($psCfg.Code) sh=$($shDot.Code)"
    }

    Complete-ValidationSuite -AllowIncompleteBash:$AllowIncompleteBash
} finally {
    Remove-ReparseLinksUnder $sandbox
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}
