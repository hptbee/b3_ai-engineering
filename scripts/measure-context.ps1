param(
    [string]$RepoRoot,
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

function Get-FileBytes([string]$RelPath) {
    $full = Join-Path $RepoRoot ($RelPath -replace '/', '\')
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return 0 }
    return (Get-Item -LiteralPath $full).Length
}

function Est-Tokens([long]$Bytes) {
    return [int][math]::Round($Bytes / 4.0)
}

$warnings = New-Object System.Collections.Generic.List[string]

$agentsBytes = Get-FileBytes 'AGENTS.md'
if ($agentsBytes -gt 3600) { $warnings.Add("AGENTS.md ($agentsBytes B > 3600 B)") }

$rulesBytes = 0
foreach ($rf in @(Get-ChildItem (Join-Path $RepoRoot 'rules') -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
    $rulesBytes += $rf.Length
}

$skillFiles = @()
foreach ($dir in @('skills', 'adapters\command-skills')) {
    $p = Join-Path $RepoRoot $dir
    if (Test-Path -LiteralPath $p) {
        $skillFiles += @(Get-ChildItem -LiteralPath $p -Recurse -Filter 'SKILL.md' -File)
    }
}

$fmTotalBytes = 0
$maxFmBytes = 0
$maxFmFile = ''
$maxSkillBytes = 0
$maxSkillFile = ''
foreach ($sf in $skillFiles) {
    $rel = $sf.FullName.Substring($RepoRoot.Length + 1) -replace '\\', '/'
    if ($sf.Length -gt $maxSkillBytes) {
        $maxSkillBytes = $sf.Length
        $maxSkillFile = $rel
    }
    if ($sf.Length -gt 4000) {
        $warnings.Add("$rel ($($sf.Length) B > 4000 B)")
    }
    $raw = Get-Content -LiteralPath $sf.FullName -Raw
    if ($raw -match '(?s)^---\r?\n(.*?)\r?\n---') {
        $fmLen = [System.Text.Encoding]::UTF8.GetByteCount($Matches[1])
        $fmTotalBytes += $fmLen
        if ($fmLen -gt $maxFmBytes) {
            $maxFmBytes = $fmLen
            $maxFmFile = $rel
        }
        if ($fmLen -gt 280) {
            $warnings.Add("$rel frontmatter ($fmLen B > 280 B)")
        }
    }
}

$alwaysOnBytes = $agentsBytes + $rulesBytes + $fmTotalBytes

$autodevCoreBytes = (Get-FileBytes 'workflows/autonomous-development.md') + (Get-FileBytes 'commands/autodev.md')
$wfAutodevBytes = Get-FileBytes 'workflows/autonomous-development.md'
if ($wfAutodevBytes -gt 10000) { $warnings.Add("workflows/autonomous-development.md ($wfAutodevBytes B > 10000 B)") }

$rlStrategyBytes = Get-FileBytes 'review-loop/strategy.md'
if ($rlStrategyBytes -gt 6000) { $warnings.Add("review-loop/strategy.md ($rlStrategyBytes B > 6000 B)") }

$rlOpBytes = $rlStrategyBytes + (Get-FileBytes 'commands/review-loop.md') + (Get-FileBytes 'agents/reviewer.md') + (Get-FileBytes 'skills/engineering/code-review/SKILL.md')
$rlAllBytes = 0
foreach ($f in @('spec.md', 'strategy.md', 'sizing.md', 'findings.md', 'models.md')) {
    $rlAllBytes += Get-FileBytes "review-loop/$f"
}

Write-Output "=== B3 Context Budget Report ==="
Write-Output ("always_on_total   : {0,6} B (~{1,4} tok)  [AGENTS.md={2} B, rules={3} B, {4} skill frontmatters={5} B]" -f $alwaysOnBytes, (Est-Tokens $alwaysOnBytes), $agentsBytes, $rulesBytes, $skillFiles.Count, $fmTotalBytes)
Write-Output ("autodev_core_load : {0,6} B (~{1,4} tok)  [autonomous-development.md={2} B + commands/autodev.md]" -f $autodevCoreBytes, (Est-Tokens $autodevCoreBytes), $wfAutodevBytes)
Write-Output ("review_loop_op    : {0,6} B (~{1,4} tok)  [strategy={2} B + cmd + reviewer + code-review/SKILL.md={3} B]" -f $rlOpBytes, (Est-Tokens $rlOpBytes), $rlStrategyBytes, (Get-FileBytes 'skills/engineering/code-review/SKILL.md'))
Write-Output ("review_loop_all   : {0,6} B (~{1,4} tok)  [spec+strategy+sizing+findings+models]" -f $rlAllBytes, (Est-Tokens $rlAllBytes))
Write-Output ("max_skill_file    : {0,6} B  ({1})" -f $maxSkillBytes, $maxSkillFile)
Write-Output ("max_frontmatter   : {0,6} B  ({1})" -f $maxFmBytes, $maxFmFile)

if ($warnings.Count -gt 0) {
    Write-Output ("warnings          : {0}" -f $warnings.Count)
    foreach ($w in $warnings) { Write-Output "  - $w" }
    if ($Strict) { exit 1 }
} else {
    Write-Output "warnings          : 0"
}
exit 0
