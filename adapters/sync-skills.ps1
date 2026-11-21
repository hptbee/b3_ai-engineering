param(
    [ValidateSet('codex', 'claude', 'antigravity')]
    [string]$HostName,
    [switch]$DryRun,
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $root '.cursor\skills'
$destination = if ($HostName -eq 'codex') { Join-Path $root '.agents\skills' } else { Join-Path $root '.claude\skills' }

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

function Test-SkillSource([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $false
    }
    return @(Get-ChildItem -LiteralPath $Path -Recurse -Filter 'SKILL.md' -File -ErrorAction SilentlyContinue).Count -gt 0
}

function Test-LinkOk([string]$Dest, [string]$Src) {
    if (-not (Test-Path -LiteralPath $Dest)) { return $false }
    $item = Get-Item -LiteralPath $Dest -Force
    $isLink = $item.LinkType -in @('Junction', 'SymbolicLink') -or
        (($item.Attributes.ToString()) -match 'ReparsePoint')
    if (-not $isLink) { return $false }
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
    if ($candidate -ne $resolvedSrc) { return $false }
    return (Test-SkillSource $Dest)
}

function Get-AntigravityEntryPaths([string]$RepoRoot) {
    $entries = New-Object System.Collections.Generic.List[string]
    $cursorSkills = Join-Path $RepoRoot '.cursor\skills'
    if (Test-Path -LiteralPath $cursorSkills -PathType Container) {
        foreach ($cat in @(Get-ChildItem -LiteralPath $cursorSkills -Directory | Sort-Object Name)) {
            $hasOneLevel = $false
            foreach ($skillDir in @(Get-ChildItem -LiteralPath $cat.FullName -Directory)) {
                if (Test-Path -LiteralPath (Join-Path $skillDir.FullName 'SKILL.md') -PathType Leaf) {
                    $hasOneLevel = $true
                    break
                }
            }
            if ($hasOneLevel) {
                $entries.Add(".cursor/skills/$($cat.Name)")
            }
        }
    }
    $cmdSkills = Join-Path $RepoRoot 'adapters\codex-command-skills'
    if (Test-Path -LiteralPath $cmdSkills -PathType Container) {
        foreach ($skillDir in @(Get-ChildItem -LiteralPath $cmdSkills -Directory)) {
            if (Test-Path -LiteralPath (Join-Path $skillDir.FullName 'SKILL.md') -PathType Leaf) {
                $entries.Add('adapters/codex-command-skills')
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

if (-not $HostName) { Fail 'Usage: .\adapters\sync-skills.ps1 -HostName codex|claude|antigravity [-DryRun] [-VerifyOnly]' }
if (-not (Test-SkillSource $source)) { Fail "Skills source missing or has no SKILL.md: $source" }

if ($HostName -eq 'antigravity') {
    $manifest = Join-Path $root '.agents\skills.json'
    if ($VerifyOnly) {
        $check = Test-AntigravityManifest $root $manifest
        if ($check.Ok) {
            Write-Output "verify ok: $manifest (antigravity); $($check.Count) SKILL.md entries visible"
            exit 0
        }
        Fail "verify failed: $($check.Reason)"
    }

    $entries = @(Get-AntigravityEntryPaths $root)
    if ($entries.Count -lt 1) {
        Fail "no 1-level skill category directories found under $source"
    }
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
        Write-Output "dry-run: write $manifest with $($entries.Count) entries ($($entries -join ', '))"
        exit 0
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $manifest) -Force | Out-Null
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($manifest, $jsonText, $utf8NoBom)

    $check = Test-AntigravityManifest $root $manifest
    if (-not $check.Ok) {
        Fail "manifest written but verification failed: $($check.Reason)"
    }
    Write-Output "synced: $manifest (antigravity); $($check.Count) SKILL.md entries visible"
    Write-Output "note: this proves .agents/skills.json resolves to 1-level SKILL.md entries, not Antigravity runtime discovery"
    exit 0
}

if ($VerifyOnly) {
    if (Test-LinkOk $destination $source) {
        Write-Output "verify ok: $destination -> $source ($HostName); SKILL.md visible"
        exit 0
    }
    Fail "verify failed: $destination is not a working link to $source with SKILL.md files"
}

if (Test-Path -LiteralPath $destination) {
    $item = Get-Item -LiteralPath $destination -Force
    if ($item.LinkType -in @('Junction', 'SymbolicLink')) {
        if (Test-LinkOk $destination $source) {
            Write-Output "ok: $destination already links to canonical skills ($HostName)"
            exit 0
        }
        Fail "existing link $destination does not resolve to $source with SKILL.md"
    }

    $children = @(Get-ChildItem -LiteralPath $destination -Force -ErrorAction SilentlyContinue)
    if ($children.Count -eq 0) {
        if ($DryRun) {
            Write-Output "dry-run: remove empty directory $destination then junction to $source"
            exit 0
        }
        try {
            Remove-Item -LiteralPath $destination -Force
        } catch {
            Fail "cannot remove empty invalid directory $destination : $($_.Exception.Message)"
        }
    } else {
        Fail "existing non-link path with content; refusing to replace: $destination"
    }
}

if ($DryRun) {
    Write-Output "dry-run: New-Item -ItemType Junction -Path '$destination' -Target '$source'"
    exit 0
}

New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
try {
    New-Item -ItemType Junction -Path $destination -Target $source | Out-Null
} catch {
    Fail "failed to create junction $destination -> $source : $($_.Exception.Message)"
}

if (-not (Test-LinkOk $destination $source)) {
    Fail "link created but verification failed: $destination -> $source"
}

Write-Output "linked: $destination -> $source ($HostName); SKILL.md visible"
Write-Output "note: this proves the filesystem link, not Codex or Cursor skill discovery"
