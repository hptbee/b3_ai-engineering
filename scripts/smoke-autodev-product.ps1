# Isolated product-repo smoke for autodev Git/checkpoint/resume contracts.
# This is not a Cursor slash-command test and not a Codex/Claude runtime test.
# Usage: powershell -File scripts/smoke-autodev-product.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sandbox = Join-Path $env:TEMP ("b3-autodev-smoke-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox | Out-Null

function Fail([string]$Message) {
    Write-Output "SMOKE FAIL: $Message"
    exit 1
}

Push-Location $sandbox
try {
    git init -q
    git config user.email 'autodev-smoke@example.com'
    git config user.name 'Autodev Smoke'
    Set-Content README.md "# greet`n"
    git add README.md
    git commit -qm 'init product'

    & powershell -NoProfile -File (Join-Path $root 'adapters\install-product.ps1') -ProductRoot $sandbox -B3Home $root -HostName cursor
    if ($LASTEXITCODE -ne 0) { Fail 'install-product' }
    $b3HomePath = (Get-Content .b3\home -Raw).Trim()
    if ($b3HomePath -ne $root) { Fail "B3_HOME mismatch: $b3HomePath" }
    if (-not (Test-Path .cursor\commands\autodev.md)) { Fail 'missing autodev command pointer' }
    if (Test-Path .cursor\skills) { Fail 'installer copied skills' }

    git add .gitignore .cursor/commands/autodev.md
    $installCached = git diff --cached --name-only
    if ($installCached -match '\.b3/') { Fail 'install commit staged .b3' }
    git commit -qm 'Attach B3 autodev pointer without copying skills'
    $runBase = git rev-parse HEAD

    # Scenario A: write master plan (no replan later)
    New-Item -ItemType Directory -Path .b3\autodev -Force | Out-Null
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
'@ | Set-Content .b3\autodev\master-plan.md

    @"
# Progress
- b3_home: $root
- product_root: $sandbox
- plan_id: Add greet(name) v1
- plan_version: 1
- branch: $(git branch --show-current)
- run_base_sha: $runBase
- run_status: running
"@ | Set-Content .b3\autodev\progress.md

    $planBefore = Get-FileHash .b3\autodev\master-plan.md -Algorithm SHA256

    # T001 (includes unused greetAlias residue for the later review/fix)
    $t1Base = git rev-parse HEAD
    Set-Content greet.js @"
function greet(name) { return 'Hello, ' + name; }
function greetAlias(name) { return greet(name); }
module.exports = { greet, greetAlias };
"@
    node -e "const {greet}=require('./greet'); if (greet('Ada')!=='Hello, Ada') process.exit(1)"
    if ($LASTEXITCODE -ne 0) { Fail 'T001 verification' }
    git add greet.js
    $cached = git diff --cached --name-only
    if ($cached -match '\.b3/') { Fail 'T001 staged .b3' }
    git commit -qm 'Add greet helper so callers can format a hello message'
    $t1 = git rev-parse HEAD

    # Interrupt: uncommitted T002 work
    Set-Content README.md "# greet`n`nUse greet(name).`n"
    git status --porcelain | Out-String | ForEach-Object { if ($_ -notmatch 'README.md') { } }

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
    $planAfter = Get-FileHash .b3\autodev\master-plan.md -Algorithm SHA256
    if ($planBefore.Hash -ne $planAfter.Hash) { Fail 'master plan rewritten during execution' }

    # Independent review of T001 residue: greetAlias was not in the requirements. Fix, then re-verify.
    Set-Content greet.js "function greet(name) { return 'Hello, ' + name; }`nmodule.exports = { greet };`n"
    node -e "const {greet}=require('./greet'); if (greet('Ada')!=='Hello, Ada') process.exit(1)"
    git add greet.js
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
    if ($tree -match '\.b3/') { Fail 'checkpoint leaked into git tree' }

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
    Write-Output 'classification: Git/checkpoint/resume/install contracts VERIFIED in an isolated repo. Host /autodev slash UX NOT VERIFIED. Independent reviewer subagent NOT used (hat-change residue removal only).'
}
finally {
    Pop-Location
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}
