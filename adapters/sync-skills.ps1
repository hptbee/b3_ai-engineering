param(
    [ValidateSet('codex', 'claude')]
    [string]$HostName,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $root '.cursor\skills'
$destination = if ($HostName -eq 'codex') { Join-Path $root '.agents\skills' } else { Join-Path $root '.claude\skills' }

if (-not $HostName) { throw 'Usage: .\adapters\sync-skills.ps1 -HostName codex|claude [-DryRun]' }
if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "Skills source not found: $source" }

if (Test-Path -LiteralPath $destination) {
    $item = Get-Item -LiteralPath $destination -Force
    if ($item.LinkType -eq 'Junction' -or $item.LinkType -eq 'SymbolicLink') {
        if ((Resolve-Path -LiteralPath $destination).Path -eq (Resolve-Path -LiteralPath $source).Path) {
            Write-Output "ok: $destination already links to canonical skills ($HostName)"
            exit 0
        }
    }
    Write-Warning "Existing non-matching path; skipping: $destination"
    exit 0
}

if ($DryRun) {
    Write-Output "dry-run: New-Item -ItemType Junction -Path '$destination' -Target '$source'"
    exit 0
}

New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
New-Item -ItemType Junction -Path $destination -Target $source | Out-Null
Write-Output "linked: $destination -> $source ($HostName)"
