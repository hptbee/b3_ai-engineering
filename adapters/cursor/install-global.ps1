# Global Cursor installer for B3 AI Engineering (Windows PowerShell / pwsh).
# Installs/updates/verifies/uninstalls flattened 1-level skills, 7 commands, 5 subagents, global b3-home, and plain-text User Rules template under ~/.cursor.
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

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

function Normalize-Path([string]$PathValue) {
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PathValue).TrimEnd('\', '/')
}

function Write-Utf8NoBom([string]$DestPath, [string]$Content) {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $lf = $Content.Replace("`r`n", "`n").Replace("`r", "`n")
    $parent = Split-Path -Parent $DestPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($DestPath, $lf, $utf8NoBom)
}

function Get-TextSha256([string]$Text) {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $bytes = $utf8NoBom.GetBytes($Text.Replace("`r`n", "`n").Replace("`r", "`n"))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
        return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-FileSha256([string]$FilePath) {
    $raw = [IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8)
    return Get-TextSha256 $raw
}

function Test-IsReparseLink([string]$PathValue) {
    $item = Get-Item -LiteralPath $PathValue -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $false }
    if ($item.LinkType -in @('Junction', 'SymbolicLink')) { return $true }
    return (($item.Attributes.ToString()) -match 'ReparsePoint')
}

function Remove-LinkOnly([string]$LinkPath) {
    $item = Get-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue
    if (-not $item) { return }
    if (-not (Test-IsReparseLink $LinkPath)) {
        Fail "refusing to remove non-link entry: $LinkPath"
    }
    if ($item.PSIsContainer) {
        if ($env:OS -eq 'Windows_NT') {
            & cmd.exe /c rmdir "`"$LinkPath`"" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath $LinkPath)) {
                Fail "could not remove junction/symlink directory: $LinkPath"
            }
        } else {
            Remove-Item -LiteralPath $LinkPath -Force
        }
    } else {
        Remove-Item -LiteralPath $LinkPath -Force
    }
}

function Create-DirLink([string]$DestPath, [string]$TargetPath) {
    $parent = Split-Path -Parent $DestPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    if ($env:OS -eq 'Windows_NT') {
        New-Item -ItemType Junction -Path $DestPath -Target $TargetPath | Out-Null
    } else {
        New-Item -ItemType SymbolicLink -Path $DestPath -Target $TargetPath | Out-Null
    }
}

function Test-LinkTarget([string]$LinkPath, [string]$ExpectedDir) {
    if (-not (Test-IsReparseLink $LinkPath)) { return $false }
    try {
        $expectedFull = [IO.Path]::GetFullPath($ExpectedDir).TrimEnd('\', '/')
        $item = Get-Item -LiteralPath $LinkPath -Force
        if (-not $item.PSIsContainer) { return $false }
        $candidate = $null
        if ($item.Target) {
            $raw = [string](@($item.Target)[0])
            if ($raw) {
                if (-not [IO.Path]::IsPathRooted($raw)) {
                    $raw = Join-Path (Split-Path -Parent $LinkPath) $raw
                }
                $candidate = [IO.Path]::GetFullPath($raw).TrimEnd('\', '/')
            }
        }
        if (-not $candidate -and (Test-Path -LiteralPath $LinkPath -PathType Container)) {
            $candidate = (Resolve-Path -LiteralPath $LinkPath).Path.TrimEnd('\', '/')
        }
        if (-not $candidate) { return $false }
        if ($env:OS -eq 'Windows_NT') {
            return $candidate.Equals($expectedFull, [System.StringComparison]::OrdinalIgnoreCase)
        }
        return $candidate -ceq $expectedFull
    } catch {
        return $false
    }
}

function Split-Frontmatter([string]$FilePath) {
    $raw = ([IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8)).Replace("`r`n", "`n").Replace("`r", "`n")
    $lines = $raw -split "`n"
    if ($lines.Count -lt 3 -or $lines[0].Trim() -ne '---') {
        Fail "canonical markdown missing YAML frontmatter: $FilePath"
    }
    $endIdx = -1
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq '---') {
            $endIdx = $i
            break
        }
    }
    if ($endIdx -lt 0) {
        Fail "canonical markdown unclosed YAML frontmatter: $FilePath"
    }
    $fmLines = @($lines[0..$endIdx])
    $bodyLines = @()
    if ($endIdx + 1 -lt $lines.Count) {
        $bodyLines = @($lines[($endIdx + 1)..($lines.Count - 1)])
    }
    $body = (($bodyLines -join "`n").TrimStart("`n")).TrimEnd()
    return [PSCustomObject]@{
        Frontmatter = ($fmLines -join "`n")
        FmLines     = $fmLines
        Body        = $body
    }
}

