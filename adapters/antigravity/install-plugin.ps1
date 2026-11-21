param(
    [string]$PluginRoot,
    [string]$B3Home,
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Remove-ReparseItem([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    $isLink = ($item.LinkType -in @('Junction', 'SymbolicLink')) -or (($item.Attributes.ToString()) -match 'ReparsePoint')
    if (-not $isLink) {
        Fail "refusing to remove non-link entry without -Force: $Path"
    }
    if ($item.PSIsContainer) {
        & cmd.exe /c rmdir "$Path" | Out-Null
        if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath $Path)) { Fail "could not remove link directory $Path" }
    } else {
        Remove-Item -LiteralPath $Path -Force
    }
}

function Strip-YamlFrontmatter([string]$Text) {
    $normalized = $Text -replace "`r`n", "`n"
    $lines = $normalized -split "`n"
    if ($lines.Count -ge 3 -and $lines[0].Trim() -eq '---') {
        for ($i = 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Trim() -eq '---') {
                $bodyLines = @()
                if ($i + 1 -lt $lines.Count) {
                    $bodyLines = $lines[($i + 1)..($lines.Count - 1)]
                }
                return (($bodyLines -join "`n").TrimStart("`n")).TrimEnd()
            }
        }
    }
    return $normalized.Trim()
}

function Parse-CursorAgent([string]$FilePath, [string]$B3HomeNormalized) {
    $raw = (Get-Content -LiteralPath $FilePath -Raw) -replace "`r`n", "`n"
    $lines = $raw -split "`n"
    if ($lines.Count -lt 3 -or $lines[0].Trim() -ne '---') {
        Fail "agent missing YAML frontmatter: $FilePath"
    }
    $endIdx = -1
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq '---') {
            $endIdx = $i
            break
        }
    }
    if ($endIdx -lt 0) {
        Fail "agent frontmatter not closed: $FilePath"
    }

    $name = $null
    $readonlyVal = $null
    $descLines = New-Object System.Collections.Generic.List[string]
    $currentKey = $null

    for ($i = 1; $i -lt $endIdx; $i++) {
        $line = $lines[$i]
        if ($line -match '^([a-zA-Z0-9_-]+):\s*(.*)$') {
            $currentKey = $Matches[1]
            $val = $Matches[2]
            if ($currentKey -eq 'name') {
                $name = $val.Trim()
            } elseif ($currentKey -eq 'readonly') {
                $readonlyVal = $val.Trim().ToLowerInvariant()
            } elseif ($currentKey -eq 'description') {
                $descLines.Add($line)
            }
        } elseif ($currentKey -eq 'description' -and ($line -match '^\s+\S' -or $line.Trim() -eq '')) {
            $descLines.Add($line)
        }
    }

    while ($descLines.Count -gt 0 -and $descLines[$descLines.Count - 1].Trim() -eq '') {
        $descLines.RemoveAt($descLines.Count - 1)
    }

    if (-not $name) { Fail "agent missing name in frontmatter: $FilePath" }
    if ($descLines.Count -eq 0) { Fail "agent missing description in frontmatter: $FilePath" }
    if ($readonlyVal -notin @('true', 'false')) {
        Fail "agent missing boolean readonly in frontmatter: $FilePath"
    }

    $toolsLine = if ($readonlyVal -eq 'true') {
        'tools: [read_file]'
    } else {
        'tools: [read_file, edit_file, write_file, run_command, manage_task]'
    }

    $body = ''
    if ($endIdx + 1 -lt $lines.Count) {
        $body = ($lines[($endIdx + 1)..($lines.Count - 1)] -join "`n").TrimStart("`n").TrimEnd()
    }

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
    $outLines.Add("<!-- Generated from $B3HomeNormalized/.cursor/agents/$fileName - do not edit here -->")
    $outLines.Add('')
    if ($body) { $outLines.Add($body) }

    return [PSCustomObject]@{
        FileName = $fileName
        Name     = $name
        Content  = (($outLines -join "`n").TrimEnd() + "`n")
    }
}

