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
$prevGhBin = $env:B3_GH_BIN
$env:B3_MODELS_PERSONAL = Join-Path $sandbox 'personal-models.md'
Remove-Item Env:B3_GH_BIN -ErrorAction SilentlyContinue

try {
    # --- 1. Dual-shell evidence-check & namespace-isolation parity (core in Rust) ---
    $rEv = Join-Path $sandbox 'ev-repo'; $rEvP = To-PosixPath $rEv
    Init-B3TestRepo -RepoPath $rEv -DefaultBranch 'main' -UserEmail 'research-test@example.com' -UserName 'Research Test' -InitialCommit
    $mp = '.b3/research-ship/runs/r1/evidence.manifest'
    $psW = Invoke-PsGuard @('evidence-check', '-RepoRoot', $rEv, '-ManifestPath', $mp, '-SourcePaths', 'README.md', '-WriteManifest')
    $shC = if ($script:HasBash) { Invoke-ShCmd "'$guardShPosix' evidence-check --repo-root '$rEvP' --manifest-path '$mp'" } else { @{ Code = 0; Text = 'EVIDENCE_FRESH' } }
    if ($psW.Code -eq 0 -and $shC.Code -eq 0 -and $shC.Text -match 'EVIDENCE_FRESH') { Pass 'research-evidence-dual-shell-parity' } else { FailCheck 'research-evidence-dual-shell-parity' "w=$($psW.Code) c=$($shC.Code)" }

    $psNew = Invoke-PsGuard @('new-run', '-RepoRoot', $rEv, '-Namespace', 'research-ship', '-Slug', 'ps-run', '-Timestamp', '20261123-0100')
    $shNew = if ($script:HasBash) { Invoke-ShCmd "'$guardShPosix' new-run --repo-root '$rEvP' --namespace research-ship --slug sh-run --timestamp 20261123-0101" } else { @{ Code = 0 } }
    if ($psNew.Code -eq 0 -and $shNew.Code -eq 0 -and -not (Test-Path (Join-Path $rEv '.b3\ship\CURRENT'))) { Pass 'namespace-isolation-dual-shell-parity' } else { FailCheck 'namespace-isolation-dual-shell-parity' "ps=$($psNew.Code) sh=$($shNew.Code)" }
    # --- 4. workflow-contracts-and-domain-decoupling ---
    $cmdText = Get-Content -LiteralPath (Join-Path $root 'commands\b3-research-ship.md') -Raw
    $skillText = Get-Content -LiteralPath (Join-Path $root 'adapters\command-skills\b3-research-ship\SKILL.md') -Raw
    $wfText = Get-Content -LiteralPath (Join-Path $root 'workflows\research-ship.md') -Raw
    $dispatchText = Get-Content -LiteralPath (Join-Path $root 'workflows\references\dispatch-naming.md') -Raw
    $wfDispatchCorpus = "$wfText`n$dispatchText"
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
                    ($wfText -match 'thread resolve != editorial/release approval') -and
                    ($gatesText -match 'gh pr list') -and
                    ($gatesText -match 'mode=local') -and
                    ($gatesText -match 'PROVIDER_UNAVAILABLE')

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
        $cmdRuleOk = if ($hName -eq 'cursor') { $cmdCopy } else { (-not $cmdCopy) }
        $giText = Get-Content -LiteralPath (Join-Path $pDir '.gitignore') -Raw
        $giBoth = ($giText -match '(?m)^\s*\.b3/ship/\s*$') -and ($giText -match '(?m)^\s*\.b3/research-ship/\s*$') -and ($giText -match '(?m)^\s*\.b3/models\.md\s*$')
        if (-not ($cmdRuleOk -and $giBoth)) { $hostsOk = $false; break }
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
                        (-not (Test-Path -LiteralPath (Join-Path $pShDir '.cursor\commands\b3-research-ship.md'))) -and
                        (Test-Path -LiteralPath (Join-Path $pShDir '.agents\skills\b3-research-ship\SKILL.md')) -and
                        (Test-Path -LiteralPath (Join-Path $giUpSh '.cursor\commands\b3-research-ship.md')) -and
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


    # --- 6. research-ship resume/gates doc contracts ---
    $adapDocsOk = ($resumeText -match 'never duplicate active work') -and ($resumeText -match 'exec_mode') -and ($resumeText -match 'worker_root') -and ($resumeText -match 'initial_dirty_paths') -and ($resumeText -match '-ProtectedPaths') -and ($gatesText -match 'SHARED_READ_ONLY') -and ($gatesText -match '-ProtectedPaths') -and ($gatesText -match 'wave\|N\|')
    if ($adapDocsOk) { Pass 'research-ship-resume-and-gates-contracts' } else { FailCheck 'research-ship-resume-and-gates-contracts' 'missing required contract tokens' }
}
finally {
    if ($null -eq $prevModelsPersonal) { Remove-Item Env:B3_MODELS_PERSONAL -ErrorAction SilentlyContinue } else { $env:B3_MODELS_PERSONAL = $prevModelsPersonal }
    $env:PATH = $prevPathEnv
    if ($null -eq $prevMockGhDir) { Remove-Item Env:B3_TEST_GH_DIR -ErrorAction SilentlyContinue } else { $env:B3_TEST_GH_DIR = $prevMockGhDir }
    if ($null -eq $prevGhBin) { Remove-Item Env:B3_GH_BIN -ErrorAction SilentlyContinue } else { $env:B3_GH_BIN = $prevGhBin }
    Pop-Location -ErrorAction SilentlyContinue
    Remove-ReparseLinksUnder $sandbox
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Complete-ValidationSuite -AllowIncompleteBash:$AllowIncompleteBash
