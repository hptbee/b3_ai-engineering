# Behavioral checks for ship hardening. Not a host skill-discovery test.
# Usage: powershell -File scripts/validate-ship-behavior.ps1
param(
    [switch]$AllowIncompleteBash
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'lib\global-test-helpers.ps1')

function Invoke-GuardRaw {
    $argList = [string[]]@($args | ForEach-Object { [string]$_ })
    $res = Invoke-PsGuard -GuardArgs $argList
    $global:LASTEXITCODE = $res.Code
    foreach ($ln in @($res.Lines)) {
        Write-Output ([string]$ln)
    }
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
    $wfDispPath = Join-Path $root 'workflows\references\dispatch-naming.md'
    $wfMain = Get-Content $wfMainPath -Raw
    $wfMainLines = @(Get-Content $wfMainPath).Count
    $wfCorpus = @($wfMain, (Get-Content $wfResPath -Raw), (Get-Content $wfTplPath -Raw), (Get-Content $wfDispPath -Raw)) -join "`n"
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
    $linksOk = ($wfMain -match 'references/ship-resume\.md') -and ($wfMain -match 'references/ship-templates\.md') -and ($wfMain -match 'references/dispatch-naming\.md') -and ($wfMain -match 'references/pr-template\.md') -and ($agentsRaw -match 'workflows/references/pr-template\.md') -and $prTplExists
    $spawnEveryOk = ($wfMain -notmatch 'on `>=2` ready') -and ($wfMain -match 'for \*\*every\*\* ready task')
    $reqReceiptOk = ($wfMain -notmatch 'when receipt exists') -and ($wfMain -match 'precommit -RequireVerifyReceipt')
    $sizeOk = ($wfMainLines -le 300)
    if ($missing.Count -eq 0 -and $linksOk -and $spawnEveryOk -and $reqReceiptOk -and $sizeOk) { Pass 'workflow-recipes' }
    else { FailCheck 'workflow-recipes' "missing=$($missing -join ', ') links=$linksOk prTpl=$prTplExists spawnEvery=$spawnEveryOk reqReceipt=$reqReceiptOk lines=$wfMainLines" }

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
        $agNoCursorCmd = -not (Test-Path (Join-Path $agProduct '.cursor\commands'))
        & powershell -NoProfile -File (Join-Path $root 'adapters\install-product.ps1') -ProductRoot $agProduct -B3Home $root -HostName antigravity | Out-Null
        $agIdemOk = ($LASTEXITCODE -eq 0)
        if (($agHomePath -eq $root) -and $agAgentsMd -and $agGiOk -and (-not $agIsTreeLink) -and ($agSkillDirs.Count -ge 30) -and $agShipOk -and $agPlanningOk -and $agNoCursorCmd -and $agIdemOk) {
            Pass 'install-product-antigravity'
        } else {
            FailCheck 'install-product-antigravity' "home=$($agHomePath -eq $root) agentsMd=$agAgentsMd gi=$agGiOk treeLink=$agIsTreeLink skills=$($agSkillDirs.Count) ship=$agShipOk planning=$agPlanningOk noCur=$agNoCursorCmd idem=$agIdemOk"
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
        $clNoCursorCmd = -not (Test-Path (Join-Path $clProduct '.cursor\commands'))
        & powershell -NoProfile -File (Join-Path $root 'adapters\install-product.ps1') -ProductRoot $clProduct -B3Home $root -HostName claude | Out-Null
        $clIdemOk = ($LASTEXITCODE -eq 0)
        if (($clHomePath -eq $root) -and $clMdOk -and $clAgentsMd -and $clGiOk -and (-not $clIsTreeLink) -and ($clSkillDirs.Count -ge 30) -and $clAgentsOk -and $clShipOk -and $clNoCursorCmd -and $clIdemOk) {
            Pass 'install-product-claude'
        } else {
            FailCheck 'install-product-claude' "home=$($clHomePath -eq $root) claudeMd=$clMdOk agentsMd=$clAgentsMd gi=$clGiOk treeLink=$clIsTreeLink skills=$($clSkillDirs.Count) agents=$clAgentsOk ship=$clShipOk noCur=$clNoCursorCmd idem=$clIdemOk"
        }
    }

    # --- CF-13: install-product host isolation (no .cursor/commands on non-Cursor), empty .b3/home fail-closed, and -Force/--force pointer refresh (PS + Bash) ---
    $cf13Errs = New-Object System.Collections.Generic.List[string]
    $cf13PsProd = Join-Path $sandbox 'cf13-codex-ps'
    $cf13ShProd = Join-Path $sandbox 'cf13-codex-sh'
    $cf13StaleHome = Join-Path $sandbox 'cf13-stale-home'
    $utf8NoBomCf13 = New-Object System.Text.UTF8Encoding($false)
    Init-B3TestRepo -RepoPath $cf13PsProd -InitialCommit
    New-Item -ItemType Directory -Path $cf13StaleHome -Force | Out-Null
    $ipPsPath = Join-Path $root 'adapters\install-product.ps1'
    $ipShPosix = To-PosixPath (Join-Path $root 'adapters\install-product.sh')
    $rootPosix = To-PosixPath $root

    $cf13R1 = Invoke-PsScript $ipPsPath @('-ProductRoot', $cf13PsProd, '-B3Home', $root, '-HostName', 'codex')
    if ($cf13R1.Code -ne 0 -or (Test-Path -LiteralPath (Join-Path $cf13PsProd '.cursor\commands')) -or (-not (Test-Path -LiteralPath (Join-Path $cf13PsProd '.agents\skills\b3-ship\SKILL.md')))) {
        $cf13Errs.Add("PS codex install failed or leaked .cursor/commands: code=$($cf13R1.Code)")
    }
    [IO.File]::WriteAllText((Join-Path $cf13PsProd '.b3\home'), "   `n", $utf8NoBomCf13)
    $cf13EmptyPs = Invoke-PsScript $ipPsPath @('-ProductRoot', $cf13PsProd, '-B3Home', $root, '-HostName', 'codex')
    if ($cf13EmptyPs.Code -eq 0 -or ($cf13EmptyPs.Text -notmatch 'refusing to overwrite empty or invalid')) {
        $cf13Errs.Add("PS empty .b3/home expected fail-closed, got code=$($cf13EmptyPs.Code) out=$($cf13EmptyPs.Text)")
    }
    [IO.File]::WriteAllText((Join-Path $cf13PsProd '.b3\home'), "$cf13StaleHome`n", $utf8NoBomCf13)
    $cf13StalePs = Invoke-PsScript $ipPsPath @('-ProductRoot', $cf13PsProd, '-B3Home', $root, '-HostName', 'codex')
    $cf13ForcePs = Invoke-PsScript $ipPsPath @('-ProductRoot', $cf13PsProd, '-B3Home', $root, '-HostName', 'codex', '-Force')
    $cf13RefreshedPs = (Get-Content -LiteralPath (Join-Path $cf13PsProd '.b3\home') -Raw).Trim()
    if ($cf13StalePs.Code -eq 0 -or $cf13ForcePs.Code -ne 0 -or ($cf13RefreshedPs -ne $root) -or (Test-Path -LiteralPath (Join-Path $cf13PsProd '.cursor\commands'))) {
        $cf13Errs.Add("PS -Force refresh failed: stale=$($cf13StalePs.Code) force=$($cf13ForcePs.Code) home=$cf13RefreshedPs")
    }
    if ($script:HasBash) {
        Init-B3TestRepo -RepoPath $cf13ShProd -InitialCommit
        $cf13ShPosix = To-PosixPath $cf13ShProd
        $cf13R1Sh = Invoke-ShCmd "'$ipShPosix' --product-root '$cf13ShPosix' --b3-home '$rootPosix' --host codex"
        if ($cf13R1Sh.Code -ne 0 -or (Test-Path -LiteralPath (Join-Path $cf13ShProd '.cursor\commands')) -or (-not (Test-Path -LiteralPath (Join-Path $cf13ShProd '.agents\skills\b3-ship\SKILL.md')))) {
            $cf13Errs.Add("SH codex install failed or leaked .cursor/commands: code=$($cf13R1Sh.Code) out=$($cf13R1Sh.Text)")
        }
        [IO.File]::WriteAllText((Join-Path $cf13ShProd '.b3\home'), "   `n", $utf8NoBomCf13)
        $cf13EmptySh = Invoke-ShCmd "'$ipShPosix' --product-root '$cf13ShPosix' --b3-home '$rootPosix' --host codex"
        if ($cf13EmptySh.Code -eq 0 -or ($cf13EmptySh.Text -notmatch 'refusing to overwrite empty or invalid')) {
            $cf13Errs.Add("SH empty .b3/home expected fail-closed, got code=$($cf13EmptySh.Code) out=$($cf13EmptySh.Text)")
        }
        [IO.File]::WriteAllText((Join-Path $cf13ShProd '.b3\home'), "$(To-PosixPath $cf13StaleHome)`n", $utf8NoBomCf13)
        $cf13StaleSh = Invoke-ShCmd "'$ipShPosix' --product-root '$cf13ShPosix' --b3-home '$rootPosix' --host codex"
        $cf13ForceSh = Invoke-ShCmd "'$ipShPosix' --product-root '$cf13ShPosix' --b3-home '$rootPosix' --host codex --force"
        $cf13RefreshedSh = ((Get-Content -LiteralPath (Join-Path $cf13ShProd '.b3\home') -Raw).Trim() -replace '\\', '/')
        if ($cf13StaleSh.Code -eq 0 -or $cf13ForceSh.Code -ne 0 -or ($cf13RefreshedSh -ine $rootPosix) -or (Test-Path -LiteralPath (Join-Path $cf13ShProd '.cursor\commands'))) {
            $cf13Errs.Add("SH --force refresh failed: stale=$($cf13StaleSh.Code) force=$($cf13ForceSh.Code) home=$cf13RefreshedSh")
        }
    }
    if ($cf13Errs.Count -eq 0) {
        Pass 'install-product-host-isolation-and-refresh'
    } else {
        FailCheck 'install-product-host-isolation-and-refresh' ($cf13Errs -join '; ')
    }

    $pluginDryHome = Join-Path $sandbox 'ag-plugin-dry-home'
    $pluginDry = Join-Path $pluginDryHome '.gemini\config\plugins\b3-ai-engineering'
    & powershell -NoProfile -File (Join-Path $root 'adapters\antigravity\install-plugin.ps1') -PluginRoot $pluginDry -UserHome $pluginDryHome -B3Home $root -DryRun | Out-Null
    $dryOk = ($LASTEXITCODE -eq 0) -and (-not (Test-Path -LiteralPath $pluginDry)) -and (-not (Test-Path -LiteralPath (Join-Path $pluginDryHome '.gemini\config\skills.json')))

    $pluginUserHome = Join-Path $sandbox 'ag-plugin-home'
    $pluginOut = Join-Path $sandbox 'ag-plugin-out'
    & powershell -NoProfile -File (Join-Path $root 'adapters\antigravity\install-plugin.ps1') -PluginRoot $pluginOut -UserHome $pluginUserHome -B3Home $root | Out-Null
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

        & powershell -NoProfile -File (Join-Path $root 'adapters\antigravity\install-plugin.ps1') -PluginRoot $pluginOut -UserHome $pluginUserHome -B3Home $root | Out-Null
        $pluginIdemOk = ($LASTEXITCODE -eq 0)
        $sjFile = Join-Path $pluginUserHome '.gemini\config\skills.json'
        $sjOk = $false
        if (Test-Path -LiteralPath $sjFile -PathType Leaf) {
            try {
                $sj = Get-Content -LiteralPath $sjFile -Raw | ConvertFrom-Json
                $sjPaths = @($sj.entries | ForEach-Object { [string]$_.path })
                $sjOk = ($sjPaths -contains (($root -replace '\\', '/') + '/skills/engineering')) -and
                        ($sjPaths -contains (($root -replace '\\', '/') + '/adapters/command-skills'))
            } catch { $sjOk = $false }
        }

        $nonB3 = Join-Path $sandbox 'non-b3-dir'
        New-Item -ItemType Directory -Path $nonB3 | Out-Null
        Set-Content (Join-Path $nonB3 'keep.txt') 'other'
        $nonB3Err = $null
        try {
            & powershell -NoProfile -File (Join-Path $root 'adapters\antigravity\install-plugin.ps1') -PluginRoot $nonB3 -UserHome $pluginUserHome -B3Home $root 2>&1 | Out-Null
        } catch { $nonB3Err = $_ }
        $refuseNonB3Ok = ($LASTEXITCODE -ne 0 -or $null -ne $nonB3Err) -and (Test-Path -LiteralPath (Join-Path $nonB3 'keep.txt'))

        if ($pjOk -and $rulesOk -and $pSkillsOk -and $agentsOk -and $sjOk -and $pluginIdemOk -and $refuseNonB3Ok) {
            Pass 'install-antigravity-plugin'
        } else {
            FailCheck 'install-antigravity-plugin' "pj=$pjOk rules=$rulesOk skills=$pSkillsOk($($pSkillDirs.Count)) agents=$agentsOk sj=$sjOk idem=$pluginIdemOk refuse=$refuseNonB3Ok"
        }
    }

    # --- b3-guard.ps1 checks ---
    $guardScript = Join-Path $root 'scripts\b3-guard.ps1'
    $fpSorted = (Invoke-GuardRaw fingerprint -DependsOn 'T002, T001, T001' -Scope '  src/api  ' -Criteria 'AC1: ok; AC2: valid').Trim()
    $fpEmpty = (Invoke-GuardRaw fingerprint -Scope 'README.md' -Criteria 'AC1: documented').Trim()
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
    $f1 = (Invoke-GuardRaw check-freshness -RepoRoot $guardRepo -ApproachAtSha $gBase -TaskBaseSha $gBase -WatchedPaths 'src/owned.js,src/contract.ts' -OwnedFiles 'src/owned.js' -IgnoreDirtyPaths 'docs/note.md')
    $f1Exit = $LASTEXITCODE
    # Stale when read_only_deps changes uncommitted
    Set-Content src\contract.ts 'export type C = { id: number }'
    $f2 = (Invoke-GuardRaw check-freshness -RepoRoot $guardRepo -ApproachAtSha $gBase -TaskBaseSha $gBase -WatchedPaths 'src/owned.js,src/contract.ts' -OwnedFiles 'src/owned.js' -IgnoreDirtyPaths 'docs/note.md')
    $f2Exit = $LASTEXITCODE
    git checkout -- src/contract.ts
    # Stale when committed change hits watched_paths
    git add src/owned.js
    git commit -qm 'move owned'
    $f3 = (Invoke-GuardRaw check-freshness -RepoRoot $guardRepo -ApproachAtSha $gBase -TaskBaseSha $gBase -WatchedPaths 'src/owned.js,src/contract.ts' -OwnedFiles 'src/owned.js')
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
    $pc1 = (Invoke-GuardRaw precommit -RepoRoot $guardRepo -AllowedPaths 'src/owned.js')
    $pc1Exit = $LASTEXITCODE
    # precommit: checkpoint staged -> fail
    New-Item -ItemType Directory -Path '.b3\ship' -Force | Out-Null
    Set-Content '.b3\ship\progress.md' 'cp'
    git add -f '.b3\ship\progress.md'
    $pc2 = (Invoke-GuardRaw precommit -RepoRoot $guardRepo -AllowedPaths 'src/owned.js')
    $pc2Exit = $LASTEXITCODE
    git reset -q HEAD '.b3\ship\progress.md'
    # precommit: undeclared staged -> fail
    Set-Content docs\note.md 'extra'
    git add docs\note.md
    $pc3 = (Invoke-GuardRaw precommit -RepoRoot $guardRepo -AllowedPaths 'src/owned.js')
    $pc3Exit = $LASTEXITCODE
    git reset -q HEAD docs\note.md
    git checkout -- docs/note.md
    # precommit: allowed staged -> pass
    Set-Content src\owned.js 'exports.a = 3'
    git add src\owned.js
    $pc4 = (Invoke-GuardRaw precommit -RepoRoot $guardRepo -AllowedPaths 'src/owned.js')
    $pc4Exit = $LASTEXITCODE
    git reset -q HEAD src\owned.js
    # snapshot: dirty tracked -> commit sha != HEAD, clean stash list, work preserved
    $gHeadNow = (git rev-parse HEAD).Trim()
    $snapDirty = (Invoke-GuardRaw snapshot -RepoRoot $guardRepo).Trim()
    $snapDirtyExit = $LASTEXITCODE
    $stashEmpty = -not (git stash list)
    $workKept = (Get-Content src\owned.js -Raw) -match 'exports\.a = 3'
    git checkout -- src/owned.js
    $snapClean = (Invoke-GuardRaw snapshot -RepoRoot $guardRepo).Trim()
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
    $dsEmpty = (Invoke-GuardRaw diff-scope -RepoRoot $guardRepo -BaseSha $dsHead) -join "`n"
    $dsEmptyExit = $LASTEXITCODE
    Set-Content package-lock.json '{"lockfileVersion":3}'
    $dsNoise = (Invoke-GuardRaw diff-scope -RepoRoot $guardRepo -BaseSha $dsHead) -join "`n"
    $dsNoiseExit = $LASTEXITCODE
    git mv src/owned.js src/renamed.js
    git add package-lock.json
    git commit -qm 'rename'
    $dsPrev = (git rev-parse HEAD).Trim()
    Set-Content src\extra.js 'exports.b = 5'
    Set-Content docs\note.md 'ignored dirty'
    $dsOut = (Invoke-GuardRaw diff-scope -RepoRoot $guardRepo -BaseSha $dsHead -PrevSha $dsPrev -IgnoreDirtyPaths 'docs/note.md') -join "`n"
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
    $dsAuto = (Invoke-GuardRaw diff-scope -RepoRoot $autoRepo) -join "`n"
    $dsAutoExit = $LASTEXITCODE
    Pop-Location

    if ($dsEmptyExit -eq 2 -and $dsEmpty -match 'EMPTY_DIFF' -and
        $dsNoiseExit -eq 0 -and $dsNoise -match 'size_class=NOISE_ONLY' -and ($dsNoise -match 'risk_level=LOW') -and
        $dsExit -eq 0 -and $dsOut -match 'size_class=XS' -and
        ($dsOut -notmatch '=>') -and $dsOut -match 'src/renamed\.js' -and
        $dsOut -match 'noise_files=package-lock\.json' -and
        $dsOut -match 'delta_files=src/extra\.js' -and ($dsOut -notmatch 'docs/note\.md') -and
        $dsAutoExit -eq 0 -and $dsAuto -match 'size_class=XS' -and ($dsAuto -match 'risk_level=LOW') -and $dsAuto -match 'review_files=feat\.js') {
        Pass 'guard-diff-scope'
    } else {
        FailCheck 'guard-diff-scope' "empty=(${dsEmptyExit}:$dsEmpty) noise=(${dsNoiseExit}:$dsNoise) out=(${dsExit}:$dsOut) auto=(${dsAutoExit}:$dsAuto)"
    }

    $runRepo = Join-Path $sandbox 'run-scoped-repo'
    New-Item -ItemType Directory -Path $runRepo | Out-Null
    $r1 = (Invoke-GuardRaw new-run -RepoRoot $runRepo -Slug 'Add Billing / Webhook!' -Timestamp '20261122-0010').Trim()
    $r1Exit = $LASTEXITCODE
    $r2 = (Invoke-GuardRaw new-run -RepoRoot $runRepo -Slug 'Add Billing / Webhook!' -Timestamp '20261122-0010').Trim()
    $r2Exit = $LASTEXITCODE
    $curContent = (Get-Content -LiteralPath (Join-Path $runRepo '.b3\ship\CURRENT') -Raw).Trim()
    $resActive = (Invoke-GuardRaw resolve-run -RepoRoot $runRepo).Trim()
    $resActiveExit = $LASTEXITCODE
    $resExplicit = (Invoke-GuardRaw resolve-run -RepoRoot $runRepo -RunId $r1).Trim()
    $resExplicitExit = $LASTEXITCODE
    $listOut = ((Invoke-GuardRaw list-runs -RepoRoot $runRepo) -join "`n")

    $legacyRepo = Join-Path $sandbox 'legacy-repo'
    New-Item -ItemType Directory -Path (Join-Path $legacyRepo '.b3\ship') | Out-Null
    Set-Content (Join-Path $legacyRepo '.b3\ship\progress.md') "- run_status: running`n"
    $resLegacy = (Invoke-GuardRaw resolve-run -RepoRoot $legacyRepo).Trim()
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
    $p1 = (Invoke-GuardRaw new-run -RepoRoot $pruneRepo -Slug 'old-pass-1' -Timestamp '20261122-0001').Trim()
    $p2 = (Invoke-GuardRaw new-run -RepoRoot $pruneRepo -Slug 'old-pass-2' -Timestamp '20261122-0002').Trim()
    $p3 = (Invoke-GuardRaw new-run -RepoRoot $pruneRepo -Slug 'active-running' -Timestamp '20261122-0003').Trim()
    $p4 = (Invoke-GuardRaw new-run -RepoRoot $pruneRepo -Slug 'latest-pass' -Timestamp '20261122-0004').Trim()
    Set-Content (Join-Path $pruneRepo ".b3\ship\runs\$p1\progress.md") "- run_status: PASS`n"
    Set-Content (Join-Path $pruneRepo ".b3\ship\runs\$p2\progress.md") "- run_status: PASS`n"
    Set-Content (Join-Path $pruneRepo ".b3\ship\runs\$p3\progress.md") "- run_status: running`n"
    Set-Content (Join-Path $pruneRepo ".b3\ship\runs\$p4\progress.md") "- run_status: PASS`n"
    Set-Content (Join-Path $pruneRepo '.b3\ship\CURRENT') "$p1`n"

    $pruneOut = ((Invoke-GuardRaw prune -RepoRoot $pruneRepo -Keep 1) -join "`n")
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
    $pNest = (Invoke-GuardRaw new-run -RepoRoot $prPsRepo -Slug 'nested-pass' -Timestamp '20261122-0001').Trim()
    $pCurPs = (Invoke-GuardRaw new-run -RepoRoot $prPsRepo -Slug 'current-active' -Timestamp '20261122-0003').Trim()
    Set-Content (Join-Path $prPsRepo ".b3\ship\runs\$pNest\progress.md") "- run_status: PASS`n"
    Set-Content (Join-Path $prPsRepo ".b3\ship\runs\$pCurPs\progress.md") "- run_status: running`n"
    New-Item -ItemType Junction -Path (Join-Path $prPsRepo ".b3\ship\runs\$pNest\nested-junc") -Target $prDecoyNested | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $prPsRepo ".b3\ship\runs\20261122-0002-top-junc") -Target $prDecoyTop | Out-Null
    $prPsOut = ((Invoke-GuardRaw prune -RepoRoot $prPsRepo -Keep 0) -join "`n")
    $prPsExit = $LASTEXITCODE

    $prLinkRepoPs = Join-Path $prLinkRoot 'repo-runs-link-ps'
    New-Item -ItemType Directory -Path (Join-Path $prLinkRepoPs '.b3\ship') -Force | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $prLinkRepoPs '.b3\ship\runs') -Target $prDecoyRuns | Out-Null
    $prevEapPr = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $prLinkFailPs = ((Invoke-GuardRaw prune -RepoRoot $prLinkRepoPs -Keep 0 2>&1) -join "`n")
    $prLinkFailPsExit = $LASTEXITCODE
    $ErrorActionPreference = $prevEapPr

    $prRepShOk = $true
    if ($script:HasBash) {
        $guardShPosixPr = (To-PosixPath $root) + '/scripts/b3-guard.sh'
        $prShRepo = Join-Path $prLinkRoot 'repo-sh'
        $pNestSh = (Invoke-GuardRaw new-run -RepoRoot $prShRepo -Slug 'nested-pass-sh' -Timestamp '20261122-0001').Trim()
        $pCurSh = (Invoke-GuardRaw new-run -RepoRoot $prShRepo -Slug 'current-active-sh' -Timestamp '20261122-0003').Trim()
        Set-Content (Join-Path $prShRepo ".b3\ship\runs\$pNestSh\progress.md") "- run_status: PASS`n"
        Set-Content (Join-Path $prShRepo ".b3\ship\runs\$pCurSh\progress.md") "- run_status: running`n"
        New-Item -ItemType Junction -Path (Join-Path $prShRepo ".b3\ship\runs\$pNestSh\nested-junc") -Target $prDecoyNested | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $prShRepo ".b3\ship\runs\20261122-0002-top-junc") -Target $prDecoyTop | Out-Null
        $prShRepoPosix = To-PosixPath $prShRepo
        $prShOut = (& $script:GitBash -c "'$guardShPosixPr' prune --repo-root '$prShRepoPosix' --keep 0") -join "`n"
        $prShExit = $LASTEXITCODE

        $prLinkRepoSh = Join-Path $prLinkRoot 'repo-runs-link-sh'
        New-Item -ItemType Directory -Path (Join-Path $prLinkRepoSh '.b3\ship') -Force | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $prLinkRepoSh '.b3\ship\runs') -Target $prDecoyRuns | Out-Null
        $prLinkShPosix = To-PosixPath $prLinkRepoSh
        $prevEapPrSh = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $prLinkFailSh = (& $script:GitBash -c "'$guardShPosixPr' prune --repo-root '$prLinkShPosix' --keep 0 2>&1") -join "`n"
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
                if ($f.Name -eq 'b3-github-verify.ps1' -and $hit.Line -match '\$env:ComSpec') { continue }
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
    $mClean = ((Invoke-GuardRaw mechanical-check -RepoRoot $mechRepo -BaseSha $mBase -AllowedPaths 'src/a.ts' -Obsoletes 'absentSym') -join "`n")
    $mCleanExit = $LASTEXITCODE
    $mkDbg = 'de' + 'bugger'
    $mkTs = '@ts-' + 'ignore'
    $mkOnly = '.on' + 'ly('
    Set-Content src\a.ts "export const a = 2;`n${mkDbg};`n// ${mkTs}"
    Set-Content src\unowned.ts "test${mkOnly}'x', () => {});"
    $mBad = ((Invoke-GuardRaw mechanical-check -RepoRoot $mechRepo -BaseSha $mBase -AllowedPaths 'src/a.ts' -Obsoletes 'src/dead.ts,oldFn') -join "`n")
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
    $trDsOut = ((Invoke-GuardRaw diff-scope -RepoRoot $trRepo -TargetRef 'src') -join "`n")
    $trDsExit = $LASTEXITCODE
    $trMcOut = ((Invoke-GuardRaw mechanical-check -RepoRoot $trRepo -TargetRef 'src' -AllowedPaths 'src/app.ts,src/pr-only.ts' -Obsoletes 'src/legacy.ts,legacyFn,newFn') -join "`n")
    $trMcExit = $LASTEXITCODE
    $trBadOut = ((Invoke-GuardRaw diff-scope -RepoRoot $trRepo -TargetRef 'nonexistent-ref-xyz') -join "`n")
    $trBadExit = $LASTEXITCODE
    $trDashOut = ((Invoke-GuardRaw diff-scope -RepoRoot $trRepo -TargetRef '--bad-flag') -join "`n")
    $trDashExit = $LASTEXITCODE

    $trShOk = $true
    if ($script:HasBash) {
        $guardShPosix = ($root -replace '\\', '/') + '/scripts/b3-guard.sh'
        $trRepoPosix = $trRepo -replace '\\', '/'
        $shDs = (& $script:GitBash -c "'$guardShPosix' diff-scope --repo-root '$trRepoPosix' --target-ref 'src'") -join "`n"
        $shDsExit = $LASTEXITCODE
        $shMc = (& $script:GitBash -c "'$guardShPosix' mechanical-check --repo-root '$trRepoPosix' --target-ref 'src' --allowed-paths 'src/app.ts,src/pr-only.ts' --obsoletes 'src/legacy.ts,legacyFn,newFn'") -join "`n"
        $shMcExit = $LASTEXITCODE
        $shDash = (& $script:GitBash -c "'$guardShPosix' mechanical-check --repo-root '$trRepoPosix' --target-ref '--bad-flag'") -join "`n"
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

    $wOk = ((Invoke-GuardRaw check-wave -WaveSpecs 'T002=src/api/a.ts,./src/api/a.ts;T003=src/ui/b.tsx') -join "`n")
    $wOkExit = $LASTEXITCODE
    $wBad = ((Invoke-GuardRaw check-wave -WaveSpecs 'T002=src/api,.;T003=src/api/orders.ts') -join "`n")
    $wBadExit = $LASTEXITCODE
    if ($wOkExit -eq 0 -and $wOk -match 'WAVE_OK: disjoint \(2 tasks, 2 paths\)' -and
        $wBadExit -eq 2 -and $wBad -match 'WAVE_CONFLICT:' -and $wBad -match 'src/api<->src/api/orders\.ts' -and $wBad -match '\.<->src/api/orders\.ts') {
        Pass 'guard-check-wave'
    } else {
        FailCheck 'guard-check-wave' "ok=(${wOkExit}:$wOk) bad=(${wBadExit}:$wBad)"
    }

    # --- guard-size-boundary: <50 files and <2000 lines = L; >=50 or >=2000 = XL (up to 100f / 5000L) ---
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
    $sb1999 = ((Invoke-GuardRaw diff-scope -RepoRoot $sbRepo -BaseSha HEAD) -join "`n")
    $sb1999Exit = $LASTEXITCODE
    [IO.File]::WriteAllText($bigPath, ("export const x = 1;`n" * 2000), $utf8NoBom)
    $sb2000 = ((Invoke-GuardRaw diff-scope -RepoRoot $sbRepo -BaseSha HEAD) -join "`n")
    $sb2000Exit = $LASTEXITCODE
    Remove-Item -LiteralPath $bigPath -Force

    1..49 | ForEach-Object {
        [IO.File]::WriteAllText((Join-Path $sbRepo "src\f$_.ts"), "export const v$_ = $_;`n", $utf8NoBom)
    }
    $sb49 = ((Invoke-GuardRaw diff-scope -RepoRoot $sbRepo -BaseSha HEAD) -join "`n")
    $sb49Exit = $LASTEXITCODE
    [IO.File]::WriteAllText((Join-Path $sbRepo 'src\f50.ts'), "export const v50 = 50;`n", $utf8NoBom)
    $sb50 = ((Invoke-GuardRaw diff-scope -RepoRoot $sbRepo -BaseSha HEAD) -join "`n")
    $sb50Exit = $LASTEXITCODE

    $sbShOk = $true
    if ($script:HasBash) {
        $guardShPosix = ($root -replace '\\', '/') + '/scripts/b3-guard.sh'
        $sbRepoPosix = $sbRepo -replace '\\', '/'
        $sh50 = (& $script:GitBash -c "'$guardShPosix' diff-scope --repo-root '$sbRepoPosix' --base-sha HEAD") -join "`n"
        $sh50Exit = $LASTEXITCODE
        Remove-Item -LiteralPath (Join-Path $sbRepo 'src\f50.ts') -Force
        $sh49 = (& $script:GitBash -c "'$guardShPosix' diff-scope --repo-root '$sbRepoPosix' --base-sha HEAD") -join "`n"
        $sh49Exit = $LASTEXITCODE
        Remove-Item -LiteralPath (Join-Path $sbRepo 'src') -Recurse -Force
        New-Item -ItemType Directory -Path (Join-Path $sbRepo 'src') | Out-Null
        [IO.File]::WriteAllText($bigPath, ("export const x = 1;`n" * 2000), $utf8NoBom)
        $sh2000 = (& $script:GitBash -c "'$guardShPosix' diff-scope --repo-root '$sbRepoPosix' --base-sha HEAD") -join "`n"
        $sh2000Exit = $LASTEXITCODE
        [IO.File]::WriteAllText($bigPath, ("export const x = 1;`n" * 1999), $utf8NoBom)
        $sh1999 = (& $script:GitBash -c "'$guardShPosix' diff-scope --repo-root '$sbRepoPosix' --base-sha HEAD") -join "`n"
        $sh1999Exit = $LASTEXITCODE
        $sbShOk = ($sh50Exit -eq 0) -and ($sh50 -match 'size_class=XL') -and ($sh50 -match 'files=50') -and
                  ($sh49Exit -eq 0) -and ($sh49 -match 'size_class=L\b') -and ($sh49 -match 'files=49') -and
                  ($sh2000Exit -eq 0) -and ($sh2000 -match 'size_class=XL') -and ($sh2000 -match 'lines=2000') -and
                  ($sh1999Exit -eq 0) -and ($sh1999 -match 'size_class=L\b') -and ($sh1999 -match 'lines=1999')
    }
    Pop-Location
    if ($sb1999Exit -eq 0 -and ($sb1999 -match 'size_class=L\b') -and ($sb1999 -match 'lines=1999') -and
        $sb2000Exit -eq 0 -and ($sb2000 -match 'size_class=XL') -and ($sb2000 -match 'lines=2000') -and
        $sb49Exit -eq 0 -and ($sb49 -match 'size_class=L\b') -and ($sb49 -match 'files=49') -and
        $sb50Exit -eq 0 -and ($sb50 -match 'size_class=XL') -and ($sb50 -match 'files=50') -and $sbShOk) {
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
    $vrPass = ((Invoke-GuardRaw verify-run -RepoRoot $vrRepo -VerifyCmd 'echo green-ok' -ReceiptPath $rec -TaskId T001 -RelevantPaths 'src/a.ts') -join "`n")
    $vrPassExit = $LASTEXITCODE
    $vcValid = ((Invoke-GuardRaw verify-check -RepoRoot $vrRepo -ReceiptPath $rec) -join "`n")
    $vcValidExit = $LASTEXITCODE
    # Scoped RelevantPaths ignores unrelated edit
    Set-Content src\other.ts 'export const o = 2;'
    $vcUnrel = ((Invoke-GuardRaw verify-check -RepoRoot $vrRepo -ReceiptPath $rec) -join "`n")
    $vcUnrelExit = $LASTEXITCODE
    # Staging verified file passes precommit -RequireVerifyReceipt
    git add src\a.ts
    $pcVrOk = ((Invoke-GuardRaw precommit -RepoRoot $vrRepo -AllowedPaths 'src/a.ts' -RequireVerifyReceipt $rec) -join "`n")
    $pcVrOkExit = $LASTEXITCODE
    # Partial staging (index != WT while receipt matches WT) fails precommit
    Set-Content src\a.ts 'export const a = 3;'
    $vrPass2 = ((Invoke-GuardRaw verify-run -RepoRoot $vrRepo -VerifyCmd 'echo green-2' -ReceiptPath $rec -TaskId T001 -RelevantPaths 'src/a.ts') -join "`n")
    $vrPass2Exit = $LASTEXITCODE
    $pcPartial = ((Invoke-GuardRaw precommit -RepoRoot $vrRepo -AllowedPaths 'src/a.ts' -RequireVerifyReceipt $rec) -join "`n")
    $pcPartialExit = $LASTEXITCODE
    # Sync index: old partial-stage receipt must now be VERIFY_STALE (H-03), then re-verify synced state before testing out-of-scope rejection
    git add src\a.ts
    $vcPartialStale = ((Invoke-GuardRaw verify-check -RepoRoot $vrRepo -ReceiptPath $rec) -join "`n")
    $vcPartialStaleExit = $LASTEXITCODE
    $vrPassSynced = ((Invoke-GuardRaw verify-run -RepoRoot $vrRepo -VerifyCmd 'echo green-synced' -ReceiptPath $rec -TaskId T001 -RelevantPaths 'src/a.ts') -join "`n")
    $vrPassSyncedExit = $LASTEXITCODE
    Set-Content src\extra.ts 'export const e = 2;'
    git add src\extra.ts
    $pcOutScope = ((Invoke-GuardRaw precommit -RepoRoot $vrRepo -AllowedPaths 'src/a.ts,src/extra.ts' -RequireVerifyReceipt $rec) -join "`n")
    $pcOutScopeExit = $LASTEXITCODE
    git reset -q HEAD src\extra.ts
    git checkout -- src\extra.ts
    # Editing relevant file invalidates receipt -> VERIFY_STALE (exit 2) + blocks precommit
    Set-Content src\a.ts 'export const a = 4;'
    $vcStale = ((Invoke-GuardRaw verify-check -RepoRoot $vrRepo -ReceiptPath $rec) -join "`n")
    $vcStaleExit = $LASTEXITCODE
    git add src\a.ts
    $pcVrStale = ((Invoke-GuardRaw precommit -RepoRoot $vrRepo -AllowedPaths 'src/a.ts' -RequireVerifyReceipt $rec) -join "`n")
    $pcVrStaleExit = $LASTEXITCODE
    # Failing verify command writes FAIL receipt + log
    $recFail = '.b3/ship/runs/r1/evidence/T002.verify'
    $vrFail = ((Invoke-GuardRaw verify-run -RepoRoot $vrRepo -VerifyCmd 'Write-Output "bad-check"; exit 3' -ReceiptPath $recFail -TaskId T002) -join "`n")
    $vrFailExit = $LASTEXITCODE
    $vcFail = ((Invoke-GuardRaw verify-check -RepoRoot $vrRepo -ReceiptPath $recFail) -join "`n")
    $vcFailExit = $LASTEXITCODE
    $failLogExists = Test-Path -LiteralPath (Join-Path $vrRepo "$recFail.log") -PathType Leaf
    # >64KB failing output (no SIGPIPE 141, exit strictly 1, full log, capped output), trailing # comment, root '.' path match, and git rm --cached partial mismatch
    $recBig = '.b3/ship/runs/r1/evidence/big.verify'
    $vrBig = ((Invoke-GuardRaw verify-run -RepoRoot $vrRepo -VerifyCmd '1..1500 | ForEach-Object { 10001..10010 -join 9 }; exit 2' -ReceiptPath $recBig) -join "`n")
    $vrBigExit = $LASTEXITCODE
    $vrComment = ((Invoke-GuardRaw verify-run -RepoRoot $vrRepo -VerifyCmd 'echo ok # trailing' -ReceiptPath '.b3/ship/runs/r1/evidence/cmt.verify' -RelevantPaths '.') -join "`n")
    $vrCommentExit = $LASTEXITCODE
    $vcDotOk = ((Invoke-GuardRaw verify-check -RepoRoot $vrRepo -ReceiptPath '.b3/ship/runs/r1/evidence/cmt.verify') -join "`n")
    $vcDotOkExit = $LASTEXITCODE
    Set-Content src\other.ts 'export const o = 99;'
    $vcDotStale = ((Invoke-GuardRaw verify-check -RepoRoot $vrRepo -ReceiptPath '.b3/ship/runs/r1/evidence/cmt.verify') -join "`n")
    $vcDotStaleExit = $LASTEXITCODE
    $pcDotOk = ((Invoke-GuardRaw precommit -RepoRoot $vrRepo -AllowedPaths '.') -join "`n")
    $pcDotOkExit = $LASTEXITCODE
    git rm -q --cached src\extra.ts
    $pcRmCached = ((Invoke-GuardRaw precommit -RepoRoot $vrRepo -AllowedPaths '.' -RequireVerifyReceipt '.b3/ship/runs/r1/evidence/cmt.verify') -join "`n")
    $pcRmCachedExit = $LASTEXITCODE
    git add src\extra.ts
    # Corrupt & missing receipt
    $recCorrupt = Join-Path $vrRepo '.b3\ship\runs\r1\evidence\bad.verify'
    Set-Content $recCorrupt "schema=b3-verify-v1`nstatus=PASS"
    $vcCorrupt = ((Invoke-GuardRaw verify-check -RepoRoot $vrRepo -ReceiptPath '.b3/ship/runs/r1/evidence/bad.verify') -join "`n")
    $vcCorruptExit = $LASTEXITCODE
    $vcMissing = ((Invoke-GuardRaw verify-check -RepoRoot $vrRepo -ReceiptPath '.b3/ship/runs/r1/evidence/none.verify') -join "`n")
    $vcMissingExit = $LASTEXITCODE

    $vrShOk = $true
    if ($script:HasBash) {
        $guardShPosix = ($root -replace '\\', '/') + '/scripts/b3-guard.sh'
        $vrRepoPosix = $vrRepo -replace '\\', '/'
        $shRec = '.b3/ship/runs/r1/evidence/sh.verify'
        $shPass = (& $script:GitBash -c "'$guardShPosix' verify-run --repo-root '$vrRepoPosix' --verify-cmd 'echo sh-ok # sh-comment' --receipt-path '$shRec' --task-id T003 --relevant-paths 'src/a.ts'") -join "`n"
        $shPassExit = $LASTEXITCODE
        # Cross-shell verification: .ps1 verify-check validates .sh receipt and produces identical tree hash
        $psOfSh = ((Invoke-GuardRaw verify-check -RepoRoot $vrRepo -ReceiptPath $shRec) -join "`n")
        $psOfShExit = $LASTEXITCODE
        $shPcOk = (& $script:GitBash -c "'$guardShPosix' precommit --repo-root '$vrRepoPosix' --allowed-paths 'src/a.ts' --require-verify-receipt '$shRec'") -join "`n"
        $shPcOkExit = $LASTEXITCODE
        $shDot = (& $script:GitBash -c "'$guardShPosix' verify-run --repo-root '$vrRepoPosix' --verify-cmd 'echo dot-ok' --receipt-path '.b3/ship/runs/r1/evidence/shdot.verify' --relevant-paths '.'") -join "`n"
        $shDotExit = $LASTEXITCODE
        $shBigCmd = 'seq 1 15000; exit 2'
        $shBig = (& $script:GitBash -c "'$guardShPosix' verify-run --repo-root '$vrRepoPosix' --verify-cmd '$shBigCmd' --receipt-path '.b3/ship/runs/r1/evidence/shbig.verify'") -join "`n"
        $shBigExit = $LASTEXITCODE
        Set-Content src\a.ts 'export const a = 5;'
        $shStale = (& $script:GitBash -c "'$guardShPosix' verify-check --repo-root '$vrRepoPosix' --receipt-path '$shRec'") -join "`n"
        $shStaleExit = $LASTEXITCODE
        $shDotStale = (& $script:GitBash -c "'$guardShPosix' verify-check --repo-root '$vrRepoPosix' --receipt-path '.b3/ship/runs/r1/evidence/shdot.verify'") -join "`n"
        $shDotStaleExit = $LASTEXITCODE
        $shFail = (& $script:GitBash -c "'$guardShPosix' verify-run --repo-root '$vrRepoPosix' --verify-cmd 'echo sh-err; exit 4' --receipt-path '.b3/ship/runs/r1/evidence/shfail.verify' --task-id T004") -join "`n"
        $shFailExit = $LASTEXITCODE
        $shCorrupt = (& $script:GitBash -c "'$guardShPosix' verify-check --repo-root '$vrRepoPosix' --receipt-path '.b3/ship/runs/r1/evidence/bad.verify'") -join "`n"
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
        $vcPartialStaleExit -eq 2 -and ($vcPartialStale -match 'VERIFY_STALE:') -and
        $vrPassSyncedExit -eq 0 -and ($vrPassSynced -match 'VERIFY_PASS:') -and
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
        FailCheck 'guard-verify-receipt' "vrPass=(${vrPassExit}:$vrPass) pStale=(${vcPartialStaleExit}:$vcPartialStale) vrSync=(${vrPassSyncedExit}:$vrPassSynced) pcOut=(${pcOutScopeExit}:$pcOutScope) vrBig=(${vrBigExit}:$vrBig) vrCmt=(${vrCommentExit}:$vrComment) vcDot=(${vcDotOkExit}/${vcDotStaleExit}) pcRm=(${pcRmCachedExit}:$pcRmCached) stale=(${vcStaleExit}:$vcStale) shOk=$vrShOk"
    }

    # --- guard-git-stderr-isolation (R001: core.autocrlf stderr warnings never corrupt SHAs/receipts/diffs) ---
    $errRepo = Join-Path $sandbox 'stderr-repo'
    New-Item -ItemType Directory -Path (Join-Path $errRepo 'src') -Force | Out-Null
    Push-Location $errRepo
    $prevErrEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        git init -q; git config user.email 'ship-test@example.com'; git config user.name 'Ship Test'
        git config core.autocrlf true
        [IO.File]::WriteAllText((Join-Path $errRepo 'src\a.ts'), "export const x = 1;`r`n", (New-Object System.Text.UTF8Encoding($false)))
        git add . 2>&1 | Out-Null; git commit -qm 'init' 2>&1 | Out-Null
        [IO.File]::WriteAllText((Join-Path $errRepo 'src\a.ts'), "export const x = 2;`nexport function hello(): number { return x; }`n", (New-Object System.Text.UTF8Encoding($false)))
    } finally {
        $ErrorActionPreference = $prevErrEap
    }
    $errRecPs = '.b3/ship/runs/r1/evidence/err-ps.verify'
    $errVr = ((Invoke-GuardRaw verify-run -RepoRoot $errRepo -VerifyCmd 'echo stderr-ok' -ReceiptPath $errRecPs -TaskId T001 -RelevantPaths 'src/a.ts') -join "`n")
    $errVrExit = $LASTEXITCODE
    $errRecTxt = [IO.File]::ReadAllText((Join-Path $errRepo $errRecPs))
    $errHashOk = ($errRecTxt -match '(?m)^head_sha=[0-9a-f]{40}\r?$') -and ($errRecTxt -match '(?m)^tree_hash=[0-9a-f]{40}\r?$') -and ($errRecTxt -notmatch 'warning:')
    $errVc = ((Invoke-GuardRaw verify-check -RepoRoot $errRepo -ReceiptPath $errRecPs) -join "`n")
    $errVcExit = $LASTEXITCODE
    $prevErrEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { git add src\a.ts 2>&1 | Out-Null } finally { $ErrorActionPreference = $prevErrEap }
    $errPc = ((Invoke-GuardRaw precommit -RepoRoot $errRepo -AllowedPaths 'src/a.ts' -RequireVerifyReceipt $errRecPs) -join "`n")
    $errPcExit = $LASTEXITCODE
    $errDs = ((Invoke-GuardRaw diff-scope -RepoRoot $errRepo) -join "`n")
    $errDsExit = $LASTEXITCODE
    $errMech = ((Invoke-GuardRaw mechanical-check -RepoRoot $errRepo -AllowedPaths 'src/a.ts') -join "`n")
    $errMechExit = $LASTEXITCODE
    $errSym = ((Invoke-GuardRaw symbol-check -RepoRoot $errRepo) -join "`n")
    $errSymExit = $LASTEXITCODE
    $errShOk = $true
    if ($script:HasBash) {
        $guardShPosix = ($root -replace '\\', '/') + '/scripts/b3-guard.sh'
        $errRepoP = $errRepo -replace '\\', '/'
        $shErrRec = '.b3/ship/runs/r1/evidence/err-sh.verify'
        $prevShEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try {
            $shErrVr = (& $script:GitBash -c "'$guardShPosix' verify-run --repo-root '$errRepoP' --verify-cmd 'echo stderr-ok' --receipt-path '$shErrRec' --task-id T001 --relevant-paths 'src/a.ts' 2>&1" | ForEach-Object { "$_" }) -join "`n"
            $shErrVrExit = $LASTEXITCODE
            $psOfShErr = ((Invoke-GuardRaw verify-check -RepoRoot $errRepo -ReceiptPath $shErrRec 2>&1) | ForEach-Object { "$_" }) -join "`n"
            $psOfShErrExit = $LASTEXITCODE
            $shOfPsErr = (& $script:GitBash -c "'$guardShPosix' verify-check --repo-root '$errRepoP' --receipt-path '$errRecPs' 2>&1" | ForEach-Object { "$_" }) -join "`n"
            $shOfPsErrExit = $LASTEXITCODE
            $shErrPc = (& $script:GitBash -c "'$guardShPosix' precommit --repo-root '$errRepoP' --allowed-paths 'src/a.ts' --require-verify-receipt '$shErrRec' 2>&1" | ForEach-Object { "$_" }) -join "`n"
            $shErrPcExit = $LASTEXITCODE
            $shErrDs = (& $script:GitBash -c "'$guardShPosix' diff-scope --repo-root '$errRepoP' 2>&1" | ForEach-Object { "$_" }) -join "`n"
            $shErrDsExit = $LASTEXITCODE
            $shErrMech = (& $script:GitBash -c "'$guardShPosix' mechanical-check --repo-root '$errRepoP' --allowed-paths 'src/a.ts' 2>&1" | ForEach-Object { "$_" }) -join "`n"
            $shErrMechExit = $LASTEXITCODE
            $shErrSym = (& $script:GitBash -c "'$guardShPosix' symbol-check --repo-root '$errRepoP' 2>&1" | ForEach-Object { "$_" }) -join "`n"
            $shErrSymExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prevShEap
        }
        $errShOk = ($shErrVrExit -eq 0) -and ($shErrVr -match 'VERIFY_PASS:') -and ($shErrVr -notmatch 'warning:') -and
                   ($psOfShErrExit -eq 0) -and ($psOfShErr -match 'VERIFY_VALID:') -and ($psOfShErr -notmatch 'warning:') -and
                   ($shOfPsErrExit -eq 0) -and ($shOfPsErr -match 'VERIFY_VALID:') -and ($shOfPsErr -notmatch 'warning:') -and
                   ($shErrPcExit -eq 0) -and ($shErrPc -eq 'PRECOMMIT_OK') -and
                   ($shErrDsExit -eq 0) -and ($shErrDs -notmatch 'warning:') -and
                   ($shErrMechExit -eq 0) -and ($shErrMech -match 'MECHANICAL_OK') -and ($shErrMech -notmatch 'warning:') -and
                   ($shErrSymExit -in @(0, 2)) -and ($shErrSym -notmatch 'warning:')
    }
    Pop-Location
    if ($errVrExit -eq 0 -and $errHashOk -and $errVcExit -eq 0 -and ($errVc -match 'VERIFY_VALID:') -and
        $errPcExit -eq 0 -and $errPc -eq 'PRECOMMIT_OK' -and
        $errDsExit -eq 0 -and ($errDs -notmatch 'warning:') -and
        $errMechExit -eq 0 -and ($errMech -match 'MECHANICAL_OK') -and
        ($errSymExit -in @(0, 2)) -and $errShOk) {
        Pass 'guard-git-stderr-isolation'
    } else {
        FailCheck 'guard-git-stderr-isolation' "vr=$errVrExit hash=$errHashOk vc=$errVcExit pc=$errPcExit ds=$errDsExit mech=$errMechExit sym=$errSymExit sh=$errShOk"
    }

    # --- guard-verify-receipt-lifecycle (R005: parallel waves, Finalize reuse, Resume check, amend/edit stale) ---
    $lcRepo = Join-Path $sandbox 'lifecycle-repo'
    New-Item -ItemType Directory -Path (Join-Path $lcRepo 'src') -Force | Out-Null
    Push-Location $lcRepo
    git init -q; git config user.email 'ship-test@example.com'; git config user.name 'Ship Test'
    Set-Content src\a.ts 'export const a = 1;'
    Set-Content src\b.ts 'export const b = 1;'
    Set-Content src\c.ts 'export const c = 1;'
    git add .; git commit -qm 'init'
    # Parallel wave at H0: both T001 (src/a.ts) and T002 (src/b.ts) verified before sequential commits
    Set-Content src\a.ts 'export const a = 2;'
    Set-Content src\b.ts 'export const b = 2;'
    $rT1 = '.b3/ship/runs/r1/evidence/T001.verify'
    $rT2 = '.b3/ship/runs/r1/evidence/T002.verify'
    $rAll = '.b3/ship/runs/r1/evidence/ALL.verify'
    $null = Invoke-GuardRaw verify-run -RepoRoot $lcRepo -VerifyCmd 'echo t1' -ReceiptPath $rT1 -TaskId T001 -RelevantPaths 'src/a.ts'
    $lcV1 = $LASTEXITCODE
    $null = Invoke-GuardRaw verify-run -RepoRoot $lcRepo -VerifyCmd 'echo t2' -ReceiptPath $rT2 -TaskId T002 -RelevantPaths 'src/b.ts'
    $lcV2 = $LASTEXITCODE
    # Commit T001 while T002 remains dirty unstaged
    git add src\a.ts
    $lcPc1 = ((Invoke-GuardRaw precommit -RepoRoot $lcRepo -AllowedPaths 'src/a.ts' -RequireVerifyReceipt $rT1) -join "`n")
    $lcPc1Exit = $LASTEXITCODE
    git commit -qm 'T001'
    # After H0 -> H1 commit, T002.verify MUST still be valid and commit cleanly without re-verifying T002
    $lcVc2AfterH1 = ((Invoke-GuardRaw verify-check -RepoRoot $lcRepo -ReceiptPath $rT2) -join "`n")
    $lcVc2Exit = $LASTEXITCODE
    git add src\b.ts
    $lcPc2 = ((Invoke-GuardRaw precommit -RepoRoot $lcRepo -AllowedPaths 'src/b.ts' -RequireVerifyReceipt $rT2) -join "`n")
    $lcPc2Exit = $LASTEXITCODE
    git commit -qm 'T002'
    # Finalize/Resume: full-repo receipt before final T003 commit stays valid after T003 commits; T001 receipt stays valid across commits
    Set-Content src\c.ts 'export const c = 2;'
    $null = Invoke-GuardRaw verify-run -RepoRoot $lcRepo -VerifyCmd 'echo all' -ReceiptPath $rAll -TaskId FINAL
    $lcVAll = $LASTEXITCODE
    git add src\c.ts
    $lcPcAll = ((Invoke-GuardRaw precommit -RepoRoot $lcRepo -AllowedPaths 'src/c.ts' -RequireVerifyReceipt $rAll) -join "`n")
    $lcPcAllExit = $LASTEXITCODE
    git commit -qm 'T003'
    $lcResT1 = ((Invoke-GuardRaw verify-check -RepoRoot $lcRepo -ReceiptPath $rT1) -join "`n")
    $lcResT1Exit = $LASTEXITCODE
    $lcFinAll = ((Invoke-GuardRaw verify-check -RepoRoot $lcRepo -ReceiptPath $rAll) -join "`n")
    $lcFinAllExit = $LASTEXITCODE
    $shFinAllOk = $true
    if ($script:HasBash) {
        $guardShPosixPre = ($root -replace '\\', '/') + '/scripts/b3-guard.sh'
        $lcRepoPPre = $lcRepo -replace '\\', '/'
        $shFinAll = (& $script:GitBash -c "'$guardShPosixPre' verify-check --repo-root '$lcRepoPPre' --receipt-path '$rAll'") -join "`n"
        $shFinAllOk = ($LASTEXITCODE -eq 0) -and ($shFinAll -match 'VERIFY_VALID:')
    }
    # Subsequent edit invalidates T001 receipt -> VERIFY_STALE (exit 2)
    Set-Content src\a.ts 'export const a = 3;'
    $lcEditStale = ((Invoke-GuardRaw verify-check -RepoRoot $lcRepo -ReceiptPath $rT1) -join "`n")
    $lcEditStaleExit = $LASTEXITCODE
    git add src\a.ts; git commit -qm 'T004'
    # History rewrite (amend) after receipt invalidates ancestry -> VERIFY_STALE (exit 2) even when content identical
    $rAmend = '.b3/ship/runs/r1/evidence/amend.verify'
    $null = Invoke-GuardRaw verify-run -RepoRoot $lcRepo -VerifyCmd 'echo ok' -ReceiptPath $rAmend -TaskId AMEND -RelevantPaths 'src/a.ts'
    git commit --amend -q -m 'T004-amended'
    $lcAmendStale = ((Invoke-GuardRaw verify-check -RepoRoot $lcRepo -ReceiptPath $rAmend) -join "`n")
    $lcAmendStaleExit = $LASTEXITCODE

    $lcShOk = $shFinAllOk
    if ($script:HasBash) {
        $guardShPosix = ($root -replace '\\', '/') + '/scripts/b3-guard.sh'
        $lcRepoP = $lcRepo -replace '\\', '/'
        $shFinStale = (& $script:GitBash -c "'$guardShPosix' verify-check --repo-root '$lcRepoP' --receipt-path '$rAll'") -join "`n"
        $shFinStaleExit = $LASTEXITCODE
        $shAmendStale = (& $script:GitBash -c "'$guardShPosix' verify-check --repo-root '$lcRepoP' --receipt-path '$rAmend'") -join "`n"
        $shAmendStaleExit = $LASTEXITCODE
        # Cross-commit PS->SH verify-run & commit & SH verify-check parity
        Set-Content src\b.ts 'export const b = 3;'
        $shWaveRec = '.b3/ship/runs/r1/evidence/sh-wave.verify'
        $null = & $script:GitBash -c "'$guardShPosix' verify-run --repo-root '$lcRepoP' --verify-cmd 'echo sh-wave' --receipt-path '$shWaveRec' --task-id SHW --relevant-paths 'src/b.ts'"
        $shWaveRunExit = $LASTEXITCODE
        git add src\b.ts
        $shWavePc = (& $script:GitBash -c "'$guardShPosix' precommit --repo-root '$lcRepoP' --allowed-paths 'src/b.ts' --require-verify-receipt '$shWaveRec'") -join "`n"
        $shWavePcExit = $LASTEXITCODE
        git commit -qm 'SHW'
        $shWaveAfter = (& $script:GitBash -c "'$guardShPosix' verify-check --repo-root '$lcRepoP' --receipt-path '$shWaveRec'") -join "`n"
        $shWaveAfterExit = $LASTEXITCODE
        # R003 core.quotepath=false cross-shell parity on non-ASCII filename (constructed ASCII-cleanly)
        $uRel = 'src/caf' + [char]0x00e9 + '.ts'
        $uFull = Join-Path $lcRepo ($uRel -replace '/', '\')
        [IO.File]::WriteAllText($uFull, "export const cafe = 1;`n", (New-Object System.Text.UTF8Encoding($false)))
        $rUtf = '.b3/ship/runs/r1/evidence/utf8.verify'
        $psU1 = ((Invoke-GuardRaw verify-run -RepoRoot $lcRepo -VerifyCmd 'echo u1' -ReceiptPath $rUtf -TaskId U1) -join "`n")
        $psU1Exit = $LASTEXITCODE
        $shU1 = (& $script:GitBash -c "'$guardShPosix' verify-check --repo-root '$lcRepoP' --receipt-path '$rUtf'") -join "`n"
        $shU1Exit = $LASTEXITCODE
        [IO.File]::WriteAllText($uFull, "export const cafe = 2;`n", (New-Object System.Text.UTF8Encoding($false)))
        $psUStale = ((Invoke-GuardRaw verify-check -RepoRoot $lcRepo -ReceiptPath $rUtf) -join "`n")
        $psUStaleExit = $LASTEXITCODE
        $shUStale = (& $script:GitBash -c "'$guardShPosix' verify-check --repo-root '$lcRepoP' --receipt-path '$rUtf'") -join "`n"
        $shUStaleExit = $LASTEXITCODE
        $rUtf2 = '.b3/ship/runs/r1/evidence/utf8-2.verify'
        $shU2 = (& $script:GitBash -c "'$guardShPosix' verify-run --repo-root '$lcRepoP' --verify-cmd 'echo u2' --receipt-path '$rUtf2' --task-id U2") -join "`n"
        $shU2Exit = $LASTEXITCODE
        $psU2 = ((Invoke-GuardRaw verify-check -RepoRoot $lcRepo -ReceiptPath $rUtf2) -join "`n")
        $psU2Exit = $LASTEXITCODE
        git add src
        $psUPc = ((Invoke-GuardRaw precommit -RepoRoot $lcRepo -AllowedPaths 'src' -RequireVerifyReceipt $rUtf2) -join "`n")
        $psUPcExit = $LASTEXITCODE
        $shUPc = (& $script:GitBash -c "'$guardShPosix' precommit --repo-root '$lcRepoP' --allowed-paths 'src' --require-verify-receipt '$rUtf2'") -join "`n"
        $shUPcExit = $LASTEXITCODE
        $uOk = ($psU1Exit -eq 0) -and ($psU1 -match 'VERIFY_PASS:') -and
               ($shU1Exit -eq 0) -and ($shU1 -match 'VERIFY_VALID:') -and
               ($psUStaleExit -eq 2) -and ($psUStale -match 'VERIFY_STALE:') -and
               ($shUStaleExit -eq 2) -and ($shUStale -match 'VERIFY_STALE:') -and
               ($shU2Exit -eq 0) -and ($shU2 -match 'VERIFY_PASS:') -and
               ($psU2Exit -eq 0) -and ($psU2 -match 'VERIFY_VALID:') -and
               ($psUPcExit -eq 0) -and ($psUPc -eq 'PRECOMMIT_OK') -and
               ($shUPcExit -eq 0) -and ($shUPc -eq 'PRECOMMIT_OK')
        $lcShOk = $shFinAllOk -and
                  ($shFinStaleExit -eq 2) -and ($shFinStale -match 'VERIFY_STALE:') -and
                  ($shAmendStaleExit -eq 2) -and ($shAmendStale -match 'VERIFY_STALE:') -and
                  ($shWaveRunExit -eq 0) -and ($shWavePcExit -eq 0) -and ($shWavePc -eq 'PRECOMMIT_OK') -and
                  ($shWaveAfterExit -eq 0) -and ($shWaveAfter -match 'VERIFY_VALID:') -and $uOk
    }
    Pop-Location
    if ($lcV1 -eq 0 -and $lcV2 -eq 0 -and $lcPc1Exit -eq 0 -and $lcPc1 -eq 'PRECOMMIT_OK' -and
        $lcVc2Exit -eq 0 -and ($lcVc2AfterH1 -match 'VERIFY_VALID:') -and
        $lcPc2Exit -eq 0 -and $lcPc2 -eq 'PRECOMMIT_OK' -and $lcVAll -eq 0 -and
        $lcPcAllExit -eq 0 -and $lcPcAll -eq 'PRECOMMIT_OK' -and
        $lcResT1Exit -eq 0 -and ($lcResT1 -match 'VERIFY_VALID:') -and
        $lcFinAllExit -eq 0 -and ($lcFinAll -match 'VERIFY_VALID:') -and
        $lcEditStaleExit -eq 2 -and ($lcEditStale -match 'VERIFY_STALE:') -and
        $lcAmendStaleExit -eq 2 -and ($lcAmendStale -match 'VERIFY_STALE:') -and $lcShOk) {
        Pass 'guard-verify-receipt-lifecycle'
    } else {
        FailCheck 'guard-verify-receipt-lifecycle' "pc1=$lcPc1Exit vc2=$lcVc2Exit pc2=$lcPc2Exit fin=$lcFinAllExit res=$lcResT1Exit ed=$lcEditStaleExit am=$lcAmendStaleExit sh=$lcShOk"
    }

    # --- guard-partial-staged-bypass (R006: block unstaged/untracked/deleted files inside receipt scope) ---
    $psRepo = Join-Path $sandbox 'partial-stage-repo'
    New-Item -ItemType Directory -Path (Join-Path $psRepo 'src') -Force | Out-Null
    Push-Location $psRepo
    git init -q; git config user.email 'ship-test@example.com'; git config user.name 'Ship Test'
    Set-Content src\a.ts 'export const a = 1;'
    Set-Content src\b.ts 'export const b = 1;'
    Set-Content src\del.ts 'export const d = 1;'
    git add .; git commit -qm 'init'
    Set-Content src\a.ts 'export const a = 2;'
    Set-Content src\c.ts 'export const c = 2;'
    Remove-Item src\del.ts
    Set-Content src\b.ts 'export const b = 99;' # disjoint parallel task edit outside T001 scope
    $rPart = '.b3/ship/runs/r1/evidence/part.verify'
    $rPartAll = '.b3/ship/runs/r1/evidence/part-all.verify'
    $rPartAllIgn = '.b3/ship/runs/r1/evidence/part-all-ign.verify'
    $null = Invoke-GuardRaw verify-run -RepoRoot $psRepo -VerifyCmd 'echo scoped' -ReceiptPath $rPart -TaskId T001 -RelevantPaths 'src/a.ts,src/c.ts,src/del.ts'
    $null = Invoke-GuardRaw verify-run -RepoRoot $psRepo -VerifyCmd 'echo all' -ReceiptPath $rPartAll -TaskId ALL
    $null = Invoke-GuardRaw verify-run -RepoRoot $psRepo -VerifyCmd 'echo all-ign' -ReceiptPath $rPartAllIgn -TaskId ALL_IGN -IgnoreDirtyPaths 'src/b.ts'
    # Partial stage 1: only src/a.ts staged (src/c.ts untracked, src/del.ts unstaged deletion) -> MUST block
    git add src\a.ts
    $pBlk1 = ((Invoke-GuardRaw precommit -RepoRoot $psRepo -AllowedPaths 'src/a.ts,src/c.ts,src/del.ts' -RequireVerifyReceipt $rPart) -join "`n")
    $pBlk1Exit = $LASTEXITCODE
    # Partial stage 2: stage src/c.ts too (src/del.ts still unstaged deletion) -> MUST block
    git add src\c.ts
    $pBlk2 = ((Invoke-GuardRaw precommit -RepoRoot $psRepo -AllowedPaths 'src/a.ts,src/c.ts,src/del.ts' -RequireVerifyReceipt $rPart) -join "`n")
    $pBlk2Exit = $LASTEXITCODE
    # Full stage of receipt scope while src/b.ts remains dirty outside scope -> PRECOMMIT_OK; ALL receipt blocks dirty src/b.ts, and passing IgnoreDirtyPaths only works if verify-run used the same IgnoreDirtyPaths
    git add -u src\del.ts
    $pOkScoped = ((Invoke-GuardRaw precommit -RepoRoot $psRepo -AllowedPaths 'src/a.ts,src/c.ts,src/del.ts' -RequireVerifyReceipt $rPart) -join "`n")
    $pOkScopedExit = $LASTEXITCODE
    $pBlkAll = ((Invoke-GuardRaw precommit -RepoRoot $psRepo -AllowedPaths 'src/a.ts,src/c.ts,src/del.ts' -RequireVerifyReceipt $rPartAll) -join "`n")
    $pBlkAllExit = $LASTEXITCODE
    $pBlkIgnMismatch = ((Invoke-GuardRaw precommit -RepoRoot $psRepo -AllowedPaths 'src/a.ts,src/c.ts,src/del.ts' -RequireVerifyReceipt $rPartAll -IgnoreDirtyPaths 'src/b.ts') -join "`n")
    $pBlkIgnMismatchExit = $LASTEXITCODE
    $pOkAllIgn = ((Invoke-GuardRaw precommit -RepoRoot $psRepo -AllowedPaths 'src/a.ts,src/c.ts,src/del.ts' -RequireVerifyReceipt $rPartAllIgn -IgnoreDirtyPaths 'src/b.ts') -join "`n")
    $pOkAllIgnExit = $LASTEXITCODE
    # R002 guard: staging an ignored path MUST block even if AllowedPaths covers it
    git add src\b.ts
    $pBlkStgIgn = ((Invoke-GuardRaw precommit -RepoRoot $psRepo -AllowedPaths 'src/a.ts,src/b.ts,src/c.ts,src/del.ts' -RequireVerifyReceipt $rPartAllIgn -IgnoreDirtyPaths 'src/b.ts') -join "`n")
    $pBlkStgIgnExit = $LASTEXITCODE
    git reset -q HEAD src\b.ts

    $partShOk = $true
    if ($script:HasBash) {
        $guardShPosix = ($root -replace '\\', '/') + '/scripts/b3-guard.sh'
        $psRepoP = $psRepo -replace '\\', '/'
        $shOkSc = (& $script:GitBash -c "'$guardShPosix' precommit --repo-root '$psRepoP' --allowed-paths 'src/a.ts,src/c.ts,src/del.ts' --require-verify-receipt '$rPart'") -join "`n"
        $shOkScExit = $LASTEXITCODE
        $shBlkAll = (& $script:GitBash -c "'$guardShPosix' precommit --repo-root '$psRepoP' --allowed-paths 'src/a.ts,src/c.ts,src/del.ts' --require-verify-receipt '$rPartAll'") -join "`n"
        $shBlkAllExit = $LASTEXITCODE
        $shOkAllIgn = (& $script:GitBash -c "'$guardShPosix' precommit --repo-root '$psRepoP' --allowed-paths 'src/a.ts,src/c.ts,src/del.ts' --require-verify-receipt '$rPartAllIgn' --ignore-dirty-paths 'src/b.ts'") -join "`n"
        $shOkAllIgnExit = $LASTEXITCODE
        git add src\b.ts
        $shBlkStgIgn = (& $script:GitBash -c "'$guardShPosix' precommit --repo-root '$psRepoP' --allowed-paths 'src/a.ts,src/b.ts,src/c.ts,src/del.ts' --require-verify-receipt '$rPartAllIgn' --ignore-dirty-paths 'src/b.ts'") -join "`n"
        $shBlkStgIgnExit = $LASTEXITCODE
        git reset -q HEAD src\b.ts
        git reset -q HEAD src\del.ts
        $shBlkDel = (& $script:GitBash -c "'$guardShPosix' precommit --repo-root '$psRepoP' --allowed-paths 'src/a.ts,src/c.ts,src/del.ts' --require-verify-receipt '$rPart'") -join "`n"
        $shBlkDelExit = $LASTEXITCODE
        $partShOk = ($shOkScExit -eq 0) -and ($shOkSc -eq 'PRECOMMIT_OK') -and
                    ($shBlkAllExit -eq 1) -and ($shBlkAll -match 'unstaged changes in receipt scope.*src/b\.ts') -and
                    ($shOkAllIgnExit -eq 0) -and ($shOkAllIgn -eq 'PRECOMMIT_OK') -and
                    ($shBlkStgIgnExit -eq 1) -and ($shBlkStgIgn -match 'staged path excluded by ignore-dirty-paths.*src/b\.ts') -and
                    ($shBlkDelExit -eq 1) -and ($shBlkDel -match 'unstaged changes in receipt scope.*src/del\.ts')
    }
    Pop-Location
    if ($pBlk1Exit -eq 1 -and ($pBlk1 -match 'unstaged changes in receipt scope.*src/c\.ts') -and ($pBlk1 -match 'src/del\.ts') -and
        $pBlk2Exit -eq 1 -and ($pBlk2 -match 'unstaged changes in receipt scope.*src/del\.ts') -and
        $pOkScopedExit -eq 0 -and $pOkScoped -eq 'PRECOMMIT_OK' -and
        $pBlkAllExit -eq 1 -and ($pBlkAll -match 'unstaged changes in receipt scope.*src/b\.ts') -and
        $pBlkIgnMismatchExit -eq 1 -and ($pBlkIgnMismatch -match 'VERIFY_STALE:') -and
        $pOkAllIgnExit -eq 0 -and $pOkAllIgn -eq 'PRECOMMIT_OK' -and
        $pBlkStgIgnExit -eq 1 -and ($pBlkStgIgn -match 'staged path excluded by ignore-dirty-paths.*src/b\.ts') -and $partShOk) {
        Pass 'guard-partial-staged-bypass'
    } else {
        FailCheck 'guard-partial-staged-bypass' "b1=(${pBlk1Exit}:$pBlk1) b2=(${pBlk2Exit}:$pBlk2) okSc=$pOkScopedExit blkAll=(${pBlkAllExit}:$pBlkAll) ignMm=$pBlkIgnMismatchExit ign=$pOkAllIgnExit stgIgn=$pBlkStgIgnExit sh=$partShOk"
    }

    # --- guard-verify-mode-type-submodule (chmod, symlink/type changes, submodule gitlink + dirty state, legacy migration) ---
    $subOrigin = Join-Path $sandbox 'sub-origin'
    New-Item -ItemType Directory -Path $subOrigin -Force | Out-Null
    Push-Location $subOrigin
    git init -q; git config user.email 'ship-test@example.com'; git config user.name 'Ship Test'
    [IO.File]::WriteAllText((Join-Path $subOrigin 's.txt'), "sub-v1`n", (New-Object System.Text.UTF8Encoding($false)))
    git add s.txt; git commit -qm 'sub-v1'
    $sub1 = (git rev-parse HEAD).Trim()
    [IO.File]::WriteAllText((Join-Path $subOrigin 's.txt'), "sub-v2`n", (New-Object System.Text.UTF8Encoding($false)))
    git add s.txt; git commit -qm 'sub-v2'
    $sub2 = (git rev-parse HEAD).Trim()
    Pop-Location

    $mtRepo = Join-Path $sandbox 'mode-type-sub-repo'
    New-Item -ItemType Directory -Path (Join-Path $mtRepo 'scripts') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $mtRepo 'deps') -Force | Out-Null
    Push-Location $mtRepo
    git init -q; git config user.email 'ship-test@example.com'; git config user.name 'Ship Test'
    $utf8NoBomMt = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $mtRepo 'scripts\run.sh'), "#!/bin/sh`necho run`n", $utf8NoBomMt)
    [IO.File]::WriteAllText((Join-Path $mtRepo 'other.txt'), "other`n", $utf8NoBomMt)
    [IO.File]::WriteAllText((Join-Path $mtRepo 'unrelated.txt'), "unrelated-0`n", $utf8NoBomMt)
    git add .; git commit -qm 'init'

    $guardShMt = ($root -replace '\\', '/') + '/scripts/b3-guard.sh'
    $mtRepoP = $mtRepo -replace '\\', '/'
    $hasShMt = $script:HasBash

    # 1. Executable bit (chmod +x) + forward ancestry + index-vs-WT mode divergence
    $rChmod = '.b3/ship/runs/r1/evidence/chmod.verify'
    $null = Invoke-GuardRaw verify-run -RepoRoot $mtRepo -VerifyCmd 'echo m0' -ReceiptPath $rChmod -TaskId CHM -RelevantPaths 'scripts/run.sh'
    $cmShInitOk = $true
    if ($hasShMt) {
        $null = & $script:GitBash -c "'$guardShMt' verify-check --repo-root '$mtRepoP' --receipt-path '$rChmod'"
        $cmShInitOk = ($LASTEXITCODE -eq 0)
    }
    git update-index --chmod=+x scripts/run.sh
    $null = Invoke-GuardRaw verify-check -RepoRoot $mtRepo -ReceiptPath $rChmod
    $cmStalePs = $LASTEXITCODE
    $null = Invoke-GuardRaw precommit -RepoRoot $mtRepo -AllowedPaths 'scripts/run.sh' -RequireVerifyReceipt $rChmod
    $cmPcBlkPs = $LASTEXITCODE
    $cmStaleSh = 2; $cmPcBlkSh = 1
    if ($hasShMt) {
        $null = & $script:GitBash -c "'$guardShMt' verify-check --repo-root '$mtRepoP' --receipt-path '$rChmod'"
        $cmStaleSh = $LASTEXITCODE
        $null = & $script:GitBash -c "'$guardShMt' precommit --repo-root '$mtRepoP' --allowed-paths 'scripts/run.sh' --require-verify-receipt '$rChmod'"
        $cmPcBlkSh = $LASTEXITCODE
    }
    $null = Invoke-GuardRaw verify-run -RepoRoot $mtRepo -VerifyCmd 'echo m1-ps' -ReceiptPath $rChmod -TaskId CHM -RelevantPaths 'scripts/run.sh'
    $cmRun1PsEx = $LASTEXITCODE
    if ($hasShMt) {
        $null = & $script:GitBash -c "'$guardShMt' verify-run --repo-root '$mtRepoP' --verify-cmd 'echo m1' --receipt-path '$rChmod' --task-id CHM --relevant-paths 'scripts/run.sh'"
    }
    $cmPcOkPs = ((Invoke-GuardRaw precommit -RepoRoot $mtRepo -AllowedPaths 'scripts/run.sh' -RequireVerifyReceipt $rChmod) -join "`n")
    $cmPcOkPsEx = $LASTEXITCODE
    $cmPcOkSh = 'PRECOMMIT_OK'; $cmPcOkShEx = 0
    if ($hasShMt) {
        $cmPcOkSh = (& $script:GitBash -c "'$guardShMt' precommit --repo-root '$mtRepoP' --allowed-paths 'scripts/run.sh' --require-verify-receipt '$rChmod'") -join "`n"
        $cmPcOkShEx = $LASTEXITCODE
    }
    git commit -qm 'chmod-x'
    $null = Invoke-GuardRaw verify-check -RepoRoot $mtRepo -ReceiptPath $rChmod
    $cmAfterPs = $LASTEXITCODE
    $cmAfterSh = 0
    if ($hasShMt) {
        $null = & $script:GitBash -c "'$guardShMt' verify-check --repo-root '$mtRepoP' --receipt-path '$rChmod'"
        $cmAfterSh = $LASTEXITCODE
    }
    # Index-vs-WT mode divergence + Windows core.filemode=true untracked script parity (R003)
    $rIdxMode = '.b3/ship/runs/r1/evidence/idx-mode.verify'
    git config core.filemode true
    git update-index --chmod=-x scripts/run.sh
    git commit -qm 'chmod-644'
    $null = Invoke-GuardRaw verify-run -RepoRoot $mtRepo -VerifyCmd 'echo idxm' -ReceiptPath $rIdxMode -TaskId IDXM -RelevantPaths 'scripts/run.sh'
    git update-index --chmod=+x scripts/run.sh
    $null = Invoke-GuardRaw verify-check -RepoRoot $mtRepo -ReceiptPath $rIdxMode
    $cmIdxStalePs = $LASTEXITCODE
    $cmIdxStaleSh = 2
    if ($hasShMt) {
        $null = & $script:GitBash -c "'$guardShMt' verify-check --repo-root '$mtRepoP' --receipt-path '$rIdxMode'"
        $cmIdxStaleSh = $LASTEXITCODE
    }
    git reset -q HEAD scripts/run.sh
    [IO.File]::WriteAllText((Join-Path $mtRepo 'scripts\untr.sh'), "#!/bin/sh`necho u`n", $utf8NoBomMt)
    $rUntrFm = '.b3/ship/runs/r1/evidence/untr-fm.verify'
    $null = Invoke-GuardRaw verify-run -RepoRoot $mtRepo -VerifyCmd 'echo ufm' -ReceiptPath $rUntrFm -TaskId UFM
    $untrFmShOk = $true
    if ($hasShMt) {
        $null = & $script:GitBash -c "'$guardShMt' verify-check --repo-root '$mtRepoP' --receipt-path '$rUntrFm'"
        $untrFmShOk = ($LASTEXITCODE -eq 0)
    }
    Remove-Item -LiteralPath (Join-Path $mtRepo 'scripts\untr.sh') -Force
    git config core.filemode false
    $chmodOk = $cmShInitOk -and ($cmRun1PsEx -eq 0) -and ($cmStalePs -eq 2) -and ($cmStaleSh -eq 2) -and
               ($cmPcBlkPs -eq 1) -and ($cmPcBlkSh -eq 1) -and
               ($cmPcOkPsEx -eq 0) -and ($cmPcOkPs -eq 'PRECOMMIT_OK') -and
               ($cmPcOkShEx -eq 0) -and ($cmPcOkSh -eq 'PRECOMMIT_OK') -and
               ($cmAfterPs -eq 0) -and ($cmAfterSh -eq 0) -and
               ($cmIdxStalePs -eq 2) -and ($cmIdxStaleSh -eq 2) -and $untrFmShOk

    # 2. Symlink & type changes (120000 <-> 100644 with identical bytes + target content edit)
    [IO.File]::WriteAllText((Join-Path $mtRepo 'lnk'), 'scripts/run.sh', $utf8NoBomMt)
    $lnkSha = (git hash-object -w -- lnk).Trim()
    git update-index --add --cacheinfo "120000,$lnkSha,lnk"
    $rSym = '.b3/ship/runs/r1/evidence/sym.verify'
    $null = Invoke-GuardRaw verify-run -RepoRoot $mtRepo -VerifyCmd 'echo s0' -ReceiptPath $rSym -TaskId SYM -RelevantPaths 'lnk'
    $null = Invoke-GuardRaw precommit -RepoRoot $mtRepo -AllowedPaths 'lnk' -RequireVerifyReceipt $rSym
    $symPc1Ps = $LASTEXITCODE
    $symPc1Sh = 0
    if ($hasShMt) {
        $null = & $script:GitBash -c "'$guardShMt' precommit --repo-root '$mtRepoP' --allowed-paths 'lnk' --require-verify-receipt '$rSym'"
        $symPc1Sh = $LASTEXITCODE
    }
    git commit -qm 'add-lnk'
    $null = Invoke-GuardRaw verify-check -RepoRoot $mtRepo -ReceiptPath $rSym
    $symAfter1Ps = $LASTEXITCODE
    $symAfter1Sh = 0
    if ($hasShMt) {
        $null = & $script:GitBash -c "'$guardShMt' verify-check --repo-root '$mtRepoP' --receipt-path '$rSym'"
        $symAfter1Sh = $LASTEXITCODE
    }
    # Type change 120000 -> 100644 keeping identical bytes ('scripts/run.sh')
    git update-index --force-remove lnk
    [IO.File]::WriteAllText((Join-Path $mtRepo 'lnk'), 'scripts/run.sh', $utf8NoBomMt)
    git add lnk
    $null = Invoke-GuardRaw verify-check -RepoRoot $mtRepo -ReceiptPath $rSym
    $symTypeStalePs = $LASTEXITCODE
    $null = Invoke-GuardRaw precommit -RepoRoot $mtRepo -AllowedPaths 'lnk' -RequireVerifyReceipt $rSym
    $symTypeBlkPs = $LASTEXITCODE
    $symTypeStaleSh = 2; $symTypeBlkSh = 1
    if ($hasShMt) {
        $null = & $script:GitBash -c "'$guardShMt' verify-check --repo-root '$mtRepoP' --receipt-path '$rSym'"
        $symTypeStaleSh = $LASTEXITCODE
        $null = & $script:GitBash -c "'$guardShMt' precommit --repo-root '$mtRepoP' --allowed-paths 'lnk' --require-verify-receipt '$rSym'"
        $symTypeBlkSh = $LASTEXITCODE
    }
    $null = Invoke-GuardRaw verify-run -RepoRoot $mtRepo -VerifyCmd 'echo s1' -ReceiptPath $rSym -TaskId SYM -RelevantPaths 'lnk'
    $null = Invoke-GuardRaw precommit -RepoRoot $mtRepo -AllowedPaths 'lnk' -RequireVerifyReceipt $rSym
    $symPc2Ps = $LASTEXITCODE
    $symPc2Sh = 0
    if ($hasShMt) {
        $null = & $script:GitBash -c "'$guardShMt' precommit --repo-root '$mtRepoP' --allowed-paths 'lnk' --require-verify-receipt '$rSym'"
        $symPc2Sh = $LASTEXITCODE
    }
    git commit -qm 'lnk-to-file'
    $null = Invoke-GuardRaw verify-check -RepoRoot $mtRepo -ReceiptPath $rSym
    $symAfter2Ps = $LASTEXITCODE
    $symAfter2Sh = 0
    if ($hasShMt) {
        $null = & $script:GitBash -c "'$guardShMt' verify-check --repo-root '$mtRepoP' --receipt-path '$rSym'"
        $symAfter2Sh = $LASTEXITCODE
    }
    # Convert 100644 -> 120000 and verify target change invalidates receipt
    git update-index --force-remove lnk
    git update-index --add --cacheinfo "120000,$lnkSha,lnk"
    git commit -qm 'file-to-lnk'
    $null = Invoke-GuardRaw verify-run -RepoRoot $mtRepo -VerifyCmd 'echo s2-ps' -ReceiptPath $rSym -TaskId SYM -RelevantPaths 'lnk'
    $symRun2PsEx = $LASTEXITCODE
    if ($hasShMt) {
        $null = & $script:GitBash -c "'$guardShMt' verify-run --repo-root '$mtRepoP' --verify-cmd 'echo s2' --receipt-path '$rSym' --task-id SYM --relevant-paths 'lnk'"
    }
    $null = Invoke-GuardRaw verify-check -RepoRoot $mtRepo -ReceiptPath $rSym
    $symBackValidPs = $LASTEXITCODE
    $symBackValidSh = 0
    if ($hasShMt) {
        $null = & $script:GitBash -c "'$guardShMt' verify-check --repo-root '$mtRepoP' --receipt-path '$rSym'"
        $symBackValidSh = $LASTEXITCODE
    }
    [IO.File]::WriteAllText((Join-Path $mtRepo 'lnk'), 'other.txt', $utf8NoBomMt)
    $null = Invoke-GuardRaw verify-check -RepoRoot $mtRepo -ReceiptPath $rSym
    $symTargetStalePs = $LASTEXITCODE
    $symTargetStaleSh = 2
    if ($hasShMt) {
        $null = & $script:GitBash -c "'$guardShMt' verify-check --repo-root '$mtRepoP' --receipt-path '$rSym'"
        $symTargetStaleSh = $LASTEXITCODE
    }
    [IO.File]::WriteAllText((Join-Path $mtRepo 'lnk'), 'scripts/run.sh', $utf8NoBomMt)
    $symOk = ($symPc1Ps -eq 0) -and ($symPc1Sh -eq 0) -and ($symAfter1Ps -eq 0) -and ($symAfter1Sh -eq 0) -and
             ($symTypeStalePs -eq 2) -and ($symTypeStaleSh -eq 2) -and ($symTypeBlkPs -eq 1) -and ($symTypeBlkSh -eq 1) -and
             ($symPc2Ps -eq 0) -and ($symPc2Sh -eq 0) -and ($symAfter2Ps -eq 0) -and ($symAfter2Sh -eq 0) -and
             ($symRun2PsEx -eq 0) -and ($symBackValidPs -eq 0) -and ($symBackValidSh -eq 0) -and
             ($symTargetStalePs -eq 2) -and ($symTargetStaleSh -eq 2)

    # 3. Submodule gitlink updates + dirty submodule + scoped forward ancestry
    $prevSubEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        git -c protocol.file.allow=always submodule add -q "$subOrigin" deps/sub 2>&1 | Out-Null
        git -C deps/sub checkout -q $sub1 2>&1 | Out-Null
        git add .gitmodules deps/sub 2>&1 | Out-Null
        git commit -qm 'add-sub1' 2>&1 | Out-Null
    } finally {
        $ErrorActionPreference = $prevSubEap
    }
    $rSubAll = '.b3/ship/runs/r1/evidence/sub-all.verify'
    $rSubSc = '.b3/ship/runs/r1/evidence/sub-scoped.verify'
    $null = Invoke-GuardRaw verify-run -RepoRoot $mtRepo -VerifyCmd 'echo sub-all' -ReceiptPath $rSubAll -TaskId SUBA
    $null = Invoke-GuardRaw verify-run -RepoRoot $mtRepo -VerifyCmd 'echo sub-sc' -ReceiptPath $rSubSc -TaskId SUBS -RelevantPaths 'deps/sub'
    $subInitShOk = $true
    if ($hasShMt) {
        $null = & $script:GitBash -c "'$guardShMt' verify-check --repo-root '$mtRepoP' --receipt-path '$rSubAll'"
        $a = $LASTEXITCODE
        $null = & $script:GitBash -c "'$guardShMt' verify-check --repo-root '$mtRepoP' --receipt-path '$rSubSc'"
        $subInitShOk = ($a -eq 0) -and ($LASTEXITCODE -eq 0)
    }
    # Move submodule pointer unstaged -> both ALL & scoped must become VERIFY_STALE
    $prevSubEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { git -C deps/sub checkout -q $sub2 2>&1 | Out-Null } finally { $ErrorActionPreference = $prevSubEap }
    $null = Invoke-GuardRaw verify-check -RepoRoot $mtRepo -ReceiptPath $rSubAll
    $subMvAllPs = $LASTEXITCODE
    $null = Invoke-GuardRaw verify-check -RepoRoot $mtRepo -ReceiptPath $rSubSc
    $subMvScPs = $LASTEXITCODE
    $subMvAllSh = 2; $subMvScSh = 2
    if ($hasShMt) {
        $null = & $script:GitBash -c "'$guardShMt' verify-check --repo-root '$mtRepoP' --receipt-path '$rSubAll'"
        $subMvAllSh = $LASTEXITCODE
        $null = & $script:GitBash -c "'$guardShMt' verify-check --repo-root '$mtRepoP' --receipt-path '$rSubSc'"
        $subMvScSh = $LASTEXITCODE
    }
    # Re-verify moved submodule while unstaged with staged sibling -> precommit blocks unstaged move -> git add deps/sub -> precommit OK -> commit -> stays VERIFY_VALID
    [IO.File]::WriteAllText((Join-Path $mtRepo 'other.txt'), "other-with-sub`n", $utf8NoBomMt)
    git add other.txt
    $rSubPair = '.b3/ship/runs/r1/evidence/sub-pair.verify'
    $null = Invoke-GuardRaw verify-run -RepoRoot $mtRepo -VerifyCmd 'echo sub-pair' -ReceiptPath $rSubPair -TaskId SUBP -RelevantPaths 'deps/sub,other.txt'
    $subUnstPc = ((Invoke-GuardRaw precommit -RepoRoot $mtRepo -AllowedPaths 'deps/sub,other.txt' -RequireVerifyReceipt $rSubPair) -join "`n")
    $subUnstPcEx = $LASTEXITCODE
    git reset -q HEAD other.txt
    [IO.File]::WriteAllText((Join-Path $mtRepo 'other.txt'), "other`n", $utf8NoBomMt)
    $null = Invoke-GuardRaw verify-run -RepoRoot $mtRepo -VerifyCmd 'echo sub-mv' -ReceiptPath $rSubSc -TaskId SUBS -RelevantPaths 'deps/sub'
    git add deps/sub
    $subStgPcPs = ((Invoke-GuardRaw precommit -RepoRoot $mtRepo -AllowedPaths 'deps/sub' -RequireVerifyReceipt $rSubSc) -join "`n")
    $subStgPcPsEx = $LASTEXITCODE
    $subStgPcSh = 'PRECOMMIT_OK'; $subStgPcShEx = 0
    if ($hasShMt) {
        $subStgPcSh = (& $script:GitBash -c "'$guardShMt' precommit --repo-root '$mtRepoP' --allowed-paths 'deps/sub' --require-verify-receipt '$rSubSc'") -join "`n"
        $subStgPcShEx = $LASTEXITCODE
    }
    git commit -qm 'bump-sub2'
    $null = Invoke-GuardRaw verify-check -RepoRoot $mtRepo -ReceiptPath $rSubSc
    $subCommitValidPs = $LASTEXITCODE
    $subCommitValidSh = 0
    if ($hasShMt) {
        $null = & $script:GitBash -c "'$guardShMt' verify-check --repo-root '$mtRepoP' --receipt-path '$rSubSc'"
        $subCommitValidSh = $LASTEXITCODE
    }
    # Dirty files inside submodule -> VERIFY_STALE, re-verify dirty, edit dirty -> VERIFY_STALE again
    [IO.File]::WriteAllText((Join-Path $mtRepo 'deps\sub\s.txt'), "dirty-1`n", $utf8NoBomMt)
    $null = Invoke-GuardRaw verify-check -RepoRoot $mtRepo -ReceiptPath $rSubSc
    $subDirty1Ps = $LASTEXITCODE
    $subDirty1Sh = 2
    if ($hasShMt) {
        $null = & $script:GitBash -c "'$guardShMt' verify-check --repo-root '$mtRepoP' --receipt-path '$rSubSc'"
        $subDirty1Sh = $LASTEXITCODE
    }
    $null = Invoke-GuardRaw verify-run -RepoRoot $mtRepo -VerifyCmd 'echo sub-dirty1' -ReceiptPath $rSubSc -TaskId SUBS -RelevantPaths 'deps/sub'
    $subDirtyShParity = $true
    if ($hasShMt) {
        $null = & $script:GitBash -c "'$guardShMt' verify-check --repo-root '$mtRepoP' --receipt-path '$rSubSc'"
        $subDirtyShParity = ($LASTEXITCODE -eq 0)
    }
    [IO.File]::WriteAllText((Join-Path $mtRepo 'deps\sub\s.txt'), "dirty-2`n", $utf8NoBomMt)
    $null = Invoke-GuardRaw verify-check -RepoRoot $mtRepo -ReceiptPath $rSubSc
    $subDirty2Ps = $LASTEXITCODE
    $subDirty2Sh = 2
    if ($hasShMt) {
        $null = & $script:GitBash -c "'$guardShMt' verify-check --repo-root '$mtRepoP' --receipt-path '$rSubSc'"
        $subDirty2Sh = $LASTEXITCODE
    }
    # Clean submodule, verify untracked file inside sub (R005), nested dirty repo (R002), uninitialized submodule, and forward ancestry
    $prevSubEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { git -C deps/sub checkout -q -- s.txt 2>&1 | Out-Null } finally { $ErrorActionPreference = $prevSubEap }
    $null = Invoke-GuardRaw verify-run -RepoRoot $mtRepo -VerifyCmd 'echo sub-clean' -ReceiptPath $rSubSc -TaskId SUBS -RelevantPaths 'deps/sub'
    # Untracked file inside submodule -> VERIFY_STALE, re-verify, edit untracked file -> VERIFY_STALE
    $subUntrFile = Join-Path $mtRepo 'deps\sub\sub-untr.txt'
    [IO.File]::WriteAllText($subUntrFile, "u-sub-1`n", $utf8NoBomMt)
    $null = Invoke-GuardRaw verify-check -RepoRoot $mtRepo -ReceiptPath $rSubSc
    $subUntr1Ps = $LASTEXITCODE
    $subUntr1Sh = 2
    if ($hasShMt) {
        $null = & $script:GitBash -c "'$guardShMt' verify-check --repo-root '$mtRepoP' --receipt-path '$rSubSc'"
        $subUntr1Sh = $LASTEXITCODE
    }
    $null = Invoke-GuardRaw verify-run -RepoRoot $mtRepo -VerifyCmd 'echo sub-untr1' -ReceiptPath $rSubSc -TaskId SUBS -RelevantPaths 'deps/sub'
    [IO.File]::WriteAllText($subUntrFile, "u-sub-2`n", $utf8NoBomMt)
    $null = Invoke-GuardRaw verify-check -RepoRoot $mtRepo -ReceiptPath $rSubSc
    $subUntr2Ps = $LASTEXITCODE
    $subUntr2Sh = 2
    if ($hasShMt) {
        $null = & $script:GitBash -c "'$guardShMt' verify-check --repo-root '$mtRepoP' --receipt-path '$rSubSc'"
        $subUntr2Sh = $LASTEXITCODE
    }
    Remove-Item -LiteralPath $subUntrFile -Force
    # Nested git repo inside deps/sub (R002)
    $nestedRepo = Join-Path $mtRepo 'deps\sub\inner-nested'
    New-Item -ItemType Directory -Path $nestedRepo -Force | Out-Null
    Push-Location $nestedRepo
    git init -q; git config user.email 'ship-test@example.com'; git config user.name 'Ship Test'
    [IO.File]::WriteAllText((Join-Path $nestedRepo 'i.txt'), "in-1`n", $utf8NoBomMt)
    git add i.txt; git commit -qm 'inner-1'
    [IO.File]::WriteAllText((Join-Path $nestedRepo 'i.txt'), "in-dirty-1`n", $utf8NoBomMt)
    Pop-Location
    $null = Invoke-GuardRaw verify-run -RepoRoot $mtRepo -VerifyCmd 'echo sub-nested' -ReceiptPath $rSubSc -TaskId SUBS -RelevantPaths 'deps/sub'
    $subNestParSh = $true
    if ($hasShMt) {
        $null = & $script:GitBash -c "'$guardShMt' verify-check --repo-root '$mtRepoP' --receipt-path '$rSubSc'"
        $subNestParSh = ($LASTEXITCODE -eq 0)
    }
    [IO.File]::WriteAllText((Join-Path $nestedRepo 'i.txt'), "in-dirty-2`n", $utf8NoBomMt)
    $null = Invoke-GuardRaw verify-check -RepoRoot $mtRepo -ReceiptPath $rSubSc
    $subNestEditPs = $LASTEXITCODE
    $subNestEditSh = 2
    if ($hasShMt) {
        $null = & $script:GitBash -c "'$guardShMt' verify-check --repo-root '$mtRepoP' --receipt-path '$rSubSc'"
        $subNestEditSh = $LASTEXITCODE
    }
    [IO.File]::WriteAllText((Join-Path $nestedRepo 'untr-in.txt'), "u1`n", $utf8NoBomMt)
    $null = Invoke-GuardRaw verify-run -RepoRoot $mtRepo -VerifyCmd 'echo sub-nested-untr' -ReceiptPath $rSubSc -TaskId SUBS -RelevantPaths 'deps/sub'
    [IO.File]::WriteAllText((Join-Path $nestedRepo 'untr-in.txt'), "u2`n", $utf8NoBomMt)
    $null = Invoke-GuardRaw verify-check -RepoRoot $mtRepo -ReceiptPath $rSubSc
    $subNestUntrPs = $LASTEXITCODE
    $subNestUntrSh = 2
    if ($hasShMt) {
        $null = & $script:GitBash -c "'$guardShMt' verify-check --repo-root '$mtRepoP' --receipt-path '$rSubSc'"
        $subNestUntrSh = $LASTEXITCODE
    }
    Remove-Item -LiteralPath $nestedRepo -Recurse -Force
    # Uninitialized submodule (160000 gitlink in HEAD, empty dir on disk without .git)
    New-Item -ItemType Directory -Path (Join-Path $mtRepo 'deps\uninit') -Force | Out-Null
    git update-index --add --cacheinfo "160000,$sub1,deps/uninit"
    git commit -qm 'add-uninit-sub'
    $rSubUninit = '.b3/ship/runs/r1/evidence/sub-uninit.verify'
    $null = Invoke-GuardRaw verify-run -RepoRoot $mtRepo -VerifyCmd 'echo sub-uninit' -ReceiptPath $rSubUninit -TaskId SUBU -RelevantPaths 'deps/uninit'
    $subUninitSh = $true
    if ($hasShMt) {
        $null = & $script:GitBash -c "'$guardShMt' verify-check --repo-root '$mtRepoP' --receipt-path '$rSubUninit'"
        $subUninitSh = ($LASTEXITCODE -eq 0)
    }
    git update-index --cacheinfo "160000,$sub2,deps/uninit"
    $null = Invoke-GuardRaw verify-check -RepoRoot $mtRepo -ReceiptPath $rSubUninit
    $subUninitBumpPs = $LASTEXITCODE
    $subUninitBumpSh = 2
    if ($hasShMt) {
        $null = & $script:GitBash -c "'$guardShMt' verify-check --repo-root '$mtRepoP' --receipt-path '$rSubUninit'"
        $subUninitBumpSh = $LASTEXITCODE
    }
    git commit -qm 'bump-uninit-sub'
    $null = Invoke-GuardRaw verify-run -RepoRoot $mtRepo -VerifyCmd 'echo sub-clean' -ReceiptPath $rSubSc -TaskId SUBS -RelevantPaths 'deps/sub'
    [IO.File]::WriteAllText((Join-Path $mtRepo 'unrelated.txt'), "unrelated-1`n", $utf8NoBomMt)
    git add unrelated.txt; git commit -qm 'unrelated-commit'
    $null = Invoke-GuardRaw verify-check -RepoRoot $mtRepo -ReceiptPath $rSubSc
    $subFwdPs = $LASTEXITCODE
    $subFwdSh = 0
    if ($hasShMt) {
        $null = & $script:GitBash -c "'$guardShMt' verify-check --repo-root '$mtRepoP' --receipt-path '$rSubSc'"
        $subFwdSh = $LASTEXITCODE
    }
    # Relative --repo-root regression test (R001 in PS & SH)
    Push-Location $sandbox
    $relName = 'mode-type-sub-repo'
    $rRel = '.b3/ship/runs/r1/evidence/rel-root.verify'
    $relOk = $true
    $null = Invoke-GuardRaw verify-run -RepoRoot $relName -VerifyCmd 'echo rel' -ReceiptPath $rRel -TaskId REL -RelevantPaths 'deps/sub'
    $relPsEx = $LASTEXITCODE
    if ($hasShMt) {
        $null = & $script:GitBash -c "cd '$($sandbox -replace '\\', '/')' && '$guardShMt' verify-check --repo-root '$relName' --receipt-path '$rRel'"
        $relShVcEx = $LASTEXITCODE
        $null = & $script:GitBash -c "cd '$($sandbox -replace '\\', '/')' && '$guardShMt' verify-run --repo-root '$relName' --verify-cmd 'echo rel-sh' --receipt-path '$rRel' --task-id REL --relevant-paths 'deps/sub'"
        $relShVrEx = $LASTEXITCODE
        $null = Invoke-GuardRaw verify-check -RepoRoot $relName -ReceiptPath $rRel
        $relPsAfterSh = $LASTEXITCODE
        $relOk = ($relPsEx -eq 0) -and ($relShVcEx -eq 0) -and ($relShVrEx -eq 0) -and ($relPsAfterSh -eq 0)
    } else {
        $relOk = ($relPsEx -eq 0)
    }
    Pop-Location
    $subOk = $subInitShOk -and ($subMvAllPs -eq 2) -and ($subMvScPs -eq 2) -and ($subMvAllSh -eq 2) -and ($subMvScSh -eq 2) -and
             ($subUnstPcEx -eq 1) -and ($subUnstPc -match 'unstaged changes in receipt scope.*deps/sub') -and
             ($subStgPcPsEx -eq 0) -and ($subStgPcPs -eq 'PRECOMMIT_OK') -and
             ($subStgPcShEx -eq 0) -and ($subStgPcSh -eq 'PRECOMMIT_OK') -and
             ($subCommitValidPs -eq 0) -and ($subCommitValidSh -eq 0) -and
             ($subDirty1Ps -eq 2) -and ($subDirty1Sh -eq 2) -and $subDirtyShParity -and
             ($subDirty2Ps -eq 2) -and ($subDirty2Sh -eq 2) -and
             ($subUntr1Ps -eq 2) -and ($subUntr1Sh -eq 2) -and ($subUntr2Ps -eq 2) -and ($subUntr2Sh -eq 2) -and
             $subNestParSh -and ($subNestEditPs -eq 2) -and ($subNestEditSh -eq 2) -and ($subNestUntrPs -eq 2) -and ($subNestUntrSh -eq 2) -and
             $subUninitSh -and ($subUninitBumpPs -eq 2) -and ($subUninitBumpSh -eq 2) -and
             ($subFwdPs -eq 0) -and ($subFwdSh -eq 0) -and $relOk

    # 4. Old-receipt migration behavior: pre-upgrade 'PATHS=ALL\nF <path> <sha>\n' hash fails closed as VERIFY_STALE (2) and migrates on verify-run
    $mtHead = (git rev-parse HEAD).Trim()
    $legSb = New-Object System.Text.StringBuilder
    [void]$legSb.Append("PATHS=ALL`n")
    $lsPairs = @(git ls-tree -r HEAD | ForEach-Object {
        $ti = $_.IndexOf("`t")
        if ($ti -gt 0) {
            $mp = $_.Substring(0, $ti).Trim() -split '\s+'
            if ($mp.Count -ge 3 -and $mp[1] -eq 'blob') {
                [PSCustomObject]@{ P = $_.Substring($ti + 1); Oid = $mp[2] }
            }
        }
    } | Sort-Object P)
    foreach ($lp in $lsPairs) { [void]$legSb.Append("F $($lp.P) $($lp.Oid)`n") }
    $legTmp = Join-Path $mtRepo '.b3\ship\runs\r1\evidence\legacy-fp.tmp'
    New-Item -ItemType Directory -Path (Split-Path -Parent $legTmp) -Force | Out-Null
    [IO.File]::WriteAllText($legTmp, $legSb.ToString(), $utf8NoBomMt)
    $legHash = (git hash-object -- $legTmp).Trim()
    Remove-Item -LiteralPath $legTmp -Force
    $rLegacy = '.b3/ship/runs/r1/evidence/legacy.verify'
    $legacyBody = @(
        'schema=b3-verify-v1',
        'task_id=LEG',
        'scope=full',
        "head_sha=$mtHead",
        "tree_hash=$legHash",
        'relevant_paths=ALL',
        'exit_code=0',
        'status=PASS',
        'command=echo legacy',
        'log_path=none',
        'timestamp_utc=2026-01-01T00:00:00Z'
    ) -join "`n"
    [IO.File]::WriteAllText((Join-Path $mtRepo $rLegacy), "$legacyBody`n", $utf8NoBomMt)
    $legCheckPs = ((Invoke-GuardRaw verify-check -RepoRoot $mtRepo -ReceiptPath $rLegacy) -join "`n")
    $legCheckPsEx = $LASTEXITCODE
    $legCheckSh = 'VERIFY_STALE:'; $legCheckShEx = 2
    if ($hasShMt) {
        $legCheckSh = (& $script:GitBash -c "'$guardShMt' verify-check --repo-root '$mtRepoP' --receipt-path '$rLegacy'") -join "`n"
        $legCheckShEx = $LASTEXITCODE
    }
    $null = Invoke-GuardRaw verify-run -RepoRoot $mtRepo -VerifyCmd 'echo migrated' -ReceiptPath $rLegacy -TaskId LEG
    $legMigRunEx = $LASTEXITCODE
    $null = Invoke-GuardRaw verify-check -RepoRoot $mtRepo -ReceiptPath $rLegacy
    $legMigPsEx = $LASTEXITCODE
    $legMigShEx = 0
    if ($hasShMt) {
        $null = & $script:GitBash -c "'$guardShMt' verify-check --repo-root '$mtRepoP' --receipt-path '$rLegacy'"
        $legMigShEx = $LASTEXITCODE
    }
    $migOk = ($legCheckPsEx -eq 2) -and ($legCheckPs -match 'VERIFY_STALE:') -and
             ($legCheckShEx -eq 2) -and ($legCheckSh -match 'VERIFY_STALE:') -and
             ($legMigRunEx -eq 0) -and ($legMigPsEx -eq 0) -and ($legMigShEx -eq 0)

    Pop-Location
    if ($chmodOk -and $symOk -and $subOk -and $migOk) {
        Pass 'guard-verify-mode-type-submodule'
    } else {
        FailCheck 'guard-verify-mode-type-submodule' "chmod=$chmodOk sym=$symOk sub=$subOk mig=$migOk"
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
    $stOut = ((Invoke-GuardRaw mechanical-check -RepoRoot $stRepo -BaseSha $stBase) -join "`n")
    $stExit = $LASTEXITCODE
    $stAllowMd = ((Invoke-GuardRaw mechanical-check -RepoRoot $stRepo -BaseSha $stBase -AllowMassDelete) -join "`n")
    $stAllowMdExit = $LASTEXITCODE
    # precommit blocks dir-prefix allow for secret, allows exact secret match, and blocks mid-merge
    git reset -q
    git add config\.env
    $pcSecDir = ((Invoke-GuardRaw precommit -RepoRoot $stRepo -AllowedPaths 'config') -join "`n")
    $pcSecDirExit = $LASTEXITCODE
    $pcSecExact = ((Invoke-GuardRaw precommit -RepoRoot $stRepo -AllowedPaths 'config/.env') -join "`n")
    $pcSecExactExit = $LASTEXITCODE
    git reset -q
    git add config\.env.example
    $pcExOk = ((Invoke-GuardRaw precommit -RepoRoot $stRepo -AllowedPaths 'config') -join "`n")
    $pcExOkExit = $LASTEXITCODE
    Set-Content .git\MERGE_HEAD $stBase
    $pcMerge = ((Invoke-GuardRaw precommit -RepoRoot $stRepo -AllowedPaths 'config') -join "`n")
    $pcMergeExit = $LASTEXITCODE
    Remove-Item .git\MERGE_HEAD -Force

    $stShOk = $true
    if ($script:HasBash) {
        $guardShPosix = ($root -replace '\\', '/') + '/scripts/b3-guard.sh'
        $stRepoPosix = $stRepo -replace '\\', '/'
        $shSt = (& $script:GitBash -c "'$guardShPosix' mechanical-check --repo-root '$stRepoPosix' --base-sha '$stBase'") -join "`n"
        $shStExit = $LASTEXITCODE
        $shStMd = (& $script:GitBash -c "'$guardShPosix' mechanical-check --repo-root '$stRepoPosix' --base-sha '$stBase' --allow-mass-delete") -join "`n"
        $shStMdExit = $LASTEXITCODE
        git reset -q; git add config\.env
        $shSecDir = (& $script:GitBash -c "'$guardShPosix' precommit --repo-root '$stRepoPosix' --allowed-paths 'config'") -join "`n"
        $shSecDirExit = $LASTEXITCODE
        $shSecExact = (& $script:GitBash -c "'$guardShPosix' precommit --repo-root '$stRepoPosix' --allowed-paths 'config/.env'") -join "`n"
        $shSecExactExit = $LASTEXITCODE
        Set-Content .git\MERGE_HEAD $stBase
        $shMerge = (& $script:GitBash -c "'$guardShPosix' precommit --repo-root '$stRepoPosix' --allowed-paths 'config/.env'") -join "`n"
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
    $syBad = ((Invoke-GuardRaw symbol-check -RepoRoot $syRepo -BaseSha $syBase) -join "`n")
    $syBadExit = $LASTEXITCODE
    $syShOk = $true
    if ($script:HasBash) {
        $guardShPosix = ($root -replace '\\', '/') + '/scripts/b3-guard.sh'
        $syRepoPosix = $syRepo -replace '\\', '/'
        $shSyBad = (& $script:GitBash -c "'$guardShPosix' symbol-check --repo-root '$syRepoPosix' --base-sha '$syBase'") -join "`n"
        $shSyBadExit = $LASTEXITCODE
        $syShOk = ($shSyBadExit -eq 2) -and ($shSyBad -match 'dangling_refs=oldUsed\(1f\)') -and ($shSyBad -match 'orphan_internal=src/lib\.ts:internalDead') -and ($shSyBad -notmatch 'orphan_internal=.*publicApi')
    }
    # Clean caller + remove internalDead, keep unreferenced export function publicApi -> SYMBOL_OK
    Set-Content src\caller.ts "export const res = 1;"
    Set-Content src\lib.ts "export function keepFn() { return 2; }`nexport function publicApi() { return 4; }"
    $syClean = ((Invoke-GuardRaw symbol-check -RepoRoot $syRepo -BaseSha $syBase) -join "`n")
    $syCleanExit = $LASTEXITCODE
    if ($script:HasBash) {
        $shSyClean = (& $script:GitBash -c "'$guardShPosix' symbol-check --repo-root '$syRepoPosix' --base-sha '$syBase'") -join "`n"
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

    $cwRw = ((Invoke-GuardRaw check-wave -RepoRoot $wtMain -WaveSpecs 'T1=src/a.ts;T2=src/b.ts' -WaveReads 'T1=src/b.ts;T2=none' -ExpectedBaseSha $wtHead) -join "`n")
    $cwRwExit = $LASTEXITCODE
    $cwBaseBad = ((Invoke-GuardRaw check-wave -RepoRoot $wtMain -WaveSpecs 'T1=src/a.ts;T2=src/b.ts' -ExpectedBaseSha ('0' * 40)) -join "`n")
    $cwBaseBadExit = $LASTEXITCODE
    $cwDisjoint = ((Invoke-GuardRaw check-wave -RepoRoot $wtMain -WaveSpecs 'T1=src/a.ts;T2=src/b.ts' -WaveReads 'T1=src/c.ts;T2=src/d.ts' -ExpectedBaseSha $wtHead) -join "`n")
    $cwDisjointExit = $LASTEXITCODE
    $wtOk = ((Invoke-GuardRaw check-worktree -RepoRoot $wtLinked -ExpectedRoot $wtMain -ExpectedBaseSha $wtHead) -join "`n")
    $wtOkExit = $LASTEXITCODE
    $wtWrongRoot = ((Invoke-GuardRaw check-worktree -RepoRoot $wtOther -ExpectedRoot $wtMain) -join "`n")
    $wtWrongRootExit = $LASTEXITCODE
    $wtWrongBase = ((Invoke-GuardRaw check-worktree -RepoRoot $wtMain -ExpectedBaseSha ('0' * 40)) -join "`n")
    $wtWrongBaseExit = $LASTEXITCODE
    Set-Content (Join-Path $wtMain '.git\MERGE_HEAD') $wtHead
    $wtMidOp = ((Invoke-GuardRaw check-worktree -RepoRoot $wtMain) -join "`n")
    $wtMidOpExit = $LASTEXITCODE
    Remove-Item (Join-Path $wtMain '.git\MERGE_HEAD') -Force

    $wtShOk = $true
    if ($script:HasBash) {
        $guardShPosix = ($root -replace '\\', '/') + '/scripts/b3-guard.sh'
        $wmPosix = $wtMain -replace '\\', '/'
        $wlPosix = $wtLinked -replace '\\', '/'
        $woPosix = $wtOther -replace '\\', '/'
        $shRw = (& $script:GitBash -c "'$guardShPosix' check-wave --repo-root '$wmPosix' --wave-specs 'T1=src/a.ts;T2=src/b.ts' --wave-reads 'T1=src/b.ts;T2=none' --expected-base-sha '$wtHead'") -join "`n"
        $shRwExit = $LASTEXITCODE
        $shBaseBad = (& $script:GitBash -c "'$guardShPosix' check-wave --repo-root '$wmPosix' --wave-specs 'T1=src/a.ts;T2=src/b.ts' --expected-base-sha '0000000000000000000000000000000000000000'") -join "`n"
        $shBaseBadExit = $LASTEXITCODE
        $shWtOk = (& $script:GitBash -c "'$guardShPosix' check-worktree --repo-root '$wlPosix' --expected-root '$wmPosix' --expected-base-sha '$wtHead'") -join "`n"
        $shWtOkExit = $LASTEXITCODE
        $shWtWrong = (& $script:GitBash -c "'$guardShPosix' check-worktree --repo-root '$woPosix' --expected-root '$wmPosix'") -join "`n"
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
    $adPc = ((Invoke-GuardRaw precommit -RepoRoot $adRepo2 -AllowedPaths 'app.ts') -join "`n")
    $adPcExit = $LASTEXITCODE
    Pop-Location
    $adRes1 = ((Invoke-GuardRaw resolve-run -RepoRoot $adRepo1) -join "`n").Trim()
    $adRes1Exit = $LASTEXITCODE
    $adList1 = ((Invoke-GuardRaw list-runs -RepoRoot $adRepo1) -join "`n")
    $adRes2 = ((Invoke-GuardRaw resolve-run -RepoRoot $adRepo2) -join "`n").Trim()
    $adRes2Exit = $LASTEXITCODE
    $adShOk = $true
    if ($script:HasBash) {
        $guardShPosix = ($root -replace '\\', '/') + '/scripts/b3-guard.sh'
        $ad1Posix = $adRepo1 -replace '\\', '/'
        $ad2Posix = $adRepo2 -replace '\\', '/'
        $shAd1 = (& $script:GitBash -c "'$guardShPosix' resolve-run --repo-root '$ad1Posix'") -join "`n"
        $shAd1Exit = $LASTEXITCODE
        $shAdList = (& $script:GitBash -c "'$guardShPosix' list-runs --repo-root '$ad1Posix'") -join "`n"
        $shAd2 = (& $script:GitBash -c "'$guardShPosix' resolve-run --repo-root '$ad2Posix'") -join "`n"
        $shAd2Exit = $LASTEXITCODE
        $shAdPc = (& $script:GitBash -c "'$guardShPosix' precommit --repo-root '$ad2Posix' --allowed-paths 'app.ts'") -join "`n"
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

    # --- guard-review-loop-edge-fixes (parent WatchedPaths vs OwnedFiles, secret del, rename mass_delete, untracked obsoletes, symbol move vs dropped export) ---
    $rlEdgeRepo = Join-Path $sandbox 'rl-edge-repo'
    New-Item -ItemType Directory -Path (Join-Path $rlEdgeRepo 'src'), (Join-Path $rlEdgeRepo 'moved'), (Join-Path $rlEdgeRepo 'secret') | Out-Null
    Push-Location $rlEdgeRepo
    git init -q; git config user.email 'ship-test@example.com'; git config user.name 'Ship Test'
    [IO.File]::WriteAllText((Join-Path $rlEdgeRepo 'src\a.ts'), "export function movedFn() { return 1; }`n", (New-Object System.Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $rlEdgeRepo 'src\b.ts'), "export const b = 1;`n", (New-Object System.Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $rlEdgeRepo 'src\lib.ts'), "export function droppedFn() { return 2; }`n", (New-Object System.Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $rlEdgeRepo 'src\caller.ts'), "import { movedFn } from './a';`nimport { droppedFn } from './lib';`nexport const z = movedFn() + droppedFn();`n", (New-Object System.Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $rlEdgeRepo 'secret\.env'), "SECRET=1`n", (New-Object System.Text.UTF8Encoding($false)))
    1..10 | ForEach-Object { [IO.File]::WriteAllText((Join-Path $rlEdgeRepo "m$_.ts"), "export function mv$_() { return $_; }`n", (New-Object System.Text.UTF8Encoding($false))) }
    git add .; git commit -qm 'init'
    $edgeBase = (git rev-parse HEAD).Trim()

    # 1. check-freshness with parent WatchedPaths='src' and OwnedFiles='src/a.ts'
    [IO.File]::WriteAllText((Join-Path $rlEdgeRepo 'src\a.ts'), "// owned edit`nexport function movedFn() { return 1; }`n", (New-Object System.Text.UTF8Encoding($false)))
    $cfOwnedOk = ((Invoke-GuardRaw check-freshness -RepoRoot $rlEdgeRepo -ApproachAtSha $edgeBase -TaskBaseSha $edgeBase -WatchedPaths 'src' -OwnedFiles 'src/a.ts') -join "`n")
    $cfOwnedOkExit = $LASTEXITCODE
    [IO.File]::WriteAllText((Join-Path $rlEdgeRepo 'src\b.ts'), "export const b = 2;`n", (New-Object System.Text.UTF8Encoding($false)))
    $cfUnownedStale = ((Invoke-GuardRaw check-freshness -RepoRoot $rlEdgeRepo -ApproachAtSha $edgeBase -TaskBaseSha $edgeBase -WatchedPaths 'src' -OwnedFiles 'src/a.ts') -join "`n")
    $cfUnownedStaleExit = $LASTEXITCODE
    git checkout -- src/a.ts src/b.ts

    # 2. mechanical-check: delete tracked .env (no secret_path false positive) + unstaged move of 10 files (no mass_delete false positive)
    git rm -q secret/.env
    1..10 | ForEach-Object { Move-Item -LiteralPath (Join-Path $rlEdgeRepo "m$_.ts") -Destination (Join-Path $rlEdgeRepo "moved\m$_.ts") }
    $mechCleanMove = ((Invoke-GuardRaw mechanical-check -RepoRoot $rlEdgeRepo -BaseSha $edgeBase) -join "`n")
    $mechCleanMoveExit = $LASTEXITCODE

    # 3. mechanical-check: Obsoletes detects token in untracked file
    [IO.File]::WriteAllText((Join-Path $rlEdgeRepo 'src\new_obs.ts'), "const legacy = 'OLD_TOK_XYZ';`n", (New-Object System.Text.UTF8Encoding($false)))
    $mechObsUntr = ((Invoke-GuardRaw mechanical-check -RepoRoot $rlEdgeRepo -BaseSha $edgeBase -Obsoletes 'OLD_TOK_XYZ') -join "`n")
    $mechObsUntrExit = $LASTEXITCODE
    Remove-Item -LiteralPath (Join-Path $rlEdgeRepo 'src\new_obs.ts') -Force

    # 4. symbol-check: moving movedFn() from src/a.ts to src/b.ts cleanly passes; dropping 'export' on droppedFn() is caught
    [IO.File]::WriteAllText((Join-Path $rlEdgeRepo 'src\a.ts'), "export const aOnly = 0;`n", (New-Object System.Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $rlEdgeRepo 'src\b.ts'), "export const b = 1;`nexport function movedFn() { return 1; }`n", (New-Object System.Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $rlEdgeRepo 'src\caller.ts'), "import { movedFn } from './b';`nimport { droppedFn } from './lib';`nexport const z = movedFn() + droppedFn();`n", (New-Object System.Text.UTF8Encoding($false)))
    $symMoveOk = ((Invoke-GuardRaw symbol-check -RepoRoot $rlEdgeRepo -BaseSha $edgeBase) -join "`n")
    $symMoveOkExit = $LASTEXITCODE

    [IO.File]::WriteAllText((Join-Path $rlEdgeRepo 'src\lib.ts'), "function droppedFn() { return 2; }`n", (New-Object System.Text.UTF8Encoding($false)))
    $symDropExp = ((Invoke-GuardRaw symbol-check -RepoRoot $rlEdgeRepo -BaseSha $edgeBase) -join "`n")
    $symDropExpExit = $LASTEXITCODE

    $rlEdgeShOk = $true
    if ($script:HasBash) {
        $guardShPosix = ($root -replace '\\', '/') + '/scripts/b3-guard.sh'
        $rlEdgeP = $rlEdgeRepo -replace '\\', '/'
        $shMechMv = (& $script:GitBash -c "'$guardShPosix' mechanical-check --repo-root '$rlEdgeP' --base-sha '$edgeBase'") -join "`n"
        $shMechMvExit = $LASTEXITCODE
        $shSymDrop = (& $script:GitBash -c "'$guardShPosix' symbol-check --repo-root '$rlEdgeP' --base-sha '$edgeBase'") -join "`n"
        $shSymDropExit = $LASTEXITCODE
        # Temporarily restore lib.ts export + remove dropped export check to verify move ok in Bash too, and check check-freshness parity
        [IO.File]::WriteAllText((Join-Path $rlEdgeRepo 'src\lib.ts'), "export function droppedFn() { return 2; }`n", (New-Object System.Text.UTF8Encoding($false)))
        $shSymMvOk = (& $script:GitBash -c "'$guardShPosix' symbol-check --repo-root '$rlEdgeP' --base-sha '$edgeBase'") -join "`n"
        $shSymMvOkExit = $LASTEXITCODE
        [IO.File]::WriteAllText((Join-Path $rlEdgeRepo 'src\new_obs.ts'), "const legacy = 'OLD_TOK_XYZ';`n", (New-Object System.Text.UTF8Encoding($false)))
        $shObs = (& $script:GitBash -c "'$guardShPosix' mechanical-check --repo-root '$rlEdgeP' --base-sha '$edgeBase' --obsoletes 'OLD_TOK_XYZ'") -join "`n"
        $shObsExit = $LASTEXITCODE
        Remove-Item -LiteralPath (Join-Path $rlEdgeRepo 'src\new_obs.ts') -Force
        [IO.File]::WriteAllText((Join-Path $rlEdgeRepo 'src\a.ts'), "// owned`n", (New-Object System.Text.UTF8Encoding($false)))
        $shCf = (& $script:GitBash -c "'$guardShPosix' check-freshness --repo-root '$rlEdgeP' --approach-at-sha '$edgeBase' --task-base-sha '$edgeBase' --watched-paths 'src' --owned-files 'src/a.ts,src/b.ts,src/caller.ts'") -join "`n"
        $shCfExit = $LASTEXITCODE
        $rlEdgeShOk = ($shMechMvExit -eq 0) -and ($shMechMv -match 'MECHANICAL_OK') -and
                      ($shSymDropExit -eq 2) -and ($shSymDrop -match 'exported_removed=droppedFn') -and ($shSymDrop -match 'dangling_refs=droppedFn\(1f\)') -and
                      ($shSymMvOkExit -eq 0) -and ($shSymMvOk -match 'SYMBOL_OK') -and
                      ($shObsExit -eq 2) -and ($shObs -match 'obsolete_hits=OLD_TOK_XYZ\(1f\)') -and
                      ($shCfExit -eq 0) -and ($shCf -eq 'FRESH')
    }
    Pop-Location

    if ($cfOwnedOkExit -eq 0 -and $cfOwnedOk -eq 'FRESH' -and
        $cfUnownedStaleExit -eq 2 -and ($cfUnownedStale -match 'src/b\.ts') -and
        $mechCleanMoveExit -eq 0 -and ($mechCleanMove -match 'MECHANICAL_OK') -and
        $mechObsUntrExit -eq 2 -and ($mechObsUntr -match 'obsolete_hits=OLD_TOK_XYZ\(1f\)') -and
        $symMoveOkExit -eq 0 -and ($symMoveOk -match 'SYMBOL_OK') -and
        $symDropExpExit -eq 2 -and ($symDropExp -match 'exported_removed=droppedFn') -and ($symDropExp -match 'dangling_refs=droppedFn\(1f\)') -and
        $rlEdgeShOk) {
        Pass 'guard-review-loop-edge-fixes'
    } else {
        FailCheck 'guard-review-loop-edge-fixes' "cf=(${cfOwnedOkExit}/${cfUnownedStaleExit}) mv=(${mechCleanMoveExit}:${mechCleanMove}) obs=(${mechObsUntrExit}:${mechObsUntr}) symMv=(${symMoveOkExit}:${symMoveOk}) symDrop=(${symDropExpExit}:${symDropExp}) sh=${rlEdgeShOk}"
    }

    $igRepo = Join-Path $sandbox 'ignored-b3-wt'
    New-Item -ItemType Directory -Path (Join-Path $igRepo 'src') | Out-Null
    & git -C $igRepo init -q | Out-Null
    & git -C $igRepo config user.email 'b3@example.com' | Out-Null
    & git -C $igRepo config user.name 'B3' | Out-Null
    [IO.File]::WriteAllText((Join-Path $igRepo '.gitignore'), ".b3/`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $igRepo 'src\app.js'), "const v = 1;`n", [Text.UTF8Encoding]::new($false))
    & git -C $igRepo add .gitignore src/app.js | Out-Null
    & git -C $igRepo commit -q -m 'init' | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $igRepo '.b3\worktrees\w1') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $igRepo '.b3\worktrees\w1\scratch.txt'), "wt`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $igRepo 'src\app.js'), "const v = 2;`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $igRepo 'src\extra.js'), "const e = 3;`n", [Text.UTF8Encoding]::new($false))

    $igGuardSh = ((Join-Path $root 'scripts\b3-guard.sh') -replace '\\', '/') -replace '^([A-Za-z]):', '/$1'
    $igRepoPosix = ($igRepo -replace '\\', '/') -replace '^([A-Za-z]):', '/$1'
    $igSnapPs = (Invoke-GuardRaw snapshot -RepoRoot $igRepo 2>&1 | Out-String).Trim()
    $igSnapPsExit = $LASTEXITCODE
    $igMcPs = (Invoke-GuardRaw mechanical-check -RepoRoot $igRepo -BaseSha HEAD -AllowedPaths 'src/app.js,src/extra.js' 2>&1 | Out-String).Trim()
    $igMcPsExit = $LASTEXITCODE
    $igShOk = $true
    if ($script:HasBash) {
        $igSnapShOut = (& $script:GitBash -c "'$igGuardSh' snapshot --repo-root '$igRepoPosix' 2>&1") -join "`n"
        $igSnapShExit = $LASTEXITCODE
        $igMcShOut = (& $script:GitBash -c "'$igGuardSh' mechanical-check --repo-root '$igRepoPosix' --base-sha HEAD --allowed-paths 'src/app.js,src/extra.js' 2>&1") -join "`n"
        $igMcShExit = $LASTEXITCODE
        $igSnapShTrim = $igSnapShOut.Trim()
        $igTreePs = (& git -C $igRepo rev-parse "${igSnapPs}^{tree}" 2>$null | Out-String).Trim()
        $igTreeSh = if ($igSnapShTrim -match '^[0-9a-f]{40}$') { (& git -C $igRepo rev-parse "${igSnapShTrim}^{tree}" 2>$null | Out-String).Trim() } else { '' }
        $igShOk = ($igSnapShExit -eq 0 -and $igSnapShTrim -match '^[0-9a-f]{40}$' -and $igTreePs -and ($igTreePs -eq $igTreeSh) -and $igMcShExit -eq 0 -and ($igMcShOut -match 'MECHANICAL_OK'))
    }
    if ($igSnapPsExit -eq 0 -and $igSnapPs -match '^[0-9a-f]{40}$' -and $igMcPsExit -eq 0 -and ($igMcPs -match 'MECHANICAL_OK') -and $igShOk) {
        Pass 'guard-ignored-b3-snapshot'
    } else {
        FailCheck 'guard-ignored-b3-snapshot' "snapPs=(${igSnapPsExit}:$igSnapPs) mcPs=(${igMcPsExit}:$igMcPs) shOk=$igShOk"
    }

    # --- guard-adversarial-regressions (C-01, C-02, H-01, H-02, H-03, H-13, C-05; PS + Bash parity) ---
    $advErrs = New-Object System.Collections.Generic.List[string]
    $advRepo = Join-Path $sandbox 'adv-reg-repo'
    $advRepoPosix = To-PosixPath $advRepo
    $utf8NoBomAdv = New-Object System.Text.UTF8Encoding($false)
    Init-B3TestRepo -RepoPath $advRepo -InitialCommit -InitialFileName 'README.md' -InitialFileContent 'adv-base'
    New-Item -ItemType Directory -Path (Join-Path $advRepo 'src') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $advRepo 'src\a.ts'), "export const a = 1;`n", $utf8NoBomAdv)
    [IO.File]::WriteAllText((Join-Path $advRepo 'src\util.js'), "export const ok = 1;`n", $utf8NoBomAdv)
    & git -C $advRepo add src/a.ts src/util.js | Out-Null
    & git -C $advRepo commit -qm 'add adv files' | Out-Null

    # C-01: Bash (and PS) precommit --allowed-paths '*,.*' (glob) and '.' (root prefix) with staged .env + src/a.ts MUST fail closed (never PRECOMMIT_OK)
    [IO.File]::WriteAllText((Join-Path $advRepo '.env'), "SECRET=1`n", $utf8NoBomAdv)
    [IO.File]::WriteAllText((Join-Path $advRepo 'src\a.ts'), "export const a = 2;`n", $utf8NoBomAdv)
    & git -C $advRepo add .env src/a.ts | Out-Null
    $c01GlobPs = Invoke-PsGuard @('precommit', '-RepoRoot', $advRepo, '-AllowedPaths', '*,.*')
    $c01DotPs = Invoke-PsGuard @('precommit', '-RepoRoot', $advRepo, '-AllowedPaths', '.')
    if ($c01GlobPs.Code -ne 1 -or ($c01GlobPs.Text -match 'PRECOMMIT_OK') -or ($c01GlobPs.Text -notmatch "PRECOMMIT_FAIL: invalid glob in path '\*'")) {
        $advErrs.Add("C-01 glob PS expected fail-closed, got code=$($c01GlobPs.Code) out=$($c01GlobPs.Text)")
    }
    if ($c01DotPs.Code -ne 1 -or ($c01DotPs.Text -match 'PRECOMMIT_OK') -or ($c01DotPs.Text -notmatch 'PRECOMMIT_FAIL: secret path staged without exact allow')) {
        $advErrs.Add("C-01 dot PS expected secret fail-closed, got code=$($c01DotPs.Code) out=$($c01DotPs.Text)")
    }
    if ($script:HasBash) {
        $c01GlobSh = Invoke-ShGuard @('precommit', '--repo-root', $advRepoPosix, '--allowed-paths', '*,.*')
        $c01DotSh = Invoke-ShGuard @('precommit', '--repo-root', $advRepoPosix, '--allowed-paths', '.')
        if ($c01GlobSh.Code -ne 1 -or ($c01GlobSh.Text -match 'PRECOMMIT_OK') -or ($c01GlobSh.Text -notmatch "PRECOMMIT_FAIL: invalid glob in path '\*'")) {
            $advErrs.Add("C-01 glob SH expected fail-closed, got code=$($c01GlobSh.Code) out=$($c01GlobSh.Text)")
        }
        if ($c01DotSh.Code -ne 1 -or ($c01DotSh.Text -match 'PRECOMMIT_OK') -or ($c01DotSh.Text -notmatch 'PRECOMMIT_FAIL: secret path staged without exact allow')) {
            $advErrs.Add("C-01 dot SH expected secret fail-closed, got code=$($c01DotSh.Code) out=$($c01DotSh.Text)")
        }
    }
    & git -C $advRepo reset -q HEAD -- .env src/a.ts | Out-Null
    Remove-Item -LiteralPath (Join-Path $advRepo '.env') -Force
    & git -C $advRepo checkout -- src/a.ts | Out-Null

    # C-02: Static check asserting ZERO AWK {6}/{40} interval quantifiers in scripts/b3-guard.sh
    $guardShRaw = [IO.File]::ReadAllText((Join-Path $root 'scripts\b3-guard.sh'))
    $awkBlocks = [regex]::Matches($guardShRaw, "(?s)(?:\bawk\b(?:[^\n']|-F'[^']*'|\\\r?\n)*|_B3_RISK_AWK_LIB=)'(?:[^']*)'")
    $awkIntervalHits = @($awkBlocks | Where-Object { $_.Value -match '\{6\}|\{40\}' })
    if ($awkBlocks.Count -lt 1 -or $awkIntervalHits.Count -gt 0) {
        $advErrs.Add("C-02 awk interval check failed: blocks=$($awkBlocks.Count) hits=$($awkIntervalHits.Count)")
    }

    # H-01: verify-run rejects .git./hooks/probe, sub/.git/config, and absolute C:\...\file. & /c/.../.git./x in both PS and Bash
    $h01Cases = @(
        @{ Label = 'dot-git-dot'; Path = '.git./hooks/probe'; NoConv = $false },
        @{ Label = 'nested-git'; Path = 'sub/.git/config'; NoConv = $false },
        @{ Label = 'abs-win-dot'; Path = (Join-Path $advRepo 'file.'); NoConv = $false },
        @{ Label = 'abs-posix-git-dot'; Path = '/c/tmp/.git./x'; NoConv = $true }
    )
    foreach ($hc in $h01Cases) {
        $hPs = Invoke-PsGuard @('verify-run', '-RepoRoot', $advRepo, '-VerifyCmd', 'echo h01', '-ReceiptPath', $hc.Path)
        if ($hPs.Code -ne 1 -or ($hPs.Text -notmatch 'VERIFY_RUN_FAIL: invalid receipt_path')) {
            $advErrs.Add("H-01 PS $($hc.Label) expected invalid receipt_path exit 1, got code=$($hPs.Code) out=$($hPs.Text)")
        }
        if ($script:HasBash) {
            $prevNoConvH01 = $env:MSYS_NO_PATHCONV
            try {
                if ($hc.NoConv) { $env:MSYS_NO_PATHCONV = '1' }
                $hSh = Invoke-ShGuard @('verify-run', '--repo-root', $advRepoPosix, '--verify-cmd', 'echo h01', '--receipt-path', $hc.Path)
            } finally {
                if ($hc.NoConv) {
                    if ($null -eq $prevNoConvH01) { Remove-Item Env:MSYS_NO_PATHCONV -ErrorAction SilentlyContinue } else { $env:MSYS_NO_PATHCONV = $prevNoConvH01 }
                }
            }
            if ($hSh.Code -ne 1 -or ($hSh.Text -notmatch 'VERIFY_RUN_FAIL: invalid receipt_path')) {
                $advErrs.Add("H-01 SH $($hc.Label) expected invalid receipt_path exit 1, got code=$($hSh.Code) out=$($hSh.Text)")
            }
        }
    }

    # H-02: diff-scope on neutral file (src/util.js) containing '++ // note' followed by eval + destructive SQL -> risk_level=CRITICAL
    $h02Sql = 'DROP ' + 'TABLE users;'
    [IO.File]::WriteAllText((Join-Path $advRepo 'src\util.js'), "export const ok = 1;`n++ // note`neval(userInput); $h02Sql`n", $utf8NoBomAdv)
    $h02Ps = Invoke-PsGuard @('diff-scope', '-RepoRoot', $advRepo, '-BaseSha', 'HEAD')
    if ($h02Ps.Code -ne 0 -or ($h02Ps.Text -notmatch '(?m)^risk_level=CRITICAL$')) {
        $advErrs.Add("H-02 PS expected risk_level=CRITICAL, got code=$($h02Ps.Code) out=$($h02Ps.Text)")
    }
    if ($script:HasBash) {
        $h02Sh = Invoke-ShGuard @('diff-scope', '--repo-root', $advRepoPosix, '--base-sha', 'HEAD')
        if ($h02Sh.Code -ne 0 -or ($h02Sh.Text -notmatch '(?m)^risk_level=CRITICAL$')) {
            $advErrs.Add("H-02 SH expected risk_level=CRITICAL, got code=$($h02Sh.Code) out=$($h02Sh.Text)")
        }
    }
    & git -C $advRepo checkout -- src/util.js | Out-Null

    # H-03: Staged BROKEN_STAGED_CONTENT while WT matches HEAD causes verify-check -> VERIFY_STALE (exit 2) in PS and Bash
    $h03Rec = '.b3/ship/runs/r1/evidence/h03.verify'
    $h03Run = Invoke-PsGuard @('verify-run', '-RepoRoot', $advRepo, '-VerifyCmd', 'echo h03-clean', '-ReceiptPath', $h03Rec, '-TaskId', 'H03', '-RelevantPaths', 'src/a.ts')
    if ($h03Run.Code -ne 0 -or ($h03Run.Text -notmatch 'VERIFY_PASS:')) {
        $advErrs.Add("H-03 seed verify-run failed: code=$($h03Run.Code) out=$($h03Run.Text)")
    } else {
        [IO.File]::WriteAllText((Join-Path $advRepo 'src\a.ts'), "BROKEN_STAGED_CONTENT`n", $utf8NoBomAdv)
        & git -C $advRepo add src/a.ts | Out-Null
        [IO.File]::WriteAllText((Join-Path $advRepo 'src\a.ts'), "export const a = 1;`n", $utf8NoBomAdv)
        $prevEapH03 = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $h03WtDiff = (& git -C $advRepo diff HEAD -- src/a.ts 2>$null | Out-String).Trim() } finally { $ErrorActionPreference = $prevEapH03 }
        if ($h03WtDiff) { $advErrs.Add("H-03 setup expected WT==HEAD, got: $h03WtDiff") }
        $h03Ps = Invoke-PsGuard @('verify-check', '-RepoRoot', $advRepo, '-ReceiptPath', $h03Rec)
        if ($h03Ps.Code -ne 2 -or ($h03Ps.Text -notmatch 'VERIFY_STALE:')) {
            $advErrs.Add("H-03 PS expected VERIFY_STALE exit 2, got code=$($h03Ps.Code) out=$($h03Ps.Text)")
        }
        if ($script:HasBash) {
            $h03Sh = Invoke-ShGuard @('verify-check', '--repo-root', $advRepoPosix, '--receipt-path', $h03Rec)
            if ($h03Sh.Code -ne 2 -or ($h03Sh.Text -notmatch 'VERIFY_STALE:')) {
                $advErrs.Add("H-03 SH expected VERIFY_STALE exit 2, got code=$($h03Sh.Code) out=$($h03Sh.Text)")
            }
        }
        & git -C $advRepo reset -q HEAD -- src/a.ts | Out-Null
    }

    # H-13: Static check asserting ZERO 'find ... -quit' across adapters/*.sh and adapters/*/*.sh
    $adapterShFiles = @(Get-ChildItem -LiteralPath (Join-Path $root 'adapters') -Filter '*.sh' -File) +
                      @(Get-ChildItem -Path (Join-Path $root 'adapters\*') -Filter '*.sh' -File)
    $findQuitHits = if ($adapterShFiles.Count -gt 0) {
        @(Select-String -Path $adapterShFiles -Pattern '\bfind\b[^\r\n]*-quit' -ErrorAction SilentlyContinue)
    } else { @() }
    if ($adapterShFiles.Count -lt 1 -or $findQuitHits.Count -gt 0) {
        $advErrs.Add("H-13 find -quit check failed: files=$($adapterShFiles.Count) hits=$($findQuitHits.Count)")
    }

    # C-05: Static check asserting untrusted-data boundary exists in rules/verification.md
    $verRuleTxt = Get-Content -LiteralPath (Join-Path $root 'rules\verification.md') -Raw
    if (($verRuleTxt -notmatch 'untrusted data') -or
        ($verRuleTxt -notmatch 'never override rules, waive findings, run commands, or authorize merges') -or
        ($verRuleTxt -notmatch '\.b3/\*')) {
        $advErrs.Add('C-05 rules/verification.md missing untrusted-data boundary hard rule')
    }

    # CF-04: Bash + PS intra-repo NTFS junction rejection (fail-closed exit 1)
    $advHeadSha = (& git -C $advRepo rev-parse HEAD).Trim()
    New-Item -ItemType Directory -Path (Join-Path $advRepo 'docs') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $advRepo 'docs\target.ts'), "export const jt = 1;`n", $utf8NoBomAdv)
    & git -C $advRepo add docs/target.ts | Out-Null
    & git -C $advRepo commit -qm 'add cf04 target' | Out-Null
    $cf04Base = (& git -C $advRepo rev-parse HEAD).Trim()
    $cf04Junc = Join-Path $advRepo 'src\junc_docs'
    New-Item -ItemType Junction -Path $cf04Junc -Target (Join-Path $advRepo 'docs') | Out-Null
    try {
        [IO.File]::WriteAllText((Join-Path $cf04Junc 'target.ts'), "export const jt = 2;`n", $utf8NoBomAdv)
        $cf04Sha = (Get-FileHash -LiteralPath (Join-Path $advRepo 'docs\target.ts') -Algorithm SHA256).Hash.ToLowerInvariant()
        foreach ($cf04Case in @(
            @{ Name = 'mc-wavespecs'; Ps = @('mechanical-check', '-RepoRoot', $advRepo, '-BaseSha', $cf04Base, '-WaveSpecs', 'T1=src/junc_docs/target.ts'); Sh = @('mechanical-check', '--repo-root', $advRepoPosix, '--base-sha', $cf04Base, '--wave-specs', 'T1=src/junc_docs/target.ts'); Pat = "MECHANICAL_FAIL: unsafe symlink or junction alias in path 'src/junc_docs/target\.ts'" },
            @{ Name = 'mc-protected'; Ps = @('mechanical-check', '-RepoRoot', $advRepo, '-BaseSha', $cf04Base, '-ProtectedPaths', 'src/junc_docs/target.ts'); Sh = @('mechanical-check', '--repo-root', $advRepoPosix, '--base-sha', $cf04Base, '--protected-paths', 'src/junc_docs/target.ts'); Pat = "MECHANICAL_FAIL: unsafe symlink or junction alias in path 'src/junc_docs/target\.ts'" },
            @{ Name = 'mc-dirtydigests'; Ps = @('mechanical-check', '-RepoRoot', $advRepo, '-BaseSha', $cf04Base, '-DirtyDigests', "src/junc_docs/target.ts=$cf04Sha"); Sh = @('mechanical-check', '--repo-root', $advRepoPosix, '--base-sha', $cf04Base, '--dirty-digests', "src/junc_docs/target.ts=$cf04Sha"); Pat = "MECHANICAL_FAIL: unsafe symlink or junction alias in path 'src/junc_docs/target\.ts'" },
            @{ Name = 'vr-receipt'; Ps = @('verify-run', '-RepoRoot', $advRepo, '-VerifyCmd', 'echo j', '-ReceiptPath', 'src/junc_docs/r.verify'); Sh = @('verify-run', '--repo-root', $advRepoPosix, '--verify-cmd', 'echo j', '--receipt-path', 'src/junc_docs/r.verify'); Pat = 'VERIFY_RUN_FAIL: invalid receipt_path' }
        )) {
            $jPs = Invoke-PsGuard $cf04Case.Ps
            if ($jPs.Code -ne 1 -or ($jPs.Text -notmatch $cf04Case.Pat)) {
                $advErrs.Add("CF-04 $($cf04Case.Name) PS expected exit 1, got code=$($jPs.Code) out=$($jPs.Text)")
            }
            if ($script:HasBash) {
                $jSh = Invoke-ShGuard $cf04Case.Sh
                if ($jSh.Code -ne 1 -or ($jSh.Text -notmatch $cf04Case.Pat)) {
                    $advErrs.Add("CF-04 $($cf04Case.Name) SH expected exit 1, got code=$($jSh.Code) out=$($jSh.Text)")
                }
            }
        }
    } finally {
        if (Test-Path -LiteralPath $cf04Junc) { [System.IO.Directory]::Delete($cf04Junc, $false) }
        & git -C $advRepo checkout -- docs/target.ts | Out-Null
    }

    # CF-05: check-freshness flag injection (-s) rejected fail-closed (exit 1) in PS and Bash
    foreach ($cf05Case in @(
        @{ Name = 'approach-sha-dash-s'; Ps = @('check-freshness', '-RepoRoot', $advRepo, '-ApproachAtSha', '-s', '-TaskBaseSha', $cf04Base, '-WatchedPaths', 'src/a.ts'); Sh = @('check-freshness', '--repo-root', $advRepoPosix, '--approach-at-sha', '-s', '--task-base-sha', $cf04Base, '--watched-paths', 'src/a.ts') },
        @{ Name = 'task-base-dash-s'; Ps = @('check-freshness', '-RepoRoot', $advRepo, '-ApproachAtSha', $cf04Base, '-TaskBaseSha', '-s', '-WatchedPaths', 'src/a.ts'); Sh = @('check-freshness', '--repo-root', $advRepoPosix, '--approach-at-sha', $cf04Base, '--task-base-sha', '-s', '--watched-paths', 'src/a.ts') }
    )) {
        $fPs = Invoke-PsGuard $cf05Case.Ps
        if ($fPs.Code -ne 1 -or ($fPs.Text -notmatch '^FRESHNESS_FAIL: invalid')) {
            $advErrs.Add("CF-05 $($cf05Case.Name) PS expected FRESHNESS_FAIL: invalid exit 1, got code=$($fPs.Code) out=$($fPs.Text)")
        }
        if ($script:HasBash) {
            $fSh = Invoke-ShGuard $cf05Case.Sh
            if ($fSh.Code -ne 1 -or ($fSh.Text -notmatch '^FRESHNESS_FAIL: invalid')) {
                $advErrs.Add("CF-05 $($cf05Case.Name) SH expected FRESHNESS_FAIL: invalid exit 1, got code=$($fSh.Code) out=$($fSh.Text)")
            }
        }
    }

    if ($advErrs.Count -eq 0) {
        Pass 'guard-adversarial-regressions'
    } else {
        FailCheck 'guard-adversarial-regressions' ($advErrs -join '; ')
    }

    # --- CF-17: real out-of-process CLI smoke (powershell -File $guardScript + B3_TEST_OUT_OF_PROC_PS=1 Invoke-PsGuard) ---
    $oopErrs = New-Object System.Collections.Generic.List[string]
    $oopPrevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $oopFpOut = ((& powershell -NoProfile -ExecutionPolicy Bypass -File $guardScript fingerprint -DependsOn 'T002,T001' -Scope 'src/a.ts' -Criteria 'AC1: ok' 2>&1) | ForEach-Object { ([string]$_).TrimEnd("`r") }) -join "`n"
        $oopFpCode = $LASTEXITCODE
        $oopDsOut = ((& powershell -NoProfile -ExecutionPolicy Bypass -File $guardScript diff-scope -RepoRoot $advRepo -BaseSha $cf04Base 2>&1) | ForEach-Object { ([string]$_).TrimEnd("`r") }) -join "`n"
        $oopDsCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oopPrevEap
    }
    if ($oopFpCode -ne 0 -or $oopFpOut -cne 'depends_on=T001,T002|scope=src/a.ts|acceptance_criteria=AC1: ok') {
        $oopErrs.Add("direct -File fingerprint code=$oopFpCode out=$oopFpOut")
    }
    if ($oopDsCode -ne 2 -or $oopDsOut -notmatch '(?m)^EMPTY_DIFF$') {
        $oopErrs.Add("direct -File diff-scope EMPTY_DIFF code=$oopDsCode out=$oopDsOut")
    }
    $prevOopEnv = $env:B3_TEST_OUT_OF_PROC_PS
    try {
        $env:B3_TEST_OUT_OF_PROC_PS = '1'
        $oopCfOk = Invoke-PsGuard @('check-freshness', '-RepoRoot', $advRepo, '-ApproachAtSha', $cf04Base, '-TaskBaseSha', $cf04Base, '-WatchedPaths', 'src/a.ts')
        $oopCfBad = Invoke-PsGuard @('check-freshness', '-RepoRoot', $advRepo, '-ApproachAtSha:-s', '-TaskBaseSha', $cf04Base, '-WatchedPaths', 'src/a.ts')
    } finally {
        if ($null -eq $prevOopEnv) { Remove-Item Env:B3_TEST_OUT_OF_PROC_PS -ErrorAction SilentlyContinue } else { $env:B3_TEST_OUT_OF_PROC_PS = $prevOopEnv }
    }
    if ($oopCfOk.Code -ne 0 -or $oopCfOk.Text -cne 'FRESH') {
        $oopErrs.Add("B3_TEST_OUT_OF_PROC_PS check-freshness FRESH code=$($oopCfOk.Code) out=$($oopCfOk.Text)")
    }
    if ($oopCfBad.Code -ne 1 -or $oopCfBad.Text -notmatch '^FRESHNESS_FAIL: invalid') {
        $oopErrs.Add("B3_TEST_OUT_OF_PROC_PS check-freshness -s code=$($oopCfBad.Code) out=$($oopCfBad.Text)")
    }
    if ($oopErrs.Count -eq 0) {
        Pass 'guard-out-of-proc-cli-smoke'
    } else {
        FailCheck 'guard-out-of-proc-cli-smoke' ($oopErrs -join '; ')
    }

    # --- guard-wave-partition-orchestration (Scenarios 1-5, 14: partition, RW, base/protected/dirty, PS+Bash parity) ---
    $pwErrs = New-Object System.Collections.Generic.List[string]
    $pwRepo = Join-Path $sandbox 'wave-orch-repo'
    $pwRepoPosix = To-PosixPath $pwRepo
    $utf8NoBomPw = New-Object System.Text.UTF8Encoding($false)
    Init-B3TestRepo -RepoPath $pwRepo -InitialCommit -InitialFileName 'README.md' -InitialFileContent 'pw-base'
    New-Item -ItemType Directory -Path (Join-Path $pwRepo 'api'), (Join-Path $pwRepo 'ui'), (Join-Path $pwRepo 'src\shared') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $pwRepo 'api\a.ts'), "export const a = 1;`n", $utf8NoBomPw)
    [IO.File]::WriteAllText((Join-Path $pwRepo 'api\b.ts'), "export const b = 1;`n", $utf8NoBomPw)
    [IO.File]::WriteAllText((Join-Path $pwRepo 'ui\b.tsx'), "export const B = () => null;`n", $utf8NoBomPw)
    [IO.File]::WriteAllText((Join-Path $pwRepo 'src\shared\types.ts'), "export type Id = string;`n", $utf8NoBomPw)
    [IO.File]::WriteAllText((Join-Path $pwRepo 'src\b.ts'), "export const sb = 1;`n", $utf8NoBomPw)
    [IO.File]::WriteAllText((Join-Path $pwRepo 'src\c.ts'), "export const sc = 1;`n", $utf8NoBomPw)
    & git -C $pwRepo add . | Out-Null
    & git -C $pwRepo commit -qm 'seed wave files' | Out-Null
    $pwBaseOld = (& git -C $pwRepo rev-parse HEAD).Trim()
    [IO.File]::WriteAllText((Join-Path $pwRepo 'README.md'), "pw-base-2`n", $utf8NoBomPw)
    & git -C $pwRepo add README.md | Out-Null
    & git -C $pwRepo commit -qm 'advance head' | Out-Null
    $pwBaseNow = (& git -C $pwRepo rev-parse HEAD).Trim()

    $checkWaveParity = {
        param(
            [string]$CaseName,
            [string[]]$PsArgs,
            [string[]]$ShArgs,
            [int]$ExpectedExit,
            [string[]]$Patterns,
            [switch]$RequireExactTextParity
        )
        $psRes = Invoke-PsGuard $PsArgs
        if ($psRes.Code -ne $ExpectedExit) {
            $pwErrs.Add("$CaseName PS exit=$($psRes.Code) expected=$ExpectedExit out=$($psRes.Text)")
            return
        }
        foreach ($pat in $Patterns) {
            if ($psRes.Text -notmatch $pat) {
                $pwErrs.Add("$CaseName PS missing /$pat/ in: $($psRes.Text)")
            }
        }
        if ($script:HasBash) {
            $shRes = Invoke-ShGuard $ShArgs
            if ($shRes.Code -ne $ExpectedExit) {
                $pwErrs.Add("$CaseName SH exit=$($shRes.Code) expected=$ExpectedExit out=$($shRes.Text)")
                return
            }
            foreach ($pat in $Patterns) {
                if ($shRes.Text -notmatch $pat) {
                    $pwErrs.Add("$CaseName SH missing /$pat/ in: $($shRes.Text)")
                }
            }
            if ($RequireExactTextParity -and ($psRes.Text -cne $shRes.Text)) {
                $pwErrs.Add("$CaseName PS/SH stdout mismatch:`nPS=$($psRes.Text)`nSH=$($shRes.Text)")
            }
        }
    }

    # Scenario 1: Disjoint multi-task wave -> WAVE_OK, wave|1|PARALLEL|agents=2
    & $checkWaveParity 's1-disjoint-wave' `
        @('check-wave', '-RepoRoot', $pwRepo, '-Partition', '-WaveSpecs', 'T001=api/a.ts;T002=ui/b.tsx', '-ExpectedBaseSha', $pwBaseNow) `
        @('check-wave', '--repo-root', $pwRepoPosix, '--partition', '--wave-specs', 'T001=api/a.ts;T002=ui/b.tsx', '--expected-base-sha', $pwBaseNow) `
        0 @('(?m)^wave_count=1$', '(?m)^max_parallel=2$', '(?m)^conflicts=none$', '(?m)^wave\|1\|PARALLEL\|agents=2\|tasks=T001,T002\|reason=independent_ready_tasks$', 'WAVE_OK: disjoint \(2 tasks, 2 paths\)') -RequireExactTextParity

    # Scenario 2: Bounded concurrency (MaxConcurrency=1) & single_ready_task
    & $checkWaveParity 's2-bounded-concurrency-1' `
        @('check-wave', '-RepoRoot', $pwRepo, '-Partition', '-MaxConcurrency', '1', '-WaveSpecs', 'T001=api/a.ts;T002=ui/b.tsx') `
        @('check-wave', '--repo-root', $pwRepoPosix, '--partition', '--max-concurrency', '1', '--wave-specs', 'T001=api/a.ts;T002=ui/b.tsx') `
        0 @('(?m)^wave_count=2$', '(?m)^max_concurrency=1$', '(?m)^max_parallel=1$', '(?m)^wave\|1\|SEQUENTIAL\|agents=1\|tasks=T001\|reason=bounded_concurrency$', '(?m)^wave\|2\|SEQUENTIAL\|agents=1\|tasks=T002\|reason=bounded_concurrency$', 'WAVE_SEQUENTIAL: waves=2 max_parallel=1 reason=bounded_concurrency') -RequireExactTextParity
    & $checkWaveParity 's2-single-ready-task' `
        @('check-wave', '-RepoRoot', $pwRepo, '-Partition', '-WaveSpecs', 'T001=api/a.ts') `
        @('check-wave', '--repo-root', $pwRepoPosix, '--partition', '--wave-specs', 'T001=api/a.ts') `
        0 @('(?m)^wave_count=1$', '(?m)^max_parallel=1$', '(?m)^wave\|1\|SEQUENTIAL\|agents=1\|tasks=T001\|reason=single_ready_task$', 'WAVE_OK: disjoint \(1 tasks, 1 paths\)') -RequireExactTextParity

    # Scenario 3: Conflicting writes partitioned cleanly + all-conflicting degrades to WAVE_SEQUENTIAL (exit 2)
    & $checkWaveParity 's3-conflicting-writes-split' `
        @('check-wave', '-RepoRoot', $pwRepo, '-Partition', '-WaveSpecs', 'T001=api/a.ts;T002=api/b.ts;T003=api/a.ts') `
        @('check-wave', '--repo-root', $pwRepoPosix, '--partition', '--wave-specs', 'T001=api/a.ts;T002=api/b.ts;T003=api/a.ts') `
        0 @('(?m)^wave_count=2$', '(?m)^max_parallel=2$', '(?m)^conflicts=api/a\.ts\(T001,T003\)$', '(?m)^wave\|1\|PARALLEL\|agents=2\|tasks=T001,T002\|reason=independent_ready_tasks$', '(?m)^wave\|2\|SEQUENTIAL\|agents=1\|tasks=T003\|reason=shared_write_conflict$', 'WAVE_PARTITIONED: waves=2 max_parallel=2 reason=conflicting_wave_split') -RequireExactTextParity
    & $checkWaveParity 's3-all-conflict-sequential' `
        @('check-wave', '-RepoRoot', $pwRepo, '-Partition', '-WaveSpecs', 'T001=api/a.ts;T002=api/a.ts') `
        @('check-wave', '--repo-root', $pwRepoPosix, '--partition', '--wave-specs', 'T001=api/a.ts;T002=api/a.ts') `
        2 @('(?m)^wave_count=2$', '(?m)^max_parallel=1$', '(?m)^wave\|1\|SEQUENTIAL\|agents=1\|tasks=T001\|reason=shared_write_conflict$', 'WAVE_SEQUENTIAL: waves=2 max_parallel=1 reason=shared_write_conflict') -RequireExactTextParity

    # Scenario 4: Shared-contract RW conflict (equal + prefix) partitions cleanly
    & $checkWaveParity 's4-rw-equal-partition' `
        @('check-wave', '-RepoRoot', $pwRepo, '-Partition', '-WaveSpecs', 'T001=src/shared.ts;T002=src/b.ts;T003=src/c.ts', '-WaveReads', 'T002=src/shared.ts;T003=src/d.ts') `
        @('check-wave', '--repo-root', $pwRepoPosix, '--partition', '--wave-specs', 'T001=src/shared.ts;T002=src/b.ts;T003=src/c.ts', '--wave-reads', 'T002=src/shared.ts;T003=src/d.ts') `
        0 @('(?m)^conflicts=rw:src/shared\.ts\(T001->T002\)$', '(?m)^wave\|1\|PARALLEL\|agents=2\|tasks=T001,T003\|reason=independent_ready_tasks$', '(?m)^wave\|2\|SEQUENTIAL\|agents=1\|tasks=T002\|reason=shared_write_conflict$', 'WAVE_PARTITIONED: waves=2 max_parallel=2') -RequireExactTextParity
    & $checkWaveParity 's4-rw-prefix-partition' `
        @('check-wave', '-RepoRoot', $pwRepo, '-Partition', '-WaveSpecs', 'T001=src/shared/types.ts;T002=src/b.ts;T003=src/c.ts', '-WaveReads', 'T002=src/shared;T003=src/d.ts') `
        @('check-wave', '--repo-root', $pwRepoPosix, '--partition', '--wave-specs', 'T001=src/shared/types.ts;T002=src/b.ts;T003=src/c.ts', '--wave-reads', 'T002=src/shared;T003=src/d.ts') `
        0 @('(?m)^conflicts=rw:src/shared/types\.ts<->src/shared\(T001->T002\)$', '(?m)^wave\|1\|PARALLEL\|agents=2\|tasks=T001,T003\|reason=independent_ready_tasks$', '(?m)^wave\|2\|SEQUENTIAL\|agents=1\|tasks=T002\|reason=shared_write_conflict$') -RequireExactTextParity

    # Scenario 5: Stale base SHA (exit 2), protected paths (exit 1), and dirty working tree overlap blocking freshness/precommit
    & $checkWaveParity 's5-stale-base-sha' `
        @('check-wave', '-RepoRoot', $pwRepo, '-Partition', '-WaveSpecs', 'T001=api/a.ts;T002=ui/b.tsx', '-ExpectedBaseSha', $pwBaseOld) `
        @('check-wave', '--repo-root', $pwRepoPosix, '--partition', '--wave-specs', 'T001=api/a.ts;T002=ui/b.tsx', '--expected-base-sha', $pwBaseOld) `
        2 @("WAVE_BASE_MISMATCH: expected=$pwBaseOld actual=$pwBaseNow") -RequireExactTextParity
    foreach ($protPath in @('.b3', '.b3/ship', '.git')) {
        & $checkWaveParity "s5-protected-$protPath" `
            @('check-wave', '-RepoRoot', $pwRepo, '-WaveSpecs', "T001=$protPath;T002=ui/b.tsx") `
            @('check-wave', '--repo-root', $pwRepoPosix, '--wave-specs', "T001=$protPath;T002=ui/b.tsx") `
            1 @('WAVE_FAIL: protected path .* cannot be worker-owned') -RequireExactTextParity
    }
    [IO.File]::WriteAllText((Join-Path $pwRepo 'src\shared\types.ts'), "export type Id = number;`n", $utf8NoBomPw)
    $s5CfPs = Invoke-PsGuard @('check-freshness', '-RepoRoot', $pwRepo, '-ApproachAtSha', $pwBaseNow, '-TaskBaseSha', $pwBaseNow, '-WatchedPaths', 'api/a.ts,src/shared/types.ts', '-OwnedFiles', 'api/a.ts')
    if ($s5CfPs.Code -ne 2 -or ($s5CfPs.Text -notmatch '^STALE: uncommitted.*src/shared/types\.ts')) {
        $pwErrs.Add("s5-dirty-freshness PS expected exit 2 STALE, got code=$($s5CfPs.Code) out=$($s5CfPs.Text)")
    }
    if ($script:HasBash) {
        $s5CfSh = Invoke-ShGuard @('check-freshness', '--repo-root', $pwRepoPosix, '--approach-at-sha', $pwBaseNow, '--task-base-sha', $pwBaseNow, '--watched-paths', 'api/a.ts,src/shared/types.ts', '--owned-files', 'api/a.ts')
        if ($s5CfSh.Code -ne 2 -or ($s5CfSh.Text -notmatch '^STALE: uncommitted.*src/shared/types\.ts')) {
            $pwErrs.Add("s5-dirty-freshness SH expected exit 2 STALE, got code=$($s5CfSh.Code) out=$($s5CfSh.Text)")
        }
    }
    & git -C $pwRepo add src/shared/types.ts | Out-Null
    $s5PcPs = Invoke-PsGuard @('precommit', '-RepoRoot', $pwRepo, '-AllowedPaths', 'api/a.ts')
    if ($s5PcPs.Code -ne 1 -or ($s5PcPs.Text -notmatch 'undeclared staged')) {
        $pwErrs.Add("s5-dirty-precommit PS expected undeclared staged exit 1, got code=$($s5PcPs.Code) out=$($s5PcPs.Text)")
    }
    & git -C $pwRepo reset -q HEAD src/shared/types.ts | Out-Null
    & git -C $pwRepo checkout -- src/shared/types.ts | Out-Null

    # Scenario 14: PS + Bash parity edge cases (multiline, None/NONE literal preservation, invalid task IDs, case-insensitive overlap, MaxConcurrency=2)
    $nlBetweenSpecs = "T1=api/a.ts;`nT2=api/b.ts"
    $nlBetweenReads = "T1=src/c.ts;`nT2=none"
    $nlInPathSpec = "T1=api/`na.ts;T2=api/b.ts"
    $nlInPathRead = "T1=src/`nc.ts;T2=none"
    & $checkWaveParity 's14-multiline-between-entries' `
        @('check-wave', '-RepoRoot', $pwRepo, '-WaveSpecs', $nlBetweenSpecs, '-WaveReads', $nlBetweenReads) `
        @('check-wave', '--repo-root', $pwRepoPosix, '--wave-specs', $nlBetweenSpecs, '--wave-reads', $nlBetweenReads) `
        0 @('WAVE_OK: disjoint \(2 tasks, 2 paths\)') -RequireExactTextParity
    & $checkWaveParity 's14-multiline-in-path-specs' `
        @('check-wave', '-RepoRoot', $pwRepo, '-WaveSpecs', $nlInPathSpec) `
        @('check-wave', '--repo-root', $pwRepoPosix, '--wave-specs', $nlInPathSpec) `
        1 @('WAVE_FAIL: invalid path') -RequireExactTextParity
    & $checkWaveParity 's14-multiline-in-path-reads' `
        @('check-wave', '-RepoRoot', $pwRepo, '-WaveSpecs', 'T1=api/a.ts;T2=api/b.ts', '-WaveReads', $nlInPathRead) `
        @('check-wave', '--repo-root', $pwRepoPosix, '--wave-specs', 'T1=api/a.ts;T2=api/b.ts', '--wave-reads', $nlInPathRead) `
        1 @('WAVE_FAIL: invalid path') -RequireExactTextParity
    & $checkWaveParity 's14-none-literal-vs-empty' `
        @('check-wave', '-RepoRoot', $pwRepo, '-Partition', '-WaveSpecs', 'T1=None;T2=api/b.ts', '-WaveReads', 'T2=none') `
        @('check-wave', '--repo-root', $pwRepoPosix, '--partition', '--wave-specs', 'T1=None;T2=api/b.ts', '--wave-reads', 'T2=none') `
        0 @('WAVE_OK: disjoint \(2 tasks, 2 paths\)') -RequireExactTextParity
    & $checkWaveParity 's14-none-upper-literal-rw-conflict' `
        @('check-wave', '-RepoRoot', $pwRepo, '-Partition', '-WaveSpecs', 'T1=None;T2=api/b.ts', '-WaveReads', 'T2=NONE') `
        @('check-wave', '--repo-root', $pwRepoPosix, '--partition', '--wave-specs', 'T1=None;T2=api/b.ts', '--wave-reads', 'T2=NONE') `
        2 @('conflicts=rw:None\(T1->T2\)', 'WAVE_SEQUENTIAL: waves=2 max_parallel=1 reason=shared_write_conflict') -RequireExactTextParity
    foreach ($badTid in @('T1,T2=api/a.ts', 'T1|T2=api/a.ts')) {
        & $checkWaveParity "s14-bad-tid-$badTid" `
            @('check-wave', '-RepoRoot', $pwRepo, '-WaveSpecs', $badTid) `
            @('check-wave', '--repo-root', $pwRepoPosix, '--wave-specs', $badTid) `
            1 @('WAVE_FAIL: invalid task id') -RequireExactTextParity
    }
    & $checkWaveParity 's14-case-insensitive-overlap' `
        @('check-wave', '-RepoRoot', $pwRepo, '-WaveSpecs', 'T1=Api/A.ts;T2=api/a.ts') `
        @('check-wave', '--repo-root', $pwRepoPosix, '--wave-specs', 'T1=Api/A.ts;T2=api/a.ts') `
        2 @('WAVE_CONFLICT: Api/A\.ts\(T1,T2\)') -RequireExactTextParity
    & $checkWaveParity 's14-max-concurrency-2-split' `
        @('check-wave', '-RepoRoot', $pwRepo, '-Partition', '-MaxConcurrency', '2', '-WaveSpecs', 'T1=api/a.ts;T2=api/b.ts;T3=ui/b.tsx') `
        @('check-wave', '--repo-root', $pwRepoPosix, '--partition', '--max-concurrency', '2', '--wave-specs', 'T1=api/a.ts;T2=api/b.ts;T3=ui/b.tsx') `
        0 @('(?m)^wave_count=2$', '(?m)^max_concurrency=2$', '(?m)^max_parallel=2$', '(?m)^conflicts=none$', '(?m)^wave\|1\|PARALLEL\|agents=2\|tasks=T1,T2\|reason=independent_ready_tasks$', '(?m)^wave\|2\|SEQUENTIAL\|agents=1\|tasks=T3\|reason=bounded_concurrency$', 'WAVE_PARTITIONED: waves=2 max_parallel=2 reason=bounded_concurrency_split') -RequireExactTextParity

    if ($pwErrs.Count -eq 0) {
        Pass 'guard-wave-partition-orchestration'
    } else {
        FailCheck 'guard-wave-partition-orchestration' ($pwErrs -join '; ')
    }

    # --- guard-adaptive-isolation-and-dirty-scope (PR #31 R001-R005: adaptive modes, dirty scope, '.' & junction containment, singleton->parallel, check-worktree -PeerRoots) ---
    $aiErrs = New-Object System.Collections.Generic.List[string]
    $aiRepo = Join-Path $sandbox 'adaptive-iso-repo'
    $aiRepoPosix = To-PosixPath $aiRepo
    $utf8NoBomAi = New-Object System.Text.UTF8Encoding($false)
    Init-B3TestRepo -RepoPath $aiRepo -InitialCommit -InitialFileName 'README.md' -InitialFileContent 'ai-base'
    New-Item -ItemType Directory -Path (Join-Path $aiRepo 'api'), (Join-Path $aiRepo 'ui'), (Join-Path $aiRepo 'src\shared'), (Join-Path $aiRepo 'src\api'), (Join-Path $aiRepo 'docs\authority'), (Join-Path $aiRepo 'config') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $aiRepo 'api\a.ts'), "export const a = 1;`n", $utf8NoBomAi)
    [IO.File]::WriteAllText((Join-Path $aiRepo 'ui\b.tsx'), "export const B = () => null;`n", $utf8NoBomAi)
    [IO.File]::WriteAllText((Join-Path $aiRepo 'src\c.ts'), "export const c = 1;`n", $utf8NoBomAi)
    [IO.File]::WriteAllText((Join-Path $aiRepo 'src\x.ts'), "export const x = 1;`n", $utf8NoBomAi)
    [IO.File]::WriteAllText((Join-Path $aiRepo 'src\y.ts'), "export const y = 1;`n", $utf8NoBomAi)
    [IO.File]::WriteAllText((Join-Path $aiRepo 'src\z.ts'), "export const z = 1;`n", $utf8NoBomAi)
    [IO.File]::WriteAllText((Join-Path $aiRepo 'src\shared\types.ts'), "export type Id = string;`n", $utf8NoBomAi)
    [IO.File]::WriteAllText((Join-Path $aiRepo 'docs\scratch.md'), "# scratch`n", $utf8NoBomAi)
    [IO.File]::WriteAllText((Join-Path $aiRepo 'docs\authority\pin.md'), "pin: v1`n", $utf8NoBomAi)
    [IO.File]::WriteAllText((Join-Path $aiRepo 'config\lock.json'), "{`"v`":1}`n", $utf8NoBomAi)
    & git -C $aiRepo add . | Out-Null
    & git -C $aiRepo commit -qm 'seed adaptive isolation files' | Out-Null
    $aiHead = (& git -C $aiRepo rev-parse HEAD).Trim()

    $checkAiParity = {
        param(
            [string]$CaseName,
            [string[]]$PsArgs,
            [string[]]$ShArgs,
            [int]$ExpectedExit,
            [string[]]$Patterns,
            [switch]$RequireExactTextParity
        )
        $psRes = Invoke-PsGuard $PsArgs
        if ($psRes.Code -ne $ExpectedExit) {
            $aiErrs.Add("$CaseName PS exit=$($psRes.Code) expected=$ExpectedExit out=$($psRes.Text)")
            return
        }
        foreach ($pat in $Patterns) {
            if ($psRes.Text -notmatch $pat) {
                $aiErrs.Add("$CaseName PS missing /$pat/ in: $($psRes.Text)")
            }
        }
        if ($script:HasBash) {
            $shRes = Invoke-ShGuard $ShArgs
            if ($shRes.Code -ne $ExpectedExit) {
                $aiErrs.Add("$CaseName SH exit=$($shRes.Code) expected=$ExpectedExit out=$($shRes.Text)")
                return
            }
            foreach ($pat in $Patterns) {
                if ($shRes.Text -notmatch $pat) {
                    $aiErrs.Add("$CaseName SH missing /$pat/ in: $($shRes.Text)")
                }
            }
            if ($RequireExactTextParity -and ($psRes.Text -cne $shRes.Text)) {
                $aiErrs.Add("$CaseName PS/SH stdout mismatch:`nPS=$($psRes.Text)`nSH=$($shRes.Text)")
            }
        }
    }

    # 1a. Shared disjoint writes with pre-existing user_dirty + mechanical-check unexpected side-effect detection + precommit + MERGE_HEAD
    $userScratchContent = "# user-dirty-preserve`n"
    [IO.File]::WriteAllText((Join-Path $aiRepo 'docs\scratch.md'), $userScratchContent, $utf8NoBomAi)
    & $checkAiParity 'ai-shared-disjoint-user-only' `
        @('check-wave', '-RepoRoot', $aiRepo, '-Partition', '-CheckDirtyScope', '-WaveSpecs', 'T001=api/a.ts;T002=ui/b.tsx', '-IgnoreDirtyPaths', 'docs/scratch.md', '-ExpectedBaseSha', $aiHead) `
        @('check-wave', '--repo-root', $aiRepoPosix, '--partition', '--check-dirty-scope', '--wave-specs', 'T001=api/a.ts;T002=ui/b.tsx', '--ignore-dirty-paths', 'docs/scratch.md', '--expected-base-sha', $aiHead) `
        0 @('(?m)^dirty_scope=user_only$', '(?m)^user_dirty=docs/scratch\.md$', '(?m)^unexpected_dirty=none$', '(?m)^blocked_tasks=none$', '(?m)^wave\|1\|PARALLEL\|agents=2\|tasks=T001,T002\|reason=independent_ready_tasks$', 'WAVE_OK: disjoint \(2 tasks, 2 paths\)') -RequireExactTextParity

    [IO.File]::WriteAllText((Join-Path $aiRepo 'api\a.ts'), "export const a = 2;`n", $utf8NoBomAi)
    [IO.File]::WriteAllText((Join-Path $aiRepo 'ui\b.tsx'), "export const B = () => 'ok';`n", $utf8NoBomAi)
    & $checkAiParity 'ai-shared-disjoint-mech-ok' `
        @('mechanical-check', '-RepoRoot', $aiRepo, '-AllowedPaths', 'api/a.ts,ui/b.tsx', '-IgnoreDirtyPaths', 'docs/scratch.md') `
        @('mechanical-check', '--repo-root', $aiRepoPosix, '--allowed-paths', 'api/a.ts,ui/b.tsx', '--ignore-dirty-paths', 'docs/scratch.md') `
        0 @('(?m)^scope_creep=none$', '(?m)^MECHANICAL_OK$') -RequireExactTextParity
    if ([IO.File]::ReadAllText((Join-Path $aiRepo 'docs\scratch.md')) -cne $userScratchContent) {
        $aiErrs.Add('ai-shared-disjoint modified pre-existing user_dirty docs/scratch.md')
    }

    New-Item -ItemType Directory -Path (Join-Path $aiRepo 'coverage') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $aiRepo 'coverage\out.json'), "{}`n", $utf8NoBomAi)
    [IO.File]::WriteAllText((Join-Path $aiRepo 'src\c.ts'), "export const c = 99;`n", $utf8NoBomAi)
    & $checkAiParity 'ai-shared-disjoint-mech-creep' `
        @('mechanical-check', '-RepoRoot', $aiRepo, '-AllowedPaths', 'api/a.ts,ui/b.tsx', '-IgnoreDirtyPaths', 'docs/scratch.md') `
        @('mechanical-check', '--repo-root', $aiRepoPosix, '--allowed-paths', 'api/a.ts,ui/b.tsx', '--ignore-dirty-paths', 'docs/scratch.md') `
        2 @('(?m)^scope_creep=coverage/out\.json,src/c\.ts$', '(?m)^MECHANICAL_FINDINGS$') -RequireExactTextParity
    if ([IO.File]::ReadAllText((Join-Path $aiRepo 'docs\scratch.md')) -cne $userScratchContent) {
        $aiErrs.Add('ai-shared-disjoint-creep modified pre-existing user_dirty docs/scratch.md')
    }
    Remove-Item -LiteralPath (Join-Path $aiRepo 'coverage') -Recurse -Force -ErrorAction SilentlyContinue

    & git -C $aiRepo add api/a.ts src/c.ts | Out-Null
    & $checkAiParity 'ai-precommit-undeclared-staged' `
        @('precommit', '-RepoRoot', $aiRepo, '-AllowedPaths', 'api/a.ts') `
        @('precommit', '--repo-root', $aiRepoPosix, '--allowed-paths', 'api/a.ts') `
        1 @('PRECOMMIT_FAIL: undeclared staged path \(src/c\.ts\)')

    $aiMergeHead = Join-Path $aiRepo '.git\MERGE_HEAD'
    [IO.File]::WriteAllText($aiMergeHead, "$aiHead`n", $utf8NoBomAi)
    & $checkAiParity 'ai-precommit-merge-head' `
        @('precommit', '-RepoRoot', $aiRepo, '-AllowedPaths', 'api/a.ts') `
        @('precommit', '--repo-root', $aiRepoPosix, '--allowed-paths', 'api/a.ts') `
        1 @('PRECOMMIT_FAIL: git operation in progress \(MERGE_HEAD\)') -RequireExactTextParity
    & $checkAiParity 'ai-check-wave-merge-head' `
        @('check-wave', '-RepoRoot', $aiRepo, '-Partition', '-CheckDirtyScope', '-WaveSpecs', 'T001=api/a.ts;T002=ui/b.tsx', '-ExpectedBaseSha', $aiHead) `
        @('check-wave', '--repo-root', $aiRepoPosix, '--partition', '--check-dirty-scope', '--wave-specs', 'T001=api/a.ts;T002=ui/b.tsx', '--expected-base-sha', $aiHead) `
        2 @('WAVE_BASE_MISMATCH: git_op_in_progress\(MERGE_HEAD\)') -RequireExactTextParity
    Remove-Item -LiteralPath $aiMergeHead -Force
    & git -C $aiRepo reset -q HEAD -- api/a.ts src/c.ts | Out-Null
    & git -C $aiRepo checkout -- api/a.ts ui/b.tsx src/c.ts docs/scratch.md | Out-Null

    # 1b. Dirty scope classification: USER_DIRTY partial isolate (modified, staged, untracked) + all-blocked vs UNEXPECTED_DIRTY fail-closed + IgnoreDirtyPaths '.'
    [IO.File]::WriteAllText((Join-Path $aiRepo 'api\a.ts'), "export const a = 3;`n", $utf8NoBomAi)
    & $checkAiParity 'ai-user-dirty-modified-partial' `
        @('check-wave', '-RepoRoot', $aiRepo, '-Partition', '-CheckDirtyScope', '-WaveSpecs', 'T001=api/a.ts;T002=ui/b.tsx;T003=src/c.ts', '-IgnoreDirtyPaths', 'api/a.ts', '-ExpectedBaseSha', $aiHead) `
        @('check-wave', '--repo-root', $aiRepoPosix, '--partition', '--check-dirty-scope', '--wave-specs', 'T001=api/a.ts;T002=ui/b.tsx;T003=src/c.ts', '--ignore-dirty-paths', 'api/a.ts', '--expected-base-sha', $aiHead) `
        0 @('(?m)^dirty_scope=user_only$', '(?m)^user_dirty=api/a\.ts$', '(?m)^unexpected_dirty=none$', '(?m)^blocked_tasks=T001$', '(?m)^conflicts=dirty:api/a\.ts\(USER_DIRTY->T001\)$', '(?m)^wave\|1\|PARALLEL\|agents=2\|tasks=T002,T003\|reason=independent_ready_tasks$', 'WAVE_PARTITIONED: waves=1 max_parallel=2 reason=dirty_scope_partial_split') -RequireExactTextParity
    & git -C $aiRepo add api/a.ts | Out-Null
    & $checkAiParity 'ai-user-dirty-staged-partial' `
        @('check-wave', '-RepoRoot', $aiRepo, '-Partition', '-CheckDirtyScope', '-WaveSpecs', 'T001=api/a.ts;T002=ui/b.tsx;T003=src/c.ts', '-IgnoreDirtyPaths', 'api/a.ts', '-ExpectedBaseSha', $aiHead) `
        @('check-wave', '--repo-root', $aiRepoPosix, '--partition', '--check-dirty-scope', '--wave-specs', 'T001=api/a.ts;T002=ui/b.tsx;T003=src/c.ts', '--ignore-dirty-paths', 'api/a.ts', '--expected-base-sha', $aiHead) `
        0 @('(?m)^dirty_scope=user_only$', '(?m)^blocked_tasks=T001$', '(?m)^wave\|1\|PARALLEL\|agents=2\|tasks=T002,T003\|reason=independent_ready_tasks$', 'WAVE_PARTITIONED: waves=1 max_parallel=2 reason=dirty_scope_partial_split') -RequireExactTextParity
    & git -C $aiRepo reset -q HEAD -- api/a.ts | Out-Null
    & git -C $aiRepo checkout -- api/a.ts | Out-Null

    $aiUntrackedUser = Join-Path $aiRepo 'api\new_user.ts'
    [IO.File]::WriteAllText($aiUntrackedUser, "export const nu = 1;`n", $utf8NoBomAi)
    & $checkAiParity 'ai-user-dirty-untracked-partial' `
        @('check-wave', '-RepoRoot', $aiRepo, '-Partition', '-CheckDirtyScope', '-WaveSpecs', 'T001=api/new_user.ts;T002=ui/b.tsx;T003=src/c.ts', '-IgnoreDirtyPaths', 'api/new_user.ts', '-ExpectedBaseSha', $aiHead) `
        @('check-wave', '--repo-root', $aiRepoPosix, '--partition', '--check-dirty-scope', '--wave-specs', 'T001=api/new_user.ts;T002=ui/b.tsx;T003=src/c.ts', '--ignore-dirty-paths', 'api/new_user.ts', '--expected-base-sha', $aiHead) `
        0 @('(?m)^dirty_scope=user_only$', '(?m)^user_dirty=api/new_user\.ts$', '(?m)^blocked_tasks=T001$', '(?m)^conflicts=dirty:api/new_user\.ts\(USER_DIRTY->T001\)$', '(?m)^wave\|1\|PARALLEL\|agents=2\|tasks=T002,T003\|reason=independent_ready_tasks$', 'WAVE_PARTITIONED: waves=1 max_parallel=2 reason=dirty_scope_partial_split') -RequireExactTextParity
    & $checkAiParity 'ai-user-dirty-all-blocked' `
        @('check-wave', '-RepoRoot', $aiRepo, '-Partition', '-CheckDirtyScope', '-WaveSpecs', 'T001=api/new_user.ts', '-IgnoreDirtyPaths', 'api/new_user.ts', '-ExpectedBaseSha', $aiHead) `
        @('check-wave', '--repo-root', $aiRepoPosix, '--partition', '--check-dirty-scope', '--wave-specs', 'T001=api/new_user.ts', '--ignore-dirty-paths', 'api/new_user.ts', '--expected-base-sha', $aiHead) `
        2 @('(?m)^dirty_scope=user_only$', '(?m)^blocked_tasks=T001$', '(?m)^wave_count=0$', '(?m)^max_parallel=0$', 'WAVE_SEQUENTIAL: waves=0 max_parallel=0 reason=dirty_scope_conflict') -RequireExactTextParity
    Remove-Item -LiteralPath $aiUntrackedUser -Force

    $aiUnexpectedUntracked = Join-Path $aiRepo 'src\unexpected_untracked.ts'
    [IO.File]::WriteAllText($aiUnexpectedUntracked, "export const uu = 1;`n", $utf8NoBomAi)
    & $checkAiParity 'ai-unexpected-dirty-untracked' `
        @('check-wave', '-RepoRoot', $aiRepo, '-Partition', '-CheckDirtyScope', '-WaveSpecs', 'T001=api/a.ts;T002=ui/b.tsx', '-ExpectedBaseSha', $aiHead) `
        @('check-wave', '--repo-root', $aiRepoPosix, '--partition', '--check-dirty-scope', '--wave-specs', 'T001=api/a.ts;T002=ui/b.tsx', '--expected-base-sha', $aiHead) `
        2 @('(?m)^dirty_scope=unexpected$', '(?m)^unexpected_dirty=src/unexpected_untracked\.ts$', 'WAVE_BASE_MISMATCH: unexpected_dirty\(src/unexpected_untracked\.ts\)') -RequireExactTextParity
    Remove-Item -LiteralPath $aiUnexpectedUntracked -Force

    [IO.File]::WriteAllText((Join-Path $aiRepo 'src\c.ts'), "export const c = 42;`n", $utf8NoBomAi)
    & git -C $aiRepo add src/c.ts | Out-Null
    & $checkAiParity 'ai-unexpected-dirty-staged' `
        @('check-wave', '-RepoRoot', $aiRepo, '-Partition', '-CheckDirtyScope', '-WaveSpecs', 'T001=api/a.ts;T002=ui/b.tsx', '-ExpectedBaseSha', $aiHead) `
        @('check-wave', '--repo-root', $aiRepoPosix, '--partition', '--check-dirty-scope', '--wave-specs', 'T001=api/a.ts;T002=ui/b.tsx', '--expected-base-sha', $aiHead) `
        2 @('(?m)^dirty_scope=unexpected$', '(?m)^unexpected_dirty=src/c\.ts$', 'WAVE_BASE_MISMATCH: unexpected_dirty\(src/c\.ts\)') -RequireExactTextParity
    & git -C $aiRepo reset -q HEAD -- src/c.ts | Out-Null
    & git -C $aiRepo checkout -- src/c.ts | Out-Null

    New-Item -ItemType Directory -Path (Join-Path $aiRepo '.b3') -Force | Out-Null
    $aiPolicyFile = Join-Path $aiRepo '.b3\research-policy.json'
    [IO.File]::WriteAllText($aiPolicyFile, "{}`n", $utf8NoBomAi)
    & $checkAiParity 'ai-unexpected-dirty-research-policy' `
        @('check-wave', '-RepoRoot', $aiRepo, '-Partition', '-CheckDirtyScope', '-WaveSpecs', 'T001=api/a.ts;T002=ui/b.tsx', '-ExpectedBaseSha', $aiHead) `
        @('check-wave', '--repo-root', $aiRepoPosix, '--partition', '--check-dirty-scope', '--wave-specs', 'T001=api/a.ts;T002=ui/b.tsx', '--expected-base-sha', $aiHead) `
        2 @('(?m)^dirty_scope=unexpected$', '(?m)^unexpected_dirty=\.b3/research-policy\.json$', 'WAVE_BASE_MISMATCH: unexpected_dirty\(\.b3/research-policy\.json\)') -RequireExactTextParity
    Remove-Item -LiteralPath (Join-Path $aiRepo '.b3') -Recurse -Force

    & $checkAiParity 'ai-ignore-dirty-dot-rejected' `
        @('check-wave', '-RepoRoot', $aiRepo, '-Partition', '-WaveSpecs', 'T001=api/a.ts', '-IgnoreDirtyPaths', '.') `
        @('check-wave', '--repo-root', $aiRepoPosix, '--partition', '--wave-specs', 'T001=api/a.ts', '--ignore-dirty-paths', '.') `
        1 @("WAVE_FAIL: invalid ignore-dirty path '\.'") -RequireExactTextParity

    # 1c. R004: '.' root rejection in -Partition vs legacy/WaveReads, -ProtectedPaths, .b3/research-policy.json/.gitmodules, and junction containment
    & $checkAiParity 'ai-legacy-nonpartition-dot-conflict' `
        @('check-wave', '-RepoRoot', $aiRepo, '-WaveSpecs', 'T001=.;T002=ui/b.tsx') `
        @('check-wave', '--repo-root', $aiRepoPosix, '--wave-specs', 'T001=.;T002=ui/b.tsx') `
        2 @('WAVE_CONFLICT: \.<->ui/b\.tsx\(T001,T002\)') -RequireExactTextParity
    & $checkAiParity 'ai-partition-dot-rejected' `
        @('check-wave', '-RepoRoot', $aiRepo, '-Partition', '-WaveSpecs', 'T001=.;T002=ui/b.tsx') `
        @('check-wave', '--repo-root', $aiRepoPosix, '--partition', '--wave-specs', 'T001=.;T002=ui/b.tsx') `
        1 @("WAVE_FAIL: protected path '\.' cannot be worker-owned in parallel partition") -RequireExactTextParity
    & $checkAiParity 'ai-wave-reads-dot-allowed' `
        @('check-wave', '-RepoRoot', $aiRepo, '-Partition', '-WaveSpecs', 'T001=api/a.ts', '-WaveReads', 'T001=.') `
        @('check-wave', '--repo-root', $aiRepoPosix, '--partition', '--wave-specs', 'T001=api/a.ts', '--wave-reads', 'T001=.') `
        0 @('(?m)^wave\|1\|SEQUENTIAL\|agents=1\|tasks=T001\|reason=single_ready_task$', 'WAVE_OK: disjoint \(1 tasks, 1 paths\)') -RequireExactTextParity

    foreach ($protSpec in @(
        @{ Name = 'exact-file'; Spec = 'T001=src/shared/types.ts'; Boundary = 'src/shared/types.ts' },
        @{ Name = 'child-file'; Spec = 'T001=docs/authority/pin.md'; Boundary = 'docs/authority' },
        @{ Name = 'ancestor-dir'; Spec = 'T001=docs'; Boundary = 'docs/authority' }
    )) {
        & $checkAiParity "ai-protected-paths-$($protSpec.Name)" `
            @('check-wave', '-RepoRoot', $aiRepo, '-Partition', '-WaveSpecs', $protSpec.Spec, '-ProtectedPaths', 'docs/authority,src/shared/types.ts') `
            @('check-wave', '--repo-root', $aiRepoPosix, '--partition', '--wave-specs', $protSpec.Spec, '--protected-paths', 'docs/authority,src/shared/types.ts') `
            1 @("overlaps single-writer boundary '$([regex]::Escape($protSpec.Boundary))'") -RequireExactTextParity
    }

    foreach ($pOwn in @('.b3/research-policy.json', '.gitmodules')) {
        & $checkAiParity "ai-protected-builtin-$pOwn" `
            @('check-wave', '-RepoRoot', $aiRepo, '-Partition', '-WaveSpecs', "T001=$pOwn;T002=ui/b.tsx") `
            @('check-wave', '--repo-root', $aiRepoPosix, '--partition', '--wave-specs', "T001=$pOwn;T002=ui/b.tsx") `
            1 @("WAVE_FAIL: protected path '$([regex]::Escape($pOwn))' cannot be worker-owned") -RequireExactTextParity
    }

    $aiChildJunc = Join-Path $aiRepo 'src\api\junc_child'
    $aiJuncRepo = Join-Path $sandbox 'junc_repo'
    $aiJuncRepoPosix = To-PosixPath $aiJuncRepo
    New-Item -ItemType Junction -Path $aiChildJunc -Target (Join-Path $aiRepo 'ui') | Out-Null
    New-Item -ItemType Junction -Path $aiJuncRepo -Target $aiRepo | Out-Null
    try {
        & $checkAiParity 'ai-junc-child-wavespecs' `
            @('check-wave', '-RepoRoot', $aiRepo, '-Partition', '-WaveSpecs', 'T001=src/api;T002=src/c.ts') `
            @('check-wave', '--repo-root', $aiRepoPosix, '--partition', '--wave-specs', 'T001=src/api;T002=src/c.ts') `
            1 @("WAVE_FAIL: unsafe symlink or junction alias in path 'src/api'") -RequireExactTextParity
        & $checkAiParity 'ai-junc-child-wavereads' `
            @('check-wave', '-RepoRoot', $aiRepo, '-Partition', '-WaveSpecs', 'T001=api/a.ts;T002=src/c.ts', '-WaveReads', 'T002=src/api') `
            @('check-wave', '--repo-root', $aiRepoPosix, '--partition', '--wave-specs', 'T001=api/a.ts;T002=src/c.ts', '--wave-reads', 'T002=src/api') `
            1 @("WAVE_FAIL: unsafe symlink or junction alias in path 'src/api'") -RequireExactTextParity
        & $checkAiParity 'ai-junc-child-protected' `
            @('check-wave', '-RepoRoot', $aiRepo, '-Partition', '-WaveSpecs', 'T001=api/a.ts', '-ProtectedPaths', 'src/api') `
            @('check-wave', '--repo-root', $aiRepoPosix, '--partition', '--wave-specs', 'T001=api/a.ts', '--protected-paths', 'src/api') `
            1 @("WAVE_FAIL: unsafe symlink or junction alias in path 'src/api'") -RequireExactTextParity
        & $checkAiParity 'ai-junc-child-ignoredirty' `
            @('check-wave', '-RepoRoot', $aiRepo, '-Partition', '-WaveSpecs', 'T001=api/a.ts', '-IgnoreDirtyPaths', 'src/api') `
            @('check-wave', '--repo-root', $aiRepoPosix, '--partition', '--wave-specs', 'T001=api/a.ts', '--ignore-dirty-paths', 'src/api') `
            1 @("WAVE_FAIL: unsafe symlink or junction alias in path 'src/api'") -RequireExactTextParity
        & $checkAiParity 'ai-junc-repo-root' `
            @('check-wave', '-RepoRoot', $aiJuncRepo, '-Partition', '-WaveSpecs', 'T001=api/a.ts') `
            @('check-wave', '--repo-root', $aiJuncRepoPosix, '--partition', '--wave-specs', 'T001=api/a.ts') `
            1 @("WAVE_FAIL: unsafe symlink or junction alias in path '\.'") -RequireExactTextParity
    } finally {
        if (Test-Path -LiteralPath $aiChildJunc) { [System.IO.Directory]::Delete($aiChildJunc, $false) }
        if (Test-Path -LiteralPath $aiJuncRepo) { [System.IO.Directory]::Delete($aiJuncRepo, $false) }
    }

    # 1d. R003: Singleton wave 1 -> parallel wave 2 + recompute after wave 1 commit
    & $checkAiParity 'ai-singleton-w1-parallel-w2' `
        @('check-wave', '-RepoRoot', $aiRepo, '-Partition', '-WaveSpecs', 'T1=src/x.ts,src/y.ts;T2=src/x.ts,src/z.ts;T3=src/y.ts', '-ExpectedBaseSha', $aiHead) `
        @('check-wave', '--repo-root', $aiRepoPosix, '--partition', '--wave-specs', 'T1=src/x.ts,src/y.ts;T2=src/x.ts,src/z.ts;T3=src/y.ts', '--expected-base-sha', $aiHead) `
        0 @('(?m)^wave_count=2$', '(?m)^max_parallel=2$', '(?m)^wave\|1\|SEQUENTIAL\|agents=1\|tasks=T1\|reason=shared_write_conflict$', '(?m)^wave\|2\|PARALLEL\|agents=2\|tasks=T2,T3\|reason=independent_ready_tasks$', 'WAVE_PARTITIONED: waves=2 max_parallel=2 reason=conflicting_wave_split') -RequireExactTextParity
    [IO.File]::WriteAllText((Join-Path $aiRepo 'src\x.ts'), "export const x = 2;`n", $utf8NoBomAi)
    & git -C $aiRepo add src/x.ts | Out-Null
    & git -C $aiRepo commit -qm 'T1 integrated' | Out-Null
    $aiAfterT1 = (& git -C $aiRepo rev-parse HEAD).Trim()
    & $checkAiParity 'ai-recompute-after-w1' `
        @('check-wave', '-RepoRoot', $aiRepo, '-Partition', '-WaveSpecs', 'T2=src/x.ts,src/z.ts;T3=src/y.ts', '-ExpectedBaseSha', $aiAfterT1) `
        @('check-wave', '--repo-root', $aiRepoPosix, '--partition', '--wave-specs', 'T2=src/x.ts,src/z.ts;T3=src/y.ts', '--expected-base-sha', $aiAfterT1) `
        0 @('(?m)^wave_count=1$', '(?m)^max_parallel=2$', '(?m)^wave\|1\|PARALLEL\|agents=2\|tasks=T2,T3\|reason=independent_ready_tasks$', 'WAVE_OK: disjoint \(2 tasks, 3 paths\)') -RequireExactTextParity

    # 1d2. F04: Pure read-only parallel waves (TaskId=none / []) & blank write scope rejection
    & $checkAiParity 'ai-f04-pure-readonly-parallel' `
        @('check-wave', '-RepoRoot', $aiRepo, '-Partition', '-WaveSpecs', 'U1=none;U2=[]', '-WaveReads', 'U1=src/shared/types.ts,api/a.ts;U2=src/shared/types.ts,README.md', '-ExpectedBaseSha', $aiAfterT1) `
        @('check-wave', '--repo-root', $aiRepoPosix, '--partition', '--wave-specs', 'U1=none;U2=[]', '--wave-reads', 'U1=src/shared/types.ts,api/a.ts;U2=src/shared/types.ts,README.md', '--expected-base-sha', $aiAfterT1) `
        0 @('(?m)^wave_count=1$', '(?m)^max_parallel=2$', '(?m)^conflicts=none$', '(?m)^wave\|1\|PARALLEL\|agents=2\|tasks=U1,U2\|reason=independent_ready_tasks$', 'WAVE_OK: disjoint \(2 tasks, 0 paths\)') -RequireExactTextParity
    & $checkAiParity 'ai-f04-blank-write-scope-rejected' `
        @('check-wave', '-RepoRoot', $aiRepo, '-Partition', '-WaveSpecs', 'U1=') `
        @('check-wave', '--repo-root', $aiRepoPosix, '--partition', '--wave-specs', 'U1=') `
        1 @("WAVE_FAIL: task 'U1' has no owned paths") -RequireExactTextParity
    & $checkAiParity 'ai-f04-mixed-rw-partition' `
        @('check-wave', '-RepoRoot', $aiRepo, '-Partition', '-WaveSpecs', 'W1=api/a.ts;R1=none;W2=ui/b.tsx', '-WaveReads', 'R1=api/a.ts;W2=README.md', '-ExpectedBaseSha', $aiAfterT1) `
        @('check-wave', '--repo-root', $aiRepoPosix, '--partition', '--wave-specs', 'W1=api/a.ts;R1=none;W2=ui/b.tsx', '--wave-reads', 'R1=api/a.ts;W2=README.md', '--expected-base-sha', $aiAfterT1) `
        0 @('(?m)^conflicts=rw:api/a\.ts\(W1->R1\)$', '(?m)^wave\|1\|PARALLEL\|agents=2\|tasks=W1,W2\|reason=independent_ready_tasks$', '(?m)^wave\|2\|SEQUENTIAL\|agents=1\|tasks=R1\|reason=shared_write_conflict$', 'WAVE_PARTITIONED: waves=2 max_parallel=2 reason=conflicting_wave_split') -RequireExactTextParity
    & $checkAiParity 'ai-f04-mixed-rw-sequential' `
        @('check-wave', '-RepoRoot', $aiRepo, '-Partition', '-WaveSpecs', 'W1=api/a.ts;R1=none', '-WaveReads', 'R1=api/a.ts', '-ExpectedBaseSha', $aiAfterT1) `
        @('check-wave', '--repo-root', $aiRepoPosix, '--partition', '--wave-specs', 'W1=api/a.ts;R1=none', '--wave-reads', 'R1=api/a.ts', '--expected-base-sha', $aiAfterT1) `
        2 @('(?m)^conflicts=rw:api/a\.ts\(W1->R1\)$', 'WAVE_SEQUENTIAL: waves=2 max_parallel=1 reason=shared_write_conflict') -RequireExactTextParity
    [IO.File]::WriteAllText((Join-Path $aiRepo 'api\a.ts'), "export const a = 10;`n", $utf8NoBomAi)
    & $checkAiParity 'ai-f04-readonly-dirty-scope' `
        @('check-wave', '-RepoRoot', $aiRepo, '-Partition', '-CheckDirtyScope', '-WaveSpecs', 'R1=none;R2=none', '-WaveReads', 'R1=api/a.ts;R2=ui/b.tsx', '-IgnoreDirtyPaths', 'api/a.ts', '-ExpectedBaseSha', $aiAfterT1) `
        @('check-wave', '--repo-root', $aiRepoPosix, '--partition', '--check-dirty-scope', '--wave-specs', 'R1=none;R2=none', '--wave-reads', 'R1=api/a.ts;R2=ui/b.tsx', '--ignore-dirty-paths', 'api/a.ts', '--expected-base-sha', $aiAfterT1) `
        0 @('(?m)^dirty_scope=user_only$', '(?m)^blocked_tasks=R1$', '(?m)^conflicts=dirty:api/a\.ts\(USER_DIRTY->R1\)$', '(?m)^wave\|1\|SEQUENTIAL\|agents=1\|tasks=R2\|reason=single_ready_task$', 'WAVE_SEQUENTIAL: waves=1 max_parallel=1 reason=dirty_scope_partial_split') -RequireExactTextParity
    & git -C $aiRepo checkout -- api/a.ts | Out-Null

    # 1d3. F01: Per-worker ownership vs combined wave diff (mechanical-check -WaveSpecs / -WorkerChanges / -WorkerRoots / -ProtectedPaths / -DirtyDigests)
    $aiBaseSha = (& git -C $aiRepo rev-parse HEAD).Trim()
    [IO.File]::WriteAllText((Join-Path $aiRepo 'docs\scratch.md'), $userScratchContent, $utf8NoBomAi)
    [IO.File]::WriteAllText((Join-Path $aiRepo 'api\a.ts'), "export const a = 20;`n", $utf8NoBomAi)
    [IO.File]::WriteAllText((Join-Path $aiRepo 'ui\b.tsx'), "export const B = () => 'w2';`n", $utf8NoBomAi)
    & $checkAiParity 'ai-mech-combined-unverified' `
        @('mechanical-check', '-RepoRoot', $aiRepo, '-AllowedPaths', 'api/a.ts,ui/b.tsx', '-IgnoreDirtyPaths', 'docs/scratch.md', '-WaveSpecs', 'T1=api/a.ts;T2=ui/b.tsx') `
        @('mechanical-check', '--repo-root', $aiRepoPosix, '--allowed-paths', 'api/a.ts,ui/b.tsx', '--ignore-dirty-paths', 'docs/scratch.md', '--wave-specs', 'T1=api/a.ts;T2=ui/b.tsx') `
        0 @('(?m)^scope_creep=none$', '(?m)^ownership_verification=UNVERIFIED_COMBINED_ONLY$', '(?m)^ownership_violations=unverified$', '(?m)^MECHANICAL_OK$') -RequireExactTextParity
    & $checkAiParity 'ai-mech-cross-worker-swap' `
        @('mechanical-check', '-RepoRoot', $aiRepo, '-BaseSha', $aiBaseSha, '-AllowedPaths', 'api/a.ts,ui/b.tsx', '-IgnoreDirtyPaths', 'docs/scratch.md', '-WaveSpecs', 'T1=api/a.ts;T2=ui/b.tsx', '-WorkerChanges', 'T1=ui/b.tsx;T2=api/a.ts') `
        @('mechanical-check', '--repo-root', $aiRepoPosix, '--base-sha', $aiBaseSha, '--allowed-paths', 'api/a.ts,ui/b.tsx', '--ignore-dirty-paths', 'docs/scratch.md', '--wave-specs', 'T1=api/a.ts;T2=ui/b.tsx', '--worker-changes', 'T1=ui/b.tsx;T2=api/a.ts') `
        2 @('(?m)^scope_creep=none$', '(?m)^ownership_verification=VIOLATION$', '(?m)^ownership_violations=api/a\.ts\(T2->T1\),ui/b\.tsx\(T1->T2\)$', '(?m)^MECHANICAL_FINDINGS$') -RequireExactTextParity
    & $checkAiParity 'ai-mech-per-worker-ok' `
        @('mechanical-check', '-RepoRoot', $aiRepo, '-BaseSha', $aiBaseSha, '-AllowedPaths', 'api/a.ts,ui/b.tsx', '-IgnoreDirtyPaths', 'docs/scratch.md', '-WaveSpecs', 'T1=api/a.ts;T2=ui/b.tsx;T3=none', '-WorkerChanges', 'T1=api/a.ts;T2=ui/b.tsx;T3=none') `
        @('mechanical-check', '--repo-root', $aiRepoPosix, '--base-sha', $aiBaseSha, '--allowed-paths', 'api/a.ts,ui/b.tsx', '--ignore-dirty-paths', 'docs/scratch.md', '--wave-specs', 'T1=api/a.ts;T2=ui/b.tsx;T3=none', '--worker-changes', 'T1=api/a.ts;T2=ui/b.tsx;T3=none') `
        0 @('(?m)^scope_creep=none$', '(?m)^ownership_verification=CALLER_ATTRIBUTED$', '(?m)^ownership_violations=none$', '(?m)^MECHANICAL_OK$') -RequireExactTextParity
    & $checkAiParity 'ai-mech-user-dirty-touch' `
        @('mechanical-check', '-RepoRoot', $aiRepo, '-BaseSha', $aiBaseSha, '-AllowedPaths', 'api/a.ts,ui/b.tsx', '-IgnoreDirtyPaths', 'docs/scratch.md', '-WaveSpecs', 'T1=api/a.ts;T2=ui/b.tsx', '-WorkerChanges', 'T1=api/a.ts,docs/scratch.md;T2=ui/b.tsx') `
        @('mechanical-check', '--repo-root', $aiRepoPosix, '--base-sha', $aiBaseSha, '--allowed-paths', 'api/a.ts,ui/b.tsx', '--ignore-dirty-paths', 'docs/scratch.md', '--wave-specs', 'T1=api/a.ts;T2=ui/b.tsx', '--worker-changes', 'T1=api/a.ts,docs/scratch.md;T2=ui/b.tsx') `
        2 @('(?m)^ownership_verification=VIOLATION$', '(?m)^ownership_violations=docs/scratch\.md\(T1->user_dirty\)$', '(?m)^MECHANICAL_FINDINGS$') -RequireExactTextParity
    & $checkAiParity 'ai-mech-unowned-claim' `
        @('mechanical-check', '-RepoRoot', $aiRepo, '-BaseSha', $aiBaseSha, '-AllowedPaths', 'api/a.ts,ui/b.tsx', '-IgnoreDirtyPaths', 'docs/scratch.md', '-WaveSpecs', 'T1=api/a.ts;T2=ui/b.tsx', '-WorkerChanges', 'T1=api/a.ts,src/c.ts;T2=ui/b.tsx') `
        @('mechanical-check', '--repo-root', $aiRepoPosix, '--base-sha', $aiBaseSha, '--allowed-paths', 'api/a.ts,ui/b.tsx', '--ignore-dirty-paths', 'docs/scratch.md', '--wave-specs', 'T1=api/a.ts;T2=ui/b.tsx', '--worker-changes', 'T1=api/a.ts,src/c.ts;T2=ui/b.tsx') `
        2 @('(?m)^ownership_verification=VIOLATION$', '(?m)^ownership_violations=src/c\.ts\(T1->unowned\)$', '(?m)^MECHANICAL_FINDINGS$') -RequireExactTextParity
    & $checkAiParity 'ai-mech-unknown-task-id' `
        @('mechanical-check', '-RepoRoot', $aiRepo, '-BaseSha', $aiBaseSha, '-WaveSpecs', 'T1=api/a.ts;T2=ui/b.tsx', '-WorkerChanges', 'T9=api/a.ts') `
        @('mechanical-check', '--repo-root', $aiRepoPosix, '--base-sha', $aiBaseSha, '--wave-specs', 'T1=api/a.ts;T2=ui/b.tsx', '--worker-changes', 'T9=api/a.ts') `
        1 @("MECHANICAL_FAIL: unknown task id 'T9' in WorkerChanges") -RequireExactTextParity
    [IO.File]::WriteAllText((Join-Path $aiRepo 'src\c.ts'), "export const c = 77;`n", $utf8NoBomAi)
    & $checkAiParity 'ai-mech-unattributed-change' `
        @('mechanical-check', '-RepoRoot', $aiRepo, '-BaseSha', $aiBaseSha, '-AllowedPaths', 'api/a.ts,ui/b.tsx,src/c.ts', '-IgnoreDirtyPaths', 'docs/scratch.md', '-WaveSpecs', 'T1=api/a.ts;T2=ui/b.tsx', '-WorkerChanges', 'T1=api/a.ts;T2=ui/b.tsx') `
        @('mechanical-check', '--repo-root', $aiRepoPosix, '--base-sha', $aiBaseSha, '--allowed-paths', 'api/a.ts,ui/b.tsx,src/c.ts', '--ignore-dirty-paths', 'docs/scratch.md', '--wave-specs', 'T1=api/a.ts;T2=ui/b.tsx', '--worker-changes', 'T1=api/a.ts;T2=ui/b.tsx') `
        2 @('(?m)^scope_creep=none$', '(?m)^ownership_verification=VIOLATION$', '(?m)^ownership_violations=src/c\.ts\(unattributed\)$', '(?m)^MECHANICAL_FINDINGS$') -RequireExactTextParity
    & git -C $aiRepo checkout -- src/c.ts ui/b.tsx | Out-Null

    # PARTIAL_ATTRIBUTION (exit 2): omitting T2 from -WorkerChanges when T1=api/a.ts;T2=ui/b.tsx
    & $checkAiParity 'ai-mech-partial-attribution' `
        @('mechanical-check', '-RepoRoot', $aiRepo, '-BaseSha', $aiBaseSha, '-AllowedPaths', 'api/a.ts,ui/b.tsx', '-IgnoreDirtyPaths', 'docs/scratch.md', '-WaveSpecs', 'T1=api/a.ts;T2=ui/b.tsx', '-WorkerChanges', 'T1=api/a.ts') `
        @('mechanical-check', '--repo-root', $aiRepoPosix, '--base-sha', $aiBaseSha, '--allowed-paths', 'api/a.ts,ui/b.tsx', '--ignore-dirty-paths', 'docs/scratch.md', '--wave-specs', 'T1=api/a.ts;T2=ui/b.tsx', '--worker-changes', 'T1=api/a.ts') `
        2 @('(?m)^scope_creep=none$', '(?m)^ownership_verification=PARTIAL_ATTRIBUTION$', '(?m)^ownership_violations=T2\(missing_worker\)$', '(?m)^MECHANICAL_FINDINGS$') -RequireExactTextParity

    # VERIFIED_PER_WORKER via -WorkerRoots (two real linked worktrees integrated into target repo + content_mismatch VIOLATION)
    $aiWtDir = Join-Path $sandbox 'ai-worker-roots'
    $aiWt1 = Join-Path $aiWtDir 'wt1'
    $aiWt2 = Join-Path $aiWtDir 'wt2'
    $aiWt1Posix = To-PosixPath $aiWt1
    $aiWt2Posix = To-PosixPath $aiWt2
    New-Item -ItemType Directory -Path $aiWtDir -Force | Out-Null
    & git -C $aiRepo worktree add -q -b ai-wr-b1 $aiWt1 $aiBaseSha 2>$null
    & git -C $aiRepo worktree add -q -b ai-wr-b2 $aiWt2 $aiBaseSha 2>$null
    try {
        [IO.File]::WriteAllText((Join-Path $aiWt1 'api\a.ts'), "export const a = 20;`n", $utf8NoBomAi)
        [IO.File]::WriteAllText((Join-Path $aiWt2 'ui\b.tsx'), "export const B = () => 'w2';`n", $utf8NoBomAi)
        [IO.File]::WriteAllText((Join-Path $aiRepo 'ui\b.tsx'), "export const B = () => 'w2';`n", $utf8NoBomAi)
        & $checkAiParity 'ai-mech-worker-roots-verified' `
            @('mechanical-check', '-RepoRoot', $aiRepo, '-BaseSha', $aiBaseSha, '-AllowedPaths', 'api/a.ts,ui/b.tsx', '-IgnoreDirtyPaths', 'docs/scratch.md', '-WaveSpecs', 'T1=api/a.ts;T2=ui/b.tsx', '-WorkerRoots', "T1=$aiWt1;T2=$aiWt2") `
            @('mechanical-check', '--repo-root', $aiRepoPosix, '--base-sha', $aiBaseSha, '--allowed-paths', 'api/a.ts,ui/b.tsx', '--ignore-dirty-paths', 'docs/scratch.md', '--wave-specs', 'T1=api/a.ts;T2=ui/b.tsx', '--worker-roots', "T1=$aiWt1Posix;T2=$aiWt2Posix") `
            0 @('(?m)^scope_creep=none$', '(?m)^ownership_verification=VERIFIED_PER_WORKER$', '(?m)^ownership_violations=none$', '(?m)^MECHANICAL_OK$') -RequireExactTextParity
        [IO.File]::WriteAllText((Join-Path $aiWt1 'api\a.ts'), "export const a = 999;`n", $utf8NoBomAi)
        & $checkAiParity 'ai-mech-worker-roots-mismatch' `
            @('mechanical-check', '-RepoRoot', $aiRepo, '-BaseSha', $aiBaseSha, '-AllowedPaths', 'api/a.ts,ui/b.tsx', '-IgnoreDirtyPaths', 'docs/scratch.md', '-WaveSpecs', 'T1=api/a.ts;T2=ui/b.tsx', '-WorkerRoots', "T1=$aiWt1;T2=$aiWt2") `
            @('mechanical-check', '--repo-root', $aiRepoPosix, '--base-sha', $aiBaseSha, '--allowed-paths', 'api/a.ts,ui/b.tsx', '--ignore-dirty-paths', 'docs/scratch.md', '--wave-specs', 'T1=api/a.ts;T2=ui/b.tsx', '--worker-roots', "T1=$aiWt1Posix;T2=$aiWt2Posix") `
            2 @('(?m)^ownership_verification=VIOLATION$', '(?m)^ownership_violations=api/a\.ts\(T1->content_mismatch\)$', '(?m)^MECHANICAL_FINDINGS$') -RequireExactTextParity
    } finally {
        & git -C $aiRepo worktree remove -f $aiWt1 2>$null | Out-Null
        & git -C $aiRepo worktree remove -f $aiWt2 2>$null | Out-Null
    }

    # CF-03: -ProtectedPaths violation & -DirtyDigests tamper (clean pass vs working-tree tamper vs git add staged tamper)
    [IO.File]::WriteAllText((Join-Path $aiRepo 'config\lock.json'), "{`"v`":2}`n", $utf8NoBomAi)
    & $checkAiParity 'ai-mech-protected-paths-violation' `
        @('mechanical-check', '-RepoRoot', $aiRepo, '-BaseSha', $aiBaseSha, '-AllowedPaths', 'api/a.ts,ui/b.tsx,config/lock.json', '-IgnoreDirtyPaths', 'docs/scratch.md', '-ProtectedPaths', '.b3/ship,config/lock.json') `
        @('mechanical-check', '--repo-root', $aiRepoPosix, '--base-sha', $aiBaseSha, '--allowed-paths', 'api/a.ts,ui/b.tsx,config/lock.json', '--ignore-dirty-paths', 'docs/scratch.md', '--protected-paths', '.b3/ship,config/lock.json') `
        2 @('(?m)^protected_violations=config/lock\.json$', '(?m)^MECHANICAL_FINDINGS$') -RequireExactTextParity
    & git -C $aiRepo checkout -- config/lock.json | Out-Null

    $origScratchSha = (Get-FileHash -LiteralPath (Join-Path $aiRepo 'docs\scratch.md') -Algorithm SHA256).Hash.ToLowerInvariant()
    & $checkAiParity 'ai-mech-dirty-digests-untouched-ok' `
        @('mechanical-check', '-RepoRoot', $aiRepo, '-BaseSha', $aiBaseSha, '-AllowedPaths', 'api/a.ts,ui/b.tsx', '-IgnoreDirtyPaths', 'docs/scratch.md', '-DirtyDigests', "docs/scratch.md=$origScratchSha", '-WaveSpecs', 'T1=api/a.ts;T2=ui/b.tsx', '-WorkerChanges', 'T1=api/a.ts;T2=ui/b.tsx') `
        @('mechanical-check', '--repo-root', $aiRepoPosix, '--base-sha', $aiBaseSha, '--allowed-paths', 'api/a.ts,ui/b.tsx', '--ignore-dirty-paths', 'docs/scratch.md', '--dirty-digests', "docs/scratch.md=$origScratchSha", '--wave-specs', 'T1=api/a.ts;T2=ui/b.tsx', '--worker-changes', 'T1=api/a.ts;T2=ui/b.tsx') `
        0 @('(?m)^dirty_tamper=none$', '(?m)^ownership_verification=CALLER_ATTRIBUTED$', '(?m)^ownership_violations=none$', '(?m)^MECHANICAL_OK$') -RequireExactTextParity
    [IO.File]::WriteAllText((Join-Path $aiRepo 'docs\scratch.md'), "# tampered-wt`n", $utf8NoBomAi)
    & $checkAiParity 'ai-mech-dirty-digests-wt-tamper' `
        @('mechanical-check', '-RepoRoot', $aiRepo, '-BaseSha', $aiBaseSha, '-AllowedPaths', 'api/a.ts,ui/b.tsx', '-IgnoreDirtyPaths', 'docs/scratch.md', '-DirtyDigests', "docs/scratch.md=$origScratchSha", '-WaveSpecs', 'T1=api/a.ts;T2=ui/b.tsx', '-WorkerChanges', 'T1=api/a.ts;T2=ui/b.tsx') `
        @('mechanical-check', '--repo-root', $aiRepoPosix, '--base-sha', $aiBaseSha, '--allowed-paths', 'api/a.ts,ui/b.tsx', '--ignore-dirty-paths', 'docs/scratch.md', '--dirty-digests', "docs/scratch.md=$origScratchSha", '--wave-specs', 'T1=api/a.ts;T2=ui/b.tsx', '--worker-changes', 'T1=api/a.ts;T2=ui/b.tsx') `
        2 @('(?m)^dirty_tamper=docs/scratch\.md$', '(?m)^ownership_verification=VIOLATION$', '(?m)^ownership_violations=docs/scratch\.md\(dirty_tamper\)$', '(?m)^MECHANICAL_FINDINGS$') -RequireExactTextParity
    & git -C $aiRepo add docs/scratch.md | Out-Null
    & $checkAiParity 'ai-mech-dirty-digests-staged-tamper' `
        @('mechanical-check', '-RepoRoot', $aiRepo, '-BaseSha', $aiBaseSha, '-AllowedPaths', 'api/a.ts,ui/b.tsx', '-IgnoreDirtyPaths', 'docs/scratch.md', '-DirtyDigests', "docs/scratch.md=$origScratchSha", '-WaveSpecs', 'T1=api/a.ts;T2=ui/b.tsx', '-WorkerChanges', 'T1=api/a.ts;T2=ui/b.tsx') `
        @('mechanical-check', '--repo-root', $aiRepoPosix, '--base-sha', $aiBaseSha, '--allowed-paths', 'api/a.ts,ui/b.tsx', '--ignore-dirty-paths', 'docs/scratch.md', '--dirty-digests', "docs/scratch.md=$origScratchSha", '--wave-specs', 'T1=api/a.ts;T2=ui/b.tsx', '--worker-changes', 'T1=api/a.ts;T2=ui/b.tsx') `
        2 @('(?m)^dirty_tamper=docs/scratch\.md$', '(?m)^ownership_verification=VIOLATION$', '(?m)^ownership_violations=docs/scratch\.md\(dirty_tamper\)$', '(?m)^MECHANICAL_FINDINGS$') -RequireExactTextParity
    & git -C $aiRepo reset -q HEAD -- docs/scratch.md | Out-Null
    & git -C $aiRepo checkout -- api/a.ts ui/b.tsx docs/scratch.md | Out-Null

    # 1e. R001: check-worktree identity & -PeerRoots (ISOLATED_WRITES)
    $wt2Parent = Join-Path $sandbox 'wt2-parent'
    $wt2Main = Join-Path $sandbox 'wt2-main'
    $wt2One = Join-Path $wt2Parent 'wt1'
    $wt2Two = Join-Path $wt2Parent 'wt2'
    $wt2Other = Join-Path $sandbox 'wt2-other'
    $wt2Junc = Join-Path $sandbox 'junc_wt'
    $wt2OuterJunc = Join-Path $sandbox 'outer_junc'
    $wt2MainPosix = To-PosixPath $wt2Main
    $wt2OnePosix = To-PosixPath $wt2One
    $wt2TwoPosix = To-PosixPath $wt2Two
    $wt2OtherPosix = To-PosixPath $wt2Other
    $wt2JuncPosix = To-PosixPath $wt2Junc
    $wt2OuterJuncPosix = To-PosixPath $wt2OuterJunc

    New-Item -ItemType Directory -Path $wt2Parent | Out-Null
    Init-B3TestRepo -RepoPath $wt2Main -InitialCommit -InitialFileName 'README.md' -InitialFileContent 'wt2-main'
    $wt2Head = (& git -C $wt2Main rev-parse HEAD).Trim()
    & git -C $wt2Main worktree add -q -b wt2-b1 $wt2One $wt2Head 2>$null
    & git -C $wt2Main worktree add -q -b wt2-b2 $wt2Two $wt2Head 2>$null
    $wt2Nested = Join-Path $wt2Main 'sub\wt-nested'
    $wt2NestedPosix = To-PosixPath $wt2Nested
    & git -C $wt2Main worktree add -q -b wt2-nested $wt2Nested $wt2Head 2>$null
    Init-B3TestRepo -RepoPath $wt2Other -InitialCommit -InitialFileName 'other.txt' -InitialFileContent 'other'
    New-Item -ItemType Junction -Path $wt2Junc -Target $wt2One | Out-Null
    New-Item -ItemType Junction -Path $wt2OuterJunc -Target $wt2Parent | Out-Null
    try {
        & $checkAiParity 'ai-wt-linked-peer-ok' `
            @('check-worktree', '-RepoRoot', $wt2One, '-ExpectedRoot', $wt2Main, '-ExpectedBaseSha', $wt2Head, '-PeerRoots', $wt2Two) `
            @('check-worktree', '--repo-root', $wt2OnePosix, '--expected-root', $wt2MainPosix, '--expected-base-sha', $wt2Head, '--peer-roots', $wt2TwoPosix) `
            0 @("WORKTREE_OK: root=.* head=$wt2Head common_dir=.* linked=true isolated=true")
        & $checkAiParity 'ai-wt-isolated-ok' `
            @('check-worktree', '-RepoRoot', $wt2One, '-ExpectedRoot', $wt2Main, '-ExpectedBaseSha', $wt2Head, '-PeerRoots', $wt2Two, '-RequireIsolated') `
            @('check-worktree', '--repo-root', $wt2OnePosix, '--expected-root', $wt2MainPosix, '--expected-base-sha', $wt2Head, '--peer-roots', $wt2TwoPosix, '--require-isolated') `
            0 @("WORKTREE_OK: root=.* head=$wt2Head common_dir=.* linked=true isolated=true")
        & $checkAiParity 'ai-wt-non-isolation-ok' `
            @('check-worktree', '-RepoRoot', $wt2Main, '-ExpectedRoot', $wt2Main, '-ExpectedBaseSha', $wt2Head) `
            @('check-worktree', '--repo-root', $wt2MainPosix, '--expected-root', $wt2MainPosix, '--expected-base-sha', $wt2Head) `
            0 @("WORKTREE_OK: root=.* head=$wt2Head common_dir=.* linked=false isolated=false")
        & $checkAiParity 'ai-wt-parent-reused-require-iso' `
            @('check-worktree', '-RepoRoot', $wt2Main, '-ExpectedRoot', $wt2Main, '-RequireIsolated') `
            @('check-worktree', '--repo-root', $wt2MainPosix, '--expected-root', $wt2MainPosix, '--require-isolated') `
            2 @('WORKTREE_UNSAFE: parent_root_reused_or_nested')
        & $checkAiParity 'ai-wt-parent-reused-peer' `
            @('check-worktree', '-RepoRoot', $wt2Main, '-ExpectedRoot', $wt2Main, '-PeerRoots', $wt2One) `
            @('check-worktree', '--repo-root', $wt2MainPosix, '--expected-root', $wt2MainPosix, '--peer-roots', $wt2OnePosix) `
            2 @('WORKTREE_UNSAFE: parent_root_reused_or_nested')
        & $checkAiParity 'ai-wt-peer-reuses-parent' `
            @('check-worktree', '-RepoRoot', $wt2One, '-ExpectedRoot', $wt2Main, '-PeerRoots', "$wt2Main,$wt2Two") `
            @('check-worktree', '--repo-root', $wt2OnePosix, '--expected-root', $wt2MainPosix, '--peer-roots', "$wt2MainPosix,$wt2TwoPosix") `
            2 @('WORKTREE_UNSAFE: parent_root_reused_or_nested')
        & $checkAiParity 'ai-wt-nested-worker-rejected' `
            @('check-worktree', '-RepoRoot', $wt2Nested, '-ExpectedRoot', $wt2Main, '-RequireIsolated') `
            @('check-worktree', '--repo-root', $wt2NestedPosix, '--expected-root', $wt2MainPosix, '--require-isolated') `
            2 @('WORKTREE_UNSAFE: parent_root_reused_or_nested')
        & $checkAiParity 'ai-wt-missing-expected-root-iso' `
            @('check-worktree', '-RepoRoot', $wt2One, '-RequireIsolated') `
            @('check-worktree', '--repo-root', $wt2OnePosix, '--require-isolated') `
            2 @('WORKTREE_UNSAFE: missing_expected_root_for_isolation')
        & $checkAiParity 'ai-wt-dup-peer' `
            @('check-worktree', '-RepoRoot', $wt2One, '-PeerRoots', $wt2One) `
            @('check-worktree', '--repo-root', $wt2OnePosix, '--peer-roots', $wt2OnePosix) `
            2 @('WORKTREE_UNSAFE: duplicate_or_nested_worktree')
        & $checkAiParity 'ai-wt-peer-other-repo' `
            @('check-worktree', '-RepoRoot', $wt2One, '-PeerRoots', $wt2Other) `
            @('check-worktree', '--repo-root', $wt2OnePosix, '--peer-roots', $wt2OtherPosix) `
            2 @('WORKTREE_UNSAFE: peer_repo_mismatch')
        $wt2MissingPeer = Join-Path $sandbox 'missing-peer'
        & $checkAiParity 'ai-wt-missing-peer' `
            @('check-worktree', '-RepoRoot', $wt2One, '-PeerRoots', $wt2MissingPeer) `
            @('check-worktree', '--repo-root', $wt2OnePosix, '--peer-roots', (To-PosixPath $wt2MissingPeer)) `
            2 @('WORKTREE_UNSAFE: missing_peer_root')

        # Junction '.' inside Push-Location, trailing '/.' & '\', and outer_junc/wt1
        $prevProcCd = [Environment]::CurrentDirectory
        Push-Location $wt2Junc
        try {
            [Environment]::CurrentDirectory = $wt2Junc
            $psDotJunc = Invoke-PsGuard @('check-worktree', '-RepoRoot', '.')
            if ($psDotJunc.Code -ne 2 -or ($psDotJunc.Text -notmatch 'WORKTREE_UNSAFE: unsafe_reparse_root')) {
                $aiErrs.Add("ai-wt-dot-junc PS exit=$($psDotJunc.Code) out=$($psDotJunc.Text)")
            }
            if ($script:HasBash) {
                $guardShPosix = To-PosixPath (Join-Path $root 'scripts\b3-guard.sh')
                $shDotJunc = Invoke-ShCmd "cd '$wt2JuncPosix' && '$guardShPosix' check-worktree --repo-root '.'"
                if ($shDotJunc.Code -ne 2 -or ($shDotJunc.Text -notmatch 'WORKTREE_UNSAFE: unsafe_reparse_root')) {
                    $aiErrs.Add("ai-wt-dot-junc SH exit=$($shDotJunc.Code) out=$($shDotJunc.Text)")
                }
            }
        } finally {
            [Environment]::CurrentDirectory = $prevProcCd
            Pop-Location
        }
        & $checkAiParity 'ai-wt-trailing-dot-slash' `
            @('check-worktree', '-RepoRoot', "$wt2Junc/.") `
            @('check-worktree', '--repo-root', "$wt2JuncPosix/.") `
            2 @('WORKTREE_UNSAFE: unsafe_reparse_root')
        & $checkAiParity 'ai-wt-trailing-slash' `
            @('check-worktree', '-RepoRoot', "$wt2Junc\") `
            @('check-worktree', '--repo-root', "$wt2JuncPosix/") `
            2 @('WORKTREE_UNSAFE: unsafe_reparse_root')
        & $checkAiParity 'ai-wt-outer-junc-parent' `
            @('check-worktree', '-RepoRoot', (Join-Path $wt2OuterJunc 'wt1')) `
            @('check-worktree', '--repo-root', "$wt2OuterJuncPosix/wt1") `
            2 @('WORKTREE_UNSAFE: unsafe_reparse_root')
    } finally {
        if (Test-Path -LiteralPath $wt2Junc) { [System.IO.Directory]::Delete($wt2Junc, $false) }
        if (Test-Path -LiteralPath $wt2OuterJunc) { [System.IO.Directory]::Delete($wt2OuterJunc, $false) }
        & git -C $wt2Main worktree remove -f $wt2One 2>$null | Out-Null
        & git -C $wt2Main worktree remove -f $wt2Two 2>$null | Out-Null
        & git -C $wt2Main worktree remove -f $wt2Nested 2>$null | Out-Null
        Remove-Item -LiteralPath (Join-Path $wt2Main 'sub') -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($aiErrs.Count -eq 0) {
        Pass 'guard-adaptive-isolation-and-dirty-scope'
    } else {
        FailCheck 'guard-adaptive-isolation-and-dirty-scope' ($aiErrs -join '; ')
    }

    # --- ship-parallel-wave-contracts-and-recovery (Scenarios 6-9, 11-13) ---
    $crErrs = New-Object System.Collections.Generic.List[string]
    $dispatchText = Get-Content -LiteralPath (Join-Path $root 'workflows\references\dispatch-naming.md') -Raw
    $shipText = Get-Content -LiteralPath (Join-Path $root 'workflows\ship.md') -Raw
    $shipTplText = Get-Content -LiteralPath (Join-Path $root 'workflows\references\ship-templates.md') -Raw
    $shipResText = Get-Content -LiteralPath (Join-Path $root 'workflows\references\ship-resume.md') -Raw
    $strategyText = Get-Content -LiteralPath (Join-Path $root 'review-loop\strategy.md') -Raw

    # Scenarios 6, 7 & 13: Sequential fallback, no-false-PARALLEL, adaptive isolation modes, honesty notes, and 4-host adapter contract (ship.md links dispatch-naming.md; detailed wave/isolation/ownership tokens checked on combined corpus)
    $shipWaveCorpus = $shipText + "`n" + $dispatchText
    if ($shipText -notmatch 'references/dispatch-naming\.md') {
        $crErrs.Add('workflows/ship.md missing explicit link to references/dispatch-naming.md')
    }
    foreach ($tok in @('single_ready_task', 'trivial_overhead', 'no_host_isolation', 'sequential_host_fallback', 'never report `PARALLEL`', 'Cursor', 'Claude Code', 'Codex', 'Antigravity', 'check-wave -Partition', 'last_wave:', 'SHARED_READ_ONLY', 'SHARED_DISJOINT_WRITES', 'ISOLATED_WRITES', 'SEQUENTIAL', 'Declared path ownership != OS filesystem isolation', '`WORKTREE_OK` verifies worktree identity, not full isolation', 'malformed_wave_output', 'unsafe_shared_side_effects', 'workers **never** stage, commit', 'UNVERIFIED_COMBINED_ONLY', 'CALLER_ATTRIBUTED', 'VERIFIED_PER_WORKER', 'PARTIAL_ATTRIBUTION', 'missing_worker', '-WorkerChanges', '-WorkerRoots', '-ProtectedPaths', '-DirtyDigests', 'dirty_tamper', '-RequireIsolated', 'empty write scopes', 'TaskId=none')) {
        if (-not $dispatchText.Contains($tok)) {
            $crErrs.Add("dispatch-naming.md missing '$tok'")
        }
    }
    foreach ($tok in @('check-wave -Partition', 'no_host_isolation', 'sequential_host_fallback', 'never report `PARALLEL`', 'last_wave:', 'single-writer', 'post-integration', 'Cursor', 'Claude', 'Codex', 'Antigravity', 'SHARED_READ_ONLY', 'SHARED_DISJOINT_WRITES', 'ISOLATED_WRITES', 'SEQUENTIAL', 'malformed_wave_output', 'UNVERIFIED_COMBINED_ONLY', 'CALLER_ATTRIBUTED', 'VERIFIED_PER_WORKER', 'PARTIAL_ATTRIBUTION', '-WorkerChanges', '-WorkerRoots', '-ProtectedPaths', '-DirtyDigests', '-RequireIsolated', 'TaskId=none')) {
        if (-not $shipWaveCorpus.Contains($tok)) {
            $crErrs.Add("ship+dispatch corpus missing '$tok'")
        }
    }
    foreach ($tok in @('check-wave -Partition', 'last_wave:', 'single-writer', 'post-integration', 'SHARED_READ_ONLY', 'SHARED_DISJOINT_WRITES', 'ISOLATED_WRITES', 'SEQUENTIAL', 'UNVERIFIED_COMBINED_ONLY', '-WorkerChanges', '-WorkerRoots', '-ProtectedPaths', '-DirtyDigests', '-RequireIsolated')) {
        if (-not $shipText.Contains($tok)) {
            $crErrs.Add("workflows/ship.md missing '$tok'")
        }
    }
    # Scenarios 8 & 9 contract: last_wave + extended Tasks columns in templates + partial wave / active-agent resume in ship-resume.md
    if ($shipTplText -notmatch '(?m)^- last_wave:') {
        $crErrs.Add('ship-templates.md missing "- last_wave:" field')
    }
    if ($shipTplText -notmatch '(?m)^\|\s*id\s*\|\s*status\s*\|\s*mode\s*\|\s*worker_root\s*\|\s*task_base\s*\|\s*scope\s*\|\s*commit\s*\|\s*verification\s*\|\s*review\s*\|\s*integration\s*\|\s*impl_agent\s*\|$') {
        $crErrs.Add('ship-templates.md missing extended Tasks columns (mode, worker_root, scope, integration)')
    }
    foreach ($tok in @('partial waves', 'never `git reset`', 'reconcile `last_wave:`', 'check-wave -Partition', 'impl_agent', 'never duplicate active work', '`mode`', '`worker_root`', '`scope`', 'integration')) {
        if (-not $shipResText.Contains($tok)) {
            $crErrs.Add("ship-resume.md missing '$tok'")
        }
    }
    # Scenario 11 contract: HIGH/CRITICAL review independence in review-loop/strategy.md
    foreach ($tok in @('SINGLE_AGENT_LIMIT', 'HIGH', 'CRITICAL', 'auto_merge', 'PASS', 'INCOMPLETE', 'verify-run')) {
        if (-not $strategyText.Contains($tok)) {
            $crErrs.Add("review-loop/strategy.md missing '$tok'")
        }
    }
    if ($strategyText -notmatch 'SINGLE_AGENT_LIMIT.*PASS.*HIGH.*CRITICAL') {
        $crErrs.Add('review-loop/strategy.md missing SINGLE_AGENT_LIMIT block on PASS for HIGH/CRITICAL')
    }

    # Scenarios 8, 9 & 12 behavioral: Partial-wave failure isolation, resolve-run + last_wave resume, and post-integration verify-run on combined tree
    $recRepo = Join-Path $sandbox 'wave-recovery-repo'
    $recRepoPosix = To-PosixPath $recRepo
    $utf8NoBomRec = New-Object System.Text.UTF8Encoding($false)
    Init-B3TestRepo -RepoPath $recRepo -InitialCommit -InitialFileName 'README.md' -InitialFileContent 'rec-base'
    New-Item -ItemType Directory -Path (Join-Path $recRepo 'src') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $recRepo 'src\t1.ts'), "export const t1 = 1;`n", $utf8NoBomRec)
    [IO.File]::WriteAllText((Join-Path $recRepo 'src\t2.ts'), "export const t2 = 1;`n", $utf8NoBomRec)
    & git -C $recRepo add . | Out-Null
    & git -C $recRepo commit -qm 'seed recovery files' | Out-Null
    $recBaseSha = (& git -C $recRepo rev-parse HEAD).Trim()

    $recRunRes = Invoke-PsGuard @('new-run', '-RepoRoot', $recRepo, '-Slug', 'wave-recover', '-Timestamp', '20261125-1000')
    $recRunId = $recRunRes.Text.Trim()
    if ($recRunRes.Code -ne 0 -or -not $recRunId) {
        $crErrs.Add("new-run failed: code=$($recRunRes.Code) out=$($recRunRes.Text)")
    } else {
        $recProg = Join-Path $recRepo ".b3\ship\runs\$recRunId\progress.md"
        [IO.File]::WriteAllText($recProg, "- run_id: $recRunId`n- last_wave: dispatch=PARALLEL agents=2 reason=disjoint_writes`n- run_status: running`n", $utf8NoBomRec)
        $resPs = Invoke-PsGuard @('resolve-run', '-RepoRoot', $recRepo)
        if ($resPs.Code -ne 0 -or $resPs.Text.Trim() -ne ".b3/ship/runs/$recRunId") {
            $crErrs.Add("resolve-run PS mismatch: code=$($resPs.Code) out=$($resPs.Text)")
        }
        if ($script:HasBash) {
            $resSh = Invoke-ShGuard @('resolve-run', '--repo-root', $recRepoPosix)
            if ($resSh.Code -ne 0 -or $resSh.Text.Trim() -ne ".b3/ship/runs/$recRunId") {
                $crErrs.Add("resolve-run SH mismatch: code=$($resSh.Code) out=$($resSh.Text)")
            }
        }
        if (((Get-Content -LiteralPath $recProg -Raw) -notmatch 'last_wave: dispatch=PARALLEL agents=2')) {
            $crErrs.Add('progress.md failed to preserve last_wave:')
        }

        # T001 succeeds & commits while T002 fails verify-run; T001 commit & receipt stay intact
        [IO.File]::WriteAllText((Join-Path $recRepo 'src\t1.ts'), "export const t1 = 2;`n", $utf8NoBomRec)
        $recR1 = ".b3/ship/runs/$recRunId/evidence/T001.verify"
        $v1 = Invoke-PsGuard @('verify-run', '-RepoRoot', $recRepo, '-VerifyCmd', 'echo t1-ok', '-ReceiptPath', $recR1, '-TaskId', 'T001', '-RelevantPaths', 'src/t1.ts')
        & git -C $recRepo add src/t1.ts | Out-Null
        $pc1 = Invoke-PsGuard @('precommit', '-RepoRoot', $recRepo, '-AllowedPaths', 'src/t1.ts', '-RequireVerifyReceipt', $recR1)
        & git -C $recRepo commit -qm 'T001 complete' | Out-Null
        $t1Sha = (& git -C $recRepo rev-parse HEAD).Trim()

        [IO.File]::WriteAllText((Join-Path $recRepo 'src\t2.ts'), "export const t2 = -1;`n", $utf8NoBomRec)
        $recR2 = ".b3/ship/runs/$recRunId/evidence/T002.verify"
        $v2Fail = Invoke-PsGuard @('verify-run', '-RepoRoot', $recRepo, '-VerifyCmd', 'Write-Output "t2-fail"; exit 2', '-ReceiptPath', $recR2, '-TaskId', 'T002', '-RelevantPaths', 'src/t2.ts')
        $pc2Blocked = Invoke-PsGuard @('precommit', '-RepoRoot', $recRepo, '-AllowedPaths', 'src/t2.ts', '-RequireVerifyReceipt', $recR2)
        if ($v1.Code -ne 0 -or $pc1.Code -ne 0 -or $v2Fail.Code -ne 1 -or ($v2Fail.Text -notmatch 'VERIFY_FAIL:') -or $pc2Blocked.Code -eq 0) {
            $crErrs.Add("partial-wave failure isolation failed: v1=$($v1.Code) pc1=$($pc1.Code) v2=$($v2Fail.Code) pc2Blk=$($pc2Blocked.Code)")
        }

        # Isolate/fix only T002, verify T001 still descends & receipt valid, commit T002, then run post-integration verify-run on combined tree (Scenario 12)
        [IO.File]::WriteAllText((Join-Path $recRepo 'src\t2.ts'), "export const t2 = 2;`n", $utf8NoBomRec)
        $v2Ok = Invoke-PsGuard @('verify-run', '-RepoRoot', $recRepo, '-VerifyCmd', 'echo t2-ok', '-ReceiptPath', $recR2, '-TaskId', 'T002', '-RelevantPaths', 'src/t2.ts')
        & git -C $recRepo add src/t2.ts | Out-Null
        $pc2Ok = Invoke-PsGuard @('precommit', '-RepoRoot', $recRepo, '-AllowedPaths', 'src/t2.ts', '-RequireVerifyReceipt', $recR2)
        & git -C $recRepo commit -qm 'T002 complete' | Out-Null
        & git -C $recRepo merge-base --is-ancestor $t1Sha HEAD | Out-Null
        $t1Anc = $LASTEXITCODE
        & git -C $recRepo merge-base --is-ancestor $recBaseSha $t1Sha | Out-Null
        $baseAnc = $LASTEXITCODE
        $vc1Post = Invoke-PsGuard @('verify-check', '-RepoRoot', $recRepo, '-ReceiptPath', $recR1)
        $recInt = ".b3/ship/runs/$recRunId/evidence/INTEGRATION.verify"
        $vIntPs = Invoke-PsGuard @('verify-run', '-RepoRoot', $recRepo, '-VerifyCmd', 'echo combined-green', '-ReceiptPath', $recInt, '-TaskId', 'WAVE1_INT')
        $vcIntPs = Invoke-PsGuard @('verify-check', '-RepoRoot', $recRepo, '-ReceiptPath', $recInt)
        if ($v2Ok.Code -ne 0 -or $pc2Ok.Code -ne 0 -or $t1Anc -ne 0 -or $baseAnc -ne 0 -or $vc1Post.Code -ne 0 -or $vIntPs.Code -ne 0 -or ($vIntPs.Text -notmatch 'VERIFY_PASS:') -or $vcIntPs.Code -ne 0) {
            $crErrs.Add("post-integration failed: v2Ok=$($v2Ok.Code) pc2Ok=$($pc2Ok.Code) t1Anc=$t1Anc baseAnc=$baseAnc vc1=$($vc1Post.Code) vInt=$($vIntPs.Code) vcInt=$($vcIntPs.Code)")
        }
        if ($script:HasBash) {
            $vcIntSh = Invoke-ShGuard @('verify-check', '--repo-root', $recRepoPosix, '--receipt-path', $recInt)
            $vc1Sh = Invoke-ShGuard @('verify-check', '--repo-root', $recRepoPosix, '--receipt-path', $recR1)
            if ($vcIntSh.Code -ne 0 -or ($vcIntSh.Text -notmatch 'VERIFY_VALID:') -or $vc1Sh.Code -ne 0) {
                $crErrs.Add("post-integration SH verify-check failed: int=$($vcIntSh.Code) t1=$($vc1Sh.Code)")
            }
        }
    }

    if ($crErrs.Count -eq 0) {
        Pass 'ship-parallel-wave-contracts-and-recovery'
    } else {
        FailCheck 'ship-parallel-wave-contracts-and-recovery' ($crErrs -join '; ')
    }

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

Complete-ValidationSuite -AllowIncompleteBash:$AllowIncompleteBash
