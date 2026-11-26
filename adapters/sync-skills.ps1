param(
    [ValidateSet('cursor', 'codex', 'claude', 'antigravity')]
    [string]$HostName,
    [switch]$DryRun,
    [switch]$VerifyOnly,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$skillsSource = Join-Path $root 'skills'
$commandsSource = Join-Path $root 'commands'
$agentsSource = Join-Path $root 'agents'
$commandSkillsSource = Join-Path $root 'adapters\command-skills'

$commonLib = Join-Path $PSScriptRoot 'lib\global-common.ps1'
if (Test-Path -LiteralPath $commonLib -PathType Leaf) {
    . $commonLib
}

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

function Initialize-PersonalModelPreferences([string]$HomeDir) {
    if ($DryRun -or $VerifyOnly -or $env:B3_SKIP_MODEL_INIT -eq '1') { return }
    if (Get-Command Initialize-PersonalModelsFile -ErrorAction SilentlyContinue) {
        $status = Initialize-PersonalModelsFile -B3Home $HomeDir -NonFatal
        if ($status -like 'kept:*') {
            Write-Output "model_preferences=$($status.Substring(5)) (kept existing)"
        } elseif ($status -like 'created:*') {
            Write-Output "model_preferences=$($status.Substring(8)) (created from example)"
        } elseif ($status -like 'error:*') {
            Write-Output "model_preferences=$status"
        }
        return
    }
    $templateMd = Join-Path $HomeDir 'config\models.example.md'
    if (-not (Test-Path -LiteralPath $templateMd -PathType Leaf)) { return }
    $dest = if ($env:B3_MODELS_PERSONAL -and $env:B3_MODELS_PERSONAL.Trim()) {
        $env:B3_MODELS_PERSONAL.Trim()
    } else {
        $uHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
        Join-Path $uHome '.b3\models.md'
    }
    if (Test-Path -LiteralPath $dest) {
        Write-Output "model_preferences=$dest (kept existing)"
        return
    }
    try {
        $parent = Split-Path -Parent $dest
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Copy-Item -LiteralPath $templateMd -Destination $dest
        Write-Output "model_preferences=$dest (created from example)"
    } catch {
        Write-Warning "optional model preferences could not be initialized at $dest : $($_.Exception.Message)"
        Write-Output "model_preferences=error:$dest"
    }
}

function Test-IsLink([System.IO.FileSystemInfo]$Item) {
    return ($Item.LinkType -in @('Junction', 'SymbolicLink')) -or (($Item.Attributes.ToString()) -match 'ReparsePoint')
}

function Test-HasActivePath([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    if (Test-IsLink $item) { return $true }
    if ($item.PSIsContainer) {
        return @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue).Count -gt 0
    }
    return $true
}

function Test-SkillSource([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    return @(Get-ChildItem -LiteralPath $Path -Recurse -Filter 'SKILL.md' -File -ErrorAction SilentlyContinue).Count -gt 0
}

function Get-SkillNameFromFile([string]$Path) {
    $text = Get-Content -LiteralPath $Path -Raw
    if ($text -match '(?m)^name:\s*([a-z0-9-]+)\s*$') { return $Matches[1] }
    return (Split-Path -Leaf (Split-Path -Parent $Path))
}

function Get-ExpectedFlatSkills() {
    $map = @{}
    $list = @()
    $files = @(Get-ChildItem -LiteralPath $skillsSource -Recurse -Filter 'SKILL.md' -File | Sort-Object FullName)
    if (Test-Path -LiteralPath $commandSkillsSource -PathType Container) {
        $files += @(Get-ChildItem -LiteralPath $commandSkillsSource -Recurse -Filter 'SKILL.md' -File | Sort-Object FullName)
    }
    foreach ($f in $files) {
        $name = Get-SkillNameFromFile $f.FullName
        $srcDir = Split-Path -Parent $f.FullName
        if ($map.ContainsKey($name)) {
            Fail "duplicate skill name '$name': $($map[$name]) and $srcDir"
        }
        $map[$name] = $srcDir
        $list += [PSCustomObject]@{ Name = $name; Source = $srcDir }
    }
    return $list
}

function Test-LinkTarget([string]$Dest, [string]$Src) {
    if (-not (Test-Path -LiteralPath $Dest)) { return $false }
    $item = Get-Item -LiteralPath $Dest -Force
    if (-not (Test-IsLink $item)) { return $false }
    $resolvedSrc = [IO.Path]::GetFullPath($Src).TrimEnd('\')
    $candidate = $null
    if ($item.Target) {
        $raw = [string](@($item.Target)[0])
        if (-not [IO.Path]::IsPathRooted($raw)) {
            $raw = Join-Path (Split-Path -Parent $Dest) $raw
        }
        $candidate = [IO.Path]::GetFullPath($raw).TrimEnd('\')
    }
    if (-not $candidate) {
        try { $candidate = (Resolve-Path -LiteralPath $Dest).Path.TrimEnd('\') } catch { $candidate = $null }
    }
    return $candidate -eq $resolvedSrc
}

function Remove-LinkPath([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return }
    if (-not (Test-IsLink $item)) { Fail "refusing to remove non-link path: $Path" }
    try {
        if ($item.PSIsContainer -and ($env:OS -eq 'Windows_NT')) {
            [System.IO.Directory]::Delete($Path, $false)
        } else {
            Remove-Item -LiteralPath $Path -Force
        }
    } catch {
        Fail "could not remove link $Path : $($_.Exception.Message)"
    }
    if ($null -ne (Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
        Fail "could not remove link $Path"
    }
}

function Sync-DirectoryLink([string]$Dest, [string]$Src, [string]$Label) {
    if (Test-Path -LiteralPath $Dest) {
        $item = Get-Item -LiteralPath $Dest -Force
        if (Test-IsLink $item) {
            if (Test-LinkTarget $Dest $Src) {
                Write-Output "ok: $Dest already links to $Src ($Label)"
                return
            }
            Fail "existing link $Dest does not resolve to $Src"
        }
        $children = @(Get-ChildItem -LiteralPath $Dest -Force -ErrorAction SilentlyContinue)
        if ($children.Count -eq 0) {
            if ($DryRun) {
                Write-Output "dry-run: remove empty directory $Dest then junction to $Src"
                return
            }
            try {
                Remove-Item -LiteralPath $Dest -Force
            } catch {
                Fail "cannot remove empty directory $Dest : $($_.Exception.Message)"
            }
        } else {
            Fail "existing non-link path with content; refusing to replace: $Dest"
        }
    }

    if ($DryRun) {
        Write-Output "dry-run: junction $Dest -> $Src"
        return
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $Dest) -Force | Out-Null
    try {
        New-Item -ItemType Junction -Path $Dest -Target $Src | Out-Null
    } catch {
        Fail "failed to create junction $Dest -> $Src : $($_.Exception.Message)"
    }
    if (-not (Test-LinkTarget $Dest $Src)) {
        Fail "link created but verification failed: $Dest -> $Src"
    }
    Write-Output "linked: $Dest -> $Src ($Label)"
}

function Test-FlatSkillIndex([string]$DestRoot, [object[]]$ExpectedSkills) {
    if (-not (Test-Path -LiteralPath $DestRoot -PathType Container)) { return $false }
    $rootItem = Get-Item -LiteralPath $DestRoot -Force
    if (Test-IsLink $rootItem) { return $false }
    foreach ($sk in $ExpectedSkills) {
        $entryDest = Join-Path $DestRoot $sk.Name
        if (-not (Test-LinkTarget $entryDest $sk.Source)) { return $false }
        if (-not (Test-Path -LiteralPath (Join-Path $entryDest 'SKILL.md') -PathType Leaf)) { return $false }
    }
    return $true
}

function Sync-FlatSkillIndex([string]$DestRoot, [object[]]$ExpectedSkills, [string]$Label) {
    if (Test-Path -LiteralPath $DestRoot) {
        $item = Get-Item -LiteralPath $DestRoot -Force
        if (Test-IsLink $item) {
            if ($DryRun) {
                Write-Output "dry-run: replace legacy nested link $DestRoot with flattened $($ExpectedSkills.Count)-skill index ($Label)"
                return
            }
            Remove-LinkPath $DestRoot
        } elseif (-not $item.PSIsContainer) {
            Fail "existing non-directory path; refusing to replace: $DestRoot"
        } else {
            foreach ($child in @(Get-ChildItem -LiteralPath $DestRoot -Force -ErrorAction SilentlyContinue)) {
                if (-not (Test-IsLink $child)) {
                    Fail "existing non-link content in $DestRoot; refusing to replace: $($child.FullName)"
                }
            }
        }
    }

    if ($DryRun) {
        Write-Output "dry-run: flatten $DestRoot with $($ExpectedSkills.Count) skill junctions ($Label)"
        return
    }

    New-Item -ItemType Directory -Path $DestRoot -Force | Out-Null
    $expectedNames = @{}
    foreach ($sk in $ExpectedSkills) {
        $expectedNames[$sk.Name] = $true
        $entryDest = Join-Path $DestRoot $sk.Name
        if (Test-Path -LiteralPath $entryDest) {
            if (Test-LinkTarget $entryDest $sk.Source) { continue }
            Remove-LinkPath $entryDest
        }
        try {
            New-Item -ItemType Junction -Path $entryDest -Target $sk.Source | Out-Null
        } catch {
            Fail "failed to create junction $entryDest -> $($sk.Source) : $($_.Exception.Message)"
        }
    }
    foreach ($child in @(Get-ChildItem -LiteralPath $DestRoot -Force -ErrorAction SilentlyContinue)) {
        if (-not $expectedNames.ContainsKey($child.Name)) {
            Remove-LinkPath $child.FullName
        }
    }
    if (-not (Test-FlatSkillIndex $DestRoot $ExpectedSkills)) {
        Fail "flattened skill index verification failed: $DestRoot"
    }
    Write-Output "linked: $DestRoot ($($ExpectedSkills.Count) flattened skills; $Label)"
}

function Get-AntigravityEntryPaths([string]$RepoRoot) {
    $entries = New-Object System.Collections.Generic.List[string]
    $coreSkills = Join-Path $RepoRoot 'skills'
    if (Test-Path -LiteralPath $coreSkills -PathType Container) {
        foreach ($cat in @(Get-ChildItem -LiteralPath $coreSkills -Directory | Sort-Object Name)) {
            $hasOneLevel = $false
            foreach ($skillDir in @(Get-ChildItem -LiteralPath $cat.FullName -Directory)) {
                if (Test-Path -LiteralPath (Join-Path $skillDir.FullName 'SKILL.md') -PathType Leaf) {
                    $hasOneLevel = $true
                    break
                }
            }
            if ($hasOneLevel) { $entries.Add("skills/$($cat.Name)") }
        }
    }
    $cmdSkills = Join-Path $RepoRoot 'adapters\command-skills'
    if (Test-Path -LiteralPath $cmdSkills -PathType Container) {
        foreach ($skillDir in @(Get-ChildItem -LiteralPath $cmdSkills -Directory)) {
            if (Test-Path -LiteralPath (Join-Path $skillDir.FullName 'SKILL.md') -PathType Leaf) {
                $entries.Add('adapters/command-skills')
                break
            }
        }
    }
    return @($entries)
}

function Test-AntigravityManifest([string]$RepoRoot, [string]$ManifestPath) {
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        return [PSCustomObject]@{ Ok = $false; Count = 0; Reason = "missing manifest: $ManifestPath" }
    }
    try {
        $parsed = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    } catch {
        return [PSCustomObject]@{ Ok = $false; Count = 0; Reason = "invalid JSON in $ManifestPath" }
    }
    if (-not $parsed.entries -or @($parsed.entries).Count -lt 1) {
        return [PSCustomObject]@{ Ok = $false; Count = 0; Reason = "manifest has no entries: $ManifestPath" }
    }

    $manifestPaths = New-Object System.Collections.Generic.List[string]
    $totalSkills = 0
    $seenNames = @{}
    foreach ($entry in @($parsed.entries)) {
        $relPath = [string]$entry.path
        if (-not $relPath) {
            return [PSCustomObject]@{ Ok = $false; Count = 0; Reason = "manifest entry missing path" }
        }
        $manifestPaths.Add($relPath)
        $resolved = Join-Path $RepoRoot ($relPath -replace '/', '\')
        if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
            return [PSCustomObject]@{ Ok = $false; Count = 0; Reason = "manifest entry path not found: $relPath" }
        }
        $entryCount = 0
        foreach ($skillDir in @(Get-ChildItem -LiteralPath $resolved -Directory)) {
            $skillFile = Join-Path $skillDir.FullName 'SKILL.md'
            if (Test-Path -LiteralPath $skillFile -PathType Leaf) {
                $raw = Get-Content -LiteralPath $skillFile -Raw
                if ($raw -notmatch '(?m)^name:\s*([a-z0-9-]+)\s*$') {
                    return [PSCustomObject]@{ Ok = $false; Count = 0; Reason = "SKILL.md missing valid name: $skillFile" }
                }
                $fmName = $Matches[1]
                if ($fmName -ne $skillDir.Name) {
                    return [PSCustomObject]@{ Ok = $false; Count = 0; Reason = "skill folder '$($skillDir.Name)' does not match frontmatter name '$fmName'" }
                }
                if ($seenNames.ContainsKey($fmName)) {
                    return [PSCustomObject]@{ Ok = $false; Count = 0; Reason = "duplicate skill name '$fmName'" }
                }
                $seenNames[$fmName] = $true
                $entryCount++
                $totalSkills++
            }
        }
        if ($entryCount -lt 1) {
            return [PSCustomObject]@{ Ok = $false; Count = 0; Reason = "manifest entry has no 1-level SKILL.md: $relPath" }
        }
    }

    foreach ($expected in (Get-AntigravityEntryPaths $RepoRoot)) {
        if ($manifestPaths -notcontains $expected) {
            return [PSCustomObject]@{ Ok = $false; Count = 0; Reason = "manifest missing expected entry: $expected" }
        }
    }
    if ($totalSkills -lt 1) {
        return [PSCustomObject]@{ Ok = $false; Count = 0; Reason = "manifest resolved 0 skills" }
    }
    return [PSCustomObject]@{ Ok = $true; Count = $totalSkills; Reason = '' }
}

if (-not $HostName) { Fail 'Usage: .\adapters\sync-skills.ps1 -HostName cursor|codex|claude|antigravity [-DryRun] [-VerifyOnly] [-Force]' }
if (-not (Test-SkillSource $skillsSource)) { Fail "Skills source missing or has no SKILL.md: $skillsSource" }

$cursorSkillsDest = Join-Path $root '.cursor\skills'
$cursorCommandsDest = Join-Path $root '.cursor\commands'
$cursorAgentsDest = Join-Path $root '.cursor\agents'
$codexSkillsDest = Join-Path $root '.agents\skills'
$claudeSkillsDest = Join-Path $root '.claude\skills'
$claudeAgentsDest = Join-Path $root '.claude\agents'
$antigravityManifest = Join-Path $root '.agents\skills.json'

if ($HostName -eq 'antigravity') {
    if (Test-HasActivePath $codexSkillsDest) {
        Write-Warning "coexistence notice: .agents/skills exists alongside .agents/skills.json; Antigravity may double-discover skills."
    }
    if ($VerifyOnly) {
        $check = Test-AntigravityManifest $root $antigravityManifest
        if ($check.Ok) {
            Write-Output "verify ok: $antigravityManifest (antigravity); $($check.Count) SKILL.md entries visible"
            exit 0
        }
        Fail "verify failed: $($check.Reason)"
    }

    $entries = @(Get-AntigravityEntryPaths $root)
    if ($entries.Count -lt 1) { Fail "no 1-level skill category directories found under $skillsSource" }
    $jsonLines = New-Object System.Collections.Generic.List[string]
    $jsonLines.Add('{')
    $jsonLines.Add('  "entries": [')
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $comma = if ($i -lt ($entries.Count - 1)) { ',' } else { '' }
        $jsonLines.Add("    { `"path`": `"$($entries[$i])`" }$comma")
    }
    $jsonLines.Add('  ]')
    $jsonLines.Add('}')
    $jsonText = ($jsonLines -join "`n") + "`n"

    if ($DryRun) {
        Write-Output "dry-run: write $antigravityManifest with $($entries.Count) entries ($($entries -join ', '))"
        exit 0
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $antigravityManifest) -Force | Out-Null
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($antigravityManifest, $jsonText, $utf8NoBom)

    $check = Test-AntigravityManifest $root $antigravityManifest
    if (-not $check.Ok) { Fail "manifest written but verification failed: $($check.Reason)" }
    Initialize-PersonalModelPreferences $root
    Write-Output "synced: $antigravityManifest (antigravity); $($check.Count) SKILL.md entries visible"
    Write-Output "note: this proves .agents/skills.json resolves to 1-level SKILL.md entries, not Antigravity runtime discovery"
    exit 0
}

if ($HostName -eq 'cursor') {
    if (-not (Test-Path -LiteralPath $commandsSource -PathType Container)) { Fail "Commands source missing: $commandsSource" }
    if (-not (Test-Path -LiteralPath $agentsSource -PathType Container)) { Fail "Agents source missing: $agentsSource" }

    if ($VerifyOnly) {
        $ok = (Test-LinkTarget $cursorSkillsDest $skillsSource) -and
              (Test-SkillSource $cursorSkillsDest) -and
              (Test-LinkTarget $cursorCommandsDest $commandsSource) -and
              (Test-LinkTarget $cursorAgentsDest $agentsSource)
        if ($ok) {
            Write-Output "verify ok: .cursor/{skills,commands,agents} -> canonical root (cursor)"
            exit 0
        }
        Fail "verify failed: .cursor/{skills,commands,agents} links are missing or invalid"
    }

    if (-not $Force) {
        if (Test-HasActivePath $codexSkillsDest) {
            Fail "coexistence guard: .agents/skills exists; Cursor cross-loads it and would duplicate skills. Remove .agents/skills or re-run with -Force"
        }
        if (Test-HasActivePath $claudeSkillsDest) {
            Fail "coexistence guard: .claude/skills exists; Cursor cross-loads it and would duplicate skills. Remove .claude/skills or re-run with -Force"
        }
    }

    Sync-DirectoryLink $cursorSkillsDest $skillsSource 'cursor skills'
    Sync-DirectoryLink $cursorCommandsDest $commandsSource 'cursor commands'
    Sync-DirectoryLink $cursorAgentsDest $agentsSource 'cursor agents'
    Initialize-PersonalModelPreferences $root
    Write-Output "note: this proves filesystem links, not Cursor runtime skill discovery"
    exit 0
}

$expectedFlatSkills = @(Get-ExpectedFlatSkills)

if ($HostName -eq 'codex') {
    if ($VerifyOnly) {
        if (Test-FlatSkillIndex $codexSkillsDest $expectedFlatSkills) {
            Write-Output "verify ok: $codexSkillsDest ($($expectedFlatSkills.Count) flattened skills; codex)"
            exit 0
        }
        Fail "verify failed: $codexSkillsDest is not a valid flattened skill index"
    }

    if (-not $Force -and (Test-HasActivePath $cursorSkillsDest)) {
        Fail "coexistence guard: .cursor/skills exists; Cursor cross-loads .agents/skills and would duplicate skills. Remove .cursor/skills or re-run with -Force"
    }
    if (Test-Path -LiteralPath $antigravityManifest -PathType Leaf) {
        Write-Warning "coexistence notice: .agents/skills.json is committed for Antigravity; if Antigravity also opens this checkout, it may read both .agents/skills.json and .agents/skills."
    }

    Sync-FlatSkillIndex $codexSkillsDest $expectedFlatSkills 'codex'
    Initialize-PersonalModelPreferences $root
    Write-Output "note: this proves filesystem links, not Codex runtime skill discovery"
    exit 0
}

if ($HostName -eq 'claude') {
    if (-not (Test-Path -LiteralPath $agentsSource -PathType Container)) { Fail "Agents source missing: $agentsSource" }

    if ($VerifyOnly) {
        $ok = (Test-FlatSkillIndex $claudeSkillsDest $expectedFlatSkills) -and
              (Test-LinkTarget $claudeAgentsDest $agentsSource)
        if ($ok) {
            Write-Output "verify ok: $claudeSkillsDest ($($expectedFlatSkills.Count) flattened skills) + $claudeAgentsDest -> $agentsSource (claude)"
            exit 0
        }
        Fail "verify failed: .claude/skills or .claude/agents link is missing or invalid"
    }

    if (-not $Force -and (Test-HasActivePath $cursorSkillsDest)) {
        Fail "coexistence guard: .cursor/skills exists; Cursor cross-loads .claude/skills and would duplicate skills. Remove .cursor/skills or re-run with -Force"
    }

    Sync-FlatSkillIndex $claudeSkillsDest $expectedFlatSkills 'claude'
    Sync-DirectoryLink $claudeAgentsDest $agentsSource 'claude agents'
    Initialize-PersonalModelPreferences $root
    Write-Output "note: this proves filesystem links, not Claude Code runtime skill discovery"
    exit 0
}
