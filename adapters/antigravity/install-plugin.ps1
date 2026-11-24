# Global Antigravity plugin lifecycle manager for B3 AI Engineering (Windows PowerShell / pwsh).
# Installs, updates, verifies, or uninstalls the canonical B3 plugin bundle under ~/.gemini/config/plugins/b3-ai-engineering.
# Usage: .\adapters\antigravity\install-plugin.ps1 [-Action install|update|verify|uninstall] [-PluginRoot <dir>] [-B3Home <dir>] [-UserHome <dir>] [-DryRun] [-Force]
param(
    [Parameter(Position = 0)]
    [ValidateSet('install', 'update', 'verify', 'uninstall')]
    [string]$Action = 'install',
    [string]$PluginRoot = '',
    [string]$B3Home = '',
    [string]$UserHome = '',
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\global-common.ps1')

function Parse-CanonicalAgent([string]$FilePath, [string]$B3HomeNormalized) {
    $parsed = Split-YamlFrontmatter $FilePath -RequireFrontmatter
    $name = $null
    $readonlyVal = $null
    $descLines = New-Object System.Collections.Generic.List[string]
    $currentKey = $null
    for ($i = 1; $i -lt ($parsed.FmLines.Count - 1); $i++) {
        $line = $parsed.FmLines[$i]
        if ($line -match '^([a-zA-Z0-9_-]+):\s*(.*)$') {
            $currentKey = $Matches[1]
            $val = $Matches[2]
            if ($currentKey -eq 'name') { $name = $val.Trim() }
            elseif ($currentKey -eq 'readonly') { $readonlyVal = $val.Trim().ToLowerInvariant() }
            elseif ($currentKey -eq 'description') { $descLines.Add($line) }
        } elseif ($currentKey -eq 'description' -and ($line -match '^\s+\S' -or $line.Trim() -eq '')) {
            $descLines.Add($line)
        }
    }
    while ($descLines.Count -gt 0 -and $descLines[$descLines.Count - 1].Trim() -eq '') {
        $descLines.RemoveAt($descLines.Count - 1)
    }
    if (-not $name) { Fail "agent missing name in frontmatter: $FilePath" }
    if ($descLines.Count -eq 0) { Fail "agent missing description in frontmatter: $FilePath" }
    if ($readonlyVal -notin @('true', 'false')) { Fail "agent missing boolean readonly in frontmatter: $FilePath" }

    $toolsLine = if ($readonlyVal -eq 'true') { 'tools: [read_file]' } else { 'tools: [read_file, edit_file, write_file, run_command, manage_task]' }
    $fileName = Split-Path -Leaf $FilePath
    $outLines = New-Object System.Collections.Generic.List[string]
    $outLines.Add('---')
    $outLines.Add("name: $name")
    foreach ($dl in $descLines) { $outLines.Add($dl) }
    $outLines.Add('subagent: true')
    $outLines.Add('mainAgent: false')
    $outLines.Add($toolsLine)
    $outLines.Add('---')
    $outLines.Add('')
    $outLines.Add("<!-- Generated from $B3HomeNormalized/agents/$fileName - do not edit here -->")
    $outLines.Add('')
    if ($parsed.Body) { $outLines.Add($parsed.Body) }
    return [PSCustomObject]@{
        FileName = $fileName
        Name     = $name
        Content  = (($outLines -join "`n").TrimEnd() + "`n")
    }
}

function Test-B3PluginJson([string]$JsonPath, [switch]$AllowExtraKeys) {
    if (-not (Test-Path -LiteralPath $JsonPath -PathType Leaf)) { return $false }
    try {
        $parsed = Get-Content -LiteralPath $JsonPath -Raw | ConvertFrom-Json
        if ($parsed.name -ne 'b3-ai-engineering') { return $false }
        if ($AllowExtraKeys) { return $true }
        $allowedKeys = @('name', 'displayName', 'version', 'description', 'suggestedPrompts')
        $extra = @($parsed.PSObject.Properties | ForEach-Object { $_.Name } | Where-Object { $allowedKeys -notcontains $_ })
        return ($extra.Count -eq 0)
    } catch {
        return $false
    }
}

function Check-AntigravityCoexistence([string]$UserHomeDir, [string]$PluginRootPath, [string[]]$AllSkillNames) {
    $pluginNorm = Normalize-Path $PluginRootPath
    $looseOverlaps = Get-SkillOverlaps (Join-Path $UserHomeDir '.gemini\config\skills') $AllSkillNames
    if ($looseOverlaps.Count -gt 0) {
        Write-Output "COEXISTENCE_WARNING: ~/.gemini/config/skills contains $($looseOverlaps.Count) overlapping B3 skill(s) ($($looseOverlaps[0])...); remove loose copies to prevent duplicate discovery."
    }
    $pluginsDir = Join-Path $UserHomeDir '.gemini\config\plugins'
    if (Test-Path -LiteralPath $pluginsDir -PathType Container) {
        foreach ($cand in @(Get-ChildItem -LiteralPath $pluginsDir -Directory -Force -ErrorAction SilentlyContinue)) {
            $candNorm = Normalize-Path $cand.FullName
            if ($candNorm.Equals($pluginNorm, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            if (Test-B3PluginJson (Join-Path $cand.FullName 'plugin.json') -AllowExtraKeys) {
                Write-Output "COEXISTENCE_WARNING: duplicate b3-ai-engineering plugin found at $($cand.FullName); only one plugin directory with name 'b3-ai-engineering' should exist."
            }
        }
    }
    $agOverlaps = Get-SkillOverlaps (Join-Path $UserHomeDir '.agents\skills') $AllSkillNames
    if ($agOverlaps.Count -gt 0) {
        Write-Output "COEXISTENCE_WARNING: ~/.agents/skills contains $($agOverlaps.Count) overlapping B3 skill(s); global Antigravity discovery may duplicate bundled plugin skills."
    }
}

$scriptRoot = $PSScriptRoot
if (-not $UserHome) {
    $UserHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
}
$UserHome = Normalize-Path $UserHome
if (-not $PluginRoot) {
    $PluginRoot = Join-Path $UserHome '.gemini\config\plugins\b3-ai-engineering'
}
$PluginRoot = Normalize-Path $PluginRoot
$pluginRootForward = To-Forward $PluginRoot
$manifestFile = Join-Path $PluginRoot '.b3-plugin-manifest'

# --- Handle uninstall before requiring B3Home ---
if ($Action -eq 'uninstall') {
    if (Test-IsReparseLink $PluginRoot) { Fail "refusing to uninstall link-based PluginRoot: $PluginRoot" }
    if (Test-IsReparseLink $manifestFile) { Fail "refusing to read link-based manifest: $manifestFile" }
    $manifest = Read-B3Manifest $manifestFile
    if ($manifest.Exists -and ($manifest.Corrupt -or $manifest.Schema -ne 'b3-antigravity-plugin-v1')) {
        Fail "refusing to uninstall invalid or corrupt B3 manifest at $manifestFile"
    }
    $hasPluginJson = Test-B3PluginJson (Join-Path $PluginRoot 'plugin.json')
    if (-not $manifest.Exists -and -not $hasPluginJson) {
        if ((Test-Path -LiteralPath $PluginRoot) -or (Test-IsReparseLink $PluginRoot)) {
            Fail "refusing to uninstall unrecognized directory (missing B3 manifest or plugin.json): $PluginRoot"
        }
        Write-Output "nothing installed (no B3 plugin at $PluginRoot)"
        exit 0
    }

    $removed = 0
    $skipped = 0
    $trackedFiles = New-Object System.Collections.Generic.List[string]
    $trackedLinks = New-Object System.Collections.Generic.List[string]
    if ($manifest.Exists) {
        foreach ($fk in (Sort-OrdinalStrings @($manifest.Sections.file.Keys))) { $trackedFiles.Add($fk) }
        foreach ($lk in (Sort-OrdinalStrings @($manifest.Sections.link.Keys))) { $trackedLinks.Add($lk) }
    } else {
        # Legacy pre-manifest B3 install fallback
        if (Test-Path -LiteralPath (Join-Path $PluginRoot 'plugin.json') -PathType Leaf) { $trackedFiles.Add('plugin.json') }
        $rPath = Join-Path $PluginRoot 'rules\AGENTS.md'
        if ((Test-Path -LiteralPath $rPath -PathType Leaf) -and ([IO.File]::ReadAllText($rPath, [System.Text.Encoding]::UTF8) -match 'Generated from B3_HOME:')) {
            $trackedFiles.Add('rules/AGENTS.md')
        }
        $agDir = Join-Path $PluginRoot 'agents'
        if ((Test-Path -LiteralPath $agDir -PathType Container) -and -not (Test-IsReparseLink $agDir)) {
            foreach ($af in @(Get-ChildItem -LiteralPath $agDir -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
                if ([IO.File]::ReadAllText($af.FullName, [System.Text.Encoding]::UTF8) -match '<!-- Generated from .*/(\.cursor/)?agents/') {
                    $trackedFiles.Add("agents/$($af.Name)")
                }
            }
        }
        $skDir = Join-Path $PluginRoot 'skills'
        if ((Test-Path -LiteralPath $skDir -PathType Container) -and -not (Test-IsReparseLink $skDir)) {
            foreach ($sk in @(Get-ChildItem -LiteralPath $skDir -Force -ErrorAction SilentlyContinue)) {
                if (Test-IsReparseLink $sk.FullName) { $trackedLinks.Add("skills/$($sk.Name)") }
            }
        }
    }

    $skillsContainer = Join-Path $PluginRoot 'skills'
    if (Test-IsReparseLink $skillsContainer) {
        Write-Warning "skipping symlinked skills directory: $skillsContainer"
        $skipped++
    } else {
        foreach ($lk in $trackedLinks) {
            $p = Join-Path $PluginRoot ($lk -replace '/', '\')
            if (-not (Test-PathWithinRoot $PluginRoot $p)) { Fail "refusing to uninstall path outside PluginRoot: $p" }
            if (Test-IsReparseLink $p) {
                if ($manifest.Exists -and -not $Force) {
                    $expTarget = if ($manifest.Sections.link.ContainsKey($lk)) { $manifest.Sections.link[$lk] } else { '' }
                    if (-not $expTarget -or -not (Test-LinkTarget $p $expTarget)) {
                        Write-Warning "skipping retargeted skill link: $p (expected $expTarget; re-run with -Force to remove)"
                        $skipped++
                        continue
                    }
                }
                if ($DryRun) { Write-Output "dry-run: remove skill link $p" } else { Remove-LinkOnly $p }
                $removed++
            } elseif (Test-Path -LiteralPath $p) {
                Write-Warning "skipping unmanaged non-link entry: $p"
            }
        }
    }
    $warnedContainers = @{}
    foreach ($fk in $trackedFiles) {
        $p = Join-Path $PluginRoot ($fk -replace '/', '\')
        if (-not (Test-PathWithinRoot $PluginRoot $p)) { Fail "refusing to uninstall path outside PluginRoot: $p" }
        $parentDir = Split-Path -Parent $p
        if ((Normalize-Path $parentDir) -ne $PluginRoot -and (Test-IsReparseLink $parentDir)) {
            if (-not $warnedContainers.ContainsKey($parentDir)) {
                Write-Warning "skipping symlinked container directory: $parentDir"
                $warnedContainers[$parentDir] = $true
            }
            $skipped++
            continue
        }
        if (Test-IsReparseLink $p) {
            Write-Warning "skipping symlinked file path: $p"
            $skipped++
            continue
        }
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            if ($manifest.Exists -and -not $Force) {
                $expSha = if ($manifest.Sections.file.ContainsKey($fk)) { $manifest.Sections.file[$fk] } else { '' }
                if (-not $expSha -or ((Get-FileSha256 $p) -ne $expSha)) {
                    Write-Warning "skipping modified managed file: $p (re-run with -Force to remove)"
                    $skipped++
                    continue
                }
            }
            if ($DryRun) { Write-Output "dry-run: remove file $p" } else { Remove-Item -LiteralPath $p -Force }
            $removed++
        }
    }
    if (-not $DryRun) {
        foreach ($subDir in @('skills', 'rules', 'agents')) { Remove-EmptyRegularDir (Join-Path $PluginRoot $subDir) }
    }
    if ($skipped -gt 0) {
        Write-Output "UNINSTALL_CONFLICT: removed=$removed skipped=$skipped plugin_root=$PluginRoot (re-run with -Force to remove modified managed entries)"
        exit 1
    }
    if ($manifest.Exists -and (Test-Path -LiteralPath $manifestFile -PathType Leaf) -and -not (Test-IsReparseLink $manifestFile)) {
        if ($DryRun) { Write-Output "dry-run: remove manifest $manifestFile" } else { Remove-Item -LiteralPath $manifestFile -Force }
        $removed++
    }
    if (-not $DryRun) {
        foreach ($subDir in @('skills', 'rules', 'agents')) { Remove-EmptyRegularDir (Join-Path $PluginRoot $subDir) }
        Remove-EmptyRegularDir $PluginRoot
    }
    Write-Output "UNINSTALL_OK: removed=$removed plugin_root=$PluginRoot"
    exit 0
}

# --- Resolve and validate B3Home (install / update / verify) ---
if (-not $B3Home) { $B3Home = Split-Path -Parent (Split-Path -Parent $scriptRoot) }
if (-not (Test-Path -LiteralPath $B3Home -PathType Container)) { Fail "B3Home not found: $B3Home" }
$B3Home = Normalize-Path (Resolve-Path -LiteralPath $B3Home).Path
$b3HomeForward = To-Forward $B3Home

$workflowPath = Join-Path $B3Home 'workflows\ship.md'
$skillsSrc = Join-Path $B3Home 'skills'
$cmdSkillsSrc = Join-Path $B3Home 'adapters\command-skills'
$rulesDir = Join-Path $B3Home 'rules'
$agentsDir = Join-Path $B3Home 'agents'

if (-not (Test-Path -LiteralPath $workflowPath -PathType Leaf)) { Fail "B3_HOME missing workflow: $workflowPath" }
if (-not (Test-Path -LiteralPath $skillsSrc -PathType Container)) { Fail "B3_HOME missing skills: $skillsSrc" }

$coreSkillMap = @{}
$cmdSkillMap = @{}
$skillMap = @{}
if ((Add-CanonicalSkills $skillsSrc $skillMap $coreSkillMap) -lt 1) { Fail "B3_HOME has no SKILL.md under skills: $skillsSrc" }
if (-not (Test-Path -LiteralPath $cmdSkillsSrc -PathType Container) -or (Add-CanonicalSkills $cmdSkillsSrc $skillMap $cmdSkillMap) -lt 1) {
    Fail "B3_HOME has no command skills under: $cmdSkillsSrc"
}
$sortedSkillNames = Sort-OrdinalStrings @($skillMap.Keys)

$ruleFiles = Sort-FilesOrdinalByFullName @(Get-ChildItem -LiteralPath $rulesDir -Filter '*.md' -File -ErrorAction SilentlyContinue)
if ($ruleFiles.Count -lt 1) { Fail "B3_HOME has no rules under $rulesDir" }

$rulesHeader = @"
# B3 AI Engineering Rules

Generated from B3_HOME: ``$b3HomeForward`` (do not edit here).
Resolve B3_HOME from ``B3_HOME`` env, product ``.b3/home``, or ``$b3HomeForward``.
Precedence: ``$b3HomeForward/docs/precedence.md``. Ship: ``$b3HomeForward/workflows/ship.md``. Review loop: ``$b3HomeForward/review-loop/strategy.md``.
Project-level AGENTS.md, GEMINI.md, .agents/rules/, and .agents/skills/ override this global baseline within their project scope; per-project install-product is optional.
B3 commands (``/b3-plan``, ``/b3-implement``, ``/b3-debug``, ``/b3-review``, ``/b3-verify``, ``/b3-review-loop``, ``/b3-ship``, ``/b3-research-ship``) and workflows remain available across local projects via bundled skills using the fallback B3_HOME above.
"@
$rulesParts = New-Object System.Collections.Generic.List[string]
$rulesParts.Add($rulesHeader.Trim())
foreach ($rf in $ruleFiles) {
    $stripped = (Split-YamlFrontmatter $rf.FullName).Body
    if ($stripped) { $rulesParts.Add($stripped) }
}
$rulesContent = (($rulesParts -join "`n`n---`n`n").TrimEnd() + "`n")
$rulesBytes = $script:B3Utf8NoBom.GetByteCount($rulesContent)
if ($rulesBytes -ge 24000) { Fail "generated rules/AGENTS.md is $rulesBytes bytes (must stay under 24000 bytes)" }

$agentFiles = Sort-FilesOrdinalByFullName @(Get-ChildItem -LiteralPath $agentsDir -Filter '*.md' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'README.md' })
if ($agentFiles.Count -lt 1) { Fail "B3_HOME has no agent definitions under $agentsDir" }
$renderedAgents = New-Object System.Collections.Generic.List[object]
foreach ($af in $agentFiles) { $renderedAgents.Add((Parse-CanonicalAgent $af.FullName $b3HomeForward)) }

$pluginJson = (@'
{
  "name": "b3-ai-engineering",
  "displayName": "B3 AI Engineering",
  "version": "1.0.0",
  "description": "Personal AI engineering system: portable rules, engineering and domain skills, independent review-loop roles, and autonomous development lifecycle.",
  "suggestedPrompts": [
    "Run /b3-ship for a new feature or plan in this repository",
    "Run an independent review-loop on the current git diff",
    "Create an implementation plan without editing code yet"
  ]
}
'@ + "`n").Replace("`r`n", "`n")

# --- Verify action (checks each capability surface independently) ---
if ($Action -eq 'verify') {
    $errors = New-Object System.Collections.Generic.List[string]
    $pluginOk = $true; $rulesOk = $true; $skillsOk = $true; $commandsOk = $true; $agentsOk = $true

    if (-not (Test-Path -LiteralPath $PluginRoot -PathType Container) -or (Test-IsReparseLink $PluginRoot)) {
        $pluginOk = $false; $rulesOk = $false; $skillsOk = $false; $commandsOk = $false; $agentsOk = $false
        $errors.Add("plugin directory missing or invalid: $PluginRoot")
    } else {
        if (Test-IsReparseLink $manifestFile) {
            $manifest = [PSCustomObject]@{ Exists = $false; Corrupt = $false; Schema = ''; Sections = @{ skill=@{}; command=@{}; agent=@{}; file=@{}; link=@{} } }
            $pluginOk = $false
            $errors.Add("missing or invalid .b3-plugin-manifest at $manifestFile")
        } else {
            $manifest = Read-B3Manifest $manifestFile
            if (-not $manifest.Exists -or $manifest.Corrupt -or $manifest.Schema -ne 'b3-antigravity-plugin-v1') {
                $pluginOk = $false
                $errors.Add("missing or invalid .b3-plugin-manifest at $manifestFile")
            }
        }
        $pjPath = Join-Path $PluginRoot 'plugin.json'
        if (Test-IsReparseLink $pjPath) {
            $pluginOk = $false; $errors.Add("plugin.json is a link (expected regular file): $pjPath")
        } elseif (-not (Test-B3PluginJson $pjPath)) {
            $pluginOk = $false; $errors.Add("missing or invalid plugin.json at $pjPath")
        } elseif ((Get-FileSha256 $pjPath) -ne (Get-TextSha256 $pluginJson)) {
            $pluginOk = $false; $errors.Add("stale or modified plugin.json at $pjPath")
        }

        $rulesDirOut = Join-Path $PluginRoot 'rules'
        $rulesOut = Join-Path $rulesDirOut 'AGENTS.md'
        if (Test-IsReparseLink $rulesDirOut) {
            $rulesOk = $false; $errors.Add("rules directory is a link (expected regular directory): $rulesDirOut")
        } elseif (Test-IsReparseLink $rulesOut) {
            $rulesOk = $false; $errors.Add("rules/AGENTS.md is a link (expected regular file): $rulesOut")
        } elseif (-not (Test-Path -LiteralPath $rulesOut -PathType Leaf)) {
            $rulesOk = $false; $errors.Add("missing rules/AGENTS.md at $rulesOut")
        } else {
            $rInfo = Read-FileInfo $rulesOut
            if ($rInfo.Length -ge 24000 -or ($rInfo.Text.TrimStart() -match '^---')) {
                $rulesOk = $false; $errors.Add("invalid rules/AGENTS.md format or size ($($rInfo.Length) B)")
            } elseif ($rInfo.Sha256 -ne (Get-TextSha256 $rulesContent)) {
                $rulesOk = $false; $errors.Add("stale or modified rules/AGENTS.md at $rulesOut")
            }
        }

        $skillsOut = Join-Path $PluginRoot 'skills'
        if (Test-IsReparseLink $skillsOut) {
            $skillsOk = $false; $commandsOk = $false
            $errors.Add("skills directory is a link (expected container of 1-level skill links): $skillsOut")
        } else {
            foreach ($sn in (Sort-OrdinalStrings @($coreSkillMap.Keys))) {
                $dest = Join-Path $skillsOut $sn
                if (-not (Test-LinkTarget $dest $coreSkillMap[$sn]) -or -not (Test-Path -LiteralPath (Join-Path $dest 'SKILL.md') -PathType Leaf)) {
                    $skillsOk = $false; $errors.Add("missing or broken skill link: $dest -> $($coreSkillMap[$sn])")
                }
            }
            if (Test-Path -LiteralPath $skillsOut -PathType Container) {
                foreach ($child in @(Get-ChildItem -LiteralPath $skillsOut -Force)) {
                    if ((Test-IsReparseLink $child.FullName) -and -not $skillMap.ContainsKey($child.Name) -and $manifest.Sections.link.ContainsKey("skills/$($child.Name)")) {
                        $skillsOk = $false; $errors.Add("stale managed skill link present: $($child.FullName)")
                    }
                }
            }
            foreach ($cn in (Sort-OrdinalStrings @($cmdSkillMap.Keys))) {
                $dest = Join-Path $skillsOut $cn
                if (-not (Test-LinkTarget $dest $cmdSkillMap[$cn]) -or -not (Test-Path -LiteralPath (Join-Path $dest 'SKILL.md') -PathType Leaf)) {
                    $commandsOk = $false; $errors.Add("missing or broken command-skill link: $dest -> $($cmdSkillMap[$cn])")
                }
            }
        }
        foreach ($coreCmd in @('b3-plan', 'b3-implement', 'b3-debug', 'b3-review', 'b3-verify', 'b3-review-loop', 'b3-ship', 'b3-research-ship')) {
            if (-not $cmdSkillMap.ContainsKey($coreCmd)) {
                $commandsOk = $false; $errors.Add("missing expected command skill in B3_HOME: $coreCmd")
            }
        }

        $agentsOut = Join-Path $PluginRoot 'agents'
        $expectedAgentSet = @($renderedAgents | ForEach-Object { $_.FileName })
        if (Test-IsReparseLink $agentsOut) {
            $agentsOk = $false; $errors.Add("agents directory is a link (expected regular directory): $agentsOut")
        } else {
            foreach ($ag in $renderedAgents) {
                $dest = Join-Path $agentsOut $ag.FileName
                if (Test-IsReparseLink $dest) {
                    $agentsOk = $false; $errors.Add("agent file is a link (expected regular file): $dest")
                } elseif (-not (Test-Path -LiteralPath $dest -PathType Leaf)) {
                    $agentsOk = $false; $errors.Add("missing agent file: $dest")
                } else {
                    $aInfo = Read-FileInfo $dest
                    if ($aInfo.Sha256 -ne (Get-TextSha256 $ag.Content)) {
                        $agentsOk = $false; $errors.Add("stale or modified agent file: $dest")
                    } elseif (($aInfo.Text -notmatch '(?m)^subagent:\s*true\s*$') -or ($aInfo.Text -notmatch '(?m)^mainAgent:\s*false\s*$') -or ($aInfo.Text -notmatch '(?m)^tools:\s*\[')) {
                        $agentsOk = $false; $errors.Add("invalid subagent frontmatter in: $dest")
                    }
                }
            }
            if (Test-Path -LiteralPath $agentsOut -PathType Container) {
                foreach ($existingAg in @(Get-ChildItem -LiteralPath $agentsOut -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
                    if ($expectedAgentSet -notcontains $existingAg.Name -and $manifest.Exists -and $manifest.Sections.file.ContainsKey("agents/$($existingAg.Name)")) {
                        $agentsOk = $false; $errors.Add("stale generated agent file present: $($existingAg.FullName)")
                    }
                }
            }
        }
    }

    Write-Output ("check.plugin={0}" -f $(if ($pluginOk) { 'OK' } else { 'FAIL' }))
    Write-Output ("check.rules={0}" -f $(if ($rulesOk) { 'OK' } else { 'FAIL' }))
    Write-Output ("check.skills={0}" -f $(if ($skillsOk) { 'OK' } else { 'FAIL' }))
    Write-Output ("check.commands={0}" -f $(if ($commandsOk) { 'OK' } else { 'FAIL' }))
    Write-Output ("check.agents={0}" -f $(if ($agentsOk) { 'OK' } else { 'FAIL' }))

    Check-AntigravityCoexistence $UserHome $PluginRoot $sortedSkillNames

    if ($errors.Count -gt 0) {
        foreach ($e in $errors) { Write-Output "VERIFY_ERROR: $e" }
        Write-Output "VERIFY_FAIL: errors=$($errors.Count) plugin_root=$PluginRoot"
        Write-Output "note: filesystem verification only -- Antigravity runtime discovery is UNKNOWN / INCOMPLETE until verified in a live session"
        exit 1
    }
    Write-Output "VERIFY_OK: skills=$($coreSkillMap.Count) commands=$($cmdSkillMap.Count) agents=$($renderedAgents.Count) rules_bytes=$rulesBytes plugin_root=$PluginRoot b3_home=$b3HomeForward"
    Write-Output "note: filesystem verification only -- Antigravity runtime discovery is UNKNOWN / INCOMPLETE until verified in a live session"
    exit 0
}

# --- Fail-closed preflight checks before any write (install / update) ---
if (Test-IsReparseLink $manifestFile) { Fail "existing link blocks managed file: $manifestFile" }
$oldManifest = Read-B3Manifest $manifestFile
if ($oldManifest.Exists -and ($oldManifest.Corrupt -or $oldManifest.Schema -ne 'b3-antigravity-plugin-v1')) {
    Fail "refusing to update invalid B3 manifest at $manifestFile"
}

if ((Test-Path -LiteralPath $PluginRoot) -or (Test-IsReparseLink $PluginRoot)) {
    if (Test-IsReparseLink $PluginRoot) { Fail "refusing to replace link at PluginRoot: $PluginRoot" }
    if (-not (Test-Path -LiteralPath $PluginRoot -PathType Container)) { Fail "refusing to replace existing file: $PluginRoot" }
    $isB3Plugin = $oldManifest.Exists -or (Test-B3PluginJson (Join-Path $PluginRoot 'plugin.json'))
    if (-not $isB3Plugin -and -not $Force) {
        Fail "refusing to overwrite existing non-B3 directory without -Force: $PluginRoot"
    }
    foreach ($subName in @('rules', 'skills', 'agents')) {
        Assert-RegularDirOrMissing (Join-Path $PluginRoot $subName) $subName
    }
    $managedFilePaths = New-Object System.Collections.Generic.List[string]
    $managedFilePaths.Add((Join-Path $PluginRoot 'plugin.json'))
    $managedFilePaths.Add((Join-Path $PluginRoot 'rules\AGENTS.md'))
    $managedFilePaths.Add($manifestFile)
    foreach ($ag in $renderedAgents) { $managedFilePaths.Add((Join-Path $PluginRoot "agents\$($ag.FileName)")) }
    foreach ($mp in $managedFilePaths) {
        if (-not ((Test-Path -LiteralPath $mp) -or (Test-IsReparseLink $mp))) { continue }
        Assert-RegularFileOrMissing $mp 'managed file'
        if ($mp -eq $manifestFile) { continue }
        $rel = $mp.Substring($PluginRoot.Length).TrimStart('\', '/') -replace '\\', '/'
        $expectedSha = if ($oldManifest.Sections.file.ContainsKey($rel)) { $oldManifest.Sections.file[$rel] } else { '' }
        if (-not $Force -and (-not $expectedSha -or (Get-FileSha256 $mp) -ne $expectedSha)) {
            Fail "UPDATE_CONFLICT: unmanaged or modified file: $mp (preserved; use -Force only after backing it up)"
        }
    }
    $existingSkillsDir = Join-Path $PluginRoot 'skills'
    if (Test-Path -LiteralPath $existingSkillsDir -PathType Container) {
        foreach ($child in @(Get-ChildItem -LiteralPath $existingSkillsDir -Force)) {
            $key = "skills/$($child.Name)"
            $desired = $skillMap.ContainsKey($child.Name)
            $tracked = $oldManifest.Sections.link.ContainsKey($key)
            if (Test-IsReparseLink $child.FullName) {
                if ($tracked) {
                    if (-not $Force -and -not (Test-LinkTarget $child.FullName $oldManifest.Sections.link[$key] -RawTargetOnly)) {
                        Fail "UPDATE_CONFLICT: modified B3 skill link: $($child.FullName)"
                    }
                } elseif ($desired) {
                    Fail "UPDATE_CONFLICT: untracked skill link: $($child.FullName) (move it manually; -Force cannot delete it)"
                }
                continue
            }
            if ($desired -and (-not $Force -or -not (Test-Path -LiteralPath (Join-Path $child.FullName 'SKILL.md') -PathType Leaf))) {
                Fail "UPDATE_CONFLICT: existing skill directory: $($child.FullName) (explicit -Force requires a valid SKILL.md)"
            }
        }
    }
    $expectedAgentFiles = @($renderedAgents | ForEach-Object { $_.FileName })
    $agentDirForPrune = Join-Path $PluginRoot 'agents'
    if (Test-Path -LiteralPath $agentDirForPrune -PathType Container) {
        foreach ($af in @(Get-ChildItem -LiteralPath $agentDirForPrune -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
            if ($expectedAgentFiles -contains $af.Name) { continue }
            $rel = "agents/$($af.Name)"
            if ($oldManifest.Sections.file.ContainsKey($rel) -and -not $Force -and ((Get-FileSha256 $af.FullName) -ne $oldManifest.Sections.file[$rel])) {
                Fail "UPDATE_CONFLICT: modified stale B3 agent: $($af.FullName)"
            }
        }
    }
}

$manifestLines = New-Object System.Collections.Generic.List[string]
$manifestLines.Add('schema=b3-antigravity-plugin-v1')
$manifestLines.Add("b3_home=$b3HomeForward")
$manifestLines.Add("plugin_root=$pluginRootForward")

if ($DryRun) {
    Write-Output "dry-run: action=$Action plugin_root=$PluginRoot"
    Write-Output "dry-run: B3_HOME=$B3Home"
    Write-Output "dry-run: write $PluginRoot\plugin.json"
    Write-Output "dry-run: write $PluginRoot\rules\AGENTS.md ($rulesBytes bytes)"
    Write-Output "dry-run: link $($skillMap.Count) skills ($($coreSkillMap.Count) skills + $($cmdSkillMap.Count) command-skills) into $PluginRoot\skills"
    Write-Output "dry-run: write $($renderedAgents.Count) agents into $PluginRoot\agents"
    Check-AntigravityCoexistence $UserHome $PluginRoot $sortedSkillNames
    Write-Output "DRY_RUN_OK: action=$Action plugin_root=$PluginRoot"
    exit 0
}

$rulesOutDir = Join-Path $PluginRoot 'rules'
$skillsOutDir = Join-Path $PluginRoot 'skills'
$agentsOutDir = Join-Path $PluginRoot 'agents'
foreach ($d in @($PluginRoot, $rulesOutDir, $skillsOutDir, $agentsOutDir)) {
    if (-not (Test-Path -LiteralPath $d -PathType Container)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

Write-Utf8NoBom (Join-Path $PluginRoot 'plugin.json') $pluginJson
$manifestLines.Add("file|plugin.json|$(Get-TextSha256 $pluginJson)")
Write-Utf8NoBom (Join-Path $rulesOutDir 'AGENTS.md') $rulesContent
$manifestLines.Add("file|rules/AGENTS.md|$(Get-TextSha256 $rulesContent)")

foreach ($child in @(Get-ChildItem -LiteralPath $skillsOutDir -Force)) {
    $key = "skills/$($child.Name)"
    if (Test-IsReparseLink $child.FullName) {
        if ($oldManifest.Sections.link.ContainsKey($key) -and -not $skillMap.ContainsKey($child.Name)) {
            Remove-LinkOnly $child.FullName
        }
    } elseif ($Force -and $skillMap.ContainsKey($child.Name)) {
        Remove-DirTreeSafely $child.FullName
    }
}
foreach ($sn in $sortedSkillNames) {
    $src = $skillMap[$sn]
    $dest = Join-Path $skillsOutDir $sn
    if (-not (Test-LinkTarget $dest $src)) {
        if (Test-IsReparseLink $dest) {
            if (-not $oldManifest.Sections.link.ContainsKey("skills/$sn")) {
                Fail "UPDATE_CONFLICT: refusing to replace untracked skill link: $dest"
            }
            Remove-LinkOnly $dest
        }
        Create-DirLink $dest $src
    }
    $manifestLines.Add("link|skills/$sn|$(To-Forward $src)")
}

$expectedAgentFiles = @($renderedAgents | ForEach-Object { $_.FileName })
foreach ($existingAgent in @(Get-ChildItem -LiteralPath $agentsOutDir -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
    if (($expectedAgentFiles -notcontains $existingAgent.Name) -and $oldManifest.Sections.file.ContainsKey("agents/$($existingAgent.Name)")) {
        Remove-Item -LiteralPath $existingAgent.FullName -Force
    }
}
foreach ($ag in $renderedAgents) {
    Write-Utf8NoBom (Join-Path $agentsOutDir $ag.FileName) $ag.Content
    $manifestLines.Add("file|agents/$($ag.FileName)|$(Get-TextSha256 $ag.Content)")
}

Write-Utf8NoBom $manifestFile (($manifestLines -join "`n") + "`n")

Check-AntigravityCoexistence $UserHome $PluginRoot $sortedSkillNames
$pluginDirName = Split-Path -Leaf $PluginRoot
Write-Output ("{0}_OK: skills={1} commands={2} agents={3} rules_bytes={4} plugin_root={5} b3_home={6}" -f $Action.ToUpperInvariant(), $coreSkillMap.Count, $cmdSkillMap.Count, $renderedAgents.Count, $rulesBytes, $PluginRoot, $b3HomeForward)
Write-Output "installed Antigravity plugin at $PluginRoot"
Write-Output "B3_HOME=$B3Home"
Write-Output "skills=$($skillMap.Count)"
Write-Output "agents=$($renderedAgents.Count)"
Write-Output "rules_bytes=$rulesBytes"
Write-Output "manage=customization://$pluginDirName"
Write-Output "note: this proves plugin files were generated, not Antigravity runtime discovery"
