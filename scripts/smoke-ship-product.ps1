# Isolated product-repo smoke for /b3-ship Git/checkpoint/resume contracts.
# This is not a Cursor slash-command test and not a Codex/Claude runtime test.
# Usage: powershell -File scripts/smoke-ship-product.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\global-test-helpers.ps1')
$root = Split-Path -Parent $PSScriptRoot
$sandbox = Join-Path $env:TEMP ("b3-ship-smoke-" + [guid]::NewGuid().ToString('N'))
$prevSkipModelInit = $env:B3_SKIP_MODEL_INIT
$env:B3_SKIP_MODEL_INIT = '1'

function Fail([string]$Message) {
    Write-Output "SMOKE FAIL: $Message"
    exit 1
}

try {
    Init-B3TestRepo -RepoPath $sandbox -UserEmail 'ship-smoke@example.com' -UserName 'Ship Smoke' -InitialCommit -InitialFileName 'README.md' -InitialFileContent '# greet'
    Push-Location $sandbox

    & powershell -NoProfile -File (Join-Path $root 'adapters\install-product.ps1') -ProductRoot $sandbox -B3Home $root -HostName cursor
    if ($LASTEXITCODE -ne 0) { Fail 'install-product' }
    $b3HomePath = (Get-Content .b3\home -Raw).Trim()
    if ($b3HomePath -ne $root) { Fail "B3_HOME mismatch: $b3HomePath" }
    if (-not (Test-Path .cursor\commands\b3-ship.md)) { Fail 'missing b3-ship command pointer' }
    if (Test-Path .cursor\skills) { Fail 'installer copied skills' }

    git add .gitignore .b3/home AGENTS.md .cursor/README.md .cursor/commands
    $installCached = git diff --cached --name-only
    if ($installCached | Where-Object { $_ -match '^\.b3/ship/' }) { Fail 'install commit staged .b3/ship' }
    git commit -qm 'Attach B3 ship pointer without copying skills'
    $runBase = git rev-parse HEAD

    # Scenario A: allocate run-scoped checkpoint dir and write master plan (no replan later)
    $guard = Join-Path $root 'scripts\b3-guard.ps1'
    $runId = (& $guard new-run -RepoRoot $sandbox -Slug 'add-greet').Trim()
    if ($LASTEXITCODE -ne 0 -or -not $runId) { Fail "new-run failed: $runId" }
    $runDirRel = (& $guard resolve-run -RepoRoot $sandbox).Trim()
    if ($LASTEXITCODE -ne 0 -or $runDirRel -ne ".b3/ship/runs/$runId") { Fail "resolve-run failed: $runDirRel" }
    $runDir = Join-Path $sandbox ($runDirRel -replace '/', '\')
    $planPath = Join-Path $runDir 'master-plan.md'
    $progressPath = Join-Path $runDir 'progress.md'

    @'
# Add greet(name)

- version: 1
- source: User story: Add greet(name) that returns Hello, <name>

## Original requirements
- greet(name) returns "Hello, <name>"
- README documents the function

## Scope
JavaScript greet helper and README

## Exclusions
- No HTTP API

## Tasks

### T001 — Implement greet

- status: pending
- depends_on: []
- scope: greet.js
- acceptance_criteria:
  - greet("Ada") returns "Hello, Ada"
- verification:
  - node -e "const {greet}=require('./greet'); if (greet('Ada')!=='Hello, Ada') process.exit(1)"

### T002 — Document greet

- status: pending
- depends_on: [T001]
- scope: README.md
- acceptance_criteria:
  - README mentions greet(name)
- verification:
  - findstr /C:"greet(" README.md
'@ | Set-Content $planPath

    @"
# Progress
- run_id: $runId
- b3_home: $root
- product_root: $sandbox
- plan_id: Add greet(name) v1
- plan_version: 1
- branch: $(git branch --show-current)
- run_base_sha: $runBase
- run_status: running
"@ | Set-Content $progressPath

    $fp1 = (& $guard fingerprint -DependsOn '[]' -Scope 'greet.js' -Criteria 'AC1: greet("Ada") returns "Hello, Ada"').Trim()
    if ($fp1 -ne 'depends_on=[]|scope=greet.js|acceptance_criteria=AC1: greet("Ada") returns "Hello, Ada"') { Fail "unexpected T001 fingerprint: $fp1" }
    $fp2 = (& $guard fingerprint -DependsOn 'T001' -Scope 'README.md' -Criteria 'AC2: README mentions greet(name)').Trim()
    if ($fp2 -ne 'depends_on=T001|scope=README.md|acceptance_criteria=AC2: README mentions greet(name)') { Fail "unexpected T002 fingerprint: $fp2" }

    $planBefore = Get-FileHash $planPath -Algorithm SHA256

    # T001 (includes unused greetAlias residue for the later review/fix)
    $t1Base = git rev-parse HEAD
    Set-Content greet.js @"
function greet(name) { return 'Hello, ' + name; }
function greetAlias(name) { return greet(name); }
module.exports = { greet, greetAlias };
"@
    node -e "const {greet}=require('./greet'); if (greet('Ada')!=='Hello, Ada') process.exit(1)"
    if ($LASTEXITCODE -ne 0) { Fail 'T001 verification' }
    $preFixSnap = (& $guard snapshot -RepoRoot $sandbox).Trim()
    if ($LASTEXITCODE -ne 0 -or $preFixSnap -notmatch '^[0-9a-f]{40}$') { Fail "invalid pre-fix snapshot: $preFixSnap" }
    $stashList = git stash list
    if ($stashList) { Fail "snapshot mutated git stash list: $stashList" }
    git add greet.js
    $cached = git diff --cached --name-only
    if ($cached -match '\.b3/') { Fail 'T001 staged .b3' }
    & $guard precommit -RepoRoot $sandbox -AllowedPaths 'greet.js' | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail 'T001 precommit guard failed' }
    git commit -qm 'Add greet helper so callers can format a hello message'
    $t1 = git rev-parse HEAD

    # Interrupt: uncommitted T002 work
    Set-Content README.md "# greet`n`nUse greet(name).`n"
    $interruptStatus = @(git status --porcelain | Where-Object { $_.Trim() })
    if ($interruptStatus.Count -ne 1 -or ($interruptStatus[0] -notmatch 'README\.md$')) {
        Fail "unexpected worktree state at interrupt:`n$($interruptStatus -join "`n")"
    }

    # Resume: T001 still complete; do not duplicate
    git merge-base --is-ancestor $t1 HEAD
    if ($LASTEXITCODE -ne 0) { Fail 'T001 not ancestor on resume' }
    git cat-file -t $t1 | Out-Null
    $logBeforeT2 = git log --oneline "$runBase..HEAD"
    if (($logBeforeT2 -split "`n" | Where-Object { $_ }).Count -ne 1) { Fail "expected one task commit before T002: $logBeforeT2" }

    # T002
    git add README.md
    git commit -qm 'Document greet in README so the helper is discoverable'
    $t2 = git rev-parse HEAD

    # Existing plan: hash unchanged (no unnecessary rewrite)
    $planAfter = Get-FileHash $planPath -Algorithm SHA256
    if ($planBefore.Hash -ne $planAfter.Hash) { Fail 'master plan rewritten during execution' }

    # Independent review of T001 residue: greetAlias was not in the requirements. Fix, then re-verify.
    Set-Content greet.js "function greet(name) { return 'Hello, ' + name; }`nmodule.exports = { greet };`n"
    node -e "const {greet}=require('./greet'); if (greet('Ada')!=='Hello, Ada') process.exit(1)"
    if ($LASTEXITCODE -ne 0) { Fail 'post-fix T001 verification' }
    git add greet.js
    & $guard precommit -RepoRoot $sandbox -AllowedPaths 'greet.js' | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail 'residue fix precommit guard failed' }
    git diff --cached --quiet
    if ($LASTEXITCODE -eq 0) { Fail 'expected residue fix to produce a diff' }
    git commit -qm 'Remove unused greet alias left after the helper landed'
    $final = git rev-parse HEAD
    if ($final -eq $t2) { Fail 'residue fix did not create a new commit' }

    $range = git log --oneline "$runBase..HEAD"
    $count = @($range -split "`n" | Where-Object { $_.Trim() }).Count
    if ($count -lt 2) { Fail "cumulative log too short:`n$range" }
    git merge-base --is-ancestor $t1 HEAD | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail 'T001 missing from final HEAD' }
    git merge-base --is-ancestor $t2 HEAD | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail 'T002 missing from final HEAD' }
    git merge-base --is-ancestor $final HEAD | Out-Null

    $tree = git ls-tree -r --name-only HEAD
    if ($tree -match '(^|/)(\.b3/ship/)') { Fail 'checkpoint leaked into git tree' }

    $porcelain = git status --porcelain
    if ($porcelain -and ($porcelain | Where-Object { $_ -notmatch '^\?\? \.b3/' })) {
        # .b3 is gitignored so it should not appear
        Fail "dirty non-ignored worktree:`n$porcelain"
    }

    Write-Output 'SMOKE PASS'
    Write-Output "run_base=$runBase"
    Write-Output "T001=$t1"
    Write-Output "T002=$t2"
    Write-Output "final=$final"
    Write-Output "log="
    Write-Output $range
    Write-Output 'classification: Git/checkpoint/resume/install contracts VERIFIED in an isolated repo. Host /b3-ship slash UX NOT VERIFIED. Independent reviewer subagent NOT used (hat-change residue removal only).'
}
finally {
    if ($null -eq $prevSkipModelInit) { Remove-Item Env:B3_SKIP_MODEL_INIT -ErrorAction SilentlyContinue } else { $env:B3_SKIP_MODEL_INIT = $prevSkipModelInit }
    Pop-Location -ErrorAction SilentlyContinue
    Remove-ReparseLinksUnder $sandbox
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}
