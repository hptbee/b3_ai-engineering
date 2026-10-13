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
$commandSkillsSrc = Join-Path $scriptRoot 'codex-command-skills'

function Remove-JunctionOrSymlink([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.LinkType -in @('Junction', 'SymbolicLink')) {
        & cmd.exe /c rmdir "$Path"
        if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath $Path)) { Fail "could not remove junction $Path" }
        return
    }
    Fail "refusing to replace existing $Path"
}

function Get-SkillNameFromFile([string]$Path) {
    $text = Get-Content -LiteralPath $Path -Raw
    if ($text -match '(?m)^name:\s*([a-z0-9-]+)\s*$') { return $Matches[1] }
    return (Split-Path -Leaf (Split-Path -Parent $Path))
}

function Test-LinkTarget([string]$LinkPath, [string]$Expected) {
    try {
        return ((Resolve-Path -LiteralPath $LinkPath).Path.TrimEnd('\')) -eq $Expected.TrimEnd('\')
    } catch {
        return $false
    }
}

function Install-SkillJunction([string]$Dest, [string]$Target) {
    if (Test-Path -LiteralPath $Dest) {
        $item = Get-Item -LiteralPath $Dest -Force
        if ($item.LinkType -in @('Junction', 'SymbolicLink') -and (Test-LinkTarget $Dest $Target)) { return }
        Fail "refusing to replace existing $Dest"
    }
    New-Item -ItemType Junction -Path $Dest -Target $Target | Out-Null
}

function Install-CodexSkillIndex([string]$DestRoot, [string]$SkillsSrc, [string]$CommandSkillsSrc) {
    if (Test-Path -LiteralPath $DestRoot) {
        $item = Get-Item -LiteralPath $DestRoot -Force
        if ($item.LinkType -in @('Junction', 'SymbolicLink')) {
            # Previous install linked the whole nested skill tree. Codex needs one folder per skill.
            Remove-JunctionOrSymlink $DestRoot
        } elseif (-not $item.PSIsContainer) {
            Fail "refusing to replace existing $DestRoot"
        }
    }
    New-Item -ItemType Directory -Path $DestRoot -Force | Out-Null
    Get-ChildItem -LiteralPath $SkillsSrc -Recurse -Filter 'SKILL.md' -File | ForEach-Object {
        $name = Get-SkillNameFromFile $_.FullName
        $srcDir = Split-Path -Parent $_.FullName
        Install-SkillJunction (Join-Path $DestRoot $name) $srcDir
    }
    if (Test-Path -LiteralPath $CommandSkillsSrc) {
        Get-ChildItem -LiteralPath $CommandSkillsSrc -Directory | ForEach-Object {
            if (-not (Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md'))) { return }
            Install-SkillJunction (Join-Path $DestRoot $_.Name) $_.FullName
        }
    }
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

function Update-HostSkillGitignore([string]$Root, [string]$HostName) {
    $line = $null
    if ($HostName -eq 'codex') { $line = '.agents/skills' }
    if ($HostName -eq 'claude') { $line = '.claude/skills' }
    if (-not $line) { return 'n/a' }
    $gi = Join-Path $Root '.gitignore'
    $escaped = [regex]::Escape($line)
    if (-not (Test-Path -LiteralPath $gi)) {
        Set-Content -LiteralPath $gi -Value ("# B3: local host skill link`n$line`n")
        return 'created'
    }
    $text = Get-Content -LiteralPath $gi -Raw
    if ($text -match "(?m)^\s*$escaped\s*$") { return 'present' }
    Add-Content -LiteralPath $gi -Value "`n# B3: local host skill link (do not commit)`n$line"
    return 'appended'
}

$cursorReadmeTemplate = Join-Path $scriptRoot 'product-cursor-readme.md'
$agentsMdTemplate = Join-Path $scriptRoot 'product-agents.md'
$b3Commands = Join-Path $B3Home '.cursor\commands'
$cursorReadmeDest = Join-Path $ProductRoot '.cursor\README.md'
$agentsMdDest = Join-Path $ProductRoot 'AGENTS.md'

$ignorePlan = 'dry-run'
$skillIgnorePlan = 'dry-run'
if (-not $DryRun) {
    $ignorePlan = Update-B3Gitignore $ProductRoot
    $skillIgnorePlan = Update-HostSkillGitignore $ProductRoot $HostName
}

if ($DryRun) {
    Write-Output "dry-run: write $homeDest = $B3Home"
    if (Test-Path -LiteralPath $commandDest) { Write-Output "dry-run: keep existing $commandDest (matches template)" }
    else { Write-Output "dry-run: write $commandDest from $template" }
    if (Test-Path -LiteralPath $agentsMdDest) { Write-Output "dry-run: keep existing $agentsMdDest" }
    elseif (Test-Path -LiteralPath $agentsMdTemplate) { Write-Output "dry-run: write $agentsMdDest from $agentsMdTemplate" }
    Write-Output "dry-run: gitignore .b3/autodev/ (see Update-B3Gitignore)"
    if ($HostName -eq 'codex') { Write-Output "dry-run: gitignore .agents/skills" }
    if ($HostName -eq 'claude') { Write-Output "dry-run: gitignore .claude/skills" }
    Get-ChildItem -LiteralPath $b3Commands -Filter '*.md' -File | ForEach-Object {
        if ($_.Name -eq 'README.md') { return }
        $dest = Join-Path (Join-Path $ProductRoot '.cursor\commands') $_.Name
        if ($_.Name -eq 'autodev.md') { return }
        if (-not (Test-Path -LiteralPath $dest)) { Write-Output "dry-run: copy command $($_.Name)" }
    }
    if ($HostName -eq 'cursor' -and (Test-Path -LiteralPath $cursorReadmeTemplate)) {
        Write-Output "dry-run: write $cursorReadmeDest"
    }
    if ($HostName -eq 'codex') { Write-Output "dry-run: flatten $linkDest (one junction per skill + command skills)" }
    elseif ($linkDest) { Write-Output "dry-run: junction $linkDest -> $skills" }
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
if ((-not (Test-Path -LiteralPath $agentsMdDest)) -and (Test-Path -LiteralPath $agentsMdTemplate)) {
    Copy-Item -LiteralPath $agentsMdTemplate -Destination $agentsMdDest
}

if (Test-Path -LiteralPath $b3Commands) {
    $cmdDir = Join-Path $ProductRoot '.cursor\commands'
    foreach ($src in Get-ChildItem -LiteralPath $b3Commands -Filter '*.md' -File) {
        if ($src.Name -in @('README.md', 'autodev.md')) { continue }
        $dest = Join-Path $cmdDir $src.Name
        if (-not (Test-Path -LiteralPath $dest)) {
            Copy-Item -LiteralPath $src.FullName -Destination $dest
        }
    }
    if ($HostName -eq 'cursor' -and (Test-Path -LiteralPath $cursorReadmeTemplate)) {
        Copy-Item -LiteralPath $cursorReadmeTemplate -Destination $cursorReadmeDest -Force
    }
}

if ($HostName -eq 'codex') {
    Install-CodexSkillIndex $agentsDest $skills $commandSkillsSrc
} elseif ($linkDest) {
    if (-not (Test-Path -LiteralPath $linkDest)) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $linkDest) -Force | Out-Null
        New-Item -ItemType Junction -Path $linkDest -Target $skills | Out-Null
    } else {
        $item = Get-Item -LiteralPath $linkDest -Force
        $ok = $item.LinkType -in @('Junction', 'SymbolicLink') -and (Test-LinkTarget $linkDest $skills)
        if (-not $ok) { Fail "refusing to replace existing $linkDest" }
    }
}

Write-Output "installed B3 pointer in $ProductRoot"
Write-Output "B3_HOME=$B3Home"
Write-Output "command=$commandDest"
Write-Output "agents.md=$agentsMdDest"
Write-Output "gitignore.b3=$ignorePlan"
Write-Output "gitignore.skills=$skillIgnorePlan"
Write-Output "host=$HostName"
if ($HostName -eq 'codex') {
    Write-Output "skills=$agentsDest (flattened junctions + `$autodev; gitignored, not copied)"
} elseif ($HostName -eq 'claude') {
    Write-Output "skills=$claudeDest -> $skills (gitignored local link, not copied)"
} else {
    Write-Output "skills=user-level ~/.cursor/skills/b3-ai-engineering -> $skills (not copied into product)"
}
Write-Output "note: this proves files were written, not host slash-command or skill discovery"
