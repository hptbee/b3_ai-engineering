# Dual-shell regression tests for 6-tier T-shirt sizing, decoupled risk dispatch,
# XXL 25k-LOC hierarchical inventory, and fail-closed coverage ledger gates.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate-tshirt-hierarchical.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$guardPs = Join-Path $root 'scripts\b3-guard.ps1'
$guardShPosix = ($root -replace '\\', '/') + '/scripts/b3-guard.sh'
$failed = 0
. (Join-Path $PSScriptRoot 'lib\global-test-helpers.ps1')
$gitBash = $script:GitBash
$hasBash = $script:HasBash
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Pass([string]$Name) { Write-Output "PASS $Name" }
function FailCheck([string]$Name, [string]$Detail) {
    Write-Output "FAIL $Name :: $Detail"
    $script:failed++
}

function Invoke-PsGuard([string[]]$GuardArgs) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & powershell -NoProfile -ExecutionPolicy Bypass -File $guardPs @GuardArgs 2>&1
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

function Init-Repo([string]$DirPath) {
    New-Item -ItemType Directory -Path $DirPath | Out-Null
    Push-Location $DirPath
    & git init -q
    & git config user.email 'tshirt-test@example.com'
    & git config user.name 'TShirt Test'
    [IO.File]::WriteAllText((Join-Path $DirPath 'README.md'), "base`n", $utf8NoBom)
    & git add README.md
    & git commit -qm 'init'
    Pop-Location
}

function Check-BothParity([string]$RepoDir, [string]$BaseSha, [string]$ExpectedSize, [ref]$Details) {
    $ps = Invoke-PsGuard @('diff-scope', '-RepoRoot', $RepoDir, '-BaseSha', $BaseSha)
    if ($ps.Code -ne 0 -or ($ps.Text -notmatch ("(?m)^size_class=${ExpectedSize}$"))) {
        $Details.Value = "ps exit=$($ps.Code) expected=$ExpectedSize got=$($ps.Text)"
        return $false
    }
    if ($hasBash) {
        $rp = $RepoDir -replace '\\', '/'
        $sh = Invoke-ShGuard "'$guardShPosix' diff-scope --repo-root '$rp' --base-sha '$BaseSha'"
        if ($sh.Code -ne $ps.Code -or $sh.Text -cne $ps.Text) {
            $Details.Value = "parity mismatch expected=${ExpectedSize}: ps=[$($ps.Text)] sh=[$($sh.Text)]"
            return $false
        }
    }
    return $true
}

