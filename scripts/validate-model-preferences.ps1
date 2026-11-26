# Lightweight behavioral checks for Markdown model preferences.
# Verifies example template, workflow references, installer init/preservation, missing-file fallback, gitignore, and zero always-on bloat.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate-model-preferences.ps1
param(
    [switch]$AllowIncompleteBash
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'lib\global-test-helpers.ps1')

$sandbox = Join-Path $env:TEMP ('b3-model-pref-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $sandbox | Out-Null
$prevPers = $env:B3_MODELS_PERSONAL
$prevSkip = $env:B3_SKIP_MODEL_INIT

try {
    $rootP = To-PosixPath $root

    # --- 1. models-example-exists ---
    $exPath = Join-Path $root 'config\models.example.md'
    $roles = @('main', 'planning', 'implementation', 'debugging', 'b3-reviewer', 'b3-fixer', 'b3-security-reviewer', 'b3-architecture-reviewer', 'b3-performance-reviewer')
    $obsolete = @('config\models.default.json', 'config\models.example.json', 'docs\model-configuration.md', 'scripts\validate-model-config.ps1')
    $exOk = Test-Path -LiteralPath $exPath -PathType Leaf
    if ($exOk) {
        $exTxt = Get-Content -LiteralPath $exPath -Raw
        foreach ($r in $roles) { if ($exTxt -notmatch [regex]::Escape("``$r``")) { $exOk = $false } }
        if ($exTxt -notmatch '\bauto\b' -or $exTxt -notmatch 'Never block workflows') { $exOk = $false }
    }
    foreach ($o in $obsolete) { if (Test-Path -LiteralPath (Join-Path $root $o)) { $exOk = $false } }
    if ($exOk) { Pass 'models-example-exists' } else { FailCheck 'models-example-exists' 'missing canonical roles/rules or obsolete JSON artifact present' }

    # --- 2. workflow-references ---
    $shipTxt = Get-Content -LiteralPath (Join-Path $root 'workflows\ship.md') -Raw
    $stratTxt = Get-Content -LiteralPath (Join-Path $root 'review-loop\strategy.md') -Raw
    $dnTxt = Get-Content -LiteralPath (Join-Path $root 'workflows\references\dispatch-naming.md') -Raw
    $modTxt = Get-Content -LiteralPath (Join-Path $root 'review-loop\models.md') -Raw
    $docPath = Join-Path $root 'docs\model-preferences.md'
    $docOk = Test-Path -LiteralPath $docPath -PathType Leaf
    $docTxt = if ($docOk) { Get-Content -LiteralPath $docPath -Raw } else { '' }
    $refsOk = ($shipTxt -match 'dispatch-naming\.md' -and $shipTxt -match 'models\.md') -and
              ($stratTxt -match 'dispatch-naming\.md' -and $stratTxt -match 'models\.md') -and
              ($dnTxt -match 'models\.md' -and $dnTxt -match '\bauto\b') -and
              ($modTxt -match 'models\.example\.md' -and $modTxt -match 'model-preferences\.md') -and
              $docOk -and ($docTxt -match 'Cursor') -and ($docTxt -match 'Antigravity') -and ($docTxt -match 'Codex') -and ($docTxt -match 'Claude Code') -and ($docTxt -match 'models\.local\.json')
    $staleHits = @()
    foreach ($dir in @('AGENTS.md', 'README.md', 'adapters', 'agents', 'commands', 'docs', 'review-loop', 'rules', 'scripts', 'workflows')) {
        $p = Join-Path $root $dir
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $files = @(Get-ChildItem -LiteralPath $p -Recurse -File | Where-Object { $_.Name -ne 'validate-model-preferences.ps1' })
        $hits = if ($files.Count -gt 0) { Select-String -Path $files -Pattern 'resolve-models|models\.default\.json|models\.example\.json|model-configuration\.md|validate-model-config' -ErrorAction SilentlyContinue } else { @() }
        if ($hits) { $staleHits += $hits }
    }
    if ($refsOk -and $staleHits.Count -eq 0) { Pass 'workflow-references' } else { FailCheck 'workflow-references' "refsOk=$refsOk stale=$($staleHits.Count)" }

    # --- 3. installer-seed-and-preserve ---
    $prodPs = Join-Path $sandbox 'prod-ps'
    New-Item -ItemType Directory -Path $prodPs | Out-Null
    Push-Location $prodPs
    & git init -q; & git config user.email 't@e.com'; & git config user.name 'T'
    Set-Content 'README.md' "# P`n"; & git add .; & git commit -qm 'init'
    Pop-Location

    $persPs = Join-Path $sandbox 'home-ps\.b3\models.md'
    $env:B3_MODELS_PERSONAL = $persPs
    Remove-Item Env:B3_SKIP_MODEL_INIT -ErrorAction SilentlyContinue
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'adapters\install-product.ps1') -ProductRoot $prodPs -B3Home $root -HostName cursor -DryRun | Out-Null
    $dryClean = -not (Test-Path -LiteralPath $persPs)
    $env:B3_SKIP_MODEL_INIT = '1'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'adapters\install-product.ps1') -ProductRoot $prodPs -B3Home $root -HostName cursor | Out-Null
    $skipClean = -not (Test-Path -LiteralPath $persPs)
    Remove-Item Env:B3_SKIP_MODEL_INIT -ErrorAction SilentlyContinue
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'adapters\install-product.ps1') -ProductRoot $prodPs -B3Home $root -HostName cursor | Out-Null
    $ipCreated = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $persPs -PathType Leaf) -and ((Get-Content -LiteralPath $persPs -Raw) -match 'B3 Model Preferences') -and (-not (Test-Path -LiteralPath (Join-Path $prodPs '.b3\models.md')))
    Set-Content -LiteralPath $persPs "# Custom`n| `planning` | custom-reasoner |`n"
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'adapters\install-product.ps1') -ProductRoot $prodPs -B3Home $root -HostName cursor | Out-Null
    $ipPreserved = ((Get-Content -LiteralPath $persPs -Raw) -match 'custom-reasoner')

    $syncFx = Join-Path $sandbox 'sync-fx'
    New-Item -ItemType Directory -Path (Join-Path $syncFx 'adapters\lib'), (Join-Path $syncFx 'config'), (Join-Path $syncFx 'skills\eng\demo'), (Join-Path $syncFx 'commands'), (Join-Path $syncFx 'agents') | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'adapters\sync-skills.ps1') -Destination (Join-Path $syncFx 'adapters\sync-skills.ps1')
    Copy-Item -LiteralPath (Join-Path $root 'adapters\sync-skills.sh') -Destination (Join-Path $syncFx 'adapters\sync-skills.sh')
    Copy-Item -LiteralPath (Join-Path $root 'adapters\lib\global-common.ps1') -Destination (Join-Path $syncFx 'adapters\lib\global-common.ps1')
    Copy-Item -LiteralPath (Join-Path $root 'adapters\lib\global-common.sh') -Destination (Join-Path $syncFx 'adapters\lib\global-common.sh')
    Copy-Item -LiteralPath $exPath -Destination (Join-Path $syncFx 'config\models.example.md')
    Set-Content -LiteralPath (Join-Path $syncFx 'skills\eng\demo\SKILL.md') "---`nname: demo`ndescription: d`n---`n# d`n"
    Set-Content -LiteralPath (Join-Path $syncFx 'commands\b3-plan.md') "# p`n"
    Set-Content -LiteralPath (Join-Path $syncFx 'agents\b3-reviewer.md') "# r`n"

    $syncPersPs = Join-Path $sandbox 'sync-ps\.b3\models.md'
    $env:B3_MODELS_PERSONAL = $syncPersPs
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $syncFx 'adapters\sync-skills.ps1') -HostName cursor | Out-Null
    $syncPsSeed = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $syncPersPs -PathType Leaf)
    Set-Content -LiteralPath $syncPersPs "keep-sync-ps"
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $syncFx 'adapters\sync-skills.ps1') -HostName cursor | Out-Null
    $syncPsKeep = ((Get-Content -LiteralPath $syncPersPs -Raw) -match 'keep-sync-ps')

    $shOk = $true
    if ($script:HasBash) {
        $prodSh = Join-Path $sandbox 'prod-sh'
        New-Item -ItemType Directory -Path $prodSh | Out-Null
        Push-Location $prodSh
        & git init -q; & git config user.email 't@e.com'; & git config user.name 'T'
        Set-Content 'README.md' "# S`n"; & git add .; & git commit -qm 'init'
        Pop-Location
        $persSh = Join-Path $sandbox 'home-sh\.b3\models.md'
        $persShP = To-PosixPath $persSh; $prodShP = To-PosixPath $prodSh; $syncFxP = To-PosixPath $syncFx
        $env:B3_MODELS_PERSONAL = $persShP
        & $script:GitBash -c "'$rootP/adapters/install-product.sh' --product-root '$prodShP' --b3-home '$rootP' --host cursor --dry-run" | Out-Null
        $shDryClean = -not (Test-Path -LiteralPath $persSh)
        & $script:GitBash -c "'$rootP/adapters/install-product.sh' --product-root '$prodShP' --b3-home '$rootP' --host cursor" | Out-Null
        $shIpSeed = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $persSh -PathType Leaf)
        Set-Content -LiteralPath $persSh "keep-sh-custom"
        & $script:GitBash -c "'$rootP/adapters/install-product.sh' --product-root '$prodShP' --b3-home '$rootP' --host cursor" | Out-Null
        $shIpKeep = ((Get-Content -LiteralPath $persSh -Raw) -match 'keep-sh-custom')

        $syncPersSh = Join-Path $sandbox 'sync-sh\.b3\models.md'
        $env:B3_MODELS_PERSONAL = To-PosixPath $syncPersSh
        & $script:GitBash -c "'$syncFxP/adapters/sync-skills.sh' --verify antigravity >/dev/null 2>&1"
        $shVerClean = -not (Test-Path -LiteralPath $syncPersSh)
        & $script:GitBash -c "'$syncFxP/adapters/sync-skills.sh' antigravity" | Out-Null
        $shSyncSeed = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $syncPersSh -PathType Leaf)
        Set-Content -LiteralPath $syncPersSh "keep-sync-sh"
        & $script:GitBash -c "'$syncFxP/adapters/sync-skills.sh' antigravity" | Out-Null
        $shSyncKeep = ((Get-Content -LiteralPath $syncPersSh -Raw) -match 'keep-sync-sh')
        $shOk = $shDryClean -and $shIpSeed -and $shIpKeep -and $shVerClean -and $shSyncSeed -and $shSyncKeep
    }
    if ($dryClean -and $skipClean -and $ipCreated -and $ipPreserved -and $syncPsSeed -and $syncPsKeep -and $shOk) {
        Pass 'installer-seed-and-preserve'
    } else {
        FailCheck 'installer-seed-and-preserve' "dry=$dryClean skip=$skipClean cr=$ipCreated keep=$ipPreserved sPs=$syncPsSeed/$syncPsKeep sh=$shOk"
    }

    # --- 4. missing-file-fallback ---
    $env:B3_MODELS_PERSONAL = Join-Path $sandbox 'does-not-exist\.b3\models.md'
    $fpPsOut = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\b3-guard.ps1') fingerprint -Scope 'demo' -Criteria @('ac1')
    $fpPsOk = ($LASTEXITCODE -eq 0) -and (($fpPsOut -join "`n") -match 'scope=demo')
    $fpShOk = $true
    if ($script:HasBash) {
        $fpShOut = & $script:GitBash -c "'$rootP/scripts/b3-guard.sh' fingerprint --scope 'demo' --criterion 'ac1'"
        $fpShOk = ($LASTEXITCODE -eq 0) -and (($fpShOut -join "`n") -match 'scope=demo')
    }
    $fallbackDocs = ($dnTxt -match 'Never block work on missing or malformed') -and ($docTxt -match 'fall back to native model selection')
    if ($fpPsOk -and $fpShOk -and $fallbackDocs) { Pass 'missing-file-fallback' } else { FailCheck 'missing-file-fallback' "ps=$fpPsOk sh=$fpShOk docs=$fallbackDocs" }

    # --- 5. gitignore-behavior ---
    & git -C $root check-ignore -q '.b3/models.md'; $b3IgnoresMd = ($LASTEXITCODE -eq 0)
    & git -C $root check-ignore -q 'config/models.example.md'; $b3TracksEx = ($LASTEXITCODE -ne 0)
    & git -C $prodPs check-ignore -q '.b3/models.md'; $prodIgnoresMd = ($LASTEXITCODE -eq 0)
    & git -C $prodPs check-ignore -q '.b3/ship/run.md'; $prodIgnoresShip = ($LASTEXITCODE -eq 0)
    & git -C $prodPs check-ignore -q '.b3/home'; $prodTracksHome = ($LASTEXITCODE -ne 0)

    $env:B3_SKIP_MODEL_INIT = '1'
    $dedupOk = $true
    foreach ($pair in @(
        @{ Repo = 'gi-ps-leg'; Script = 'ps'; Init = ".b3/`n.b3/models.md`n" },
        @{ Repo = 'gi-sh-leg'; Script = 'sh'; Init = ".b3/`n.b3/models.md`n" },
        @{ Repo = 'gi-sh-only'; Script = 'sh'; Init = ".b3/models.md`n" }
    )) {
        if ($pair.Script -eq 'sh' -and -not $script:HasBash) { continue }
        $rDir = Join-Path $sandbox $pair.Repo
        New-Item -ItemType Directory -Path $rDir | Out-Null
        [IO.File]::WriteAllText((Join-Path $rDir '.gitignore'), $pair.Init, [System.Text.UTF8Encoding]::new($false))
        if ($pair.Script -eq 'ps') {
            & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'adapters\install-product.ps1') -ProductRoot $rDir -B3Home $root -HostName cursor | Out-Null
        } else {
            & $script:GitBash -c "'$rootP/adapters/install-product.sh' --product-root '$(To-PosixPath $rDir)' --b3-home '$rootP' --host cursor" | Out-Null
        }
        $lines = @(Get-Content -LiteralPath (Join-Path $rDir '.gitignore') | ForEach-Object { $_.Trim() })
        if (@($lines | Where-Object { $_ -eq '.b3/ship/' }).Count -ne 1 -or @($lines | Where-Object { $_ -eq '.b3/models.md' }).Count -ne 1) { $dedupOk = $false }
    }
    Remove-Item Env:B3_SKIP_MODEL_INIT -ErrorAction SilentlyContinue

    if ($b3IgnoresMd -and $b3TracksEx -and $prodIgnoresMd -and $prodIgnoresShip -and $prodTracksHome -and $dedupOk) {
        Pass 'gitignore-behavior'
    } else {
        FailCheck 'gitignore-behavior' "b3Ig=$b3IgnoresMd b3Tr=$b3TracksEx pMd=$prodIgnoresMd pSh=$prodIgnoresShip pHm=$prodTracksHome dedup=$dedupOk"
    }

    # --- 6. no-always-on-context-increase ---
    $mcOut = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\measure-context.ps1') -Strict
    $mcExit = $LASTEXITCODE
    $agentsTxt = Get-Content -LiteralPath (Join-Path $root 'AGENTS.md') -Raw
    $rulesHits = Select-String -Path (Get-ChildItem -LiteralPath (Join-Path $root 'rules') -Filter '*.md' -File) -Pattern 'models\.md|models\.example\.md|Preferred Model' -ErrorAction SilentlyContinue
    if ($mcExit -eq 0 -and ($agentsTxt -notmatch 'models\.md|models\.example\.md|Preferred Model') -and (-not $rulesHits)) {
        Pass 'no-always-on-context-increase'
    } else {
        FailCheck 'no-always-on-context-increase' "mcExit=$mcExit rulesHits=$($rulesHits.Count)"
    }
}
finally {
    if ($null -eq $prevPers) { Remove-Item Env:B3_MODELS_PERSONAL -ErrorAction SilentlyContinue } else { $env:B3_MODELS_PERSONAL = $prevPers }
    if ($null -eq $prevSkip) { Remove-Item Env:B3_SKIP_MODEL_INIT -ErrorAction SilentlyContinue } else { $env:B3_SKIP_MODEL_INIT = $prevSkip }
    Pop-Location -ErrorAction SilentlyContinue
    Remove-ReparseLinksUnder $sandbox
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Complete-ValidationSuite -AllowIncompleteBash:$AllowIncompleteBash