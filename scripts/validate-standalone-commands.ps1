# Behavioral checks for the six standalone commands (/b3-plan, /b3-implement, /b3-debug, /b3-review, /b3-review-loop, /b3-verify).
# Tests guard/verification/state-isolation/contract behavior in isolated sandboxes (not host IDE UI discovery).
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate-standalone-commands.ps1
param(
    [switch]$AllowIncompleteBash
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'lib\global-test-helpers.ps1')
$guardShPosix = (To-PosixPath $root) + '/scripts/b3-guard.sh'

function Init-TestRepo([string]$DirPath) {
    Init-B3TestRepo -RepoPath $DirPath -DefaultBranch 'main' -UserEmail 'standalone-test@example.com' -UserName 'Standalone Test'
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
    New-Item -ItemType Junction -Path $juncPath -Target $outJuncDir | Out-Null
    $juncOk = Test-Path -LiteralPath $juncPath -PathType Container
    Set-Content (Join-Path $badDir 'junclog.verify') "schema=b3-verify-v1`ntask_id=t1`nscope=scoped`nhead_sha=$headSha`ntree_hash=$treeSha`nrelevant_paths=src/a.ts`nexit_code=0`nstatus=PASS`ncommand=echo ok`nlog_path=.b3/ship/verify/extlink/secret.log`ntimestamp_utc=2026-11-22T10:00:00Z`n"

    $psNoCmd = Invoke-PsGuard @('verify-check', '-RepoRoot', $r1, '-ReceiptPath', '.b3/ship/verify/nocmd.verify')
    $psBadTs = Invoke-PsGuard @('verify-check', '-RepoRoot', $r1, '-ReceiptPath', '.b3/ship/verify/badts.verify')
    $psMissLog = Invoke-PsGuard @('verify-check', '-RepoRoot', $r1, '-ReceiptPath', '.b3/ship/verify/misslog.verify')
    $psTravLog = Invoke-PsGuard @('verify-check', '-RepoRoot', $r1, '-ReceiptPath', '.b3/ship/verify/travlog.verify')
    $psAbsLog = Invoke-PsGuard @('verify-check', '-RepoRoot', $r1, '-ReceiptPath', '.b3/ship/verify/abslog.verify')
    $psJuncLog = Invoke-PsGuard @('verify-check', '-RepoRoot', $r1, '-ReceiptPath', '.b3/ship/verify/junclog.verify')

    $provShOk = $true
    if ($script:HasBash) {
        $shSeed = Invoke-ShCmd "'$guardShPosix' verify-check --repo-root '$r1Posix' --receipt-path '.b3/ship/verify/seed.verify'"
        $shNoCmd = Invoke-ShCmd "'$guardShPosix' verify-check --repo-root '$r1Posix' --receipt-path '.b3/ship/verify/nocmd.verify'"
        $shBadTs = Invoke-ShCmd "'$guardShPosix' verify-check --repo-root '$r1Posix' --receipt-path '.b3/ship/verify/badts.verify'"
        $shMissLog = Invoke-ShCmd "'$guardShPosix' verify-check --repo-root '$r1Posix' --receipt-path '.b3/ship/verify/misslog.verify'"
        $shTravLog = Invoke-ShCmd "'$guardShPosix' verify-check --repo-root '$r1Posix' --receipt-path '.b3/ship/verify/travlog.verify'"
        $shAbsLog = Invoke-ShCmd "'$guardShPosix' verify-check --repo-root '$r1Posix' --receipt-path '.b3/ship/verify/abslog.verify'"
        $shJuncLog = Invoke-ShCmd "'$guardShPosix' verify-check --repo-root '$r1Posix' --receipt-path '.b3/ship/verify/junclog.verify'"
        $provShOk = ($shSeed.Code -eq 0) -and ($shSeed.Text -match 'VERIFY_VALID:') -and
                    ($shNoCmd.Code -eq 1) -and ($shNoCmd.Text -match "VERIFY_CORRUPT: missing field 'command'") -and
                    ($shBadTs.Code -eq 1) -and ($shBadTs.Text -match 'VERIFY_CORRUPT: invalid timestamp_utc') -and
                    ($shMissLog.Code -eq 1) -and ($shMissLog.Text -match 'VERIFY_CORRUPT: missing log_path') -and
                    ($shTravLog.Code -eq 1) -and ($shTravLog.Text -match 'VERIFY_CORRUPT: invalid log_path') -and
                    ($shAbsLog.Code -eq 1) -and ($shAbsLog.Text -match 'VERIFY_CORRUPT: invalid log_path') -and
                    ($shJuncLog.Code -eq 1) -and ($shJuncLog.Text -match 'VERIFY_CORRUPT: invalid log_path')
    }
    if (Test-Path -LiteralPath $juncPath) { [IO.Directory]::Delete($juncPath, $false) }

    if ($seed.Code -eq 0 -and $seedCheckPs.Code -eq 0 -and $juncOk -and
        $psNoCmd.Code -eq 1 -and ($psNoCmd.Text -match "VERIFY_CORRUPT: missing field 'command'") -and
        $psBadTs.Code -eq 1 -and ($psBadTs.Text -match 'VERIFY_CORRUPT: invalid timestamp_utc') -and
        $psMissLog.Code -eq 1 -and ($psMissLog.Text -match 'VERIFY_CORRUPT: missing log_path') -and
        $psTravLog.Code -eq 1 -and ($psTravLog.Text -match 'VERIFY_CORRUPT: invalid log_path') -and
        $psAbsLog.Code -eq 1 -and ($psAbsLog.Text -match 'VERIFY_CORRUPT: invalid log_path') -and
        $psJuncLog.Code -eq 1 -and ($psJuncLog.Text -match 'VERIFY_CORRUPT: invalid log_path') -and $provShOk) {
        Pass 'standalone-verify-provenance'
    } else {
        FailCheck 'standalone-verify-provenance' "seed=$($seed.Code) juncOk=$juncOk psNoCmd=$($psNoCmd.Text) psBadTs=$($psBadTs.Text) psMiss=$($psMissLog.Text) psTrav=$($psTravLog.Text) psAbs=$($psAbsLog.Text) psJunc=$($psJuncLog.Text) shOk=$provShOk"
    }

    # --- R016 regression: verify-run containment, pre-execution validation, and relative-root canonicalization ---
    $r1c = Join-Path $sandbox 'containment-repo'
    $r1cPosix = $r1c -replace '\\', '/'
    Init-TestRepo $r1c
    New-Item -ItemType Directory -Path (Join-Path $r1c 'src') | Out-Null
    Set-Content (Join-Path $r1c 'src\a.ts') "export const a = 1;`n"
    Push-Location $r1c
    & git add .; & git commit -qm 'init'
    Pop-Location

    $cVerifyDir = Join-Path $r1c '.b3\ship\verify'
    New-Item -ItemType Directory -Path $cVerifyDir -Force | Out-Null
    $cJunc = Join-Path $cVerifyDir 'extlink'
    New-Item -ItemType Junction -Path $cJunc -Target $outJuncDir | Out-Null

    $sideEffectPs = Join-Path $sandbox 'ran-ps.txt'
    $outLogEsc = Join-Path $sandbox 'escape-run.log'
    $outRecEsc = Join-Path $sandbox 'escape-rec.verify'
    $outJuncLog = Join-Path $outJuncDir 'evil-run.log'

    $psLogTrav = Invoke-PsGuard @('verify-run', '-RepoRoot', $r1c, '-VerifyCmd', "Set-Content '$sideEffectPs' 'ran'; exit 0", '-ReceiptPath', '.b3/ship/verify/ok.verify', '-LogPath', '../escape-run.log')
    $psLogAbs = Invoke-PsGuard @('verify-run', '-RepoRoot', $r1c, '-VerifyCmd', 'exit 2', '-ReceiptPath', '.b3/ship/verify/ok.verify', '-LogPath', $outLogEsc)
    $psLogJunc = Invoke-PsGuard @('verify-run', '-RepoRoot', $r1c, '-VerifyCmd', 'exit 2', '-ReceiptPath', '.b3/ship/verify/ok.verify', '-LogPath', '.b3/ship/verify/extlink/evil-run.log')
    $psRecTrav = Invoke-PsGuard @('verify-run', '-RepoRoot', $r1c, '-VerifyCmd', "Set-Content '$sideEffectPs' 'ran'", '-ReceiptPath', '../escape-rec.verify')
    $psRecAbs = Invoke-PsGuard @('verify-run', '-RepoRoot', $r1c, '-VerifyCmd', 'echo ok', '-ReceiptPath', $outRecEsc)
    $psRecGit = Invoke-PsGuard @('verify-run', '-RepoRoot', $r1c, '-VerifyCmd', 'echo ok', '-ReceiptPath', '.git/evil.verify')
    $psRecJunc = Invoke-PsGuard @('verify-run', '-RepoRoot', $r1c, '-VerifyCmd', 'echo ok', '-ReceiptPath', '.b3/ship/verify/extlink/evil.verify')

    $absInRecPs = Join-Path $r1c '.b3\ship\verify\relroot-ps.verify'
    $absInLogPs = Join-Path $r1c '.b3\ship\verify\relroot-ps.log'
    Push-Location $r1c
    try {
        $psRelRootRun = Invoke-PsGuard @('verify-run', '-VerifyCmd', '1..40 | ForEach-Object { "line-$_" }', '-ReceiptPath', $absInRecPs, '-LogPath', $absInLogPs, '-RelevantPaths', 'src/a.ts')
    } finally {
        Pop-Location
    }
    $psRelRootChk = Invoke-PsGuard @('verify-check', '-RepoRoot', $r1c, '-ReceiptPath', '.b3/ship/verify/relroot-ps.verify')
    $psRelRecTxt = if (Test-Path -LiteralPath $absInRecPs) { Get-Content -LiteralPath $absInRecPs -Raw } else { '' }
    $psRelLogSafe = ($psRelRecTxt -match '(?m)^log_path=\.b3/ship/verify/relroot-ps\.log\r?$')

    $contShOk = $true
    $contShDetail = ''
    if ($script:HasBash) {
        $sideEffectSh = (Join-Path $sandbox 'ran-sh.txt') -replace '\\', '/'
        $outLogEscP = $outLogEsc -replace '\\', '/'
        $outRecEscP = $outRecEsc -replace '\\', '/'
        $shLogTrav = Invoke-ShCmd "'$guardShPosix' verify-run --repo-root '$r1cPosix' --verify-cmd 'touch $sideEffectSh' --receipt-path '.b3/ship/verify/ok.verify' --log-path '../escape-run.log'"
        $shLogAbs = Invoke-ShCmd "'$guardShPosix' verify-run --repo-root '$r1cPosix' --verify-cmd 'exit 2' --receipt-path '.b3/ship/verify/ok.verify' --log-path '$outLogEscP'"
        $shLogJunc = Invoke-ShCmd "'$guardShPosix' verify-run --repo-root '$r1cPosix' --verify-cmd 'exit 2' --receipt-path '.b3/ship/verify/ok.verify' --log-path '.b3/ship/verify/extlink/evil-run.log'"
        $shRecTrav = Invoke-ShCmd "'$guardShPosix' verify-run --repo-root '$r1cPosix' --verify-cmd 'touch $sideEffectSh' --receipt-path '../escape-rec.verify'"
        $shRecAbs = Invoke-ShCmd "'$guardShPosix' verify-run --repo-root '$r1cPosix' --verify-cmd 'echo ok' --receipt-path '$outRecEscP'"
        $shRecGit = Invoke-ShCmd "'$guardShPosix' verify-run --repo-root '$r1cPosix' --verify-cmd 'echo ok' --receipt-path '.git/evil.verify'"
        $shRecJunc = Invoke-ShCmd "'$guardShPosix' verify-run --repo-root '$r1cPosix' --verify-cmd 'echo ok' --receipt-path '.b3/ship/verify/extlink/evil.verify'"

        $absInRecShP = "$r1cPosix/.b3/ship/verify/relroot-sh.verify"
        $absInLogShP = "$r1cPosix/.b3/ship/verify/relroot-sh.log"
        $shRelRootRun = Invoke-ShCmd "cd '$r1cPosix' && '$guardShPosix' verify-run --verify-cmd 'seq 1 40' --receipt-path '$absInRecShP' --log-path '$absInLogShP' --relevant-paths 'src/a.ts'"
        $shRelRootChk = Invoke-ShCmd "'$guardShPosix' verify-check --repo-root '$r1cPosix' --receipt-path '.b3/ship/verify/relroot-sh.verify'"
        $absInRecShWin = Join-Path $r1c '.b3\ship\verify\relroot-sh.verify'
        $shRelRecTxt = if (Test-Path -LiteralPath $absInRecShWin) { Get-Content -LiteralPath $absInRecShWin -Raw } else { '' }
        $shRelLogSafe = ($shRelRecTxt -match '(?m)^log_path=\.b3/ship/verify/relroot-sh\.log\r?$')

        $contShOk = ($shLogTrav.Code -eq 1) -and ($shLogTrav.Text -match 'VERIFY_RUN_FAIL: invalid log_path') -and
                    ($shLogAbs.Code -eq 1) -and ($shLogAbs.Text -match 'VERIFY_RUN_FAIL: invalid log_path') -and
                    ($shLogJunc.Code -eq 1) -and ($shLogJunc.Text -match 'VERIFY_RUN_FAIL: invalid log_path') -and
                    ($shRecTrav.Code -eq 1) -and ($shRecTrav.Text -match 'VERIFY_RUN_FAIL: invalid receipt_path') -and
                    ($shRecAbs.Code -eq 1) -and ($shRecAbs.Text -match 'VERIFY_RUN_FAIL: invalid receipt_path') -and
                    ($shRecGit.Code -eq 1) -and ($shRecGit.Text -match 'VERIFY_RUN_FAIL: invalid receipt_path') -and
                    ($shRecJunc.Code -eq 1) -and ($shRecJunc.Text -match 'VERIFY_RUN_FAIL: invalid receipt_path') -and
                    (-not (Test-Path -LiteralPath (Join-Path $sandbox 'ran-sh.txt'))) -and
                    ($shRelRootRun.Code -eq 0) -and ($shRelRootChk.Code -eq 0) -and ($shRelRootChk.Text -match 'VERIFY_VALID:') -and $shRelLogSafe
        if (-not $contShOk) {
            $contShDetail = "lt=$($shLogTrav.Code):$($shLogTrav.Text)|la=$($shLogAbs.Code)|lj=$($shLogJunc.Code)|rt=$($shRecTrav.Code)|ra=$($shRecAbs.Code)|rg=$($shRecGit.Code)|rj=$($shRecJunc.Code)|rr=$($shRelRootRun.Code):$($shRelRootRun.Text)|rc=$($shRelRootChk.Code):$($shRelRootChk.Text)|safe=$shRelLogSafe"
        }
    }
    if (Test-Path -LiteralPath $cJunc) { [IO.Directory]::Delete($cJunc, $false) }
    $noEscapes = (-not (Test-Path -LiteralPath $sideEffectPs)) -and
                 (-not (Test-Path -LiteralPath $outLogEsc)) -and
                 (-not (Test-Path -LiteralPath $outRecEsc)) -and
                 (-not (Test-Path -LiteralPath $outJuncLog)) -and
                 (-not (Test-Path -LiteralPath (Join-Path $r1c '.git\evil.verify')))
    if ($psLogTrav.Code -eq 1 -and ($psLogTrav.Text -match 'VERIFY_RUN_FAIL: invalid log_path') -and
        $psLogAbs.Code -eq 1 -and ($psLogAbs.Text -match 'VERIFY_RUN_FAIL: invalid log_path') -and
        $psLogJunc.Code -eq 1 -and ($psLogJunc.Text -match 'VERIFY_RUN_FAIL: invalid log_path') -and
        $psRecTrav.Code -eq 1 -and ($psRecTrav.Text -match 'VERIFY_RUN_FAIL: invalid receipt_path') -and
        $psRecAbs.Code -eq 1 -and ($psRecAbs.Text -match 'VERIFY_RUN_FAIL: invalid receipt_path') -and
        $psRecGit.Code -eq 1 -and ($psRecGit.Text -match 'VERIFY_RUN_FAIL: invalid receipt_path') -and
        $psRecJunc.Code -eq 1 -and ($psRecJunc.Text -match 'VERIFY_RUN_FAIL: invalid receipt_path') -and
        $psRelRootRun.Code -eq 0 -and $psRelRootChk.Code -eq 0 -and ($psRelRootChk.Text -match 'VERIFY_VALID:') -and $psRelLogSafe -and
        $noEscapes -and $contShOk) {
        Pass 'standalone-verify-run-containment'
    } else {
        FailCheck 'standalone-verify-run-containment' "psLT=$($psLogTrav.Code) psLA=$($psLogAbs.Code) psLJ=$($psLogJunc.Code) psRT=$($psRecTrav.Code) psRA=$($psRecAbs.Code) psRG=$($psRecGit.Code) psRJ=$($psRecJunc.Code) relRun=$($psRelRootRun.Code) relChk=$($psRelRootChk.Code)/$psRelLogSafe noEsc=$noEscapes shOk=$contShOk ($contShDetail)"
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
    if ($script:HasBash) {
        $shCmdOk = Invoke-ShCmd "'$guardShPosix' verify-check --repo-root '$r2Posix' --receipt-path '.b3/ship/verify/unit.verify' --expected-cmd 'echo check-unit' --relevant-paths 'src/a.ts'"
        $shCmdBad = Invoke-ShCmd "'$guardShPosix' verify-check --repo-root '$r2Posix' --receipt-path '.b3/ship/verify/unit.verify' --expected-cmd 'echo check-all'"
        $shScopeBad = Invoke-ShCmd "'$guardShPosix' verify-check --repo-root '$r2Posix' --receipt-path '.b3/ship/verify/unit.verify' --relevant-paths 'src/a.ts,package.json'"
        $shAllCovers = Invoke-ShCmd "'$guardShPosix' verify-check --repo-root '$r2Posix' --receipt-path '.b3/ship/verify/all.verify' --expected-cmd 'echo full-suite' --relevant-paths 'src/a.ts,package.json'"
        $scopeShOk1 = ($shCmdOk.Code -eq 0) -and ($shCmdOk.Text -match 'VERIFY_VALID:') -and
                      ($shCmdBad.Code -eq 1) -and ($shCmdBad.Text -match 'VERIFY_MISMATCH: command mismatch') -and
                      ($shScopeBad.Code -eq 1) -and ($shScopeBad.Text -match 'VERIFY_SCOPE_MISMATCH: uncovered path \(package\.json\)') -and
                      ($shAllCovers.Code -eq 0) -and ($shAllCovers.Text -match 'VERIFY_VALID:')
    }

    # Edit dependency manifest -> ALL receipt turns VERIFY_STALE (exit 2)
    Set-Content (Join-Path $r2 'package.json') "{`"name`":`"x`",`"version`":`"2`"}"
    $psAllStale = Invoke-PsGuard @('verify-check', '-RepoRoot', $r2, '-ReceiptPath', '.b3/ship/verify/all.verify', '-RelevantPaths', 'src/a.ts,package.json')
    $scopeShOk2 = $true
    if ($script:HasBash) {
        $shAllStale = Invoke-ShCmd "'$guardShPosix' verify-check --repo-root '$r2Posix' --receipt-path '.b3/ship/verify/all.verify' --relevant-paths 'src/a.ts,package.json'"
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
    if ($script:HasBash) {
        $shBig = Invoke-ShCmd "'$guardShPosix' verify-run --repo-root '$r2Posix' --verify-cmd 'seq 1 15000; exit 2' --receipt-path '.b3/ship/verify/shbig.verify'"
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
    if ($script:HasBash) {
        $shDiff = Invoke-ShCmd "'$guardShPosix' diff-scope --repo-root '$r3Posix' --base-sha HEAD"
        $shVcIso = Invoke-ShCmd "'$guardShPosix' verify-check --repo-root '$r3Posix' --receipt-path '.b3/ship/verify/claim.verify'"
        $shRes = Invoke-ShCmd "'$guardShPosix' resolve-run --repo-root '$r3Posix'"
        $isoShOk = ($shDiff.Code -eq 0) -and ($shDiff.Text -match 'review_files=src/app\.ts') -and ($shDiff.Text -notmatch '\.b3/') -and
                   ($shVcIso.Code -eq 0) -and ($shRes.Code -eq 1) -and ($shRes.Text -match 'NO_ACTIVE_RUN')
    }

    Push-Location $r3
    & git add -f '.b3/ship/review-loop/r1/state.md'
    Pop-Location
    $psPcBlk = Invoke-PsGuard @('precommit', '-RepoRoot', $r3, '-AllowedPaths', 'src/app.ts,.b3/ship/review-loop/r1/state.md')
    $isoPcShOk = $true
    if ($script:HasBash) {
        $shPcBlk = Invoke-ShCmd "'$guardShPosix' precommit --repo-root '$r3Posix' --allowed-paths 'src/app.ts,.b3/ship/review-loop/r1/state.md'"
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
    if ($script:HasBash) {
        $shDelta = Invoke-ShCmd "'$guardShPosix' diff-scope --repo-root '$r4Posix' --base-sha '$baseSha4' --prev-sha '$snap1'"
        $shMech = Invoke-ShCmd "'$guardShPosix' mechanical-check --repo-root '$r4Posix' --base-sha '$baseSha4'"
        $shSymOk = Invoke-ShCmd "'$guardShPosix' symbol-check --repo-root '$r4Posix' --base-sha '$baseSha4'"
        $shLoopVc = Invoke-ShCmd "'$guardShPosix' verify-check --repo-root '$r4Posix' --receipt-path '.b3/ship/review-loop/r1/evidence/verify.verify' --expected-cmd 'echo loop-pass' --relevant-paths 'src/calc.ts,src/caller.ts'"
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

    # --- 6. standalone-review-loop-optimizations (untracked snapshot/delta, parity, and fail-closed guards) ---
    $r5 = Join-Path $sandbox 'opt-repo'
    $r5Posix = $r5 -replace '\\', '/'
    Init-TestRepo $r5
    New-Item -ItemType Directory -Path (Join-Path $r5 'src') | Out-Null
    [IO.File]::WriteAllText((Join-Path $r5 'src\main.ts'), "export const x = 1;`n", (New-Object System.Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $r5 'foo'), "placeholder`n", (New-Object System.Text.UTF8Encoding($false)))
    Push-Location $r5
    & git add .; & git commit -qm 'init'
    $baseSha5 = (& git rev-parse HEAD).Trim()
    # Delete tracked 'foo' and create untracked dir file 'foo/bar.ts' (1 line without trailing newline)
    & git rm -q foo
    New-Item -ItemType Directory -Path (Join-Path $r5 'foo') | Out-Null
    [IO.File]::WriteAllText((Join-Path $r5 'foo\bar.ts'), 'export const bar = 1', (New-Object System.Text.UTF8Encoding($false)))
    Pop-Location

    # Untracked file created BEFORE snapshot: real git status stays untracked, immediate diff-scope -PrevSha must be delta_files=none
    [IO.File]::WriteAllText((Join-Path $r5 'src\untracked.ts'), "export const u = 1;`n", (New-Object System.Text.UTF8Encoding($false)))
    $snapU1 = (Invoke-PsGuard @('snapshot', '-RepoRoot', $r5)).Text.Trim()
    Push-Location $r5
    $gitStatusKeepUntr = ((& git status --short) -join "`n") -match '\?\?\s+src/untracked\.ts'
    $stashKeepEmpty = -not (& git stash list)
    Pop-Location
    $psDeltaNone = Invoke-PsGuard @('diff-scope', '-RepoRoot', $r5, '-BaseSha', $baseSha5, '-PrevSha', $snapU1)

    # Edit untracked file -> appears in delta_files
    [IO.File]::WriteAllText((Join-Path $r5 'src\untracked.ts'), "export const u = 2;`n", (New-Object System.Text.UTF8Encoding($false)))
    $psDeltaEdit = Invoke-PsGuard @('diff-scope', '-RepoRoot', $r5, '-BaseSha', $baseSha5, '-PrevSha', $snapU1)

    # Snapshot again, delete untracked file + add brand-new untracked file -> both appear in delta_files
    $snapU2 = (Invoke-PsGuard @('snapshot', '-RepoRoot', $r5)).Text.Trim()
    Remove-Item -LiteralPath (Join-Path $r5 'src\untracked.ts') -Force
    [IO.File]::WriteAllText((Join-Path $r5 'src\brand_new.ts'), "export const b = 1;`n", (New-Object System.Text.UTF8Encoding($false)))
    $psDeltaDelNew = Invoke-PsGuard @('diff-scope', '-RepoRoot', $r5, '-BaseSha', $baseSha5, '-PrevSha', $snapU2)

    # Flag-injection guard & dir-as-receipt pre-execution guard & .git log_path guard
    $psFlagInj = Invoke-PsGuard @('diff-scope', '-RepoRoot', $r5, '-BaseSha', '--cached')
    New-Item -ItemType Directory -Path (Join-Path $r5 '.b3\ship\dirrec') | Out-Null
    $markerPs = Join-Path $r5 'should-not-exist-ps.txt'
    $psDirRec = Invoke-PsGuard @('verify-run', '-RepoRoot', $r5, '-VerifyCmd', "echo bad > should-not-exist-ps.txt", '-ReceiptPath', '.b3/ship/dirrec')
    $noSideEffPs = -not (Test-Path -LiteralPath $markerPs)
    New-Item -ItemType Directory -Path (Join-Path $r5 '.b3\ship\ev') | Out-Null
    $gitLogVariantsOk = $true
    foreach ($badLogPath in @('.git/HEAD', '././.git/HEAD', './//.git/HEAD', '././//./.git/HEAD', '.GIT/HEAD')) {
        [IO.File]::WriteAllText((Join-Path $r5 '.b3\ship\ev\gitlog.verify'), "schema=b3-verify-v1`ntask_id=T1`nscope=s`nhead_sha=$baseSha5`ntree_hash=$(('0' * 40))`nrelevant_paths=ALL`nexit_code=0`nstatus=PASS`ncommand=echo ok`nlog_path=$badLogPath`ntimestamp_utc=2026-01-01T00:00:00Z`n", (New-Object System.Text.UTF8Encoding($false)))
        $psGl = Invoke-PsGuard @('verify-check', '-RepoRoot', $r5, '-ReceiptPath', '.b3/ship/ev/gitlog.verify')
        if ($psGl.Code -ne 1 -or ($psGl.Text -notmatch 'VERIFY_CORRUPT: invalid log_path')) { $gitLogVariantsOk = $false }
        if ($script:HasBash) {
            $shGl = Invoke-ShCmd "'$guardShPosix' verify-check --repo-root '$r5Posix' --receipt-path '.b3/ship/ev/gitlog.verify'"
            if ($shGl.Code -ne 1 -or ($shGl.Text -notmatch 'VERIFY_CORRUPT: invalid log_path')) { $gitLogVariantsOk = $false }
        }
    }

    # Check PS/Bash measure-context strict parity including trailing backslash on -RepoRoot
    $prevMcEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $mcPsRaw = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\measure-context.ps1') -RepoRoot "$root\" -Strict 2>&1
    $mcPsExit = $LASTEXITCODE
    $ErrorActionPreference = $prevMcEap
    $mcPsNorm = ($mcPsRaw | ForEach-Object { ([string]$_).TrimEnd("`r") }) -join "`n"

    $optShOk = $true
    if ($script:HasBash) {
        $shSnap = Invoke-ShCmd "'$guardShPosix' snapshot --repo-root '$r5Posix'"
        $snapShId = $shSnap.Text.Trim()
        $shDeltaNone = Invoke-ShCmd "'$guardShPosix' diff-scope --repo-root '$r5Posix' --base-sha '$baseSha5' --prev-sha '$snapShId'"
        $shFlagInj = Invoke-ShCmd "'$guardShPosix' diff-scope --repo-root '$r5Posix' --base-sha '--cached'"
        $markerSh = Join-Path $r5 'should-not-exist-sh.txt'
        $shDirRec = Invoke-ShCmd "'$guardShPosix' verify-run --repo-root '$r5Posix' --verify-cmd 'touch should-not-exist-sh.txt' --receipt-path '.b3/ship/dirrec'"
        $noSideEffSh = -not (Test-Path -LiteralPath $markerSh)
        $shNonCkVr = Invoke-ShCmd "'$guardShPosix' verify-run --repo-root '$r5Posix' --verify-cmd 'echo nonck-ok' --receipt-path '.b3/nonck/sub/r.verify' --relevant-paths 'foo/bar.ts'"
        $shNonCkVc = Invoke-ShCmd "'$guardShPosix' verify-check --repo-root '$r5Posix' --receipt-path '.b3/nonck/sub/r.verify'"
        $prevShMc = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $mcShRaw = & $script:GitBash -c "'$($root -replace '\\','/')/scripts/measure-context.sh' --strict" 2>&1
        $mcShExit = $LASTEXITCODE
        $ErrorActionPreference = $prevShMc
        $mcShNorm = ($mcShRaw | ForEach-Object { ([string]$_).TrimEnd("`r") }) -join "`n"
        $optShOk = ($shSnap.Code -eq 0) -and ($snapShId -match '^[0-9a-f]{40}$') -and
                   ($shDeltaNone.Code -eq 0) -and ($shDeltaNone.Text -match 'size_class=XS\b') -and ($shDeltaNone.Text -match 'review_files=foo,foo/bar\.ts,src/brand_new\.ts') -and ($shDeltaNone.Text -match 'lines=3\b') -and ($shDeltaNone.Text -match 'delta_files=none') -and
                   ($shFlagInj.Code -eq 1) -and ($shFlagInj.Text -match 'DIFF_SCOPE_FAIL:') -and
                   ($shDirRec.Code -eq 1) -and $noSideEffSh -and
                   ($shNonCkVr.Code -eq 0) -and ($shNonCkVc.Code -eq 0) -and ($shNonCkVc.Text -match 'VERIFY_VALID:') -and
                   ($mcShExit -eq 0) -and ($mcPsNorm -ceq $mcShNorm)
    }

    if ($snapU1 -match '^[0-9a-f]{40}$' -and $gitStatusKeepUntr -and $stashKeepEmpty -and
        $psDeltaNone.Code -eq 0 -and ($psDeltaNone.Text -match 'size_class=XS\b') -and ($psDeltaNone.Text -match 'review_files=foo,foo/bar\.ts,src/untracked\.ts') -and ($psDeltaNone.Text -match 'lines=3\b') -and ($psDeltaNone.Text -match 'delta_files=none') -and
        $psDeltaEdit.Code -eq 0 -and ($psDeltaEdit.Text -match 'delta_files=src/untracked\.ts') -and
        $psDeltaDelNew.Code -eq 0 -and ($psDeltaDelNew.Text -match 'delta_files=src/brand_new\.ts,src/untracked\.ts') -and
        $psFlagInj.Code -eq 1 -and ($psFlagInj.Text -match 'DIFF_SCOPE_FAIL:') -and
        $psDirRec.Code -eq 1 -and $noSideEffPs -and
        $gitLogVariantsOk -and
        $mcPsExit -eq 0 -and ($mcPsNorm -match 'warnings\s*:\s*0') -and $optShOk) {
        Pass 'standalone-review-loop-optimizations'
    } else {
        FailCheck 'standalone-review-loop-optimizations' "none=$($psDeltaNone.Text) edit=$($psDeltaEdit.Text) delNew=$($psDeltaDelNew.Text) flag=$($psFlagInj.Code) dir=$($psDirRec.Code)/$noSideEffPs gl=$gitLogVariantsOk mc=$mcPsExit shOk=$optShOk"
    }

    # --- Regression: fail-closed snapshot and cleared review delta (PS + Git Bash) ---
    $r6 = Join-Path $sandbox 'snapshot-safety-repo'
    $r6Posix = $r6 -replace '\\', '/'
    Init-TestRepo $r6
    [IO.File]::WriteAllText((Join-Path $r6 'main.ts'), "export const baseline = 1;`n", (New-Object System.Text.UTF8Encoding($false)))
    Push-Location $r6
    & git add main.ts; & git commit -qm 'baseline'
    $base6 = (& git rev-parse HEAD).Trim()
    Pop-Location
    [IO.File]::WriteAllText((Join-Path $r6 'temporary.ts'), "temporary change`n", (New-Object System.Text.UTF8Encoding($false)))
    $psSnap6 = Invoke-PsGuard @('snapshot', '-RepoRoot', $r6)
    Remove-Item -LiteralPath (Join-Path $r6 'temporary.ts') -Force
    $psClean6 = Invoke-PsGuard @('diff-scope', '-RepoRoot', $r6, '-BaseSha', $base6, '-PrevSha', $psSnap6.Text.Trim())
    $psEmpty6 = Invoke-PsGuard @('diff-scope', '-RepoRoot', $r6, '-BaseSha', $base6)

    # Neither shell may write an untracked credentials blob into .git/objects.
    [IO.File]::WriteAllText((Join-Path $r6 'credentials.json'), '{"secret":"snapshot-test-unique"}', (New-Object System.Text.UTF8Encoding($false)))
    $secretOid6 = (& git -C $r6 hash-object -- credentials.json).Trim()
    $psSecret6 = Invoke-PsGuard @('snapshot', '-RepoRoot', $r6)
    $shOk6 = $true
    if ($script:HasBash) {
        $shSecret6 = Invoke-ShCmd "'$guardShPosix' snapshot --repo-root '$r6Posix'"
        $shOk6 = ($shSecret6.Code -eq 1) -and ($shSecret6.Text -match 'sensitive path cannot be snapshotted')
    }
    & git -C $r6 cat-file -e $secretOid6 2>$null
    $secretNotStored6 = ($LASTEXITCODE -ne 0)
    Remove-Item -LiteralPath (Join-Path $r6 'credentials.json') -Force
    if ($script:HasBash) {
        [IO.File]::WriteAllText((Join-Path $r6 'temporary.ts'), "temporary change`n", (New-Object System.Text.UTF8Encoding($false)))
        $shSnap6 = Invoke-ShCmd "'$guardShPosix' snapshot --repo-root '$r6Posix'"
        Remove-Item -LiteralPath (Join-Path $r6 'temporary.ts') -Force
        $shClean6 = Invoke-ShCmd "'$guardShPosix' diff-scope --repo-root '$r6Posix' --base-sha '$base6' --prev-sha '$($shSnap6.Text.Trim())'"
        $shEmpty6 = Invoke-ShCmd "'$guardShPosix' diff-scope --repo-root '$r6Posix' --base-sha '$base6'"
        $shOk6 = $shOk6 -and ($shSnap6.Code -eq 0) -and
                 ($shClean6.Code -eq 0) -and ($shClean6.Text -match 'size_class=CLEAN_AFTER_FIX') -and
                 ($shClean6.Text -match 'delta_files=temporary\.ts') -and
                 ($shEmpty6.Code -eq 2) -and ($shEmpty6.Text -match 'EMPTY_DIFF')
    }
    $subOrigin6 = Join-Path $sandbox 'snapshot-sub-origin'
    Init-TestRepo $subOrigin6
    [IO.File]::WriteAllText((Join-Path $subOrigin6 'src.txt'), "source`n", (New-Object System.Text.UTF8Encoding($false)))
    Push-Location $subOrigin6
    & git add src.txt; & git commit -qm 'sub init'
    Pop-Location
    Push-Location $r6
    & git -c protocol.file.allow=always submodule add -q $subOrigin6 deps/lib
    Pop-Location
    [IO.File]::WriteAllText((Join-Path $r6 'deps\lib\dirty-untracked.txt'), "not in gitlink`n", (New-Object System.Text.UTF8Encoding($false)))
    $psSub6 = Invoke-PsGuard @('snapshot', '-RepoRoot', $r6)
    if ($script:HasBash) {
        $shSub6 = Invoke-ShCmd "'$guardShPosix' snapshot --repo-root '$r6Posix'"
        $shOk6 = $shOk6 -and ($shSub6.Code -eq 1) -and ($shSub6.Text -match 'dirty submodule cannot be snapshotted')
    }
    if ($psSnap6.Code -eq 0 -and ($psSnap6.Text.Trim() -match '^[0-9a-f]{40}$') -and
        $psClean6.Code -eq 0 -and ($psClean6.Text -match 'size_class=CLEAN_AFTER_FIX') -and
        ($psClean6.Text -match 'delta_files=temporary\.ts') -and
        $psEmpty6.Code -eq 2 -and ($psEmpty6.Text -match 'EMPTY_DIFF') -and
        $psSecret6.Code -eq 1 -and ($psSecret6.Text -match 'sensitive path cannot be snapshotted') -and
        $secretNotStored6 -and $psSub6.Code -eq 1 -and
        ($psSub6.Text -match 'dirty submodule cannot be snapshotted') -and $shOk6) {
        Pass 'standalone-snapshot-safety-and-cleared-diff'
    } else {
        FailCheck 'standalone-snapshot-safety-and-cleared-diff' "clean=$($psClean6.Code) empty=$($psEmpty6.Code) secret=$($psSecret6.Code)/$secretNotStored6 sub=$($psSub6.Code) sh=$shOk6"
    }

    # --- 8. standalone-command-contracts ---
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
    $revOk = ($cmdRev -match 'symbol-check') -and ($skRev -match 'Scope \(delta-first\)') -and ($skRev -match 'never auto-fix or start `/b3-review-loop`') -and ($skRev -match 'skip inside `/b3-review-loop`') -and $revTplOk
    $rlBytes = ([System.Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes((Join-Path $root 'review-loop\strategy.md')))).Replace("`r", '').Length
    $hierPath = Join-Path $root 'review-loop\hierarchical.md'
    $sizingTxt = Get-Content -LiteralPath (Join-Path $root 'review-loop\sizing.md') -Raw
    $singleAgentGateOk = ($strat -match 'SINGLE_AGENT_LIMIT[^.\r\n]*cannot emit `PASS`[^.\r\n]*`HIGH`/`CRITICAL`[^.\r\n]*`INCOMPLETE`') -and
                         ($strat -match 'UNKNOWN / INCOMPLETE[^.\r\n]*`SINGLE_AGENT_LIMIT` on `HIGH`/`CRITICAL`') -and
                         ($strat -match 'SINGLE_AGENT_LIMIT[^.\r\n]*blocks `auto_merge`')
    $rlOk = (Test-Path -LiteralPath $hierPath -PathType Leaf) -and
            ($sizingTxt -match 'XS') -and ($sizingTxt -match 'XXL') -and ($sizingTxt -match 'SMALL -> S') -and
            ($cmdRl -match '\.b3/ship/review-loop/') -and ($strat -match 'SINGLE_AGENT_LIMIT') -and $singleAgentGateOk -and
            ($strat -match 'dispatch fresh `b3-fixer`') -and ($strat -match '`FAIL` on failed check') -and
            ($strat -match 'EVIDENCED RISK') -and ($strat -match 'review-inventory') -and ($strat -match 'review-ledger') -and ($rlBytes -le 5200)
    $verOk = ($cmdVer -match 'verify-run') -and ($skVer -match 'verify-check') -and ($skVer -match 'untrusted provenance')
    $agentsContractOk = $true
    foreach ($ra in @('b3-reviewer.md', 'b3-security-reviewer.md', 'b3-architecture-reviewer.md', 'b3-performance-reviewer.md')) {
        $rat = Get-Content -LiteralPath (Join-Path $root "agents\$ra") -Raw
        if ($rat -notmatch 'NO_BLOCKING_FINDINGS \| BLOCKING_FINDINGS \| INCOMPLETE') { $agentsContractOk = $false }
    }
    $revAgTxt = Get-Content -LiteralPath (Join-Path $root 'agents\b3-reviewer.md') -Raw
    $fixAgTxt = Get-Content -LiteralPath (Join-Path $root 'agents\b3-fixer.md') -Raw
    $agentsContractOk = $agentsContractOk -and ($revAgTxt -match 'skip `code-review/SKILL\.md`, `review-template\.md`') -and ($fixAgTxt -match 'verification/SKILL\.md.*on demand only')

    if ($implDescNoShip -and $implSingleHop -and $implSingleTaskOk -and $planOk -and $dbgOk -and $revOk -and $rlOk -and $verOk -and $agentsContractOk) {
        Pass 'standalone-command-contracts'
    } else {
        FailCheck 'standalone-command-contracts' "desc=$implDescNoShip hop=$implSingleHop singleTask=$implSingleTaskOk plan=$planOk dbg=$dbgOk rev=$revOk rl=$rlOk($rlBytes) ver=$verOk ag=$agentsContractOk"
    }
}
finally {
    Pop-Location -ErrorAction SilentlyContinue
    Remove-ReparseLinksUnder $sandbox
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Complete-ValidationSuite -AllowIncompleteBash:$AllowIncompleteBash