function Get-SkillNameFromFile([string]$SkillFile) {
    $parsed = Split-Frontmatter $SkillFile
    foreach ($line in $parsed.FmLines) {
        if ($line -match '^\s*name:\s*([a-z0-9-]+)\s*$') {
            return $Matches[1]
        }
    }
    return (Split-Path -Leaf (Split-Path -Parent $SkillFile))
}

function Read-Manifest([string]$ManifestPath) {
    $entries = [PSCustomObject]@{
        Exists   = $false
        B3Home   = ''
        Skills   = @{}
        Commands = @{}
        Agents   = @{}
        Files    = @{}
    }
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        return $entries
    }
    $entries.Exists = $true
    $lines = ([IO.File]::ReadAllText($ManifestPath, [System.Text.Encoding]::UTF8)).Replace("`r`n", "`n").Split("`n")
    foreach ($line in $lines) {
        $t = $line.Trim()
        if (-not $t) { continue }
        if ($t -match '^b3_home=(.+)$') {
            $entries.B3Home = $Matches[1].Trim()
            continue
        }
        $parts = $t -split '\|', 3
        if ($parts.Count -lt 3) { continue }
        switch ($parts[0]) {
            'skill'   { $entries.Skills[$parts[1]] = $parts[2] }
            'command' { $entries.Commands[$parts[1]] = $parts[2] }
            'agent'   { $entries.Agents[$parts[1]] = $parts[2] }
            'file'    { $entries.Files[$parts[1]] = $parts[2] }
        }
    }
    return $entries
}

function Check-CrossHostCoexistence([string]$UserHomeDir, [string[]]$SkillNames) {
    foreach ($sub in @('.agents\skills', '.claude\skills')) {
        $otherRoot = Join-Path $UserHomeDir $sub
        if (-not (Test-Path -LiteralPath $otherRoot -PathType Container)) { continue }
        $overlaps = New-Object System.Collections.Generic.List[string]
        foreach ($sn in $SkillNames) {
            if (Test-Path -LiteralPath (Join-Path $otherRoot $sn)) {
                $overlaps.Add($sn)
            }
        }
        if ($overlaps.Count -gt 0) {
            $subDisp = '~/' + ($sub -replace '\\', '/')
            Write-Output "COEXISTENCE_WARNING: $subDisp contains $($overlaps.Count) overlapping B3 skill(s); Cursor cross-loads $subDisp and may show duplicates."
        }
    }
}

