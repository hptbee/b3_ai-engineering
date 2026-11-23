# Behavioral checks for the six standalone commands (/b3-plan, /b3-implement, /b3-debug, /b3-review, /b3-review-loop, /b3-verify).
# Tests guard/verification/state-isolation/contract behavior in isolated sandboxes (not host IDE UI discovery).
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate-standalone-commands.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$guardPs = Join-Path $root 'scripts\b3-guard.ps1'
$guardShPosix = ($root -replace '\\', '/') + '/scripts/b3-guard.sh'
$gitBash = 'C:\Program Files\Git\bin\bash.exe'
$hasBash = Test-Path -LiteralPath $gitBash -PathType Leaf
$failed = 0

function Pass([string]$Name) { Write-Output "PASS $Name" }
function FailCheck([string]$Name, [string]$Detail) {
    Write-Output "FAIL $Name :: $Detail"
    $script:failed++
}

function Invoke-PsGuard([string[]]$GuardArgs) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & powershell -NoProfile -File $guardPs @GuardArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    $lines = @($raw | ForEach-Object { ([string]$_).TrimEnd("`r") })
    return @{ Code = $code; Lines = $lines; Text = ($lines -join "`n") }
}

function Invoke-ShGuard([string]$BashCmd) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & $gitBash -c $BashCmd 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    $lines = @($raw | ForEach-Object { ([string]$_).TrimEnd("`r") })
    return @{ Code = $code; Lines = $lines; Text = ($lines -join "`n") }
}

function Init-TestRepo([string]$DirPath) {
    New-Item -ItemType Directory -Path $DirPath | Out-Null
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        Push-Location $DirPath
        & git init -q
        & git config user.email 'standalone-test@example.com'
        & git config user.name 'Standalone Test'
    } finally {
        Pop-Location -ErrorAction SilentlyContinue
        $ErrorActionPreference = $prev
    }
}

