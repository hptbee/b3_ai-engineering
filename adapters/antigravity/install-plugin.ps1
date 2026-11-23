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

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

function Normalize-Path([string]$PathValue) {
    $p = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PathValue).TrimEnd('\', '/')
    if ($p -match '^([a-z]):(.*)$') {
        $p = $Matches[1].ToUpperInvariant() + ':' + $Matches[2]
    }
    return $p
}

function To-Forward([string]$PathValue) {
    $p = $PathValue -replace '\\', '/'
    if ($p -match '^([a-z]):(.*)$') {
        $p = $Matches[1].ToUpperInvariant() + ':' + $Matches[2]
    }
    return $p
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $lf = $Content.Replace("`r`n", "`n").Replace("`r", "`n")
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($Path, $lf, $utf8NoBom)
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
    $bytes = [IO.File]::ReadAllBytes($FilePath)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
        return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
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
        Fail "refusing to remove non-link entry without -Force: $LinkPath"
    }
    if ($item.PSIsContainer) {
        if ($env:OS -eq 'Windows_NT') {
            & cmd.exe /c rmdir "`"$LinkPath`"" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0 -or $null -ne (Get-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue)) {
                Fail "could not remove link directory $LinkPath"
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

function Get-SkillNameFromFile([string]$SkillFile) {
    $raw = ([IO.File]::ReadAllText($SkillFile, [System.Text.Encoding]::UTF8)).Replace("`r`n", "`n").Replace("`r", "`n")
    $lines = $raw -split "`n"
    if ($lines.Count -ge 3 -and $lines[0].Trim() -eq '---') {
        for ($i = 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Trim() -eq '---') { break }
            if ($lines[$i] -match '^\s*name:\s*([a-z0-9-]+)\s*$') {
                return $Matches[1]
            }
        }
    }
    return (Split-Path -Leaf (Split-Path -Parent $SkillFile))
}

function Parse-CanonicalAgent([string]$FilePath, [string]$B3HomeNormalized) {
    $raw = ([IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8)).Replace("`r`n", "`n").Replace("`r", "`n")
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
    $outLines.Add("<!-- Generated from $B3HomeNormalized/agents/$fileName - do not edit here -->")
    $outLines.Add('')
    if ($body) { $outLines.Add($body) }

    return [PSCustomObject]@{
        FileName = $fileName
        Name     = $name
        Content  = (($outLines -join "`n").TrimEnd() + "`n")
    }
}

function Read-PluginManifest([string]$ManifestPath) {
    $m = [PSCustomObject]@{
        Exists     = $false
        Schema     = ''
        B3Home     = ''
        PluginRoot = ''
        Files      = @{}
        Links      = @{}
    }
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        return $m
    }
    $m.Exists = $true
    $lines = ([IO.File]::ReadAllText($ManifestPath, [System.Text.Encoding]::UTF8)).Replace("`r`n", "`n").Split("`n")
    foreach ($line in $lines) {
        $t = $line.Trim()
        if (-not $t) { continue }
        if ($t -match '^schema=(.+)$') { $m.Schema = $Matches[1].Trim(); continue }
        if ($t -match '^b3_home=(.+)$') { $m.B3Home = $Matches[1].Trim(); continue }
        if ($t -match '^plugin_root=(.+)$') { $m.PluginRoot = $Matches[1].Trim(); continue }
        $parts = $t -split '\|', 3
        if ($parts.Count -lt 3) { continue }
        if ($parts[0] -eq 'file') { $m.Files[$parts[1]] = $parts[2] }
        elseif ($parts[0] -eq 'link') { $m.Links[$parts[1]] = $parts[2] }
    }
    return $m
}

function Sort-OrdinalStrings([string[]]$Items) {
    $arr = @($Items)
    if ($arr.Count -gt 1) {
        [Array]::Sort($arr, [System.StringComparer]::Ordinal)
    }
    return $arr
}