$scriptRoot = $PSScriptRoot
if (-not $B3Home) {
    $B3Home = Split-Path -Parent (Split-Path -Parent $scriptRoot)
}
if (-not (Test-Path -LiteralPath $B3Home -PathType Container)) {
    Fail "B3Home directory not found: $B3Home"
}
$B3Home = (Resolve-Path -LiteralPath $B3Home).Path.TrimEnd('\', '/')
$b3HomeForward = $B3Home -replace '\\', '/'

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

$expectedCommands = @('b3-plan.md', 'b3-implement.md', 'b3-debug.md', 'b3-review.md', 'b3-verify.md', 'b3-review-loop.md', 'b3-ship.md')
$expectedAgents = @('b3-reviewer.md', 'b3-fixer.md', 'b3-security-reviewer.md', 'b3-architecture-reviewer.md', 'b3-performance-reviewer.md')

# --- Uninstall ---
if ($Action -eq 'uninstall') {
    $manifest = Read-Manifest $manifestFile
    if (-not $manifest.Exists) {
        Write-Output "nothing installed (no manifest at $manifestFile)"
        exit 0
    }
    $removed = 0
    foreach ($sk in @($manifest.Skills.Keys | Sort-Object)) {
        $p = Join-Path $skillsDest $sk
        if (Test-Path -LiteralPath $p) {
            if (Test-IsReparseLink $p) {
                if ($DryRun) { Write-Output "dry-run: remove skill link $p" } else { Remove-LinkOnly $p }
                $removed++
            } else {
                Write-Warning "skipping unmanaged non-link skill directory: $p"
            }
        } else {
            # Also handle dangling junction/symlink where Test-Path returns false
            if (Test-IsReparseLink $p) {
                if ($DryRun) { Write-Output "dry-run: remove broken skill link $p" } else { Remove-LinkOnly $p }
                $removed++
            }
        }
    }
    foreach ($cmd in @($manifest.Commands.Keys | Sort-Object)) {
        $p = Join-Path $commandsDest $cmd
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            $txt = [IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
            if ($txt -match 'b3-global-cursor-managed:') {
                if ($DryRun) { Write-Output "dry-run: remove command $p" } else { Remove-Item -LiteralPath $p -Force }
                $removed++
            } else {
                Write-Warning "skipping unmanaged command file: $p"
            }
        }
    }
    foreach ($ag in @($manifest.Agents.Keys | Sort-Object)) {
        $p = Join-Path $agentsDest $ag
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            $txt = [IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
            if ($txt -match 'b3-global-cursor-managed:') {
                if ($DryRun) { Write-Output "dry-run: remove agent $p" } else { Remove-Item -LiteralPath $p -Force }
                $removed++
            } else {
                Write-Warning "skipping unmanaged agent file: $p"
            }
        }
    }
    if ($manifest.Files.ContainsKey('b3-user-rules.txt') -and (Test-Path -LiteralPath $userRulesFile -PathType Leaf)) {
        $txt = [IO.File]::ReadAllText($userRulesFile, [System.Text.Encoding]::UTF8)
        if ($txt -match 'b3-global-cursor-managed:') {
            if ($DryRun) { Write-Output "dry-run: remove $userRulesFile" } else { Remove-Item -LiteralPath $userRulesFile -Force }
            $removed++
        } else {
            Write-Warning "skipping unmanaged file: $userRulesFile"
        }
    }
    if ($manifest.Files.ContainsKey('b3-home') -and (Test-Path -LiteralPath $b3HomeFile -PathType Leaf)) {
        $curSha = Get-FileSha256 $b3HomeFile
        if ($curSha -eq $manifest.Files['b3-home']) {
            if ($DryRun) { Write-Output "dry-run: remove $b3HomeFile" } else { Remove-Item -LiteralPath $b3HomeFile -Force }
            $removed++
        } else {
            Write-Warning "skipping modified b3-home: $b3HomeFile"
        }
    }
    if ($DryRun) {
        Write-Output "dry-run: remove manifest $manifestFile"
    } else {
        Remove-Item -LiteralPath $manifestFile -Force
        foreach ($subDir in @($skillsDest, $commandsDest, $agentsDest)) {
            if (Test-Path -LiteralPath $subDir -PathType Container) {
                if (@(Get-ChildItem -LiteralPath $subDir -Force).Count -eq 0) {
                    Remove-Item -LiteralPath $subDir -Force
                }
            }
        }
    }
    Write-Output "UNINSTALL_OK: removed=$removed cursor_home=$CursorHome"
    exit 0
}

# --- Validate canonical B3_HOME (install / update / verify) ---
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
    if (-not (Test-Path -LiteralPath (Join-Path $commandsSrc $c) -PathType Leaf)) {
        Fail "B3_HOME missing canonical command: $c"
    }
}
foreach ($a in $expectedAgents) {
    if (-not (Test-Path -LiteralPath (Join-Path $agentsSrc $a) -PathType Leaf)) {
        Fail "B3_HOME missing canonical agent: $a"
    }
}

