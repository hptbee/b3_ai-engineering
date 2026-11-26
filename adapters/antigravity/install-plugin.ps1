# Global Antigravity plugin lifecycle manager for B3 AI Engineering (Windows PowerShell / pwsh).
# Installs, updates, verifies, or uninstalls the canonical B3 plugin bundle under ~/.gemini/config/plugins/b3-ai-engineering and B3 skill entries in ~/.gemini/config/skills.json.
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

function Normalize-SkillJsonPath([string]$PathValue) {
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return '' }
    $p = To-Forward $PathValue.Trim()
    if ($p -match '^[A-Za-z]:/$') { return $p }
    if ($p -eq '/') { return '/' }
    return $p.TrimEnd('/')
}

function Test-SkillPathEqual([string]$A, [string]$B) {
    $cmp = if ($env:OS -eq 'Windows_NT') { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    return $A.Equals($B, $cmp)
}

function Test-IsB3ManagedSkillPath([string]$CandidatePath, [string[]]$B3Prefixes) {
    $norm = Normalize-SkillJsonPath $CandidatePath
    if (-not $norm) { return $false }
    $cmp = if ($env:OS -eq 'Windows_NT') { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    foreach ($rawPrefix in $B3Prefixes) {
        $prefix = Normalize-SkillJsonPath $rawPrefix
        if (-not $prefix) { continue }
        $cmdPath = if ($prefix -eq '/') { '/adapters/command-skills' } else { "$prefix/adapters/command-skills" }
        $skillsExact = if ($prefix -eq '/') { '/skills' } else { "$prefix/skills" }
        $skillsPrefix = if ($prefix -eq '/') { '/skills/' } else { "$prefix/skills/" }
        if ($norm.Equals($cmdPath, $cmp) -or $norm.Equals($skillsExact, $cmp) -or $norm.StartsWith($skillsPrefix, $cmp)) {
            return $true
        }
    }
    return $false
}

function Get-DesiredSkillsJsonEntries([hashtable]$CoreMap, [hashtable]$CmdMap) {
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    if ($env:OS -eq 'Windows_NT') {
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    }
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($bucket in @($CoreMap, $CmdMap)) {
        $parents = New-Object System.Collections.Generic.List[string]
        foreach ($skillDir in $bucket.Values) {
            $parentDir = Normalize-SkillJsonPath (Split-Path -Parent $skillDir)
            if ($parentDir) { $parents.Add($parentDir) }
        }
        foreach ($p in (Sort-OrdinalStrings @($parents))) {
            if ($seen.Add($p)) { $result.Add($p) }
        }
    }
    return @($result)
}

function Read-SkillsJsonState([string]$JsonPath) {
    $state = [PSCustomObject]@{
        Exists    = $false
        Valid     = $true
        Error     = ''
        Obj       = $null
        Entries   = @()
        OtherKeys = @()
    }
    if (-not (Test-Path -LiteralPath $JsonPath -PathType Leaf)) {
        return $state
    }
    $state.Exists = $true
    try {
        $raw = [IO.File]::ReadAllText($JsonPath, $script:B3Utf8NoBom)
        $parsed = $raw | ConvertFrom-Json
    } catch {
        $state.Valid = $false
        $state.Error = "invalid JSON in global skills.json: $($_.Exception.Message)"
        return $state
    }
    if ($null -eq $parsed -or ($parsed -is [System.Array]) -or ($parsed -is [string]) -or ($parsed -is [ValueType])) {
        $state.Valid = $false
        $state.Error = 'global skills.json root must be a JSON object'
        return $state
    }
    $propNames = @($parsed.PSObject.Properties | ForEach-Object { $_.Name })
    $state.OtherKeys = @($propNames | Where-Object { $_ -cne 'entries' })
    $entriesProp = $parsed.PSObject.Properties['entries']
    if ($null -ne $entriesProp) {
        if ($null -eq $entriesProp.Value -or (-not ($entriesProp.Value -is [System.Collections.IList]))) {
            $state.Valid = $false
            $state.Error = 'global skills.json "entries" must be a JSON array'
            return $state
        }
        $state.Entries = @($entriesProp.Value)
    }
    $state.Obj = $parsed
    return $state
}

function ConvertTo-SkillsJsonContent($ExistingObj, [object[]]$EntriesArray) {
    $out = [ordered]@{}
    if ($null -ne $ExistingObj) {
        foreach ($prop in $ExistingObj.PSObject.Properties) {
            if ($prop.Name -ceq 'entries') { continue }
            $out[$prop.Name] = $prop.Value
        }
    }
    $out['entries'] = [object[]]$EntriesArray
    return (((ConvertTo-Json -InputObject $out -Depth 16).Replace("`r`n", "`n")) + "`n")
}

function Get-UninstallB3Prefixes([string]$PluginRootPath, $ManifestObj) {
    $prefixes = New-Object System.Collections.Generic.List[string]
    if ($ManifestObj -and $ManifestObj.B3Home) {
        $prefixes.Add((Normalize-SkillJsonPath $ManifestObj.B3Home))
    }
    $rPath = Join-Path $PluginRootPath 'rules\AGENTS.md'
    if ((Test-Path -LiteralPath $rPath -PathType Leaf) -and -not (Test-IsReparseLink $rPath)) {
        $rText = [IO.File]::ReadAllText($rPath, [System.Text.Encoding]::UTF8)
        if ($rText -match 'Generated from B3_HOME:\s*`([^`]+)`') {
            $prefixes.Add((Normalize-SkillJsonPath $Matches[1]))
        }
    }
    $skDir = Join-Path $PluginRootPath 'skills'
    if ((Test-Path -LiteralPath $skDir -PathType Container) -and -not (Test-IsReparseLink $skDir)) {
        foreach ($sk in @(Get-ChildItem -LiteralPath $skDir -Force -ErrorAction SilentlyContinue)) {
            if (-not (Test-IsReparseLink $sk.FullName) -or -not $sk.Target) { continue }
            foreach ($t in @($sk.Target)) {
                $tNorm = Normalize-SkillJsonPath ([string]$t)
                if ($tNorm -match '^(.+?)/(?:skills/[^/]+|adapters/command-skills)/[^/]+$') {
                    $prefixes.Add((Normalize-SkillJsonPath $Matches[1]))
                }
            }
        }
    }
    return @(Sort-OrdinalStrings @($prefixes | Where-Object { $_ } | Select-Object -Unique))
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
$UserHome = Resolve-UserHome $UserHome
if (-not $PluginRoot) {
    $PluginRoot = Join-Path $UserHome '.gemini\config\plugins\b3-ai-engineering'
}
$PluginRoot = Normalize-Path $PluginRoot
$pluginRootForward = To-Forward $PluginRoot
$manifestFile = Join-Path $PluginRoot '.b3-plugin-manifest'
$geminiDir = Join-Path $UserHome '.gemini'
$geminiConfigDir = Join-Path $geminiDir 'config'
$skillsJsonPath = Join-Path $geminiConfigDir 'skills.json'

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

    $uninstallB3Prefixes = Get-UninstallB3Prefixes $PluginRoot $manifest
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
            $expTarget = if ($manifest.Sections.link.ContainsKey($lk)) { $manifest.Sections.link[$lk] } else { '' }
            Uninstall-ManagedLink -RootDir $PluginRoot -RootLabel 'PluginRoot' -Path (Join-Path $PluginRoot ($lk -replace '/', '\')) `
                -ExpectedTarget $expTarget -VerifyExpected ([bool]$manifest.Exists) -Force $Force -DryRun $DryRun `
                -UnmanagedLabel 'unmanaged non-link entry' -Removed ([ref]$removed) -Skipped ([ref]$skipped)
        }
    }
    $warnedContainers = @{}
    foreach ($fk in $trackedFiles) {
        $expSha = if ($manifest.Sections.file.ContainsKey($fk)) { $manifest.Sections.file[$fk] } else { '' }
        Uninstall-ManagedFile -RootDir $PluginRoot -RootLabel 'PluginRoot' -Path (Join-Path $PluginRoot ($fk -replace '/', '\')) `
            -ExpectedSha $expSha -VerifySha ([bool]$manifest.Exists) -MarkerRegex '' `
            -Label 'file path' -ShaMismatchLabel 'modified managed file' -WarnedContainers $warnedContainers `
            -Force $Force -DryRun $DryRun -Removed ([ref]$removed) -Skipped ([ref]$skipped)
    }
    if (-not $DryRun) {
        foreach ($subDir in @('skills', 'rules', 'agents')) { Remove-EmptyRegularDir (Join-Path $PluginRoot $subDir) }
    }
    if ((Test-Path -LiteralPath $skillsJsonPath) -or (Test-IsReparseLink $skillsJsonPath)) {
        if ((Test-IsReparseLink $geminiDir) -or (Test-IsReparseLink $geminiConfigDir) -or (Test-IsReparseLink $skillsJsonPath)) {
            Write-Warning "skipping symlinked global skills.json path: $skillsJsonPath"
            $skipped++
        } elseif (-not (Test-Path -LiteralPath $skillsJsonPath -PathType Leaf)) {
            Write-Warning "skipping non-file global skills.json path: $skillsJsonPath"
            $skipped++
        } else {
            $sjState = Read-SkillsJsonState $skillsJsonPath
            if (-not $sjState.Valid) {
                Write-Warning "skipping invalid global skills.json: $skillsJsonPath ($($sjState.Error))"
                $skipped++
            } elseif ($uninstallB3Prefixes.Count -gt 0) {
                $keptEntries = New-Object System.Collections.Generic.List[object]
                $removedEntries = 0
                foreach ($item in $sjState.Entries) {
                    $itemPath = if ($null -ne $item -and $item.PSObject -and $item.PSObject.Properties['path']) { [string]$item.path } else { '' }
                    if ($itemPath -and (Test-IsB3ManagedSkillPath $itemPath $uninstallB3Prefixes)) {
                        $removedEntries++
                    } else {
                        $keptEntries.Add($item)
                    }
                }
                if ($removedEntries -gt 0) {
                    if ($keptEntries.Count -eq 0 -and $sjState.OtherKeys.Count -eq 0) {
                        if ($DryRun) { Write-Output "dry-run: remove $skillsJsonPath" } else { Remove-Item -LiteralPath $skillsJsonPath -Force }
                    } else {
                        $updatedSj = ConvertTo-SkillsJsonContent $sjState.Obj ([object[]]$keptEntries.ToArray())
                        if ($DryRun) { Write-Output "dry-run: update $skillsJsonPath (remove $removedEntries B3 entries)" } else { Write-Utf8NoBom $skillsJsonPath $updatedSj }
                    }
                    $removed++
                }
            }
        }
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
$B3Home = Resolve-B3Home $B3Home (Split-Path -Parent (Split-Path -Parent $scriptRoot))
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
$desiredSkillsJsonEntries = Get-DesiredSkillsJsonEntries $coreSkillMap $cmdSkillMap

$ruleFiles = Sort-FilesOrdinalByFullName @(Get-ChildItem -LiteralPath $rulesDir -Filter '*.md' -File -ErrorAction SilentlyContinue)
if ($ruleFiles.Count -lt 1) { Fail "B3_HOME has no rules under $rulesDir" }

$rulesHeader = @"
# B3 AI Engineering Rules

Generated from B3_HOME: ``$b3HomeForward`` (do not edit here).
Resolve B3_HOME from ``B3_HOME`` env, product ``.b3/home``, or ``$b3HomeForward``.
Precedence: ``$b3HomeForward/docs/precedence.md``. Ship: ``$b3HomeForward/workflows/ship.md``. Review loop: ``$b3HomeForward/review-loop/strategy.md``.
Project-level AGENTS.md, GEMINI.md, .agents/rules/, and .agents/skills/ override this global baseline within their project scope; per-project install-product is optional.
B3 commands (``/b3-plan``, ``/b3-implement``, ``/b3-debug``, ``/b3-review``, ``/b3-verify``, ``/b3-review-loop``, ``/b3-ship``, ``/b3-research-ship``, ``/b3-pr-resolve``, ``/b3-pr-reply``, ``/b3-pr-comment``) and workflows remain available across local projects via bundled skills using the fallback B3_HOME above.
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

$agentNames = Get-CanonicalMarkdownNames $agentsDir
if ($agentNames.Count -lt 1) { Fail "B3_HOME has no agent definitions under $agentsDir" }
$renderedAgents = New-Object System.Collections.Generic.List[object]
foreach ($an in $agentNames) { $renderedAgents.Add((Parse-CanonicalAgent (Join-Path $agentsDir $an) $b3HomeForward)) }

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
    $pluginOk = $true; $rulesOk = $true; $skillsOk = $true; $commandsOk = $true; $agentsOk = $true; $skillsJsonOk = $true

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
        foreach ($cmdMd in (Get-CanonicalMarkdownNames (Join-Path $B3Home 'commands'))) {
            $coreCmd = [IO.Path]::GetFileNameWithoutExtension($cmdMd)
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

    if ((Test-IsReparseLink $geminiDir) -or (Test-IsReparseLink $geminiConfigDir) -or (Test-IsReparseLink $skillsJsonPath)) {
        $skillsJsonOk = $false; $errors.Add("global skills.json path uses symlink or junction: $skillsJsonPath")
    } elseif (-not (Test-Path -LiteralPath $skillsJsonPath -PathType Leaf)) {
        $skillsJsonOk = $false; $errors.Add("missing global skills.json at $skillsJsonPath")
    } else {
        $sjState = Read-SkillsJsonState $skillsJsonPath
        if (-not $sjState.Valid) {
            $skillsJsonOk = $false; $errors.Add("invalid global skills.json at $skillsJsonPath : $($sjState.Error)")
        } elseif ($null -eq $sjState.Obj.PSObject.Properties['entries']) {
            $skillsJsonOk = $false; $errors.Add("global skills.json missing entries array at $skillsJsonPath")
        } else {
            $normPaths = New-Object System.Collections.Generic.List[string]
            foreach ($item in $sjState.Entries) {
                $itemPath = if ($null -ne $item -and $item.PSObject -and $item.PSObject.Properties['path']) { Normalize-SkillJsonPath ([string]$item.path) } else { '' }
                if ($itemPath) { $normPaths.Add($itemPath) }
            }
            foreach ($req in $desiredSkillsJsonEntries) {
                $found = $false
                foreach ($np in $normPaths) {
                    if (Test-SkillPathEqual $np $req) { $found = $true; break }
                }
                if (-not $found) {
                    $skillsJsonOk = $false; $errors.Add("global skills.json missing B3 entry: $req")
                }
            }
            foreach ($item in $sjState.Entries) {
                $rawItemPath = if ($null -ne $item -and $item.PSObject -and $item.PSObject.Properties['path']) { [string]$item.path } else { '' }
                $np = Normalize-SkillJsonPath $rawItemPath
                if ($np -and (Test-IsB3ManagedSkillPath $np @($b3HomeForward))) {
                    $inDesired = $false
                    foreach ($req in $desiredSkillsJsonEntries) {
                        if (Test-SkillPathEqual $np $req) { $inDesired = $true; break }
                    }
                    if (-not $inDesired) {
                        $skillsJsonOk = $false; $errors.Add("stale B3 entry in global skills.json: $rawItemPath")
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
    Write-Output ("check.skills_json={0}" -f $(if ($skillsJsonOk) { 'OK' } else { 'FAIL' }))

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

Assert-RegularDirOrMissing $geminiDir '.gemini'
Assert-RegularDirOrMissing $geminiConfigDir '.gemini/config'
Assert-RegularFileOrMissing $skillsJsonPath 'global skills.json'
$existingSkillsJson = Read-SkillsJsonState $skillsJsonPath
if ($existingSkillsJson.Exists -and -not $existingSkillsJson.Valid -and -not $Force) {
    Fail "UPDATE_CONFLICT: invalid global skills.json at $skillsJsonPath ($($existingSkillsJson.Error)) (preserved; use -Force only after backing it up)"
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

if ($DryRun) {
    Write-Output "dry-run: action=$Action plugin_root=$PluginRoot"
    Write-Output "dry-run: B3_HOME=$B3Home"
    Write-Output "dry-run: write $PluginRoot\plugin.json"
    Write-Output "dry-run: write $PluginRoot\rules\AGENTS.md ($rulesBytes bytes)"
    Write-Output "dry-run: link $($skillMap.Count) skills ($($coreSkillMap.Count) skills + $($cmdSkillMap.Count) command-skills) into $PluginRoot\skills"
    Write-Output "dry-run: write $($renderedAgents.Count) agents into $PluginRoot\agents"
    Write-Output "dry-run: update $skillsJsonPath ($($desiredSkillsJsonEntries.Count) skill category entries)"
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

Write-B3Manifest -ManifestPath $manifestFile -Schema 'b3-antigravity-plugin-v1' -B3HomeForward $b3HomeForward -PluginRootForward $pluginRootForward -EntryLines $manifestLines.ToArray()

$replacePrefixes = New-Object System.Collections.Generic.List[string]
$replacePrefixes.Add($b3HomeForward)
if ($oldManifest.Exists -and $oldManifest.B3Home) {
    $replacePrefixes.Add((Normalize-SkillJsonPath $oldManifest.B3Home))
}
$mergedEntries = New-Object System.Collections.Generic.List[object]
$baseSjObj = if ($existingSkillsJson.Exists -and $existingSkillsJson.Valid) { $existingSkillsJson.Obj } else { $null }
if ($null -ne $baseSjObj) {
    foreach ($item in $existingSkillsJson.Entries) {
        $itemPath = if ($null -ne $item -and $item.PSObject -and $item.PSObject.Properties['path']) { Normalize-SkillJsonPath ([string]$item.path) } else { '' }
        if ($itemPath) {
            if (Test-IsB3ManagedSkillPath $itemPath @($replacePrefixes)) { continue }
            $matchesDesired = $false
            foreach ($req in $desiredSkillsJsonEntries) {
                if (Test-SkillPathEqual $itemPath $req) { $matchesDesired = $true; break }
            }
            if ($matchesDesired) { continue }
        }
        $mergedEntries.Add($item)
    }
}
foreach ($req in $desiredSkillsJsonEntries) {
    $mergedEntries.Add([ordered]@{ path = $req })
}
$skillsJsonContent = ConvertTo-SkillsJsonContent $baseSjObj ([object[]]$mergedEntries.ToArray())
Write-Utf8NoBom $skillsJsonPath $skillsJsonContent

Check-AntigravityCoexistence $UserHome $PluginRoot $sortedSkillNames
$pluginDirName = Split-Path -Leaf $PluginRoot
Write-Output ("{0}_OK: skills={1} commands={2} agents={3} rules_bytes={4} plugin_root={5} b3_home={6}" -f $Action.ToUpperInvariant(), $coreSkillMap.Count, $cmdSkillMap.Count, $renderedAgents.Count, $rulesBytes, $PluginRoot, $b3HomeForward)
Write-Output "installed Antigravity plugin at $PluginRoot"
Write-Output "B3_HOME=$B3Home"
Write-Output "skills=$($skillMap.Count)"
Write-Output "skills_json=$skillsJsonPath ($($desiredSkillsJsonEntries.Count) entries)"
Write-Output "agents=$($renderedAgents.Count)"
Write-Output "rules_bytes=$rulesBytes"
Write-Output "manage=customization://$pluginDirName"
Write-Output "note: this proves plugin files were generated, not Antigravity runtime discovery"