$sandbox = Join-Path $env:TEMP ('b3-tshirt-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox | Out-Null

try {
    # --- 1. tshirt-all-boundaries-parity ---
    $r1 = Join-Path $sandbox 'boundaries-repo'
    $r1Posix = $r1 -replace '\\', '/'
    Init-Repo $r1
    $base1 = (& git -C $r1 rev-parse HEAD).Trim()
    New-Item -ItemType Directory -Path (Join-Path $r1 'docs') | Out-Null
    $bFail = ''
    $bOk = $true

    # LOC boundaries on 1 file
    foreach ($pair in @(
        @{ L = 100; S = 'XS' }, @{ L = 101; S = 'S' },
        @{ L = 300; S = 'S' }, @{ L = 301; S = 'M' },
        @{ L = 800; S = 'M' }, @{ L = 801; S = 'L' },
        @{ L = 1999; S = 'L' }, @{ L = 2000; S = 'XL' },
        @{ L = 5000; S = 'XL' }, @{ L = 5001; S = 'XXL' }
    )) {
        [IO.File]::WriteAllText((Join-Path $r1 'docs\loc.md'), ("doc line`n" * $pair.L), $utf8NoBom)
        & git -C $r1 add docs/loc.md
        if (-not (Check-BothParity $r1 $base1 $pair.S ([ref]$bFail))) { $bOk = $false; break }
    }
    if ($bOk) {
        & git -C $r1 rm -q -f docs/loc.md 2>$null
        if (Test-Path (Join-Path $r1 'docs\loc.md')) { Remove-Item (Join-Path $r1 'docs\loc.md') -Force }
        foreach ($fpair in @(
            @{ F = 3; S = 'XS' }, @{ F = 4; S = 'S' },
            @{ F = 8; S = 'S' }, @{ F = 9; S = 'M' },
            @{ F = 20; S = 'M' }, @{ F = 21; S = 'L' },
            @{ F = 49; S = 'L' }, @{ F = 50; S = 'XL' },
            @{ F = 100; S = 'XL' }, @{ F = 101; S = 'XXL' }
        )) {
            & git -C $r1 reset -q HEAD -- docs 2>$null
            & git -C $r1 clean -qf -- docs
            New-Item -ItemType Directory -Path (Join-Path $r1 'docs') -Force | Out-Null
            1..$fpair.F | ForEach-Object {
                $n = '{0:D3}' -f $_
                [IO.File]::WriteAllText((Join-Path $r1 "docs\f${n}.md"), "d`n", $utf8NoBom)
            }
            & git -C $r1 add docs
            if (-not (Check-BothParity $r1 $base1 $fpair.S ([ref]$bFail))) { $bOk = $false; break }
        }
    }
    # Mixed dimensions: larger dimension wins
    if ($bOk) {
        & git -C $r1 reset -q HEAD -- docs; & git -C $r1 clean -qf -- docs
        New-Item -ItemType Directory -Path (Join-Path $r1 'docs') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $r1 'docs\a.md'), ("line`n" * 350), $utf8NoBom)
        [IO.File]::WriteAllText((Join-Path $r1 'docs\b.md'), "line`n", $utf8NoBom)
        & git -C $r1 add docs
        if (-not (Check-BothParity $r1 $base1 'M' ([ref]$bFail))) { $bOk = $false }
    }
    # NOISE_ONLY + EMPTY_DIFF + generated noise surfacing + CLEAN_AFTER_FIX
    if ($bOk) {
        & git -C $r1 reset -q HEAD -- docs; & git -C $r1 clean -qf -- docs
        $psEmpty = Invoke-PsGuard @('diff-scope', '-RepoRoot', $r1, '-BaseSha', $base1)
        if ($psEmpty.Code -ne 2 -or ($psEmpty.Text -notmatch 'EMPTY_DIFF')) { $bOk = $false; $bFail = "empty=$($psEmpty.Text)" }
        [IO.File]::WriteAllText((Join-Path $r1 'package-lock.json'), "{}`n", $utf8NoBom)
        if (-not (Check-BothParity $r1 $base1 'NOISE_ONLY' ([ref]$bFail))) { $bOk = $false }
        Remove-Item -LiteralPath (Join-Path $r1 'package-lock.json') -Force
        [IO.File]::WriteAllText((Join-Path $r1 'Form1.Designer.cs'), "// gen`n", $utf8NoBom)
        $psGenN = Invoke-PsGuard @('diff-scope', '-RepoRoot', $r1, '-BaseSha', $base1)
        if ($psGenN.Code -ne 0 -or ($psGenN.Text -notmatch 'size_class=NOISE_ONLY') -or ($psGenN.Text -notmatch 'risk_signals=generated_code')) {
            $bOk = $false; $bFail = "genNoise=$($psGenN.Text)"
        }
        Remove-Item -LiteralPath (Join-Path $r1 'Form1.Designer.cs') -Force
    }
    if ($bOk) { Pass 'tshirt-all-boundaries-parity' } else { FailCheck 'tshirt-all-boundaries-parity' $bFail }

    # --- 2. risk-decoupling-and-dispatch ---
    $r2 = Join-Path $sandbox 'risk-repo'
    $r2Posix = $r2 -replace '\\', '/'
    Init-Repo $r2
    $base2 = (& git -C $r2 rev-parse HEAD).Trim()

    # 2a: XS + CRITICAL (30 LOC auth)
    New-Item -ItemType Directory -Path (Join-Path $r2 'src\auth') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $r2 'src\auth\jwt.ts'), ("export function verifyToken(t: string) { return t.length > 0; }`n" * 30), $utf8NoBom)
    $psXsCrit = Invoke-PsGuard @('diff-scope', '-RepoRoot', $r2, '-BaseSha', $base2)
    $shXsCrit = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' diff-scope --repo-root '$r2Posix' --base-sha '$base2'" } else { $psXsCrit }
    $xsCritOk = ($psXsCrit.Code -eq 0) -and ($psXsCrit.Text -match 'size_class=XS') -and ($psXsCrit.Text -match 'risk_level=CRITICAL') -and
                ($psXsCrit.Text -match 'risk_signals=auth_security') -and ($psXsCrit.Text -match 'recommended_specialists=b3-security-reviewer') -and
                ($shXsCrit.Text -ceq $psXsCrit.Text)

    # 2b: HOT PATH ONLY -> HIGH + b3-performance-reviewer only
    Remove-Item -LiteralPath (Join-Path $r2 'src') -Recurse -Force
    New-Item -ItemType Directory -Path (Join-Path $r2 'src\render') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $r2 'src\render\frame.ts'), "export function tick() { useFrame(() => {}); }`n", $utf8NoBom)
    $psPerf = Invoke-PsGuard @('diff-scope', '-RepoRoot', $r2, '-BaseSha', $base2)
    $perfOk = ($psPerf.Code -eq 0) -and ($psPerf.Text -match 'size_class=XS') -and ($psPerf.Text -match 'risk_level=HIGH') -and
              ($psPerf.Text -match 'recommended_specialists=b3-performance-reviewer$')

    # 2c: GENERATED CODE non-exempt
    Remove-Item -LiteralPath (Join-Path $r2 'src') -Recurse -Force
    New-Item -ItemType Directory -Path (Join-Path $r2 'src') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $r2 'src\client.generated.ts'), "export const ver = 1;`n", $utf8NoBom)
    $psGen = Invoke-PsGuard @('review-inventory', '-RepoRoot', $r2, '-BaseSha', $base2)
    $genOk = ($psGen.Code -eq 0) -and ($psGen.Text -match 'risk_level=MEDIUM') -and ($psGen.Text -match 'risk_signals=generated_code') -and ($psGen.Text -match 'generated_files=src/client\.generated\.ts')

    # 2d: XXL + LOW (101 docs files totaling 22,000 LOC)
    Remove-Item -LiteralPath (Join-Path $r2 'src') -Recurse -Force
    New-Item -ItemType Directory -Path (Join-Path $r2 'docs') -Force | Out-Null
    1..100 | ForEach-Object {
        $n = '{0:D3}' -f $_
        [IO.File]::WriteAllText((Join-Path $r2 "docs\p${n}.md"), ("Documentation text about architecture and auth guidelines.`n" * 100), $utf8NoBom)
    }
    [IO.File]::WriteAllText((Join-Path $r2 'docs\p101.md'), ("Documentation text.`n" * 12000), $utf8NoBom)
    & git -C $r2 add docs
    $psXxlLow = Invoke-PsGuard @('diff-scope', '-RepoRoot', $r2, '-BaseSha', $base2)
    $shXxlLow = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' diff-scope --repo-root '$r2Posix' --base-sha '$base2'" } else { $psXxlLow }
    $xxlLowOk = ($psXxlLow.Code -eq 0) -and ($psXxlLow.Text -match 'size_class=XXL') -and ($psXxlLow.Text -match 'lines=22000') -and
                ($psXxlLow.Text -match 'risk_level=LOW') -and ($psXxlLow.Text -match 'risk_signals=none') -and
                ($psXxlLow.Text -match 'recommended_specialists=none') -and ($shXxlLow.Text -ceq $psXxlLow.Text)

    if ($xsCritOk -and $perfOk -and $genOk -and $xxlLowOk) {
        Pass 'risk-decoupling-and-dispatch'
    } else {
        FailCheck 'risk-decoupling-and-dispatch' "xsCrit=$xsCritOk perf=$perfOk gen=$genOk xxlLow=$xxlLowOk ps=[$($psXsCrit.Text) | $($psXxlLow.Text)]"
    }

    # --- 3. xxl-25k-mixed-inventory-parity (25,000+ LOC mixed-risk PR via --target-ref) ---
    $r3 = Join-Path $sandbox 'xxl-25k-repo'
    $r3Posix = $r3 -replace '\\', '/'
    Init-Repo $r3
    $base3 = (& git -C $r3 rev-parse HEAD).Trim()
    Push-Location $r3
    & git checkout -qb feat/huge-pr
    # Auth (CRITICAL) + matching test under tests/auth/ (paired into src/auth!)
    New-Item -ItemType Directory -Path 'src\auth', 'tests\auth', 'src\contracts', 'src\render', 'docs\api', 'docs\arch', 'docs\ops' -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $r3 'src\auth\jwt.ts'), ("export function verifyToken(tok: string) { return tok !== ''; }`n" * 120), $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $r3 'tests\auth\jwt.test.ts'), ("export const authTest = true;`n" * 40), $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $r3 'src\contracts\order.ts'), ("export interface OrderDto { id: string; }`n" * 150), $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $r3 'src\render\scene.ts'), ("export function onTick() { useFrame(() => {}); }`n" * 150), $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $r3 'docs\api\spec.md'), ("Detailed API guide content line.`n" * 4000), $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $r3 'docs\arch\design.md'), ("Detailed arch design content line.`n" * 4000), $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $r3 'docs\ops\runbook.md'), ("Detailed ops runbook content line.`n" * 4000), $utf8NoBom)
    # 16 cohesive feature modules (each <=1000 lines, total >25k LOC, >100 files total)
    1..16 | ForEach-Object {
        $m = 'm{0:D2}' -f $_
        $dir = Join-Path $r3 "src\$m"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        1..7 | ForEach-Object {
            $fi = $_
            [IO.File]::WriteAllText((Join-Path $dir "file${fi}.ts"), ("export const v_${m}_${fi} = ${fi};`n" * 120), $utf8NoBom)
        }
    }
    & git add .
    & git commit -qm '25k mixed PR'
    $pr3Sha = (& git rev-parse HEAD).Trim()
    & git checkout -q -b main-check $base3
    Pop-Location

    $swPs = [System.Diagnostics.Stopwatch]::StartNew()
    $ps25 = Invoke-PsGuard @('review-inventory', '-RepoRoot', $r3, '-BaseSha', $base3, '-TargetRef', $pr3Sha, '-MaxConcurrency', '4')
    $swPs.Stop()
    $sh25 = $ps25
    $shSec = 0.0
    if ($hasBash) {
        $swSh = [System.Diagnostics.Stopwatch]::StartNew()
        $sh25 = Invoke-ShGuard "'$guardShPosix' review-inventory --repo-root '$r3Posix' --base-sha '$base3' --target-ref '$pr3Sha' --max-concurrency 4"
        $swSh.Stop()
        $shSec = [math]::Round($swSh.Elapsed.TotalSeconds, 3)
    }
    $psSec = [math]::Round($swPs.Elapsed.TotalSeconds, 3)
    Write-Output "INFO 25k-inventory timing: ps=${psSec}s sh=${shSec}s"

    $ok25 = ($ps25.Code -eq 0) -and ($sh25.Code -eq 0) -and ($sh25.Text -ceq $ps25.Text) -and
            ($ps25.Text -match 'size_class=XXL') -and ($ps25.Text -match 'risk_level=CRITICAL') -and
            ($ps25.Text -match '(?m)^l1_specialists=b3-architecture-reviewer,b3-performance-reviewer,b3-security-reviewer$') -and
            ($ps25.Text -match '(?m)^l1_skip_rationale=none$') -and
            ($ps25.Text -match 'split_recommended=true') -and ($ps25.Text -match 'max_concurrency=4') -and
            ($ps25.Text -match 'unit\|U\d+\|docs/api\|1\|4000\|LOW\|none\|') -and
            ($ps25.Text -match 'unit\|U\d+\|docs/arch\|1\|4000\|LOW\|none\|') -and
            ($ps25.Text -match 'unit\|U\d+\|docs/ops\|1\|4000\|LOW\|none\|') -and
            ($ps25.Text -match 'unit\|U\d+\|src/auth\|2\|160\|CRITICAL\|b3-security-reviewer\|.*\|src/auth/jwt\.ts,tests/auth/jwt\.test\.ts') -and
            ($ps25.Text -match 'unit\|U\d+\|src/contracts\|1\|150\|HIGH\|b3-architecture-reviewer\|') -and
            ($ps25.Text -match 'unit\|U\d+\|src/render\|1\|150\|HIGH\|b3-performance-reviewer\|') -and
            ($ps25.Text -match 'unit\|U\d+\|src/m01\|7\|840\|MEDIUM\|none\|general_code_change\|')
    $ucMatch = [regex]::Match($ps25.Text, '(?m)^unit_count=(\d+)$')
    $ucVal = if ($ucMatch.Success) { [int]$ucMatch.Groups[1].Value } else { 0 }
    $ok25 = $ok25 -and ($ucVal -ge 22)
    if ($ok25) { Pass 'xxl-25k-mixed-inventory-parity' } else { FailCheck 'xxl-25k-mixed-inventory-parity' "uc=$ucVal eq=$($sh25.Text -ceq $ps25.Text) text=$($ps25.Text)" }

    # --- 4. ledger-coverage-invalidation-resume-budget ---
    $r4 = Join-Path $sandbox 'ledger-repo'
    $r4Posix = $r4 -replace '\\', '/'
    Init-Repo $r4
    $base4 = (& git -C $r4 rev-parse HEAD).Trim()
    New-Item -ItemType Directory -Path (Join-Path $r4 'docs'), (Join-Path $r4 'src\auth'), (Join-Path $r4 'src\contracts'), (Join-Path $r4 'src\orders') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $r4 'docs\notes.md'), ("Docs line.`n" * 805), $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $r4 'src\auth\login.ts'), "export function verifyToken(t: string) { return t.length > 0; }`n", $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $r4 'src\contracts\order.ts'), "export interface Order { id: string; }`n", $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $r4 'src\orders\handler.ts'), "import type { Order } from '../contracts/order';`nexport const makeOrder = (o: Order) => o;`n", $utf8NoBom)
    & git -C $r4 add .; & git -C $r4 commit -qm 'work'

    $lp = '.b3/ship/review-loop/r4/ledger.md'
    $psLInit = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r4, '-Action', 'init', '-LedgerPath', $lp, '-BaseSha', $base4, '-MaxConcurrency', '3', '-MaxPasses', '15')
    $chkPending = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r4, '-Action', 'check', '-LedgerPath', $lp)

    # Units sorted: U01=docs (LOW), U02=src/auth (CRITICAL), U03=src/contracts (HIGH), U04=src/orders (LOW)
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r4, '-Action', 'update', '-LedgerPath', $lp, '-UnitId', 'U01', '-Status', 'REVIEWED'))
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r4, '-Action', 'update', '-LedgerPath', $lp, '-UnitId', 'U02', '-Status', 'REVIEWED')) # Missing specialist!
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r4, '-Action', 'update', '-LedgerPath', $lp, '-UnitId', 'U03', '-Status', 'REVIEWED', '-Specialists', 'b3-architecture-reviewer'))
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r4, '-Action', 'update', '-LedgerPath', $lp, '-UnitId', 'U04', '-Status', 'IN_PROGRESS')) # Interrupted!
    $chkNoSpec = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r4, '-Action', 'check', '-LedgerPath', $lp)

    # Fix specialist on U02, still missing verify_receipt on CRITICAL unit U02!
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r4, '-Action', 'update', '-LedgerPath', $lp, '-UnitId', 'U02', '-Specialists', 'b3-security-reviewer'))
    $chkNoRec = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r4, '-Action', 'check', '-LedgerPath', $lp)

    # Create receipts for U02 and U03, mark U04 REVIEWED, leave cross_unit PENDING -> must block
    [void](Invoke-PsGuard @('verify-run', '-RepoRoot', $r4, '-VerifyCmd', 'echo auth-ok', '-ReceiptPath', '.b3/ship/review-loop/r4/evidence/u02.verify', '-RelevantPaths', 'src/auth/login.ts'))
    [void](Invoke-PsGuard @('verify-run', '-RepoRoot', $r4, '-VerifyCmd', 'echo contract-ok', '-ReceiptPath', '.b3/ship/review-loop/r4/evidence/u03.verify', '-RelevantPaths', 'src/contracts/order.ts'))
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r4, '-Action', 'update', '-LedgerPath', $lp, '-UnitId', 'U02', '-Status', 'REVIEWED', '-ReceiptPath', '.b3/ship/review-loop/r4/evidence/u02.verify'))
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r4, '-Action', 'update', '-LedgerPath', $lp, '-UnitId', 'U03', '-Status', 'REVIEWED', '-ReceiptPath', '.b3/ship/review-loop/r4/evidence/u03.verify'))
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r4, '-Action', 'update', '-LedgerPath', $lp, '-UnitId', 'U04', '-Status', 'IN_PROGRESS'))
    $chkResume = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r4, '-Action', 'check', '-LedgerPath', $lp)

    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r4, '-Action', 'update', '-LedgerPath', $lp, '-UnitId', 'U04', '-Status', 'REVIEWED', '-Findings', 'R001:OPEN'))
    $chkOpenF = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r4, '-Action', 'check', '-LedgerPath', $lp)

    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r4, '-Action', 'update', '-LedgerPath', $lp, '-UnitId', 'U04', '-Status', 'REVIEWED', '-Findings', 'R001:VERIFIED'))
    $chkCrossPend = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r4, '-Action', 'check', '-LedgerPath', $lp)

    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r4, '-Action', 'update', '-LedgerPath', $lp, '-CrossUnitStatus', 'REVIEWED'))
    $psGatePass = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r4, '-Action', 'check', '-LedgerPath', $lp)
    $shGatePass = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r4Posix' --action check --ledger-path '$lp'" } else { $psGatePass }

    # Shared contract edit invalidates dependent reviewed unit (U03 + U04 hash includes contract_files!)
    [IO.File]::WriteAllText((Join-Path $r4 'src\contracts\order.ts'), "export interface Order { id: string; total: number; }`n", $utf8NoBom)
    $psStaleCon = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r4, '-Action', 'check', '-LedgerPath', $lp)
    $shStaleCon = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r4Posix' --action check --ledger-path '$lp'" } else { $psStaleCon }

    # Re-verify contracts + refresh affected units + cross-unit back to PASS, then test uncovered file + exhausted budget
    [void](Invoke-PsGuard @('verify-run', '-RepoRoot', $r4, '-VerifyCmd', 'echo contract-ok2', '-ReceiptPath', '.b3/ship/review-loop/r4/evidence/u03.verify', '-RelevantPaths', 'src/contracts/order.ts'))
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r4, '-Action', 'update', '-LedgerPath', $lp, '-UnitId', 'U01', '-Status', 'REVIEWED'))
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r4, '-Action', 'update', '-LedgerPath', $lp, '-UnitId', 'U02', '-Status', 'REVIEWED'))
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r4, '-Action', 'update', '-LedgerPath', $lp, '-UnitId', 'U03', '-Status', 'REVIEWED'))
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r4, '-Action', 'update', '-LedgerPath', $lp, '-UnitId', 'U04', '-Status', 'REVIEWED'))
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r4, '-Action', 'update', '-LedgerPath', $lp, '-CrossUnitStatus', 'REVIEWED'))
    New-Item -ItemType Directory -Path (Join-Path $r4 'src\extra') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $r4 'src\extra\new.ts'), "export const x = 1;`n", $utf8NoBom)
    $chkUncov = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r4, '-Action', 'check', '-LedgerPath', $lp)
    Remove-Item -LiteralPath (Join-Path $r4 'src\extra') -Recurse -Force

    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r4, '-Action', 'update', '-LedgerPath', $lp, '-PassesUsed', '16', '-BudgetStatus', 'EXHAUSTED'))
    $psBudget = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r4, '-Action', 'check', '-LedgerPath', $lp)
    $shBudget = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r4Posix' --action check --ledger-path '$lp'" } else { $psBudget }

    $ok4 = ($psLInit.Code -eq 0) -and ($psLInit.Text -match 'LEDGER_INIT:.*size=L risk=CRITICAL units=4') -and
           ($chkPending.Code -eq 2) -and ($chkPending.Text -match 'LEDGER_INCOMPLETE: unit U01 status=PENDING') -and
           ($chkNoSpec.Code -eq 2) -and ($chkNoSpec.Text -match 'mandatory CRITICAL specialist') -and
           ($chkNoRec.Code -eq 2) -and ($chkNoRec.Text -match 'missing verify_receipt') -and
           ($chkResume.Code -eq 2) -and ($chkResume.Text -match 'U04 status=IN_PROGRESS') -and
           ($chkOpenF.Code -eq 2) -and ($chkOpenF.Text -match 'unresolved findings') -and
           ($chkCrossPend.Code -eq 2) -and ($chkCrossPend.Text -match 'cross_unit_status=PENDING') -and
           ($psGatePass.Code -eq 0) -and ($psGatePass.Text -match 'LEDGER_GATE_PASS:') -and ($shGatePass.Text -ceq $psGatePass.Text) -and
           ($psStaleCon.Code -eq 2) -and ($psStaleCon.Text -match 'LEDGER_STALE:') -and ($shStaleCon.Text -ceq $psStaleCon.Text) -and
           ($chkUncov.Code -eq 2) -and ($chkUncov.Text -match 'uncovered files \(src/extra/new\.ts\)') -and
           ($psBudget.Code -eq 2) -and ($psBudget.Text -match 'budget exhausted') -and ($shBudget.Text -ceq $psBudget.Text)
    if ($ok4) { Pass 'ledger-coverage-invalidation-resume-budget' } else {
        FailCheck 'ledger-coverage-invalidation-resume-budget' "pend=$($chkPending.Text) spec=$($chkNoSpec.Text) rec=$($chkNoRec.Text) res=$($chkResume.Text) open=$($chkOpenF.Text) cu=$($chkCrossPend.Text) pass=$($psGatePass.Text) stale=$($psStaleCon.Text) uncov=$($chkUncov.Text) bdg=$($psBudget.Text)"
    }

    # --- 5. legacy-normalization-safety-and-edge-cases ---
    $r5 = Join-Path $sandbox 'legacy-edge-repo'
    $r5Posix = $r5 -replace '\\', '/'
    Init-Repo $r5
    $base5 = (& git -C $r5 rev-parse HEAD).Trim()
    [IO.File]::WriteAllText((Join-Path $r5 'app.ts'), "export const a = 1;`n", $utf8NoBom)
    & git -C $r5 add app.ts; & git -C $r5 commit -qm 'app'
    $stPath = Join-Path $r5 '.b3\ship\legacy-state.md'
    New-Item -ItemType Directory -Path (Split-Path -Parent $stPath) -Force | Out-Null
    [IO.File]::WriteAllText($stPath, "size_class: VERY_LARGE`niter: 1`n", $utf8NoBom)
    $psNormSt = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r5, '-Action', 'normalize', '-LedgerPath', '.b3/ship/legacy-state.md')
    $stTxt = [IO.File]::ReadAllText($stPath)
    $shNormSm = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r5Posix' --action normalize --scope LARGE" } else { @{ Code = 0; Text = 'L' } }

    # Sensitive untracked fails review-ledger init cleanly without writing secret blob
    [IO.File]::WriteAllText((Join-Path $r5 '.env'), "API_SECRET=12345`n", $utf8NoBom)
    $envOid = (& git -C $r5 hash-object -- .env).Trim()
    $psSecInit = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r5, '-Action', 'init', '-LedgerPath', '.b3/ship/sec.md', '-BaseSha', $base5)
    $shSecInit = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r5Posix' --action init --ledger-path '.b3/ship/sec.md' --base-sha '$base5'" } else { $psSecInit }
    & git -C $r5 cat-file -e $envOid 2>$null
    $noEnvBlob = ($LASTEXITCODE -ne 0)
    Remove-Item -LiteralPath (Join-Path $r5 '.env') -Force

    # Dirty submodule fails review-ledger init closed
    $subOrg = Join-Path $sandbox 'sub-edge-org'
    Init-Repo $subOrg
    Push-Location $r5
    & git -c protocol.file.allow=always submodule add -q $subOrg libs/sub
    Pop-Location
    [IO.File]::WriteAllText((Join-Path $r5 'libs\sub\dirty.txt'), "dirty`n", $utf8NoBom)
    $psSubInit = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r5, '-Action', 'init', '-LedgerPath', '.b3/ship/sub.md', '-BaseSha', $base5)
    $shSubInit = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r5Posix' --action init --ledger-path '.b3/ship/sub.md' --base-sha '$base5'" } else { $psSubInit }

    # No-op fix detection (snapshot + immediate diff-scope -PrevSha -> delta_files=none)
    Remove-Item -LiteralPath (Join-Path $r5 'libs\sub\dirty.txt') -Force
    $snapNoop = (Invoke-PsGuard @('snapshot', '-RepoRoot', $r5)).Text.Trim()
    $dsNoop = Invoke-PsGuard @('diff-scope', '-RepoRoot', $r5, '-BaseSha', $base5, '-PrevSha', $snapNoop)

    $ok5 = ($psNormSt.Code -eq 0) -and ($psNormSt.Text -match 'changes=1') -and ($stTxt -match 'size_class: XL') -and
           ($shNormSm.Code -eq 0) -and ($shNormSm.Text.Trim() -ceq 'L') -and
           ($psSecInit.Code -eq 1) -and ($psSecInit.Text -match 'sensitive path cannot be snapshotted') -and ($shSecInit.Text -ceq $psSecInit.Text) -and $noEnvBlob -and
           ($psSubInit.Code -eq 1) -and ($psSubInit.Text -match 'dirty submodule cannot be snapshotted') -and ($shSubInit.Text -ceq $psSubInit.Text) -and
           ($dsNoop.Code -eq 0) -and ($dsNoop.Text -match 'delta_files=none')
    if ($ok5) { Pass 'legacy-normalization-safety-and-edge-cases' } else {
        FailCheck 'legacy-normalization-safety-and-edge-cases' "norm=$($psNormSt.Text) sec=$($psSecInit.Text) blob=$noEnvBlob sub=$($psSubInit.Text) noop=$($dsNoop.Text)"
    }

    # --- 6. ledger-cross-shell-targetref-and-risk-escalation ---
    $r6 = Join-Path $sandbox 'cross-targetref-repo'
    $r6Posix = $r6 -replace '\\', '/'
    $r6Msys = [regex]::Replace($r6Posix, '^([A-Za-z]):', { param($m) '/' + $m.Groups[1].Value.ToLowerInvariant() })
    Init-Repo $r6
    New-Item -ItemType Directory -Path (Join-Path $r6 'src\del'), (Join-Path $r6 'src\feat'), (Join-Path $r6 'src\contracts') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $r6 'src\del\old.ts'), "export const legacy = 1;`n", $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $r6 'src\feat\app.ts'), "export const feat = 1;`n", $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $r6 'src\contracts\api.ts'), "export interface ApiV1 { ok: boolean; }`n", $utf8NoBom)
    & git -C $r6 add .; & git -C $r6 commit -qm 'base6'
    $base6 = (& git -C $r6 rev-parse HEAD).Trim()

    & git -C $r6 checkout -qb 'pr-target'
    & git -C $r6 rm -q 'src/del/old.ts'
    [IO.File]::WriteAllText((Join-Path $r6 'src\feat\app.ts'), "export const feat = 2;`n", $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $r6 'src\contracts\api.ts'), "export interface ApiV1 { ok: boolean; id: string; }`n", $utf8NoBom)
    & git -C $r6 add .; & git -C $r6 commit -qm 'pr6'

    $psMissingMsys = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r6, '-Action', 'check', '-LedgerPath', '.b3/ship/nonexistent.md')
    $shMissingMsys = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r6Msys' --action check --ledger-path '.b3/ship/nonexistent.md'" } else { $psMissingMsys }
    Push-Location $r6
    try {
        $psDotAbs = Invoke-PsGuard @('review-ledger', '-RepoRoot', '.', '-Action', 'check', '-LedgerPath', "$r6\.b3\ship\nonexistent.md")
        $shDotAbs = if ($hasBash) { Invoke-ShGuard "cd '$r6Msys' && '$guardShPosix' review-ledger --repo-root . --action check --ledger-path '$r6Posix/.b3/ship/nonexistent.md'" } else { $psDotAbs }
    } finally {
        Pop-Location -ErrorAction SilentlyContinue
    }

    $trLp = '.b3/ship/tr-ledger.md'
    $psTrInit = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r6, '-Action', 'init', '-LedgerPath', $trLp, '-BaseSha', $base6, '-TargetRef', 'pr-target')
    $shTrInit = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r6Msys' --action init --ledger-path '.b3/ship/tr-ledger-sh.md' --base-sha '$base6' --target-ref 'pr-target'" } else { $psTrInit }
    $trTxt = [IO.File]::ReadAllText((Join-Path $r6 '.b3\ship\tr-ledger.md'))
    $trShTxt = if ($hasBash) { [IO.File]::ReadAllText((Join-Path $r6 '.b3\ship\tr-ledger-sh.md')) } else { $trTxt }
    $unitRows6 = @{}
    foreach ($ln in ($trTxt -split "`n")) {
        if ($ln -match '^\|\s*(U\d+)\s*\|') {
            $cols = @($ln.Split('|') | ForEach-Object { $_.Trim() })
            if ($cols.Count -ge 13) { $unitRows6[$cols[12]] = $cols[1] }
        }
    }
    $uDel = $unitRows6['src/del/old.ts']
    $uCon = $unitRows6['src/contracts/api.ts']
    $uFeat = $unitRows6['src/feat/app.ts']
    [void](Invoke-PsGuard @('verify-run', '-RepoRoot', $r6, '-VerifyCmd', 'echo tr-con-ok', '-ReceiptPath', '.b3/ship/tr-con.verify', '-RelevantPaths', 'src/contracts/api.ts'))
    if ($hasBash) {
        [void](Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r6Msys' --action update --ledger-path '$trLp' --unit-id '$uDel' --status REVIEWED")
        [void](Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r6Msys' --action update --ledger-path '$trLp' --unit-id '$uCon' --status REVIEWED --specialists b3-architecture-reviewer --receipt-path '.b3/ship/tr-con.verify'")
    } else {
        [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r6, '-Action', 'update', '-LedgerPath', $trLp, '-UnitId', $uDel, '-Status', 'REVIEWED'))
        [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r6, '-Action', 'update', '-LedgerPath', $trLp, '-UnitId', $uCon, '-Status', 'REVIEWED', '-Specialists', 'b3-architecture-reviewer', '-ReceiptPath', '.b3/ship/tr-con.verify'))
    }
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r6, '-Action', 'update', '-LedgerPath', $trLp, '-UnitId', $uFeat, '-Status', 'REVIEWED'))
    $psTrChk = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r6, '-Action', 'check', '-LedgerPath', $trLp)
    $shTrChk = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r6Msys' --action check --ledger-path '$trLp'" } else { $psTrChk }

    # Risk escalation (LOW -> CRITICAL): check fails closed until specialist + receipt + update refresh unit risk
    $r6b = Join-Path $sandbox 'risk-escalation-repo'
    $r6bPosix = $r6b -replace '\\', '/'
    Init-Repo $r6b
    $base6b = (& git -C $r6b rev-parse HEAD).Trim()
    New-Item -ItemType Directory -Path (Join-Path $r6b 'src\pay') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $r6b 'src\pay\calc.ts'), "export const calc = (n: number) => n + 1;`n", $utf8NoBom)
    & git -C $r6b add .; & git -C $r6b commit -qm 'low'
    $escLp = '.b3/ship/esc-ledger.md'
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r6b, '-Action', 'init', '-LedgerPath', $escLp, '-BaseSha', $base6b))
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r6b, '-Action', 'update', '-LedgerPath', $escLp, '-UnitId', 'U01', '-Status', 'REVIEWED'))
    $psEscLow = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r6b, '-Action', 'check', '-LedgerPath', $escLp)

    [IO.File]::WriteAllText((Join-Path $r6b 'src\pay\calc.ts'), "export function verifyToken(t: string) { return jwt.verify(t, crypto.createHash('sha256').digest('hex')); }`n", $utf8NoBom)
    $psEscStale = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r6b, '-Action', 'check', '-LedgerPath', $escLp)
    $shEscStale = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r6bPosix' --action check --ledger-path '$escLp'" } else { $psEscStale }

    # Re-marking REVIEWED without specialist/receipt must still fail closed
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r6b, '-Action', 'update', '-LedgerPath', $escLp, '-UnitId', 'U01', '-Status', 'REVIEWED'))
    $chkEscNeedSpec = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r6b, '-Action', 'check', '-LedgerPath', $escLp)
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r6b, '-Action', 'update', '-LedgerPath', $escLp, '-UnitId', 'U01', '-Specialists', 'b3-security-reviewer'))
    $chkEscNeedRec = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r6b, '-Action', 'check', '-LedgerPath', $escLp)

    [void](Invoke-PsGuard @('verify-run', '-RepoRoot', $r6b, '-VerifyCmd', 'echo esc-sec-ok', '-ReceiptPath', '.b3/ship/esc.verify', '-RelevantPaths', 'src/pay/calc.ts'))
    if ($hasBash) {
        [void](Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r6bPosix' --action update --ledger-path '$escLp' --unit-id U01 --status REVIEWED --specialists b3-security-reviewer --receipt-path '.b3/ship/esc.verify'")
    } else {
        [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r6b, '-Action', 'update', '-LedgerPath', $escLp, '-UnitId', 'U01', '-Status', 'REVIEWED', '-Specialists', 'b3-security-reviewer', '-ReceiptPath', '.b3/ship/esc.verify'))
    }
    $psEscPass = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r6b, '-Action', 'check', '-LedgerPath', $escLp)
    $shEscPass = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r6bPosix' --action check --ledger-path '$escLp'" } else { $psEscPass }

    # Bash normalize preserves trailing newline
    $shNormPath = Join-Path $r6b '.b3\ship\sh-norm.md'
    New-Item -ItemType Directory -Path (Split-Path -Parent $shNormPath) -Force | Out-Null
    [IO.File]::WriteAllText($shNormPath, "size_class: VERY_LARGE`niter: 1`n", $utf8NoBom)
    if ($hasBash) {
        $shNormRes = Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r6bPosix' --action normalize --ledger-path '.b3/ship/sh-norm.md'"
        $shNormTxt = [IO.File]::ReadAllText($shNormPath)
        $shNormOk = ($shNormRes.Code -eq 0) -and ($shNormTxt -ceq "size_class: XL`niter: 1`n")
    } else {
        $shNormOk = $true
    }

    $ok6 = ($shMissingMsys.Code -eq 1) -and ($shMissingMsys.Text -ceq 'LEDGER_MISSING: .b3/ship/nonexistent.md') -and ($shMissingMsys.Text -ceq $psMissingMsys.Text) -and
           ($shDotAbs.Code -eq 1) -and ($shDotAbs.Text -ceq 'LEDGER_MISSING: .b3/ship/nonexistent.md') -and ($shDotAbs.Text -ceq $psDotAbs.Text) -and
           ($psTrInit.Code -eq 0) -and ($shTrInit.Code -eq 0) -and ($trTxt -ceq $trShTxt) -and
           ($uDel -ne '') -and ($uCon -ne '') -and ($uFeat -ne '') -and
           ($psTrChk.Code -eq 0) -and ($psTrChk.Text -match 'LEDGER_GATE_PASS:') -and ($shTrChk.Code -eq 0) -and ($shTrChk.Text -ceq $psTrChk.Text) -and
           ($psEscLow.Code -eq 0) -and ($psEscLow.Text -match 'risk=LOW') -and
           ($psEscStale.Code -eq 2) -and ($psEscStale.Text -match 'LEDGER_STALE: unit U01 risk changed \(LOW->CRITICAL\)') -and ($shEscStale.Text -ceq $psEscStale.Text) -and
           ($chkEscNeedSpec.Code -eq 2) -and ($chkEscNeedSpec.Text -match 'mandatory CRITICAL specialist') -and
           ($chkEscNeedRec.Code -eq 2) -and ($chkEscNeedRec.Text -match 'missing verify_receipt for CRITICAL unit U01') -and
           ($psEscPass.Code -eq 0) -and ($psEscPass.Text -match 'LEDGER_GATE_PASS:.*risk=CRITICAL') -and ($shEscPass.Code -eq 0) -and ($shEscPass.Text -ceq $psEscPass.Text) -and
           $shNormOk
    if ($ok6) { Pass 'ledger-cross-shell-targetref-and-risk-escalation' } else {
        FailCheck 'ledger-cross-shell-targetref-and-risk-escalation' "msys=$($shMissingMsys.Text) dot=$($shDotAbs.Text) trEq=$($trTxt -ceq $trShTxt) trChk=(ps=$($psTrChk.Text)|sh=$($shTrChk.Text)) stale=$($psEscStale.Text) needSp=$($chkEscNeedSpec.Text) needRec=$($chkEscNeedRec.Text) escPass=(ps=$($psEscPass.Text)|sh=$($shEscPass.Text)) norm=$shNormOk"
    }

    # --- 7. security-dir-path-detection ---
    $r7 = Join-Path $sandbox 'sec-dir-repo'
    $r7Posix = $r7 -replace '\\', '/'
    Init-Repo $r7
    $base7 = (& git -C $r7 rev-parse HEAD).Trim()
    $secDirOk = $true
    $secDirFail = ''
    foreach ($secRel in @('src/auth/login.ts', 'src/security/access.ts', 'src/permissions/guard.ts', 'src/oauth/callback.ts', 'src/auth.ts')) {
        & git -C $r7 reset -q HEAD -- . 2>$null
        & git -C $r7 clean -qf -d -- src docs tests evals 2>$null
        $fullSec = Join-Path $r7 ($secRel -replace '/', '\')
        New-Item -ItemType Directory -Path (Split-Path -Parent $fullSec) -Force | Out-Null
        [IO.File]::WriteAllText($fullSec, "export const handler = (v: number) => v + 1;`n", $utf8NoBom)
        $psSd = Invoke-PsGuard @('diff-scope', '-RepoRoot', $r7, '-BaseSha', $base7)
        $shSd = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' diff-scope --repo-root '$r7Posix' --base-sha '$base7'" } else { $psSd }
        if ($psSd.Code -ne 0 -or ($psSd.Text -notmatch 'risk_level=CRITICAL') -or ($psSd.Text -notmatch 'risk_signals=auth_security') -or ($psSd.Text -notmatch 'recommended_specialists=b3-security-reviewer') -or ($shSd.Text -cne $psSd.Text)) {
            $secDirOk = $false
            $secDirFail = "secFile=$secRel ps=$($psSd.Text) sh=$($shSd.Text)"
            break
        }
    }
    if ($secDirOk) {
        foreach ($safeRel in @('docs/auth/guide.md', 'tests/auth/login.test.ts', 'src/authors/list.ts', 'evals/auth/case.yaml')) {
            & git -C $r7 reset -q HEAD -- . 2>$null
            & git -C $r7 clean -qf -d -- src docs tests evals 2>$null
            $fullSafe = Join-Path $r7 ($safeRel -replace '/', '\')
            New-Item -ItemType Directory -Path (Split-Path -Parent $fullSafe) -Force | Out-Null
            [IO.File]::WriteAllText($fullSafe, "export const item = 1;`n", $utf8NoBom)
            $psSf = Invoke-PsGuard @('diff-scope', '-RepoRoot', $r7, '-BaseSha', $base7)
            $shSf = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' diff-scope --repo-root '$r7Posix' --base-sha '$base7'" } else { $psSf }
            if ($psSf.Code -ne 0 -or ($psSf.Text -notmatch 'risk_level=LOW') -or ($psSf.Text -notmatch 'risk_signals=none') -or ($psSf.Text -notmatch 'recommended_specialists=none') -or ($shSf.Text -cne $psSf.Text)) {
                $secDirOk = $false
                $secDirFail = "safeFile=$safeRel ps=$($psSf.Text) sh=$($shSf.Text)"
                break
            }
        }
    }
    if ($secDirOk) { Pass 'security-dir-path-detection' } else { FailCheck 'security-dir-path-detection' $secDirFail }

    # --- 8. critical-specialist-waiver-policy ---
    $r8 = Join-Path $sandbox 'waiver-repo'
    $r8Posix = $r8 -replace '\\', '/'
    Init-Repo $r8
    $base8 = (& git -C $r8 rev-parse HEAD).Trim()
    New-Item -ItemType Directory -Path (Join-Path $r8 'src\contracts'), (Join-Path $r8 'src\security') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $r8 'src\contracts\api.ts'), "export interface Dto { id: string; }`n", $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $r8 'src\security\access.ts'), "export const ok = (x: number) => x > 0;`n", $utf8NoBom)
    & git -C $r8 add .; & git -C $r8 commit -qm 'sec-and-contract'
    $wLp = '.b3/ship/waiver-ledger.md'
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r8, '-Action', 'init', '-LedgerPath', $wLp, '-BaseSha', $base8, '-MaxPasses', '10'))
    [void](Invoke-PsGuard @('verify-run', '-RepoRoot', $r8, '-VerifyCmd', 'echo w-u01', '-ReceiptPath', '.b3/ship/w1.verify', '-RelevantPaths', 'src/contracts/api.ts'))
    [void](Invoke-PsGuard @('verify-run', '-RepoRoot', $r8, '-VerifyCmd', 'echo w-u02', '-ReceiptPath', '.b3/ship/w2.verify', '-RelevantPaths', 'src/security/access.ts'))
    # U01=src/contracts (HIGH): non-none rationale >=5 chars allowed
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r8, '-Action', 'update', '-LedgerPath', $wLp, '-UnitId', 'U01', '-Status', 'REVIEWED', '-Rationale', 'Reviewed contract inline', '-ReceiptPath', '.b3/ship/w1.verify'))
    # U02=src/security (CRITICAL): free-form rationale must FAIL CLOSED
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r8, '-Action', 'update', '-LedgerPath', $wLp, '-UnitId', 'U02', '-Status', 'REVIEWED', '-Rationale', 'looks fine no security risk needed', '-ReceiptPath', '.b3/ship/w2.verify'))
    $psFreeDeny = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r8, '-Action', 'check', '-LedgerPath', $wLp)
    $shFreeDeny = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r8Posix' --action check --ledger-path '$wLp'" } else { $psFreeDeny }
    # Self-declared waiver attempts (even syntactically structured) MUST FAIL CLOSED as LEDGER_BLOCKED (R002)
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r8, '-Action', 'update', '-LedgerPath', $wLp, '-UnitId', 'U02', '-Status', 'REVIEWED', '-Rationale', 'WAIVER:approved_by=agent;ticket=SEC-101;reason=Static schema adapter only no auth'))
    $psPhDeny = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r8, '-Action', 'check', '-LedgerPath', $wLp)
    $shPhDeny = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r8Posix' --action check --ledger-path '$wLp'" } else { $psPhDeny }
    $bsWaiver = 'WAIVER:approved_by=sec-lead@corp;ticket=SEC-404;reason=123456\n78'
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r8, '-Action', 'update', '-LedgerPath', $wLp, '-UnitId', 'U02', '-Status', 'REVIEWED', '-Rationale', $bsWaiver))
    $psBsWaiverDeny = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r8, '-Action', 'check', '-LedgerPath', $wLp)
    $shBsWaiverDeny = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r8Posix' --action check --ledger-path '$wLp'" } else { $psBsWaiverDeny }
    $validWaiver = 'WAIVER:approved_by=sec-lead@corp;ticket=SEC-404;reason=Pure DTO mapper verified by security owner'
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r8, '-Action', 'update', '-LedgerPath', $wLp, '-UnitId', 'U02', '-Status', 'REVIEWED', '-Rationale', $validWaiver))
    $psWaiverDeny = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r8, '-Action', 'check', '-LedgerPath', $wLp)
    $shWaiverDeny = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r8Posix' --action check --ledger-path '$wLp'" } else { $psWaiverDeny }
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r8, '-Action', 'update', '-LedgerPath', $wLp, '-UnitId', 'U02', '-Status', 'REVIEWED', '-Rationale', 'waiver:approved_by=sec-lead@corp;ticket=SEC-404;reason=lowercase check'))
    $psLowerDeny = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r8, '-Action', 'check', '-LedgerPath', $wLp)
    $shLowerDeny = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r8Posix' --action check --ledger-path '$wLp'" } else { $psLowerDeny }
    # Only running the mandatory CRITICAL specialist allows U02 to pass (with no waivers= tag)
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r8, '-Action', 'update', '-LedgerPath', $wLp, '-UnitId', 'U02', '-Status', 'REVIEWED', '-Specialists', 'b3-security-reviewer', '-Rationale', 'none'))
    $psSpecOk = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r8, '-Action', 'check', '-LedgerPath', $wLp)
    $shSpecOk = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r8Posix' --action check --ledger-path '$wLp'" } else { $psSpecOk }
    $ok8 = ($psFreeDeny.Code -eq 2) -and ($psFreeDeny.Text -match 'mandatory CRITICAL specialist') -and ($shFreeDeny.Code -eq 2) -and ($shFreeDeny.Text -ceq $psFreeDeny.Text) -and
           ($psPhDeny.Code -eq 2) -and ($psPhDeny.Text -match 'LEDGER_BLOCKED: unverified CRITICAL specialist waiver rejected') -and ($shPhDeny.Code -eq 2) -and ($shPhDeny.Text -ceq $psPhDeny.Text) -and
           ($psBsWaiverDeny.Code -eq 2) -and ($psBsWaiverDeny.Text -match 'LEDGER_BLOCKED: unverified CRITICAL specialist waiver rejected') -and ($shBsWaiverDeny.Code -eq 2) -and ($shBsWaiverDeny.Text -ceq $psBsWaiverDeny.Text) -and
           ($psWaiverDeny.Code -eq 2) -and ($psWaiverDeny.Text -match 'LEDGER_BLOCKED: unverified CRITICAL specialist waiver rejected') -and ($shWaiverDeny.Code -eq 2) -and ($shWaiverDeny.Text -ceq $psWaiverDeny.Text) -and
           ($psLowerDeny.Code -eq 2) -and ($psLowerDeny.Text -match 'LEDGER_BLOCKED: unverified CRITICAL specialist waiver rejected') -and ($shLowerDeny.Code -eq 2) -and ($shLowerDeny.Text -ceq $psLowerDeny.Text) -and
           ($psSpecOk.Code -eq 0) -and ($psSpecOk.Text -match '^LEDGER_GATE_PASS:') -and ($psSpecOk.Text -notmatch 'waivers=') -and ($shSpecOk.Code -eq 0) -and ($shSpecOk.Text -ceq $psSpecOk.Text)
    if ($ok8) { Pass 'critical-specialist-waiver-policy' } else {
        FailCheck 'critical-specialist-waiver-policy' "free=$($psFreeDeny.Text) ph=$($psPhDeny.Text) bs=$($psBsWaiverDeny.Text) wv=$($psWaiverDeny.Text) pass=(ps=$($psSpecOk.Text)|sh=$($shSpecOk.Text))"
    }

    # --- 9. target-ref-branch-movement-invalidation ---
    $r9 = Join-Path $sandbox 'branch-move-repo'
    $r9Posix = $r9 -replace '\\', '/'
    Init-Repo $r9
    New-Item -ItemType Directory -Path (Join-Path $r9 'src\a'), (Join-Path $r9 'src\b') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $r9 'src\a\m.ts'), "export const a = 1;`n", $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $r9 'src\b\m.ts'), "export const b = 1;`n", $utf8NoBom)
    & git -C $r9 add .; & git -C $r9 commit -qm 'base9'
    $base9 = (& git -C $r9 rev-parse HEAD).Trim()
    & git -C $r9 checkout -qb 'pr-branch'
    [IO.File]::WriteAllText((Join-Path $r9 'src\a\m.ts'), "export const a = 2;`n", $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $r9 'src\b\m.ts'), "export const b = 2;`n", $utf8NoBom)
    & git -C $r9 add .; & git -C $r9 commit -qm 'pr9-c1'
    $sha9_1 = (& git -C $r9 rev-parse HEAD).Trim()
    $brLp = '.b3/ship/branch-ledger.md'
    $psBrInit = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r9, '-Action', 'init', '-LedgerPath', $brLp, '-BaseSha', $base9, '-TargetRef', 'pr-branch')
    $brTxt = [IO.File]::ReadAllText((Join-Path $r9 '.b3\ship\branch-ledger.md'))
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r9, '-Action', 'update', '-LedgerPath', $brLp, '-UnitId', 'U01', '-Status', 'REVIEWED'))
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r9, '-Action', 'update', '-LedgerPath', $brLp, '-UnitId', 'U02', '-Status', 'REVIEWED'))
    $psBrPass1 = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r9, '-Action', 'check', '-LedgerPath', $brLp)
    # Advance pr-branch touching only src/b/m.ts
    [IO.File]::WriteAllText((Join-Path $r9 'src\b\m.ts'), "export const b = 3;`n", $utf8NoBom)
    & git -C $r9 add src/b/m.ts; & git -C $r9 commit -qm 'pr9-c2'
    $sha9_2 = (& git -C $r9 rev-parse HEAD).Trim()
    $psBrMoved = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r9, '-Action', 'check', '-LedgerPath', $brLp)
    $shBrMoved = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r9Posix' --action check --ledger-path '$brLp'" } else { $psBrMoved }
    # Metadata-only update without -Status REVIEWED must NOT refresh target_sha or unit_tree_hash
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r9, '-Action', 'update', '-LedgerPath', $brLp, '-UnitId', 'U02', '-Findings', 'none'))
    $psBrMetaStillStale = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r9, '-Action', 'check', '-LedgerPath', $brLp)
    if ($hasBash) {
        [void](Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r9Posix' --action update --ledger-path '$brLp' --unit-id U02 --findings none")
    }
    $shBrMetaStillStale = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r9Posix' --action check --ledger-path '$brLp'" } else { $psBrMetaStillStale }
    # Re-review only moved U02 -> updates target_sha to sha9_2 and U01 stays valid
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r9, '-Action', 'update', '-LedgerPath', $brLp, '-UnitId', 'U02', '-Status', 'REVIEWED'))
    $psBrRecov = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r9, '-Action', 'check', '-LedgerPath', $brLp)
    # Advance pr-branch touching src/a/m.ts (U01) while updating only U02 -> U01 must catch unit_tree_hash stale
    [IO.File]::WriteAllText((Join-Path $r9 'src\a\m.ts'), "export const a = 3;`n", $utf8NoBom)
    & git -C $r9 add src/a/m.ts; & git -C $r9 commit -qm 'pr9-c3'
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r9, '-Action', 'update', '-LedgerPath', $brLp, '-UnitId', 'U02', '-Status', 'REVIEWED'))
    $psBrUnitStale = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r9, '-Action', 'check', '-LedgerPath', $brLp)
    # Delete pr-branch -> unresolvable target_ref must FAIL CLOSED
    & git -C $r9 checkout -q $base9
    & git -C $r9 branch -D 'pr-branch' -q
    $psBrMissing = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r9, '-Action', 'check', '-LedgerPath', $brLp)
    $shBrMissing = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r9Posix' --action check --ledger-path '$brLp'" } else { $psBrMissing }
    $ok9 = ($psBrInit.Code -eq 0) -and ($brTxt -match '(?m)^target_ref=pr-branch$') -and ($brTxt -match "(?m)^target_sha=$sha9_1$") -and
           ($psBrPass1.Code -eq 0) -and
           ($psBrMoved.Code -eq 2) -and ($psBrMoved.Text -match "LEDGER_STALE: target_ref 'pr-branch' moved \($sha9_1->$sha9_2\)") -and ($shBrMoved.Code -eq 2) -and ($shBrMoved.Text -ceq $psBrMoved.Text) -and
           ($psBrMetaStillStale.Code -eq 2) -and ($psBrMetaStillStale.Text -match "LEDGER_STALE: target_ref 'pr-branch' moved \($sha9_1->$sha9_2\)") -and ($shBrMetaStillStale.Code -eq 2) -and ($shBrMetaStillStale.Text -ceq $psBrMetaStillStale.Text) -and
           ($psBrRecov.Code -eq 0) -and ($psBrUnitStale.Code -eq 2) -and ($psBrUnitStale.Text -match 'LEDGER_STALE: unit U01 invalidated') -and
           ($psBrMissing.Code -eq 2) -and ($psBrMissing.Text -match "LEDGER_STALE: target_ref 'pr-branch' cannot be resolved") -and ($shBrMissing.Code -eq 2) -and ($shBrMissing.Text -ceq $psBrMissing.Text)
    if ($ok9) { Pass 'target-ref-branch-movement-invalidation' } else {
        FailCheck 'target-ref-branch-movement-invalidation' "moved=$($psBrMoved.Text) recov=$($psBrRecov.Text) uStale=$($psBrUnitStale.Text) miss=$($psBrMissing.Text)"
    }

    # --- 10. default-bounded-xxl-budget-and-overrides ---
    $r10 = Join-Path $sandbox 'xxl-budget-repo'
    $r10Posix = $r10 -replace '\\', '/'
    Init-Repo $r10
    $base10 = (& git -C $r10 rev-parse HEAD).Trim()
    New-Item -ItemType Directory -Path (Join-Path $r10 'docs') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $r10 'docs\d001.md'), "Small doc`n", $utf8NoBom)
    $psXsDef = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r10, '-Action', 'init', '-LedgerPath', '.b3/ship/xs-def.md', '-BaseSha', $base10)
    $xsDefTxt = [IO.File]::ReadAllText((Join-Path $r10 '.b3\ship\xs-def.md'))
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r10, '-Action', 'update', '-LedgerPath', '.b3/ship/xs-def.md', '-UnitId', 'U01', '-Status', 'REVIEWED', '-PassesUsed', '6'))
    $psXsExh = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r10, '-Action', 'check', '-LedgerPath', '.b3/ship/xs-def.md')
    # Expand to 101 docs -> XXL (single unit U01), default max_passes=24
    2..101 | ForEach-Object {
        $n = '{0:D3}' -f $_
        [IO.File]::WriteAllText((Join-Path $r10 "docs\d${n}.md"), "Doc line`n", $utf8NoBom)
    }
    $psXxlDef = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r10, '-Action', 'init', '-LedgerPath', '.b3/ship/xxl-ps.md', '-BaseSha', $base10)
    $shXxlDef = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r10Posix' --action init --ledger-path '.b3/ship/xxl-sh.md' --base-sha '$base10'" } else { $psXxlDef }
    $xxlPsTxt = [IO.File]::ReadAllText((Join-Path $r10 '.b3\ship\xxl-ps.md'))
    $xxlShTxt = if ($hasBash) { [IO.File]::ReadAllText((Join-Path $r10 '.b3\ship\xxl-sh.md')) } else { $xxlPsTxt }
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r10, '-Action', 'update', '-LedgerPath', '.b3/ship/xxl-ps.md', '-UnitId', 'U01', '-Status', 'REVIEWED', '-PassesUsed', '25'))
    $psXxlExh = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r10, '-Action', 'check', '-LedgerPath', '.b3/ship/xxl-ps.md')
    $shXxlExh = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r10Posix' --action check --ledger-path '.b3/ship/xxl-ps.md'" } else { $psXxlExh }
    # Override --max-passes 30 allows 25, rejects 31; --max-passes 0 rejected
    if ($hasBash) {
        [void](Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r10Posix' --action update --ledger-path '.b3/ship/xxl-ps.md' --max-passes 30")
    } else {
        [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r10, '-Action', 'update', '-LedgerPath', '.b3/ship/xxl-ps.md', '-MaxPasses', '30'))
    }
    $psXxlOvOk = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r10, '-Action', 'check', '-LedgerPath', '.b3/ship/xxl-ps.md')
    $shXxlOvOk = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r10Posix' --action check --ledger-path '.b3/ship/xxl-ps.md'" } else { $psXxlOvOk }
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r10, '-Action', 'update', '-LedgerPath', '.b3/ship/xxl-ps.md', '-PassesUsed', '31'))
    $psXxlOvExh = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r10, '-Action', 'check', '-LedgerPath', '.b3/ship/xxl-ps.md')
    $psZeroBad = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r10, '-Action', 'init', '-LedgerPath', '.b3/ship/xxl-zero.md', '-BaseSha', $base10, '-MaxPasses', '0')
    $shZeroBad = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r10Posix' --action init --ledger-path '.b3/ship/xxl-zero.md' --base-sha '$base10' --max-passes 0" } else { $psZeroBad }
    $psUpdZeroBad = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r10, '-Action', 'update', '-LedgerPath', '.b3/ship/xxl-ps.md', '-MaxPasses', '0')
    $ok10 = ($psXsDef.Code -eq 0) -and ($xsDefTxt -match '(?m)^max_passes=5$') -and ($psXsExh.Code -eq 2) -and ($psXsExh.Text -match 'budget exhausted \(passes=6/5\)') -and
            ($psXxlDef.Code -eq 0) -and ($shXxlDef.Code -eq 0) -and ($xxlPsTxt -match '(?m)^max_passes=24$') -and ($xxlShTxt -match '(?m)^max_passes=24$') -and
            ($psXxlExh.Code -eq 2) -and ($psXxlExh.Text -match 'budget exhausted \(passes=25/24\)') -and ($shXxlExh.Code -eq 2) -and ($shXxlExh.Text -ceq $psXxlExh.Text) -and
            ($psXxlOvOk.Code -eq 0) -and ($psXxlOvOk.Text -match 'LEDGER_GATE_PASS:') -and ($shXxlOvOk.Code -eq 0) -and ($shXxlOvOk.Text -ceq $psXxlOvOk.Text) -and
            ($psXxlOvExh.Code -eq 2) -and ($psXxlOvExh.Text -match 'budget exhausted \(passes=31/30\)') -and
            ($psZeroBad.Code -eq 1) -and ($shZeroBad.Code -eq 1) -and ($psUpdZeroBad.Code -eq 1)
    if ($ok10) { Pass 'default-bounded-xxl-budget-and-overrides' } else {
        FailCheck 'default-bounded-xxl-budget-and-overrides' "xsExh=$($psXsExh.Text) xxlInit=$($psXxlDef.Text) xxlExh=$($psXxlExh.Text) ovOk=(ps=$($psXxlOvOk.Text)|sh=$($shXxlOvOk.Text)) ovExh=$($psXxlOvExh.Text) zero=$($psZeroBad.Code)/$($shZeroBad.Code)/$($psUpdZeroBad.Code)"
    }

    # --- 11. r001-oversized-single-dir-partitioning ---
    $r11 = Join-Path $sandbox 'r001-30k-one-dir'
    $r11Posix = $r11 -replace '\\', '/'
    Init-Repo $r11
    $base11 = (& git -C $r11 rev-parse HEAD).Trim()
    # (a) 30k+ LOC inside ONE flat directory src/monolith (contracts + import-coupled features + paired test + multi-runtime pair)
    New-Item -ItemType Directory -Path (Join-Path $r11 'src\monolith') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $r11 'src\monolith\api.proto'), ("message Order { string id = 1; }`n" * 120), $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $r11 'src\monolith\alpha_gate.ts'), "import { runAuth } from './auth_core';`nexport const gate = () => runAuth();`n" + ("export const g = 1;`n" * 80), $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $r11 'src\monolith\auth_core.ts'), ("export function runAuth() { return true; }`n" * 3000), $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $r11 'src\monolith\alpha_gate.test.ts'), ("export const gateTest = true;`n" * 60), $utf8NoBom)
    foreach ($fIdx in 1..6) {
        $fn = 'feat{0:D2}' -f $fIdx
        [IO.File]::WriteAllText((Join-Path $r11 "src\monolith\${fn}_model.ts"), ("export interface ${fn}Dto { id: number; }`n" * 2200), $utf8NoBom)
        [IO.File]::WriteAllText((Join-Path $r11 "src\monolith\${fn}_service.ts"), "import type { ${fn}Dto } from './${fn}_model';`nexport const make_${fn} = (x: ${fn}Dto) => x;`n" + ("export const line_${fn} = 1;`n" * 2200), $utf8NoBom)
        [IO.File]::WriteAllText((Join-Path $r11 "src\monolith\${fn}.test.ts"), ("export const test_${fn} = true;`n" * 40), $utf8NoBom)
    }
    [IO.File]::WriteAllText((Join-Path $r11 'src\monolith\sync_tool.ps1'), ("# ps helper line`n" * 2600), $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $r11 'src\monolith\sync_tool.sh'), ("# sh helper line`n" * 2600), $utf8NoBom)
    & git -C $r11 add .; & git -C $r11 commit -qm '30k flat dir'
    $ps30k = Invoke-PsGuard @('review-inventory', '-RepoRoot', $r11, '-BaseSha', $base11, '-MaxConcurrency', '4')
    $sh30k = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-inventory --repo-root '$r11Posix' --base-sha '$base11' --max-concurrency 4" } else { $ps30k }
    $uLines30k = @($ps30k.Lines | Where-Object { $_ -like 'unit|*' })
    $allBounded30k = ($uLines30k.Count -ge 9)
    foreach ($ul in $uLines30k) {
        $cols = $ul -split '\|'
        $ufc = [int]$cols[3]; $ulc = [int]$cols[4]
        if ($ulc -gt 5000 -or ($ufc -gt 100 -and $ulc -gt 1000)) { $allBounded30k = $false }
    }
    # (b) Indivisible single file > 5000L must fail closed PARTITION_INCOMPLETE exit 2 (in both inventory and ledger init)
    [IO.File]::WriteAllText((Join-Path $r11 'src\monolith\giant.ts'), ("export const big = 1;`n" * 5100), $utf8NoBom)
    & git -C $r11 add .; & git -C $r11 commit -qm 'indivisible 5100L'
    $psGiantInv = Invoke-PsGuard @('review-inventory', '-RepoRoot', $r11, '-BaseSha', $base11)
    $shGiantInv = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-inventory --repo-root '$r11Posix' --base-sha '$base11'" } else { $psGiantInv }
    $psGiantLed = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r11, '-Action', 'init', '-LedgerPath', '.b3/ship/fail-giant.md', '-BaseSha', $base11)
    $shGiantLed = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r11Posix' --action init --ledger-path '.b3/ship/fail-giant-sh.md' --base-sha '$base11'" } else { $psGiantLed }
    # (c) Connected 2-file import graph > 5000L must fail closed PARTITION_INCOMPLETE (never split arbitrarily by LOC)
    Remove-Item -LiteralPath (Join-Path $r11 'src\monolith\giant.ts') -Force
    [IO.File]::WriteAllText((Join-Path $r11 'src\monolith\mono_a.ts'), "import { mb } from './mono_b';`nexport const ma = () => mb;`n" + ("export const aLine = 1;`n" * 3000), $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $r11 'src\monolith\mono_b.ts'), ("export const mb = 2;`n" * 3000), $utf8NoBom)
    & git -C $r11 add -A; & git -C $r11 commit -qm 'coupled 6k pair'
    $psCoup = Invoke-PsGuard @('review-inventory', '-RepoRoot', $r11, '-BaseSha', $base11)
    $shCoup = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-inventory --repo-root '$r11Posix' --base-sha '$base11'" } else { $psCoup }
    # (d) Contract-only oversized directory with single-quoted './x27_b' import must keep PS/Bash parity (fail PARTITION_INCOMPLETE)
    Remove-Item -LiteralPath (Join-Path $r11 'src\monolith\mono_a.ts'), (Join-Path $r11 'src\monolith\mono_b.ts') -Force
    New-Item -ItemType Directory -Path (Join-Path $r11 'src\contracts') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $r11 'src\contracts\x27_a.proto'), ("import './x27_b';`n" + ("message A { string id = 1; }`n" * 3000)), $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $r11 'src\contracts\x27_b.proto'), ("message B { string id = 1; }`n" * 3000), $utf8NoBom)
    & git -C $r11 add -A; & git -C $r11 commit -qm 'contract-only coupled'
    $psConCoup = Invoke-PsGuard @('review-inventory', '-RepoRoot', $r11, '-BaseSha', $base11)
    $shConCoup = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-inventory --repo-root '$r11Posix' --base-sha '$base11'" } else { $psConCoup }
    # (e) >100 files & >1000L triggers Boundary-1 deeper directory subdivision with exact parity
    $r11b = Join-Path $sandbox 'r001-110f-repo'
    $r11bPosix = $r11b -replace '\\', '/'
    Init-Repo $r11b
    $base11b = (& git -C $r11b rev-parse HEAD).Trim()
    foreach ($sd in @('sub1', 'sub2')) {
        New-Item -ItemType Directory -Path (Join-Path $r11b "src\bigmod\$sd") -Force | Out-Null
        1..55 | ForEach-Object {
            [IO.File]::WriteAllText((Join-Path $r11b "src\bigmod\${sd}\f${_}.ts"), ("export const v = ${_};`n" * 15), $utf8NoBom)
        }
    }
    & git -C $r11b add .; & git -C $r11b commit -qm '110 files deeper split'
    $ps110f = Invoke-PsGuard @('review-inventory', '-RepoRoot', $r11b, '-BaseSha', $base11b)
    $sh110f = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-inventory --repo-root '$r11bPosix' --base-sha '$base11b'" } else { $ps110f }
    $ok11 = ($ps30k.Code -eq 0) -and ($sh30k.Code -eq 0) -and ($sh30k.Text -ceq $ps30k.Text) -and $allBounded30k -and
            ($ps30k.Text -match 'size_class=XXL') -and ($ps30k.Text -match 'max_concurrency=4') -and
            ($ps30k.Text -match 'unit\|U\d+\|src/monolith/\(contracts\)\|') -and
            ($ps30k.Text -match 'src/monolith/alpha_gate\.test\.ts,src/monolith/alpha_gate\.ts,src/monolith/auth_core\.ts') -and
            ($ps30k.Text -match 'src/monolith/sync_tool\.ps1') -and ($ps30k.Text -match 'src/monolith/sync_tool\.sh') -and
            ($psGiantInv.Code -eq 2) -and ($shGiantInv.Code -eq 2) -and ($shGiantInv.Text -ceq $psGiantInv.Text) -and ($psGiantInv.Text -match '^PARTITION_INCOMPLETE:') -and
            ($psGiantLed.Code -eq 2) -and ($shGiantLed.Code -eq 2) -and ($shGiantLed.Text -ceq $psGiantLed.Text) -and ($psGiantLed.Text -match '^PARTITION_INCOMPLETE:') -and
            ($psCoup.Code -eq 2) -and ($shCoup.Code -eq 2) -and ($shCoup.Text -ceq $psCoup.Text) -and ($psCoup.Text -match '^PARTITION_INCOMPLETE:') -and
            ($psConCoup.Code -eq 2) -and ($shConCoup.Code -eq 2) -and ($shConCoup.Text -ceq $psConCoup.Text) -and ($psConCoup.Text -match '^PARTITION_INCOMPLETE:') -and
            ($ps110f.Code -eq 0) -and ($sh110f.Code -eq 0) -and ($sh110f.Text -ceq $ps110f.Text) -and
            ($ps110f.Text -match 'unit\|U01\|src/bigmod/sub1\|55\|825\|') -and ($ps110f.Text -match 'unit\|U02\|src/bigmod/sub2\|55\|825\|')
    if ($ok11) { Pass 'r001-oversized-single-dir-partitioning' } else {
        FailCheck 'r001-oversized-single-dir-partitioning' "30k=($($ps30k.Code)/$($sh30k.Code) eq=$($sh30k.Text -ceq $ps30k.Text) bounded=$allBounded30k cnt=$($uLines30k.Count)) giant=$($psGiantInv.Text) coup=$($psCoup.Text) concoup=$($psConCoup.Text) b1=$($ps110f.Code)/$($sh110f.Code)"
    }

    # --- 12. r001-l-xl-max-four-units ---
    $r12 = Join-Path $sandbox 'r001-l-xl-cap'
    $r12Posix = $r12 -replace '\\', '/'
    Init-Repo $r12
    $base12 = (& git -C $r12 rev-parse HEAD).Trim()
    New-Item -ItemType Directory -Path (Join-Path $r12 'tests\alpha') -Force | Out-Null
    foreach ($mod in @('src\alpha', 'src\beta', 'src\gamma', 'src\delta', 'apps\web', 'apps\admin', 'ops\scripts')) {
        New-Item -ItemType Directory -Path (Join-Path $r12 $mod) -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $r12 "$mod\mod.ts"), ("export const val = 1;`n" * 180), $utf8NoBom)
    }
    [IO.File]::WriteAllText((Join-Path $r12 'tests\alpha\alpha.test.ts'), ("export const tAlpha = true;`n" * 30), $utf8NoBom)
    & git -C $r12 add .; & git -C $r12 commit -qm '7-dir L PR'
    $psCapL = Invoke-PsGuard @('review-inventory', '-RepoRoot', $r12, '-BaseSha', $base12)
    $shCapL = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-inventory --repo-root '$r12Posix' --base-sha '$base12'" } else { $psCapL }
    $psCapInit = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r12, '-Action', 'init', '-LedgerPath', '.b3/ship/cap-ps.md', '-BaseSha', $base12)
    $shCapInit = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r12Posix' --action init --ledger-path '.b3/ship/cap-sh.md' --base-sha '$base12'" } else { $psCapInit }
    $capPsTxt = [IO.File]::ReadAllText((Join-Path $r12 '.b3\ship\cap-ps.md'))
    $capShTxt = if ($hasBash) { [IO.File]::ReadAllText((Join-Path $r12 '.b3\ship\cap-sh.md')) } else { $capPsTxt }
    $uc12Match = [regex]::Match($psCapL.Text, '(?m)^unit_count=(\d+)$')
    $uc12 = if ($uc12Match.Success) { [int]$uc12Match.Groups[1].Value } else { 0 }
    # Hand-crafted 5-unit L ledger must fail check
    $over5Path = Join-Path $r12 '.b3\ship\over5.md'
    $over5Txt = $capPsTxt -replace '(?m)^unit_count=.*$', 'unit_count=5'
    $over5Txt = $over5Txt + "| U05 | extra/m | 1 | 10 | LOW | none | none | PENDING | none | none | none | README.md |`n"
    [IO.File]::WriteAllText($over5Path, $over5Txt, $utf8NoBom)
    $psOver5Chk = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r12, '-Action', 'check', '-LedgerPath', '.b3/ship/over5.md')
    $shOver5Chk = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r12Posix' --action check --ledger-path '.b3/ship/over5.md'" } else { $psOver5Chk }
    # Post-init growth >5000L even after update REVIEWED must fail closed with LEDGER_INCOMPLETE: oversized unit
    $grownFile = ([regex]::Match($capPsTxt, '\| U01 \|[^\r\n]+\| ([^|,\s]+\.ts)').Groups[1].Value).Trim()
    if (-not $grownFile) { $grownFile = 'apps/admin/mod.ts' }
    [IO.File]::WriteAllText((Join-Path $r12 ($grownFile -replace '/', '\')), ("export const val = 1;`n" * 5100), $utf8NoBom)
    & git -C $r12 add .; & git -C $r12 commit -qm 'grow u01 >5000L'
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r12, '-Action', 'update', '-LedgerPath', '.b3/ship/cap-ps.md', '-UnitId', 'U01', '-Status', 'REVIEWED'))
    $psGrownChk = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r12, '-Action', 'check', '-LedgerPath', '.b3/ship/cap-ps.md')
    $shGrownChk = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r12Posix' --action check --ledger-path '.b3/ship/cap-ps.md'" } else { $psGrownChk }
    $ok12 = ($psCapL.Code -eq 0) -and ($shCapL.Code -eq 0) -and ($shCapL.Text -ceq $psCapL.Text) -and
            ($psCapL.Text -match 'size_class=L') -and ($uc12 -ge 2) -and ($uc12 -le 4) -and
            ($psCapL.Text -match 'tests/alpha/alpha\.test\.ts') -and
            ($psCapInit.Code -eq 0) -and ($shCapInit.Code -eq 0) -and ($capShTxt -ceq $capPsTxt) -and
            ($psOver5Chk.Code -eq 2) -and ($shOver5Chk.Code -eq 2) -and ($shOver5Chk.Text -ceq $psOver5Chk.Text) -and
            ($psOver5Chk.Text -match 'LEDGER_INCOMPLETE: L PR exceeds max 4 units \(5\)') -and
            ($psGrownChk.Code -eq 2) -and ($shGrownChk.Code -eq 2) -and ($shGrownChk.Text -ceq $psGrownChk.Text) -and
            ($psGrownChk.Text -match 'LEDGER_INCOMPLETE: oversized unit U01')
    if ($ok12) { Pass 'r001-l-xl-max-four-units' } else {
        FailCheck 'r001-l-xl-max-four-units' "uc=$uc12 eqInv=$($shCapL.Text -ceq $psCapL.Text) eqLed=$($capShTxt -ceq $capPsTxt) over5=$($psOver5Chk.Text) grown=$($psGrownChk.Text)"
    }

    # --- 13. r003-monotonic-pass-tamper-and-resume ---
    $r13 = Join-Path $sandbox 'r003-pass-repo'
    $r13Posix = $r13 -replace '\\', '/'
    Init-Repo $r13
    $base13 = (& git -C $r13 rev-parse HEAD).Trim()
    New-Item -ItemType Directory -Path (Join-Path $r13 'src\u1'), (Join-Path $r13 'src\u2'), (Join-Path $r13 'src\u3') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $r13 'src\u1\a.ts'), ("export const a = 1;`n" * 300), $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $r13 'src\u2\b.ts'), ("export const b = 2;`n" * 300), $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $r13 'src\u3\c.ts'), ("export const c = 3;`n" * 300), $utf8NoBom)
    & git -C $r13 add .; & git -C $r13 commit -qm '3-unit L'
    $lp13 = '.b3/ship/p13.md'
    $lp13Sh = '.b3/ship/p13-sh.md'
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r13, '-Action', 'init', '-LedgerPath', $lp13, '-BaseSha', $base13, '-MaxPasses', '3'))
    if ($hasBash) { [void](Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r13Posix' --action init --ledger-path '$lp13Sh' --base-sha '$base13' --max-passes 3") }
    # Monotonic auto-increment on unit REVIEWED + specialist add
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r13, '-Action', 'update', '-LedgerPath', $lp13, '-UnitId', 'U01', '-Status', 'REVIEWED'))
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r13, '-Action', 'update', '-LedgerPath', $lp13, '-UnitId', 'U02', '-Specialists', 'b3-architecture-reviewer'))
    if ($hasBash) {
        [void](Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r13Posix' --action update --ledger-path '$lp13Sh' --unit-id U01 --status REVIEWED")
        [void](Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r13Posix' --action update --ledger-path '$lp13Sh' --unit-id U02 --specialists b3-architecture-reviewer")
    }
    $psLed13After2 = [IO.File]::ReadAllText((Join-Path $r13 '.b3\ship\p13.md'))
    $shLed13After2 = if ($hasBash) { [IO.File]::ReadAllText((Join-Path $r13 '.b3\ship\p13-sh.md')) } else { $psLed13After2 }
    # Reject passes_used reduction/reset and consumed pass bypass in both PS and Bash
    $psReset = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r13, '-Action', 'update', '-LedgerPath', $lp13, '-PassesUsed', '1')
    $shReset = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r13Posix' --action update --ledger-path '$lp13Sh' --passes-used 1" } else { $psReset }
    $psBypass = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r13, '-Action', 'update', '-LedgerPath', $lp13, '-UnitId', 'U02', '-Status', 'REVIEWED', '-PassesUsed', '2')
    $shBypass = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r13Posix' --action update --ledger-path '$lp13Sh' --unit-id U02 --status REVIEWED --passes-used 2" } else { $psBypass }
    # Complete remaining units + cross_unit -> auto passes_used=5 > max_passes=3 -> EXHAUSTED
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r13, '-Action', 'update', '-LedgerPath', $lp13, '-UnitId', 'U02', '-Status', 'REVIEWED'))
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r13, '-Action', 'update', '-LedgerPath', $lp13, '-UnitId', 'U03', '-Status', 'REVIEWED'))
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r13, '-Action', 'update', '-LedgerPath', $lp13, '-CrossUnitStatus', 'REVIEWED'))
    $psForceOk = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r13, '-Action', 'update', '-LedgerPath', $lp13, '-BudgetStatus', 'OK')
    $shForceOk = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r13Posix' --action update --ledger-path '$lp13' --budget-status OK" } else { $psForceOk }
    $psExh13 = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r13, '-Action', 'check', '-LedgerPath', $lp13)
    $shExh13 = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r13Posix' --action check --ledger-path '$lp13'" } else { $psExh13 }
    # Tamper copy on disk: passes_used=5 -> passes_used=1 must fail LEDGER_CORRUPT (both check and update)
    $tamperRel = '.b3/ship/p13-tamper.md'
    $tamperTxt = ($psLed13After2 -replace '(?m)^passes_used=2$', 'passes_used=1')
    [IO.File]::WriteAllText((Join-Path $r13 '.b3\ship\p13-tamper.md'), $tamperTxt, $utf8NoBom)
    $psTamperChk = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r13, '-Action', 'check', '-LedgerPath', $tamperRel)
    $shTamperChk = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r13Posix' --action check --ledger-path '$tamperRel'" } else { $psTamperChk }
    $psTamperUpd = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r13, '-Action', 'update', '-LedgerPath', $tamperRel, '-UnitId', 'U03', '-Status', 'REVIEWED')
    $tamperRowTxt = ($psLed13After2 -replace '(?m)^pass\|1\|U01\|unit:REVIEWED\|1\|', 'pass|1|U01|unit:REVIEWED|0|')
    [IO.File]::WriteAllText((Join-Path $r13 '.b3\ship\p13-trow.md'), $tamperRowTxt, $utf8NoBom)
    $psTrowChk = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r13, '-Action', 'check', '-LedgerPath', '.b3/ship/p13-trow.md')
    $shTrowChk = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r13Posix' --action check --ledger-path '.b3/ship/p13-trow.md'" } else { $psTrowChk }
    $badNumTxt = ($psLed13After2 -replace '(\| U01 \|[^|]+\| )1 \|', '$1abc |')
    [IO.File]::WriteAllText((Join-Path $r13 '.b3\ship\p13-badnum.md'), $badNumTxt, $utf8NoBom)
    $psBadNum = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r13, '-Action', 'check', '-LedgerPath', '.b3/ship/p13-badnum.md')
    $shBadNum = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r13Posix' --action check --ledger-path '.b3/ship/p13-badnum.md'" } else { $psBadNum }
    # Resume with positive override -MaxPasses 8 -> PASS
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r13, '-Action', 'update', '-LedgerPath', $lp13, '-MaxPasses', '8'))
    $psResOk = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r13, '-Action', 'check', '-LedgerPath', $lp13)
    $shResOk = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r13Posix' --action check --ledger-path '$lp13'" } else { $psResOk }
    $ok13 = ($psLed13After2 -match '(?m)^passes_used=2$') -and ($shLed13After2 -ceq $psLed13After2) -and
            ($psLed13After2 -match '(?m)^pass\|1\|U01\|unit:REVIEWED\|1\|') -and ($psLed13After2 -match '(?m)^pass\|2\|U02\|specialist\|1\|') -and
            ($psReset.Code -eq 1) -and ($shReset.Code -eq 1) -and ($shReset.Text -ceq $psReset.Text) -and ($psReset.Text -match 'cannot be reduced or reset') -and
            ($psBypass.Code -eq 1) -and ($shBypass.Code -eq 1) -and ($shBypass.Text -ceq $psBypass.Text) -and ($psBypass.Text -match 'cannot bypass consumed passes') -and
            ($psForceOk.Code -eq 1) -and ($shForceOk.Code -eq 1) -and ($shForceOk.Text -ceq $psForceOk.Text) -and ($psForceOk.Text -match 'cannot set budget_status=OK') -and
            ($psExh13.Code -eq 2) -and ($shExh13.Code -eq 2) -and ($shExh13.Text -ceq $psExh13.Text) -and ($psExh13.Text -match 'budget exhausted \(passes=5/3\)') -and
            ($psTamperChk.Code -eq 1) -and ($shTamperChk.Code -eq 1) -and ($shTamperChk.Text -ceq $psTamperChk.Text) -and ($psTamperChk.Text -match '^LEDGER_CORRUPT:') -and
            ($psTamperUpd.Code -eq 1) -and ($psTamperUpd.Text -match '^LEDGER_CORRUPT:') -and
            ($psTrowChk.Code -eq 1) -and ($shTrowChk.Code -eq 1) -and ($shTrowChk.Text -ceq $psTrowChk.Text) -and ($psTrowChk.Text -match '^LEDGER_CORRUPT:') -and
            ($psBadNum.Code -eq 1) -and ($shBadNum.Code -eq 1) -and ($shBadNum.Text -ceq $psBadNum.Text) -and ($psBadNum.Text -match '^LEDGER_CORRUPT: invalid unit row numeric field') -and
            ($psResOk.Code -eq 0) -and ($shResOk.Code -eq 0) -and ($shResOk.Text -ceq $psResOk.Text) -and ($psResOk.Text -match '^LEDGER_GATE_PASS:')
    if ($ok13) { Pass 'r003-monotonic-pass-tamper-and-resume' } else {
        FailCheck 'r003-monotonic-pass-tamper-and-resume' "eqLed=$($shLed13After2 -ceq $psLed13After2) rst=$($psReset.Text) byp=$($psBypass.Text) fok=$($psForceOk.Text) exh=$($psExh13.Text) tmp=$($psTamperChk.Text) trow=$($psTrowChk.Text) badn=$($psBadNum.Text) res=$($psResOk.Text)"
    }

    # --- 14. r004-xxl-low-risk-docs-no-arch-specialist ---
    $r14 = Join-Path $sandbox 'r004-low-docs-xxl'
    $r14Posix = $r14 -replace '\\', '/'
    Init-Repo $r14
    $base14 = (& git -C $r14 rev-parse HEAD).Trim()
    foreach ($sec in @('part1', 'part2', 'part3', 'part4')) {
        $dDir = Join-Path $r14 "docs\$sec"
        New-Item -ItemType Directory -Path $dDir -Force | Out-Null
        1..26 | ForEach-Object {
            $dn = 'doc{0:D2}' -f $_
            [IO.File]::WriteAllText((Join-Path $dDir "${dn}.md"), ("Guide content line.`n" * 210), $utf8NoBom)
        }
    }
    & git -C $r14 add .; & git -C $r14 commit -qm '21k docs-only XXL'
    $psDocsXxl = Invoke-PsGuard @('review-inventory', '-RepoRoot', $r14, '-BaseSha', $base14)
    $shDocsXxl = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-inventory --repo-root '$r14Posix' --base-sha '$base14'" } else { $psDocsXxl }
    # Add an isolated non-contract LOW-risk utility file in a separate repo
    $r14b = Join-Path $sandbox 'r004-low-isolated'
    $r14bPosix = $r14b -replace '\\', '/'
    Init-Repo $r14b
    $base14b = (& git -C $r14b rev-parse HEAD).Trim()
    New-Item -ItemType Directory -Path (Join-Path $r14b 'src') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $r14b 'src\helper.ts'), "export const doubleIt = (x: number) => x * 2;`n", $utf8NoBom)
    & git -C $r14b add .; & git -C $r14b commit -qm 'isolated low util'
    $psIso = Invoke-PsGuard @('review-inventory', '-RepoRoot', $r14b, '-BaseSha', $base14b)
    $shIso = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-inventory --repo-root '$r14bPosix' --base-sha '$base14b'" } else { $psIso }
    $ok14 = ($psDocsXxl.Code -eq 0) -and ($shDocsXxl.Code -eq 0) -and ($shDocsXxl.Text -ceq $psDocsXxl.Text) -and
            ($psDocsXxl.Text -match '(?m)^size_class=XXL$') -and ($psDocsXxl.Text -match '(?m)^risk_level=LOW$') -and
            ($psDocsXxl.Text -match '(?m)^recommended_specialists=none$') -and
            ($psDocsXxl.Text -match '(?m)^l1_specialists=none$') -and
            ($psDocsXxl.Text -match '(?m)^l1_skip_rationale=low-risk-docs-only$') -and
            ($psIso.Code -eq 0) -and ($shIso.Code -eq 0) -and ($shIso.Text -ceq $psIso.Text) -and
            ($psIso.Text -match '(?m)^risk_level=LOW$') -and ($psIso.Text -match '(?m)^l1_specialists=none$') -and
            ($psIso.Text -match '(?m)^l1_skip_rationale=low-risk-isolated-no-contracts$')
    if ($ok14) { Pass 'r004-xxl-low-risk-docs-no-arch-specialist' } else {
        FailCheck 'r004-xxl-low-risk-docs-no-arch-specialist' "docs=($($psDocsXxl.Text)) iso=($($psIso.Text))"
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
