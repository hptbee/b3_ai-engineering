param(
    [string]$RepoRoot,
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$RepoRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RepoRoot)
$isoEnc = [System.Text.Encoding]::GetEncoding(28591)

function Get-LfContent([string]$FullPath) {
    if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) { return '' }
    return $isoEnc.GetString([System.IO.File]::ReadAllBytes($FullPath)).Replace("`r", '')
}

function Get-PathLfBytes([string]$FullPath) {
    return (Get-LfContent $FullPath).Length
}

function Get-FileBytes([string]$RelPath) {
    $full = Join-Path $RepoRoot ($RelPath -replace '/', '\')
    return Get-PathLfBytes $full
}

function Est-Tokens([long]$Bytes) {
    return [int][math]::Floor(($Bytes + 2) / 4.0)
}

$warnings = New-Object System.Collections.Generic.List[string]

$agentsBytes = Get-FileBytes 'AGENTS.md'
if ($agentsBytes -gt 3600) { $warnings.Add("AGENTS.md ($agentsBytes B > 3600 B)") }

$rulesBytes = 0
foreach ($rf in @(Get-ChildItem (Join-Path $RepoRoot 'rules') -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
    $rulesBytes += Get-PathLfBytes $rf.FullName
}

$skillFiles = @()
foreach ($dir in @('skills', 'adapters\command-skills')) {
    $p = Join-Path $RepoRoot $dir
    if (Test-Path -LiteralPath $p) {
        $skillFiles += @(Get-ChildItem -LiteralPath $p -Recurse -Filter 'SKILL.md' -File)
    }
}
$skillFiles = @($skillFiles | Sort-Object { ($_.FullName.Substring($RepoRoot.Length + 1) -replace '\\', '/') })

$fmTotalBytes = 0
$maxFmBytes = 0
$maxFmFile = ''
$maxSkillBytes = 0
$maxSkillFile = ''
foreach ($sf in $skillFiles) {
    $rel = $sf.FullName.Substring($RepoRoot.Length + 1) -replace '\\', '/'
    $lf = Get-LfContent $sf.FullName
    $sb = $lf.Length
    if ($sb -gt $maxSkillBytes) {
        $maxSkillBytes = $sb
        $maxSkillFile = $rel
    }
    if ($sb -gt 4000) {
        $warnings.Add("$rel ($sb B > 4000 B)")
    }
    if ($lf -match '(?s)\A---\n(.*?)\n---(?:\n|\z)') {
        $fmLen = $Matches[1].Length
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

$wfShipBytes = Get-FileBytes 'workflows/ship.md'
if ($wfShipBytes -gt 9500) { $warnings.Add("workflows/ship.md ($wfShipBytes B > 9500 B)") }
$shipCoreBytes = $wfShipBytes + (Get-FileBytes 'commands/b3-ship.md')

$shipRefsBytes = (Get-FileBytes 'workflows/references/ship-templates.md') + (Get-FileBytes 'workflows/references/ship-resume.md')
if ($shipRefsBytes -gt 6000) { $warnings.Add("workflows/references/ship-{templates,resume}.md ($shipRefsBytes B > 6000 B)") }

$rlStrategyBytes = Get-FileBytes 'review-loop/strategy.md'
if ($rlStrategyBytes -gt 5400) { $warnings.Add("review-loop/strategy.md ($rlStrategyBytes B > 5400 B)") }

$crSkillBytes = Get-FileBytes 'skills/engineering/code-review/SKILL.md'
$revAgentBytes = Get-FileBytes 'agents/b3-reviewer.md'
$reviewDeltaBytes = $revAgentBytes + $crSkillBytes
$planCmdBytes = (Get-FileBytes 'commands/b3-plan.md') + (Get-FileBytes 'skills/engineering/planning/SKILL.md')
$implCmdBytes = (Get-FileBytes 'commands/b3-implement.md') + (Get-FileBytes 'skills/engineering/problem-solving/SKILL.md')
$debugCmdBytes = (Get-FileBytes 'commands/b3-debug.md') + (Get-FileBytes 'skills/engineering/debugging/SKILL.md')
$reviewCmdBytes = (Get-FileBytes 'commands/b3-review.md') + $crSkillBytes
$verifyCmdBytes = (Get-FileBytes 'commands/b3-verify.md') + (Get-FileBytes 'skills/engineering/verification/SKILL.md')
$rlOpBytes = $rlStrategyBytes + (Get-FileBytes 'commands/b3-review-loop.md') + $revAgentBytes + $crSkillBytes
$rlAllBytes = 0
foreach ($f in @('spec.md', 'strategy.md', 'sizing.md', 'models.md')) {
    $rlAllBytes += Get-FileBytes "review-loop/$f"
}

$agentRolesBytes = 0
foreach ($af in @(Get-ChildItem (Join-Path $RepoRoot 'agents') -Filter '*.md' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'README.md' })) {
    $agentRolesBytes += Get-PathLfBytes $af.FullName
}
if ($agentRolesBytes -gt 8500) { $warnings.Add("agents/*.md roles ($agentRolesBytes B > 8500 B)") }

Write-Output "=== B3 Context Budget Report ==="
Write-Output ("always_on_total   : {0,6} B (~{1,4} tok)  [AGENTS.md={2} B, rules={3} B, {4} skill frontmatters={5} B]" -f $alwaysOnBytes, (Est-Tokens $alwaysOnBytes), $agentsBytes, $rulesBytes, $skillFiles.Count, $fmTotalBytes)
Write-Output ("ship_core_load    : {0,6} B (~{1,4} tok)  [ship.md={2} B + commands/b3-ship.md]" -f $shipCoreBytes, (Est-Tokens $shipCoreBytes), $wfShipBytes)
Write-Output ("ship_refs_load    : {0,6} B (~{1,4} tok)  [ship-templates.md + ship-resume.md]" -f $shipRefsBytes, (Est-Tokens $shipRefsBytes))
Write-Output ("review_loop_op    : {0,6} B (~{1,4} tok)  [strategy={2} B + cmd + reviewer + code-review/SKILL.md={3} B]" -f $rlOpBytes, (Est-Tokens $rlOpBytes), $rlStrategyBytes, $crSkillBytes)
Write-Output ("review_delta_load : {0,6} B (~{1,4} tok)  [b3-reviewer.md + code-review/SKILL.md]" -f $reviewDeltaBytes, (Est-Tokens $reviewDeltaBytes))
Write-Output ("standalone_cmds   : plan={0} B, impl={1} B, debug={2} B, review={3} B, verify={4} B" -f $planCmdBytes, $implCmdBytes, $debugCmdBytes, $reviewCmdBytes, $verifyCmdBytes)
Write-Output ("review_loop_all   : {0,6} B (~{1,4} tok)  [spec+strategy+sizing+models (reference-only)]" -f $rlAllBytes, (Est-Tokens $rlAllBytes))
Write-Output ("agents_roles_total: {0,6} B (~{1,4} tok)  [5 runtime subagent roles excl. README.md]" -f $agentRolesBytes, (Est-Tokens $agentRolesBytes))
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
