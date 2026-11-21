# Behavioral checks for autodev hardening. Not a host skill-discovery test.
# Usage: powershell -File scripts/validate-autodev-behavior.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failed = 0

function Pass([string]$Name) { Write-Output "PASS $Name" }
function FailCheck([string]$Name, [string]$Detail) {
    Write-Output "FAIL $Name :: $Detail"
    $script:failed++
}

$sandbox = Join-Path $env:TEMP ("b3-autodev-behavior-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox | Out-Null
Push-Location $sandbox
try {
    # --- F4: empty invalid dest is replaced; nonempty dest fails ---
    $fx = Join-Path $sandbox 'sync-fx'
    New-Item -ItemType Directory -Path (Join-Path $fx 'adapters') | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fx '.cursor\skills\demo') | Out-Null
    Set-Content (Join-Path $fx '.cursor\skills\demo\SKILL.md') "---`nname: demo`ndescription: demo`n---`n# demo`n"
    Copy-Item (Join-Path $root 'adapters\sync-skills.ps1') (Join-Path $fx 'adapters\sync-skills.ps1')

    $empty = Join-Path $fx '.agents\skills'
    New-Item -ItemType Directory -Path $empty | Out-Null
    & powershell -NoProfile -File (Join-Path $fx 'adapters\sync-skills.ps1') -HostName codex
    if ($LASTEXITCODE -ne 0) {
        FailCheck 'sync-empty-dir' "exit $LASTEXITCODE"
    } else {
        $n = @(Get-ChildItem -LiteralPath $empty -Recurse -Filter 'SKILL.md' -File -ErrorAction SilentlyContinue).Count
        $item = Get-Item -LiteralPath $empty -Force
        $isLink = $item.LinkType -in @('Junction', 'SymbolicLink') -or (($item.Attributes.ToString()) -match 'ReparsePoint')
        if ($n -ge 1 -and $isLink) { Pass 'sync-empty-dir' }
        else { FailCheck 'sync-empty-dir' "LinkType=$($item.LinkType) attrs=$($item.Attributes) skillCount=$n" }
    }

    $fx2 = Join-Path $sandbox 'sync-fx-nonempty'
    New-Item -ItemType Directory -Path (Join-Path $fx2 'adapters') | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fx2 '.cursor\skills\demo') | Out-Null
    Set-Content (Join-Path $fx2 '.cursor\skills\demo\SKILL.md') "---`nname: demo`ndescription: demo`n---`n# demo`n"
    Copy-Item (Join-Path $root 'adapters\sync-skills.ps1') (Join-Path $fx2 'adapters\sync-skills.ps1')
    New-Item -ItemType Directory -Path (Join-Path $fx2 '.agents\skills') | Out-Null
    Set-Content (Join-Path $fx2 '.agents\skills\stale.txt') 'not a link'
    $err = $null
    try {
        & powershell -NoProfile -File (Join-Path $fx2 'adapters\sync-skills.ps1') -HostName codex 2>&1 | Out-Null
    } catch { $err = $_ }
    if ($LASTEXITCODE -ne 0 -or $err) { Pass 'sync-nonempty-refuse' }
    else { FailCheck 'sync-nonempty-refuse' 'exit 0 on nonempty invalid dest' }

    # --- F1 + F3: product install pointer, no skill copy, gitignore ---
    $product = Join-Path $sandbox 'product'
    New-Item -ItemType Directory -Path $product | Out-Null
    Push-Location $product
    git init -q
    git config user.email 'autodev-test@example.com'
    git config user.name 'Autodev Test'
    Set-Content README.md 'product'
    git add README.md
    git commit -qm 'init'
    Pop-Location

    & powershell -NoProfile -File (Join-Path $root 'adapters\install-product.ps1') -ProductRoot $product -B3Home $root -HostName cursor
    if ($LASTEXITCODE -ne 0) { FailCheck 'install-product' "exit $LASTEXITCODE" }
    else {
        $homePath = (Get-Content (Join-Path $product '.b3\home') -Raw).Trim()
        $cmd = Join-Path $product '.cursor\commands\autodev.md'
        $copiedSkills = Test-Path (Join-Path $product '.cursor\skills')
        $gi = Get-Content (Join-Path $product '.gitignore') -Raw
        $giOk = ($gi -match '(?m)^\s*\.b3/autodev/\s*$') -or ($gi -match '(?m)^\s*\.b3/\s*$')
        if ($homePath -eq $root -and (Test-Path $cmd) -and -not $copiedSkills -and $giOk) {
            Pass 'install-product'
        } else {
            FailCheck 'install-product' "home=$homePath copiedSkills=$copiedSkills gitignoreMatch=$giOk"
        }

        & powershell -NoProfile -File (Join-Path $root 'adapters\install-product.ps1') -ProductRoot $product -B3Home $root -HostName cursor
        if ($LASTEXITCODE -eq 0) { Pass 'install-idempotent' }
        else { FailCheck 'install-idempotent' "exit $LASTEXITCODE on second identical install" }

        Set-Content $cmd 'custom autodev'
        $err = $null
        try {
            & powershell -NoProfile -File (Join-Path $root 'adapters\install-product.ps1') -ProductRoot $product -B3Home $root -HostName cursor 2>&1 | Out-Null
        } catch { $err = $_ }
        if ($LASTEXITCODE -ne 0 -or $err) {
            $after = Get-Content $cmd -Raw
            if ($after -match 'custom autodev') { Pass 'install-refuse-overwrite-command' }
            else { FailCheck 'install-refuse-overwrite-command' 'file was changed' }
        } else {
            FailCheck 'install-refuse-overwrite-command' 'exit 0 overwrote custom autodev.md'
        }
        Copy-Item (Join-Path $root 'adapters\product-autodev.md') $cmd -Force

        & powershell -NoProfile -File (Join-Path $root 'adapters\install-product.ps1') -ProductRoot $product -B3Home $root -HostName codex
        if ($LASTEXITCODE -ne 0) { FailCheck 'install-product-codex' "exit $LASTEXITCODE" }
        else {
            $agentsLink = Join-Path $product '.agents\skills'
            $item = Get-Item -LiteralPath $agentsLink -Force
            $isTreeLink = $item.LinkType -in @('Junction', 'SymbolicLink')
            $autodevOk = Test-Path (Join-Path $agentsLink 'autodev\SKILL.md')
            $planningOk = Test-Path (Join-Path $agentsLink 'planning\SKILL.md')
            $skillN = @(Get-ChildItem -LiteralPath $agentsLink -Directory -Force -ErrorAction SilentlyContinue).Count
            $giCodex = Get-Content (Join-Path $product '.gitignore') -Raw
            $agentsMdOk = Test-Path (Join-Path $product 'AGENTS.md')
            $giSkillOk = ($giCodex -match '(?m)^\s*\.agents/skills\s*$')
            if ((-not $isTreeLink) -and $autodevOk -and $planningOk -and $skillN -ge 24 -and $agentsMdOk -and $giSkillOk) { Pass 'install-product-codex' }
            else { FailCheck 'install-product-codex' "treeLink=$isTreeLink autodev=$autodevOk planning=$planningOk skills=$skillN agentsMd=$agentsMdOk gi=$giSkillOk" }
        }
    }

    Push-Location $product
    New-Item -ItemType Directory -Path '.b3\autodev' -Force | Out-Null
    Set-Content '.b3\autodev\progress.md' 'secret-checkpoint'
    Set-Content 'app.js' 'module.exports = 1'
    git add -A
    $cached = git diff --cached --name-only
    if ($cached | Where-Object { $_ -match '^\.b3/autodev/' }) { FailCheck 'checkpoint-not-staged' "cached=`n$cached" }
    else { Pass 'checkpoint-not-staged' }
    git add app.js
    git commit -qm 'add app'
    $show = git ls-tree -r --name-only HEAD
    if ($show | Where-Object { $_ -match '^\.b3/autodev/' }) { FailCheck 'checkpoint-not-in-commit' "tree=`n$show" }
    else { Pass 'checkpoint-not-in-commit' }

    # --- F5: SHA exists but is not ancestor ---
    $tree = git rev-parse 'HEAD^{tree}'
    $orphan = git commit-tree $tree -m 'orphan'
    $head = git rev-parse HEAD
    git cat-file -t $orphan | Out-Null
    git merge-base --is-ancestor $orphan $head
    if ($LASTEXITCODE -ne 0) { Pass 'sha-not-ancestor' }
    else { FailCheck 'sha-not-ancestor' 'orphan unexpectedly ancestor of HEAD' }

    git merge-base --is-ancestor $head $head
    if ($LASTEXITCODE -eq 0) { Pass 'sha-is-ancestor' }
    else { FailCheck 'sha-is-ancestor' 'HEAD is not ancestor of itself' }
    Pop-Location

    # --- F2 recipe present in workflow + progressive-disclosure references ---
    $wfMainPath = Join-Path $root 'workflows\autonomous-development.md'
    $wfResPath = Join-Path $root 'workflows\references\autodev-resume.md'
    $wfTplPath = Join-Path $root 'workflows\references\autodev-templates.md'
    $wfMain = Get-Content $wfMainPath -Raw
    $wfMainLines = @(Get-Content $wfMainPath).Count
    $wfCorpus = @($wfMain, (Get-Content $wfResPath -Raw), (Get-Content $wfTplPath -Raw)) -join "`n"
    $needles = @(
        'run_base_sha',
        'task_base',
        'git ls-files --others --exclude-standard',
        'git merge-base --is-ancestor',
        'git add -A',
        'B3_HOME',
        'Implementation Readiness Gate',
        'Just-in-Time',
        'approach_at_sha',
        'Evidence-based refinement',
        'Empty template headings are not evidence',
        'design-only',
        'watched_paths',
        'task_spec_fingerprint',
        'git diff --name-only {approach_at_sha}',
        're-run the Implementation Readiness Gate',
        'includes the working tree against that tree',
        'initial_dirty_paths',
        'baseline_status',
        'reuse:',
        'obsoletes:',
        'read_only_deps',
        'Invariants',
        'pre_fix_object',
        'autodev-guard'
    )
    $missing = @($needles | Where-Object { $wfCorpus -notlike "*$_*" })
    $linksOk = ($wfMain -match 'references/autodev-resume\.md') -and ($wfMain -match 'references/autodev-templates\.md')
    $sizeOk = ($wfMainLines -le 300)
    if ($missing.Count -eq 0 -and $linksOk -and $sizeOk) { Pass 'workflow-recipes' }
    else { FailCheck 'workflow-recipes' "missing=$($missing -join ', ') links=$linksOk lines=$wfMainLines" }

    $inlineOk = ($wfCorpus -match '(?m)^\s*- inspected:') -and ($wfCorpus -match '(?m)^\s*- changes:') -and ($wfCorpus -match '(?m)^\s*- data_flow:') -and ($wfCorpus -match '(?m)^\s*- watched_paths:') -and ($wfCorpus -match '(?m)^\s*- task_spec_fingerprint:') -and ($wfCorpus -match '(?m)^\s*- readiness: draft') -and ($wfCorpus -match '(?m)^\s*- reuse:') -and ($wfCorpus -match '(?m)^\s*- obsoletes:') -and ($wfCorpus -match '(?m)^\s*- read_only_deps:')
    if ($inlineOk) { Pass 'inline-template-fields' }
    else { FailCheck 'inline-template-fields' 'progress template missing inspected/changes/data_flow/watched_paths/fingerprint/draft/reuse/obsoletes/read_only_deps' }

    # Simulated Git freshness (not a live /autodev agent). Named-file change vs unrelated change.
    $fresh = Join-Path $sandbox 'freshness'
    New-Item -ItemType Directory -Path $fresh | Out-Null
    Push-Location $fresh
    git init -q
    git config user.email 'autodev-test@example.com'
    git config user.name 'Autodev Test'
    New-Item -ItemType Directory -Path src, docs | Out-Null
    Set-Content src\api.js 'exports.x = 1'
    Set-Content docs\NOTE.md 'n'
    git add src/api.js docs/NOTE.md
    git commit -qm 'base'
    $approachAt = git rev-parse HEAD
    Set-Content src\api.js 'exports.x = 2'
    git add src/api.js
    git commit -qm 'contract'
    $staleHit = git diff --name-only $approachAt HEAD
    if ($staleHit -match 'src/api.js') { Pass 'approach-stale-named-file' }
    else { FailCheck 'approach-stale-named-file' "diff=`n$staleHit" }
    git reset --hard $approachAt | Out-Null
    Set-Content docs\NOTE.md 'unrelated'
    git add docs/NOTE.md
    git commit -qm 'docs'
    $unrelated = git diff --name-only $approachAt HEAD
    $named = @('src/api.js')
    $hit = @($unrelated | Where-Object { $named -contains ($_ -replace '\\','/') -or $named -contains $_ })
    if ($hit.Count -eq 0 -and ($unrelated -match 'docs/NOTE.md')) { Pass 'approach-fresh-unrelated' }
    else { FailCheck 'approach-fresh-unrelated' "diff=`n$unrelated hit=$($hit -join ',')" }
    git reset --hard $approachAt | Out-Null
    New-Item -ItemType Directory -Path src\contracts -Force | Out-Null
    Set-Content src\contracts\order.ts 'export type Order = { id: string }'
    git add src/contracts/order.ts
    git commit -qm 'contract file'
    $approachAt2 = git rev-parse HEAD
    Set-Content src\contracts\order.ts 'export type Order = { id: string; v: 2 }'
    $headDiff = git diff --name-only $approachAt2 HEAD
    $wtDiff = git diff --name-only $approachAt2
    if ((-not $headDiff) -and ($wtDiff -match 'src/contracts/order.ts')) { Pass 'approach-stale-uncommitted-watched' }
    else { FailCheck 'approach-stale-uncommitted-watched' "HEAD=`n$headDiff`nWT=`n$wtDiff" }
    Pop-Location

    # --- Antigravity adapter checks ---
    $agVerifyOut = (& powershell -NoProfile -File (Join-Path $root 'adapters\sync-skills.ps1') -HostName antigravity -VerifyOnly) -join "`n"
    if ($LASTEXITCODE -eq 0 -and $agVerifyOut -match 'SKILL\.md entries visible') { Pass 'sync-antigravity-verify' }
    else { FailCheck 'sync-antigravity-verify' "exit=$LASTEXITCODE out=$agVerifyOut" }

    $agSyncFx = Join-Path $sandbox 'ag-sync-fx'
    New-Item -ItemType Directory -Path (Join-Path $agSyncFx 'adapters') | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $agSyncFx '.cursor\skills\eng\demo') | Out-Null
    Set-Content (Join-Path $agSyncFx '.cursor\skills\eng\demo\SKILL.md') "---`nname: demo`ndescription: demo`n---`n# demo`n"
    Copy-Item (Join-Path $root 'adapters\sync-skills.ps1') (Join-Path $agSyncFx 'adapters\sync-skills.ps1')
    & powershell -NoProfile -File (Join-Path $agSyncFx 'adapters\sync-skills.ps1') -HostName antigravity | Out-Null
    if ($LASTEXITCODE -ne 0) {
        FailCheck 'sync-antigravity-generate' "exit $LASTEXITCODE"
    } else {
        $manifestPath = Join-Path $agSyncFx '.agents\skills.json'
        $dupJunction = Test-Path -LiteralPath (Join-Path $agSyncFx '.agents\skills')
        $jsonOk = $false
        $entryOk = $false
        if (Test-Path -LiteralPath $manifestPath) {
            try {
                $m = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
                $jsonOk = $true
                $entryOk = (@($m.entries | ForEach-Object { $_.path }) -contains '.cursor/skills/eng')
            } catch { $jsonOk = $false }
        }
        & powershell -NoProfile -File (Join-Path $agSyncFx 'adapters\sync-skills.ps1') -HostName antigravity -VerifyOnly | Out-Null
        $verify2 = ($LASTEXITCODE -eq 0)
        if ($jsonOk -and $entryOk -and (-not $dupJunction) -and $verify2) { Pass 'sync-antigravity-generate' }
        else { FailCheck 'sync-antigravity-generate' "json=$jsonOk entry=$entryOk dupJunction=$dupJunction verify=$verify2" }
    }

    $agProduct = Join-Path $sandbox 'ag-product'
    New-Item -ItemType Directory -Path $agProduct | Out-Null
    Push-Location $agProduct
    git init -q
    git config user.email 'autodev-test@example.com'
    git config user.name 'Autodev Test'
    Set-Content README.md 'ag product'
    git add README.md
    git commit -qm 'init'
    Pop-Location

    & powershell -NoProfile -File (Join-Path $root 'adapters\install-product.ps1') -ProductRoot $agProduct -B3Home $root -HostName antigravity | Out-Null
    if ($LASTEXITCODE -ne 0) {
        FailCheck 'install-product-antigravity' "exit $LASTEXITCODE"
    } else {
        $agHomePath = (Get-Content (Join-Path $agProduct '.b3\home') -Raw).Trim()
        $agAgentsMd = Test-Path (Join-Path $agProduct 'AGENTS.md')
        $agGi = Get-Content (Join-Path $agProduct '.gitignore') -Raw
        $agGiOk = (($agGi -match '(?m)^\s*\.b3/autodev/\s*$') -or ($agGi -match '(?m)^\s*\.b3/\s*$')) -and ($agGi -match '(?m)^\s*\.agents/skills\s*$')
        $agSkillsDir = Join-Path $agProduct '.agents\skills'
        $agItem = Get-Item -LiteralPath $agSkillsDir -Force
        $agIsTreeLink = $agItem.LinkType -in @('Junction', 'SymbolicLink')
        $agSkillDirs = @(Get-ChildItem -LiteralPath $agSkillsDir -Directory -Force -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') })
        $agAutodevOk = Test-Path (Join-Path $agSkillsDir 'autodev\SKILL.md')
        $agPlanningOk = Test-Path (Join-Path $agSkillsDir 'planning\SKILL.md')
        & powershell -NoProfile -File (Join-Path $root 'adapters\install-product.ps1') -ProductRoot $agProduct -B3Home $root -HostName antigravity | Out-Null
        $agIdemOk = ($LASTEXITCODE -eq 0)
        if (($agHomePath -eq $root) -and $agAgentsMd -and $agGiOk -and (-not $agIsTreeLink) -and ($agSkillDirs.Count -ge 30) -and $agAutodevOk -and $agPlanningOk -and $agIdemOk) {
            Pass 'install-product-antigravity'
        } else {
            FailCheck 'install-product-antigravity' "home=$($agHomePath -eq $root) agentsMd=$agAgentsMd gi=$agGiOk treeLink=$agIsTreeLink skills=$($agSkillDirs.Count) autodev=$agAutodevOk planning=$agPlanningOk idem=$agIdemOk"
        }
    }

    $pluginDry = Join-Path $sandbox 'ag-plugin-dry'
    & powershell -NoProfile -File (Join-Path $root 'adapters\antigravity\install-plugin.ps1') -PluginRoot $pluginDry -B3Home $root -DryRun | Out-Null
    $dryOk = ($LASTEXITCODE -eq 0) -and (-not (Test-Path -LiteralPath $pluginDry))

    $pluginOut = Join-Path $sandbox 'ag-plugin-out'
    & powershell -NoProfile -File (Join-Path $root 'adapters\antigravity\install-plugin.ps1') -PluginRoot $pluginOut -B3Home $root | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not $dryOk) {
        FailCheck 'install-antigravity-plugin' "exit=$LASTEXITCODE dryOk=$dryOk"
    } else {
        $pjPath = Join-Path $pluginOut 'plugin.json'
        $pjOk = $false
        if (Test-Path -LiteralPath $pjPath) {
            try {
                $pj = Get-Content -LiteralPath $pjPath -Raw | ConvertFrom-Json
                $allowedKeys = @('name', 'displayName', 'version', 'description', 'suggestedPrompts')
                $propNames = @($pj.PSObject.Properties | ForEach-Object { $_.Name })
                $extraProps = @($propNames | Where-Object { $allowedKeys -notcontains $_ })
                $pjOk = ($pj.name -eq 'b3-ai-engineering') -and ($extraProps.Count -eq 0) -and (@($pj.suggestedPrompts).Count -eq 3)
            } catch { $pjOk = $false }
        }

        $rulesOutPath = Join-Path $pluginOut 'rules\AGENTS.md'
        $rulesOk = $false
        if (Test-Path -LiteralPath $rulesOutPath) {
            $rText = Get-Content -LiteralPath $rulesOutPath -Raw
            $rBytes = ([System.IO.File]::ReadAllBytes($rulesOutPath)).Length
            $noFm = -not ($rText.TrimStart() -match '^---')
            $hasAllRules = ($rText -match '# Engineering principles') -and ($rText -match '# Evidence and provenance') -and ($rText -match '# Portability') -and ($rText -match '# Simplest correct solution') -and ($rText -match '# Verification')
            $rulesOk = $noFm -and ($rBytes -lt 24000) -and $hasAllRules
        }

        $pSkillsDir = Join-Path $pluginOut 'skills'
        $pSkillDirs = @(Get-ChildItem -LiteralPath $pSkillsDir -Directory -Force -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') })
        $pSkillsOk = ($pSkillDirs.Count -ge 30)

        $pAgentsDir = Join-Path $pluginOut 'agents'
        $roAgents = @('reviewer.md', 'security-reviewer.md', 'architecture-reviewer.md', 'performance-reviewer.md')
        $agentsOk = $true
        foreach ($ro in $roAgents) {
            $ap = Join-Path $pAgentsDir $ro
            if (-not (Test-Path -LiteralPath $ap)) { $agentsOk = $false; break }
            $at = Get-Content -LiteralPath $ap -Raw
            if (($at -notmatch '(?m)^subagent:\s*true\s*$') -or ($at -notmatch '(?m)^mainAgent:\s*false\s*$') -or ($at -notmatch '(?m)^tools:\s*\[read_file\]\s*$') -or ($at -match 'edit_file|write_file')) {
                $agentsOk = $false
                break
            }
            if ($ro -eq 'performance-reviewer.md' -and ($at -notmatch 'Independent check for material performance risks')) {
                $agentsOk = $false
                break
            }
        }
        $fixerPath = Join-Path $pAgentsDir 'fixer.md'
        if (-not (Test-Path -LiteralPath $fixerPath)) { $agentsOk = $false }
        else {
            $ft = Get-Content -LiteralPath $fixerPath -Raw
            if (($ft -notmatch '(?m)^subagent:\s*true\s*$') -or ($ft -notmatch '(?m)^mainAgent:\s*false\s*$') -or ($ft -notmatch 'edit_file') -or ($ft -notmatch 'run_command')) {
                $agentsOk = $false
            }
        }

        & powershell -NoProfile -File (Join-Path $root 'adapters\antigravity\install-plugin.ps1') -PluginRoot $pluginOut -B3Home $root | Out-Null
        $pluginIdemOk = ($LASTEXITCODE -eq 0)

        $nonB3 = Join-Path $sandbox 'non-b3-dir'
        New-Item -ItemType Directory -Path $nonB3 | Out-Null
        Set-Content (Join-Path $nonB3 'keep.txt') 'other'
        $nonB3Err = $null
        try {
            & powershell -NoProfile -File (Join-Path $root 'adapters\antigravity\install-plugin.ps1') -PluginRoot $nonB3 -B3Home $root 2>&1 | Out-Null
        } catch { $nonB3Err = $_ }
        $refuseNonB3Ok = ($LASTEXITCODE -ne 0 -or $null -ne $nonB3Err) -and (Test-Path -LiteralPath (Join-Path $nonB3 'keep.txt'))

        if ($pjOk -and $rulesOk -and $pSkillsOk -and $agentsOk -and $pluginIdemOk -and $refuseNonB3Ok) {
            Pass 'install-antigravity-plugin'
        } else {
            FailCheck 'install-antigravity-plugin' "pj=$pjOk rules=$rulesOk skills=$pSkillsOk($($pSkillDirs.Count)) agents=$agentsOk idem=$pluginIdemOk refuse=$refuseNonB3Ok"
        }
    }

    # --- autodev-guard.ps1 checks ---
    $guardScript = Join-Path $root 'scripts\autodev-guard.ps1'
    $fpSorted = (& powershell -NoProfile -File $guardScript fingerprint -DependsOn 'T002, T001, T001' -Scope '  src/api  ' -Criteria 'AC1: ok; AC2: valid').Trim()
    $fpEmpty = (& powershell -NoProfile -File $guardScript fingerprint -Scope 'README.md' -Criteria 'AC1: documented').Trim()
    if ($fpSorted -eq 'depends_on=T001,T002|scope=src/api|acceptance_criteria=AC1: ok; AC2: valid' -and $fpEmpty -eq 'depends_on=[]|scope=README.md|acceptance_criteria=AC1: documented') {
        Pass 'guard-fingerprint'
    } else {
        FailCheck 'guard-fingerprint' "sorted=$fpSorted empty=$fpEmpty"
    }

    $guardRepo = Join-Path $sandbox 'guard-repo'
    New-Item -ItemType Directory -Path $guardRepo | Out-Null
    Push-Location $guardRepo
    git init -q
    git config user.email 'autodev-test@example.com'
    git config user.name 'Autodev Test'
    New-Item -ItemType Directory -Path src, docs | Out-Null
    Set-Content src\owned.js 'exports.a = 1'
    Set-Content src\contract.ts 'export type C = { id: string }'
    Set-Content docs\note.md 'note'
    git add .
    git commit -qm 'init'
    $gBase = git rev-parse HEAD

    # Fresh when unrelated + owned files change uncommitted; ignore dirty path respected
    Set-Content docs\note.md 'unrelated dirty'
    Set-Content src\owned.js 'exports.a = 2'
    $f1 = (& powershell -NoProfile -File $guardScript check-freshness -RepoRoot $guardRepo -ApproachAtSha $gBase -TaskBaseSha $gBase -WatchedPaths 'src/owned.js,src/contract.ts' -OwnedFiles 'src/owned.js' -IgnoreDirtyPaths 'docs/note.md')
    $f1Exit = $LASTEXITCODE
    # Stale when read_only_deps changes uncommitted
    Set-Content src\contract.ts 'export type C = { id: number }'
    $f2 = (& powershell -NoProfile -File $guardScript check-freshness -RepoRoot $guardRepo -ApproachAtSha $gBase -TaskBaseSha $gBase -WatchedPaths 'src/owned.js,src/contract.ts' -OwnedFiles 'src/owned.js' -IgnoreDirtyPaths 'docs/note.md')
    $f2Exit = $LASTEXITCODE
    git checkout -- src/contract.ts
    # Stale when committed change hits watched_paths
    git add src/owned.js
    git commit -qm 'move owned'
    $f3 = (& powershell -NoProfile -File $guardScript check-freshness -RepoRoot $guardRepo -ApproachAtSha $gBase -TaskBaseSha $gBase -WatchedPaths 'src/owned.js,src/contract.ts' -OwnedFiles 'src/owned.js')
    $f3Exit = $LASTEXITCODE
    Pop-Location
    if ($f1Exit -eq 0 -and $f1 -eq 'FRESH' -and $f2Exit -eq 2 -and $f2 -match '^STALE: uncommitted' -and $f3Exit -eq 2 -and $f3 -match '^STALE: committed') {
        Pass 'guard-freshness'
    } else {
        FailCheck 'guard-freshness' "f1=(${f1Exit}:$f1) f2=(${f2Exit}:$f2) f3=(${f3Exit}:$f3)"
    }

    Push-Location $guardRepo
    git checkout -- docs/note.md
    # precommit: nothing staged -> fail
    $pc1 = (& powershell -NoProfile -File $guardScript precommit -RepoRoot $guardRepo -AllowedPaths 'src/owned.js')
    $pc1Exit = $LASTEXITCODE
    # precommit: checkpoint staged -> fail
    New-Item -ItemType Directory -Path '.b3\autodev' -Force | Out-Null
    Set-Content '.b3\autodev\progress.md' 'cp'
    git add -f '.b3\autodev\progress.md'
    $pc2 = (& powershell -NoProfile -File $guardScript precommit -RepoRoot $guardRepo -AllowedPaths 'src/owned.js')
    $pc2Exit = $LASTEXITCODE
    git reset -q HEAD '.b3\autodev\progress.md'
    # precommit: undeclared staged -> fail
    Set-Content docs\note.md 'extra'
    git add docs\note.md
    $pc3 = (& powershell -NoProfile -File $guardScript precommit -RepoRoot $guardRepo -AllowedPaths 'src/owned.js')
    $pc3Exit = $LASTEXITCODE
    git reset -q HEAD docs\note.md
    git checkout -- docs/note.md
    # precommit: allowed staged -> pass
    Set-Content src\owned.js 'exports.a = 3'
    git add src\owned.js
    $pc4 = (& powershell -NoProfile -File $guardScript precommit -RepoRoot $guardRepo -AllowedPaths 'src/owned.js')
    $pc4Exit = $LASTEXITCODE
    git reset -q HEAD src\owned.js
    # snapshot: dirty tracked -> commit sha != HEAD, clean stash list, work preserved
    $gHeadNow = (git rev-parse HEAD).Trim()
    $snapDirty = (& powershell -NoProfile -File $guardScript snapshot -RepoRoot $guardRepo).Trim()
    $snapDirtyExit = $LASTEXITCODE
    $stashEmpty = -not (git stash list)
    $workKept = (Get-Content src\owned.js -Raw) -match 'exports\.a = 3'
    git checkout -- src/owned.js
    $snapClean = (& powershell -NoProfile -File $guardScript snapshot -RepoRoot $guardRepo).Trim()
    $snapCleanExit = $LASTEXITCODE
    Pop-Location

    if ($pc1Exit -ne 0 -and $pc2Exit -ne 0 -and $pc2 -match 'checkpoint staged' -and $pc3Exit -ne 0 -and $pc3 -match 'undeclared staged' -and $pc4Exit -eq 0 -and $pc4 -eq 'PRECOMMIT_OK') {
        Pass 'guard-precommit'
    } else {
        FailCheck 'guard-precommit' "pc1=(${pc1Exit}:$pc1) pc2=(${pc2Exit}:$pc2) pc3=(${pc3Exit}:$pc3) pc4=(${pc4Exit}:$pc4)"
    }
    if ($snapDirtyExit -eq 0 -and $snapDirty -match '^[0-9a-f]{40}$' -and $snapDirty -ne $gHeadNow -and $stashEmpty -and $workKept -and $snapCleanExit -eq 0 -and $snapClean -eq $gHeadNow) {
        Pass 'guard-snapshot'
    } else {
        FailCheck 'guard-snapshot' "dirty=(${snapDirtyExit}:$snapDirty vs $gHeadNow) stashEmpty=$stashEmpty kept=$workKept clean=(${snapCleanExit}:$snapClean)"
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
