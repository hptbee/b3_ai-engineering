param(
    [ValidateSet('codex', 'claude')]
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

if (-not $HostName) { Fail 'Usage: .\adapters\sync-skills.ps1 -HostName codex|claude [-DryRun] [-VerifyOnly]' }
if (-not (Test-SkillSource $source)) { Fail "Skills source missing or has no SKILL.md: $source" }

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