function Sort-FilesOrdinalByFullName([System.IO.FileInfo[]]$Files) {
    $arr = @($Files)
    if ($arr.Count -gt 1) {
        [Array]::Sort($arr, [System.Comparison[System.IO.FileInfo]]{ param($a, $b) [System.StringComparer]::Ordinal.Compare($a.FullName, $b.FullName) })
    }
    return $arr
}

function Test-B3PluginJson([string]$JsonPath) {
    if (-not (Test-Path -LiteralPath $JsonPath -PathType Leaf)) { return $false }
    try {
        $parsed = Get-Content -LiteralPath $JsonPath -Raw | ConvertFrom-Json
        $allowedKeys = @('name', 'displayName', 'version', 'description', 'suggestedPrompts')
        $propNames = @($parsed.PSObject.Properties | ForEach-Object { $_.Name })
        $extra = @($propNames | Where-Object { $allowedKeys -notcontains $_ })
        return ($parsed.name -eq 'b3-ai-engineering') -and ($extra.Count -eq 0)
    } catch {
        return $false
    }
}

function Test-B3PluginName([string]$JsonPath) {
    if (-not (Test-Path -LiteralPath $JsonPath -PathType Leaf)) { return $false }
    try {
        $parsed = Get-Content -LiteralPath $JsonPath -Raw | ConvertFrom-Json
        return ($parsed.name -eq 'b3-ai-engineering')
    } catch {
        return $false
    }
}

