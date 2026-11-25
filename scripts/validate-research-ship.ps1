# Behavioral checks for /b3-research-ship across PowerShell and Git Bash.
# Covers research evidence freshness, governance fail-closed rules, namespace/wave orchestration, PR/merge gates, and 4-host adapter compatibility.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate-research-ship.ps1
param(
    [switch]$AllowIncompleteBash
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'lib\global-test-helpers.ps1')
$guardShPosix = (To-PosixPath $root) + '/scripts/b3-guard.sh'

function Init-TestRepo([string]$DirPath) {
    Init-B3TestRepo -RepoPath $DirPath -DefaultBranch 'main' -UserEmail 'research-test@example.com' -UserName 'Research Test'
}

$sandbox = Join-Path $env:TEMP ('b3-research-ship-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox | Out-Null
$prevModelsPersonal = $env:B3_MODELS_PERSONAL
$prevPathEnv = $env:PATH
$prevMockGhDir = $env:B3_TEST_GH_DIR
$env:B3_MODELS_PERSONAL = Join-Path $sandbox 'personal-models.md'

$mockBinDir = Join-Path $sandbox 'mock-bin'
$mockDataDir = Join-Path $sandbox 'mock-data'
New-Item -ItemType Directory -Path $mockBinDir, $mockDataDir -Force | Out-Null
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$mockPsHelper = Join-Path $mockBinDir 'mock-gh.ps1'
[IO.File]::WriteAllText($mockPsHelper, @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ArgsIn)
$dir = $env:B3_TEST_GH_DIR
if (-not $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) { [Console]::Error.WriteLine('HTTP 500: mock dir missing'); exit 1 }
if (-not $ArgsIn -or $ArgsIn[0] -cne 'api') { [Console]::Error.WriteLine('unexpected gh subcommand'); exit 1 }
$slurp = $false
$endpoint = ''
for ($i = 1; $i -lt $ArgsIn.Count; $i++) {
    if ($ArgsIn[$i] -ceq '--paginate') { continue }
    elseif ($ArgsIn[$i] -ceq '--slurp') { $slurp = $true }
    else { $endpoint = $ArgsIn[$i] }
}
$clean = ($endpoint -split '\?')[0]
$key = (($clean -replace '%2[fF]', '__') -replace '/', '__')
$errFile = Join-Path $dir "$key.err"
$jsonFile = Join-Path $dir "$key.json"
if (Test-Path -LiteralPath $errFile -PathType Leaf) { [Console]::Error.Write([IO.File]::ReadAllText($errFile)); exit 1 }
if (Test-Path -LiteralPath $jsonFile -PathType Leaf) {
    $raw = [IO.File]::ReadAllText($jsonFile)
    if ($slurp) { Write-Output "[$raw]" } else { Write-Output $raw }
    exit 0
}
[Console]::Error.WriteLine("HTTP 404 Not Found: $clean")
exit 1
'@, $utf8NoBom)
[IO.File]::WriteAllText((Join-Path $mockBinDir 'gh.cmd'), "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0mock-gh.ps1`" %*`r`n", $utf8NoBom)
[IO.File]::WriteAllText((Join-Path $mockBinDir 'gh'), @'
#!/usr/bin/env bash
set -euo pipefail
dir="${B3_TEST_GH_DIR:-}"
[[ -n "$dir" && -d "$dir" ]] || { echo "HTTP 500: mock dir missing" >&2; exit 1; }
[[ "${1:-}" == "api" ]] || { echo "unexpected gh subcommand" >&2; exit 1; }
shift; slurp=false; endpoint=""
while [[ $# -gt 0 ]]; do
  case "$1" in --paginate) shift ;; --slurp) slurp=true; shift ;; *) endpoint="$1"; shift ;; esac
done
clean="${endpoint%%\?*}"
key="$(printf '%s' "$clean" | sed 's|%2[fF]|__|g; s|/|__|g')"
if [[ -f "${dir}/${key}.err" ]]; then cat "${dir}/${key}.err" >&2; exit 1; fi
if [[ -f "${dir}/${key}.json" ]]; then
  if $slurp; then printf '['; cat "${dir}/${key}.json"; printf ']\n'; else cat "${dir}/${key}.json"; fi
  exit 0
fi
echo "HTTP 404 Not Found: ${clean}" >&2; exit 1
'@, $utf8NoBom)

function Write-MockPreMergeFixtures([string]$Dir, [string]$Slug, [int]$PrNum, [string]$DefBr, [string]$DefSha, [string]$BaseRef, [string]$BaseSha, [string]$HeadRef, [string]$HeadSha, [string]$ChangedFile) {
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    $sk = $Slug -replace '/', '__'
    $bk = $BaseRef -replace '/', '__'
    $dk = $DefBr -replace '/', '__'
    [IO.File]::WriteAllText((Join-Path $Dir "repos__${sk}__pulls__${PrNum}.json"), (@{
        number = $PrNum; state = 'open'; draft = $false; merged = $false; merged_at = $null; merge_commit_sha = $null
        mergeable = $true; mergeable_state = 'clean'; user = @{ login = 'alice' }
        base = @{ ref = $BaseRef; sha = $BaseSha; repo = @{ full_name = $Slug; default_branch = $DefBr } }
        head = @{ ref = $HeadRef; sha = $HeadSha; repo = @{ full_name = $Slug } }
    } | ConvertTo-Json -Depth 6), $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $Dir "repos__${sk}__branches__${bk}.json"), (@{ name = $BaseRef; protected = $false; commit = @{ sha = $BaseSha } } | ConvertTo-Json -Depth 4), $utf8NoBom)
    if ($DefBr -cne $BaseRef) {
        [IO.File]::WriteAllText((Join-Path $Dir "repos__${sk}__branches__${dk}.json"), (@{ name = $DefBr; protected = $false; commit = @{ sha = $DefSha } } | ConvertTo-Json -Depth 4), $utf8NoBom)
    }
    [IO.File]::WriteAllText((Join-Path $Dir "repos__${sk}__rules__branches__${bk}.json"), '[]', $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $Dir "repos__${sk}__pulls__${PrNum}__files.json"), "[{`"filename`":`"$ChangedFile`",`"status`":`"modified`"}]", $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $Dir "repos__${sk}__pulls__${PrNum}__reviews.json"), "[{`"id`":1,`"user`":{`"login`":`"bob`",`"type`":`"User`"},`"author_association`":`"COLLABORATOR`",`"state`":`"APPROVED`",`"commit_id`":`"$HeadSha`"}]", $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $Dir "repos__${sk}__commits__${HeadSha}__check-runs.json"), "{`"total_count`":1,`"check_runs`":[{`"id`":1,`"name`":`"ci/test`",`"app`":{`"id`":15368},`"head_sha`":`"$HeadSha`",`"status`":`"completed`",`"conclusion`":`"success`"}]}", $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $Dir "repos__${sk}__commits__${HeadSha}__status.json"), "{`"sha`":`"$HeadSha`",`"state`":`"pending`",`"total_count`":0,`"statuses`":[]}", $utf8NoBom)
}

function Write-MockPostMergeFixtures([string]$Dir, [string]$Slug, [int]$PrNum, [string]$BaseRef, [string]$HeadSha, [string]$MergeSha, [string]$LiveSha) {
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    $sk = $Slug -replace '/', '__'
    $bk = $BaseRef -replace '/', '__'
    [IO.File]::WriteAllText((Join-Path $Dir "repos__${sk}__pulls__${PrNum}.json"), (@{
        number = $PrNum; state = 'closed'; merged = $true; merged_at = '2026-11-24T15:00:00Z'; merge_commit_sha = $MergeSha; commits = 1
        base = @{ ref = $BaseRef; sha = $LiveSha; repo = @{ full_name = $Slug; default_branch = 'main' } }
        head = @{ ref = 'feat/research-test'; sha = $HeadSha; repo = @{ full_name = $Slug } }
    } | ConvertTo-Json -Depth 6), $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $Dir "repos__${sk}__branches__${bk}.json"), (@{ name = $BaseRef; protected = $false; commit = @{ sha = $LiveSha } } | ConvertTo-Json -Depth 4), $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $Dir "repos__${sk}__compare__${MergeSha}...${LiveSha}.json"), '{"status":"identical","behind_by":0,"ahead_by":0}', $utf8NoBom)
}

