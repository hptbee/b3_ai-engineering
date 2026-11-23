param(
    [Parameter(Mandatory = $true)]
    [string]$ProductRoot,
    [string]$B3Home,
    [ValidateSet('cursor', 'codex', 'claude', 'antigravity')]
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
$workflow = Join-Path $B3Home 'workflows\ship.md'
$b3Commands = Join-Path $B3Home 'commands'
$template = Join-Path $b3Commands 'b3-ship.md'
$skills = Join-Path $B3Home 'skills'
$b3Agents = Join-Path $B3Home 'agents'
$commandSkillsSrc = Join-Path $B3Home 'adapters\command-skills'

if (-not (Test-Path -LiteralPath $workflow)) { Fail "B3_HOME missing workflow: $workflow" }
if (-not (Test-Path -LiteralPath $template)) { Fail "missing template: $template" }
if (@(Get-ChildItem -LiteralPath $skills -Recurse -Filter 'SKILL.md' -File -ErrorAction SilentlyContinue).Count -lt 1) {
    Fail "B3_HOME has no SKILL.md under skills: $skills"
}

$productSkills = Join-Path $ProductRoot '.cursor\skills'
$commandDest = Join-Path $ProductRoot '.cursor\commands\b3-ship.md'
$homeDest = Join-Path $ProductRoot '.b3\home'
$agentsDest = Join-Path $ProductRoot '.agents\skills'
$claudeSkillsDest = Join-Path $ProductRoot '.claude\skills'
$claudeAgentsDest = Join-Path $ProductRoot '.claude\agents'
$claudeMdDest = Join-Path $ProductRoot 'CLAUDE.md'

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
    if (Test-Path -LiteralPath $claudeSkillsDest) {
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
        $item = Get-Item -LiteralPath $LinkPath -Force
        $expectedFull = [IO.Path]::GetFullPath($Expected).TrimEnd('\')
        $candidate = $null
        if ($item.Target) {
            $raw = [string](@($item.Target)[0])
            if (-not [IO.Path]::IsPathRooted($raw)) {
                $raw = Join-Path (Split-Path -Parent $LinkPath) $raw
            }
            $candidate = [IO.Path]::GetFullPath($raw).TrimEnd('\')
        }
        if (-not $candidate) {
            $candidate = (Resolve-Path -LiteralPath $LinkPath).Path.TrimEnd('\')
        }
        return $candidate -eq $expectedFull
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

function Install-FlatSkillIndex([string]$DestRoot, [string]$SkillsSrc, [string]$CmdSkillsSrc) {
    if (Test-Path -LiteralPath $DestRoot) {
        $item = Get-Item -LiteralPath $DestRoot -Force
        if ($item.LinkType -in @('Junction', 'SymbolicLink')) {
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
    if (Test-Path -LiteralPath $CmdSkillsSrc) {
        Get-ChildItem -LiteralPath $CmdSkillsSrc -Directory | ForEach-Object {
            if (-not (Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md'))) { return }
            Install-SkillJunction (Join-Path $DestRoot $_.Name) $_.FullName
        }
    }
}

function Update-B3Gitignore([string]$Root) {
    $gi = Join-Path $Root '.gitignore'
    $block = @"

# B3: commit .b3/home; keep ship checkpoints and local model overrides private
.b3/ship/
.b3/models.local.json
"@
    if (-not (Test-Path -LiteralPath $gi)) {
        Set-Content -LiteralPath $gi -Value ($block.TrimStart() + "`n")
        return 'created'
    }
    $text = Get-Content -LiteralPath $gi -Raw
    $hasShip = ($text -match '(?m)^\s*\.b3/ship/\s*$')
    $hasModels = ($text -match '(?m)^\s*\.b3/models\.local\.json\s*$')
    if ($hasShip -and $hasModels) { return 'present' }
    if ($text -match '(?m)^\s*\.b3/\s*$') {
        $text = [regex]::Replace($text, '(?m)^\s*\.b3/\s*$', ".b3/ship/`n.b3/models.local.json")
        Set-Content -LiteralPath $gi -Value $text -NoNewline
        return 'upgraded'
    }
    if ($hasShip) {
        Add-Content -LiteralPath $gi -Value "`n.b3/models.local.json"
        return 'upgraded'
    }
    Add-Content -LiteralPath $gi -Value $block
    return 'appended'
}

function Initialize-PersonalModelConfig([string]$HomeDir, [switch]$IsDryRun) {
    if ($env:B3_SKIP_MODEL_INIT -eq '1') { return 'skipped' }
    $templateCfg = Join-Path $HomeDir 'config\models.default.json'
    if (-not (Test-Path -LiteralPath $templateCfg -PathType Leaf)) { return 'no-template' }
    $dest = if ($env:B3_MODELS_PERSONAL -and $env:B3_MODELS_PERSONAL.Trim()) {
        $env:B3_MODELS_PERSONAL.Trim()
    } else {
        $uHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
        Join-Path $uHome '.b3\models.local.json'
    }
    if (Test-Path -LiteralPath $dest) {
        if ($IsDryRun) { Write-Output "dry-run: keep existing personal model config $dest" }
        return "kept:$dest"
    }
    if ($IsDryRun) {
        Write-Output "dry-run: seed personal model config at $dest from $templateCfg"
        return "dry-run:$dest"
    }
    $parent = Split-Path -Parent $dest
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Copy-Item -LiteralPath $templateCfg -Destination $dest
    return "created:$dest"
}

function Update-HostSkillGitignore([string]$Root, [string]$HostName) {
    $lines = @()
    if ($HostName -in @('codex', 'antigravity')) { $lines = @('.agents/skills') }
    if ($HostName -eq 'claude') { $lines = @('.claude/skills', '.claude/agents') }
    if ($lines.Count -eq 0) { return 'n/a' }

    $gi = Join-Path $Root '.gitignore'
    if (-not (Test-Path -LiteralPath $gi)) {
        Set-Content -LiteralPath $gi -Value ("# B3: local host links (do not commit)`n" + ($lines -join "`n") + "`n")
        return 'created'
    }
    $text = Get-Content -LiteralPath $gi -Raw
    $missing = @()
    foreach ($line in $lines) {
        $escaped = [regex]::Escape($line)
        if ($text -notmatch "(?m)^\s*$escaped\s*$") { $missing += $line }
    }
    if ($missing.Count -eq 0) { return 'present' }
    Add-Content -LiteralPath $gi -Value ("`n# B3: local host links (do not commit)`n" + ($missing -join "`n"))
    return 'appended'
}

$cursorReadmeTemplate = Join-Path $scriptRoot 'product-cursor-readme.md'
$agentsMdTemplate = Join-Path $scriptRoot 'product-agents.md'
$claudeMdTemplate = Join-Path $scriptRoot 'product-claude.md'
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
    if ($HostName -eq 'claude') {
        if (Test-Path -LiteralPath $claudeMdDest) { Write-Output "dry-run: keep existing $claudeMdDest" }
        elseif (Test-Path -LiteralPath $claudeMdTemplate) { Write-Output "dry-run: write $claudeMdDest from $claudeMdTemplate" }
    }
    Write-Output "dry-run: gitignore .b3/ship/ and .b3/models.local.json (see Update-B3Gitignore)"
    if ($HostName -in @('codex', 'antigravity')) { Write-Output "dry-run: gitignore .agents/skills" }
    if ($HostName -eq 'claude') { Write-Output "dry-run: gitignore .claude/skills and .claude/agents" }
    if (Test-Path -LiteralPath $b3Commands) {
        Get-ChildItem -LiteralPath $b3Commands -Filter '*.md' -File | ForEach-Object {
            if ($_.Name -in @('README.md', 'b3-ship.md')) { return }
            $dest = Join-Path (Join-Path $ProductRoot '.cursor\commands') $_.Name
            if (-not (Test-Path -LiteralPath $dest)) { Write-Output "dry-run: copy command $($_.Name)" }
        }
    }
    if ($HostName -eq 'cursor' -and (Test-Path -LiteralPath $cursorReadmeTemplate)) {
        Write-Output "dry-run: write $cursorReadmeDest"
    }
    if ($HostName -in @('codex', 'antigravity')) {
        Write-Output "dry-run: flatten $agentsDest (one junction per skill + command skills)"
    } elseif ($HostName -eq 'claude') {
        Write-Output "dry-run: flatten $claudeSkillsDest (one junction per skill + command skills)"
        Write-Output "dry-run: junction $claudeAgentsDest -> $b3Agents"
    }
    [void](Initialize-PersonalModelConfig $B3Home -IsDryRun)
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
if ($HostName -eq 'claude' -and (-not (Test-Path -LiteralPath $claudeMdDest)) -and (Test-Path -LiteralPath $claudeMdTemplate)) {
    Copy-Item -LiteralPath $claudeMdTemplate -Destination $claudeMdDest
}

if (Test-Path -LiteralPath $b3Commands) {
    $cmdDir = Join-Path $ProductRoot '.cursor\commands'
    foreach ($src in Get-ChildItem -LiteralPath $b3Commands -Filter '*.md' -File) {
        if ($src.Name -in @('README.md', 'b3-ship.md')) { continue }
        $dest = Join-Path $cmdDir $src.Name
        if (-not (Test-Path -LiteralPath $dest)) {
            Copy-Item -LiteralPath $src.FullName -Destination $dest
        }
    }
    if ($HostName -eq 'cursor' -and (Test-Path -LiteralPath $cursorReadmeTemplate)) {
        Copy-Item -LiteralPath $cursorReadmeTemplate -Destination $cursorReadmeDest -Force
    }
}

if ($HostName -in @('codex', 'antigravity')) {
    Install-FlatSkillIndex $agentsDest $skills $commandSkillsSrc
} elseif ($HostName -eq 'claude') {
    Install-FlatSkillIndex $claudeSkillsDest $skills $commandSkillsSrc
    if (Test-Path -LiteralPath $b3Agents -PathType Container) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $claudeAgentsDest) -Force | Out-Null
        Install-SkillJunction $claudeAgentsDest $b3Agents
    }
}

$modelCfgStatus = Initialize-PersonalModelConfig $B3Home

Write-Output "installed B3 pointer in $ProductRoot"
Write-Output "B3_HOME=$B3Home"
Write-Output "command=$commandDest"
Write-Output "agents.md=$agentsMdDest"
if ($HostName -eq 'claude') { Write-Output "claude.md=$claudeMdDest" }
Write-Output "gitignore.b3=$ignorePlan"
Write-Output "gitignore.skills=$skillIgnorePlan"
Write-Output "model_config=$modelCfgStatus"
Write-Output "host=$HostName"
if ($HostName -eq 'codex') {
    Write-Output "skills=$agentsDest (flattened junctions + `$b3-ship; gitignored, not copied)"
} elseif ($HostName -eq 'antigravity') {
    Write-Output "skills=$agentsDest (flattened junctions + command skills; gitignored, not copied; use adapters/antigravity/install-plugin.ps1 if Cursor also opens this repo)"
} elseif ($HostName -eq 'claude') {
    Write-Output "skills=$claudeSkillsDest (flattened junctions + command skills) + $claudeAgentsDest -> $b3Agents (gitignored, not copied)"
} else {
    Write-Output "skills=user-level ~/.cursor/skills/b3-ai-engineering -> $skills (not copied into product)"
}
Write-Output "note: this proves files were written, not host slash-command or skill discovery"
