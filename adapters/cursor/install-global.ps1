# Global Cursor installer for B3 AI Engineering (Windows PowerShell / pwsh).
# Installs/updates/verifies/uninstalls flattened 1-level skills, 11 commands, 5 subagents, global b3-home, and plain-text User Rules template under ~/.cursor.
# Usage: .\adapters\cursor\install-global.ps1 [-Action install|update|verify|uninstall] [-CursorHome <dir>] [-B3Home <dir>] [-UserHome <dir>] [-DryRun] [-Force]
param(
    [Parameter(Position = 0)]
    [ValidateSet('install', 'update', 'verify', 'uninstall')]
    [string]$Action = 'install',
    [string]$CursorHome = '',
    [string]$B3Home = '',
    [string]$UserHome = '',
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\global-common.ps1')

function Check-CrossHostCoexistence([string]$UserHomeDir, [string[]]$SkillNames) {
    foreach ($sub in @('.agents\skills', '.claude\skills')) {
        $overlaps = Get-SkillOverlaps (Join-Path $UserHomeDir $sub) $SkillNames
        if ($overlaps.Count -gt 0) {
            $subDisp = '~/' + ($sub -replace '\\', '/')
            Write-Output "COEXISTENCE_WARNING: $subDisp contains $($overlaps.Count) overlapping B3 skill(s); Cursor cross-loads $subDisp and may show duplicates."
        }
    }
}

function Uninstall-ManagedFile([string]$Path, [string]$ExpectedSha, [bool]$RequireMarker, [string]$Label, [ref]$Removed, [ref]$Skipped) {
    if (-not (Test-PathWithinRoot $CursorHome $Path)) {
        Fail "refusing to uninstall path outside CursorHome: $Path"
    }
    if (Test-IsReparseLink $Path) {
        Write-Warning "skipping symlinked ${Label}: $Path"
        $Skipped.Value++
        return
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    if ($RequireMarker) {
        $txt = [IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        if ($txt -notmatch 'b3-global-cursor-managed:') {
            Write-Warning "skipping unmanaged ${Label}: $Path"
            return
        }
    }
    if (-not $Force -and (-not $ExpectedSha -or ((Get-FileSha256 $Path) -ne $ExpectedSha))) {
        Write-Warning "skipping modified or unverified ${Label}: $Path (re-run with -Force to remove)"
        $Skipped.Value++
        return
    }
    if ($DryRun) { Write-Output "dry-run: remove $Path" } else { Remove-Item -LiteralPath $Path -Force }
    $Removed.Value++
}

function Assert-ManagedDocPreflight([string]$Path, [string]$Label) {
    Assert-RegularFileOrMissing $Path $Label
    if ((Test-Path -LiteralPath $Path -PathType Leaf) -and -not $Force) {
        $txt = [IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        if ($txt -notmatch 'b3-global-cursor-managed:') {
            Fail "refusing to overwrite unmanaged ${Label} $Path (re-run with -Force to replace)"
        }
    }
}

$scriptRoot = $PSScriptRoot
if (-not $UserHome) {
    $UserHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
}
$UserHome = Normalize-Path $UserHome
if (-not $CursorHome) {
    $CursorHome = Join-Path $UserHome '.cursor'
}
$CursorHome = Normalize-Path $CursorHome

$skillsDest = Join-Path $CursorHome 'skills'
$commandsDest = Join-Path $CursorHome 'commands'
$agentsDest = Join-Path $CursorHome 'agents'
$b3HomeFile = Join-Path $CursorHome 'b3-home'
$userRulesFile = Join-Path $CursorHome 'b3-user-rules.txt'
$manifestFile = Join-Path $CursorHome '.b3-global-manifest'

$expectedCommands = @('b3-plan.md', 'b3-implement.md', 'b3-debug.md', 'b3-review.md', 'b3-verify.md', 'b3-review-loop.md', 'b3-ship.md', 'b3-research-ship.md', 'b3-pr-resolve.md', 'b3-pr-reply.md', 'b3-pr-comment.md')
$expectedAgents = @('b3-reviewer.md', 'b3-fixer.md', 'b3-security-reviewer.md', 'b3-architecture-reviewer.md', 'b3-performance-reviewer.md')

# --- Uninstall ---
if ($Action -eq 'uninstall') {
    if (Test-IsReparseLink $CursorHome) { Fail "refusing to uninstall link-based CursorHome: $CursorHome" }
    if (Test-IsReparseLink $manifestFile) { Fail "refusing to read link-based manifest: $manifestFile" }
    $manifest = Read-B3Manifest $manifestFile
    if (-not $manifest.Exists) {
        Write-Output "nothing installed (no manifest at $manifestFile)"
        exit 0
    }
    if ($manifest.Corrupt -or $manifest.Schema -ne 'b3-cursor-global-v1') {
        Fail "refusing to uninstall invalid or corrupt B3 manifest at $manifestFile"
    }
    $removed = 0
    $skipped = 0
    if (Test-IsReparseLink $skillsDest) {
        Write-Warning "skipping symlinked skills directory: $skillsDest"
        $skipped++
    } else {
        foreach ($sk in (Sort-OrdinalStrings @($manifest.Sections.skill.Keys))) {
            $p = Join-Path $skillsDest $sk
            if (-not (Test-PathWithinRoot $CursorHome $p)) {
                Fail "refusing to uninstall path outside CursorHome: $p"
            }
            if (Test-IsReparseLink $p) {
                $expTarget = $manifest.Sections.skill[$sk]
                if (-not $Force -and (-not $expTarget -or -not (Test-LinkTarget $p $expTarget))) {
                    Write-Warning "skipping retargeted skill link: $p (expected $expTarget; re-run with -Force to remove)"
                    $skipped++
                    continue
                }
                if ($DryRun) { Write-Output "dry-run: remove skill link $p" } else { Remove-LinkOnly $p }
                $removed++
            } elseif (Test-Path -LiteralPath $p) {
                Write-Warning "skipping unmanaged non-link skill directory: $p"
            }
        }
    }
    if (Test-IsReparseLink $commandsDest) {
        Write-Warning "skipping symlinked commands directory: $commandsDest"
        $skipped++
    } else {
        foreach ($cmd in (Sort-OrdinalStrings @($manifest.Sections.command.Keys))) {
            Uninstall-ManagedFile (Join-Path $commandsDest $cmd) $manifest.Sections.command[$cmd] $true 'command file' ([ref]$removed) ([ref]$skipped)
        }
    }
    if (Test-IsReparseLink $agentsDest) {
        Write-Warning "skipping symlinked agents directory: $agentsDest"
        $skipped++
    } else {
        foreach ($ag in (Sort-OrdinalStrings @($manifest.Sections.agent.Keys))) {
            Uninstall-ManagedFile (Join-Path $agentsDest $ag) $manifest.Sections.agent[$ag] $true 'agent file' ([ref]$removed) ([ref]$skipped)
        }
    }
    if ($manifest.Sections.file.ContainsKey('b3-user-rules.txt')) {
        Uninstall-ManagedFile $userRulesFile $manifest.Sections.file['b3-user-rules.txt'] $true 'file' ([ref]$removed) ([ref]$skipped)
    }
    if ($manifest.Sections.file.ContainsKey('b3-home')) {
        Uninstall-ManagedFile $b3HomeFile $manifest.Sections.file['b3-home'] $false 'b3-home' ([ref]$removed) ([ref]$skipped)
    }
    if (-not $DryRun) {
        foreach ($subDir in @($skillsDest, $commandsDest, $agentsDest)) { Remove-EmptyRegularDir $subDir }
    }
    if ($skipped -gt 0) {
        Write-Output "UNINSTALL_CONFLICT: removed=$removed skipped=$skipped cursor_home=$CursorHome (re-run with -Force to remove modified managed entries)"
        exit 1
    }
    if ($DryRun) {
        Write-Output "dry-run: remove manifest $manifestFile"
    } else {
        Remove-Item -LiteralPath $manifestFile -Force
        foreach ($subDir in @($skillsDest, $commandsDest, $agentsDest)) { Remove-EmptyRegularDir $subDir }
    }
    Write-Output "UNINSTALL_OK: removed=$removed cursor_home=$CursorHome"
    exit 0
}

# --- Validate canonical B3_HOME (install / update / verify) ---
if (-not $B3Home) { $B3Home = Split-Path -Parent (Split-Path -Parent $scriptRoot) }
if (-not (Test-Path -LiteralPath $B3Home -PathType Container)) { Fail "B3Home directory not found: $B3Home" }
$B3Home = Normalize-Path (Resolve-Path -LiteralPath $B3Home).Path
$b3HomeForward = To-Forward $B3Home

$workflowPath = Join-Path $B3Home 'workflows\ship.md'
$skillsSrc = Join-Path $B3Home 'skills'
$commandsSrc = Join-Path $B3Home 'commands'
$agentsSrc = Join-Path $B3Home 'agents'
$rulesSrc = Join-Path $B3Home 'rules'

if (-not (Test-Path -LiteralPath $workflowPath -PathType Leaf)) { Fail "B3_HOME missing workflow: $workflowPath" }
if (-not (Test-Path -LiteralPath $skillsSrc -PathType Container)) { Fail "B3_HOME missing skills dir: $skillsSrc" }
if (-not (Test-Path -LiteralPath $commandsSrc -PathType Container)) { Fail "B3_HOME missing commands dir: $commandsSrc" }
if (-not (Test-Path -LiteralPath $agentsSrc -PathType Container)) { Fail "B3_HOME missing agents dir: $agentsSrc" }
if (@(Get-ChildItem -LiteralPath $rulesSrc -Filter '*.md' -File -ErrorAction SilentlyContinue).Count -lt 1) {
    Fail "B3_HOME missing rules/*.md under: $rulesSrc"
}
foreach ($c in $expectedCommands) {
    if (-not (Test-Path -LiteralPath (Join-Path $commandsSrc $c) -PathType Leaf)) { Fail "B3_HOME missing canonical command: $c" }
}
foreach ($a in $expectedAgents) {
    if (-not (Test-Path -LiteralPath (Join-Path $agentsSrc $a) -PathType Leaf)) { Fail "B3_HOME missing canonical agent: $a" }
}

$skillTargets = @{}
if ((Add-CanonicalSkills $skillsSrc $skillTargets $null) -lt 1) {
    Fail "B3_HOME has no SKILL.md under: $skillsSrc"
}
$sortedSkillNames = Sort-OrdinalStrings @($skillTargets.Keys)

$renderedCommands = @{}
foreach ($c in $expectedCommands) {
    $parsed = Split-YamlFrontmatter (Join-Path $commandsSrc $c) -RequireFrontmatter
    $renderedCommands[$c] = (@(
        $parsed.Frontmatter,
        "<!-- b3-global-cursor-managed: source=$b3HomeForward/commands/$c -->",
        '',
        "**Global B3_HOME fallback:** if ``B3_HOME`` env and project ``.b3/home`` are absent, read ``~/.cursor/b3-home`` (``$b3HomeForward``). Project ``AGENTS.md`` and ``.cursor/rules/*.mdc`` override global defaults on project requirements.",
        '',
        $parsed.Body
    ) -join "`n").TrimEnd() + "`n"
}

$renderedAgents = @{}
foreach ($a in $expectedAgents) {
    $parsed = Split-YamlFrontmatter (Join-Path $agentsSrc $a) -RequireFrontmatter
    $renderedAgents[$a] = (@(
        $parsed.Frontmatter,
        "<!-- b3-global-cursor-managed: source=$b3HomeForward/agents/$a -->",
        '',
        "**Global B3_HOME:** resolve ``B3_HOME`` env, project ``.b3/home``, or ``~/.cursor/b3-home`` (``$b3HomeForward``).",
        '',
        $parsed.Body
    ) -join "`n").TrimEnd() + "`n"
}

$renderedUserRules = (@(
    "# B3 Global User Rules (paste into Cursor Settings > Rules > User Rules)",
    "# b3-global-cursor-managed: source=$b3HomeForward/rules/",
    "B3 Engineering Baseline (personal/global; project AGENTS.md and .cursor/rules/*.mdc override these on project requirements):",
    "1. Resolve B3_HOME: B3_HOME env var -> project .b3/home -> ~/.cursor/b3-home ($b3HomeForward). Never copy skills/ into product repos.",
    "2. Verification honesty: never claim PASS without executed evidence; missing evidence, skipped suite, or tool failure = UNKNOWN / INCOMPLETE.",
    "3. Scope & design: understand before editing; prefer simplest correct change meeting stated requirements; load only the smallest matching skill from ~/.cursor/skills/.",
    "4. Provenance: cite official docs vs practice vs preference; never copy external repos verbatim without provenance.",
    "5. Delegation: independent review and fixer roles stay separate; report host limit honestly if subagent isolation is unavailable."
) -join "`n") + "`n"
$renderedB3Home = "$b3HomeForward`n"

$manifest = if (Test-IsReparseLink $manifestFile) {
    [PSCustomObject]@{ Exists = $false; Corrupt = $false; Schema = ''; Sections = @{ skill=@{}; command=@{}; agent=@{}; file=@{} } }
} else {
    Read-B3Manifest $manifestFile
}

# --- Verify ---
if ($Action -eq 'verify') {
    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($pair in @(
        @{ Path = $CursorHome; Label = 'cursor_home' },
        @{ Path = $skillsDest; Label = 'skills directory' },
        @{ Path = $commandsDest; Label = 'commands directory' },
        @{ Path = $agentsDest; Label = 'agents directory' }
    )) {
        if (Test-IsReparseLink $pair.Path) {
            $errors.Add("$($pair.Label) is a link (expected regular directory): $($pair.Path)")
        }
    }
    if (Test-IsReparseLink $manifestFile) {
        $errors.Add("manifest is a link (expected regular file): $manifestFile")
    } elseif (-not $manifest.Exists) {
        $errors.Add("missing manifest: $manifestFile")
    } elseif ($manifest.Corrupt -or $manifest.Schema -ne 'b3-cursor-global-v1') {
        $errors.Add("invalid or corrupt manifest at $manifestFile")
    }
    $legacySkillDir = Join-Path $skillsDest 'b3-ai-engineering'
    if ((Test-Path -LiteralPath $legacySkillDir) -or (Test-IsReparseLink $legacySkillDir)) {
        $errors.Add("legacy b3-ai-engineering entry still exists at $legacySkillDir (run with -Force to migrate)")
    }
    foreach ($fchk in @(
        @{ Path = $b3HomeFile; Expected = $renderedB3Home; Label = 'b3-home' },
        @{ Path = $userRulesFile; Expected = $renderedUserRules; Label = 'b3-user-rules.txt' }
    )) {
        if (Test-IsReparseLink $fchk.Path) {
            $errors.Add("$($fchk.Label) is a link (expected regular file): $($fchk.Path)")
        } elseif (-not (Test-Path -LiteralPath $fchk.Path -PathType Leaf)) {
            $errors.Add("missing $($fchk.Label): $($fchk.Path)")
        } elseif ((Get-FileSha256 $fchk.Path) -ne (Get-TextSha256 $fchk.Expected)) {
            $errors.Add("stale or modified $($fchk.Label) at $($fchk.Path)")
        }
    }
    foreach ($sn in $sortedSkillNames) {
        $dest = Join-Path $skillsDest $sn
        if (-not (Test-LinkTarget $dest $skillTargets[$sn]) -or -not (Test-Path -LiteralPath (Join-Path $dest 'SKILL.md') -PathType Leaf)) {
            $errors.Add("invalid or missing skill link: $dest -> $($skillTargets[$sn])")
        }
    }
    foreach ($oldSk in $manifest.Sections.skill.Keys) {
        if (-not $skillTargets.ContainsKey($oldSk)) {
            $oldPath = Join-Path $skillsDest $oldSk
            if ((Test-Path -LiteralPath $oldPath) -or (Test-IsReparseLink $oldPath)) {
                $errors.Add("stale managed skill entry present: $oldPath")
            }
        }
    }
    foreach ($c in $expectedCommands) {
        $dest = Join-Path $commandsDest $c
        if (Test-IsReparseLink $dest) { $errors.Add("command is a link (expected regular file): $dest") }
        elseif (-not (Test-Path -LiteralPath $dest -PathType Leaf)) { $errors.Add("missing command: $dest") }
        elseif ((Get-FileSha256 $dest) -ne (Get-TextSha256 $renderedCommands[$c])) { $errors.Add("stale or modified command: $dest") }
    }
    foreach ($a in $expectedAgents) {
        $dest = Join-Path $agentsDest $a
        if (Test-IsReparseLink $dest) { $errors.Add("agent is a link (expected regular file): $dest") }
        elseif (-not (Test-Path -LiteralPath $dest -PathType Leaf)) { $errors.Add("missing agent: $dest") }
        elseif ((Get-FileSha256 $dest) -ne (Get-TextSha256 $renderedAgents[$a])) { $errors.Add("stale or modified agent: $dest") }
    }

    Check-CrossHostCoexistence $UserHome $sortedSkillNames

    if ($errors.Count -gt 0) {
        foreach ($e in $errors) { Write-Output "VERIFY_ERROR: $e" }
        Write-Output "VERIFY_FAIL: errors=$($errors.Count)"
        exit 1
    }
    Write-Output "VERIFY_OK: skills=$($sortedSkillNames.Count) commands=$($expectedCommands.Count) agents=$($expectedAgents.Count) cursor_home=$CursorHome b3_home=$b3HomeForward"
    Write-Output "note: filesystem links and hashes verified (PASS); live Cursor IDE/CLI activation and User Rules UI application remain UNKNOWN / INCOMPLETE until verified in Cursor."
    exit 0
}

# --- Preflight all conflicts before any disk mutation (install / update) ---
Assert-RegularDirOrMissing $CursorHome 'cursor_home'
Assert-RegularDirOrMissing $skillsDest 'skills'
Assert-RegularDirOrMissing $commandsDest 'commands'
Assert-RegularDirOrMissing $agentsDest 'agents'
Assert-RegularFileOrMissing $manifestFile 'manifest'
if ($manifest.Exists -and ($manifest.Corrupt -or $manifest.Schema -ne 'b3-cursor-global-v1')) {
    Fail "refusing to ${Action}: invalid or corrupt B3 manifest at $manifestFile"
}

$legacySkillDir = Join-Path $skillsDest 'b3-ai-engineering'
$removeLegacyLink = $false
if ((Test-Path -LiteralPath $legacySkillDir) -or (Test-IsReparseLink $legacySkillDir)) {
    $legacySrc = Join-Path $B3Home 'skills'
    if ($Force -and (Test-IsReparseLink $legacySkillDir) -and (Test-LinkTarget $legacySkillDir $legacySrc)) {
        $removeLegacyLink = $true
    } else {
        Fail "legacy $legacySkillDir exists; re-run with -Force if it is a link to $legacySrc (or move unmanaged directory aside)"
    }
}

$skillAlreadyOk = @{}
foreach ($sn in $sortedSkillNames) {
    $dest = Join-Path $skillsDest $sn
    if ((Test-Path -LiteralPath $dest) -or (Test-IsReparseLink $dest)) {
        if (Test-LinkTarget $dest $skillTargets[$sn]) {
            $skillAlreadyOk[$sn] = $true
            continue
        }
        $isManaged = $manifest.Sections.skill.ContainsKey($sn) -and ($Action -eq 'update')
        if (Test-IsReparseLink $dest) {
            if ($isManaged -or $Force) { continue }
            Fail "conflicting link at $dest (does not point to $($skillTargets[$sn])). Re-run with -Force or update."
        }
        if ($Force) {
            if (-not (Test-Path -LiteralPath (Join-Path $dest 'SKILL.md') -PathType Leaf)) {
                Fail "refusing to overwrite non-skill directory even with -Force: $dest"
            }
            continue
        }
        Fail "conflicting unmanaged directory at $dest; move aside or re-run with -Force"
    }
}

foreach ($c in $expectedCommands) { Assert-ManagedDocPreflight (Join-Path $commandsDest $c) 'command' }
foreach ($a in $expectedAgents) { Assert-ManagedDocPreflight (Join-Path $agentsDest $a) 'agent' }
Assert-ManagedDocPreflight $userRulesFile 'user rules'

Assert-RegularFileOrMissing $b3HomeFile 'b3-home'
if (Test-Path -LiteralPath $b3HomeFile -PathType Leaf) {
    $curHome = ([IO.File]::ReadAllText($b3HomeFile, [System.Text.Encoding]::UTF8)).Trim() -replace '\\', '/'
    $homeManaged = $manifest.Sections.file.ContainsKey('b3-home') -and ($Action -eq 'update')
    if ($curHome -ne $b3HomeForward -and -not $homeManaged -and -not $Force) {
        Fail "refusing to overwrite unmanaged $b3HomeFile (points to $curHome; re-run with -Force)"
    }
}

# --- Execute install / update (or print DryRun plan) ---
if ($DryRun) {
    if ($removeLegacyLink) { Write-Output "dry-run: remove legacy link $legacySkillDir" }
    Write-Output "dry-run: ensure $CursorHome, write $b3HomeFile ($b3HomeForward), $userRulesFile"
    Write-Output "dry-run: link $($sortedSkillNames.Count) flattened skills under $skillsDest"
    Write-Output "dry-run: write $($expectedCommands.Count) commands under $commandsDest and $($expectedAgents.Count) agents under $agentsDest"
    foreach ($oldSk in (Sort-OrdinalStrings @($manifest.Sections.skill.Keys))) {
        if (-not $skillTargets.ContainsKey($oldSk)) { Write-Output "dry-run: prune removed skill $(Join-Path $skillsDest $oldSk)" }
    }
    Check-CrossHostCoexistence $UserHome $sortedSkillNames
    Write-Output "DRY_RUN_OK: action=$Action cursor_home=$CursorHome"
    exit 0
}

foreach ($d in @($CursorHome, $skillsDest, $commandsDest, $agentsDest)) {
    if (-not (Test-Path -LiteralPath $d -PathType Container)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
if ($removeLegacyLink) {
    Remove-LinkOnly $legacySkillDir
    Write-Output "migrated: removed legacy link $legacySkillDir"
}

$manifestLines = New-Object System.Collections.Generic.List[string]
$manifestLines.Add('schema=b3-cursor-global-v1')
$manifestLines.Add("b3_home=$b3HomeForward")

foreach ($sn in $sortedSkillNames) {
    $dest = Join-Path $skillsDest $sn
    $src = $skillTargets[$sn]
    $srcFwd = To-Forward $src
    if (-not $skillAlreadyOk.ContainsKey($sn)) {
        if (Test-IsReparseLink $dest) { Remove-LinkOnly $dest }
        elseif (Test-Path -LiteralPath $dest -PathType Container) { Remove-DirTreeSafely $dest }
        Create-DirLink $dest $src
    }
    $manifestLines.Add("skill|$sn|$srcFwd")
}

foreach ($oldSk in (Sort-OrdinalStrings @($manifest.Sections.skill.Keys))) {
    if (-not $skillTargets.ContainsKey($oldSk)) {
        $oldPath = Join-Path $skillsDest $oldSk
        if (Test-IsReparseLink $oldPath) { Remove-LinkOnly $oldPath }
        elseif (Test-Path -LiteralPath $oldPath) { Write-Warning "skipping prune of non-link directory $oldPath" }
    }
}

foreach ($c in $expectedCommands) {
    $dest = Join-Path $commandsDest $c
    $body = $renderedCommands[$c]
    Write-Utf8NoBom $dest $body
    $manifestLines.Add("command|$c|$(Get-TextSha256 $body)")
}
foreach ($a in $expectedAgents) {
    $dest = Join-Path $agentsDest $a
    $body = $renderedAgents[$a]
    Write-Utf8NoBom $dest $body
    $manifestLines.Add("agent|$a|$(Get-TextSha256 $body)")
}
foreach ($pruneSpec in @(
    @{ Keys = @($manifest.Sections.command.Keys); Expected = $expectedCommands; Dir = $commandsDest },
    @{ Keys = @($manifest.Sections.agent.Keys); Expected = $expectedAgents; Dir = $agentsDest }
)) {
    foreach ($oldName in $pruneSpec.Keys) {
        if ($oldName -notin $pruneSpec.Expected) {
            $oldPath = Join-Path $pruneSpec.Dir $oldName
            if ((Test-Path -LiteralPath $oldPath -PathType Leaf) -and ([IO.File]::ReadAllText($oldPath, [System.Text.Encoding]::UTF8) -match 'b3-global-cursor-managed:')) {
                Remove-Item -LiteralPath $oldPath -Force
            }
        }
    }
}

Write-Utf8NoBom $b3HomeFile $renderedB3Home
$manifestLines.Add("file|b3-home|$(Get-TextSha256 $renderedB3Home)")
Write-Utf8NoBom $userRulesFile $renderedUserRules
$manifestLines.Add("file|b3-user-rules.txt|$(Get-TextSha256 $renderedUserRules)")

Write-Utf8NoBom $manifestFile (($manifestLines -join "`n") + "`n")

Check-CrossHostCoexistence $UserHome $sortedSkillNames
Write-Output ("{0}_OK: skills={1} commands={2} agents={3} cursor_home={4} b3_home={5}" -f $Action.ToUpperInvariant(), $sortedSkillNames.Count, $expectedCommands.Count, $expectedAgents.Count, $CursorHome, $b3HomeForward)
Write-Output "note: Cursor global User Rules must be pasted once manually from $userRulesFile into Cursor Settings > Rules > User Rules (runtime discovery UNKNOWN / INCOMPLETE until verified in Cursor)."
