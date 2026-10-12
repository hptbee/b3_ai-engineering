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

    # --- F2 recipe present in workflow ---
    $wf = Get-Content (Join-Path $root 'workflows\autonomous-development.md') -Raw
    $needles = @(
        'run_base_sha',
        'task_base',
        'git ls-files --others --exclude-standard',
        'git merge-base --is-ancestor',
        'git add -A',
        'B3_HOME'
    )
    $missing = @($needles | Where-Object { $wf -notlike "*$_*" })
    if ($missing.Count -eq 0) { Pass 'workflow-recipes' }
    else { FailCheck 'workflow-recipes' ($missing -join ', ') }
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