$scriptRoot = $PSScriptRoot
if (-not $B3Home) {
    $B3Home = Split-Path -Parent (Split-Path -Parent $scriptRoot)
}
if (-not (Test-Path -LiteralPath $B3Home)) { Fail "B3Home not found: $B3Home" }
$B3Home = (Resolve-Path -LiteralPath $B3Home).Path.TrimEnd('\')
$b3HomeForward = $B3Home -replace '\\', '/'

if (-not $PluginRoot) {
    $userHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
    $PluginRoot = Join-Path $userHome '.gemini\config\plugins\b3-ai-engineering'
}

$workflowPath = Join-Path $B3Home 'workflows\autonomous-development.md'
$skillsSrc = Join-Path $B3Home '.cursor\skills'
$cmdSkillsSrc = Join-Path $B3Home 'adapters\codex-command-skills'
$rulesDir = Join-Path $B3Home 'rules'
$agentsDir = Join-Path $B3Home '.cursor\agents'

if (-not (Test-Path -LiteralPath $workflowPath -PathType Leaf)) {
    Fail "B3_HOME missing workflow: $workflowPath"
}
if (-not (Test-Path -LiteralPath $skillsSrc -PathType Container)) {
    Fail "B3_HOME missing .cursor/skills: $skillsSrc"
}

$canonicalSkillFiles = @(Get-ChildItem -LiteralPath $skillsSrc -Recurse -Filter 'SKILL.md' -File | Sort-Object FullName)
if ($canonicalSkillFiles.Count -lt 1) {
    Fail "B3_HOME has no SKILL.md under .cursor/skills: $skillsSrc"
}
$cmdSkillFiles = @()
if (Test-Path -LiteralPath $cmdSkillsSrc -PathType Container) {
    $cmdSkillFiles = @(Get-ChildItem -LiteralPath $cmdSkillsSrc -Recurse -Filter 'SKILL.md' -File | Sort-Object FullName)
}

$skillMap = @{}
$skillEntries = New-Object System.Collections.Generic.List[object]
foreach ($sf in @($canonicalSkillFiles + $cmdSkillFiles)) {
    $raw = Get-Content -LiteralPath $sf.FullName -Raw
    $skillName = if ($raw -match '(?m)^name:\s*([a-z0-9-]+)\s*$') { $Matches[1] } else { Split-Path -Leaf (Split-Path -Parent $sf.FullName) }
    if ($skillMap.ContainsKey($skillName)) {
        Fail "duplicate skill name '$skillName': $($skillMap[$skillName]) and $($sf.FullName)"
    }
    $srcDir = Split-Path -Parent $sf.FullName
    $skillMap[$skillName] = $srcDir
    $skillEntries.Add([PSCustomObject]@{ Name = $skillName; Source = $srcDir })
}

$ruleFiles = @(Get-ChildItem -LiteralPath $rulesDir -Filter '*.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)
if ($ruleFiles.Count -lt 1) {
    Fail "B3_HOME has no rules under $rulesDir"
}

$rulesHeader = @"
# B3 AI Engineering Rules

Generated from B3_HOME: ``$b3HomeForward`` (do not edit here).
Resolve B3_HOME from ``B3_HOME`` env, product ``.b3/home``, or ``$b3HomeForward``.
Precedence: ``$b3HomeForward/docs/precedence.md``. Autodev: ``$b3HomeForward/workflows/autonomous-development.md``. Review loop: ``$b3HomeForward/review-loop/spec.md``.
"@
$rulesParts = New-Object System.Collections.Generic.List[string]
$rulesParts.Add($rulesHeader.Trim())
foreach ($rf in $ruleFiles) {
    $stripped = Strip-YamlFrontmatter (Get-Content -LiteralPath $rf.FullName -Raw)
    if ($stripped) { $rulesParts.Add($stripped) }
}
$rulesContent = (($rulesParts -join "`n`n---`n`n").TrimEnd() + "`n")
$rulesBytes = [System.Text.Encoding]::UTF8.GetByteCount($rulesContent)
if ($rulesBytes -ge 24000) {
    Fail "generated rules/AGENTS.md is $rulesBytes bytes (must stay under 24000 bytes)"
}

$agentFiles = @(Get-ChildItem -LiteralPath $agentsDir -Filter '*.md' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'README.md' } | Sort-Object Name)
if ($agentFiles.Count -lt 1) {
    Fail "B3_HOME has no agent definitions under $agentsDir"
}
$renderedAgents = New-Object System.Collections.Generic.List[object]
foreach ($af in $agentFiles) {
    $renderedAgents.Add((Parse-CursorAgent $af.FullName $b3HomeForward))
}

# Fail-closed checks on existing $PluginRoot before writing anything
if (Test-Path -LiteralPath $PluginRoot) {
    $rootItem = Get-Item -LiteralPath $PluginRoot -Force
    if (-not $rootItem.PSIsContainer) {
        Fail "refusing to replace existing file: $PluginRoot"
    }
    $existingManifest = Join-Path $PluginRoot 'plugin.json'
    $isB3Plugin = $false
    if (Test-Path -LiteralPath $existingManifest -PathType Leaf) {
        try {
            $parsed = Get-Content -LiteralPath $existingManifest -Raw | ConvertFrom-Json
            if ($parsed.name -eq 'b3-ai-engineering') { $isB3Plugin = $true }
        } catch {
            $isB3Plugin = $false
        }
    }
    if (-not $isB3Plugin -and -not $Force) {
        Fail "refusing to overwrite existing non-B3 directory without -Force: $PluginRoot"
    }
    $existingSkillsDir = Join-Path $PluginRoot 'skills'
    if ((Test-Path -LiteralPath $existingSkillsDir -PathType Container) -and -not $Force) {
        foreach ($child in @(Get-ChildItem -LiteralPath $existingSkillsDir -Force)) {
            $isLink = ($child.LinkType -in @('Junction', 'SymbolicLink')) -or (($child.Attributes.ToString()) -match 'ReparsePoint')
            if (-not $isLink) {
                Fail "refusing to overwrite non-link entry in $existingSkillsDir without -Force: $($child.FullName)"
            }
        }
    }
}

$pluginJson = @'
{
  "name": "b3-ai-engineering",
  "displayName": "B3 AI Engineering",
  "version": "1.0.0",
  "description": "Personal AI engineering system: portable rules, engineering and domain skills, independent review-loop roles, and autonomous development lifecycle.",
  "suggestedPrompts": [
    "Run autodev for a new feature or plan in this repository",
    "Run an independent review-loop on the current git diff",
    "Create an implementation plan without editing code yet"
  ]
}
'@ + "`n"
$pluginJson = $pluginJson -replace "`r`n", "`n"

if ($DryRun) {
    Write-Output "dry-run: plugin_root=$PluginRoot"
    Write-Output "dry-run: B3_HOME=$B3Home"
    Write-Output "dry-run: write $PluginRoot\plugin.json"
    Write-Output "dry-run: write $PluginRoot\rules\AGENTS.md ($rulesBytes bytes)"
    Write-Output "dry-run: link $($skillEntries.Count) skills into $PluginRoot\skills"
    Write-Output "dry-run: write $($renderedAgents.Count) agents into $PluginRoot\agents"
    exit 0
}

$rulesOutDir = Join-Path $PluginRoot 'rules'
$skillsOutDir = Join-Path $PluginRoot 'skills'
$agentsOutDir = Join-Path $PluginRoot 'agents'

New-Item -ItemType Directory -Path $PluginRoot -Force | Out-Null
New-Item -ItemType Directory -Path $rulesOutDir -Force | Out-Null
New-Item -ItemType Directory -Path $skillsOutDir -Force | Out-Null
New-Item -ItemType Directory -Path $agentsOutDir -Force | Out-Null

Write-Utf8NoBom (Join-Path $PluginRoot 'plugin.json') $pluginJson
Write-Utf8NoBom (Join-Path $rulesOutDir 'AGENTS.md') $rulesContent

foreach ($child in @(Get-ChildItem -LiteralPath $skillsOutDir -Force)) {
    $isLink = ($child.LinkType -in @('Junction', 'SymbolicLink')) -or (($child.Attributes.ToString()) -match 'ReparsePoint')
    if ($isLink) {
        Remove-ReparseItem $child.FullName
    } elseif ($Force) {
        Remove-Item -LiteralPath $child.FullName -Recurse -Force
    }
}
foreach ($se in $skillEntries) {
    $dest = Join-Path $skillsOutDir $se.Name
    New-Item -ItemType Junction -Path $dest -Target $se.Source | Out-Null
}

$expectedAgentFiles = @($renderedAgents | ForEach-Object { $_.FileName })
foreach ($existingAgent in @(Get-ChildItem -LiteralPath $agentsOutDir -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
    if ($expectedAgentFiles -notcontains $existingAgent.Name) {
        $existingText = Get-Content -LiteralPath $existingAgent.FullName -Raw
        if ($Force -or ($existingText -match '<!-- Generated from .*/\.cursor/agents/')) {
            Remove-Item -LiteralPath $existingAgent.FullName -Force
        }
    }
}
foreach ($ag in $renderedAgents) {
    Write-Utf8NoBom (Join-Path $agentsOutDir $ag.FileName) $ag.Content
}

$pluginDirName = Split-Path -Leaf $PluginRoot
Write-Output "installed Antigravity plugin at $PluginRoot"
Write-Output "B3_HOME=$B3Home"
Write-Output "skills=$($skillEntries.Count)"
Write-Output "agents=$($renderedAgents.Count)"
Write-Output "rules_bytes=$rulesBytes"
Write-Output "manage=customization://$pluginDirName"
Write-Output "note: this proves plugin files were generated, not Antigravity runtime discovery"