$sandbox = Join-Path $env:TEMP ('b3-standalone-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox | Out-Null

try {
    # --- 1. standalone-verify-provenance ---
    $r1 = Join-Path $sandbox 'prov-repo'
    $r1Posix = $r1 -replace '\\', '/'
    Init-TestRepo $r1
    New-Item -ItemType Directory -Path (Join-Path $r1 'src') | Out-Null
    Set-Content (Join-Path $r1 'src\a.ts') "export const a = 1;`n"
    Push-Location $r1
    & git add .; & git commit -qm 'init'
    Pop-Location

    $seed = Invoke-PsGuard @('verify-run', '-RepoRoot', $r1, '-VerifyCmd', 'echo prov-ok', '-ReceiptPath', '.b3/ship/verify/seed.verify', '-RelevantPaths', 'src/a.ts')
    $seedCheckPs = Invoke-PsGuard @('verify-check', '-RepoRoot', $r1, '-ReceiptPath', '.b3/ship/verify/seed.verify')

    $headSha = (& git -C $r1 rev-parse HEAD).Trim()
    $treeMatch = [regex]::Match((Get-Content (Join-Path $r1 '.b3\ship\verify\seed.verify') -Raw), 'tree_hash=([0-9a-f]{40})')
    $treeSha = if ($treeMatch.Success) { $treeMatch.Groups[1].Value } else { '' }
    Set-Content (Join-Path $sandbox 'escape.log') "outside repo`n"

    $badDir = Join-Path $r1 '.b3\ship\verify'
    Set-Content (Join-Path $badDir 'nocmd.verify') "schema=b3-verify-v1`ntask_id=t1`nscope=scoped`nhead_sha=$headSha`ntree_hash=$treeSha`nrelevant_paths=src/a.ts`nexit_code=0`nstatus=PASS`nlog_path=none`ntimestamp_utc=2026-11-22T10:00:00Z`n"
    Set-Content (Join-Path $badDir 'badts.verify') "schema=b3-verify-v1`ntask_id=t1`nscope=scoped`nhead_sha=$headSha`ntree_hash=$treeSha`nrelevant_paths=src/a.ts`nexit_code=0`nstatus=PASS`ncommand=echo ok`nlog_path=none`ntimestamp_utc=bad-time`n"
    Set-Content (Join-Path $badDir 'misslog.verify') "schema=b3-verify-v1`ntask_id=t1`nscope=scoped`nhead_sha=$headSha`ntree_hash=$treeSha`nrelevant_paths=src/a.ts`nexit_code=0`nstatus=PASS`ncommand=echo ok`nlog_path=.b3/ship/verify/missing.log`ntimestamp_utc=2026-11-22T10:00:00Z`n"
    Set-Content (Join-Path $badDir 'travlog.verify') "schema=b3-verify-v1`ntask_id=t1`nscope=scoped`nhead_sha=$headSha`ntree_hash=$treeSha`nrelevant_paths=src/a.ts`nexit_code=0`nstatus=PASS`ncommand=echo ok`nlog_path=../escape.log`ntimestamp_utc=2026-11-22T10:00:00Z`n"
    Set-Content (Join-Path $badDir 'abslog.verify') "schema=b3-verify-v1`ntask_id=t1`nscope=scoped`nhead_sha=$headSha`ntree_hash=$treeSha`nrelevant_paths=src/a.ts`nexit_code=0`nstatus=PASS`ncommand=echo ok`nlog_path=/etc/passwd`ntimestamp_utc=2026-11-22T10:00:00Z`n"

    $outJuncDir = Join-Path $sandbox 'outside-logs'
    New-Item -ItemType Directory -Path $outJuncDir | Out-Null
    Set-Content (Join-Path $outJuncDir 'secret.log') "outside secret`n"
    $juncPath = Join-Path $badDir 'extlink'
    & cmd /c mklink /J $juncPath $outJuncDir | Out-Null
    $juncExit = $LASTEXITCODE
    Set-Content (Join-Path $badDir 'junclog.verify') "schema=b3-verify-v1`ntask_id=t1`nscope=scoped`nhead_sha=$headSha`ntree_hash=$treeSha`nrelevant_paths=src/a.ts`nexit_code=0`nstatus=PASS`ncommand=echo ok`nlog_path=.b3/ship/verify/extlink/secret.log`ntimestamp_utc=2026-11-22T10:00:00Z`n"

    $psNoCmd = Invoke-PsGuard @('verify-check', '-RepoRoot', $r1, '-ReceiptPath', '.b3/ship/verify/nocmd.verify')
    $psBadTs = Invoke-PsGuard @('verify-check', '-RepoRoot', $r1, '-ReceiptPath', '.b3/ship/verify/badts.verify')
    $psMissLog = Invoke-PsGuard @('verify-check', '-RepoRoot', $r1, '-ReceiptPath', '.b3/ship/verify/misslog.verify')
    $psTravLog = Invoke-PsGuard @('verify-check', '-RepoRoot', $r1, '-ReceiptPath', '.b3/ship/verify/travlog.verify')
    $psAbsLog = Invoke-PsGuard @('verify-check', '-RepoRoot', $r1, '-ReceiptPath', '.b3/ship/verify/abslog.verify')
    $psJuncLog = Invoke-PsGuard @('verify-check', '-RepoRoot', $r1, '-ReceiptPath', '.b3/ship/verify/junclog.verify')

    $provShOk = $true
    if ($hasBash) {
        $shSeed = Invoke-ShGuard "'$guardShPosix' verify-check --repo-root '$r1Posix' --receipt-path '.b3/ship/verify/seed.verify'"
        $shNoCmd = Invoke-ShGuard "'$guardShPosix' verify-check --repo-root '$r1Posix' --receipt-path '.b3/ship/verify/nocmd.verify'"
        $shBadTs = Invoke-ShGuard "'$guardShPosix' verify-check --repo-root '$r1Posix' --receipt-path '.b3/ship/verify/badts.verify'"
        $shMissLog = Invoke-ShGuard "'$guardShPosix' verify-check --repo-root '$r1Posix' --receipt-path '.b3/ship/verify/misslog.verify'"
        $shTravLog = Invoke-ShGuard "'$guardShPosix' verify-check --repo-root '$r1Posix' --receipt-path '.b3/ship/verify/travlog.verify'"
        $shAbsLog = Invoke-ShGuard "'$guardShPosix' verify-check --repo-root '$r1Posix' --receipt-path '.b3/ship/verify/abslog.verify'"
        $shJuncLog = Invoke-ShGuard "'$guardShPosix' verify-check --repo-root '$r1Posix' --receipt-path '.b3/ship/verify/junclog.verify'"
        $provShOk = ($shSeed.Code -eq 0) -and ($shSeed.Text -match 'VERIFY_VALID:') -and
                    ($shNoCmd.Code -eq 1) -and ($shNoCmd.Text -match "VERIFY_CORRUPT: missing field 'command'") -and
                    ($shBadTs.Code -eq 1) -and ($shBadTs.Text -match 'VERIFY_CORRUPT: invalid timestamp_utc') -and
                    ($shMissLog.Code -eq 1) -and ($shMissLog.Text -match 'VERIFY_CORRUPT: missing log_path') -and
                    ($shTravLog.Code -eq 1) -and ($shTravLog.Text -match 'VERIFY_CORRUPT: invalid log_path') -and
                    ($shAbsLog.Code -eq 1) -and ($shAbsLog.Text -match 'VERIFY_CORRUPT: invalid log_path') -and
                    ($shJuncLog.Code -eq 1) -and ($shJuncLog.Text -match 'VERIFY_CORRUPT: invalid log_path')
    }
    if (Test-Path -LiteralPath $juncPath) { [IO.Directory]::Delete($juncPath) }

    if ($seed.Code -eq 0 -and $seedCheckPs.Code -eq 0 -and $juncExit -eq 0 -and
        $psNoCmd.Code -eq 1 -and ($psNoCmd.Text -match "VERIFY_CORRUPT: missing field 'command'") -and
        $psBadTs.Code -eq 1 -and ($psBadTs.Text -match 'VERIFY_CORRUPT: invalid timestamp_utc') -and
        $psMissLog.Code -eq 1 -and ($psMissLog.Text -match 'VERIFY_CORRUPT: missing log_path') -and
        $psTravLog.Code -eq 1 -and ($psTravLog.Text -match 'VERIFY_CORRUPT: invalid log_path') -and
        $psAbsLog.Code -eq 1 -and ($psAbsLog.Text -match 'VERIFY_CORRUPT: invalid log_path') -and
        $psJuncLog.Code -eq 1 -and ($psJuncLog.Text -match 'VERIFY_CORRUPT: invalid log_path') -and $provShOk) {
        Pass 'standalone-verify-provenance'
    } else {
        FailCheck 'standalone-verify-provenance' "seed=$($seed.Code) juncExit=$juncExit psNoCmd=$($psNoCmd.Text) psBadTs=$($psBadTs.Text) psMiss=$($psMissLog.Text) psTrav=$($psTravLog.Text) psAbs=$($psAbsLog.Text) psJunc=$($psJuncLog.Text) shOk=$provShOk"
    }

    # --- 2. standalone-verify-cmd-and-scope ---
    $r2 = Join-Path $sandbox 'scope-repo'
    $r2Posix = $r2 -replace '\\', '/'
    Init-TestRepo $r2
    New-Item -ItemType Directory -Path (Join-Path $r2 'src') | Out-Null
    Set-Content (Join-Path $r2 'src\a.ts') "export const a = 1;`n"
    Set-Content (Join-Path $r2 'package.json') "{`"name`":`"x`"}"
    Push-Location $r2
    & git add .; & git commit -qm 'init'
    Pop-Location

    $vrScoped = Invoke-PsGuard @('verify-run', '-RepoRoot', $r2, '-VerifyCmd', 'echo check-unit', '-ReceiptPath', '.b3/ship/verify/unit.verify', '-RelevantPaths', 'src/a.ts')
    $psCmdOk = Invoke-PsGuard @('verify-check', '-RepoRoot', $r2, '-ReceiptPath', '.b3/ship/verify/unit.verify', '-ExpectedCmd', 'echo check-unit', '-RelevantPaths', 'src/a.ts')
    $psCmdBad = Invoke-PsGuard @('verify-check', '-RepoRoot', $r2, '-ReceiptPath', '.b3/ship/verify/unit.verify', '-ExpectedCmd', 'echo check-all')
    $psScopeBad = Invoke-PsGuard @('verify-check', '-RepoRoot', $r2, '-ReceiptPath', '.b3/ship/verify/unit.verify', '-RelevantPaths', 'src/a.ts,package.json')

    $vrAll = Invoke-PsGuard @('verify-run', '-RepoRoot', $r2, '-VerifyCmd', 'echo full-suite', '-ReceiptPath', '.b3/ship/verify/all.verify')
    $psAllCovers = Invoke-PsGuard @('verify-check', '-RepoRoot', $r2, '-ReceiptPath', '.b3/ship/verify/all.verify', '-ExpectedCmd', 'echo full-suite', '-RelevantPaths', 'src/a.ts,package.json')

    $scopeShOk1 = $true
    if ($hasBash) {
        $shCmdOk = Invoke-ShGuard "'$guardShPosix' verify-check --repo-root '$r2Posix' --receipt-path '.b3/ship/verify/unit.verify' --expected-cmd 'echo check-unit' --relevant-paths 'src/a.ts'"
        $shCmdBad = Invoke-ShGuard "'$guardShPosix' verify-check --repo-root '$r2Posix' --receipt-path '.b3/ship/verify/unit.verify' --expected-cmd 'echo check-all'"
        $shScopeBad = Invoke-ShGuard "'$guardShPosix' verify-check --repo-root '$r2Posix' --receipt-path '.b3/ship/verify/unit.verify' --relevant-paths 'src/a.ts,package.json'"
        $shAllCovers = Invoke-ShGuard "'$guardShPosix' verify-check --repo-root '$r2Posix' --receipt-path '.b3/ship/verify/all.verify' --expected-cmd 'echo full-suite' --relevant-paths 'src/a.ts,package.json'"
        $scopeShOk1 = ($shCmdOk.Code -eq 0) -and ($shCmdOk.Text -match 'VERIFY_VALID:') -and
                      ($shCmdBad.Code -eq 1) -and ($shCmdBad.Text -match 'VERIFY_MISMATCH: command mismatch') -and
                      ($shScopeBad.Code -eq 1) -and ($shScopeBad.Text -match 'VERIFY_SCOPE_MISMATCH: uncovered path \(package\.json\)') -and
                      ($shAllCovers.Code -eq 0) -and ($shAllCovers.Text -match 'VERIFY_VALID:')
    }

    # Edit dependency manifest -> ALL receipt turns VERIFY_STALE (exit 2)
    Set-Content (Join-Path $r2 'package.json') "{`"name`":`"x`",`"version`":`"2`"}"
    $psAllStale = Invoke-PsGuard @('verify-check', '-RepoRoot', $r2, '-ReceiptPath', '.b3/ship/verify/all.verify', '-RelevantPaths', 'src/a.ts,package.json')
    $scopeShOk2 = $true
    if ($hasBash) {
        $shAllStale = Invoke-ShGuard "'$guardShPosix' verify-check --repo-root '$r2Posix' --receipt-path '.b3/ship/verify/all.verify' --relevant-paths 'src/a.ts,package.json'"
        $scopeShOk2 = ($shAllStale.Code -eq 2) -and ($shAllStale.Text -match 'VERIFY_STALE:')
    }

    if ($vrScoped.Code -eq 0 -and $psCmdOk.Code -eq 0 -and
        $psCmdBad.Code -eq 1 -and ($psCmdBad.Text -match 'VERIFY_MISMATCH: command mismatch') -and
        $psScopeBad.Code -eq 1 -and ($psScopeBad.Text -match 'VERIFY_SCOPE_MISMATCH: uncovered path \(package\.json\)') -and
        $vrAll.Code -eq 0 -and $psAllCovers.Code -eq 0 -and
        $psAllStale.Code -eq 2 -and ($psAllStale.Text -match 'VERIFY_STALE:') -and
        $scopeShOk1 -and $scopeShOk2) {
        Pass 'standalone-verify-cmd-and-scope'
    } else {
        FailCheck 'standalone-verify-cmd-and-scope' "cmdOk=$($psCmdOk.Code) cmdBad=$($psCmdBad.Text) scopeBad=$($psScopeBad.Text) allCovers=$($psAllCovers.Code) stale=$($psAllStale.Text) sh1=$scopeShOk1 sh2=$scopeShOk2"
    }

    # --- 3. standalone-verify-large-output-cap (>64KB exit 1, capped stdout <= 36 lines, full .log preserved) ---
    $psBig = Invoke-PsGuard @('verify-run', '-RepoRoot', $r2, '-VerifyCmd', '1..1500 | ForEach-Object { 10001..10010 -join 9 }; exit 2', '-ReceiptPath', '.b3/ship/verify/psbig.verify')
    $psBigLog = Join-Path $r2 '.b3\ship\verify\psbig.verify.log'
    $psBigLogCount = if (Test-Path -LiteralPath $psBigLog) { (Get-Content -LiteralPath $psBigLog).Count } else { 0 }

    $bigShOk = $true
    if ($hasBash) {
        $shBig = Invoke-ShGuard "'$guardShPosix' verify-run --repo-root '$r2Posix' --verify-cmd 'seq 1 15000; exit 2' --receipt-path '.b3/ship/verify/shbig.verify'"
        $shBigLog = Join-Path $r2 '.b3\ship\verify\shbig.verify.log'
        $shBigLogCount = if (Test-Path -LiteralPath $shBigLog) { (Get-Content -LiteralPath $shBigLog).Count } else { 0 }
        $bigShOk = ($shBig.Code -eq 1) -and ($shBig.Text -match 'VERIFY_FAIL: exit=2 ') -and ($shBig.Lines.Count -le 36) -and ($shBigLogCount -ge 15000)
    }

    if ($psBig.Code -eq 1 -and ($psBig.Text -match 'VERIFY_FAIL: exit=2 ') -and ($psBig.Lines.Count -le 36) -and ($psBigLogCount -ge 1500) -and $bigShOk) {
        Pass 'standalone-verify-large-output-cap'
    } else {
        FailCheck 'standalone-verify-large-output-cap' "psCode=$($psBig.Code) psLines=$($psBig.Lines.Count) psLog=$psBigLogCount shOk=$bigShOk"
    }

    # --- 4. standalone-state-isolation ---
    $r3 = Join-Path $sandbox 'iso-repo'
    $r3Posix = $r3 -replace '\\', '/'
    Init-TestRepo $r3
    New-Item -ItemType Directory -Path (Join-Path $r3 'src') | Out-Null
    Set-Content (Join-Path $r3 'src\app.ts') "export const v = 1;`n"
    Push-Location $r3
    & git add .; & git commit -qm 'init'
    Pop-Location
    Set-Content (Join-Path $r3 'src\app.ts') "export const v = 2;`n"

    $vrIso = Invoke-PsGuard @('verify-run', '-RepoRoot', $r3, '-VerifyCmd', 'echo iso-ok', '-ReceiptPath', '.b3/ship/verify/claim.verify', '-RelevantPaths', 'src/app.ts')
    New-Item -ItemType Directory -Path (Join-Path $r3 '.b3\ship\review-loop\r1\logs') -Force | Out-Null
    Set-Content (Join-Path $r3 '.b3\ship\review-loop\r1\state.md') "iter: 1`n"
    Set-Content (Join-Path $r3 '.b3\ship\review-loop\r1\logs\iter1.log') "ok`n"

    $psDiff = Invoke-PsGuard @('diff-scope', '-RepoRoot', $r3, '-BaseSha', 'HEAD')
    $psVcIso = Invoke-PsGuard @('verify-check', '-RepoRoot', $r3, '-ReceiptPath', '.b3/ship/verify/claim.verify')
    $psRes = Invoke-PsGuard @('resolve-run', '-RepoRoot', $r3)

    # Modify standalone review-loop state file -> verify receipt remains VALID
    Set-Content (Join-Path $r3 '.b3\ship\review-loop\r1\state.md') "iter: 2`n"
    $psVcIso2 = Invoke-PsGuard @('verify-check', '-RepoRoot', $r3, '-ReceiptPath', '.b3/ship/verify/claim.verify')

    $isoShOk = $true
    if ($hasBash) {
        $shDiff = Invoke-ShGuard "'$guardShPosix' diff-scope --repo-root '$r3Posix' --base-sha HEAD"
        $shVcIso = Invoke-ShGuard "'$guardShPosix' verify-check --repo-root '$r3Posix' --receipt-path '.b3/ship/verify/claim.verify'"
        $shRes = Invoke-ShGuard "'$guardShPosix' resolve-run --repo-root '$r3Posix'"
        $isoShOk = ($shDiff.Code -eq 0) -and ($shDiff.Text -match 'review_files=src/app\.ts') -and ($shDiff.Text -notmatch '\.b3/') -and
                   ($shVcIso.Code -eq 0) -and ($shRes.Code -eq 1) -and ($shRes.Text -match 'NO_ACTIVE_RUN')
    }

    Push-Location $r3
    & git add -f '.b3/ship/review-loop/r1/state.md'
    Pop-Location
    $psPcBlk = Invoke-PsGuard @('precommit', '-RepoRoot', $r3, '-AllowedPaths', 'src/app.ts,.b3/ship/review-loop/r1/state.md')
    $isoPcShOk = $true
    if ($hasBash) {
        $shPcBlk = Invoke-ShGuard "'$guardShPosix' precommit --repo-root '$r3Posix' --allowed-paths 'src/app.ts,.b3/ship/review-loop/r1/state.md'"
        $isoPcShOk = ($shPcBlk.Code -eq 1) -and ($shPcBlk.Text -match 'checkpoint staged')
    }

    if ($vrIso.Code -eq 0 -and $psDiff.Code -eq 0 -and ($psDiff.Text -match 'review_files=src/app\.ts') -and ($psDiff.Text -notmatch '\.b3/') -and
        $psVcIso.Code -eq 0 -and $psVcIso2.Code -eq 0 -and $psRes.Code -eq 1 -and ($psRes.Text -match 'NO_ACTIVE_RUN') -and
        $psPcBlk.Code -eq 1 -and ($psPcBlk.Text -match 'checkpoint staged') -and $isoShOk -and $isoPcShOk) {
        Pass 'standalone-state-isolation'
    } else {
        FailCheck 'standalone-state-isolation' "diff=$($psDiff.Text) vc=$($psVcIso2.Text) res=$($psRes.Text) pc=$($psPcBlk.Text) shOk=$isoShOk pcSh=$isoPcShOk"
    }

    # --- 5. standalone-review-loop-cycle (delta loop without /b3-ship) ---
    $r4 = Join-Path $sandbox 'loop-repo'
    $r4Posix = $r4 -replace '\\', '/'
    Init-TestRepo $r4
    New-Item -ItemType Directory -Path (Join-Path $r4 'src') | Out-Null
    Set-Content (Join-Path $r4 'src\calc.ts') "export function keepFn(x: number) { return x + 1; }`nexport function dropFn(x: number) { return x - 1; }`n"
    Set-Content (Join-Path $r4 'src\caller.ts') "import { keepFn, dropFn } from './calc';`nexport const val = keepFn(1) + dropFn(2);`n"
    Push-Location $r4
    & git add .; & git commit -qm 'init'
    $baseSha4 = (& git rev-parse HEAD).Trim()
    Pop-Location

    # Break invariant: delete dropFn while caller.ts still references it
    Set-Content (Join-Path $r4 'src\calc.ts') "export function keepFn(x: number) { return x + 1; }`n"
    $psSymFail = Invoke-PsGuard @('symbol-check', '-RepoRoot', $r4, '-BaseSha', $baseSha4)
    $snap1 = (Invoke-PsGuard @('snapshot', '-RepoRoot', $r4)).Text.Trim()

    # Fix caller inside delta pass
    Set-Content (Join-Path $r4 'src\caller.ts') "import { keepFn } from './calc';`nexport const val = keepFn(1);`n"
    $psDelta = Invoke-PsGuard @('diff-scope', '-RepoRoot', $r4, '-BaseSha', $baseSha4, '-PrevSha', $snap1)
    $psMech = Invoke-PsGuard @('mechanical-check', '-RepoRoot', $r4, '-BaseSha', $baseSha4)
    $psSymOk = Invoke-PsGuard @('symbol-check', '-RepoRoot', $r4, '-BaseSha', $baseSha4)
    $psLoopVr = Invoke-PsGuard @('verify-run', '-RepoRoot', $r4, '-VerifyCmd', 'echo loop-pass', '-ReceiptPath', '.b3/ship/review-loop/r1/evidence/verify.verify', '-RelevantPaths', 'src/calc.ts,src/caller.ts')
    $psLoopVc = Invoke-PsGuard @('verify-check', '-RepoRoot', $r4, '-ReceiptPath', '.b3/ship/review-loop/r1/evidence/verify.verify', '-ExpectedCmd', 'echo loop-pass', '-RelevantPaths', 'src/calc.ts,src/caller.ts')

    $loopShOk = $true
    if ($hasBash) {
        $shDelta = Invoke-ShGuard "'$guardShPosix' diff-scope --repo-root '$r4Posix' --base-sha '$baseSha4' --prev-sha '$snap1'"
        $shMech = Invoke-ShGuard "'$guardShPosix' mechanical-check --repo-root '$r4Posix' --base-sha '$baseSha4'"
        $shSymOk = Invoke-ShGuard "'$guardShPosix' symbol-check --repo-root '$r4Posix' --base-sha '$baseSha4'"
        $shLoopVc = Invoke-ShGuard "'$guardShPosix' verify-check --repo-root '$r4Posix' --receipt-path '.b3/ship/review-loop/r1/evidence/verify.verify' --expected-cmd 'echo loop-pass' --relevant-paths 'src/calc.ts,src/caller.ts'"
        $loopShOk = ($shDelta.Code -eq 0) -and ($shDelta.Text -match 'delta_files=src/caller\.ts') -and
                    ($shMech.Code -eq 0) -and ($shMech.Text -match 'MECHANICAL_OK') -and
                    ($shSymOk.Code -eq 0) -and ($shSymOk.Text -match 'SYMBOL_OK') -and
                    ($shLoopVc.Code -eq 0) -and ($shLoopVc.Text -match 'VERIFY_VALID:')
    }

    if ($psSymFail.Code -eq 2 -and ($psSymFail.Text -match 'dangling_refs=dropFn') -and
        $psDelta.Code -eq 0 -and ($psDelta.Text -match 'delta_files=src/caller\.ts') -and
        $psMech.Code -eq 0 -and ($psMech.Text -match 'MECHANICAL_OK') -and
        $psSymOk.Code -eq 0 -and ($psSymOk.Text -match 'SYMBOL_OK') -and
        $psLoopVr.Code -eq 0 -and $psLoopVc.Code -eq 0 -and $loopShOk) {
        Pass 'standalone-review-loop-cycle'
    } else {
        FailCheck 'standalone-review-loop-cycle' "symFail=$($psSymFail.Text) delta=$($psDelta.Text) symOk=$($psSymOk.Text) vc=$($psLoopVc.Text) shOk=$loopShOk"
    }

    # --- 6. standalone-command-contracts ---
    $cmdImpl = Get-Content -LiteralPath (Join-Path $root 'commands\b3-implement.md') -Raw
    $csImpl = Get-Content -LiteralPath (Join-Path $root 'adapters\command-skills\b3-implement\SKILL.md') -Raw
    $cmdPlan = Get-Content -LiteralPath (Join-Path $root 'commands\b3-plan.md') -Raw
    $skPlan = Get-Content -LiteralPath (Join-Path $root 'skills\engineering\planning\SKILL.md') -Raw
    $skDbg = Get-Content -LiteralPath (Join-Path $root 'skills\engineering\debugging\SKILL.md') -Raw
    $cmdRev = Get-Content -LiteralPath (Join-Path $root 'commands\b3-review.md') -Raw
    $skRev = Get-Content -LiteralPath (Join-Path $root 'skills\engineering\code-review\SKILL.md') -Raw
    $cmdRl = Get-Content -LiteralPath (Join-Path $root 'commands\b3-review-loop.md') -Raw
    $strat = Get-Content -LiteralPath (Join-Path $root 'review-loop\strategy.md') -Raw
    $cmdVer = Get-Content -LiteralPath (Join-Path $root 'commands\b3-verify.md') -Raw
    $skVer = Get-Content -LiteralPath (Join-Path $root 'skills\engineering\verification\SKILL.md') -Raw

    $implDescMatch = [regex]::Match($cmdImpl, '(?ms)^---\r?\n.*?\r?\ndescription:\s*(.+?)\r?\n')
    $implDescNoShip = $implDescMatch.Success -and ($implDescMatch.Groups[1].Value -notmatch 'ship a change')
    $implSingleHop = ($cmdImpl -match 'do \*\*not\*\* eagerly load .*feature-implementation\.md') -and ($csImpl -match 'skip `workflows/feature-implementation\.md`')
    $planOk = ($cmdPlan -match 'plan-only') -and ($skPlan -match 'risk-adaptive depth') -and ($skPlan -match 'Readiness Check')
    $dbgOk = ($skDbg -match 'broken invariant') -and ($skDbg -match 'sibling entry points') -and ($skDbg -match 'regression test') -and ($skDbg -match '3 failed fix attempts')
    $revTplPath = Join-Path $root 'skills\engineering\code-review\references\review-template.md'
    $csRev = Get-Content -LiteralPath (Join-Path $root 'adapters\command-skills\b3-review\SKILL.md') -Raw
    $ghPrRef = Get-Content -LiteralPath (Join-Path $root 'skills\engineering\code-review\references\github-pr-review.md') -Raw
    $agentsRaw = Get-Content -LiteralPath (Join-Path $root 'AGENTS.md') -Raw
    $revTplOk = (Test-Path -LiteralPath $revTplPath -PathType Leaf) -and
                ($cmdRev -match 'review-template\.md') -and
                ($csRev -match 'review-template\.md') -and
                ($skRev -match 'review-template\.md') -and
                ($ghPrRef -match 'review-template\.md') -and
                ($agentsRaw -match 'skills/engineering/code-review/references/review-template\.md')
    $implSingleTaskOk = ($cmdImpl -match 'dispatch-naming\.md') -and ($cmdImpl -match 'b3-impl-t00N') -and ($cmdImpl -match 'B3_MODELS_PERSONAL') -and
                        ($csImpl -match 'dispatch-naming\.md') -and ($csImpl -match 'b3-impl-t00N') -and ($csImpl -match 'B3_MODELS_PERSONAL')
    $revOk = ($cmdRev -match 'symbol-check') -and ($skRev -match 'Scope \(delta-first\)') -and ($skRev -match 'never auto-fix or start `/b3-review-loop`') -and $revTplOk
    $rlBytes = ([System.Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes((Join-Path $root 'review-loop\strategy.md')))).Replace("`r", '').Length
    $rlOk = ($cmdRl -match '\.b3/ship/review-loop/') -and ($strat -match 'SINGLE_AGENT_LIMIT') -and ($strat -match 'dispatch fresh `b3-fixer`') -and ($rlBytes -le 5400)
    $verOk = ($cmdVer -match 'verify-run') -and ($skVer -match 'verify-check') -and ($skVer -match 'untrusted provenance')

    if ($implDescNoShip -and $implSingleHop -and $implSingleTaskOk -and $planOk -and $dbgOk -and $revOk -and $rlOk -and $verOk) {
        Pass 'standalone-command-contracts'
    } else {
        FailCheck 'standalone-command-contracts' "desc=$implDescNoShip hop=$implSingleHop singleTask=$implSingleTaskOk plan=$planOk dbg=$dbgOk rev=$revOk rl=$rlOk($rlBytes) ver=$verOk"
    }
}
finally {
    Pop-Location -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed -gt 0) {
    Write-Output "$failed check(s) failed"
    exit 1
}
Write-Output 'ok'
exit 0
