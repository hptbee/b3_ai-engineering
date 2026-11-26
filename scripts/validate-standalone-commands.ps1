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
    $r2 = Join-Path $sandbox 'big-repo'; $r2Posix = $r2 -replace '\\', '/'
    Init-B3TestRepo -RepoPath $r2 -DefaultBranch 'main' -UserEmail 'standalone-test@example.com' -UserName 'Standalone Test' -InitialCommit
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

    # --- measure-context trailing backslash + PS/Bash parity ---
    $prevMcEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $mcPsRaw = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\measure-context.ps1') -RepoRoot "$root\" -Strict 2>&1
    $mcPsExit = $LASTEXITCODE
    $ErrorActionPreference = $prevMcEap
    $mcPsNorm = ($mcPsRaw | ForEach-Object { ([string]$_).TrimEnd("`r") }) -join "`n"
    $mcShOk = $true
    if ($script:HasBash) {
        $prevShMc = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $mcShRaw = & $script:GitBash -c "'$($root -replace '\\','/')/scripts/measure-context.sh' --strict" 2>&1
        $mcShExit = $LASTEXITCODE
        $ErrorActionPreference = $prevShMc
        $mcShNorm = ($mcShRaw | ForEach-Object { ([string]$_).TrimEnd("`r") }) -join "`n"
        $mcShOk = ($mcShExit -eq 0) -and ($mcPsNorm -ceq $mcShNorm)
    }
    if ($mcPsExit -eq 0 -and ($mcPsNorm -match 'warnings\s*:\s*0') -and $mcShOk) { Pass 'standalone-measure-context-parity' } else { FailCheck 'standalone-measure-context-parity' "ps=$mcPsExit sh=$mcShOk" }
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