$skillFiles = @(Get-ChildItem -LiteralPath $skillsSrc -Recurse -Filter 'SKILL.md' -File | Sort-Object FullName)
if ($skillFiles.Count -lt 1) { Fail "B3_HOME has no SKILL.md under: $skillsSrc" }

$skillTargets = @{}
foreach ($sf in $skillFiles) {
    $sname = Get-SkillNameFromFile $sf.FullName
    if ($skillTargets.ContainsKey($sname)) {
        Fail "duplicate canonical skill name '$sname' at $($sf.FullName)"
    }
    $skillTargets[$sname] = (Split-Path -Parent $sf.FullName)
}
$sortedSkillNames = @($skillTargets.Keys | Sort-Object)

$renderedCommands = @{}
foreach ($c in $expectedCommands) {
    $parsed = Split-Frontmatter (Join-Path $commandsSrc $c)
    $content = @(
        $parsed.Frontmatter,
        "<!-- b3-global-cursor-managed: source=$b3HomeForward/commands/$c -->",
        '',
        "**Global B3_HOME fallback:** if ``B3_HOME`` env and project ``.b3/home`` are absent, read ``~/.cursor/b3-home`` (``$b3HomeForward``). Project ``AGENTS.md`` and ``.cursor/rules/*.mdc`` override global defaults on project requirements.",
        '',
        $parsed.Body
    ) -join "`n"
    $renderedCommands[$c] = $content.TrimEnd() + "`n"
}