function Check-AntigravityCoexistence([string]$UserHomeDir, [string]$PluginRootPath, [string[]]$AllSkillNames) {
    $pluginNorm = (Normalize-Path $PluginRootPath)
    $looseSkills = Join-Path $UserHomeDir '.gemini\config\skills'
    if (Test-Path -LiteralPath $looseSkills -PathType Container) {
        $overlaps = @($AllSkillNames | Where-Object {
            $p = Join-Path $looseSkills $_
            (Test-Path -LiteralPath $p) -or (Test-IsReparseLink $p)
        })
        if ($overlaps.Count -gt 0) {
            Write-Output "COEXISTENCE_WARNING: ~/.gemini/config/skills contains $($overlaps.Count) overlapping B3 skill(s) ($($overlaps[0])...); remove loose copies to prevent duplicate discovery."
        }
    }

    $pluginsDir = Join-Path $UserHomeDir '.gemini\config\plugins'
    if (Test-Path -LiteralPath $pluginsDir -PathType Container) {
        foreach ($cand in @(Get-ChildItem -LiteralPath $pluginsDir -Directory -Force -ErrorAction SilentlyContinue)) {
            $candNorm = Normalize-Path $cand.FullName
            if ($candNorm.Equals($pluginNorm, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            $candJson = Join-Path $cand.FullName 'plugin.json'
            if (Test-B3PluginName $candJson) {
                Write-Output "COEXISTENCE_WARNING: duplicate b3-ai-engineering plugin found at $($cand.FullName); only one plugin directory with name 'b3-ai-engineering' should exist."
            }
        }
    }

    $globalAgentsSkills = Join-Path $UserHomeDir '.agents\skills'
    if (Test-Path -LiteralPath $globalAgentsSkills -PathType Container) {
        $agOverlaps = @($AllSkillNames | Where-Object {
            $p = Join-Path $globalAgentsSkills $_
            (Test-Path -LiteralPath $p) -or (Test-IsReparseLink $p)
        })
        if ($agOverlaps.Count -gt 0) {
            Write-Output "COEXISTENCE_WARNING: ~/.agents/skills contains $($agOverlaps.Count) overlapping B3 skill(s); global Antigravity discovery may duplicate bundled plugin skills."
        }
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
    if (Test-IsReparseLink $PluginRoot) {
        Fail "refusing to uninstall link-based PluginRoot: $PluginRoot"
    }
    $manifest = Read-PluginManifest $manifestFile
    $hasPluginJson = Test-B3PluginJson (Join-Path $PluginRoot 'plugin.json')
    if (-not $manifest.Exists -and -not $hasPluginJson) {
        if ((Test-Path -LiteralPath $PluginRoot) -or (Test-IsReparseLink $PluginRoot)) {
            Fail "refusing to uninstall unrecognized directory (missing B3 manifest or plugin.json): $PluginRoot"
        }
        Write-Output "nothing installed (no B3 plugin at $PluginRoot)"
        exit 0
    }

    $removed = 0
    $trackedFiles = New-Object System.Collections.Generic.List[string]
    $trackedLinks = New-Object System.Collections.Generic.List[string]
    if ($manifest.Exists) {
        foreach ($fk in @($manifest.Files.Keys | Sort-Object)) { $trackedFiles.Add($fk) }
        foreach ($lk in @($manifest.Links.Keys | Sort-Object)) { $trackedLinks.Add($lk) }
    } else {
        # Legacy pre-manifest B3 install fallback
        if (Test-Path -LiteralPath (Join-Path $PluginRoot 'plugin.json') -PathType Leaf) { $trackedFiles.Add('plugin.json') }
        $rPath = Join-Path $PluginRoot 'rules\AGENTS.md'
        if ((Test-Path -LiteralPath $rPath -PathType Leaf) -and ([IO.File]::ReadAllText($rPath, [System.Text.Encoding]::UTF8) -match 'Generated from B3_HOME:')) {
            $trackedFiles.Add('rules/AGENTS.md')
        }
        $agDir = Join-Path $PluginRoot 'agents'
        if (Test-Path -LiteralPath $agDir -PathType Container) {
            foreach ($af in @(Get-ChildItem -LiteralPath $agDir -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
                $txt = [IO.File]::ReadAllText($af.FullName, [System.Text.Encoding]::UTF8)
                if ($txt -match '<!-- Generated from .*/(\.cursor/)?agents/') {
                    $trackedFiles.Add("agents/$($af.Name)")
                }
            }
        }
        $skDir = Join-Path $PluginRoot 'skills'
        if (Test-Path -LiteralPath $skDir -PathType Container) {
            foreach ($sk in @(Get-ChildItem -LiteralPath $skDir -Force -ErrorAction SilentlyContinue)) {
                if (Test-IsReparseLink $sk.FullName) { $trackedLinks.Add("skills/$($sk.Name)") }
            }
        }
    }

    foreach ($lk in $trackedLinks) {
        $p = Join-Path $PluginRoot ($lk -replace '/', '\')
        if (Test-IsReparseLink $p) {
            if ($DryRun) { Write-Output "dry-run: remove skill link $p" } else { Remove-LinkOnly $p }
            $removed++
        } elseif (Test-Path -LiteralPath $p) {
            Write-Warning "skipping unmanaged non-link entry: $p"
        }
    }
    foreach ($fk in $trackedFiles) {
        $p = Join-Path $PluginRoot ($fk -replace '/', '\')
        if (Test-IsReparseLink $p) {
            Write-Warning "skipping symlinked file path: $p"
            continue
        }
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            if ($DryRun) { Write-Output "dry-run: remove file $p" } else { Remove-Item -LiteralPath $p -Force }
            $removed++
        }
    }
    if ($manifest.Exists -and (Test-Path -LiteralPath $manifestFile -PathType Leaf)) {
        if ($DryRun) { Write-Output "dry-run: remove manifest $manifestFile" } else { Remove-Item -LiteralPath $manifestFile -Force }
        $removed++
    }
    if (-not $DryRun) {
        foreach ($subDir in @('skills', 'rules', 'agents')) {
            $sd = Join-Path $PluginRoot $subDir
            if ((Test-Path -LiteralPath $sd -PathType Container) -and -not (Test-IsReparseLink $sd)) {
                if (@(Get-ChildItem -LiteralPath $sd -Force).Count -eq 0) {
                    Remove-Item -LiteralPath $sd -Force
                }
            }
        }
        if ((Test-Path -LiteralPath $PluginRoot -PathType Container) -and -not (Test-IsReparseLink $PluginRoot)) {
            if (@(Get-ChildItem -LiteralPath $PluginRoot -Force).Count -eq 0) {
                Remove-Item -LiteralPath $PluginRoot -Force
            }
        }
    }
    Write-Output "UNINSTALL_OK: removed=$removed plugin_root=$PluginRoot"
    exit 0
}

# --- Resolve and validate B3Home (install / update / verify) ---
if (-not $B3Home) {
    $B3Home = Split-Path -Parent (Split-Path -Parent $scriptRoot)
}
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

$canonicalSkillFiles = Sort-FilesOrdinalByFullName @(Get-ChildItem -LiteralPath $skillsSrc -Recurse -Filter 'SKILL.md' -File)
if ($canonicalSkillFiles.Count -lt 1) { Fail "B3_HOME has no SKILL.md under skills: $skillsSrc" }

$cmdSkillFiles = @()
if (Test-Path -LiteralPath $cmdSkillsSrc -PathType Container) {
    $cmdSkillFiles = Sort-FilesOrdinalByFullName @(Get-ChildItem -LiteralPath $cmdSkillsSrc -Recurse -Filter 'SKILL.md' -File)
}
if ($cmdSkillFiles.Count -lt 1) { Fail "B3_HOME has no command skills under: $cmdSkillsSrc" }

$coreSkillMap = @{}
$cmdSkillMap = @{}
$skillMap = @{}
$skillEntries = New-Object System.Collections.Generic.List[object]

foreach ($sf in $canonicalSkillFiles) {
    $sname = Get-SkillNameFromFile $sf.FullName
    if ($skillMap.ContainsKey($sname)) {
        Fail "duplicate skill name '$sname': $($skillMap[$sname]) and $($sf.FullName)"
    }
    $srcDir = Normalize-Path (Split-Path -Parent $sf.FullName)
    $skillMap[$sname] = $srcDir
    $coreSkillMap[$sname] = $srcDir
    $skillEntries.Add([PSCustomObject]@{ Name = $sname; Source = $srcDir; Kind = 'skill' })
}
foreach ($sf in $cmdSkillFiles) {
    $sname = Get-SkillNameFromFile $sf.FullName
    if ($skillMap.ContainsKey($sname)) {
        Fail "duplicate skill name '$sname': $($skillMap[$sname]) and $($sf.FullName)"
    }
    $srcDir = Normalize-Path (Split-Path -Parent $sf.FullName)
    $skillMap[$sname] = $srcDir
    $cmdSkillMap[$sname] = $srcDir
    $skillEntries.Add([PSCustomObject]@{ Name = $sname; Source = $srcDir; Kind = 'command' })
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
B3 commands (``/b3-plan``, ``/b3-implement``, ``/b3-debug``, ``/b3-review``, ``/b3-verify``, ``/b3-review-loop``, ``/b3-ship``) and workflows remain available across local projects via bundled skills using the fallback B3_HOME above.
"@
$rulesParts = New-Object System.Collections.Generic.List[string]
$rulesParts.Add($rulesHeader.Trim())
foreach ($rf in $ruleFiles) {
    $stripped = Strip-YamlFrontmatter ([IO.File]::ReadAllText($rf.FullName, [System.Text.Encoding]::UTF8))
    if ($stripped) { $rulesParts.Add($stripped) }
}
$rulesContent = (($rulesParts -join "`n`n---`n`n").TrimEnd() + "`n")
$rulesBytes = [System.Text.Encoding]::UTF8.GetByteCount($rulesContent)
if ($rulesBytes -ge 24000) {
    Fail "generated rules/AGENTS.md is $rulesBytes bytes (must stay under 24000 bytes)"
}

$agentFiles = Sort-FilesOrdinalByFullName @(Get-ChildItem -LiteralPath $agentsDir -Filter '*.md' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'README.md' })
if ($agentFiles.Count -lt 1) { Fail "B3_HOME has no agent definitions under $agentsDir" }
$renderedAgents = New-Object System.Collections.Generic.List[object]
foreach ($af in $agentFiles) {
    $renderedAgents.Add((Parse-CanonicalAgent $af.FullName $b3HomeForward))
}

$pluginJson = @'
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
'@ + "`n"
$pluginJson = $pluginJson.Replace("`r`n", "`n")

# --- Verify action (checks each capability surface independently) ---
if ($Action -eq 'verify') {
    $errors = New-Object System.Collections.Generic.List[string]
    $pluginOk = $true
    $rulesOk = $true
    $skillsOk = $true
    $commandsOk = $true
    $agentsOk = $true

    if (-not (Test-Path -LiteralPath $PluginRoot -PathType Container) -or (Test-IsReparseLink $PluginRoot)) {
        $pluginOk = $false; $rulesOk = $false; $skillsOk = $false; $commandsOk = $false; $agentsOk = $false
        $errors.Add("plugin directory missing or invalid: $PluginRoot")
    } else {
        $manifest = Read-PluginManifest $manifestFile
        if (-not $manifest.Exists -or $manifest.Schema -ne 'b3-antigravity-plugin-v1') {
            $pluginOk = $false
            $errors.Add("missing or invalid .b3-plugin-manifest at $manifestFile")
        }
        $pjPath = Join-Path $PluginRoot 'plugin.json'
        if (-not (Test-B3PluginJson $pjPath)) {
            $pluginOk = $false
            $errors.Add("missing or invalid plugin.json at $pjPath")
        } elseif ((Get-FileSha256 $pjPath) -ne (Get-TextSha256 $pluginJson)) {
            $pluginOk = $false
            $errors.Add("stale or modified plugin.json at $pjPath")
        }

        $rulesDirOut = Join-Path $PluginRoot 'rules'
        $rulesOut = Join-Path $rulesDirOut 'AGENTS.md'
        if (Test-IsReparseLink $rulesDirOut) {
            $rulesOk = $false
            $errors.Add("rules directory is a link (expected regular directory): $rulesDirOut")
        } elseif (-not (Test-Path -LiteralPath $rulesOut -PathType Leaf)) {
            $rulesOk = $false
            $errors.Add("missing rules/AGENTS.md at $rulesOut")
        } else {
            $rActualBytes = ([IO.File]::ReadAllBytes($rulesOut)).Length
            $rActualText = [IO.File]::ReadAllText($rulesOut, [System.Text.Encoding]::UTF8)
            if ($rActualBytes -ge 24000 -or ($rActualText.TrimStart() -match '^---')) {
                $rulesOk = $false
                $errors.Add("invalid rules/AGENTS.md format or size ($rActualBytes B)")
            } elseif ((Get-FileSha256 $rulesOut) -ne (Get-TextSha256 $rulesContent)) {
                $rulesOk = $false
                $errors.Add("stale or modified rules/AGENTS.md at $rulesOut")
            }
        }

        $skillsOut = Join-Path $PluginRoot 'skills'
        if (Test-IsReparseLink $skillsOut) {
            $skillsOk = $false
            $commandsOk = $false
            $errors.Add("skills directory is a link (expected container of 1-level skill links): $skillsOut")
        } else {
            foreach ($sn in (Sort-OrdinalStrings @($coreSkillMap.Keys))) {
                $dest = Join-Path $skillsOut $sn
                if (-not (Test-LinkTarget $dest $coreSkillMap[$sn]) -or -not (Test-Path -LiteralPath (Join-Path $dest 'SKILL.md') -PathType Leaf)) {
                    $skillsOk = $false
                    $errors.Add("missing or broken skill link: $dest -> $($coreSkillMap[$sn])")
                }
            }
            if (Test-Path -LiteralPath $skillsOut -PathType Container) {
                foreach ($child in @(Get-ChildItem -LiteralPath $skillsOut -Force)) {
                    if ((Test-IsReparseLink $child.FullName) -and -not $skillMap.ContainsKey($child.Name)) {
                        $skillsOk = $false
                        $errors.Add("stale managed skill link present: $($child.FullName)")
                    }
                }
            }

            foreach ($cn in (Sort-OrdinalStrings @($cmdSkillMap.Keys))) {
                $dest = Join-Path $skillsOut $cn
                if (-not (Test-LinkTarget $dest $cmdSkillMap[$cn]) -or -not (Test-Path -LiteralPath (Join-Path $dest 'SKILL.md') -PathType Leaf)) {
                    $commandsOk = $false
                    $errors.Add("missing or broken command-skill link: $dest -> $($cmdSkillMap[$cn])")
                }
            }
        }
        foreach ($coreCmd in @('b3-plan', 'b3-implement', 'b3-debug', 'b3-review', 'b3-verify', 'b3-review-loop', 'b3-ship')) {
            if (-not $cmdSkillMap.ContainsKey($coreCmd)) {
                $commandsOk = $false
                $errors.Add("missing expected command skill in B3_HOME: $coreCmd")
            }
        }

        $agentsOut = Join-Path $PluginRoot 'agents'
        $expectedAgentSet = @($renderedAgents | ForEach-Object { $_.FileName })
        if (Test-IsReparseLink $agentsOut) {
            $agentsOk = $false
            $errors.Add("agents directory is a link (expected regular directory): $agentsOut")
        } else {
            foreach ($ag in $renderedAgents) {
                $dest = Join-Path $agentsOut $ag.FileName
                if (-not (Test-Path -LiteralPath $dest -PathType Leaf)) {
                    $agentsOk = $false
                    $errors.Add("missing agent file: $dest")
                } elseif ((Get-FileSha256 $dest) -ne (Get-TextSha256 $ag.Content)) {
                    $agentsOk = $false
                    $errors.Add("stale or modified agent file: $dest")
                } else {
                    $txt = [IO.File]::ReadAllText($dest, [System.Text.Encoding]::UTF8)
                    if (($txt -notmatch '(?m)^subagent:\s*true\s*$') -or ($txt -notmatch '(?m)^mainAgent:\s*false\s*$') -or ($txt -notmatch '(?m)^tools:\s*\[')) {
                        $agentsOk = $false
                        $errors.Add("invalid subagent frontmatter in: $dest")
                    }
                }
            }
            if (Test-Path -LiteralPath $agentsOut -PathType Container) {
                foreach ($existingAg in @(Get-ChildItem -LiteralPath $agentsOut -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
                    if ($expectedAgentSet -notcontains $existingAg.Name) {
                        $agTxt = [IO.File]::ReadAllText($existingAg.FullName, [System.Text.Encoding]::UTF8)
                        $isTrackedAg = $manifest.Exists -and $manifest.Files.ContainsKey("agents/$($existingAg.Name)")
                        if ($isTrackedAg -or ($agTxt -match '<!-- Generated from .*/(\.cursor/)?agents/')) {
                            $agentsOk = $false
                            $errors.Add("stale generated agent file present: $($existingAg.FullName)")
                        }
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
        Write-Output "note: filesystem verification only — Antigravity runtime discovery is UNKNOWN / INCOMPLETE until verified in a live session"
        exit 1
    }
    Write-Output "VERIFY_OK: skills=$($coreSkillMap.Count) commands=$($cmdSkillMap.Count) agents=$($renderedAgents.Count) rules_bytes=$rulesBytes plugin_root=$PluginRoot b3_home=$b3HomeForward"
    Write-Output "note: filesystem verification only — Antigravity runtime discovery is UNKNOWN / INCOMPLETE until verified in a live session"
    exit 0
}

# --- Fail-closed preflight checks before any write (install / update) ---
if ((Test-Path -LiteralPath $PluginRoot) -or (Test-IsReparseLink $PluginRoot)) {
    if (Test-IsReparseLink $PluginRoot) {
        Fail "refusing to replace link at PluginRoot: $PluginRoot"
    }
    $rootItem = Get-Item -LiteralPath $PluginRoot -Force
    if (-not $rootItem.PSIsContainer) {
        Fail "refusing to replace existing file: $PluginRoot"
    }
    $existingManifest = Read-PluginManifest $manifestFile
    $isB3Plugin = $existingManifest.Exists -or (Test-B3PluginJson (Join-Path $PluginRoot 'plugin.json'))
    if (-not $isB3Plugin -and -not $Force) {
        Fail "refusing to overwrite existing non-B3 directory without -Force: $PluginRoot"
    }
    $existingSkillsDir = Join-Path $PluginRoot 'skills'
    if ((Test-Path -LiteralPath $existingSkillsDir -PathType Container) -and -not $Force) {
        foreach ($child in @(Get-ChildItem -LiteralPath $existingSkillsDir -Force)) {
            if (-not (Test-IsReparseLink $child.FullName)) {
                Fail "refusing to overwrite non-link entry in $existingSkillsDir without -Force: $($child.FullName)"
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
    Write-Output "dry-run: link $($skillEntries.Count) skills ($($coreSkillMap.Count) skills + $($cmdSkillMap.Count) command-skills) into $PluginRoot\skills"
    Write-Output "dry-run: write $($renderedAgents.Count) agents into $PluginRoot\agents"
    Check-AntigravityCoexistence $UserHome $PluginRoot $sortedSkillNames
    Write-Output "DRY_RUN_OK: action=$Action plugin_root=$PluginRoot"
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
$manifestLines.Add("file|plugin.json|$(Get-TextSha256 $pluginJson)")
Write-Utf8NoBom (Join-Path $rulesOutDir 'AGENTS.md') $rulesContent
$manifestLines.Add("file|rules/AGENTS.md|$(Get-TextSha256 $rulesContent)")

foreach ($child in @(Get-ChildItem -LiteralPath $skillsOutDir -Force)) {
    if (Test-IsReparseLink $child.FullName) {
        if (-not $skillMap.ContainsKey($child.Name) -or -not (Test-LinkTarget $child.FullName $skillMap[$child.Name])) {
            Remove-LinkOnly $child.FullName
        }
    } elseif ($Force) {
        Remove-Item -LiteralPath $child.FullName -Recurse -Force
    }
}
foreach ($sn in $sortedSkillNames) {
    $src = $skillMap[$sn]
    $dest = Join-Path $skillsOutDir $sn
    if (-not (Test-LinkTarget $dest $src)) {
        if (Test-IsReparseLink $dest) { Remove-LinkOnly $dest }
        Create-DirLink $dest $src
    }
    $manifestLines.Add("link|skills/$sn|$(To-Forward $src)")
}

$expectedAgentFiles = @($renderedAgents | ForEach-Object { $_.FileName })
$oldManifest = Read-PluginManifest $manifestFile
foreach ($existingAgent in @(Get-ChildItem -LiteralPath $agentsOutDir -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
    if ($expectedAgentFiles -notcontains $existingAgent.Name) {
        $existingText = [IO.File]::ReadAllText($existingAgent.FullName, [System.Text.Encoding]::UTF8)
        $isTracked = $oldManifest.Files.ContainsKey("agents/$($existingAgent.Name)")
        if ($Force -or $isTracked -or ($existingText -match '<!-- Generated from .*/(\.cursor/)?agents/')) {
            Remove-Item -LiteralPath $existingAgent.FullName -Force
        }
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
Write-Output "skills=$($skillEntries.Count)"
Write-Output "agents=$($renderedAgents.Count)"
Write-Output "rules_bytes=$rulesBytes"
Write-Output "manage=customization://$pluginDirName"
Write-Output "note: this proves plugin files were generated, not Antigravity runtime discovery"
