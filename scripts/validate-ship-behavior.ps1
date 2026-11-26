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
    New-B3SyncFixture -FixtureDir $fx -RepoRoot $root -IncludeCommands -IncludeAgents

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
    New-B3SyncFixture -FixtureDir $fxCur -RepoRoot $root -IncludeCommands -IncludeAgents
    & powershell -NoProfile -File (Join-Path $fxCur 'adapters\sync-skills.ps1') -HostName cursor | Out-Null
    $curSyncExit = $LASTEXITCODE
    & powershell -NoProfile -File (Join-Path $fxCur 'adapters\sync-skills.ps1') -HostName cursor -VerifyOnly | Out-Null
    $curVerifyExit = $LASTEXITCODE
    if ($curSyncExit -eq 0 -and $curVerifyExit -eq 0) { Pass 'sync-cursor' }
    else { FailCheck 'sync-cursor' "sync=$curSyncExit verify=$curVerifyExit" }

    # Claude sync on clean fixture
    $fxCl = Join-Path $sandbox 'sync-fx-claude'
    New-B3SyncFixture -FixtureDir $fxCl -RepoRoot $root -IncludeAgents
    & powershell -NoProfile -File (Join-Path $fxCl 'adapters\sync-skills.ps1') -HostName claude | Out-Null
    $clSyncExit = $LASTEXITCODE
    & powershell -NoProfile -File (Join-Path $fxCl 'adapters\sync-skills.ps1') -HostName claude -VerifyOnly | Out-Null
    $clVerifyExit = $LASTEXITCODE
    if ($clSyncExit -eq 0 -and $clVerifyExit -eq 0) { Pass 'sync-claude' }
    else { FailCheck 'sync-claude' "sync=$clSyncExit verify=$clVerifyExit" }

    $fx2 = Join-Path $sandbox 'sync-fx-nonempty'
    New-B3SyncFixture -FixtureDir $fx2 -RepoRoot $root
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
    Init-B3TestRepo -RepoPath $fresh -UserEmail 'ship-test@example.com' -UserName 'Ship Test'
    Push-Location $fresh
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
    New-B3SyncFixture -FixtureDir $agSyncFx -RepoRoot $root
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
    Init-B3TestRepo -RepoPath $agProduct -UserEmail 'ship-test@example.com' -UserName 'Ship Test' -InitialCommit -InitialFileName 'README.md' -InitialFileContent 'ag product'

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
    Init-B3TestRepo -RepoPath $clProduct -UserEmail 'ship-test@example.com' -UserName 'Ship Test' -InitialCommit -InitialFileName 'README.md' -InitialFileContent 'claude product'

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
                $cmdHits += "$($f.Name):$($hit.LineNumber)"
            }
        }
    }
    if ($cmdHits.Count -eq 0) { Pass 'no-cmd-exe-junction-ops' }
    else { FailCheck 'no-cmd-exe-junction-ops' "hits=$($cmdHits -join ', ')" }


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


    # --- CF-17: real out-of-process CLI smoke (powershell -File $guardScript + B3_TEST_OUT_OF_PROC_PS=1 Invoke-PsGuard) ---
    $oopRepo = Join-Path $sandbox 'oop-repo'
    Init-B3TestRepo -RepoPath $oopRepo -DefaultBranch 'main' -UserEmail 'ship-test@example.com' -UserName 'Ship Test' -InitialCommit
    $oopBase = (& git -C $oopRepo rev-parse HEAD).Trim()
    $oopErrs = New-Object System.Collections.Generic.List[string]
    $oopPrevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $oopFpOut = ((& powershell -NoProfile -ExecutionPolicy Bypass -File $guardScript fingerprint -DependsOn 'T002,T001' -Scope 'src/a.ts' -Criteria 'AC1: ok' 2>&1) | ForEach-Object { ([string]$_).TrimEnd("`r") }) -join "`n"
        $oopFpCode = $LASTEXITCODE
        $oopDsOut = ((& powershell -NoProfile -ExecutionPolicy Bypass -File $guardScript diff-scope -RepoRoot $oopRepo -BaseSha $oopBase 2>&1) | ForEach-Object { ([string]$_).TrimEnd("`r") }) -join "`n"
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
        $oopCfOk = Invoke-PsGuard @('check-freshness', '-RepoRoot', $oopRepo, '-ApproachAtSha', $oopBase, '-TaskBaseSha', $oopBase, '-WatchedPaths', 'README.md')
        $oopCfBad = Invoke-PsGuard @('check-freshness', '-RepoRoot', $oopRepo, '-ApproachAtSha:-s', '-TaskBaseSha', $oopBase, '-WatchedPaths', 'README.md')
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
    if ($shipTplText -notmatch '(?m)^\|\s*id\s*\|\s*status\s*\|\s*mode\s*\|\s*worker_root\s*\|\s*task_base\s*\|\s*scope\s*\|\s*commit\s*\|\s*verification\s*\|\s*review\s*\|\s*integration\s*\|\s*impl_agent\s*\|\r?$') {
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