$renderedAgents = @{}
foreach ($a in $expectedAgents) {
    $parsed = Split-Frontmatter (Join-Path $agentsSrc $a)
    $content = @(
        $parsed.Frontmatter,
        "<!-- b3-global-cursor-managed: source=$b3HomeForward/agents/$a -->",
        '',
        "**Global B3_HOME:** resolve ``B3_HOME`` env, project ``.b3/home``, or ``~/.cursor/b3-home`` (``$b3HomeForward``).",
        '',
        $parsed.Body
    ) -join "`n"
    $renderedAgents[$a] = $content.TrimEnd() + "`n"
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

$manifest = Read-Manifest $manifestFile

# --- Verify ---
if ($Action -eq 'verify') {
    $errors = New-Object System.Collections.Generic.List[string]
    if (-not $manifest.Exists) {
        $errors.Add("missing manifest: $manifestFile")
    }
    $legacySkillDir = Join-Path $skillsDest 'b3-ai-engineering'
    if ((Test-Path -LiteralPath $legacySkillDir) -or (Test-IsReparseLink $legacySkillDir)) {
        $errors.Add("legacy b3-ai-engineering entry still exists at $legacySkillDir (run with -Force to migrate)")
    }
    if (-not (Test-Path -LiteralPath $b3HomeFile -PathType Leaf)) {
        $errors.Add("missing b3-home file: $b3HomeFile")
    } elseif ((Get-FileSha256 $b3HomeFile) -ne (Get-TextSha256 $renderedB3Home)) {
        $errors.Add("b3-home mismatch at $b3HomeFile")
    }
    if (-not (Test-Path -LiteralPath $userRulesFile -PathType Leaf)) {
        $errors.Add("missing b3-user-rules.txt: $userRulesFile")
    } elseif ((Get-FileSha256 $userRulesFile) -ne (Get-TextSha256 $renderedUserRules)) {
        $errors.Add("stale or modified b3-user-rules.txt at $userRulesFile")
    }
    foreach ($sn in $sortedSkillNames) {
        $dest = Join-Path $skillsDest $sn
        if (-not (Test-LinkTarget $dest $skillTargets[$sn]) -or -not (Test-Path -LiteralPath (Join-Path $dest 'SKILL.md') -PathType Leaf)) {
            $errors.Add("invalid or missing skill link: $dest -> $($skillTargets[$sn])")
        }
    }
    foreach ($oldSk in $manifest.Skills.Keys) {
        if (-not $skillTargets.ContainsKey($oldSk)) {
            $oldPath = Join-Path $skillsDest $oldSk
            if ((Test-Path -LiteralPath $oldPath) -or (Test-IsReparseLink $oldPath)) {
                $errors.Add("stale managed skill entry present: $oldPath")
            }
        }
    }
    foreach ($c in $expectedCommands) {
        $dest = Join-Path $commandsDest $c
        if (-not (Test-Path -LiteralPath $dest -PathType Leaf)) {
            $errors.Add("missing command: $dest")
        } elseif ((Get-FileSha256 $dest) -ne (Get-TextSha256 $renderedCommands[$c])) {
            $errors.Add("stale or modified command: $dest")
        }
    }
    foreach ($a in $expectedAgents) {
        $dest = Join-Path $agentsDest $a
        if (-not (Test-Path -LiteralPath $dest -PathType Leaf)) {
            $errors.Add("missing agent: $dest")
        } elseif ((Get-FileSha256 $dest) -ne (Get-TextSha256 $renderedAgents[$a])) {
            $errors.Add("stale or modified agent: $dest")
        }
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

foreach ($sn in $sortedSkillNames) {
    $dest = Join-Path $skillsDest $sn
    if ((Test-Path -LiteralPath $dest) -or (Test-IsReparseLink $dest)) {
        if (Test-LinkTarget $dest $skillTargets[$sn]) { continue }
        $isManaged = $manifest.Skills.ContainsKey($sn) -and ($Action -eq 'update')
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

foreach ($c in $expectedCommands) {
    $dest = Join-Path $commandsDest $c
    if (Test-Path -LiteralPath $dest -PathType Leaf) {
        $txt = [IO.File]::ReadAllText($dest, [System.Text.Encoding]::UTF8)
        if ($txt -notmatch 'b3-global-cursor-managed:' -and -not $Force) {
            Fail "refusing to overwrite unmanaged command $dest (re-run with -Force to replace)"
        }
    } elseif (Test-Path -LiteralPath $dest) {
        Fail "existing non-file path blocks command $dest"
    }
}

foreach ($a in $expectedAgents) {
    $dest = Join-Path $agentsDest $a
    if (Test-Path -LiteralPath $dest -PathType Leaf) {
        $txt = [IO.File]::ReadAllText($dest, [System.Text.Encoding]::UTF8)
        if ($txt -notmatch 'b3-global-cursor-managed:' -and -not $Force) {
            Fail "refusing to overwrite unmanaged agent $dest (re-run with -Force to replace)"
        }
    } elseif (Test-Path -LiteralPath $dest) {
        Fail "existing non-file path blocks agent $dest"
    }
}

if (Test-Path -LiteralPath $b3HomeFile) {
    if (-not (Test-Path -LiteralPath $b3HomeFile -PathType Leaf)) { Fail "existing non-file path blocks $b3HomeFile" }
    $curHome = ([IO.File]::ReadAllText($b3HomeFile, [System.Text.Encoding]::UTF8)).Trim() -replace '\\', '/'
    $homeManaged = $manifest.Files.ContainsKey('b3-home') -and ($Action -eq 'update')
    if ($curHome -ne $b3HomeForward -and -not $homeManaged -and -not $Force) {
        Fail "refusing to overwrite unmanaged $b3HomeFile (points to $curHome; re-run with -Force)"
    }
}

if (Test-Path -LiteralPath $userRulesFile) {
    if (-not (Test-Path -LiteralPath $userRulesFile -PathType Leaf)) { Fail "existing non-file path blocks $userRulesFile" }
    $txt = [IO.File]::ReadAllText($userRulesFile, [System.Text.Encoding]::UTF8)
    if ($txt -notmatch 'b3-global-cursor-managed:' -and -not $Force) {
        Fail "refusing to overwrite unmanaged $userRulesFile (re-run with -Force)"
    }
}

# --- Execute install / update (or print DryRun plan) ---
$manifestLines = New-Object System.Collections.Generic.List[string]
$manifestLines.Add('schema=b3-cursor-global-v1')
$manifestLines.Add("b3_home=$b3HomeForward")

if ($DryRun) {
    if ($removeLegacyLink) { Write-Output "dry-run: remove legacy link $legacySkillDir" }
    Write-Output "dry-run: ensure $CursorHome, write $b3HomeFile ($b3HomeForward), $userRulesFile"
    Write-Output "dry-run: link $($sortedSkillNames.Count) flattened skills under $skillsDest"
    Write-Output "dry-run: write $($expectedCommands.Count) commands under $commandsDest and $($expectedAgents.Count) agents under $agentsDest"
    foreach ($oldSk in @($manifest.Skills.Keys | Sort-Object)) {
        if (-not $skillTargets.ContainsKey($oldSk)) { Write-Output "dry-run: prune removed skill $(Join-Path $skillsDest $oldSk)" }
    }
    Check-CrossHostCoexistence $UserHome $sortedSkillNames
    Write-Output "DRY_RUN_OK: action=$Action cursor_home=$CursorHome"
    exit 0
}

foreach ($d in @($CursorHome, $skillsDest, $commandsDest, $agentsDest)) {
    if (-not (Test-Path -LiteralPath $d -PathType Container)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
}

if ($removeLegacyLink) {
    Remove-LinkOnly $legacySkillDir
    Write-Output "migrated: removed legacy link $legacySkillDir"
}

foreach ($sn in $sortedSkillNames) {
    $dest = Join-Path $skillsDest $sn
    $src = $skillTargets[$sn]
    $srcFwd = $src -replace '\\', '/'
    if (Test-LinkTarget $dest $src) {
        $manifestLines.Add("skill|$sn|$srcFwd")
        continue
    }
    if (Test-IsReparseLink $dest) {
        Remove-LinkOnly $dest
    } elseif (Test-Path -LiteralPath $dest -PathType Container) {
        Remove-Item -LiteralPath $dest -Recurse -Force
    }
    Create-DirLink $dest $src
    $manifestLines.Add("skill|$sn|$srcFwd")
}

# Prune stale skills from previous manifest
foreach ($oldSk in @($manifest.Skills.Keys | Sort-Object)) {
    if (-not $skillTargets.ContainsKey($oldSk)) {
        $oldPath = Join-Path $skillsDest $oldSk
        if (Test-IsReparseLink $oldPath) {
            Remove-LinkOnly $oldPath
        } elseif (Test-Path -LiteralPath $oldPath) {
            Write-Warning "skipping prune of non-link directory $oldPath"
        }
    }
}

foreach ($c in $expectedCommands) {
    $dest = Join-Path $commandsDest $c
    $body = $renderedCommands[$c]
    Write-Utf8NoBom $dest $body
    $manifestLines.Add("command|$c|$(Get-TextSha256 $body)")
}
foreach ($oldCmd in @($manifest.Commands.Keys | Sort-Object)) {
    if ($oldCmd -notin $expectedCommands) {
        $oldPath = Join-Path $commandsDest $oldCmd
        if ((Test-Path -LiteralPath $oldPath -PathType Leaf) -and ([IO.File]::ReadAllText($oldPath, [System.Text.Encoding]::UTF8) -match 'b3-global-cursor-managed:')) {
            Remove-Item -LiteralPath $oldPath -Force
        }
    }
}

foreach ($a in $expectedAgents) {
    $dest = Join-Path $agentsDest $a
    $body = $renderedAgents[$a]
    Write-Utf8NoBom $dest $body
    $manifestLines.Add("agent|$a|$(Get-TextSha256 $body)")
}
foreach ($oldAg in @($manifest.Agents.Keys | Sort-Object)) {
    if ($oldAg -notin $expectedAgents) {
        $oldPath = Join-Path $agentsDest $oldAg
        if ((Test-Path -LiteralPath $oldPath -PathType Leaf) -and ([IO.File]::ReadAllText($oldPath, [System.Text.Encoding]::UTF8) -match 'b3-global-cursor-managed:')) {
            Remove-Item -LiteralPath $oldPath -Force
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
