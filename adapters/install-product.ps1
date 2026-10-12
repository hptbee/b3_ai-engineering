param(
    [Parameter(Mandatory = $true)]
    [string]$ProductRoot,
    [string]$B3Home,
    [ValidateSet('cursor', 'codex', 'claude')]
    [string]$HostName = 'cursor',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

function Test-SameFile([string]$Left, [string]$Right) {
    if (-not (Test-Path -LiteralPath $Left) -or -not (Test-Path -LiteralPath $Right)) { return $false }
    return (Get-FileHash -LiteralPath $Left -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $Right -Algorithm SHA256).Hash
}

$scriptRoot = $PSScriptRoot
if (-not $B3Home) { $B3Home = Split-Path -Parent $scriptRoot }
$B3Home = (Resolve-Path -LiteralPath $B3Home).Path
$ProductRoot = (Resolve-Path -LiteralPath $ProductRoot).Path
$workflow = Join-Path $B3Home 'workflows\autonomous-development.md'
$template = Join-Path $scriptRoot 'product-autodev.md'
$skills = Join-Path $B3Home '.cursor\skills'

if (-not (Test-Path -LiteralPath $workflow)) { Fail "B3_HOME missing workflow: $workflow" }
if (-not (Test-Path -LiteralPath $template)) { Fail "missing template: $template" }
if (@(Get-ChildItem -LiteralPath $skills -Recurse -Filter 'SKILL.md' -File -ErrorAction SilentlyContinue).Count -lt 1) {
    Fail "B3_HOME has no SKILL.md under .cursor/skills: $skills"
}

$productSkills = Join-Path $ProductRoot '.cursor\skills'
$commandDest = Join-Path $ProductRoot '.cursor\commands\autodev.md'
$homeDest = Join-Path $ProductRoot '.b3\home'
$agentsDest = Join-Path $ProductRoot '.agents\skills'
$claudeDest = Join-Path $ProductRoot '.claude\skills'

if (Test-Path -LiteralPath $productSkills) {
    $productSkillCount = @(Get-ChildItem -LiteralPath $productSkills -Recurse -Filter 'SKILL.md' -File -ErrorAction SilentlyContinue).Count
    if ($productSkillCount -gt 0) {
        Fail "product already has $productSkillCount SKILL.md under .cursor/skills; refusing to install a duplicate skill tree"
    }
}

if ($HostName -eq 'cursor') {
    if (Test-Path -LiteralPath $agentsDest) {
        Fail "product has .agents/skills; Cursor would duplicate discovery. Remove it or install with -HostName codex only in a Codex-only checkout"
    }
    if (Test-Path -LiteralPath $claudeDest) {
        Fail "product has .claude/skills; Cursor would duplicate discovery. Remove it before a Cursor install"
    }
}

if (Test-Path -LiteralPath $commandDest) {
    if (-not (Test-SameFile $commandDest $template)) {
        Fail "refusing to overwrite existing $commandDest (differs from template). Move it aside and re-run"
    }
}

if (Test-Path -LiteralPath $homeDest) {
    $existingHome = (Get-Content -LiteralPath $homeDest -Raw).Trim()
    if ($existingHome -ne $B3Home) {
        Fail "refusing to overwrite $homeDest (points to $existingHome, requested $B3Home)"
    }
}

$linkDest = $null
if ($HostName -eq 'codex') { $linkDest = $agentsDest }
if ($HostName -eq 'claude') { $linkDest = $claudeDest }
$linkExistsOk = $false
if ($linkDest -and (Test-Path -LiteralPath $linkDest)) {
    $item = Get-Item -LiteralPath $linkDest -Force
    if ($item.LinkType -in @('Junction', 'SymbolicLink')) {
        try { $linkExistsOk = ((Resolve-Path -LiteralPath $linkDest).Path.TrimEnd('\') -eq $skills.TrimEnd('\')) } catch { $linkExistsOk = $false }
    }
    if (-not $linkExistsOk) { Fail "refusing to replace existing $linkDest" }
}

function Test-B3GitignoreOk([string]$Text) {
    return ($Text -match '(?m)^\s*\.b3/autodev/\s*$') -or ($Text -match '(?m)^\s*\.b3/\s*$')
}

function Update-B3Gitignore([string]$Root) {
    $gi = Join-Path $Root '.gitignore'
    $block = @"

# B3: commit .b3/home; keep autodev checkpoints local
.b3/autodev/
"@
    if (-not (Test-Path -LiteralPath $gi)) {
        Set-Content -LiteralPath $gi -Value ($block.TrimStart() + "`n")
        return 'created'
    }
    $text = Get-Content -LiteralPath $gi -Raw
    if ($text -match '(?m)^\s*\.b3/autodev/\s*$') { return 'present' }
    if ($text -match '(?m)^\s*\.b3/\s*$') {
        $text = [regex]::Replace($text, '(?m)^\s*\.b3/\s*$', '.b3/autodev/')
        Set-Content -LiteralPath $gi -Value $text -NoNewline
        return 'upgraded'
    }
    Add-Content -LiteralPath $gi -Value $block
    return 'appended'
}

$cursorReadmeTemplate = Join-Path $scriptRoot 'product-cursor-readme.md'
$b3Commands = Join-Path $B3Home '.cursor\commands'
$cursorReadmeDest = Join-Path $ProductRoot '.cursor\README.md'

$ignorePlan = 'dry-run'
if (-not $DryRun) { $ignorePlan = Update-B3Gitignore $ProductRoot }

if ($DryRun) {
    Write-Output "dry-run: write $homeDest = $B3Home"
    if (Test-Path -LiteralPath $commandDest) { Write-Output "dry-run: keep existing $commandDest (matches template)" }
    else { Write-Output "dry-run: write $commandDest from $template" }
    Write-Output "dry-run: gitignore .b3/autodev/ (see Update-B3Gitignore)"
    Get-ChildItem -LiteralPath $b3Commands -Filter '*.md' -File | ForEach-Object {
        if ($_.Name -eq 'README.md') { return }
        $dest = Join-Path (Join-Path $ProductRoot '.cursor\commands') $_.Name
        if ($_.Name -eq 'autodev.md') { return }
        if (-not (Test-Path -LiteralPath $dest)) { Write-Output "dry-run: copy command $($_.Name)" }
    }
    if ($HostName -eq 'cursor' -and (Test-Path -LiteralPath $cursorReadmeTemplate)) {
        Write-Output "dry-run: write $cursorReadmeDest"
    }
    if ($linkDest -and -not $linkExistsOk) { Write-Output "dry-run: junction $linkDest -> $skills" }
    exit 0
}

New-Item -ItemType Directory -Path (Join-Path $ProductRoot '.b3') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $ProductRoot '.cursor\commands') -Force | Out-Null
if (-not (Test-Path -LiteralPath $homeDest)) {
    Set-Content -LiteralPath $homeDest -Value $B3Home -NoNewline
}
if (-not (Test-Path -LiteralPath $commandDest)) {
    Copy-Item -LiteralPath $template -Destination $commandDest
}

if ($HostName -eq 'cursor' -and (Test-Path -LiteralPath $b3Commands)) {
    $cmdDir = Join-Path $ProductRoot '.cursor\commands'
    foreach ($src in Get-ChildItem -LiteralPath $b3Commands -Filter '*.md' -File) {
        if ($src.Name -in @('README.md', 'autodev.md')) { continue }
        $dest = Join-Path $cmdDir $src.Name
        if (-not (Test-Path -LiteralPath $dest)) {
            Copy-Item -LiteralPath $src.FullName -Destination $dest
        }
    }
    if (Test-Path -LiteralPath $cursorReadmeTemplate) {
        Copy-Item -LiteralPath $cursorReadmeTemplate -Destination $cursorReadmeDest -Force
    }
}

if ($linkDest -and -not $linkExistsOk) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $linkDest) -Force | Out-Null
    New-Item -ItemType Junction -Path $linkDest -Target $skills | Out-Null
}

Write-Output "installed B3 pointer in $ProductRoot"
Write-Output "B3_HOME=$B3Home"
Write-Output "command=$commandDest"
Write-Output "gitignore.b3=$ignorePlan"
Write-Output "host=$HostName"
Write-Output "skills=user-level ~/.cursor/skills/b3-ai-engineering -> $skills (not copied into product)"
Write-Output "note: this proves files were written, not host slash-command or skill discovery"
