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
    New-Item -ItemType Directory -Path 'src\auth', 'tests\auth', 'src\contracts', 'src\render', 'docs' -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $r3 'src\auth\jwt.ts'), ("export function verifyToken(tok: string) { return tok !== ''; }`n" * 120), $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $r3 'tests\auth\jwt.test.ts'), ("export const authTest = true;`n" * 40), $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $r3 'src\contracts\order.ts'), ("export interface OrderDto { id: string; }`n" * 150), $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $r3 'src\render\scene.ts'), ("export function onTick() { useFrame(() => {}); }`n" * 150), $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $r3 'docs\big-spec.md'), ("Detailed guide content line.`n" * 12000), $utf8NoBom)
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
            ($ps25.Text -match 'split_recommended=true') -and ($ps25.Text -match 'max_concurrency=4') -and
            ($ps25.Text -match 'unit\|U\d+\|docs\|1\|12000\|LOW\|none\|') -and
            ($ps25.Text -match 'unit\|U\d+\|src/auth\|2\|160\|CRITICAL\|b3-security-reviewer\|.*\|src/auth/jwt\.ts,tests/auth/jwt\.test\.ts') -and
            ($ps25.Text -match 'unit\|U\d+\|src/contracts\|1\|150\|HIGH\|b3-architecture-reviewer\|') -and
            ($ps25.Text -match 'unit\|U\d+\|src/render\|1\|150\|HIGH\|b3-performance-reviewer\|') -and
            ($ps25.Text -match 'unit\|U\d+\|src/m01\|7\|840\|MEDIUM\|none\|general_code_change\|')
    $ucMatch = [regex]::Match($ps25.Text, '(?m)^unit_count=(\d+)$')
    $ucVal = if ($ucMatch.Success) { [int]$ucMatch.Groups[1].Value } else { 0 }
    $ok25 = $ok25 -and ($ucVal -ge 20)
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
    $psLInit = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r4, '-Action', 'init', '-LedgerPath', $lp, '-BaseSha', $base4, '-MaxConcurrency', '3', '-MaxPasses', '5')
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

    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r4, '-Action', 'update', '-LedgerPath', $lp, '-CrossUnitStatus', 'REVIEWED', '-PassesUsed', '3'))
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

    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $r4, '-Action', 'update', '-LedgerPath', $lp, '-PassesUsed', '5', '-BudgetStatus', 'EXHAUSTED'))
    $psBudget = Invoke-PsGuard @('review-ledger', '-RepoRoot', $r4, '-Action', 'check', '-LedgerPath', $lp)
    $shBudget = if ($hasBash) { Invoke-ShGuard "'$guardShPosix' review-ledger --repo-root '$r4Posix' --action check --ledger-path '$lp'" } else { $psBudget }

    $ok4 = ($psLInit.Code -eq 0) -and ($psLInit.Text -match 'LEDGER_INIT:.*size=L risk=CRITICAL units=4') -and
           ($chkPending.Code -eq 2) -and ($chkPending.Text -match 'LEDGER_INCOMPLETE: unit U01 status=PENDING') -and
           ($chkNoSpec.Code -eq 2) -and ($chkNoSpec.Text -match 'missing specialist') -and
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
           ($chkEscNeedSpec.Code -eq 2) -and ($chkEscNeedSpec.Text -match 'missing specialist') -and
           ($chkEscNeedRec.Code -eq 2) -and ($chkEscNeedRec.Text -match 'missing verify_receipt for CRITICAL unit U01') -and
           ($psEscPass.Code -eq 0) -and ($psEscPass.Text -match 'LEDGER_GATE_PASS:.*risk=CRITICAL') -and ($shEscPass.Code -eq 0) -and ($shEscPass.Text -ceq $psEscPass.Text) -and
           $shNormOk
    if ($ok6) { Pass 'ledger-cross-shell-targetref-and-risk-escalation' } else {
        FailCheck 'ledger-cross-shell-targetref-and-risk-escalation' "msys=$($shMissingMsys.Text) dot=$($shDotAbs.Text) trEq=$($trTxt -ceq $trShTxt) trChk=(ps=$($psTrChk.Text)|sh=$($shTrChk.Text)) stale=$($psEscStale.Text) needSp=$($chkEscNeedSpec.Text) needRec=$($chkEscNeedRec.Text) escPass=(ps=$($psEscPass.Text)|sh=$($shEscPass.Text)) norm=$shNormOk"
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
