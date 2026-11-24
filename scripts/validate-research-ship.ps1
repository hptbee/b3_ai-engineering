# Behavioral checks for /b3-research-ship across PowerShell and Git Bash.
# Covers research evidence freshness, governance fail-closed rules, namespace/wave orchestration, PR/merge gates, and 4-host adapter compatibility.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate-research-ship.ps1
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

function Init-TestRepo([string]$DirPath) {
    New-Item -ItemType Directory -Path $DirPath -Force | Out-Null
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        Push-Location $DirPath
        & git init -q
        & git symbolic-ref HEAD refs/heads/main
        & git config user.email 'research-test@example.com'
        & git config user.name 'Research Test'
    } finally {
        Pop-Location -ErrorAction SilentlyContinue
        $ErrorActionPreference = $prev
    }
}

function Remove-ReparseLinksUnder([string]$DirPath) {
    if (-not (Test-Path -LiteralPath $DirPath)) { return }
    $rootItem = Get-Item -LiteralPath $DirPath -Force -ErrorAction SilentlyContinue
    if (-not $rootItem) { return }
    if ((($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) -or ($rootItem.LinkType -in @('Junction', 'SymbolicLink'))) {
        if ($rootItem.PSIsContainer) { [System.IO.Directory]::Delete($rootItem.FullName, $false) }
        else { Remove-Item -LiteralPath $rootItem.FullName -Force -ErrorAction SilentlyContinue }
        return
    }
    if (-not $rootItem.PSIsContainer) { return }
    foreach ($child in @(Get-ChildItem -LiteralPath $rootItem.FullName -Force -ErrorAction SilentlyContinue)) {
        if ((($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) -or ($child.LinkType -in @('Junction', 'SymbolicLink'))) {
            if ($child.PSIsContainer) { [System.IO.Directory]::Delete($child.FullName, $false) }
            else { Remove-Item -LiteralPath $child.FullName -Force -ErrorAction SilentlyContinue }
        } elseif ($child.PSIsContainer) {
            Remove-ReparseLinksUnder $child.FullName
        }
    }
}

$sandbox = Join-Path $env:TEMP ('b3-research-ship-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox | Out-Null
$prevModelsPersonal = $env:B3_MODELS_PERSONAL
$env:B3_MODELS_PERSONAL = Join-Path $sandbox 'personal-models.md'

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
    if ($hasBash) {
        Set-Content (Join-Path $rEv 'sources\secondary.md') "# Secondary Source`nClause B`n" -NoNewline
        $wSh = Invoke-ShGuard "'$guardShPosix' evidence-check --repo-root '$rEvPosix' --write-manifest --manifest-path '.b3/research-ship/runs/r1/evidence/sources-sh.manifest' --source-paths 'sources/primary.md,sources/secondary.md'"
        $fSh = Invoke-ShGuard "'$guardShPosix' evidence-check --repo-root '$rEvPosix' --manifest-path '.b3/research-ship/runs/r1/evidence/sources-sh.manifest' --source-paths 'sources/primary.md,sources/secondary.md'"
        $uncSh = Invoke-ShGuard "'$guardShPosix' evidence-check --repo-root '$rEvPosix' --manifest-path '.b3/research-ship/runs/r1/evidence/sources-sh.manifest' --source-paths 'sources/primary.md,sources/extra.md'"
        $caseSh = Invoke-ShGuard "'$guardShPosix' evidence-check --repo-root '$rEvPosix' --manifest-path '.b3/research-ship/runs/r1/evidence/sources-sh.manifest' --source-paths 'Sources/Primary.md'"
        $travSh = Invoke-ShGuard "'$guardShPosix' evidence-check --repo-root '$rEvPosix' --manifest-path '../escape.manifest'"
        $juncSh = Invoke-ShGuard "'$guardShPosix' evidence-check --repo-root '$rEvPosix' --write-manifest --manifest-path 'linked-out/esc-sh.manifest' --source-paths 'sources/primary.md'"
        Add-Content (Join-Path $rEv 'sources\secondary.md') "drift`n"
        $stSh = Invoke-ShGuard "'$guardShPosix' evidence-check --repo-root '$rEvPosix' --manifest-path '.b3/research-ship/runs/r1/evidence/sources-sh.manifest'"
        Remove-Item (Join-Path $rEv 'sources\secondary.md') -Force
        $missSh = Invoke-ShGuard "'$guardShPosix' evidence-check --repo-root '$rEvPosix' --manifest-path '.b3/research-ship/runs/r1/evidence/sources-sh.manifest'"
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

    # Explicit authorized policy
    Set-Content (Join-Path $rGov '.b3\auth-policy.json') (@{
        auto_merge = 'authorized'
        protected_paths = @('releases/')
        allow_protected_paths = $false
        require_ci = $true
        require_review = $true
    } | ConvertTo-Json)
    $authOk = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PolicyPath', '.b3/auth-policy.json', '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS', '-ChangedPaths', 'docs/notes.md')
    $authProtFail = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PolicyPath', '.b3/auth-policy.json', '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS', '-ChangedPaths', 'releases/v3.json')
    $omitChangedFail = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PolicyPath', '.b3/auth-policy.json', '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS')

    # Malformed & type-mismatched / injection policy JSON checks
    Set-Content (Join-Path $rGov '.b3\bad-policy.json') '{ broken json'
    Set-Content (Join-Path $rGov '.b3\arr-policy.json') '[1]'
    Set-Content (Join-Path $rGov '.b3\num-policy.json') '123'
    Set-Content (Join-Path $rGov '.b3\arr-am-policy.json') '{"auto_merge":["authorized"]}'
    Set-Content (Join-Path $rGov '.b3\str-pp-policy.json') '{"protected_paths":"releases/"}'
    Set-Content (Join-Path $rGov '.b3\nl-pp-policy.json') '{"auto_merge":"disabled","protected_paths":["foo\nauto_merge=authorized\nrequire_ci=false"]}'
    $badJson = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PolicyPath', '.b3/bad-policy.json', '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS')
    $badRootArr = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PolicyPath', '.b3/arr-policy.json', '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS')
    $badRootNum = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PolicyPath', '.b3/num-policy.json', '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS')
    $badAmArr = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PolicyPath', '.b3/arr-am-policy.json', '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS')
    $badPpStr = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PolicyPath', '.b3/str-pp-policy.json', '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS')
    $badPpNl = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PolicyPath', '.b3/nl-pp-policy.json', '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS', '-ChangedPaths', 'docs/notes.md')

    # Default .b3/research-policy.json junction escape check in isolated repo
    $rDefJunc = Join-Path $sandbox 'def-junc-repo'
    $rDefJuncPosix = $rDefJunc -replace '\\', '/'
    $outPolDir = Join-Path $sandbox 'outside-pol'
    New-Item -ItemType Directory -Path $rDefJunc, $outPolDir -Force | Out-Null
    Set-Content (Join-Path $outPolDir 'research-policy.json') '{"auto_merge":"authorized"}'
    New-Item -ItemType Junction -Path (Join-Path $rDefJunc '.b3') -Target $outPolDir | Out-Null
    $defJuncPs = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rDefJunc, '-PrState', 'OPEN', '-CiStatus', 'PASS', '-ReviewStatus', 'PASS')

    # Post-merge verification: merge featSha into main and test ancestor vs non-ancestor
    Push-Location $rGov
    & git merge --no-ff -qm 'merge feat' $featSha | Out-Null
    Pop-Location
    $postOk = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PostMerge', '-PrState', 'MERGED', '-MergedSha', $featSha, '-MainRef', 'main')
    $postFalse = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PostMerge', '-PrState', 'MERGED', '-MergedSha', $sideSha, '-MainRef', 'main')
    $postOpen = Invoke-PsGuard @('merge-policy-check', '-RepoRoot', $rGov, '-PostMerge', '-PrState', 'OPEN', '-MergedSha', $featSha, '-MainRef', 'main')

    $govShOk = $true
    if ($hasBash) {
        $shDisabled = Invoke-ShGuard "'$guardShPosix' merge-policy-check --repo-root '$rGovPosix' --pr-state OPEN --ci-status PASS --review-status PASS --changed-paths docs/notes.md"
        $shWithheld = Invoke-ShGuard "'$guardShPosix' merge-policy-check --repo-root '$rGovPosix' --pr-state OPEN --ci-status PASS --review-status PASS --governance-status WITHHELD_PROMOTION"
        $shProt = Invoke-ShGuard "'$guardShPosix' merge-policy-check --repo-root '$rGovPosix' --policy-path .b3/auth-policy.json --pr-state OPEN --ci-status PASS --review-status PASS --changed-paths releases/v3.json"
        $shOmitChanged = Invoke-ShGuard "'$guardShPosix' merge-policy-check --repo-root '$rGovPosix' --policy-path .b3/auth-policy.json --pr-state OPEN --ci-status PASS --review-status PASS"
        $shAuth = Invoke-ShGuard "'$guardShPosix' merge-policy-check --repo-root '$rGovPosix' --policy-path .b3/auth-policy.json --pr-state OPEN --ci-status PASS --review-status PASS --changed-paths docs/notes.md"
        $shBadJson = Invoke-ShGuard "'$guardShPosix' merge-policy-check --repo-root '$rGovPosix' --policy-path .b3/bad-policy.json --pr-state OPEN --ci-status PASS --review-status PASS"
        $shBadNl = Invoke-ShGuard "'$guardShPosix' merge-policy-check --repo-root '$rGovPosix' --policy-path .b3/nl-pp-policy.json --pr-state OPEN --ci-status PASS --review-status PASS --changed-paths docs/notes.md"
        $shDefJunc = Invoke-ShGuard "'$guardShPosix' merge-policy-check --repo-root '$rDefJuncPosix' --pr-state OPEN --ci-status PASS --review-status PASS"
        $shPostOk = Invoke-ShGuard "'$guardShPosix' merge-policy-check --repo-root '$rGovPosix' --post-merge --pr-state MERGED --merged-sha '$featSha' --main-ref main"
        $shPostBad = Invoke-ShGuard "'$guardShPosix' merge-policy-check --repo-root '$rGovPosix' --post-merge --pr-state MERGED --merged-sha '$sideSha' --main-ref main"
        $govShOk = ($shDisabled.Code -eq 2 -and $shDisabled.Text -match 'PR_READY: auto_merge=disabled') -and
                   ($shWithheld.Code -eq 1 -and $shWithheld.Text -match 'WITHHELD_PROMOTION') -and
                   ($shProt.Code -eq 1 -and $shProt.Text -match 'protected_paths=releases/v3\.json') -and
                   ($shOmitChanged.Code -eq 1 -and $shOmitChanged.Text -match 'missing_changed_paths') -and
                   ($shAuth.Code -eq 0 -and $shAuth.Text -match 'MERGE_AUTHORIZED') -and
                   ($shBadJson.Code -eq 1 -and $shBadJson.Text -match 'invalid_policy_json') -and
                   ($shBadNl.Code -eq 1 -and $shBadNl.Text -match 'invalid_policy_json') -and
                   ($shDefJunc.Code -eq 1 -and $shDefJunc.Text -match 'invalid_policy_path') -and
                   ($shPostOk.Code -eq 0 -and $shPostOk.Text -match 'POST_MERGE_VERIFIED' -and $shPostOk.Text -match 'deployed=NOT_VERIFIED') -and
                   ($shPostBad.Code -eq 1 -and $shPostBad.Text -match 'POST_MERGE_FAILED')
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
        ($authOk.Code -eq 0 -and $authOk.Text -match 'MERGE_AUTHORIZED') -and
        ($authProtFail.Code -eq 1 -and $authProtFail.Text -match 'protected_paths') -and
        ($omitChangedFail.Code -eq 1 -and $omitChangedFail.Text -match 'missing_changed_paths') -and
        ($badJson.Code -eq 1 -and $badJson.Text -match 'invalid_policy_json') -and
        ($badRootArr.Code -eq 1 -and $badRootArr.Text -match 'invalid_policy_json') -and
        ($badRootNum.Code -eq 1 -and $badRootNum.Text -match 'invalid_policy_json') -and
        ($badAmArr.Code -eq 1 -and $badAmArr.Text -match 'invalid_policy_json') -and
        ($badPpStr.Code -eq 1 -and $badPpStr.Text -match 'invalid_policy_json') -and
        ($badPpNl.Code -eq 1 -and $badPpNl.Text -match 'invalid_policy_json') -and
        ($defJuncPs.Code -eq 1 -and $defJuncPs.Text -match 'invalid_policy_path') -and
        ($postOk.Code -eq 0 -and $postOk.Text -match 'POST_MERGE_VERIFIED' -and $postOk.Text -match 'runtime_served=NOT_VERIFIED' -and $postOk.Text -match 'deployed=NOT_VERIFIED') -and
        ($postFalse.Code -eq 1 -and $postFalse.Text -match 'POST_MERGE_FAILED') -and
        ($postOpen.Code -eq 1 -and $postOpen.Text -match 'POST_MERGE_FAILED') -and $govShOk) {
        Pass 'governance-and-merge-policy-gates'
    } else {
        FailCheck 'governance-and-merge-policy-gates' "noPol=$($noPol.Code) missOwner=$($missOwner.Code) protHit=$($protHit.Code) omitChg=$($omitChangedFail.Code) badTypes=$($badRootArr.Code)/$($badRootNum.Code)/$($badAmArr.Code)/$($badPpStr.Code)/$($badPpNl.Code) defJunc=$($defJuncPs.Code) postOk=$($postOk.Code) sh=$govShOk"
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
    if ($hasBash) {
        $shNew = Invoke-ShGuard "'$guardShPosix' new-run --repo-root '$rNsPosix' --namespace research-ship --slug bash-pass --timestamp 20261123-0101"
        Set-Content (Join-Path $rNs '.b3\research-ship\runs\20261123-0101-bash-pass\progress.md') "- run_status: PASS`n"
        $shNew2 = Invoke-ShGuard "'$guardShPosix' new-run --repo-root '$rNsPosix' --namespace research-ship --slug bash-pass2 --timestamp 20261123-0102"
        Set-Content (Join-Path $rNs '.b3\research-ship\runs\20261123-0102-bash-pass2\progress.md') "- run_status: PASS`n"
        $shPrune = Invoke-ShGuard "'$guardShPosix' prune --repo-root '$rNsPosix' --namespace research-ship --keep 0"
        $shRes = Invoke-ShGuard "'$guardShPosix' resolve-run --repo-root '$rNsPosix' --namespace research-ship"
        $shList = Invoke-ShGuard "'$guardShPosix' list-runs --repo-root '$rNsPosix' --namespace research-ship"
        $shEmptyShip = Invoke-ShGuard "'$guardShPosix' resolve-run --repo-root '$rNsPosix' --namespace ship"
        $shDs = Invoke-ShGuard "'$guardShPosix' diff-scope --repo-root '$rNsPosix' --base-sha '$nsBase'"
        $shWaveOk = Invoke-ShGuard "'$guardShPosix' check-wave --repo-root '$rNsPosix' --expected-base-sha '$nsBase' --wave-specs 'U001=research/u1.md;U002=research/u2.md' --wave-reads 'U001=sources/a.md;U002=sources/b.md'"
        $shWaveCon = Invoke-ShGuard "'$guardShPosix' check-wave --repo-root '$rNsPosix' --expected-base-sha '$nsBase' --wave-specs 'U001=research/u1.md,ledger/index.json;U002=research/u2.md,ledger/index.json'"
        Push-Location $rNs
        & git add -f '.b3/research-ship/runs/20261123-0100-star-compare/progress.md'
        $shPc = Invoke-ShGuard "'$guardShPosix' precommit --repo-root '$rNsPosix' --allowed-paths '.b3/research-ship'"
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
    if ($hasBash) {
        $shVr = Invoke-ShGuard "'$guardShPosix' verify-run --repo-root '$rNsPosix' --verify-cmd 'echo verified' --receipt-path '.b3/research-ship/runs/vr-sh.receipt' --task-id U001 --scope research-check"
        Set-Content (Join-Path $rNs '.b3\research-ship\runs\extra-sh-checkpoint.md') "# checkpoint note sh`n"
        $shVc = Invoke-ShGuard "'$guardShPosix' verify-check --repo-root '$rNsPosix' --receipt-path '.b3/research-ship/runs/vr-sh.receipt'"
        $rPrSh = Join-Path $sandbox 'prune-rs-sh'
        $rPrShPosix = $rPrSh -replace '\\', '/'
        $rLinkRunsPosix = $rLinkRuns -replace '\\', '/'
        Init-TestRepo $rPrSh
        Set-Content (Join-Path $rPrSh 'a.txt') "a`n"
        Push-Location $rPrSh; & git add .; & git commit -qm 'init'; Pop-Location
        [void](Invoke-ShGuard "'$guardShPosix' new-run --repo-root '$rPrShPosix' --namespace research-ship --slug old-sh --timestamp 20261123-0202")
        $oldShDir = Join-Path $rPrSh '.b3\research-ship\runs\20261123-0202-old-sh'
        Set-Content (Join-Path $oldShDir 'progress.md') "- run_status: PASS`n"
        New-Item -ItemType Junction -Path (Join-Path $oldShDir 'junc-out') -Target $decoyPrune | Out-Null
        [void](Invoke-ShGuard "'$guardShPosix' new-run --repo-root '$rPrShPosix' --namespace research-ship --slug cur-sh --timestamp 20261123-0203")
        Set-Content (Join-Path $rPrSh '.b3\research-ship\runs\20261123-0203-cur-sh\progress.md') "- run_status: PASS`n"
        $shPrSafe = Invoke-ShGuard "'$guardShPosix' prune --repo-root '$rPrShPosix' --namespace research-ship --keep 0"
        $shPrLink = Invoke-ShGuard "'$guardShPosix' prune --repo-root '$rLinkRunsPosix' --namespace research-ship --keep 0"
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

    $pluginOut = Join-Path $sandbox 'ag-plugin'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'adapters\antigravity\install-plugin.ps1') -PluginRoot $pluginOut -B3Home $root | Out-Null
    $pluginOk = ($LASTEXITCODE -eq 0) -and
                (Test-Path -LiteralPath (Join-Path $pluginOut 'skills\b3-research-ship\SKILL.md')) -and
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
    if ($hasBash) {
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
        $shInst = Invoke-ShGuard "'$rootPosix/adapters/install-product.sh' --product-root '$pShPosix' --b3-home '$rootPosix' --host codex"
        $shUpRes = Invoke-ShGuard "'$rootPosix/adapters/install-product.sh' --product-root '$giUpShPosix' --b3-home '$rootPosix' --host cursor"
        $shAppRes = Invoke-ShGuard "'$rootPosix/adapters/install-product.sh' --product-root '$giAppShPosix' --b3-home '$rootPosix' --host cursor"
        $shDryRes = Invoke-ShGuard "'$rootPosix/adapters/install-product.sh' --product-root '$giUpShPosix' --b3-home '$rootPosix' --host cursor --dry-run"
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
}
finally {
    if ($null -eq $prevModelsPersonal) { Remove-Item Env:B3_MODELS_PERSONAL -ErrorAction SilentlyContinue } else { $env:B3_MODELS_PERSONAL = $prevModelsPersonal }
    Pop-Location -ErrorAction SilentlyContinue
    Remove-ReparseLinksUnder $sandbox
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed -gt 0) {
    Write-Output "$failed check(s) failed"
    exit 1
}
Write-Output 'ok'
exit 0
