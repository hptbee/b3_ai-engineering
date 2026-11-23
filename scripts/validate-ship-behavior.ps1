# Behavioral checks for ship hardening. Not a host skill-discovery test.
# Usage: powershell -File scripts/validate-ship-behavior.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failed = 0
. (Join-Path $PSScriptRoot 'lib\global-test-helpers.ps1')

function Pass([string]$Name) { Write-Output "PASS $Name" }
function FailCheck([string]$Name, [string]$Detail) {
    Write-Output "FAIL $Name :: $Detail"
    $script:failed++
}

$sandbox = Join-Path $env:TEMP ("b3-ship-behavior-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox | Out-Null
$prevModelsPersonal = $env:B3_MODELS_PERSONAL
$env:B3_MODELS_PERSONAL = Join-Path $sandbox 'personal-models.md'
Push-Location $sandbox
try {
    # --- F4: empty invalid dest is replaced; nonempty dest fails; cursor sync & coexistence guard ---
    $fx = Join-Path $sandbox 'sync-fx'
    New-Item -ItemType Directory -Path (Join-Path $fx 'adapters') | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fx 'skills\eng\demo') | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fx 'commands') | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fx 'agents') | Out-Null
    Set-Content (Join-Path $fx 'skills\eng\demo\SKILL.md') "---`nname: demo`ndescription: demo`n---`n# demo`n"
    Set-Content (Join-Path $fx 'commands\b3-plan.md') '# b3-plan'
    Set-Content (Join-Path $fx 'agents\b3-reviewer.md') '# b3-reviewer'
    Copy-Item (Join-Path $root 'adapters\sync-skills.ps1') (Join-Path $fx 'adapters\sync-skills.ps1')

    $empty = Join-Path $fx '.agents\skills'
    New-Item -ItemType Directory -Path $empty | Out-Null
    & powershell -NoProfile -File (Join-Path $fx 'adapters\sync-skills.ps1') -HostName codex
    if ($LASTEXITCODE -ne 0) {
        FailCheck 'sync-empty-dir' "exit $LASTEXITCODE"
    } else {
        $demoLink = Join-Path $empty 'demo'
        $skillOk = Test-Path -LiteralPath (Join-Path $demoLink 'SKILL.md') -PathType Leaf
        $item = Get-Item -LiteralPath $demoLink -Force -ErrorAction SilentlyContinue
        $isLink = $item -and ($item.LinkType -in @('Junction', 'SymbolicLink') -or (($item.Attributes.ToString()) -match 'ReparsePoint'))
        if ($skillOk -and $isLink) { Pass 'sync-empty-dir' }
        else { FailCheck 'sync-empty-dir' "demoLink=$isLink skillOk=$skillOk" }
    }

    # Coexistence guard: cursor sync must fail specifically on coexistence guard when .agents/skills exists
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $coexOut = (& powershell -NoProfile -File (Join-Path $fx 'adapters\sync-skills.ps1') -HostName cursor 2>&1 | Out-String)
    $coexExit = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    $coexNoCursor = -not (Test-Path -LiteralPath (Join-Path $fx '.cursor\skills'))
    if ($coexExit -ne 0 -and ($coexOut -match 'coexistence guard') -and $coexNoCursor) { Pass 'sync-coexistence-guard' }
    else { FailCheck 'sync-coexistence-guard' "exit=$coexExit noCursor=$coexNoCursor out=$coexOut" }

    # Cursor sync on clean fixture
    $fxCur = Join-Path $sandbox 'sync-fx-cursor'
    New-Item -ItemType Directory -Path (Join-Path $fxCur 'adapters') | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fxCur 'skills\eng\demo') | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fxCur 'commands') | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fxCur 'agents') | Out-Null
    Set-Content (Join-Path $fxCur 'skills\eng\demo\SKILL.md') "---`nname: demo`ndescription: demo`n---`n# demo`n"
    Set-Content (Join-Path $fxCur 'commands\b3-plan.md') '# b3-plan'
    Set-Content (Join-Path $fxCur 'agents\b3-reviewer.md') '# b3-reviewer'
    Copy-Item (Join-Path $root 'adapters\sync-skills.ps1') (Join-Path $fxCur 'adapters\sync-skills.ps1')
    & powershell -NoProfile -File (Join-Path $fxCur 'adapters\sync-skills.ps1') -HostName cursor | Out-Null
    $curSyncExit = $LASTEXITCODE
    & powershell -NoProfile -File (Join-Path $fxCur 'adapters\sync-skills.ps1') -HostName cursor -VerifyOnly | Out-Null
    $curVerifyExit = $LASTEXITCODE
    if ($curSyncExit -eq 0 -and $curVerifyExit -eq 0) { Pass 'sync-cursor' }
    else { FailCheck 'sync-cursor' "sync=$curSyncExit verify=$curVerifyExit" }

    # Claude sync on clean fixture
    $fxCl = Join-Path $sandbox 'sync-fx-claude'
    New-Item -ItemType Directory -Path (Join-Path $fxCl 'adapters') | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fxCl 'skills\eng\demo') | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fxCl 'agents') | Out-Null
    Set-Content (Join-Path $fxCl 'skills\eng\demo\SKILL.md') "---`nname: demo`ndescription: demo`n---`n# demo`n"
    Set-Content (Join-Path $fxCl 'agents\b3-reviewer.md') '# b3-reviewer'
    Copy-Item (Join-Path $root 'adapters\sync-skills.ps1') (Join-Path $fxCl 'adapters\sync-skills.ps1')
    & powershell -NoProfile -File (Join-Path $fxCl 'adapters\sync-skills.ps1') -HostName claude | Out-Null
    $clSyncExit = $LASTEXITCODE
    & powershell -NoProfile -File (Join-Path $fxCl 'adapters\sync-skills.ps1') -HostName claude -VerifyOnly | Out-Null
    $clVerifyExit = $LASTEXITCODE
    if ($clSyncExit -eq 0 -and $clVerifyExit -eq 0) { Pass 'sync-claude' }
    else { FailCheck 'sync-claude' "sync=$clSyncExit verify=$clVerifyExit" }

    $fx2 = Join-Path $sandbox 'sync-fx-nonempty'
    New-Item -ItemType Directory -Path (Join-Path $fx2 'adapters') | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fx2 'skills\eng\demo') | Out-Null
    Set-Content (Join-Path $fx2 'skills\eng\demo\SKILL.md') "---`nname: demo`ndescription: demo`n---`n# demo`n"
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
    git config user.email 'ship-test@example.com'
    git config user.name 'Ship Test'
    Set-Content README.md 'product'
    git add README.md
    git commit -qm 'init'
    Pop-Location

    & powershell -NoProfile -File (Join-Path $root 'adapters\install-product.ps1') -ProductRoot $product -B3Home $root -HostName cursor
    if ($LASTEXITCODE -ne 0) { FailCheck 'install-product' "exit $LASTEXITCODE" }
    else {
        $homePath = (Get-Content (Join-Path $product '.b3\home') -Raw).Trim()
        $cmd = Join-Path $product '.cursor\commands\b3-ship.md'
        $copiedSkills = Test-Path (Join-Path $product '.cursor\skills')
        $gi = Get-Content (Join-Path $product '.gitignore') -Raw
        $giOk = ($gi -match '(?m)^\s*\.b3/ship/\s*$') -or ($gi -match '(?m)^\s*\.b3/\s*$')
        if ($homePath -eq $root -and (Test-Path $cmd) -and -not $copiedSkills -and $giOk) {
            Pass 'install-product'
        } else {
            FailCheck 'install-product' "home=$homePath copiedSkills=$copiedSkills gitignoreMatch=$giOk"
        }

        & powershell -NoProfile -File (Join-Path $root 'adapters\install-product.ps1') -ProductRoot $product -B3Home $root -HostName cursor
        if ($LASTEXITCODE -eq 0) { Pass 'install-idempotent' }
        else { FailCheck 'install-idempotent' "exit $LASTEXITCODE on second identical install" }

        Set-Content $cmd 'custom ship'
        $err = $null
        try {
            & powershell -NoProfile -File (Join-Path $root 'adapters\install-product.ps1') -ProductRoot $product -B3Home $root -HostName cursor 2>&1 | Out-Null
        } catch { $err = $_ }
        if ($LASTEXITCODE -ne 0 -or $err) {
            $after = Get-Content $cmd -Raw
            if ($after -match 'custom ship') { Pass 'install-refuse-overwrite-command' }
            else { FailCheck 'install-refuse-overwrite-command' 'file was changed' }
        } else {
            FailCheck 'install-refuse-overwrite-command' 'exit 0 overwrote custom b3-ship.md'
        }
        Copy-Item (Join-Path $root 'commands\b3-ship.md') $cmd -Force

        & powershell -NoProfile -File (Join-Path $root 'adapters\install-product.ps1') -ProductRoot $product -B3Home $root -HostName codex
        if ($LASTEXITCODE -ne 0) { FailCheck 'install-product-codex' "exit $LASTEXITCODE" }
        else {
            $agentsLink = Join-Path $product '.agents\skills'
            $item = Get-Item -LiteralPath $agentsLink -Force
            $isTreeLink = $item.LinkType -in @('Junction', 'SymbolicLink')
            $shipOk = Test-Path (Join-Path $agentsLink 'b3-ship\SKILL.md')
            $planningOk = Test-Path (Join-Path $agentsLink 'planning\SKILL.md')
            $skillN = @(Get-ChildItem -LiteralPath $agentsLink -Directory -Force -ErrorAction SilentlyContinue).Count
            $giCodex = Get-Content (Join-Path $product '.gitignore') -Raw
            $agentsMdOk = Test-Path (Join-Path $product 'AGENTS.md')
            $giSkillOk = ($giCodex -match '(?m)^\s*\.agents/skills\s*$')
            if ((-not $isTreeLink) -and $shipOk -and $planningOk -and $skillN -ge 24 -and $agentsMdOk -and $giSkillOk) { Pass 'install-product-codex' }
            else { FailCheck 'install-product-codex' "treeLink=$isTreeLink ship=$shipOk planning=$planningOk skills=$skillN agentsMd=$agentsMdOk gi=$giSkillOk" }
        }
    }

    Push-Location $product
    New-Item -ItemType Directory -Path '.b3\ship' -Force | Out-Null
    Set-Content '.b3\ship\progress.md' 'secret-checkpoint'
    Set-Content 'app.js' 'module.exports = 1'
    git add -A
    $cached = git diff --cached --name-only
    if ($cached | Where-Object { $_ -match '^\.b3/ship/' }) { FailCheck 'checkpoint-not-staged' "cached=`n$cached" }
    else { Pass 'checkpoint-not-staged' }
    git add app.js
    git commit -qm 'add app'
    $show = git ls-tree -r --name-only HEAD
    if ($show | Where-Object { $_ -match '^\.b3/ship/' }) { FailCheck 'checkpoint-not-in-commit' "tree=`n$show" }
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
    $wfMainPath = Join-Path $root 'workflows\ship.md'
    $wfResPath = Join-Path $root 'workflows\references\ship-resume.md'
    $wfTplPath = Join-Path $root 'workflows\references\ship-templates.md'
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
        'b3-guard'
    )
    $missing = @($needles | Where-Object { $wfCorpus -notlike "*$_*" })
    $prTplExists = Test-Path -LiteralPath (Join-Path $root 'workflows\references\pr-template.md') -PathType Leaf
    $agentsRaw = Get-Content (Join-Path $root 'AGENTS.md') -Raw
    $linksOk = ($wfMain -match 'references/ship-resume\.md') -and ($wfMain -match 'references/ship-templates\.md') -and ($wfMain -match 'references/pr-template\.md') -and ($agentsRaw -match 'workflows/references/pr-template\.md') -and $prTplExists
    $spawnEveryOk = ($wfMain -notmatch 'on `>=2` ready') -and ($wfMain -match 'for \*\*every\*\* ready task')
    $sizeOk = ($wfMainLines -le 300)
    if ($missing.Count -eq 0 -and $linksOk -and $spawnEveryOk -and $sizeOk) { Pass 'workflow-recipes' }
    else { FailCheck 'workflow-recipes' "missing=$($missing -join ', ') links=$linksOk prTpl=$prTplExists spawnEvery=$spawnEveryOk lines=$wfMainLines" }

    $inlineOk = ($wfCorpus -match '(?m)^\s*- inspected:') -and ($wfCorpus -match '(?m)^\s*- files:') -and ($wfCorpus -match '(?m)^\s*- changes:') -and ($wfCorpus -match '(?m)^\s*- verification:') -and ($wfCorpus -match '(?m)^\s*- watched_paths:') -and ($wfCorpus -match '(?m)^\s*- task_spec_fingerprint:') -and ($wfCorpus -match '(?m)^\s*- readiness: draft') -and ($wfCorpus -match '(?m)^\s*- reuse:') -and ($wfCorpus -match '(?m)^\s*- obsoletes:') -and ($wfCorpus -match '(?m)^\s*- read_only_deps:')
    if ($inlineOk) { Pass 'inline-template-fields' }
    else { FailCheck 'inline-template-fields' 'progress template missing required lean inline fields' }

    # Simulated Git freshness (not a live /b3-ship agent). Named-file change vs unrelated change.
    $fresh = Join-Path $sandbox 'freshness'
    New-Item -ItemType Directory -Path $fresh | Out-Null
    Push-Location $fresh
    git init -q
    git config user.email 'ship-test@example.com'
    git config user.name 'Ship Test'
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
    New-Item -ItemType Directory -Path (Join-Path $agSyncFx 'skills\eng\demo') | Out-Null
    Set-Content (Join-Path $agSyncFx 'skills\eng\demo\SKILL.md') "---`nname: demo`ndescription: demo`n---`n# demo`n"
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
                $entryOk = (@($m.entries | ForEach-Object { $_.path }) -contains 'skills/eng')
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
    git config user.email 'ship-test@example.com'
    git config user.name 'Ship Test'
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
        $agGiOk = (($agGi -match '(?m)^\s*\.b3/ship/\s*$') -or ($agGi -match '(?m)^\s*\.b3/\s*$')) -and ($agGi -match '(?m)^\s*\.agents/skills\s*$')
        $agSkillsDir = Join-Path $agProduct '.agents\skills'
        $agItem = Get-Item -LiteralPath $agSkillsDir -Force
        $agIsTreeLink = $agItem.LinkType -in @('Junction', 'SymbolicLink')
        $agSkillDirs = @(Get-ChildItem -LiteralPath $agSkillsDir -Directory -Force -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') })
        $agShipOk = Test-Path (Join-Path $agSkillsDir 'b3-ship\SKILL.md')
        $agPlanningOk = Test-Path (Join-Path $agSkillsDir 'planning\SKILL.md')
        & powershell -NoProfile -File (Join-Path $root 'adapters\install-product.ps1') -ProductRoot $agProduct -B3Home $root -HostName antigravity | Out-Null
        $agIdemOk = ($LASTEXITCODE -eq 0)
        if (($agHomePath -eq $root) -and $agAgentsMd -and $agGiOk -and (-not $agIsTreeLink) -and ($agSkillDirs.Count -ge 30) -and $agShipOk -and $agPlanningOk -and $agIdemOk) {
            Pass 'install-product-antigravity'
        } else {
            FailCheck 'install-product-antigravity' "home=$($agHomePath -eq $root) agentsMd=$agAgentsMd gi=$agGiOk treeLink=$agIsTreeLink skills=$($agSkillDirs.Count) ship=$agShipOk planning=$agPlanningOk idem=$agIdemOk"
        }
    }

    $clProduct = Join-Path $sandbox 'claude-product'
    New-Item -ItemType Directory -Path $clProduct | Out-Null
    Push-Location $clProduct
    git init -q
    git config user.email 'ship-test@example.com'
    git config user.name 'Ship Test'
    Set-Content README.md 'claude product'
    git add README.md
    git commit -qm 'init'
    Pop-Location

    & powershell -NoProfile -File (Join-Path $root 'adapters\install-product.ps1') -ProductRoot $clProduct -B3Home $root -HostName claude | Out-Null
    if ($LASTEXITCODE -ne 0) {
        FailCheck 'install-product-claude' "exit $LASTEXITCODE"
    } else {
        $clHomePath = (Get-Content (Join-Path $clProduct '.b3\home') -Raw).Trim()
        $clMdOk = Test-Path (Join-Path $clProduct 'CLAUDE.md')
        $clAgentsMd = Test-Path (Join-Path $clProduct 'AGENTS.md')
        $clGi = Get-Content (Join-Path $clProduct '.gitignore') -Raw
        $clGiOk = ($clGi -match '(?m)^\s*\.b3/ship/\s*$') -and ($clGi -match '(?m)^\s*\.claude/skills\s*$') -and ($clGi -match '(?m)^\s*\.claude/agents\s*$')
        $clSkillsDir = Join-Path $clProduct '.claude\skills'
        $clSkillsItem = Get-Item -LiteralPath $clSkillsDir -Force
        $clIsTreeLink = $clSkillsItem.LinkType -in @('Junction', 'SymbolicLink')
        $clSkillDirs = @(Get-ChildItem -LiteralPath $clSkillsDir -Directory -Force -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') })
        $clAgentsLinkItem = Get-Item -LiteralPath (Join-Path $clProduct '.claude\agents') -Force -ErrorAction SilentlyContinue
        $clAgentsIsLink = $clAgentsLinkItem -and ($clAgentsLinkItem.LinkType -in @('Junction', 'SymbolicLink') -or (($clAgentsLinkItem.Attributes.ToString()) -match 'ReparsePoint'))
        $clAgentsOk = $clAgentsIsLink -and (Test-Path (Join-Path $clProduct '.claude\agents\b3-reviewer.md'))
        $clShipItem = Get-Item -LiteralPath (Join-Path $clSkillsDir 'b3-ship') -Force -ErrorAction SilentlyContinue
        $clShipIsLink = $clShipItem -and ($clShipItem.LinkType -in @('Junction', 'SymbolicLink') -or (($clShipItem.Attributes.ToString()) -match 'ReparsePoint'))
        $clShipOk = $clShipIsLink -and (Test-Path (Join-Path $clSkillsDir 'b3-ship\SKILL.md'))
        & powershell -NoProfile -File (Join-Path $root 'adapters\install-product.ps1') -ProductRoot $clProduct -B3Home $root -HostName claude | Out-Null
        $clIdemOk = ($LASTEXITCODE -eq 0)
        if (($clHomePath -eq $root) -and $clMdOk -and $clAgentsMd -and $clGiOk -and (-not $clIsTreeLink) -and ($clSkillDirs.Count -ge 30) -and $clAgentsOk -and $clShipOk -and $clIdemOk) {
            Pass 'install-product-claude'
        } else {
            FailCheck 'install-product-claude' "home=$($clHomePath -eq $root) claudeMd=$clMdOk agentsMd=$clAgentsMd gi=$clGiOk treeLink=$clIsTreeLink skills=$($clSkillDirs.Count) agents=$clAgentsOk ship=$clShipOk idem=$clIdemOk"
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
            $hasStrategyRef = ($rText -match 'review-loop/strategy\.md') -and ($rText -notmatch 'review-loop/spec\.md')
            $rulesOk = $noFm -and ($rBytes -lt 24000) -and $hasAllRules -and $hasStrategyRef
        }

        $pSkillsDir = Join-Path $pluginOut 'skills'
        $pSkillDirs = @(Get-ChildItem -LiteralPath $pSkillsDir -Directory -Force -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') })
        $pSkillsOk = ($pSkillDirs.Count -ge 30)

        $pAgentsDir = Join-Path $pluginOut 'agents'
        $roAgents = @('b3-reviewer.md', 'b3-security-reviewer.md', 'b3-architecture-reviewer.md', 'b3-performance-reviewer.md')
        $agentsOk = $true
        foreach ($ro in $roAgents) {
            $ap = Join-Path $pAgentsDir $ro
            if (-not (Test-Path -LiteralPath $ap)) { $agentsOk = $false; break }
            $at = Get-Content -LiteralPath $ap -Raw
            if (($at -notmatch '(?m)^subagent:\s*true\s*$') -or ($at -notmatch '(?m)^mainAgent:\s*false\s*$') -or ($at -notmatch '(?m)^tools:\s*\[read_file\]\s*$') -or ($at -match 'edit_file|write_file')) {
                $agentsOk = $false
                break
            }
            if ($ro -eq 'b3-performance-reviewer.md' -and ($at -notmatch 'Independent check for material performance risks')) {
                $agentsOk = $false
                break
            }
        }
        $fixerPath = Join-Path $pAgentsDir 'b3-fixer.md'
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

    # --- b3-guard.ps1 checks ---
    $guardScript = Join-Path $root 'scripts\b3-guard.ps1'
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
    git config user.email 'ship-test@example.com'
    git config user.name 'Ship Test'
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
    New-Item -ItemType Directory -Path '.b3\ship' -Force | Out-Null
    Set-Content '.b3\ship\progress.md' 'cp'
    git add -f '.b3\ship\progress.md'
    $pc2 = (& powershell -NoProfile -File $guardScript precommit -RepoRoot $guardRepo -AllowedPaths 'src/owned.js')
    $pc2Exit = $LASTEXITCODE
    git reset -q HEAD '.b3\ship\progress.md'
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

    # --- guard-diff-scope, run-scoped checkpoints & context-budget-strict ---
    Push-Location $guardRepo
    $dsHead = (git rev-parse HEAD).Trim()
    $dsEmpty = (& $guardScript diff-scope -RepoRoot $guardRepo -BaseSha $dsHead) -join "`n"
    $dsEmptyExit = $LASTEXITCODE
    Set-Content package-lock.json '{"lockfileVersion":3}'
    $dsNoise = (& $guardScript diff-scope -RepoRoot $guardRepo -BaseSha $dsHead) -join "`n"
    $dsNoiseExit = $LASTEXITCODE
    git mv src/owned.js src/renamed.js
    git add package-lock.json
    git commit -qm 'rename'
    $dsPrev = (git rev-parse HEAD).Trim()
    Set-Content src\extra.js 'exports.b = 5'
    Set-Content docs\note.md 'ignored dirty'
    $dsOut = (& $guardScript diff-scope -RepoRoot $guardRepo -BaseSha $dsHead -PrevSha $dsPrev -IgnoreDirtyPaths 'docs/note.md') -join "`n"
    $dsExit = $LASTEXITCODE
    Pop-Location

    $autoRepo = Join-Path $sandbox 'diff-scope-auto'
    New-Item -ItemType Directory -Path $autoRepo | Out-Null
    Push-Location $autoRepo
    git init -q -b main
    git config user.email 'ship-test@example.com'
    git config user.name 'Ship Test'
    Set-Content base.js 'exports.base = 1'
    git add base.js
    git commit -qm 'main base'
    git checkout -qb feat/auto-base
    Set-Content feat.js 'exports.feat = 2'
    git add feat.js
    git commit -qm 'feature commit'
    $dsAuto = (& $guardScript diff-scope -RepoRoot $autoRepo) -join "`n"
    $dsAutoExit = $LASTEXITCODE
    Pop-Location

    if ($dsEmptyExit -eq 2 -and $dsEmpty -match 'EMPTY_DIFF' -and
        $dsNoiseExit -eq 0 -and $dsNoise -match 'size_class=NOISE_ONLY' -and
        $dsExit -eq 0 -and $dsOut -match 'size_class=SMALL' -and
        ($dsOut -notmatch '=>') -and $dsOut -match 'src/renamed\.js' -and
        $dsOut -match 'noise_files=package-lock\.json' -and
        $dsOut -match 'delta_files=src/extra\.js' -and ($dsOut -notmatch 'docs/note\.md') -and
        $dsAutoExit -eq 0 -and $dsAuto -match 'size_class=SMALL' -and $dsAuto -match 'review_files=feat\.js') {
        Pass 'guard-diff-scope'
    } else {
        FailCheck 'guard-diff-scope' "empty=(${dsEmptyExit}:$dsEmpty) noise=(${dsNoiseExit}:$dsNoise) out=(${dsExit}:$dsOut) auto=(${dsAutoExit}:$dsAuto)"
    }

    $runRepo = Join-Path $sandbox 'run-scoped-repo'
    New-Item -ItemType Directory -Path $runRepo | Out-Null
    $r1 = (& powershell -NoProfile -File $guardScript new-run -RepoRoot $runRepo -Slug 'Add Billing / Webhook!' -Timestamp '20261122-0010').Trim()
    $r1Exit = $LASTEXITCODE
    $r2 = (& powershell -NoProfile -File $guardScript new-run -RepoRoot $runRepo -Slug 'Add Billing / Webhook!' -Timestamp '20261122-0010').Trim()
    $r2Exit = $LASTEXITCODE
    $curContent = (Get-Content -LiteralPath (Join-Path $runRepo '.b3\ship\CURRENT') -Raw).Trim()
    $resActive = (& powershell -NoProfile -File $guardScript resolve-run -RepoRoot $runRepo).Trim()
    $resActiveExit = $LASTEXITCODE
    $resExplicit = (& powershell -NoProfile -File $guardScript resolve-run -RepoRoot $runRepo -RunId $r1).Trim()
    $resExplicitExit = $LASTEXITCODE
    $listOut = ((& powershell -NoProfile -File $guardScript list-runs -RepoRoot $runRepo) -join "`n")

    $legacyRepo = Join-Path $sandbox 'legacy-repo'
    New-Item -ItemType Directory -Path (Join-Path $legacyRepo '.b3\ship') | Out-Null
    Set-Content (Join-Path $legacyRepo '.b3\ship\progress.md') "- run_status: running`n"
    $resLegacy = (& powershell -NoProfile -File $guardScript resolve-run -RepoRoot $legacyRepo).Trim()
    $resLegacyExit = $LASTEXITCODE

    if ($r1Exit -eq 0 -and $r1 -eq '20261122-0010-add-billing-webhook' -and
        $r2Exit -eq 0 -and $r2 -eq '20261122-0010-add-billing-webhook-2' -and
        $curContent -eq $r2 -and
        $resActiveExit -eq 0 -and $resActive -eq ".b3/ship/runs/$r2" -and
        $resExplicitExit -eq 0 -and $resExplicit -eq ".b3/ship/runs/$r1" -and
        ($listOut -match ('\* ' + [regex]::Escape($r2))) -and
        $resLegacyExit -eq 0 -and $resLegacy -eq '.b3/ship') {
        Pass 'guard-new-and-resolve-run'
    } else {
        FailCheck 'guard-new-and-resolve-run' "r1=(${r1Exit}:$r1) r2=(${r2Exit}:$r2) cur=$curContent active=(${resActiveExit}:$resActive) explicit=(${resExplicitExit}:$resExplicit) legacy=(${resLegacyExit}:$resLegacy)"
    }

    $pruneRepo = Join-Path $sandbox 'prune-repo'
    New-Item -ItemType Directory -Path $pruneRepo | Out-Null
    $p1 = (& powershell -NoProfile -File $guardScript new-run -RepoRoot $pruneRepo -Slug 'old-pass-1' -Timestamp '20261122-0001').Trim()
    $p2 = (& powershell -NoProfile -File $guardScript new-run -RepoRoot $pruneRepo -Slug 'old-pass-2' -Timestamp '20261122-0002').Trim()
    $p3 = (& powershell -NoProfile -File $guardScript new-run -RepoRoot $pruneRepo -Slug 'active-running' -Timestamp '20261122-0003').Trim()
    $p4 = (& powershell -NoProfile -File $guardScript new-run -RepoRoot $pruneRepo -Slug 'latest-pass' -Timestamp '20261122-0004').Trim()
    Set-Content (Join-Path $pruneRepo ".b3\ship\runs\$p1\progress.md") "- run_status: PASS`n"
    Set-Content (Join-Path $pruneRepo ".b3\ship\runs\$p2\progress.md") "- run_status: PASS`n"
    Set-Content (Join-Path $pruneRepo ".b3\ship\runs\$p3\progress.md") "- run_status: running`n"
    Set-Content (Join-Path $pruneRepo ".b3\ship\runs\$p4\progress.md") "- run_status: PASS`n"
    Set-Content (Join-Path $pruneRepo '.b3\ship\CURRENT') "$p1`n"

    $pruneOut = ((& powershell -NoProfile -File $guardScript prune -RepoRoot $pruneRepo -Keep 1) -join "`n")
    $pruneExit = $LASTEXITCODE
    $p1Kept = Test-Path -LiteralPath (Join-Path $pruneRepo ".b3\ship\runs\$p1")
    $p2Removed = -not (Test-Path -LiteralPath (Join-Path $pruneRepo ".b3\ship\runs\$p2"))
    $p3Kept = Test-Path -LiteralPath (Join-Path $pruneRepo ".b3\ship\runs\$p3")
    $p4Kept = Test-Path -LiteralPath (Join-Path $pruneRepo ".b3\ship\runs\$p4")
    if ($pruneExit -eq 0 -and $p1Kept -and $p2Removed -and $p3Kept -and $p4Kept -and $pruneOut -match 'PRUNE_OK: 1 removed') {
        Pass 'guard-prune-safe'
    } else {
        FailCheck 'guard-prune-safe' "exit=$pruneExit p1Kept=$p1Kept p2Removed=$p2Removed p3Kept=$p3Kept p4Kept=$p4Kept out=$pruneOut"
    }

    # --- R003 regression: prune must never follow nested or top-level reparse junctions ---
    $prLinkRoot = Join-Path $sandbox 'prune-reparse'
    $prDecoyNested = Join-Path $prLinkRoot 'decoy-nested'
    $prDecoyTop = Join-Path $prLinkRoot 'decoy-top'
    $prDecoyRuns = Join-Path $prLinkRoot 'decoy-runs'
    New-Item -ItemType Directory -Path $prDecoyNested, $prDecoyTop, $prDecoyRuns | Out-Null
    Set-Content (Join-Path $prDecoyNested 'keep1.txt') 'keep1'
    Set-Content (Join-Path $prDecoyTop 'keep2.txt') 'keep2'
    Set-Content (Join-Path $prDecoyTop 'progress.md') "- run_status: PASS`n"
    Set-Content (Join-Path $prDecoyRuns 'keep3.txt') 'keep3'

    $prPsRepo = Join-Path $prLinkRoot 'repo-ps'
    $pNest = (& powershell -NoProfile -File $guardScript new-run -RepoRoot $prPsRepo -Slug 'nested-pass' -Timestamp '20261122-0001').Trim()
    $pCurPs = (& powershell -NoProfile -File $guardScript new-run -RepoRoot $prPsRepo -Slug 'current-active' -Timestamp '20261122-0003').Trim()
    Set-Content (Join-Path $prPsRepo ".b3\ship\runs\$pNest\progress.md") "- run_status: PASS`n"
    Set-Content (Join-Path $prPsRepo ".b3\ship\runs\$pCurPs\progress.md") "- run_status: running`n"
    New-Item -ItemType Junction -Path (Join-Path $prPsRepo ".b3\ship\runs\$pNest\nested-junc") -Target $prDecoyNested | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $prPsRepo ".b3\ship\runs\20261122-0002-top-junc") -Target $prDecoyTop | Out-Null
    $prPsOut = ((& powershell -NoProfile -File $guardScript prune -RepoRoot $prPsRepo -Keep 0) -join "`n")
    $prPsExit = $LASTEXITCODE

    $prLinkRepoPs = Join-Path $prLinkRoot 'repo-runs-link-ps'
    New-Item -ItemType Directory -Path (Join-Path $prLinkRepoPs '.b3\ship') -Force | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $prLinkRepoPs '.b3\ship\runs') -Target $prDecoyRuns | Out-Null
    $prevEapPr = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $prLinkFailPs = ((& powershell -NoProfile -File $guardScript prune -RepoRoot $prLinkRepoPs -Keep 0 2>&1) -join "`n")
    $prLinkFailPsExit = $LASTEXITCODE
    $ErrorActionPreference = $prevEapPr

    $prRepShOk = $true
    $gitBashPr = 'C:\Program Files\Git\bin\bash.exe'
    if (Test-Path -LiteralPath $gitBashPr) {
        $guardShPosixPr = ($root -replace '\\', '/') + '/scripts/b3-guard.sh'
        $prShRepo = Join-Path $prLinkRoot 'repo-sh'
        $pNestSh = (& powershell -NoProfile -File $guardScript new-run -RepoRoot $prShRepo -Slug 'nested-pass-sh' -Timestamp '20261122-0001').Trim()
        $pCurSh = (& powershell -NoProfile -File $guardScript new-run -RepoRoot $prShRepo -Slug 'current-active-sh' -Timestamp '20261122-0003').Trim()
        Set-Content (Join-Path $prShRepo ".b3\ship\runs\$pNestSh\progress.md") "- run_status: PASS`n"
        Set-Content (Join-Path $prShRepo ".b3\ship\runs\$pCurSh\progress.md") "- run_status: running`n"
        New-Item -ItemType Junction -Path (Join-Path $prShRepo ".b3\ship\runs\$pNestSh\nested-junc") -Target $prDecoyNested | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $prShRepo ".b3\ship\runs\20261122-0002-top-junc") -Target $prDecoyTop | Out-Null
        $prShRepoPosix = $prShRepo -replace '\\', '/'
        $prShOut = (& $gitBashPr -c "'$guardShPosixPr' prune --repo-root '$prShRepoPosix' --keep 0") -join "`n"
        $prShExit = $LASTEXITCODE

        $prLinkRepoSh = Join-Path $prLinkRoot 'repo-runs-link-sh'
        New-Item -ItemType Directory -Path (Join-Path $prLinkRepoSh '.b3\ship') -Force | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $prLinkRepoSh '.b3\ship\runs') -Target $prDecoyRuns | Out-Null
        $prLinkShPosix = $prLinkRepoSh -replace '\\', '/'
        $prevEapPrSh = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $prLinkFailSh = (& $gitBashPr -c "'$guardShPosixPr' prune --repo-root '$prLinkShPosix' --keep 0 2>&1") -join "`n"
        $prLinkFailShExit = $LASTEXITCODE
        $ErrorActionPreference = $prevEapPrSh

        $prRepShOk = ($prShExit -eq 0) -and ($prShOut -match 'PRUNE_OK: 1 removed') -and
                     (-not (Test-Path -LiteralPath (Join-Path $prShRepo ".b3\ship\runs\$pNestSh"))) -and
                     ($prLinkFailShExit -eq 1) -and ($prLinkFailSh -match 'PRUNE_FAIL: runs directory is a link')
    }
    $decoysIntact = (Test-Path -LiteralPath (Join-Path $prDecoyNested 'keep1.txt')) -and
                    (Test-Path -LiteralPath (Join-Path $prDecoyTop 'keep2.txt')) -and
                    (Test-Path -LiteralPath (Join-Path $prDecoyRuns 'keep3.txt'))
    if ($prPsExit -eq 0 -and ($prPsOut -match 'PRUNE_OK: 1 removed') -and
        (-not (Test-Path -LiteralPath (Join-Path $prPsRepo ".b3\ship\runs\$pNest"))) -and
        $prLinkFailPsExit -eq 1 -and ($prLinkFailPs -match 'PRUNE_FAIL: runs directory is a link') -and
        $prRepShOk -and $decoysIntact) {
        Pass 'guard-prune-safe-reparse'
    } else {
        FailCheck 'guard-prune-safe-reparse' "ps=(${prPsExit}:$prPsOut) linkFailPs=(${prLinkFailPsExit}:$prLinkFailPs) sh=$prRepShOk decoys=$decoysIntact"
    }

    # --- R002 static regression: no shell-out junction operations in adapters and scripts ---
    $cmdHits = @()
    foreach ($dirRel in @('adapters', 'scripts')) {
        foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $root $dirRel) -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.sh') })) {
            foreach ($hit in @(Select-String -LiteralPath $f.FullName -Pattern 'cmd\.exe|cmd\s+/c|\bmklink\b' -ErrorAction SilentlyContinue)) {
                if ($hit.Line -match '^\s*#' -or $hit.Line -match 'Select-String' -or $hit.Line -match 'no-cmd-exe') { continue }
                $cmdHits += "$($f.Name):$($hit.LineNumber)"
            }
        }
    }
    if ($cmdHits.Count -eq 0) { Pass 'no-cmd-exe-junction-ops' }
    else { FailCheck 'no-cmd-exe-junction-ops' "hits=$($cmdHits -join ', ')" }

    $mechRepo = Join-Path $sandbox 'mech-repo'
    New-Item -ItemType Directory -Path $mechRepo | Out-Null
    Push-Location $mechRepo
    git init -q
    git config user.email 'ship-test@example.com'
    git config user.name 'Ship Test'
    New-Item -ItemType Directory -Path src | Out-Null
    Set-Content src\a.ts "export const a = 1;`nexport function oldFn() { return 1; }"
    Set-Content src\b.ts "import { oldFn } from './a';`nexport const b = oldFn();"
    Set-Content src\dead.ts "export const dead = 1;"
    git add .
    git commit -qm 'init'
    $mBase = (git rev-parse HEAD).Trim()
    Set-Content src\a.ts "export const a = 2;`nexport function oldFn() { return 2; }"
    $mClean = ((& powershell -NoProfile -File $guardScript mechanical-check -RepoRoot $mechRepo -BaseSha $mBase -AllowedPaths 'src/a.ts' -Obsoletes 'absentSym') -join "`n")
    $mCleanExit = $LASTEXITCODE
    $mkDbg = 'de' + 'bugger'
    $mkTs = '@ts-' + 'ignore'
    $mkOnly = '.on' + 'ly('
    Set-Content src\a.ts "export const a = 2;`n${mkDbg};`n// ${mkTs}"
    Set-Content src\unowned.ts "test${mkOnly}'x', () => {});"
    $mBad = ((& powershell -NoProfile -File $guardScript mechanical-check -RepoRoot $mechRepo -BaseSha $mBase -AllowedPaths 'src/a.ts' -Obsoletes 'src/dead.ts,oldFn') -join "`n")
    $mBadExit = $LASTEXITCODE
    Pop-Location
    if ($mCleanExit -eq 0 -and $mClean -match 'MECHANICAL_OK' -and
        $mBadExit -eq 2 -and $mBad -match 'scope_creep=src/unowned\.ts' -and
        $mBad -match "src/a\.ts:2:${mkDbg}" -and $mBad -match "src/a\.ts:3:${mkTs}" -and
        $mBad -match ('src/unowned\.ts:1:\.on' + 'ly\(') -and
        $mBad -match 'oldFn\(1f\)' -and $mBad -match 'src/dead\.ts\(exists\)') {
        Pass 'guard-mechanical-check'
    } else {
        FailCheck 'guard-mechanical-check' "clean=(${mCleanExit}:$mClean) bad=(${mBadExit}:$mBad)"
    }

    # --- -TargetRef / --target-ref tests (un-checked-out PR/branch commit with dirty+untracked WT) ---
    $trRepo = Join-Path $sandbox 'target-ref-repo'
    New-Item -ItemType Directory -Path $trRepo | Out-Null
    Push-Location $trRepo
    git init -q
    git config user.email 'ship-test@example.com'
    git config user.name 'Ship Test'
    New-Item -ItemType Directory -Path src | Out-Null
    Set-Content src\app.ts "export const v = 1;`nexport function legacyFn() { return 1; }"
    Set-Content src\legacy.ts "export const legacy = 1;"
    git add .
    git commit -qm 'main init'
    $trMain = (git rev-parse HEAD).Trim()
    git branch -M main
    git checkout -qb src
    Set-Content src\app.ts "export const v = 2;`n${mkDbg};`nexport function newFn() { return 2; }"
    git rm -q src/legacy.ts
    Set-Content src\pr-only.ts "export const pr = 1;"
    git add .
    git commit -qm 'pr commit'
    git checkout -q main
    # Dirty + untracked local working tree must NOT pollute TargetRef checks
    Set-Content src\app.ts "export const v = 999;"
    Set-Content src\wt-untracked.ts "test${mkOnly}'wt', () => {});"

    # Branch literally named 'src' collides with directory 'src/' unless resolved to SHA + '--'
    $trDsOut = ((& powershell -NoProfile -File $guardScript diff-scope -RepoRoot $trRepo -TargetRef 'src') -join "`n")
    $trDsExit = $LASTEXITCODE
    $trMcOut = ((& powershell -NoProfile -File $guardScript mechanical-check -RepoRoot $trRepo -TargetRef 'src' -AllowedPaths 'src/app.ts,src/pr-only.ts' -Obsoletes 'src/legacy.ts,legacyFn,newFn') -join "`n")
    $trMcExit = $LASTEXITCODE
    $trBadOut = ((& powershell -NoProfile -File $guardScript diff-scope -RepoRoot $trRepo -TargetRef 'nonexistent-ref-xyz') -join "`n")
    $trBadExit = $LASTEXITCODE
    $trDashOut = ((& powershell -NoProfile -File $guardScript diff-scope -RepoRoot $trRepo -TargetRef '--bad-flag') -join "`n")
    $trDashExit = $LASTEXITCODE

    $trShOk = $true
    $gitBash = 'C:\Program Files\Git\bin\bash.exe'
    if (Test-Path -LiteralPath $gitBash) {
        $guardShPosix = ($root -replace '\\', '/') + '/scripts/b3-guard.sh'
        $trRepoPosix = $trRepo -replace '\\', '/'
        $shDs = (& $gitBash -c "'$guardShPosix' diff-scope --repo-root '$trRepoPosix' --target-ref 'src'") -join "`n"
        $shDsExit = $LASTEXITCODE
        $shMc = (& $gitBash -c "'$guardShPosix' mechanical-check --repo-root '$trRepoPosix' --target-ref 'src' --allowed-paths 'src/app.ts,src/pr-only.ts' --obsoletes 'src/legacy.ts,legacyFn,newFn'") -join "`n"
        $shMcExit = $LASTEXITCODE
        $shDash = (& $gitBash -c "'$guardShPosix' mechanical-check --repo-root '$trRepoPosix' --target-ref '--bad-flag'") -join "`n"
        $shDashExit = $LASTEXITCODE
        $trShOk = ($shDsExit -eq 0) -and ($shDs -match 'review_files=src/app\.ts,src/legacy\.ts,src/pr-only\.ts') -and ($shDs -notmatch 'wt-untracked') -and
                  ($shMcExit -eq 2) -and ($shMc -match 'scope_creep=src/legacy\.ts') -and ($shMc -match "src/app\.ts:2:${mkDbg}") -and ($shMc -match 'obsolete_hits=newFn\(1f\)') -and ($shMc -notmatch 'legacyFn') -and ($shMc -notmatch 'src/legacy\.ts\(exists') -and
                  ($shDashExit -eq 1) -and ($shDash -match 'MECHANICAL_FAIL')
    }
    Pop-Location
    if ($trDsExit -eq 0 -and ($trDsOut -match 'review_files=src/app\.ts,src/legacy\.ts,src/pr-only\.ts') -and ($trDsOut -notmatch 'wt-untracked') -and
        $trMcExit -eq 2 -and ($trMcOut -match 'scope_creep=src/legacy\.ts') -and ($trMcOut -match "src/app\.ts:2:${mkDbg}") -and ($trMcOut -match 'obsolete_hits=newFn\(1f\)') -and ($trMcOut -notmatch 'legacyFn') -and ($trMcOut -notmatch 'src/legacy\.ts\(exists') -and
        $trBadExit -eq 1 -and ($trBadOut -match 'DIFF_SCOPE_FAIL') -and
        $trDashExit -eq 1 -and ($trDashOut -match 'DIFF_SCOPE_FAIL') -and $trShOk) {
        Pass 'guard-target-ref'
    } else {
        FailCheck 'guard-target-ref' "ds=(${trDsExit}:$trDsOut) mc=(${trMcExit}:$trMcOut) bad=(${trBadExit}:$trBadOut) dash=(${trDashExit}:$trDashOut) shOk=$trShOk"
    }

    $wOk = ((& powershell -NoProfile -File $guardScript check-wave -WaveSpecs 'T002=src/api/a.ts,./src/api/a.ts;T003=src/ui/b.tsx') -join "`n")
    $wOkExit = $LASTEXITCODE
    $wBad = ((& powershell -NoProfile -File $guardScript check-wave -WaveSpecs 'T002=src/api,.;T003=src/api/orders.ts') -join "`n")
    $wBadExit = $LASTEXITCODE
    if ($wOkExit -eq 0 -and $wOk -match 'WAVE_OK: disjoint \(2 tasks, 2 paths\)' -and
        $wBadExit -eq 2 -and $wBad -match 'WAVE_CONFLICT:' -and $wBad -match 'src/api<->src/api/orders\.ts' -and $wBad -match '\.<->src/api/orders\.ts') {
        Pass 'guard-check-wave'
    } else {
        FailCheck 'guard-check-wave' "ok=(${wOkExit}:$wOk) bad=(${wBadExit}:$wBad)"
    }

    # --- guard-size-boundary: <50 files and <2000 lines = LARGE; >=50 or >=2000 = VERY_LARGE ---
    $sbRepo = Join-Path $sandbox 'size-boundary-repo'
    New-Item -ItemType Directory -Path $sbRepo | Out-Null
    Push-Location $sbRepo
    git init -q
    git config user.email 'ship-test@example.com'
    git config user.name 'Ship Test'
    Set-Content README.md 'init'
    git add README.md
    git commit -qm 'init'
    New-Item -ItemType Directory -Path src | Out-Null
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $bigPath = Join-Path $sbRepo 'src\big.ts'
    [IO.File]::WriteAllText($bigPath, ("export const x = 1;`n" * 1999), $utf8NoBom)
    $sb1999 = ((& powershell -NoProfile -File $guardScript diff-scope -RepoRoot $sbRepo -BaseSha HEAD) -join "`n")
    $sb1999Exit = $LASTEXITCODE
    [IO.File]::WriteAllText($bigPath, ("export const x = 1;`n" * 2000), $utf8NoBom)
    $sb2000 = ((& powershell -NoProfile -File $guardScript diff-scope -RepoRoot $sbRepo -BaseSha HEAD) -join "`n")
    $sb2000Exit = $LASTEXITCODE
    Remove-Item -LiteralPath $bigPath -Force

    1..49 | ForEach-Object {
        [IO.File]::WriteAllText((Join-Path $sbRepo "src\f$_.ts"), "export const v$_ = $_;`n", $utf8NoBom)
    }
    $sb49 = ((& powershell -NoProfile -File $guardScript diff-scope -RepoRoot $sbRepo -BaseSha HEAD) -join "`n")
    $sb49Exit = $LASTEXITCODE
    [IO.File]::WriteAllText((Join-Path $sbRepo 'src\f50.ts'), "export const v50 = 50;`n", $utf8NoBom)
    $sb50 = ((& powershell -NoProfile -File $guardScript diff-scope -RepoRoot $sbRepo -BaseSha HEAD) -join "`n")
    $sb50Exit = $LASTEXITCODE

    $sbShOk = $true
    if (Test-Path -LiteralPath $gitBash) {
        $guardShPosix = ($root -replace '\\', '/') + '/scripts/b3-guard.sh'
        $sbRepoPosix = $sbRepo -replace '\\', '/'
        $sh50 = (& $gitBash -c "'$guardShPosix' diff-scope --repo-root '$sbRepoPosix' --base-sha HEAD") -join "`n"
        $sh50Exit = $LASTEXITCODE
        Remove-Item -LiteralPath (Join-Path $sbRepo 'src\f50.ts') -Force
        $sh49 = (& $gitBash -c "'$guardShPosix' diff-scope --repo-root '$sbRepoPosix' --base-sha HEAD") -join "`n"
        $sh49Exit = $LASTEXITCODE
        Remove-Item -LiteralPath (Join-Path $sbRepo 'src') -Recurse -Force
        New-Item -ItemType Directory -Path (Join-Path $sbRepo 'src') | Out-Null
        [IO.File]::WriteAllText($bigPath, ("export const x = 1;`n" * 2000), $utf8NoBom)
        $sh2000 = (& $gitBash -c "'$guardShPosix' diff-scope --repo-root '$sbRepoPosix' --base-sha HEAD") -join "`n"
        $sh2000Exit = $LASTEXITCODE
        [IO.File]::WriteAllText($bigPath, ("export const x = 1;`n" * 1999), $utf8NoBom)
        $sh1999 = (& $gitBash -c "'$guardShPosix' diff-scope --repo-root '$sbRepoPosix' --base-sha HEAD") -join "`n"
        $sh1999Exit = $LASTEXITCODE
        $sbShOk = ($sh50Exit -eq 0) -and ($sh50 -match 'size_class=VERY_LARGE') -and ($sh50 -match 'files=50') -and
                  ($sh49Exit -eq 0) -and ($sh49 -match 'size_class=LARGE') -and ($sh49 -match 'files=49') -and
                  ($sh2000Exit -eq 0) -and ($sh2000 -match 'size_class=VERY_LARGE') -and ($sh2000 -match 'lines=2000') -and
                  ($sh1999Exit -eq 0) -and ($sh1999 -match 'size_class=LARGE') -and ($sh1999 -match 'lines=1999')
    }
    Pop-Location
    if ($sb1999Exit -eq 0 -and ($sb1999 -match 'size_class=LARGE') -and ($sb1999 -match 'lines=1999') -and
        $sb2000Exit -eq 0 -and ($sb2000 -match 'size_class=VERY_LARGE') -and ($sb2000 -match 'lines=2000') -and
        $sb49Exit -eq 0 -and ($sb49 -match 'size_class=LARGE') -and ($sb49 -match 'files=49') -and
        $sb50Exit -eq 0 -and ($sb50 -match 'size_class=VERY_LARGE') -and ($sb50 -match 'files=50') -and $sbShOk) {
        Pass 'guard-size-boundary'
    } else {
        FailCheck 'guard-size-boundary' "1999=(${sb1999Exit}:$sb1999) 2000=(${sb2000Exit}:$sb2000) 49=(${sb49Exit}:$sb49) 50=(${sb50Exit}:$sb50) shOk=$sbShOk"
    }

    # --- guard-verify-receipt (dual shell: PASS, stale, precommit + partial/scope guards, fail, corrupt, scoped paths) ---
    $vrRepo = Join-Path $sandbox 'vr-repo'
    New-Item -ItemType Directory -Path $vrRepo | Out-Null
    Push-Location $vrRepo
    git init -q; git config user.email 'ship-test@example.com'; git config user.name 'Ship Test'
    New-Item -ItemType Directory -Path src | Out-Null
    Set-Content src\a.ts 'export const a = 1;'
    Set-Content src\other.ts 'export const o = 1;'
    Set-Content src\extra.ts 'export const e = 1;'
    git add .; git commit -qm 'init'
    Set-Content src\a.ts 'export const a = 2;'
    $rec = '.b3/ship/runs/r1/evidence/T001.verify'
    $vrPass = ((& powershell -NoProfile -File $guardScript verify-run -RepoRoot $vrRepo -VerifyCmd 'echo green-ok' -ReceiptPath $rec -TaskId T001 -RelevantPaths 'src/a.ts') -join "`n")
    $vrPassExit = $LASTEXITCODE
    $vcValid = ((& powershell -NoProfile -File $guardScript verify-check -RepoRoot $vrRepo -ReceiptPath $rec) -join "`n")
    $vcValidExit = $LASTEXITCODE
    # Scoped RelevantPaths ignores unrelated edit
    Set-Content src\other.ts 'export const o = 2;'
    $vcUnrel = ((& powershell -NoProfile -File $guardScript verify-check -RepoRoot $vrRepo -ReceiptPath $rec) -join "`n")
    $vcUnrelExit = $LASTEXITCODE
    # Staging verified file passes precommit -RequireVerifyReceipt
    git add src\a.ts
    $pcVrOk = ((& powershell -NoProfile -File $guardScript precommit -RepoRoot $vrRepo -AllowedPaths 'src/a.ts' -RequireVerifyReceipt $rec) -join "`n")
    $pcVrOkExit = $LASTEXITCODE
    # Partial staging (index != WT while receipt matches WT) fails precommit
    Set-Content src\a.ts 'export const a = 3;'
    $vrPass2 = ((& powershell -NoProfile -File $guardScript verify-run -RepoRoot $vrRepo -VerifyCmd 'echo green-2' -ReceiptPath $rec -TaskId T001 -RelevantPaths 'src/a.ts') -join "`n")
    $vrPass2Exit = $LASTEXITCODE
    $pcPartial = ((& powershell -NoProfile -File $guardScript precommit -RepoRoot $vrRepo -AllowedPaths 'src/a.ts' -RequireVerifyReceipt $rec) -join "`n")
    $pcPartialExit = $LASTEXITCODE
    # Sync index & test out-of-receipt-scope staged path
    git add src\a.ts
    Set-Content src\extra.ts 'export const e = 2;'
    git add src\extra.ts
    $pcOutScope = ((& powershell -NoProfile -File $guardScript precommit -RepoRoot $vrRepo -AllowedPaths 'src/a.ts,src/extra.ts' -RequireVerifyReceipt $rec) -join "`n")
    $pcOutScopeExit = $LASTEXITCODE
    git reset -q HEAD src\extra.ts
    git checkout -- src\extra.ts
    # Editing relevant file invalidates receipt -> VERIFY_STALE (exit 2) + blocks precommit
    Set-Content src\a.ts 'export const a = 4;'
    $vcStale = ((& powershell -NoProfile -File $guardScript verify-check -RepoRoot $vrRepo -ReceiptPath $rec) -join "`n")
    $vcStaleExit = $LASTEXITCODE
    git add src\a.ts
    $pcVrStale = ((& powershell -NoProfile -File $guardScript precommit -RepoRoot $vrRepo -AllowedPaths 'src/a.ts' -RequireVerifyReceipt $rec) -join "`n")
    $pcVrStaleExit = $LASTEXITCODE
    # Failing verify command writes FAIL receipt + log
    $recFail = '.b3/ship/runs/r1/evidence/T002.verify'
    $vrFail = ((& powershell -NoProfile -File $guardScript verify-run -RepoRoot $vrRepo -VerifyCmd 'Write-Output "bad-check"; exit 3' -ReceiptPath $recFail -TaskId T002) -join "`n")
    $vrFailExit = $LASTEXITCODE
    $vcFail = ((& powershell -NoProfile -File $guardScript verify-check -RepoRoot $vrRepo -ReceiptPath $recFail) -join "`n")
    $vcFailExit = $LASTEXITCODE
    $failLogExists = Test-Path -LiteralPath (Join-Path $vrRepo "$recFail.log") -PathType Leaf
    # >64KB failing output (no SIGPIPE 141, exit strictly 1, full log, capped output), trailing # comment, root '.' path match, and git rm --cached partial mismatch
    $recBig = '.b3/ship/runs/r1/evidence/big.verify'
    $vrBig = ((& powershell -NoProfile -File $guardScript verify-run -RepoRoot $vrRepo -VerifyCmd '1..1500 | ForEach-Object { 10001..10010 -join 9 }; exit 2' -ReceiptPath $recBig) -join "`n")
    $vrBigExit = $LASTEXITCODE
    $vrComment = ((& powershell -NoProfile -File $guardScript verify-run -RepoRoot $vrRepo -VerifyCmd 'echo ok # trailing' -ReceiptPath '.b3/ship/runs/r1/evidence/cmt.verify' -RelevantPaths '.') -join "`n")
    $vrCommentExit = $LASTEXITCODE
    $vcDotOk = ((& powershell -NoProfile -File $guardScript verify-check -RepoRoot $vrRepo -ReceiptPath '.b3/ship/runs/r1/evidence/cmt.verify') -join "`n")
    $vcDotOkExit = $LASTEXITCODE
    Set-Content src\other.ts 'export const o = 99;'
    $vcDotStale = ((& powershell -NoProfile -File $guardScript verify-check -RepoRoot $vrRepo -ReceiptPath '.b3/ship/runs/r1/evidence/cmt.verify') -join "`n")
    $vcDotStaleExit = $LASTEXITCODE
    $pcDotOk = ((& powershell -NoProfile -File $guardScript precommit -RepoRoot $vrRepo -AllowedPaths '.') -join "`n")
    $pcDotOkExit = $LASTEXITCODE
    git rm -q --cached src\extra.ts
    $pcRmCached = ((& powershell -NoProfile -File $guardScript precommit -RepoRoot $vrRepo -AllowedPaths '.' -RequireVerifyReceipt '.b3/ship/runs/r1/evidence/cmt.verify') -join "`n")
    $pcRmCachedExit = $LASTEXITCODE
    git add src\extra.ts
    # Corrupt & missing receipt
    $recCorrupt = Join-Path $vrRepo '.b3\ship\runs\r1\evidence\bad.verify'
    Set-Content $recCorrupt "schema=b3-verify-v1`nstatus=PASS"
    $vcCorrupt = ((& powershell -NoProfile -File $guardScript verify-check -RepoRoot $vrRepo -ReceiptPath '.b3/ship/runs/r1/evidence/bad.verify') -join "`n")
    $vcCorruptExit = $LASTEXITCODE
    $vcMissing = ((& powershell -NoProfile -File $guardScript verify-check -RepoRoot $vrRepo -ReceiptPath '.b3/ship/runs/r1/evidence/none.verify') -join "`n")
    $vcMissingExit = $LASTEXITCODE

    $vrShOk = $true
    if (Test-Path -LiteralPath $gitBash) {
        $guardShPosix = ($root -replace '\\', '/') + '/scripts/b3-guard.sh'
        $vrRepoPosix = $vrRepo -replace '\\', '/'
        $shRec = '.b3/ship/runs/r1/evidence/sh.verify'
        $shPass = (& $gitBash -c "'$guardShPosix' verify-run --repo-root '$vrRepoPosix' --verify-cmd 'echo sh-ok # sh-comment' --receipt-path '$shRec' --task-id T003 --relevant-paths 'src/a.ts'") -join "`n"
        $shPassExit = $LASTEXITCODE
        # Cross-shell verification: .ps1 verify-check validates .sh receipt and produces identical tree hash
        $psOfSh = ((& powershell -NoProfile -File $guardScript verify-check -RepoRoot $vrRepo -ReceiptPath $shRec) -join "`n")
        $psOfShExit = $LASTEXITCODE
        $shPcOk = (& $gitBash -c "'$guardShPosix' precommit --repo-root '$vrRepoPosix' --allowed-paths 'src/a.ts' --require-verify-receipt '$shRec'") -join "`n"
        $shPcOkExit = $LASTEXITCODE
        $shDot = (& $gitBash -c "'$guardShPosix' verify-run --repo-root '$vrRepoPosix' --verify-cmd 'echo dot-ok' --receipt-path '.b3/ship/runs/r1/evidence/shdot.verify' --relevant-paths '.'") -join "`n"
        $shDotExit = $LASTEXITCODE
        $shBigCmd = 'seq 1 15000; exit 2'
        $shBig = (& $gitBash -c "'$guardShPosix' verify-run --repo-root '$vrRepoPosix' --verify-cmd '$shBigCmd' --receipt-path '.b3/ship/runs/r1/evidence/shbig.verify'") -join "`n"
        $shBigExit = $LASTEXITCODE
        Set-Content src\a.ts 'export const a = 5;'
        $shStale = (& $gitBash -c "'$guardShPosix' verify-check --repo-root '$vrRepoPosix' --receipt-path '$shRec'") -join "`n"
        $shStaleExit = $LASTEXITCODE
        $shDotStale = (& $gitBash -c "'$guardShPosix' verify-check --repo-root '$vrRepoPosix' --receipt-path '.b3/ship/runs/r1/evidence/shdot.verify'") -join "`n"
        $shDotStaleExit = $LASTEXITCODE
        $shFail = (& $gitBash -c "'$guardShPosix' verify-run --repo-root '$vrRepoPosix' --verify-cmd 'echo sh-err; exit 4' --receipt-path '.b3/ship/runs/r1/evidence/shfail.verify' --task-id T004") -join "`n"
        $shFailExit = $LASTEXITCODE
        $shCorrupt = (& $gitBash -c "'$guardShPosix' verify-check --repo-root '$vrRepoPosix' --receipt-path '.b3/ship/runs/r1/evidence/bad.verify'") -join "`n"
        $shCorruptExit = $LASTEXITCODE
        $vrShOk = ($shPassExit -eq 0) -and ($shPass -match 'VERIFY_PASS:') -and
                  ($psOfShExit -eq 0) -and ($psOfSh -match 'VERIFY_VALID:') -and
                  ($shPcOkExit -eq 0) -and ($shPcOk -eq 'PRECOMMIT_OK') -and
                  ($shDotExit -eq 0) -and ($shDot -match 'VERIFY_PASS:') -and
                  ($shBigExit -eq 1) -and ($shBig -match 'VERIFY_FAIL: exit=2 ') -and
                  ($shStaleExit -eq 2) -and ($shStale -match 'VERIFY_STALE:') -and
                  ($shDotStaleExit -eq 2) -and ($shDotStale -match 'VERIFY_STALE:') -and
                  ($shFailExit -eq 1) -and ($shFail -match 'VERIFY_FAIL:') -and
                  ($shCorruptExit -eq 1) -and ($shCorrupt -match 'VERIFY_CORRUPT:')
    }
    Pop-Location
    if ($vrPassExit -eq 0 -and ($vrPass -match 'VERIFY_PASS:') -and
        $vcValidExit -eq 0 -and ($vcValid -match 'VERIFY_VALID:') -and
        $vcUnrelExit -eq 0 -and ($vcUnrel -match 'VERIFY_VALID:') -and
        $pcVrOkExit -eq 0 -and $pcVrOk -eq 'PRECOMMIT_OK' -and
        $vrPass2Exit -eq 0 -and $pcPartialExit -eq 1 -and ($pcPartial -match 'staged content differs') -and
        $pcOutScopeExit -eq 1 -and ($pcOutScope -match 'outside receipt scope') -and
        $vcStaleExit -eq 2 -and ($vcStale -match 'VERIFY_STALE:') -and
        $pcVrStaleExit -eq 1 -and ($pcVrStale -match 'VERIFY_STALE:') -and
        $vrFailExit -eq 1 -and ($vrFail -match 'VERIFY_FAIL:') -and $failLogExists -and
        $vrBigExit -eq 1 -and ($vrBig -match 'VERIFY_FAIL: exit=2 ') -and
        $vrCommentExit -eq 0 -and $vcDotOkExit -eq 0 -and $vcDotStaleExit -eq 2 -and
        $pcDotOkExit -eq 0 -and $pcRmCachedExit -eq 1 -and ($pcRmCached -match 'staged content differs') -and
        $vcFailExit -eq 1 -and ($vcFail -match 'VERIFY_FAILED_RECEIPT:') -and
        $vcCorruptExit -eq 1 -and ($vcCorrupt -match 'VERIFY_CORRUPT:') -and
        $vcMissingExit -eq 1 -and ($vcMissing -match 'VERIFY_MISSING:') -and $vrShOk) {
        Pass 'guard-verify-receipt'
    } else {
        FailCheck 'guard-verify-receipt' "vrPass=(${vrPassExit}:$vrPass) vrBig=(${vrBigExit}:$vrBig) vrCmt=(${vrCommentExit}:$vrComment) vcDot=(${vcDotOkExit}/${vcDotStaleExit}) pcRm=(${pcRmCachedExit}:$pcRmCached) stale=(${vcStaleExit}:$vcStale) shOk=$vrShOk"
    }

    # --- guard-safety-tripwires (secrets, destructive SQL non-test vs test, mass delete + AllowMassDelete, MERGE_HEAD) ---
    $stRepo = Join-Path $sandbox 'safety-repo'
    New-Item -ItemType Directory -Path $stRepo | Out-Null
    Push-Location $stRepo
    git init -q; git config user.email 'ship-test@example.com'; git config user.name 'Ship Test'
    New-Item -ItemType Directory -Path config,migrations,tests | Out-Null
    1..10 | ForEach-Object { Set-Content "f$_.ts" "export const n$_ = $_;" }
    git add .; git commit -qm 'init'
    $stBase = (git rev-parse HEAD).Trim()
    1..10 | ForEach-Object { Remove-Item "f$_.ts" }
    Set-Content config\.env 'TOKEN=abc'
    Set-Content config\.env.example 'TOKEN=placeholder'
    $mkDropSql = 'DROP ' + 'TABLE users;'
    Set-Content migrations\001.sql $mkDropSql
    Set-Content tests\db.test.ts "const sql = `"$mkDropSql`";"
    $stOut = ((& powershell -NoProfile -File $guardScript mechanical-check -RepoRoot $stRepo -BaseSha $stBase) -join "`n")
    $stExit = $LASTEXITCODE
    $stAllowMd = ((& powershell -NoProfile -File $guardScript mechanical-check -RepoRoot $stRepo -BaseSha $stBase -AllowMassDelete) -join "`n")
    $stAllowMdExit = $LASTEXITCODE
    # precommit blocks dir-prefix allow for secret, allows exact secret match, and blocks mid-merge
    git reset -q
    git add config\.env
    $pcSecDir = ((& powershell -NoProfile -File $guardScript precommit -RepoRoot $stRepo -AllowedPaths 'config') -join "`n")
    $pcSecDirExit = $LASTEXITCODE
    $pcSecExact = ((& powershell -NoProfile -File $guardScript precommit -RepoRoot $stRepo -AllowedPaths 'config/.env') -join "`n")
    $pcSecExactExit = $LASTEXITCODE
    git reset -q
    git add config\.env.example
    $pcExOk = ((& powershell -NoProfile -File $guardScript precommit -RepoRoot $stRepo -AllowedPaths 'config') -join "`n")
    $pcExOkExit = $LASTEXITCODE
    Set-Content .git\MERGE_HEAD $stBase
    $pcMerge = ((& powershell -NoProfile -File $guardScript precommit -RepoRoot $stRepo -AllowedPaths 'config') -join "`n")
    $pcMergeExit = $LASTEXITCODE
    Remove-Item .git\MERGE_HEAD -Force

    $stShOk = $true
    if (Test-Path -LiteralPath $gitBash) {
        $guardShPosix = ($root -replace '\\', '/') + '/scripts/b3-guard.sh'
        $stRepoPosix = $stRepo -replace '\\', '/'
        $shSt = (& $gitBash -c "'$guardShPosix' mechanical-check --repo-root '$stRepoPosix' --base-sha '$stBase'") -join "`n"
        $shStExit = $LASTEXITCODE
        $shStMd = (& $gitBash -c "'$guardShPosix' mechanical-check --repo-root '$stRepoPosix' --base-sha '$stBase' --allow-mass-delete") -join "`n"
        $shStMdExit = $LASTEXITCODE
        git reset -q; git add config\.env
        $shSecDir = (& $gitBash -c "'$guardShPosix' precommit --repo-root '$stRepoPosix' --allowed-paths 'config'") -join "`n"
        $shSecDirExit = $LASTEXITCODE
        $shSecExact = (& $gitBash -c "'$guardShPosix' precommit --repo-root '$stRepoPosix' --allowed-paths 'config/.env'") -join "`n"
        $shSecExactExit = $LASTEXITCODE
        Set-Content .git\MERGE_HEAD $stBase
        $shMerge = (& $gitBash -c "'$guardShPosix' precommit --repo-root '$stRepoPosix' --allowed-paths 'config/.env'") -join "`n"
        $shMergeExit = $LASTEXITCODE
        Remove-Item .git\MERGE_HEAD -Force
        $stShOk = ($shStExit -eq 2) -and ($shSt -match 'secret_path:config/\.env') -and ($shSt -match 'destructive_sql:migrations/001\.sql:1') -and ($shSt -match 'mass_delete:10f') -and ($shSt -notmatch 'tests/db\.test\.ts') -and
                  ($shStMdExit -eq 2) -and ($shStMd -notmatch 'mass_delete') -and
                  ($shSecDirExit -eq 1) -and ($shSecDir -match 'secret path staged without exact allow') -and
                  ($shSecExactExit -eq 0) -and ($shSecExact -eq 'PRECOMMIT_OK') -and
                  ($shMergeExit -eq 1) -and ($shMerge -match 'git operation in progress \(MERGE_HEAD\)')
    }
    Pop-Location
    if ($stExit -eq 2 -and ($stOut -match 'secret_path:config/\.env') -and ($stOut -match 'destructive_sql:migrations/001\.sql:1') -and ($stOut -match 'mass_delete:10f') -and ($stOut -notmatch 'tests/db\.test\.ts') -and
        $stAllowMdExit -eq 2 -and ($stAllowMd -notmatch 'mass_delete') -and
        $pcSecDirExit -eq 1 -and ($pcSecDir -match 'secret path staged without exact allow') -and
        $pcSecExactExit -eq 0 -and $pcSecExact -eq 'PRECOMMIT_OK' -and
        $pcExOkExit -eq 0 -and $pcExOk -eq 'PRECOMMIT_OK' -and
        $pcMergeExit -eq 1 -and ($pcMerge -match 'git operation in progress \(MERGE_HEAD\)') -and $stShOk) {
        Pass 'guard-safety-tripwires'
    } else {
        FailCheck 'guard-safety-tripwires' "st=(${stExit}:$stOut) allowMd=(${stAllowMdExit}:$stAllowMd) secDir=(${pcSecDirExit}:$pcSecDir) secEx=(${pcSecExactExit}:$pcSecExact) exOk=(${pcExOkExit}:$pcExOk) merge=(${pcMergeExit}:$pcMerge) shOk=$stShOk"
    }

    # --- guard-symbol-check (dangling refs, internal orphan, exported public API tolerance) ---
    $syRepo = Join-Path $sandbox 'sym-repo'
    New-Item -ItemType Directory -Path $syRepo | Out-Null
    Push-Location $syRepo
    git init -q; git config user.email 'ship-test@example.com'; git config user.name 'Ship Test'
    New-Item -ItemType Directory -Path src | Out-Null
    Set-Content src\lib.ts "export function oldUsed() { return 1; }`nexport function keepFn() { return 2; }"
    Set-Content src\caller.ts "import { oldUsed } from './lib';`nexport const res = oldUsed();"
    git add .; git commit -qm 'init'
    $syBase = (git rev-parse HEAD).Trim()
    Set-Content src\lib.ts "export function keepFn() { return 2; }`nfunction internalDead() { return 3; }`nexport function publicApi() { return 4; }"
    $syBad = ((& powershell -NoProfile -File $guardScript symbol-check -RepoRoot $syRepo -BaseSha $syBase) -join "`n")
    $syBadExit = $LASTEXITCODE
    $syShOk = $true
    if (Test-Path -LiteralPath $gitBash) {
        $guardShPosix = ($root -replace '\\', '/') + '/scripts/b3-guard.sh'
        $syRepoPosix = $syRepo -replace '\\', '/'
        $shSyBad = (& $gitBash -c "'$guardShPosix' symbol-check --repo-root '$syRepoPosix' --base-sha '$syBase'") -join "`n"
        $shSyBadExit = $LASTEXITCODE
        $syShOk = ($shSyBadExit -eq 2) -and ($shSyBad -match 'dangling_refs=oldUsed\(1f\)') -and ($shSyBad -match 'orphan_internal=src/lib\.ts:internalDead') -and ($shSyBad -notmatch 'orphan_internal=.*publicApi')
    }
    # Clean caller + remove internalDead, keep unreferenced export function publicApi -> SYMBOL_OK
    Set-Content src\caller.ts "export const res = 1;"
    Set-Content src\lib.ts "export function keepFn() { return 2; }`nexport function publicApi() { return 4; }"
    $syClean = ((& powershell -NoProfile -File $guardScript symbol-check -RepoRoot $syRepo -BaseSha $syBase) -join "`n")
    $syCleanExit = $LASTEXITCODE
    if (Test-Path -LiteralPath $gitBash) {
        $shSyClean = (& $gitBash -c "'$guardShPosix' symbol-check --repo-root '$syRepoPosix' --base-sha '$syBase'") -join "`n"
        $shSyCleanExit = $LASTEXITCODE
        $syShOk = $syShOk -and ($shSyCleanExit -eq 0) -and ($shSyClean -match 'SYMBOL_OK')
    }
    Pop-Location
    if ($syBadExit -eq 2 -and ($syBad -match 'dangling_refs=oldUsed\(1f\)') -and ($syBad -match 'orphan_internal=src/lib\.ts:internalDead') -and ($syBad -notmatch 'orphan_internal=.*publicApi') -and
        $syCleanExit -eq 0 -and ($syClean -match 'SYMBOL_OK') -and $syShOk) {
        Pass 'guard-symbol-check'
    } else {
        FailCheck 'guard-symbol-check' "bad=(${syBadExit}:$syBad) clean=(${syCleanExit}:$syClean) shOk=$syShOk"
    }

    # --- guard-wave-rw-and-worktree (WaveReads, ExpectedBaseSha, linked worktree, wrong root/head/MERGE_HEAD) ---
    $wtMain = Join-Path $sandbox 'wt-main'
    $wtOther = Join-Path $sandbox 'wt-other'
    $wtLinked = Join-Path $sandbox 'wt-linked'
    New-Item -ItemType Directory -Path $wtMain, $wtOther | Out-Null
    Push-Location $wtMain
    git init -q; git config user.email 'ship-test@example.com'; git config user.name 'Ship Test'
    New-Item -ItemType Directory -Path src | Out-Null
    Set-Content src\a.ts 'export const a = 1;'
    Set-Content src\b.ts 'export const b = 1;'
    git add .; git commit -qm 'init'
    $wtHead = (git rev-parse HEAD).Trim()
    git worktree add -q -b wt-branch $wtLinked $wtHead 2>$null
    Pop-Location
    Push-Location $wtOther
    git init -q; git config user.email 'ship-test@example.com'; git config user.name 'Ship Test'
    Set-Content r.txt 'other'; git add .; git commit -qm 'other'
    Pop-Location

    $cwRw = ((& powershell -NoProfile -File $guardScript check-wave -RepoRoot $wtMain -WaveSpecs 'T1=src/a.ts;T2=src/b.ts' -WaveReads 'T1=src/b.ts;T2=none' -ExpectedBaseSha $wtHead) -join "`n")
    $cwRwExit = $LASTEXITCODE
    $cwBaseBad = ((& powershell -NoProfile -File $guardScript check-wave -RepoRoot $wtMain -WaveSpecs 'T1=src/a.ts;T2=src/b.ts' -ExpectedBaseSha ('0' * 40)) -join "`n")
    $cwBaseBadExit = $LASTEXITCODE
    $cwDisjoint = ((& powershell -NoProfile -File $guardScript check-wave -RepoRoot $wtMain -WaveSpecs 'T1=src/a.ts;T2=src/b.ts' -WaveReads 'T1=src/c.ts;T2=src/d.ts' -ExpectedBaseSha $wtHead) -join "`n")
    $cwDisjointExit = $LASTEXITCODE
    $wtOk = ((& powershell -NoProfile -File $guardScript check-worktree -RepoRoot $wtLinked -ExpectedRoot $wtMain -ExpectedBaseSha $wtHead) -join "`n")
    $wtOkExit = $LASTEXITCODE
    $wtWrongRoot = ((& powershell -NoProfile -File $guardScript check-worktree -RepoRoot $wtOther -ExpectedRoot $wtMain) -join "`n")
    $wtWrongRootExit = $LASTEXITCODE
    $wtWrongBase = ((& powershell -NoProfile -File $guardScript check-worktree -RepoRoot $wtMain -ExpectedBaseSha ('0' * 40)) -join "`n")
    $wtWrongBaseExit = $LASTEXITCODE
    Set-Content (Join-Path $wtMain '.git\MERGE_HEAD') $wtHead
    $wtMidOp = ((& powershell -NoProfile -File $guardScript check-worktree -RepoRoot $wtMain) -join "`n")
    $wtMidOpExit = $LASTEXITCODE
    Remove-Item (Join-Path $wtMain '.git\MERGE_HEAD') -Force

    $wtShOk = $true
    if (Test-Path -LiteralPath $gitBash) {
        $guardShPosix = ($root -replace '\\', '/') + '/scripts/b3-guard.sh'
        $wmPosix = $wtMain -replace '\\', '/'
        $wlPosix = $wtLinked -replace '\\', '/'
        $woPosix = $wtOther -replace '\\', '/'
        $shRw = (& $gitBash -c "'$guardShPosix' check-wave --repo-root '$wmPosix' --wave-specs 'T1=src/a.ts;T2=src/b.ts' --wave-reads 'T1=src/b.ts;T2=none' --expected-base-sha '$wtHead'") -join "`n"
        $shRwExit = $LASTEXITCODE
        $shBaseBad = (& $gitBash -c "'$guardShPosix' check-wave --repo-root '$wmPosix' --wave-specs 'T1=src/a.ts;T2=src/b.ts' --expected-base-sha '0000000000000000000000000000000000000000'") -join "`n"
        $shBaseBadExit = $LASTEXITCODE
        $shWtOk = (& $gitBash -c "'$guardShPosix' check-worktree --repo-root '$wlPosix' --expected-root '$wmPosix' --expected-base-sha '$wtHead'") -join "`n"
        $shWtOkExit = $LASTEXITCODE
        $shWtWrong = (& $gitBash -c "'$guardShPosix' check-worktree --repo-root '$woPosix' --expected-root '$wmPosix'") -join "`n"
        $shWtWrongExit = $LASTEXITCODE
        $wtShOk = ($shRwExit -eq 2) -and ($shRw -match 'WAVE_CONFLICT: rw:src/b\.ts\(T2->T1\)') -and
                  ($shBaseBadExit -eq 2) -and ($shBaseBad -match 'WAVE_BASE_MISMATCH:') -and
                  ($shWtOkExit -eq 0) -and ($shWtOk -match 'WORKTREE_OK:') -and
                  ($shWtWrongExit -eq 2) -and ($shWtWrong -match 'WORKTREE_UNSAFE: root_mismatch')
    }
    Push-Location $wtMain; git worktree remove -f $wtLinked 2>$null; Pop-Location
    if ($cwRwExit -eq 2 -and ($cwRw -match 'WAVE_CONFLICT: rw:src/b\.ts\(T2->T1\)') -and
        $cwBaseBadExit -eq 2 -and ($cwBaseBad -match 'WAVE_BASE_MISMATCH:') -and
        $cwDisjointExit -eq 0 -and ($cwDisjoint -match 'WAVE_OK:') -and
        $wtOkExit -eq 0 -and ($wtOk -match 'WORKTREE_OK:') -and
        $wtWrongRootExit -eq 2 -and ($wtWrongRoot -match 'WORKTREE_UNSAFE: root_mismatch') -and
        $wtWrongBaseExit -eq 2 -and ($wtWrongBase -match 'WORKTREE_UNSAFE: base_mismatch') -and
        $wtMidOpExit -eq 2 -and ($wtMidOp -match 'WORKTREE_UNSAFE: git_op_in_progress') -and $wtShOk) {
        Pass 'guard-wave-rw-and-worktree'
    } else {
        FailCheck 'guard-wave-rw-and-worktree' "rw=(${cwRwExit}:$cwRw) base=(${cwBaseBadExit}:$cwBaseBad) wtOk=(${wtOkExit}:$wtOk) wrongRoot=(${wtWrongRootExit}:$wtWrongRoot) wrongBase=(${wtWrongBaseExit}:$wtWrongBase) mid=(${wtMidOpExit}:$wtMidOp) shOk=$wtShOk"
    }

    # --- guard-legacy-autodev-fallback (.b3/autodev CURRENT + progress.md + precommit block) ---
    $adRepo1 = Join-Path $sandbox 'ad-cur-repo'
    $adRepo2 = Join-Path $sandbox 'ad-prog-repo'
    New-Item -ItemType Directory -Path (Join-Path $adRepo1 '.b3\autodev\runs\20261121-0100-old') | Out-Null
    Set-Content (Join-Path $adRepo1 '.b3\autodev\CURRENT') "20261121-0100-old`n"
    Set-Content (Join-Path $adRepo1 '.b3\autodev\runs\20261121-0100-old\progress.md') "- run_status: running`n"
    New-Item -ItemType Directory -Path (Join-Path $adRepo2 '.b3\autodev') | Out-Null
    Set-Content (Join-Path $adRepo2 '.b3\autodev\progress.md') "- run_status: paused`n"
    Push-Location $adRepo2
    git init -q; git config user.email 'ship-test@example.com'; git config user.name 'Ship Test'
    Set-Content app.ts 'export const x = 1;'
    git add app.ts; git commit -qm 'init'
    git add -f .b3\autodev\progress.md
    $adPc = ((& powershell -NoProfile -File $guardScript precommit -RepoRoot $adRepo2 -AllowedPaths 'app.ts') -join "`n")
    $adPcExit = $LASTEXITCODE
    Pop-Location
    $adRes1 = ((& powershell -NoProfile -File $guardScript resolve-run -RepoRoot $adRepo1) -join "`n").Trim()
    $adRes1Exit = $LASTEXITCODE
    $adList1 = ((& powershell -NoProfile -File $guardScript list-runs -RepoRoot $adRepo1) -join "`n")
    $adRes2 = ((& powershell -NoProfile -File $guardScript resolve-run -RepoRoot $adRepo2) -join "`n").Trim()
    $adRes2Exit = $LASTEXITCODE
    $adShOk = $true
    if (Test-Path -LiteralPath $gitBash) {
        $guardShPosix = ($root -replace '\\', '/') + '/scripts/b3-guard.sh'
        $ad1Posix = $adRepo1 -replace '\\', '/'
        $ad2Posix = $adRepo2 -replace '\\', '/'
        $shAd1 = (& $gitBash -c "'$guardShPosix' resolve-run --repo-root '$ad1Posix'") -join "`n"
        $shAd1Exit = $LASTEXITCODE
        $shAdList = (& $gitBash -c "'$guardShPosix' list-runs --repo-root '$ad1Posix'") -join "`n"
        $shAd2 = (& $gitBash -c "'$guardShPosix' resolve-run --repo-root '$ad2Posix'") -join "`n"
        $shAd2Exit = $LASTEXITCODE
        $shAdPc = (& $gitBash -c "'$guardShPosix' precommit --repo-root '$ad2Posix' --allowed-paths 'app.ts'") -join "`n"
        $shAdPcExit = $LASTEXITCODE
        $adShOk = ($shAd1Exit -eq 0) -and ($shAd1 -eq '.b3/autodev/runs/20261121-0100-old') -and
                  ($shAdList -match '\(legacy-autodev\)') -and
                  ($shAd2Exit -eq 0) -and ($shAd2 -eq '.b3/autodev') -and
                  ($shAdPcExit -eq 1) -and ($shAdPc -match 'checkpoint staged')
    }
    if ($adRes1Exit -eq 0 -and $adRes1 -eq '.b3/autodev/runs/20261121-0100-old' -and
        ($adList1 -match '\(legacy-autodev\)') -and
        $adRes2Exit -eq 0 -and $adRes2 -eq '.b3/autodev' -and
        $adPcExit -eq 1 -and ($adPc -match 'checkpoint staged') -and $adShOk) {
        Pass 'guard-legacy-autodev-fallback'
    } else {
        FailCheck 'guard-legacy-autodev-fallback' "res1=(${adRes1Exit}:$adRes1) res2=(${adRes2Exit}:$adRes2) pc=(${adPcExit}:$adPc) shOk=$adShOk"
    }

    $hopViolations = @()
    foreach ($cs in @(Get-ChildItem (Join-Path $root 'adapters\command-skills') -Recurse -Filter 'SKILL.md' -File)) {
        $csText = Get-Content -LiteralPath $cs.FullName -Raw
        if (($csText -match '\{B3_HOME\}/commands/') -or ($csText -match '(?m)^(?!.*(do not|not\b)).*\bcommands/[a-z-]+\.md')) {
            $hopViolations += $cs.FullName
        }
    }
    $copiedCmdRelLinks = @()
    $copiedCmdMissingB3Home = @()
    foreach ($cmdFile in @(Get-ChildItem (Join-Path $root 'commands') -Filter '*.md' -File | Where-Object { $_.Name -ne 'README.md' })) {
        $cmdText = Get-Content -LiteralPath $cmdFile.FullName -Raw
        if ($cmdText -match '\]\(\.\./') {
            $copiedCmdRelLinks += $cmdFile.Name
        }
        if ($cmdText -notmatch '\bB3_HOME\b') {
            $copiedCmdMissingB3Home += $cmdFile.Name
        }
    }
    $cmdRlText = Get-Content -LiteralPath (Join-Path $root 'commands\b3-review-loop.md') -Raw
    $cmdRevText = Get-Content -LiteralPath (Join-Path $root 'commands\b3-review.md') -Raw
    $refLinkPattern = '\]\([^)]*review-loop/(spec|sizing|models)\.md\)'
    $eagerSpec = ($cmdRlText -match $refLinkPattern) -or ($cmdRevText -match $refLinkPattern) -or ($wfMain -match $refLinkPattern) -or ($wfMain -match 'sizing\.md')
    $specLeaks = @()
    foreach ($dirName in @('skills', 'workflows')) {
        foreach ($f in @(Get-ChildItem (Join-Path $root $dirName) -Recurse -Filter '*.md' -File)) {
            foreach ($line in @(Get-Content -LiteralPath $f.FullName)) {
                if ($line -match 'review-loop/spec\.md' -and $line -notmatch '(?i)\b(do not|never|skip)\b') {
                    $specLeaks += $f.FullName
                    break
                }
            }
        }
    }
    $prodAgentsText = Get-Content -LiteralPath (Join-Path $root 'adapters\product-agents.md') -Raw
    $prodAgentsTwoHop = ($prodAgentsText -match 'commands/b3-ship\.md')
    if ($hopViolations.Count -eq 0 -and (-not $eagerSpec) -and $copiedCmdRelLinks.Count -eq 0 -and $copiedCmdMissingB3Home.Count -eq 0 -and $specLeaks.Count -eq 0 -and (-not $prodAgentsTwoHop)) {
        Pass 'context-single-hop-no-eager-spec'
    } else {
        FailCheck 'context-single-hop-no-eager-spec' "hops=$($hopViolations.Count) eagerSpec=$eagerSpec copiedRelLinks=$($copiedCmdRelLinks -join ',') missingB3Home=$($copiedCmdMissingB3Home -join ',') specLeaks=$($specLeaks -join ',') prodAgentsTwoHop=$prodAgentsTwoHop"
    }

    # Naming is a dispatch-only contract, not a globally injected rule.
    $namingFile = Join-Path $root 'workflows\references\dispatch-naming.md'
    $namingText = if (Test-Path -LiteralPath $namingFile) { Get-Content -LiteralPath $namingFile -Raw } else { '' }
    $shipNamingText = Get-Content -LiteralPath (Join-Path $root 'workflows\ship.md') -Raw
    $reviewNamingText = Get-Content -LiteralPath (Join-Path $root 'review-loop\strategy.md') -Raw
    $namingOk = (-not (Test-Path -LiteralPath (Join-Path $root 'rules\agent-naming.md'))) -and
                (-not (Test-Path -LiteralPath (Join-Path $root '.cursor\rules\agent-naming.mdc'))) -and
                (-not (Test-Path -LiteralPath (Join-Path $root 'agents\dispatch-naming.md'))) -and
                ($namingText -match 'b3-impl-<task-id>') -and
                ($namingText -match 'host-returned agent ID') -and
                ($namingText -match 'only if the host API supports custom names') -and
                ($shipNamingText -match 'references/dispatch-naming\.md') -and
                ($reviewNamingText -match 'workflows/references/dispatch-naming\.md')
    if ($namingOk) { Pass 'agent-naming-dispatch-contract' }
    else { FailCheck 'agent-naming-dispatch-contract' 'global rule, fallback, ID separation or dispatch link missing' }

    $ctxOut = (& powershell -NoProfile -File (Join-Path $root 'scripts\measure-context.ps1') -RepoRoot $root -Strict) -join "`n"
    if ($LASTEXITCODE -eq 0 -and $ctxOut -match 'warnings\s*:\s*0') {
        Pass 'context-budget-strict'
    } else {
        FailCheck 'context-budget-strict' "exit=$LASTEXITCODE out=$ctxOut"
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