try {
    # --- 1. research-evidence-freshness-and-containment (PS + Bash) ---
    $rEv = Join-Path $sandbox 'ev-repo'
    $rEvPosix = $rEv -replace '\\', '/'
    Init-TestRepo $rEv
    New-Item -ItemType Directory -Path (Join-Path $rEv 'sources') -Force | Out-Null
    Set-Content (Join-Path $rEv 'sources\primary.md') "# Primary Source`nClause A`n" -NoNewline
    Set-Content (Join-Path $rEv 'sources\secondary.md') "# Secondary Source`nClause B`n" -NoNewline
    Set-Content (Join-Path $sandbox 'outside.txt') "outside`n"
    Push-Location $rEv
    & git add .; & git commit -qm 'init sources'
    Pop-Location

    $mRel = '.b3/research-ship/runs/r1/evidence/sources.manifest'
    $wRes = Invoke-PsGuard @('evidence-check', '-RepoRoot', $rEv, '-WriteManifest', '-ManifestPath', $mRel, '-SourcePaths', 'sources/primary.md,sources/secondary.md')
    $fPs = Invoke-PsGuard @('evidence-check', '-RepoRoot', $rEv, '-ManifestPath', $mRel, '-SourcePaths', 'sources/primary.md,sources/secondary.md')
    $uncPs = Invoke-PsGuard @('evidence-check', '-RepoRoot', $rEv, '-ManifestPath', $mRel, '-SourcePaths', 'sources/primary.md,sources/extra.md')
    $casePs = Invoke-PsGuard @('evidence-check', '-RepoRoot', $rEv, '-ManifestPath', $mRel, '-SourcePaths', 'Sources/Primary.md')
    $travPs = Invoke-PsGuard @('evidence-check', '-RepoRoot', $rEv, '-ManifestPath', $mRel, '-SourcePaths', '../outside.txt')

    # Junction containment test (outside repo)
    $outEvDir = Join-Path $sandbox 'outside-ev'
    New-Item -ItemType Directory -Path $outEvDir -Force | Out-Null
    Set-Content (Join-Path $outEvDir 'secret.md') "secret`n"
    New-Item -ItemType Junction -Path (Join-Path $rEv 'linked-out') -Target $outEvDir | Out-Null
    $juncPs = Invoke-PsGuard @('evidence-check', '-RepoRoot', $rEv, '-WriteManifest', '-ManifestPath', 'linked-out/esc.manifest', '-SourcePaths', 'sources/primary.md')

    Add-Content (Join-Path $rEv 'sources\primary.md') "Edited clause`n"
    $stPs = Invoke-PsGuard @('evidence-check', '-RepoRoot', $rEv, '-ManifestPath', $mRel)

    Remove-Item (Join-Path $rEv 'sources\secondary.md') -Force
    $missPs = Invoke-PsGuard @('evidence-check', '-RepoRoot', $rEv, '-ManifestPath', $mRel)

    $evShOk = $true
    if ($script:HasBash) {
        Set-Content (Join-Path $rEv 'sources\secondary.md') "# Secondary Source`nClause B`n" -NoNewline
        $wSh = Invoke-ShCmd "'$guardShPosix' evidence-check --repo-root '$rEvPosix' --write-manifest --manifest-path '.b3/research-ship/runs/r1/evidence/sources-sh.manifest' --source-paths 'sources/primary.md,sources/secondary.md'"
        $fSh = Invoke-ShCmd "'$guardShPosix' evidence-check --repo-root '$rEvPosix' --manifest-path '.b3/research-ship/runs/r1/evidence/sources-sh.manifest' --source-paths 'sources/primary.md,sources/secondary.md'"
        $uncSh = Invoke-ShCmd "'$guardShPosix' evidence-check --repo-root '$rEvPosix' --manifest-path '.b3/research-ship/runs/r1/evidence/sources-sh.manifest' --source-paths 'sources/primary.md,sources/extra.md'"
        $caseSh = Invoke-ShCmd "'$guardShPosix' evidence-check --repo-root '$rEvPosix' --manifest-path '.b3/research-ship/runs/r1/evidence/sources-sh.manifest' --source-paths 'Sources/Primary.md'"
        $travSh = Invoke-ShCmd "'$guardShPosix' evidence-check --repo-root '$rEvPosix' --manifest-path '../escape.manifest'"
        $juncSh = Invoke-ShCmd "'$guardShPosix' evidence-check --repo-root '$rEvPosix' --write-manifest --manifest-path 'linked-out/esc-sh.manifest' --source-paths 'sources/primary.md'"
        Add-Content (Join-Path $rEv 'sources\secondary.md') "drift`n"
        $stSh = Invoke-ShCmd "'$guardShPosix' evidence-check --repo-root '$rEvPosix' --manifest-path '.b3/research-ship/runs/r1/evidence/sources-sh.manifest'"
        Remove-Item (Join-Path $rEv 'sources\secondary.md') -Force
        $missSh = Invoke-ShCmd "'$guardShPosix' evidence-check --repo-root '$rEvPosix' --manifest-path '.b3/research-ship/runs/r1/evidence/sources-sh.manifest'"
        $evShOk = ($wSh.Code -eq 0 -and $wSh.Text -match 'EVIDENCE_WRITTEN') -and
                  ($fSh.Code -eq 0 -and $fSh.Text -match 'EVIDENCE_FRESH') -and
                  ($uncSh.Code -eq 1 -and $uncSh.Text -match 'uncovered') -and
                  ($caseSh.Code -eq 1 -and $caseSh.Text -match 'uncovered') -and
                  ($travSh.Code -eq 1 -and $travSh.Text -match 'EVIDENCE_MISSING') -and
                  ($juncSh.Code -eq 1 -and $juncSh.Text -match 'invalid') -and
                  ($stSh.Code -eq 2 -and $stSh.Text -match 'EVIDENCE_STALE') -and
                  ($missSh.Code -eq 1 -and $missSh.Text -match 'EVIDENCE_MISSING')
    }
    if ($wRes.Code -eq 0 -and ($fPs.Code -eq 0 -and $fPs.Text -match 'EVIDENCE_FRESH') -and
        ($uncPs.Code -eq 1 -and $uncPs.Text -match 'uncovered') -and
        ($casePs.Code -eq 1 -and $casePs.Text -match 'uncovered') -and
        ($travPs.Code -eq 1 -and $travPs.Text -match 'invalid path') -and
        ($juncPs.Code -eq 1 -and $juncPs.Text -match 'invalid') -and
        ($stPs.Code -eq 2 -and $stPs.Text -match 'EVIDENCE_STALE') -and
        ($missPs.Code -eq 1 -and $missPs.Text -match 'EVIDENCE_MISSING') -and $evShOk) {
        Pass 'research-evidence-freshness'
    } else {
        FailCheck 'research-evidence-freshness' "w=$($wRes.Code) f=$($fPs.Code) unc=$($uncPs.Code) case=$($casePs.Code) trav=$($travPs.Code) junc=$($juncPs.Code) st=$($stPs.Code) miss=$($missPs.Code) sh=$evShOk"
    }

    # --- 2. governance-and-merge-policy-gates (PS + Bash) ---
    $rGov = Join-Path $sandbox 'gov-repo'
    $rGovPosix = $rGov -replace '\\', '/'
    Init-TestRepo $rGov
    New-Item -ItemType Directory -Path (Join-Path $rGov '.b3') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $rGov 'docs') -Force | Out-Null
    Set-Content (Join-Path $rGov 'docs\notes.md') "# Notes`n"
    Push-Location $rGov
    & git add .; & git commit -qm 'base'
    $baseMainSha = (& git rev-parse HEAD).Trim()
    & git checkout -qb feat/research-test
    Set-Content (Join-Path $rGov 'docs\notes.md') "# Updated Notes`n"
    & git add .; & git commit -qm 'research commit'
    $featSha = (& git rev-parse HEAD).Trim()
    & git checkout -qb unmerged-side $baseMainSha
    Set-Content (Join-Path $rGov 'docs\side.md') "# Side`n"
    & git add .; & git commit -qm 'side commit'
    $sideSha = (& git rev-parse HEAD).Trim()
    & git checkout -q main
    Pop-Location

    # Default (no policy file) -> PR_READY (exit 2)
    $noPol = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS', '-BlockingFindings', '0', '-GovernanceStatus', 'CLEAR')

    # Protected-path policy with auto_merge disabled
    Set-Content (Join-Path $rGov '.b3\research-policy.json') (@{
        auto_merge = 'disabled'
        protected_paths = @('releases/', 'docs/authority/')
        allow_protected_paths = $false
        require_ci = $true
        require_review = $true
    } | ConvertTo-Json)

    $missOwner = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS', '-GovernanceStatus', 'MISSING_OWNER_DECISION')
    $withheld = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS', '-GovernanceStatus', 'WITHHELD_PROMOTION')
    $badDigest = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS', '-GovernanceStatus', 'INVALID_EDITORIAL_REVIEW')
    $unauthRev = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS', '-GovernanceStatus', 'UNAUTHORIZED_REVIEWER')
    $protHit = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS', '-ChangedPaths', 'docs/notes.md,releases/v3.json')
    $resOnlyPr = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS', '-ChangedPaths', 'docs/notes.md')
    $failCi = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PrState', 'OPEN', '-CiStatus', 'FAIL', '-ReviewStatus', 'PASS')
    $blkFind = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS', '-BlockingFindings', '2')

    # Explicit authorized policy (uncommitted in $rGov used for pre-auth path checks; clean base-bound repo $rAuth for MERGE_AUTHORIZED)
    Set-Content (Join-Path $rGov '.b3\auth-policy.json') (@{
        auto_merge = 'authorized'
        protected_paths = @('releases/')
        allow_protected_paths = $false
        require_ci = $true
        require_review = $true
    } | ConvertTo-Json)
    $authProtFail = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PolicyPath', '.b3/auth-policy.json', '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS', '-ChangedPaths', 'releases/v3.json')
    $authDotFail = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PolicyPath', '.b3/auth-policy.json', '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS', '-ChangedPaths', '.')
    $omitChangedFail = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PolicyPath', '.b3/research-policy.json', '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS')

    # Clean base-bound authorized repo with committed policy + PR commit + verified INDEPENDENT ledger + trusted GitHub mock
    $rAuth = Join-Path $sandbox 'auth-ok-repo'
    $rAuthPosix = To-PosixPath $rAuth
    Init-TestRepo $rAuth
    New-Item -ItemType Directory -Path (Join-Path $rAuth '.b3'), (Join-Path $rAuth 'docs') -Force | Out-Null
    Set-Content (Join-Path $rAuth '.b3\research-policy.json') (@{
        auto_merge = 'authorized'
        protected_paths = @('releases/')
        allow_protected_paths = $false
        require_ci = $true
        require_review = $true
    } | ConvertTo-Json)
    Set-Content (Join-Path $rAuth 'docs\notes.md') "# Base Notes`n"
    Push-Location $rAuth
    & git remote add origin 'https://github.com/octo/rs-auth.git'
    & git add .; & git commit -qm 'base with auth policy'
    $authBaseSha = (& git rev-parse HEAD).Trim()
    & git checkout -qb feat/auth-pr
    Set-Content (Join-Path $rAuth 'docs\notes.md') "# Updated Authorized Notes`n"
    & git add .; & git commit -qm 'pr notes change'
    $authHeadSha = (& git rev-parse HEAD).Trim()
    Pop-Location
    $authLed = '.b3/research-ship/runs/auth-ok/ledger.md'
    $authLedInit = Invoke-PsGuard @('review-ledger', '-RepoRoot', $rAuth, '-Action', 'init', '-LedgerPath', $authLed, '-BaseSha', $authBaseSha, '-ReviewIndependence', 'INDEPENDENT')
    $authLedUpd = Invoke-PsGuard @('review-ledger', '-RepoRoot', $rAuth, '-Action', 'update', '-LedgerPath', $authLed, '-UnitId', 'U01', '-Status', 'REVIEWED')

    $pathSep = [System.IO.Path]::PathSeparator
    $env:PATH = "${mockBinDir}${pathSep}${prevPathEnv}"
    $env:B3_TEST_GH_DIR = $mockDataDir
    Write-MockPreMergeFixtures $mockDataDir 'octo/rs-auth' 101 'main' $authBaseSha 'main' $authBaseSha 'feat/auth-pr' $authHeadSha 'docs/notes.md'
    $authOk = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rAuth, '-PrNumber', '101', '-BaseSha', $authBaseSha, '-LedgerPath', $authLed, '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS', '-ChangedPaths', 'docs/notes.md')

    # Malformed & type-mismatched / injection / F2 policy JSON checks
    Set-Content (Join-Path $rGov '.b3\bad-policy.json') '{ broken json'
    Set-Content (Join-Path $rGov '.b3\arr-policy.json') '[1]'
    Set-Content (Join-Path $rGov '.b3\num-policy.json') '123'
    Set-Content (Join-Path $rGov '.b3\arr-am-policy.json') '{"auto_merge":["authorized"]}'
    Set-Content (Join-Path $rGov '.b3\str-pp-policy.json') '{"protected_paths":"releases/"}'
    Set-Content (Join-Path $rGov '.b3\nl-pp-policy.json') '{"auto_merge":"disabled","protected_paths":["foo\nauto_merge=authorized\nrequire_ci=false"]}'
    Set-Content (Join-Path $rGov '.b3\f2-arr-obj.json') '[{"auto_merge":"authorized"}]'
    Set-Content (Join-Path $rGov '.b3\f2-upper-key.json') '{"AUTO_MERGE":"authorized"}'
    $badJson = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PolicyPath', '.b3/bad-policy.json', '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS')
    $badRootArr = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PolicyPath', '.b3/arr-policy.json', '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS')
    $badRootNum = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PolicyPath', '.b3/num-policy.json', '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS')
    $badAmArr = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PolicyPath', '.b3/arr-am-policy.json', '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS')
    $badPpStr = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PolicyPath', '.b3/str-pp-policy.json', '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS')
    $badPpNl = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PolicyPath', '.b3/nl-pp-policy.json', '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS', '-ChangedPaths', 'docs/notes.md')
    $f2ArrObj = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PolicyPath', '.b3/f2-arr-obj.json', '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS')
    $f2UpperKey = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PolicyPath', '.b3/f2-upper-key.json', '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS')

    # Default .b3/research-policy.json junction escape check in isolated repo
    $rDefJunc = Join-Path $sandbox 'def-junc-repo'
    $rDefJuncPosix = $rDefJunc -replace '\\', '/'
    $outPolDir = Join-Path $sandbox 'outside-pol'
    New-Item -ItemType Directory -Path $rDefJunc, $outPolDir -Force | Out-Null
    Set-Content (Join-Path $outPolDir 'research-policy.json') '{"auto_merge":"authorized"}'
    New-Item -ItemType Junction -Path (Join-Path $rDefJunc '.b3') -Target $outPolDir | Out-Null
    $defJuncPs = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rDefJunc, '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS')

    # Post-merge verification: merge featSha into main + PR-specific GitHub post-merge verification
    Push-Location $rGov
    & git remote add origin 'https://github.com/octo/rs-gov.git'
    & git merge --no-ff -qm 'merge feat' $featSha | Out-Null
    $govMergeSha = (& git rev-parse HEAD).Trim()
    Pop-Location
    Write-MockPostMergeFixtures $mockDataDir 'octo/rs-gov' 201 'main' $featSha $govMergeSha $govMergeSha
    $postOk = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PostMerge', '-PrNumber', '201', '-PrState', 'MERGED', '-MergedSha', $govMergeSha, '-MainRef', 'main')
    $postFalse = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PostMerge', '-PrNumber', '201', '-PrState', 'MERGED', '-MergedSha', $sideSha, '-MainRef', 'main')
    $postOpen = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PostMerge', '-PrNumber', '201', '-PrState', 'OPEN', '-MergedSha', $govMergeSha, '-MainRef', 'main')
    $postNoMain = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PostMerge', '-PrNumber', '201', '-PrState', 'MERGED', '-MergedSha', $govMergeSha)
    $postHeadRef = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PostMerge', '-PrNumber', '201', '-PrState', 'MERGED', '-MergedSha', $govMergeSha, '-MainRef', 'HEAD')
    $postHeadTilde = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PostMerge', '-PrNumber', '201', '-PrState', 'MERGED', '-MergedSha', $govMergeSha, '-MainRef', 'HEAD~0')
    $postNoPr = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PostMerge', '-PrState', 'MERGED', '-MergedSha', $govMergeSha, '-MainRef', 'main')

    $govShOk = $true
    if ($script:HasBash) {
        $shDisabled = Invoke-ShGuard @('merge-policy-check', '--repo-root', $rGovPosix, '--pr-state', 'OPEN', '--ci-status', 'PASS', '--review-status', 'PASS', '--changed-paths', 'docs/notes.md')
        $shWithheld = Invoke-ShGuard @('merge-policy-check', '--repo-root', $rGovPosix, '--pr-state', 'OPEN', '--ci-status', 'PASS', '--review-status', 'PASS', '--governance-status', 'WITHHELD_PROMOTION')
        $shProt = Invoke-ShGuard @('merge-policy-check', '--repo-root', $rGovPosix, '--policy-path', '.b3/auth-policy.json', '--pr-state', 'OPEN', '--ci-status', 'PASS', '--review-status', 'PASS', '--changed-paths', 'releases/v3.json')
        $shDot = Invoke-ShGuard @('merge-policy-check', '--repo-root', $rGovPosix, '--policy-path', '.b3/auth-policy.json', '--pr-state', 'OPEN', '--ci-status', 'PASS', '--review-status', 'PASS', '--changed-paths', '.')
        $shOctalBlk = Invoke-ShGuard @('merge-policy-check', '--repo-root', $rGovPosix, '--pr-state', 'OPEN', '--ci-status', 'PASS', '--review-status', 'PASS', '--blocking-findings', '08')
        $shOmitChanged = Invoke-ShGuard @('merge-policy-check', '--repo-root', $rGovPosix, '--policy-path', '.b3/research-policy.json', '--pr-state', 'OPEN', '--ci-status', 'PASS', '--review-status', 'PASS')
        $shAuth = Invoke-ShGuard @('merge-policy-check', '--repo-root', $rAuthPosix, '--pr-number', '101', '--base-sha', $authBaseSha, '--ledger-path', $authLed, '--pr-state', 'OPEN', '--ci-status', 'PASS', '--review-status', 'PASS', '--changed-paths', 'docs/notes.md')
        $shBadJson = Invoke-ShGuard @('merge-policy-check', '--repo-root', $rGovPosix, '--policy-path', '.b3/bad-policy.json', '--pr-state', 'OPEN', '--ci-status', 'PASS', '--review-status', 'PASS')
        $shBadNl = Invoke-ShGuard @('merge-policy-check', '--repo-root', $rGovPosix, '--policy-path', '.b3/nl-pp-policy.json', '--pr-state', 'OPEN', '--ci-status', 'PASS', '--review-status', 'PASS', '--changed-paths', 'docs/notes.md')
        $shF2ArrObj = Invoke-ShGuard @('merge-policy-check', '--repo-root', $rGovPosix, '--policy-path', '.b3/f2-arr-obj.json', '--pr-state', 'OPEN', '--ci-status', 'PASS', '--review-status', 'PASS')
        $shF2Upper = Invoke-ShGuard @('merge-policy-check', '--repo-root', $rGovPosix, '--policy-path', '.b3/f2-upper-key.json', '--pr-state', 'OPEN', '--ci-status', 'PASS', '--review-status', 'PASS')
        $shDefJunc = Invoke-ShGuard @('merge-policy-check', '--repo-root', $rDefJuncPosix, '--pr-state', 'OPEN', '--ci-status', 'PASS', '--review-status', 'PASS')
        $shPostOk = Invoke-ShGuard @('merge-policy-check', '--repo-root', $rGovPosix, '--post-merge', '--pr-number', '201', '--pr-state', 'MERGED', '--merged-sha', $govMergeSha, '--main-ref', 'main')
        $shPostBad = Invoke-ShGuard @('merge-policy-check', '--repo-root', $rGovPosix, '--post-merge', '--pr-number', '201', '--pr-state', 'MERGED', '--merged-sha', $sideSha, '--main-ref', 'main')
        $shPostNoMain = Invoke-ShGuard @('merge-policy-check', '--repo-root', $rGovPosix, '--post-merge', '--pr-number', '201', '--pr-state', 'MERGED', '--merged-sha', $govMergeSha)
        $shPostHead = Invoke-ShGuard @('merge-policy-check', '--repo-root', $rGovPosix, '--post-merge', '--pr-number', '201', '--pr-state', 'MERGED', '--merged-sha', $govMergeSha, '--main-ref', 'HEAD')
        $shPostTilde = Invoke-ShGuard @('merge-policy-check', '--repo-root', $rGovPosix, '--post-merge', '--pr-number', '201', '--pr-state', 'MERGED', '--merged-sha', $govMergeSha, '--main-ref', 'HEAD~0')
        $shPostNoPr = Invoke-ShGuard @('merge-policy-check', '--repo-root', $rGovPosix, '--post-merge', '--pr-state', 'MERGED', '--merged-sha', $govMergeSha, '--main-ref', 'main')
        $govShOk = ($shDisabled.Code -eq 2 -and $shDisabled.Text -match 'PR_READY: auto_merge=disabled') -and
                   ($shWithheld.Code -eq 1 -and $shWithheld.Text -match 'WITHHELD_PROMOTION') -and
                   ($shProt.Code -eq 1 -and $shProt.Text -match 'protected_paths=releases/v3\.json') -and
                   ($shDot.Code -eq 1 -and $shDot.Text -match 'protected_paths=\.') -and
                   ($shOctalBlk.Code -eq 1 -and $shOctalBlk.Text -match 'blocking_findings=8') -and
                   ($shOmitChanged.Code -eq 1 -and $shOmitChanged.Text -match 'missing_changed_paths') -and
                   ($shAuth.Code -eq 0 -and $shAuth.Text -match 'MERGE_AUTHORIZED' -and $shAuth.Text -ceq $authOk.Text) -and
                   ($shBadJson.Code -eq 1 -and $shBadJson.Text -match 'invalid_policy_json') -and
                   ($shBadNl.Code -eq 1 -and $shBadNl.Text -match 'invalid_policy_json') -and
                   ($shF2ArrObj.Code -eq 1 -and $shF2ArrObj.Text -match 'invalid_policy_json' -and $shF2ArrObj.Text -notmatch 'MERGE_AUTHORIZED') -and
                   ($shF2Upper.Code -eq 2 -and $shF2Upper.Text -match 'PR_READY: auto_merge=disabled' -and $shF2Upper.Text -notmatch 'MERGE_AUTHORIZED') -and
                   ($shDefJunc.Code -eq 1 -and $shDefJunc.Text -match 'invalid_policy_path') -and
                   ($shPostOk.Code -eq 0 -and $shPostOk.Text -match 'POST_MERGE_VERIFIED' -and $shPostOk.Text -match 'pr_status=PR_MERGED' -and $shPostOk.Text -match 'deployed=NOT_VERIFIED' -and $shPostOk.Text -ceq $postOk.Text) -and
                   ($shPostBad.Code -eq 1 -and $shPostBad.Text -match 'POST_MERGE_FAILED') -and
                   ($shPostNoMain.Code -eq 1 -and $shPostNoMain.Text -match 'POST_MERGE_FAILED: missing_main_ref') -and
                   ($shPostHead.Code -eq 1 -and $shPostHead.Text -match 'POST_MERGE_FAILED: invalid_main_ref') -and
                   ($shPostTilde.Code -eq 1 -and $shPostTilde.Text -match 'POST_MERGE_FAILED: invalid_main_ref') -and
                   ($shPostNoPr.Code -eq 1 -and $shPostNoPr.Text -match 'POST_MERGE_FAILED: missing_pr_number')
    }

    if (($noPol.Code -eq 2 -and $noPol.Text -match 'PR_READY') -and
        ($missOwner.Code -eq 1 -and $missOwner.Text -match 'MISSING_OWNER_DECISION') -and
        ($withheld.Code -eq 1 -and $withheld.Text -match 'WITHHELD_PROMOTION') -and
        ($badDigest.Code -eq 1 -and $badDigest.Text -match 'INVALID_EDITORIAL_REVIEW') -and
        ($unauthRev.Code -eq 1 -and $unauthRev.Text -match 'UNAUTHORIZED_REVIEWER') -and
        ($protHit.Code -eq 1 -and $protHit.Text -match 'protected_paths=releases/v3\.json') -and
        ($resOnlyPr.Code -eq 2 -and $resOnlyPr.Text -match 'PR_READY') -and
        ($failCi.Code -eq 1 -and $failCi.Text -match 'ci_status=FAIL') -and
        ($blkFind.Code -eq 1 -and $blkFind.Text -match 'blocking_findings=2') -and
        ($authLedInit.Code -eq 0 -and $authLedUpd.Code -eq 0) -and
        ($authOk.Code -eq 0 -and $authOk.Text -match 'MERGE_AUTHORIZED') -and
        ($authProtFail.Code -eq 1 -and $authProtFail.Text -match 'protected_paths') -and
        ($authDotFail.Code -eq 1 -and $authDotFail.Text -match 'protected_paths=\.') -and
        ($omitChangedFail.Code -eq 1 -and $omitChangedFail.Text -match 'missing_changed_paths') -and
        ($badJson.Code -eq 1 -and $badJson.Text -match 'invalid_policy_json') -and
        ($badRootArr.Code -eq 1 -and $badRootArr.Text -match 'invalid_policy_json') -and
        ($badRootNum.Code -eq 1 -and $badRootNum.Text -match 'invalid_policy_json') -and
        ($badAmArr.Code -eq 1 -and $badAmArr.Text -match 'invalid_policy_json') -and
        ($badPpStr.Code -eq 1 -and $badPpStr.Text -match 'invalid_policy_json') -and
        ($badPpNl.Code -eq 1 -and $badPpNl.Text -match 'invalid_policy_json') -and
        ($f2ArrObj.Code -eq 1 -and $f2ArrObj.Text -match 'invalid_policy_json' -and $f2ArrObj.Text -notmatch 'MERGE_AUTHORIZED') -and
        ($f2UpperKey.Code -eq 2 -and $f2UpperKey.Text -match 'PR_READY: auto_merge=disabled' -and $f2UpperKey.Text -notmatch 'MERGE_AUTHORIZED') -and
        ($defJuncPs.Code -eq 1 -and $defJuncPs.Text -match 'invalid_policy_path') -and
        ($postOk.Code -eq 0 -and $postOk.Text -match 'POST_MERGE_VERIFIED' -and $postOk.Text -match 'pr_status=PR_MERGED' -and $postOk.Text -match 'runtime_served=NOT_VERIFIED' -and $postOk.Text -match 'deployed=NOT_VERIFIED') -and
        ($postFalse.Code -eq 1 -and $postFalse.Text -match 'POST_MERGE_FAILED') -and
        ($postOpen.Code -eq 1 -and $postOpen.Text -match 'POST_MERGE_FAILED') -and
        ($postNoMain.Code -eq 1 -and $postNoMain.Text -match 'POST_MERGE_FAILED: missing_main_ref') -and
        ($postHeadRef.Code -eq 1 -and $postHeadRef.Text -match 'POST_MERGE_FAILED: invalid_main_ref') -and
        ($postHeadTilde.Code -eq 1 -and $postHeadTilde.Text -match 'POST_MERGE_FAILED: invalid_main_ref') -and
        ($postNoPr.Code -eq 1 -and $postNoPr.Text -match 'POST_MERGE_FAILED: missing_pr_number') -and $govShOk) {
        Pass 'governance-and-merge-policy-gates'
    } else {
        FailCheck 'governance-and-merge-policy-gates' "noPol=$($noPol.Code) authOk=$($authOk.Code)/$($authOk.Text) omitChg=$($omitChangedFail.Code) f2=$($f2ArrObj.Code)/$($f2UpperKey.Code) postNeg=$($postNoMain.Code)/$($postHeadRef.Code)/$($postHeadTilde.Code)/$($postNoPr.Code) sh=$govShOk"
    }

    # --- 2b. c04-h04-h08-merge-policy-hardening (PS + Bash) ---
    # (a) Missing -PrNumber -> MERGE_BLOCKED: missing_pr_number; -BaseSha HEAD -> MERGE_BLOCKED: base_sha_equals_head
    $psNoPr = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rAuth, '-BaseSha', $authBaseSha, '-LedgerPath', $authLed, '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS', '-ChangedPaths', 'docs/notes.md')
    $shNoPr = if ($script:HasBash) { Invoke-ShGuard @('merge-policy-check', '--repo-root', $rAuthPosix, '--base-sha', $authBaseSha, '--ledger-path', $authLed, '--pr-state', 'OPEN', '--ci-status', 'PASS', '--review-status', 'PASS', '--changed-paths', 'docs/notes.md') } else { $psNoPr }
    $psBaseHead = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rAuth, '-PrNumber', '101', '-BaseSha', 'HEAD', '-LedgerPath', $authLed, '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS', '-ChangedPaths', 'docs/notes.md')
    $shBaseHead = if ($script:HasBash) { Invoke-ShGuard @('merge-policy-check', '--repo-root', $rAuthPosix, '--pr-number', '101', '--base-sha', 'HEAD', '--ledger-path', $authLed, '--pr-state', 'OPEN', '--ci-status', 'PASS', '--review-status', 'PASS', '--changed-paths', 'docs/notes.md') } else { $psBaseHead }

    # (b) Missing -LedgerPath, UNKNOWN default ledger, or SINGLE_AGENT_LIMIT ledger -> MERGE_BLOCKED
    $psNoLed = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rAuth, '-PrNumber', '101', '-BaseSha', $authBaseSha, '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS', '-ChangedPaths', 'docs/notes.md')
    $shNoLed = if ($script:HasBash) { Invoke-ShGuard @('merge-policy-check', '--repo-root', $rAuthPosix, '--pr-number', '101', '--base-sha', $authBaseSha, '--pr-state', 'OPEN', '--ci-status', 'PASS', '--review-status', 'PASS', '--changed-paths', 'docs/notes.md') } else { $psNoLed }
    $unkLed = '.b3/research-ship/runs/auth-unk/ledger.md'
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $rAuth, '-Action', 'init', '-LedgerPath', $unkLed, '-BaseSha', $authBaseSha))
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $rAuth, '-Action', 'update', '-LedgerPath', $unkLed, '-UnitId', 'U01', '-Status', 'REVIEWED'))
    $psUnkBlk = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rAuth, '-PrNumber', '101', '-BaseSha', $authBaseSha, '-LedgerPath', $unkLed, '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS', '-ChangedPaths', 'docs/notes.md')
    $shUnkBlk = if ($script:HasBash) { Invoke-ShGuard @('merge-policy-check', '--repo-root', $rAuthPosix, '--pr-number', '101', '--base-sha', $authBaseSha, '--ledger-path', $unkLed, '--pr-state', 'OPEN', '--ci-status', 'PASS', '--review-status', 'PASS', '--changed-paths', 'docs/notes.md') } else { $psUnkBlk }
    $salLed = '.b3/research-ship/runs/auth-sal/ledger.md'
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $rAuth, '-Action', 'init', '-LedgerPath', $salLed, '-BaseSha', $authBaseSha, '-ReviewIndependence', 'SINGLE_AGENT_LIMIT'))
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $rAuth, '-Action', 'update', '-LedgerPath', $salLed, '-UnitId', 'U01', '-Status', 'REVIEWED'))
    $psSalBlk = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rAuth, '-PrNumber', '101', '-BaseSha', $authBaseSha, '-LedgerPath', $salLed, '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS', '-ChangedPaths', 'docs/notes.md')
    $shSalBlk = if ($script:HasBash) { Invoke-ShGuard @('merge-policy-check', '--repo-root', $rAuthPosix, '--pr-number', '101', '--base-sha', $authBaseSha, '--ledger-path', $salLed, '--pr-state', 'OPEN', '--ci-status', 'PASS', '--review-status', 'PASS', '--changed-paths', 'docs/notes.md') } else { $psSalBlk }

    # (c) Dirty working tree outside .b3/ship/ & .b3/research-ship/ -> MERGE_BLOCKED: dirty_worktree
    Set-Content (Join-Path $rAuth 'dirty-scratch.txt') "uncommitted`n"
    $psDirty = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rAuth, '-PrNumber', '101', '-BaseSha', $authBaseSha, '-LedgerPath', $authLed, '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS', '-ChangedPaths', 'docs/notes.md')
    $shDirty = if ($script:HasBash) { Invoke-ShGuard @('merge-policy-check', '--repo-root', $rAuthPosix, '--pr-number', '101', '--base-sha', $authBaseSha, '--ledger-path', $authLed, '--pr-state', 'OPEN', '--ci-status', 'PASS', '--review-status', 'PASS', '--changed-paths', 'docs/notes.md') } else { $psDirty }
    Remove-Item -LiteralPath (Join-Path $rAuth 'dirty-scratch.txt') -Force

    # (d) Policy modified in PR (policy_modified_in_pr) & policy path substitution blocked (policy_path_override_not_allowed)
    $rPolMod = Join-Path $sandbox 'pol-mod-repo'
    $rPolModPosix = To-PosixPath $rPolMod
    Init-TestRepo $rPolMod
    New-Item -ItemType Directory -Path (Join-Path $rPolMod '.b3'), (Join-Path $rPolMod 'docs') -Force | Out-Null
    Set-Content (Join-Path $rPolMod '.b3\research-policy.json') (@{
        auto_merge = 'authorized'
        protected_paths = @('releases/')
        allow_protected_paths = $false
        require_ci = $true
        require_review = $true
    } | ConvertTo-Json)
    Set-Content (Join-Path $rPolMod 'docs\notes.md') "# Base`n"
    Push-Location $rPolMod
    & git remote add origin 'https://github.com/octo/rs-polmod.git'
    & git add .; & git commit -qm 'base'
    $pmBaseSha = (& git rev-parse HEAD).Trim()
    & git checkout -qb feat/pol-mod
    Set-Content (Join-Path $rPolMod '.b3\research-policy.json') (@{
        auto_merge = 'authorized'
        protected_paths = @()
        allow_protected_paths = $true
        require_ci = $true
        require_review = $true
    } | ConvertTo-Json)
    & git add .; & git commit -qm 'tamper policy'
    $pmHead1 = (& git rev-parse HEAD).Trim()
    Pop-Location
    Write-MockPreMergeFixtures $mockDataDir 'octo/rs-polmod' 102 'main' $pmBaseSha 'main' $pmBaseSha 'feat/pol-mod' $pmHead1 '.b3/research-policy.json'
    $psPolMod = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rPolMod, '-PrNumber', '102', '-BaseSha', $pmBaseSha, '-LedgerPath', $authLed, '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS', '-ChangedPaths', 'docs/notes.md')
    $shPolMod = if ($script:HasBash) { Invoke-ShGuard @('merge-policy-check', '--repo-root', $rPolModPosix, '--pr-number', '102', '--base-sha', $pmBaseSha, '--ledger-path', $authLed, '--pr-state', 'OPEN', '--ci-status', 'PASS', '--review-status', 'PASS', '--changed-paths', 'docs/notes.md') } else { $psPolMod }

    Push-Location $rPolMod
    & git checkout -qb feat/pol-not-in-base $pmBaseSha
    Set-Content (Join-Path $rPolMod '.b3\new-auth.json') (@{
        auto_merge = 'authorized'
        protected_paths = @('releases/')
        allow_protected_paths = $false
        require_ci = $true
        require_review = $true
    } | ConvertTo-Json)
    Set-Content (Join-Path $rPolMod 'docs\notes.md') "# PR`n"
    & git add .; & git commit -qm 'add custom policy'
    $pmHead2 = (& git rev-parse HEAD).Trim()
    Pop-Location
    Write-MockPreMergeFixtures $mockDataDir 'octo/rs-polmod' 103 'main' $pmBaseSha 'main' $pmBaseSha 'feat/pol-not-in-base' $pmHead2 '.b3/new-auth.json'
    $psPolNotBase = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rPolMod, '-PolicyPath', '.b3/new-auth.json', '-PrNumber', '103', '-BaseSha', $pmBaseSha, '-LedgerPath', $authLed, '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS', '-ChangedPaths', 'docs/notes.md')
    $shPolNotBase = if ($script:HasBash) { Invoke-ShGuard @('merge-policy-check', '--repo-root', $rPolModPosix, '--policy-path', '.b3/new-auth.json', '--pr-number', '103', '--base-sha', $pmBaseSha, '--ledger-path', $authLed, '--pr-state', 'OPEN', '--ci-status', 'PASS', '--review-status', 'PASS', '--changed-paths', 'docs/notes.md') } else { $psPolNotBase }

    # (e) H-04: traversal, dot segment, case mismatch, protected_paths ["./"], and git mv rename bypass
    $psH04Trav = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rAuth, '-PrNumber', '101', '-BaseSha', $authBaseSha, '-LedgerPath', $authLed, '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS', '-ChangedPaths', 'docs/../releases/v3.json')
    $shH04Trav = if ($script:HasBash) { Invoke-ShGuard @('merge-policy-check', '--repo-root', $rAuthPosix, '--pr-number', '101', '--base-sha', $authBaseSha, '--ledger-path', $authLed, '--pr-state', 'OPEN', '--ci-status', 'PASS', '--review-status', 'PASS', '--changed-paths', 'docs/../releases/v3.json') } else { $psH04Trav }
    $psH04DotSeg = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rAuth, '-PrNumber', '101', '-BaseSha', $authBaseSha, '-LedgerPath', $authLed, '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS', '-ChangedPaths', 'releases/./v3.json')
    $shH04DotSeg = if ($script:HasBash) { Invoke-ShGuard @('merge-policy-check', '--repo-root', $rAuthPosix, '--pr-number', '101', '--base-sha', $authBaseSha, '--ledger-path', $authLed, '--pr-state', 'OPEN', '--ci-status', 'PASS', '--review-status', 'PASS', '--changed-paths', 'releases/./v3.json') } else { $psH04DotSeg }
    $psH04Case = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rAuth, '-PrNumber', '101', '-BaseSha', $authBaseSha, '-LedgerPath', $authLed, '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS', '-ChangedPaths', 'Releases/v3.json')
    $shH04Case = if ($script:HasBash) { Invoke-ShGuard @('merge-policy-check', '--repo-root', $rAuthPosix, '--pr-number', '101', '--base-sha', $authBaseSha, '--ledger-path', $authLed, '--pr-state', 'OPEN', '--ci-status', 'PASS', '--review-status', 'PASS', '--changed-paths', 'Releases/v3.json') } else { $psH04Case }

    Set-Content (Join-Path $rGov '.b3\dot-slash-policy.json') '{"auto_merge":"disabled","protected_paths":["./"],"allow_protected_paths":false,"require_ci":true,"require_review":true}'
    $psH04DotSlash = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PolicyPath', '.b3/dot-slash-policy.json', '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS', '-ChangedPaths', 'docs/notes.md')
    $shH04DotSlash = if ($script:HasBash) { Invoke-ShGuard @('merge-policy-check', '--repo-root', $rGovPosix, '--policy-path', '.b3/dot-slash-policy.json', '--pr-state', 'OPEN', '--ci-status', 'PASS', '--review-status', 'PASS', '--changed-paths', 'docs/notes.md') } else { $psH04DotSlash }

    $rRen = Join-Path $sandbox 'h04-rename-repo'
    $rRenPosix = To-PosixPath $rRen
    Init-TestRepo $rRen
    New-Item -ItemType Directory -Path (Join-Path $rRen '.b3'), (Join-Path $rRen 'releases'), (Join-Path $rRen 'docs') -Force | Out-Null
    Set-Content (Join-Path $rRen '.b3\research-policy.json') (@{
        auto_merge = 'authorized'
        protected_paths = @('releases/')
        allow_protected_paths = $false
        require_ci = $true
        require_review = $true
    } | ConvertTo-Json)
    Set-Content (Join-Path $rRen 'releases\a.json') '{"version":1}'
    Push-Location $rRen
    & git remote add origin 'https://github.com/octo/rs-ren.git'
    & git add .; & git commit -qm 'base with release file'
    $renBaseSha = (& git rev-parse HEAD).Trim()
    & git checkout -qb feat/rename-release
    & git mv releases/a.json docs/a.md
    & git commit -qm 'rename release file to docs'
    $renHeadSha = (& git rev-parse HEAD).Trim()
    Pop-Location
    $renLed = '.b3/research-ship/runs/ren/ledger.md'
    [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $rRen, '-Action', 'init', '-LedgerPath', $renLed, '-BaseSha', $renBaseSha, '-ReviewIndependence', 'INDEPENDENT'))
    $renLedTxt = Get-Content -LiteralPath (Join-Path $rRen '.b3\research-ship\runs\ren\ledger.md') -Raw
    foreach ($rm in [regex]::Matches($renLedTxt, '(?m)^\|\s*(U\d+)\s*\|')) {
        [void](Invoke-PsGuard @('review-ledger', '-RepoRoot', $rRen, '-Action', 'update', '-LedgerPath', $renLed, '-UnitId', $rm.Groups[1].Value, '-Status', 'REVIEWED'))
    }
    Write-MockPreMergeFixtures $mockDataDir 'octo/rs-ren' 104 'main' $renBaseSha 'main' $renBaseSha 'feat/rename-release' $renHeadSha 'docs/a.md'
    $psH04Ren = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rRen, '-PrNumber', '104', '-BaseSha', $renBaseSha, '-LedgerPath', $renLed, '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS', '-ChangedPaths', 'docs/a.md')
    $shH04Ren = if ($script:HasBash) { Invoke-ShGuard @('merge-policy-check', '--repo-root', $rRenPosix, '--pr-number', '104', '--base-sha', $renBaseSha, '--ledger-path', $renLed, '--pr-state', 'OPEN', '--ci-status', 'PASS', '--review-status', 'PASS', '--changed-paths', 'docs/a.md') } else { $psH04Ren }

    $hardOk = ($psNoPr.Code -eq 1 -and $psNoPr.Text -match 'MERGE_BLOCKED: missing_pr_number' -and $shNoPr.Code -eq 1 -and $shNoPr.Text -ceq $psNoPr.Text) -and
              ($psBaseHead.Code -eq 1 -and $psBaseHead.Text -match 'MERGE_BLOCKED: base_sha_equals_head' -and $shBaseHead.Code -eq 1 -and $shBaseHead.Text -ceq $psBaseHead.Text) -and
              ($psNoLed.Code -eq 1 -and $psNoLed.Text -match 'MERGE_BLOCKED: missing_ledger_path' -and $shNoLed.Code -eq 1 -and $shNoLed.Text -ceq $psNoLed.Text) -and
              ($psUnkBlk.Code -eq 1 -and $psUnkBlk.Text -match 'MERGE_BLOCKED: review_independence_unknown' -and $shUnkBlk.Code -eq 1 -and $shUnkBlk.Text -ceq $psUnkBlk.Text) -and
              ($psSalBlk.Code -eq 1 -and $psSalBlk.Text -match 'MERGE_BLOCKED: single_agent_limit' -and $shSalBlk.Code -eq 1 -and $shSalBlk.Text -ceq $psSalBlk.Text) -and
              ($psDirty.Code -eq 1 -and $psDirty.Text -match 'MERGE_BLOCKED: dirty_worktree' -and $shDirty.Code -eq 1 -and $shDirty.Text -ceq $psDirty.Text) -and
              ($psPolMod.Code -eq 1 -and $psPolMod.Text -match 'MERGE_BLOCKED: policy_modified_in_pr' -and $shPolMod.Code -eq 1 -and $shPolMod.Text -ceq $psPolMod.Text) -and
              ($psPolNotBase.Code -eq 1 -and $psPolNotBase.Text -match 'MERGE_BLOCKED: policy_path_override_not_allowed' -and $shPolNotBase.Code -eq 1 -and $shPolNotBase.Text -ceq $psPolNotBase.Text) -and
              ($psH04Trav.Code -eq 1 -and $psH04Trav.Text -match 'MERGE_BLOCKED: invalid_changed_path' -and $shH04Trav.Code -eq 1 -and $shH04Trav.Text -ceq $psH04Trav.Text) -and
              ($psH04DotSeg.Code -eq 1 -and $psH04DotSeg.Text -match 'MERGE_BLOCKED: invalid_changed_path' -and $shH04DotSeg.Code -eq 1 -and $shH04DotSeg.Text -ceq $psH04DotSeg.Text) -and
              ($psH04Case.Code -eq 1 -and $psH04Case.Text -match 'MERGE_BLOCKED: protected_paths=Releases/v3\.json' -and $shH04Case.Code -eq 1 -and $shH04Case.Text -ceq $psH04Case.Text) -and
              ($psH04DotSlash.Code -eq 1 -and $psH04DotSlash.Text -match 'MERGE_BLOCKED: protected_paths=docs/notes\.md' -and $shH04DotSlash.Code -eq 1 -and $shH04DotSlash.Text -ceq $psH04DotSlash.Text) -and
              ($psH04Ren.Code -eq 1 -and $psH04Ren.Text -match 'MERGE_BLOCKED: protected_paths=releases/a\.json' -and $shH04Ren.Code -eq 1 -and $shH04Ren.Text -ceq $psH04Ren.Text)
    if ($hardOk) {
        Pass 'c04-h04-h08-merge-policy-hardening'
    } else {
        FailCheck 'c04-h04-h08-merge-policy-hardening' "noPr=$($psNoPr.Text)|$($shNoPr.Text) baseHead=$($psBaseHead.Text) noLed=$($psNoLed.Text) unk=$($psUnkBlk.Text) sal=$($psSalBlk.Text) dirty=$($psDirty.Text) polMod=$($psPolMod.Text) polOvr=$($psPolNotBase.Text) trav=$($psH04Trav.Text) dot=$($psH04DotSeg.Text) case=$($psH04Case.Text) dotSl=$($psH04DotSlash.Text) ren=$($psH04Ren.Text)"
    }

    # --- 3. namespace-isolation-checkpoints-and-waves (PS + Bash) ---
    $rNs = Join-Path $sandbox 'ns-repo'
    $rNsPosix = $rNs -replace '\\', '/'
    Init-TestRepo $rNs
    Set-Content (Join-Path $rNs 'init.txt') "v1`n"
    Push-Location $rNs
    & git add .; & git commit -qm 'init'
    $nsBase = (& git rev-parse HEAD).Trim()
    Pop-Location

    $rsId = Invoke-PsGuard @('new-run', '-RepoRoot', $rNs, '-Namespace', 'research-ship', '-Slug', 'star-compare', '-Timestamp', '20261123-0100')
    Set-Content (Join-Path $rNs '.b3\research-ship\runs\20261123-0100-star-compare\progress.md') "- run_status: running`n"
    $rsRes = Invoke-PsGuard @('resolve-run', '-RepoRoot', $rNs, '-Namespace', 'research-ship')
    $shipResEmpty = Invoke-PsGuard @('resolve-run', '-RepoRoot', $rNs, '-Namespace', 'ship')
    $rsList = Invoke-PsGuard @('list-runs', '-RepoRoot', $rNs, '-Namespace', 'research-ship')
    $badNs = Invoke-PsGuard @('new-run', '-RepoRoot', $rNs, '-Namespace', 'bogus', '-Slug', 'x')

    # Verify .b3/research-ship checkpoint is excluded from diff-scope and blocked by precommit
    $dsIgnored = Invoke-PsGuard @('diff-scope', '-RepoRoot', $rNs, '-BaseSha', $nsBase)
    Push-Location $rNs
    & git add -f '.b3/research-ship/runs/20261123-0100-star-compare/progress.md'
    $pcBlocked = Invoke-PsGuard @('precommit', '-RepoRoot', $rNs, '-AllowedPaths', '.b3/research-ship')
    & git reset -q
    Pop-Location

    # Wave checks: disjoint parallel research units vs shared ledger conflict
    $waveOk = Invoke-PsGuard @('check-wave', '-RepoRoot', $rNs, '-ExpectedBaseSha', $nsBase, '-WaveSpecs', 'U001=research/u1.md;U002=research/u2.md', '-WaveReads', 'U001=sources/a.md;U002=sources/b.md')
    $waveConflict = Invoke-PsGuard @('check-wave', '-RepoRoot', $rNs, '-ExpectedBaseSha', $nsBase, '-WaveSpecs', 'U001=research/u1.md,ledger/index.json;U002=research/u2.md,ledger/index.json')

    $nsShOk = $true
    if ($script:HasBash) {
        $shNew = Invoke-ShCmd "'$guardShPosix' new-run --repo-root '$rNsPosix' --namespace research-ship --slug bash-pass --timestamp 20261123-0101"
        Set-Content (Join-Path $rNs '.b3\research-ship\runs\20261123-0101-bash-pass\progress.md') "- run_status: PASS`n"
        $shNew2 = Invoke-ShCmd "'$guardShPosix' new-run --repo-root '$rNsPosix' --namespace research-ship --slug bash-pass2 --timestamp 20261123-0102"
        Set-Content (Join-Path $rNs '.b3\research-ship\runs\20261123-0102-bash-pass2\progress.md') "- run_status: PASS`n"
        $shPrune = Invoke-ShCmd "'$guardShPosix' prune --repo-root '$rNsPosix' --namespace research-ship --keep 0"
        $shRes = Invoke-ShCmd "'$guardShPosix' resolve-run --repo-root '$rNsPosix' --namespace research-ship"
        $shList = Invoke-ShCmd "'$guardShPosix' list-runs --repo-root '$rNsPosix' --namespace research-ship"
        $shEmptyShip = Invoke-ShCmd "'$guardShPosix' resolve-run --repo-root '$rNsPosix' --namespace ship"
        $shDs = Invoke-ShCmd "'$guardShPosix' diff-scope --repo-root '$rNsPosix' --base-sha '$nsBase'"
        $shWaveOk = Invoke-ShCmd "'$guardShPosix' check-wave --repo-root '$rNsPosix' --expected-base-sha '$nsBase' --wave-specs 'U001=research/u1.md;U002=research/u2.md' --wave-reads 'U001=sources/a.md;U002=sources/b.md'"
        $shWaveCon = Invoke-ShCmd "'$guardShPosix' check-wave --repo-root '$rNsPosix' --expected-base-sha '$nsBase' --wave-specs 'U001=research/u1.md,ledger/index.json;U002=research/u2.md,ledger/index.json'"
        Push-Location $rNs
        & git add -f '.b3/research-ship/runs/20261123-0100-star-compare/progress.md'
        $shPc = Invoke-ShCmd "'$guardShPosix' precommit --repo-root '$rNsPosix' --allowed-paths '.b3/research-ship'"
        & git reset -q
        Pop-Location
        $nsShOk = ($shNew.Code -eq 0 -and $shNew2.Code -eq 0) -and
                  ($shPrune.Code -eq 0 -and $shPrune.Text -match 'PRUNE_OK: 1 removed') -and
                  ($shRes.Code -eq 0 -and $shRes.Text -eq '.b3/research-ship/runs/20261123-0102-bash-pass2') -and
                  ($shList.Code -eq 0 -and $shList.Text -match '20261123-0100-star-compare \[running\]' -and $shList.Text -match '\* 20261123-0102-bash-pass2 \[PASS\]') -and
                  ($shEmptyShip.Code -eq 1 -and $shEmptyShip.Text -eq 'NO_ACTIVE_RUN') -and
                  ($shDs.Code -eq 2 -and $shDs.Text -eq 'EMPTY_DIFF') -and
                  ($shWaveOk.Code -eq 0 -and $shWaveCon.Code -eq 2) -and
                  ($shPc.Code -eq 1 -and $shPc.Text -match 'checkpoint staged')
    }

    if ($rsId.Code -eq 0 -and $rsRes.Code -eq 0 -and $rsRes.Text -eq '.b3/research-ship/runs/20261123-0100-star-compare' -and
        $shipResEmpty.Code -eq 1 -and ($rsList.Text -match '\* 20261123-0100-star-compare \[running\]') -and
        $badNs.Code -eq 1 -and ($dsIgnored.Code -eq 2 -and $dsIgnored.Text -eq 'EMPTY_DIFF') -and
        ($pcBlocked.Code -eq 1 -and $pcBlocked.Text -match 'checkpoint staged') -and
        ($waveOk.Code -eq 0 -and $waveConflict.Code -eq 2) -and $nsShOk) {
        Pass 'namespace-isolation-and-waves'
    } else {
        FailCheck 'namespace-isolation-and-waves' "rsId=$($rsId.Code) rsRes=$($rsRes.Text) shipEmpty=$($shipResEmpty.Code) ds=$($dsIgnored.Code) pc=$($pcBlocked.Code) wave=$($waveOk.Code)/$($waveConflict.Code) sh=$nsShOk"
    }

    # --- 3b. research-ship-safety-and-receipt-exclusion (PS + Bash) ---
    $vrOk = $true
    $vrPs = Invoke-PsGuard @('verify-run', '-RepoRoot', $rNs, '-VerifyCmd', 'Write-Output verified', '-ReceiptPath', '.b3/research-ship/runs/vr.receipt', '-TaskId', 'U001', '-Scope', 'research-check')
    Set-Content (Join-Path $rNs '.b3\research-ship\runs\extra-checkpoint.md') "# checkpoint note`n"
    $vcPs = Invoke-PsGuard @('verify-check', '-RepoRoot', $rNs, '-ReceiptPath', '.b3/research-ship/runs/vr.receipt')
    $vrOk = ($vrPs.Code -eq 0) -and ($vcPs.Code -eq 0) -and ($vcPs.Text -match 'VERIFY_VALID')

    $decoyPrune = Join-Path $sandbox 'prune-decoy'
    New-Item -ItemType Directory -Path $decoyPrune -Force | Out-Null
    Set-Content (Join-Path $decoyPrune 'preserve.txt') "keep me`n"
    $rPrPs = Join-Path $sandbox 'prune-rs-ps'
    Init-TestRepo $rPrPs
    Set-Content (Join-Path $rPrPs 'a.txt') "a`n"
    Push-Location $rPrPs; & git add .; & git commit -qm 'init'; Pop-Location
    [void](Invoke-PsGuard @('new-run', '-RepoRoot', $rPrPs, '-Namespace', 'research-ship', '-Slug', 'old-pass', '-Timestamp', '20261123-0200'))
    $oldPassDir = Join-Path $rPrPs '.b3\research-ship\runs\20261123-0200-old-pass'
    Set-Content (Join-Path $oldPassDir 'progress.md') "- run_status: PASS`n"
    New-Item -ItemType Junction -Path (Join-Path $oldPassDir 'junc-out') -Target $decoyPrune | Out-Null
    [void](Invoke-PsGuard @('new-run', '-RepoRoot', $rPrPs, '-Namespace', 'research-ship', '-Slug', 'cur-pass', '-Timestamp', '20261123-0201'))
    Set-Content (Join-Path $rPrPs '.b3\research-ship\runs\20261123-0201-cur-pass\progress.md') "- run_status: PASS`n"
    $prSafePs = Invoke-PsGuard @('prune', '-RepoRoot', $rPrPs, '-Namespace', 'research-ship', '-Keep', '0')
    $decoyStillPs = Test-Path -LiteralPath (Join-Path $decoyPrune 'preserve.txt') -PathType Leaf

    $rLinkRuns = Join-Path $sandbox 'prune-rs-link'
    Init-TestRepo $rLinkRuns
    New-Item -ItemType Directory -Path (Join-Path $rLinkRuns '.b3\research-ship') -Force | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $rLinkRuns '.b3\research-ship\runs') -Target $decoyPrune | Out-Null
    $prLinkPs = Invoke-PsGuard @('prune', '-RepoRoot', $rLinkRuns, '-Namespace', 'research-ship', '-Keep', '0')

    $safeShOk = $true
    if ($script:HasBash) {
        $shVr = Invoke-ShCmd "'$guardShPosix' verify-run --repo-root '$rNsPosix' --verify-cmd 'echo verified' --receipt-path '.b3/research-ship/runs/vr-sh.receipt' --task-id U001 --scope research-check"
        Set-Content (Join-Path $rNs '.b3\research-ship\runs\extra-sh-checkpoint.md') "# checkpoint note sh`n"
        $shVc = Invoke-ShCmd "'$guardShPosix' verify-check --repo-root '$rNsPosix' --receipt-path '.b3/research-ship/runs/vr-sh.receipt'"
        $rPrSh = Join-Path $sandbox 'prune-rs-sh'
        $rPrShPosix = $rPrSh -replace '\\', '/'
        $rLinkRunsPosix = $rLinkRuns -replace '\\', '/'
        Init-TestRepo $rPrSh
        Set-Content (Join-Path $rPrSh 'a.txt') "a`n"
        Push-Location $rPrSh; & git add .; & git commit -qm 'init'; Pop-Location
        [void](Invoke-ShCmd "'$guardShPosix' new-run --repo-root '$rPrShPosix' --namespace research-ship --slug old-sh --timestamp 20261123-0202")
        $oldShDir = Join-Path $rPrSh '.b3\research-ship\runs\20261123-0202-old-sh'
        Set-Content (Join-Path $oldShDir 'progress.md') "- run_status: PASS`n"
        New-Item -ItemType Junction -Path (Join-Path $oldShDir 'junc-out') -Target $decoyPrune | Out-Null
        [void](Invoke-ShCmd "'$guardShPosix' new-run --repo-root '$rPrShPosix' --namespace research-ship --slug cur-sh --timestamp 20261123-0203")
        Set-Content (Join-Path $rPrSh '.b3\research-ship\runs\20261123-0203-cur-sh\progress.md') "- run_status: PASS`n"
        $shPrSafe = Invoke-ShCmd "'$guardShPosix' prune --repo-root '$rPrShPosix' --namespace research-ship --keep 0"
        $shPrLink = Invoke-ShCmd "'$guardShPosix' prune --repo-root '$rLinkRunsPosix' --namespace research-ship --keep 0"
        $decoyStillSh = Test-Path -LiteralPath (Join-Path $decoyPrune 'preserve.txt') -PathType Leaf
        $safeShOk = ($shVr.Code -eq 0) -and ($shVc.Code -eq 0 -and $shVc.Text -match 'VERIFY_VALID') -and
                    ($shPrSafe.Code -eq 0 -and $shPrSafe.Text -match 'PRUNE_OK: 1 removed') -and
                    ($shPrLink.Code -eq 1 -and $shPrLink.Text -match 'is a link') -and $decoyStillSh
    }

    if ($vrOk -and $prSafePs.Code -eq 0 -and ($prSafePs.Text -match 'PRUNE_OK: 1 removed') -and $decoyStillPs -and
        $prLinkPs.Code -eq 1 -and ($prLinkPs.Text -match 'is a link') -and $safeShOk) {
        Pass 'research-ship-safety-and-receipt-exclusion'
    } else {
        FailCheck 'research-ship-safety-and-receipt-exclusion' "vr=$vrOk pr=$($prSafePs.Code) decoy=$decoyStillPs link=$($prLinkPs.Code) sh=$safeShOk"
    }

    # --- 4. workflow-contracts-and-domain-decoupling ---
    $cmdText = Get-Content -LiteralPath (Join-Path $root 'commands\b3-research-ship.md') -Raw
    $skillText = Get-Content -LiteralPath (Join-Path $root 'adapters\command-skills\b3-research-ship\SKILL.md') -Raw
    $wfText = Get-Content -LiteralPath (Join-Path $root 'workflows\research-ship.md') -Raw
    $gatesText = Get-Content -LiteralPath (Join-Path $root 'workflows\references\research-ship-gates.md') -Raw
    $resumeText = Get-Content -LiteralPath (Join-Path $root 'workflows\references\research-ship-resume.md') -Raw

    $portableDecoupled = ($cmdText -notmatch '(?i)tu\s*vi|tuvi|chinh tinh|phu tinh|phi tinh|tu hoa') -and
                         ($skillText -notmatch '(?i)tu\s*vi|tuvi|chinh tinh|phu tinh|phi tinh|tu hoa') -and
                         ($wfText -notmatch '(?i)tu\s*vi|tuvi|chinh tinh|phu tinh|phi tinh|tu hoa') -and
                         ($gatesText -notmatch '(?i)tu\s*vi|tuvi|chinh tinh|phu tinh|phi tinh|tu hoa') -and
                         ($resumeText -notmatch '(?i)tu\s*vi|tuvi|chinh tinh|phu tinh|phi tinh|tu hoa')

    $phasesOk = $true
    foreach ($ph in @('### A. Preflight', '### B. Research Planning', '### C. Source Discovery', '### D. Cross-Source Analysis', '### E. Independent Evidence Verification', '### F. Formalization', '### G. Implementation', '### H. Technical Verification', '### I. PR Lifecycle', '### J. Merge Eligibility', '### K. Authorized Auto-Merge')) {
        if ($wfText -notmatch [regex]::Escape($ph)) { $phasesOk = $false; break }
    }

    $singleHopSkillOk = ($skillText -match 'workflows/research-ship\.md') -and
                        ($skillText -notmatch 'commands/b3-research-ship\.md') -and
                        ($skillText -notmatch 'review-loop/spec\.md')
    $boundariesOk = ($wfText -match 'RESEARCHED != VERIFIED != IMPLEMENTED != RELEASED') -and
                    ($wfText -match 'PR_MERGED != RUNTIME_SERVED != DEPLOYED') -and
                    ($wfText -match 'continue independent eligible units') -and
                    ($gatesText -match 'gh pr list')

    if ($portableDecoupled -and $phasesOk -and $singleHopSkillOk -and $boundariesOk) {
        Pass 'workflow-contracts-and-decoupling'
    } else {
        FailCheck 'workflow-contracts-and-decoupling' "decoupled=$portableDecoupled phases=$phasesOk singleHop=$singleHopSkillOk bounds=$boundariesOk"
    }

    # --- 5. four-host-compatibility-and-context ---
    $hostsOk = $true
    foreach ($hName in @('cursor', 'codex', 'claude', 'antigravity')) {
        $pDir = Join-Path $sandbox "prod-$hName"
        New-Item -ItemType Directory -Path $pDir -Force | Out-Null
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'adapters\install-product.ps1') -ProductRoot $pDir -B3Home $root -HostName $hName | Out-Null
        if ($LASTEXITCODE -ne 0) { $hostsOk = $false; break }
        $cmdCopy = Test-Path -LiteralPath (Join-Path $pDir '.cursor\commands\b3-research-ship.md')
        $giText = Get-Content -LiteralPath (Join-Path $pDir '.gitignore') -Raw
        $giBoth = ($giText -match '(?m)^\s*\.b3/ship/\s*$') -and ($giText -match '(?m)^\s*\.b3/research-ship/\s*$') -and ($giText -match '(?m)^\s*\.b3/models\.md\s*$')
        if (-not ($cmdCopy -and $giBoth)) { $hostsOk = $false; break }
        if ($hName -in @('codex', 'antigravity')) {
            if (-not (Test-Path -LiteralPath (Join-Path $pDir '.agents\skills\b3-research-ship\SKILL.md'))) { $hostsOk = $false; break }
        }
        if ($hName -eq 'claude') {
            if (-not (Test-Path -LiteralPath (Join-Path $pDir '.claude\skills\b3-research-ship\SKILL.md'))) { $hostsOk = $false; break }
        }
    }

    $pluginHome = Join-Path $sandbox 'ag-plugin-home'
    $pluginOut = Join-Path $sandbox 'ag-plugin'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'adapters\antigravity\install-plugin.ps1') -PluginRoot $pluginOut -UserHome $pluginHome -B3Home $root | Out-Null
    $pluginOk = ($LASTEXITCODE -eq 0) -and
                (Test-Path -LiteralPath (Join-Path $pluginOut 'skills\b3-research-ship\SKILL.md')) -and
                (Test-Path -LiteralPath (Join-Path $pluginHome '.gemini\config\skills.json') -PathType Leaf) -and
                (@(Get-ChildItem -LiteralPath (Join-Path $pluginOut 'agents') -Filter '*.md' -File).Count -eq 5)

    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'adapters\sync-skills.ps1') -HostName antigravity -VerifyOnly | Out-Null
    $syncAgOk = ($LASTEXITCODE -eq 0)

    # .gitignore upgrade (.b3/ -> .b3/ship/ + .b3/research-ship/) & append (.b3/ship/ -> + .b3/research-ship/)
    $giUpPs = Join-Path $sandbox 'gi-up-ps'
    $giAppPs = Join-Path $sandbox 'gi-app-ps'
    New-Item -ItemType Directory -Path $giUpPs, $giAppPs -Force | Out-Null
    Set-Content (Join-Path $giUpPs '.gitignore') ".b3/`nnode_modules/`n" -NoNewline
    Set-Content (Join-Path $giAppPs '.gitignore') ".b3/ship/`n" -NoNewline
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'adapters\install-product.ps1') -ProductRoot $giUpPs -B3Home $root -HostName cursor | Out-Null
    $giUpPsText = Get-Content -LiteralPath (Join-Path $giUpPs '.gitignore') -Raw
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'adapters\install-product.ps1') -ProductRoot $giAppPs -B3Home $root -HostName cursor | Out-Null
    $giAppPsText = Get-Content -LiteralPath (Join-Path $giAppPs '.gitignore') -Raw
    $giMigrationsOk = ($giUpPsText -match '(?m)^\s*\.b3/ship/\s*$') -and ($giUpPsText -match '(?m)^\s*\.b3/research-ship/\s*$') -and ($giUpPsText -match '(?m)^\s*\.b3/models\.md\s*$') -and ($giUpPsText -notmatch '(?m)^\s*\.b3/\s*$') -and
                      ($giAppPsText -match '(?m)^\s*\.b3/ship/\s*$') -and ($giAppPsText -match '(?m)^\s*\.b3/research-ship/\s*$') -and ($giAppPsText -match '(?m)^\s*\.b3/models\.md\s*$')

    $bashCompatOk = $true
    if ($script:HasBash) {
        $pShDir = Join-Path $sandbox 'prod-sh-codex'
        $pShPosix = $pShDir -replace '\\', '/'
        $giUpSh = Join-Path $sandbox 'gi-up-sh'
        $giAppSh = Join-Path $sandbox 'gi-app-sh'
        $giUpShPosix = $giUpSh -replace '\\', '/'
        $giAppShPosix = $giAppSh -replace '\\', '/'
        $rootPosix = $root -replace '\\', '/'
        New-Item -ItemType Directory -Path $pShDir, $giUpSh, $giAppSh -Force | Out-Null
        Set-Content (Join-Path $giUpSh '.gitignore') ".b3/`nnode_modules/`n" -NoNewline
        Set-Content (Join-Path $giAppSh '.gitignore') ".b3/ship/`n" -NoNewline
        $shInst = Invoke-ShCmd "'$rootPosix/adapters/install-product.sh' --product-root '$pShPosix' --b3-home '$rootPosix' --host codex"
        $shUpRes = Invoke-ShCmd "'$rootPosix/adapters/install-product.sh' --product-root '$giUpShPosix' --b3-home '$rootPosix' --host cursor"
        $shAppRes = Invoke-ShCmd "'$rootPosix/adapters/install-product.sh' --product-root '$giAppShPosix' --b3-home '$rootPosix' --host cursor"
        $shDryRes = Invoke-ShCmd "'$rootPosix/adapters/install-product.sh' --product-root '$giUpShPosix' --b3-home '$rootPosix' --host cursor --dry-run"
        $giSh = if (Test-Path -LiteralPath (Join-Path $pShDir '.gitignore')) { Get-Content -LiteralPath (Join-Path $pShDir '.gitignore') -Raw } else { '' }
        $giUpShText = Get-Content -LiteralPath (Join-Path $giUpSh '.gitignore') -Raw
        $giAppShText = Get-Content -LiteralPath (Join-Path $giAppSh '.gitignore') -Raw
        $bashCompatOk = ($shInst.Code -eq 0) -and ($shUpRes.Code -eq 0) -and ($shAppRes.Code -eq 0) -and ($shDryRes.Code -eq 0) -and
                        (Test-Path -LiteralPath (Join-Path $pShDir '.cursor\commands\b3-research-ship.md')) -and
                        ($giSh -match '(?m)^\s*\.b3/research-ship/\s*$') -and ($giSh -match '(?m)^\s*\.b3/models\.md\s*$') -and
                        ($giUpShText -match '(?m)^\s*\.b3/ship/\s*$') -and ($giUpShText -match '(?m)^\s*\.b3/research-ship/\s*$') -and ($giUpShText -match '(?m)^\s*\.b3/models\.md\s*$') -and ($giUpShText -notmatch '(?m)^\s*\.b3/\s*$') -and
                        ($giAppShText -match '(?m)^\s*\.b3/ship/\s*$') -and ($giAppShText -match '(?m)^\s*\.b3/research-ship/\s*$') -and ($giAppShText -match '(?m)^\s*\.b3/models\.md\s*$') -and
                        ($shDryRes.Text -match '\.b3/research-ship/') -and ($shDryRes.Text -match '\.b3/models\.md')
    }

    if ($hostsOk -and $pluginOk -and $syncAgOk -and $giMigrationsOk -and $bashCompatOk) {
        Pass 'four-host-compatibility'
    } else {
        FailCheck 'four-host-compatibility' "hosts=$hostsOk plugin=$pluginOk syncAg=$syncAgOk giMig=$giMigrationsOk bashCompat=$bashCompatOk"
    }

    $ctxOut = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\measure-context.ps1') -RepoRoot $root -Strict) -join "`n"
    if ($LASTEXITCODE -eq 0 -and $ctxOut -match 'warnings\s*:\s*0' -and $ctxOut -match 'research_ship_core') {
        Pass 'research-ship-context-budget-strict'
    } else {
        FailCheck 'research-ship-context-budget-strict' "exit=$LASTEXITCODE out=$ctxOut"
    }

    # --- 6. research-wave-partition-and-blocked-isolation (PS + Bash) ---
    $rWave = Join-Path $sandbox 'rs-wave-repo'
    $rWavePosix = To-PosixPath $rWave
    Init-B3TestRepo -RepoPath $rWave -DefaultBranch 'main' -UserEmail 'research-test@example.com' -UserName 'Research Test' -InitialCommit
    Push-Location $rWave
    $waveBase = (& git rev-parse HEAD).Trim()
    Pop-Location

    $wDisjointPs = Invoke-PsGuard @('check-wave', '-RepoRoot', $rWave, '-ExpectedBaseSha', $waveBase, '-Partition', '-WaveSpecs', 'U001=research/u1.md;U002=research/u2.md', '-WaveReads', 'U001=evidence-index.md,sources.manifest;U002=evidence-index.md,sources.manifest')
    $wPartWritePs = Invoke-PsGuard @('check-wave', '-RepoRoot', $rWave, '-ExpectedBaseSha', $waveBase, '-Partition', '-WaveSpecs', 'U001=research/u1.md;U002=research/u2.md;U003=research/u1.md,research/ledger.md', '-WaveReads', 'U001=evidence-index.md,sources.manifest;U002=evidence-index.md,sources.manifest;U003=evidence-index.md,sources.manifest')
    $wPartRwPs = Invoke-PsGuard @('check-wave', '-RepoRoot', $rWave, '-ExpectedBaseSha', $waveBase, '-Partition', '-WaveSpecs', 'U001=research/u1.md;U002=research/u2.md;U003=research/u3.md', '-WaveReads', 'U001=evidence-index.md,sources.manifest;U002=evidence-index.md,sources.manifest;U003=research/u1.md,evidence-index.md')
    $wProtPs = Invoke-PsGuard @('check-wave', '-RepoRoot', $rWave, '-ExpectedBaseSha', $waveBase, '-Partition', '-WaveSpecs', 'U001=.b3/research-ship;U002=research/u2.md')
    $wLedgerPartPs = Invoke-PsGuard @('check-wave', '-RepoRoot', $rWave, '-ExpectedBaseSha', $waveBase, '-Partition', '-WaveSpecs', 'U001=evidence-index.md;U002=evidence-index.md')
    $wLedgerRawPs = Invoke-PsGuard @('check-wave', '-RepoRoot', $rWave, '-ExpectedBaseSha', $waveBase, '-WaveSpecs', 'U001=evidence-index.md;U002=evidence-index.md')

    $rsWavePsOk = ($wDisjointPs.Code -eq 0 -and
                   ($wDisjointPs.Text -match '(?m)^WAVE_OK: disjoint \(2 tasks, 2 paths\)$') -and
                   ($wDisjointPs.Text -match '(?m)^wave\|1\|PARALLEL\|agents=2\|tasks=U001,U002\|reason=independent_ready_tasks$')) -and
                  ($wPartWritePs.Code -eq 0 -and
                   ($wPartWritePs.Text -match '(?m)^WAVE_PARTITIONED: waves=2 max_parallel=2 reason=conflicting_wave_split$') -and
                   ($wPartWritePs.Text -match '(?m)^wave\|1\|PARALLEL\|agents=2\|tasks=U001,U002\|reason=independent_ready_tasks$') -and
                   ($wPartWritePs.Text -match '(?m)^wave\|2\|SEQUENTIAL\|agents=1\|tasks=U003\|reason=shared_write_conflict$')) -and
                  ($wPartRwPs.Code -eq 0 -and
                   ($wPartRwPs.Text -match '(?m)^conflicts=rw:research/u1\.md\(U001->U003\)$') -and
                   ($wPartRwPs.Text -match '(?m)^WAVE_PARTITIONED: waves=2 max_parallel=2 reason=conflicting_wave_split$') -and
                   ($wPartRwPs.Text -match '(?m)^wave\|1\|PARALLEL\|agents=2\|tasks=U001,U002\|reason=independent_ready_tasks$') -and
                   ($wPartRwPs.Text -match '(?m)^wave\|2\|SEQUENTIAL\|agents=1\|tasks=U003\|reason=shared_write_conflict$')) -and
                  ($wProtPs.Code -eq 1 -and ($wProtPs.Text -match "WAVE_FAIL: protected path '\.b3/research-ship' cannot be worker-owned")) -and
                  ($wLedgerPartPs.Code -eq 2 -and
                   ($wLedgerPartPs.Text -match '(?m)^WAVE_SEQUENTIAL: waves=2 max_parallel=1 reason=shared_write_conflict$') -and
                   ($wLedgerPartPs.Text -match '(?m)^wave\|1\|SEQUENTIAL\|agents=1\|tasks=U001\|reason=shared_write_conflict$') -and
                   ($wLedgerPartPs.Text -match '(?m)^wave\|2\|SEQUENTIAL\|agents=1\|tasks=U002\|reason=shared_write_conflict$')) -and
                  ($wLedgerRawPs.Code -eq 2 -and ($wLedgerRawPs.Text -match 'WAVE_CONFLICT: evidence-index\.md\(U001,U002\)'))

    $rsWaveShOk = $true
    if ($script:HasBash) {
        $wDisjointSh = Invoke-ShGuard @('check-wave', '--repo-root', $rWavePosix, '--expected-base-sha', $waveBase, '--partition', '--wave-specs', 'U001=research/u1.md;U002=research/u2.md', '--wave-reads', 'U001=evidence-index.md,sources.manifest;U002=evidence-index.md,sources.manifest')
        $wPartWriteSh = Invoke-ShGuard @('check-wave', '--repo-root', $rWavePosix, '--expected-base-sha', $waveBase, '--partition', '--wave-specs', 'U001=research/u1.md;U002=research/u2.md;U003=research/u1.md,research/ledger.md', '--wave-reads', 'U001=evidence-index.md,sources.manifest;U002=evidence-index.md,sources.manifest;U003=evidence-index.md,sources.manifest')
        $wPartRwSh = Invoke-ShGuard @('check-wave', '--repo-root', $rWavePosix, '--expected-base-sha', $waveBase, '--partition', '--wave-specs', 'U001=research/u1.md;U002=research/u2.md;U003=research/u3.md', '--wave-reads', 'U001=evidence-index.md,sources.manifest;U002=evidence-index.md,sources.manifest;U003=research/u1.md,evidence-index.md')
        $wProtSh = Invoke-ShGuard @('check-wave', '--repo-root', $rWavePosix, '--expected-base-sha', $waveBase, '--partition', '--wave-specs', 'U001=.b3/research-ship;U002=research/u2.md')
        $wLedgerPartSh = Invoke-ShGuard @('check-wave', '--repo-root', $rWavePosix, '--expected-base-sha', $waveBase, '--partition', '--wave-specs', 'U001=evidence-index.md;U002=evidence-index.md')
        $wLedgerRawSh = Invoke-ShGuard @('check-wave', '--repo-root', $rWavePosix, '--expected-base-sha', $waveBase, '--wave-specs', 'U001=evidence-index.md;U002=evidence-index.md')

        $rsWaveShOk = ($wDisjointSh.Code -eq $wDisjointPs.Code -and $wDisjointSh.Text -ceq $wDisjointPs.Text) -and
                      ($wPartWriteSh.Code -eq $wPartWritePs.Code -and $wPartWriteSh.Text -ceq $wPartWritePs.Text) -and
                      ($wPartRwSh.Code -eq $wPartRwPs.Code -and $wPartRwSh.Text -ceq $wPartRwPs.Text) -and
                      ($wProtSh.Code -eq $wProtPs.Code -and $wProtSh.Text -ceq $wProtPs.Text) -and
                      ($wLedgerPartSh.Code -eq $wLedgerPartPs.Code -and $wLedgerPartSh.Text -ceq $wLedgerPartPs.Text) -and
                      ($wLedgerRawSh.Code -eq $wLedgerRawPs.Code -and $wLedgerRawSh.Text -ceq $wLedgerRawPs.Text)
    }

    $tmplText = Get-Content -LiteralPath (Join-Path $root 'workflows\references\research-ship-templates.md') -Raw
    $rsWaveDocsOk = ($wfText -match 'check-wave -Partition') -and
                    ($wfText -match 'continue independent eligible units') -and
                    ($wfText -match 'last_wave:') -and
                    ($wfText -match '(?i)single-writer') -and
                    ($tmplText -match 'last_wave:') -and
                    ($tmplText -match '(?i)single-writer') -and
                    ($gatesText -match 'check-wave -Partition') -and
                    ($gatesText -match '(?i)single-writer')

    if ($rsWavePsOk -and $rsWaveShOk -and $rsWaveDocsOk) {
        Pass 'research-wave-partition-and-blocked-isolation'
    } else {
        FailCheck 'research-wave-partition-and-blocked-isolation' "ps=$rsWavePsOk sh=$rsWaveShOk docs=$rsWaveDocsOk"
    }
}
finally {
    if ($null -eq $prevModelsPersonal) { Remove-Item Env:B3_MODELS_PERSONAL -ErrorAction SilentlyContinue } else { $env:B3_MODELS_PERSONAL = $prevModelsPersonal }
    $env:PATH = $prevPathEnv
    if ($null -eq $prevMockGhDir) { Remove-Item Env:B3_TEST_GH_DIR -ErrorAction SilentlyContinue } else { $env:B3_TEST_GH_DIR = $prevMockGhDir }
    Pop-Location -ErrorAction SilentlyContinue
    Remove-ReparseLinksUnder $sandbox
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Complete-ValidationSuite -AllowIncompleteBash:$AllowIncompleteBash
