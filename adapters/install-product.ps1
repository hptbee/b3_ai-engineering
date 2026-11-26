param(
    [Parameter(Mandatory = $true)]
    [string]$ProductRoot,
    [string]$B3Home,
    [ValidateSet('cursor', 'codex', 'claude', 'antigravity', 'all')]
    [string]$HostName = 'cursor',
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

if ($env:B3_USE_LEGACY -ne '1') {
    $b3HomeDefault = Split-Path -Parent $PSScriptRoot
    $b3BinName = if ([IO.Path]::DirectorySeparatorChar -eq '\') { 'b3.exe' } else { 'b3' }
    $b3Candidate = if ($env:B3_BIN -and (Test-Path -LiteralPath $env:B3_BIN -PathType Leaf)) {
        $env:B3_BIN
    } else {
        $relBin = Join-Path $b3HomeDefault "target\release\$b3BinName"
        if (Test-Path -LiteralPath $relBin -PathType Leaf) { $relBin } else { $null }
    }
    if ($b3Candidate) {
        $effectiveHome = if ($B3Home) { $B3Home } else { $b3HomeDefault }
        $fwdArgs = New-Object System.Collections.Generic.List[string]
        [void]$fwdArgs.Add('install')
        [void]$fwdArgs.Add('product')
        [void]$fwdArgs.Add("--product-root=$ProductRoot")
        [void]$fwdArgs.Add("--b3-home=$effectiveHome")
        [void]$fwdArgs.Add("--host=$HostName")
        if ($DryRun) { [void]$fwdArgs.Add('--dry-run') }
        if ($Force) { [void]$fwdArgs.Add('--force') }

        $psiB = New-Object System.Diagnostics.ProcessStartInfo
        $psiB.FileName = $b3Candidate
        $psiB.UseShellExecute = $false
        $psiB.RedirectStandardOutput = $true
        $psiB.RedirectStandardError = $true
        $psiB.CreateNoWindow = $true
        $utf8B = New-Object System.Text.UTF8Encoding($false)
        $psiB.StandardOutputEncoding = $utf8B
        $psiB.StandardErrorEncoding = $utf8B
        if ($psiB.PSObject.Properties['ArgumentList']) {
            foreach ($fa in $fwdArgs) { [void]$psiB.ArgumentList.Add($fa) }
        } else {
            $psiB.Arguments = (($fwdArgs | ForEach-Object {
                if ($null -eq $_ -or $_.Length -eq 0) { '""' }
                elseif ($_ -match '[\s"]') { '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }
                else { $_ }
            }) -join ' ')
        }
        $pB = [System.Diagnostics.Process]::Start($psiB)
        if (-not $pB) { exit 1 }
        try {
            $eBTask = $pB.StandardError.ReadToEndAsync()
            $oBTask = $pB.StandardOutput.ReadToEndAsync()
            $pB.WaitForExit()
            $oBTxt = $oBTask.GetAwaiter().GetResult()
            $eBTxt = $eBTask.GetAwaiter().GetResult()
            $ecB = [int]$pB.ExitCode
            if ($oBTxt) {
                $linesB = $oBTxt -split "\r?\n"
                $endB = $linesB.Length
                if ($endB -gt 0 -and $linesB[$endB - 1] -eq '') { $endB-- }
                for ($ib = 0; $ib -lt $endB; $ib++) { Write-Output $linesB[$ib] }
            }
            if ($eBTxt) {
                [Console]::Error.Write($eBTxt)
                [Console]::Error.Flush()
            }
            exit $ecB
        } finally {
            $pB.Dispose()
        }
    }
}

. (Join-Path $PSScriptRoot 'lib\global-common.ps1')

$scriptRoot = $PSScriptRoot
$B3Home = Resolve-B3Home $B3Home (Split-Path -Parent $scriptRoot)
$ProductRoot = (Resolve-Path -LiteralPath $ProductRoot).Path
$workflow = Join-Path $B3Home 'workflows\ship.md'
$b3Commands = Join-Path $B3Home 'commands'
$template = Join-Path $b3Commands 'b3-ship.md'
$skills = Join-Path $B3Home 'skills'
$b3Agents = Join-Path $B3Home 'agents'
$commandSkillsSrc = Join-Path $B3Home 'adapters\command-skills'

if (-not (Test-Path -LiteralPath $workflow)) { Fail "B3_HOME missing workflow: $workflow" }
if (-not (Test-Path -LiteralPath $template)) { Fail "missing template: $template" }
if (@(Get-ChildItem -LiteralPath $skills -Recurse -Filter 'SKILL.md' -File -ErrorAction SilentlyContinue).Count -lt 1) {
    Fail "B3_HOME has no SKILL.md under skills: $skills"
}

$useCursor = ($HostName -in @('cursor', 'all'))
$useFlatAgentsSkills = ($HostName -in @('codex', 'antigravity', 'all'))
$useClaude = ($HostName -in @('claude', 'all'))

$productSkills = Join-Path $ProductRoot '.cursor\skills'
$cursorDir = Join-Path $ProductRoot '.cursor'
$cursorCommandsDir = Join-Path $ProductRoot '.cursor\commands'
$commandDest = Join-Path $cursorCommandsDir 'b3-ship.md'
$homeDest = Join-Path $ProductRoot '.b3\home'
$agentsDest = Join-Path $ProductRoot '.agents\skills'
$claudeSkillsDest = Join-Path $ProductRoot '.claude\skills'
$claudeAgentsDest = Join-Path $ProductRoot '.claude\agents'
$claudeMdDest = Join-Path $ProductRoot 'CLAUDE.md'
$cursorReadmeTemplate = Join-Path $scriptRoot 'product-cursor-readme.md'
$agentsMdTemplate = Join-Path $scriptRoot 'product-agents.md'
$claudeMdTemplate = Join-Path $scriptRoot 'product-claude.md'
$cursorReadmeDest = Join-Path $ProductRoot '.cursor\README.md'
$agentsMdDest = Join-Path $ProductRoot 'AGENTS.md'

if (Test-Path -LiteralPath $productSkills) {
    $productSkillCount = @(Get-ChildItem -LiteralPath $productSkills -Recurse -Filter 'SKILL.md' -File -ErrorAction SilentlyContinue).Count
    if ($productSkillCount -gt 0) {
        Fail "product already has $productSkillCount SKILL.md under .cursor/skills; refusing to install a duplicate skill tree"
    }
}

if ($HostName -eq 'cursor' -and -not $Force) {
    if ((Test-Path -LiteralPath $agentsDest) -or (Test-IsReparseLink $agentsDest)) {
        Fail "product has .agents/skills; Cursor would duplicate discovery. Remove it, use -Force, or install with -HostName codex only in a Codex-only checkout"
    }
    if ((Test-Path -LiteralPath $claudeSkillsDest) -or (Test-IsReparseLink $claudeSkillsDest)) {
        Fail "product has .claude/skills; Cursor would duplicate discovery. Remove it or pass -Force before a Cursor install"
    }
}

Assert-RegularDirOrMissing (Join-Path $ProductRoot '.b3') '.b3'
Assert-RegularFileOrMissing $homeDest '.b3/home'
$rewriteHome = (-not (Test-Path -LiteralPath $homeDest -PathType Leaf)) -or $Force
if (Test-Path -LiteralPath $homeDest -PathType Leaf) {
    $rawHome = Get-Content -LiteralPath $homeDest -Raw -ErrorAction SilentlyContinue
    $existingHome = if ($null -ne $rawHome) { ([string]$rawHome).Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($existingHome)) {
        if (-not $Force) {
            Fail "refusing to overwrite empty or invalid $homeDest. Pass -Force to update"
        }
        $rewriteHome = $true
    } else {
        $sameHome = $false
        if ($existingHome -match '^(/|[A-Za-z]:[\\/]|\\\\)') {
            try {
                $cmpMode = if ($env:OS -eq 'Windows_NT') { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
                $normExisting = Normalize-Path $existingHome
                $normRequested = Normalize-Path $B3Home
                $sameHome = (-not [string]::IsNullOrEmpty($normExisting)) -and $normExisting.Equals($normRequested, $cmpMode)
            } catch {
                $sameHome = ($existingHome -eq $B3Home)
            }
        }
        if (-not $sameHome -and -not $Force) {
            Fail "refusing to overwrite $homeDest (points to $existingHome, requested $B3Home). Pass -Force to update"
        }
        if (-not $sameHome) { $rewriteHome = $true }
    }
}

function Get-CanonicalCommandPayload([string]$SrcPath) {
    $raw = [IO.File]::ReadAllText($SrcPath, [System.Text.Encoding]::UTF8)
    $bodyLf = $raw.Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd("`n") + "`n"
    $bodySha = Get-TextSha256 $bodyLf
    $rendered = "${bodyLf}<!-- b3-managed-command: sha256=${bodySha} -->`n"
    return [PSCustomObject]@{
        BodyLf   = $bodyLf
        BodySha  = $bodySha
        Rendered = $rendered
    }
}

function Get-ManagedCommandState([string]$DestPath, [PSCustomObject]$Payload) {
    if (-not (Test-Path -LiteralPath $DestPath -PathType Leaf)) {
        return 'missing'
    }
    $destRaw = [IO.File]::ReadAllText($DestPath, [System.Text.Encoding]::UTF8)
    $destLf = $destRaw.Replace("`r`n", "`n").Replace("`r", "`n")
    if ($destLf -ceq $Payload.Rendered) {
        return 'current'
    }
    if ($destLf -match '(?s)\A(.*\n)<!-- b3-managed-command: sha256=([0-9a-f]{64}) -->\n?\z') {
        $prefixLf = $Matches[1]
        $recordedSha = $Matches[2]
        if ((Get-TextSha256 $prefixLf) -ceq $recordedSha) {
            return 'managed-stale'
        }
        return 'user-modified'
    }
    $destNorm = $destLf.TrimEnd("`n") + "`n"
    if ($destNorm -ceq $Payload.BodyLf) {
        return 'legacy-unmodified'
    }
    return 'user-modified'
}

$commandEntries = New-Object System.Collections.Generic.List[object]
if ($useCursor) {
    Assert-RegularDirOrMissing $cursorDir '.cursor'
    Assert-RegularDirOrMissing $cursorCommandsDir '.cursor/commands'
    Assert-RegularFileOrMissing $cursorReadmeDest '.cursor/README.md'
    $cmdFiles = Sort-FilesOrdinalByFullName @(Get-ChildItem -LiteralPath $b3Commands -Filter '*.md' -File | Where-Object { $_.Name -ne 'README.md' })
    foreach ($src in $cmdFiles) {
        $dest = Join-Path $cursorCommandsDir $src.Name
        Assert-RegularFileOrMissing $dest $src.Name
        $payload = Get-CanonicalCommandPayload $src.FullName
        $state = Get-ManagedCommandState $dest $payload
        if ($state -eq 'user-modified' -and -not $Force) {
            Fail "refusing to overwrite modified command pointer $dest. Re-run with -Force to overwrite"
        }
        $commandEntries.Add([PSCustomObject]@{
            Name    = $src.Name
            Src     = $src.FullName
            Dest    = $dest
            Payload = $payload
            State   = $state
        })
    }
}

function Install-SkillJunction([string]$Dest, [string]$Target) {
    if ((Test-Path -LiteralPath $Dest) -or (Test-IsReparseLink $Dest)) {
        if (Test-IsReparseLink $Dest) {
            if (Test-LinkTarget $Dest $Target) { return }
            if (-not $Force) {
                Fail "refusing to replace existing link $Dest (pass -Force to update)"
            }
            Remove-LinkOnly $Dest
        } else {
            Fail "refusing to replace existing non-link $Dest"
        }
    }
    Create-DirLink $Dest $Target
}

function Install-FlatSkillIndex([string]$DestRoot, [string]$SkillsSrc, [string]$CmdSkillsSrc) {
    if ((Test-Path -LiteralPath $DestRoot) -or (Test-IsReparseLink $DestRoot)) {
        if (Test-IsReparseLink $DestRoot) {
            Remove-LinkOnly $DestRoot
        } elseif (-not (Test-Path -LiteralPath $DestRoot -PathType Container)) {
            Fail "refusing to replace existing $DestRoot"
        }
    }
    New-Item -ItemType Directory -Path $DestRoot -Force | Out-Null
    Get-ChildItem -LiteralPath $SkillsSrc -Recurse -Filter 'SKILL.md' -File | ForEach-Object {
        $name = Get-SkillNameFromFile $_.FullName
        $srcDir = Split-Path -Parent $_.FullName
        Install-SkillJunction (Join-Path $DestRoot $name) $srcDir
    }
    if (Test-Path -LiteralPath $CmdSkillsSrc) {
        Get-ChildItem -LiteralPath $CmdSkillsSrc -Directory | ForEach-Object {
            if (-not (Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md'))) { return }
            Install-SkillJunction (Join-Path $DestRoot $_.Name) $_.FullName
        }
    }
}

function Update-B3Gitignore([string]$Root) {
    $gi = Join-Path $Root '.gitignore'
    $block = @"

# B3: commit .b3/home; keep run checkpoints and local model preferences private
.b3/ship/
.b3/research-ship/
.b3/pr-feedback/
.b3/models.md
"@
    if (-not (Test-Path -LiteralPath $gi)) {
        Set-Content -LiteralPath $gi -Value ($block.TrimStart() + "`n")
        return 'created'
    }
    $text = Get-Content -LiteralPath $gi -Raw
    $hasShip = ($text -match '(?m)^\s*\.b3/ship/\s*$')
    $hasResearch = ($text -match '(?m)^\s*\.b3/research-ship/\s*$')
    $hasPrFb = ($text -match '(?m)^\s*\.b3/pr-feedback/\s*$')
    $hasModels = ($text -match '(?m)^\s*\.b3/models\.md\s*$')
    if ($hasShip -and $hasResearch -and $hasPrFb -and $hasModels) { return 'present' }

    $missing = @()
    if (-not $hasShip) { $missing += '.b3/ship/' }
    if (-not $hasResearch) { $missing += '.b3/research-ship/' }
    if (-not $hasPrFb) { $missing += '.b3/pr-feedback/' }
    if (-not $hasModels) { $missing += '.b3/models.md' }

    if ($text -match '(?m)^\s*\.b3/\s*$') {
        $replacement = $missing -join "`n"
        $text = [regex]::Replace($text, '(?m)^\s*\.b3/\s*$', $replacement)
        Set-Content -LiteralPath $gi -Value $text -NoNewline
        return 'upgraded'
    }
    if ($hasShip -or $hasResearch -or $hasPrFb -or $hasModels) {
        Add-Content -LiteralPath $gi -Value ("`n" + ($missing -join "`n"))
        return 'upgraded'
    }
    Add-Content -LiteralPath $gi -Value $block
    return 'appended'
}

function Update-HostSkillGitignore([string]$Root, [string]$TargetHost) {
    $lines = @()
    if ($TargetHost -in @('codex', 'antigravity', 'all')) { $lines += '.agents/skills' }
    if ($TargetHost -in @('claude', 'all')) { $lines += @('.claude/skills', '.claude/agents') }
    if ($lines.Count -eq 0) { return 'n/a' }

    $gi = Join-Path $Root '.gitignore'
    if (-not (Test-Path -LiteralPath $gi)) {
        Set-Content -LiteralPath $gi -Value ("# B3: local host links (do not commit)`n" + ($lines -join "`n") + "`n")
        return 'created'
    }
    $text = Get-Content -LiteralPath $gi -Raw
    $missing = @()
    foreach ($line in $lines) {
        $escaped = [regex]::Escape($line)
        if ($text -notmatch "(?m)^\s*$escaped\s*$") { $missing += $line }
    }
    if ($missing.Count -eq 0) { return 'present' }
    Add-Content -LiteralPath $gi -Value ("`n# B3: local host links (do not commit)`n" + ($missing -join "`n"))
    return 'appended'
}

if ($DryRun) {
    Write-Output "dry-run: write $homeDest = $B3Home"
    if ($useCursor) {
        foreach ($entry in $commandEntries) {
            if ($entry.State -eq 'current') { Write-Output "dry-run: keep existing $($entry.Dest) (up to date)" }
            elseif ($entry.State -eq 'missing') { Write-Output "dry-run: write $($entry.Dest) from $($entry.Src)" }
            else { Write-Output "dry-run: refresh $($entry.Dest) from $($entry.Src) ($($entry.State))" }
        }
        if (Test-Path -LiteralPath $cursorReadmeTemplate) {
            Write-Output "dry-run: write $cursorReadmeDest"
        }
    }
    if (Test-Path -LiteralPath $agentsMdDest) { Write-Output "dry-run: keep existing $agentsMdDest" }
    elseif (Test-Path -LiteralPath $agentsMdTemplate) { Write-Output "dry-run: write $agentsMdDest from $agentsMdTemplate" }
    if ($useClaude) {
        if (Test-Path -LiteralPath $claudeMdDest) { Write-Output "dry-run: keep existing $claudeMdDest" }
        elseif (Test-Path -LiteralPath $claudeMdTemplate) { Write-Output "dry-run: write $claudeMdDest from $claudeMdTemplate" }
    }
    Write-Output "dry-run: gitignore .b3/ship/, .b3/research-ship/, .b3/pr-feedback/, and .b3/models.md (see Update-B3Gitignore)"
    if ($useFlatAgentsSkills) {
        Write-Output "dry-run: gitignore .agents/skills"
        Write-Output "dry-run: flatten $agentsDest (one junction per skill + command-skills linked)"
    }
    if ($useClaude) {
        Write-Output "dry-run: gitignore .claude/skills and .claude/agents"
        Write-Output "dry-run: flatten $claudeSkillsDest (one junction per skill + command-skills linked)"
        Write-Output "dry-run: junction $claudeAgentsDest -> $b3Agents"
    }
    $modelDryStatus = Initialize-PersonalModelsFile -B3Home $B3Home -DryRun -NonFatal
    if ($modelDryStatus -like 'kept:*') {
        Write-Output "dry-run: keep existing personal model preferences $($modelDryStatus.Substring(5))"
    } elseif ($modelDryStatus -like 'dry-run:*') {
        Write-Output "dry-run: initialize personal model preferences at $($modelDryStatus.Substring(8)) from $(Join-Path $B3Home 'config\models.example.md')"
    }
    exit 0
}

$ignorePlan = Update-B3Gitignore $ProductRoot
$skillIgnorePlan = Update-HostSkillGitignore $ProductRoot $HostName

New-Item -ItemType Directory -Path (Join-Path $ProductRoot '.b3') -Force | Out-Null
if ($rewriteHome) {
    [IO.File]::WriteAllText($homeDest, $B3Home, $script:B3Utf8NoBom)
}
if ((-not (Test-Path -LiteralPath $agentsMdDest)) -and (Test-Path -LiteralPath $agentsMdTemplate)) {
    Copy-Item -LiteralPath $agentsMdTemplate -Destination $agentsMdDest
}
if ($useClaude -and (-not (Test-Path -LiteralPath $claudeMdDest)) -and (Test-Path -LiteralPath $claudeMdTemplate)) {
    Copy-Item -LiteralPath $claudeMdTemplate -Destination $claudeMdDest
}

if ($useCursor) {
    New-Item -ItemType Directory -Path $cursorCommandsDir -Force | Out-Null
    foreach ($entry in $commandEntries) {
        if ($entry.State -ne 'current') {
            Write-Utf8NoBom $entry.Dest $entry.Payload.Rendered
        }
    }
    if (Test-Path -LiteralPath $cursorReadmeTemplate) {
        Copy-Item -LiteralPath $cursorReadmeTemplate -Destination $cursorReadmeDest -Force
    }
}

if ($useFlatAgentsSkills) {
    Install-FlatSkillIndex $agentsDest $skills $commandSkillsSrc
}
if ($useClaude) {
    Install-FlatSkillIndex $claudeSkillsDest $skills $commandSkillsSrc
    if (Test-Path -LiteralPath $b3Agents -PathType Container) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $claudeAgentsDest) -Force | Out-Null
        Install-SkillJunction $claudeAgentsDest $b3Agents
    }
}

$modelPrefStatus = Initialize-PersonalModelsFile -B3Home $B3Home -NonFatal

Write-Output "installed B3 pointer in $ProductRoot"
Write-Output "B3_HOME=$B3Home"
if ($useCursor) {
    Write-Output "command=$commandDest"
} elseif ($HostName -in @('codex', 'antigravity')) {
    Write-Output "command=command-skills ($agentsDest)"
} else {
    Write-Output "command=command-skills ($claudeSkillsDest)"
}
Write-Output "agents.md=$agentsMdDest"
if ($useClaude) { Write-Output "claude.md=$claudeMdDest" }
Write-Output "gitignore.b3=$ignorePlan"
Write-Output "gitignore.skills=$skillIgnorePlan"
Write-Output "model_preferences=$modelPrefStatus"
Write-Output "host=$HostName"
if ($HostName -eq 'codex') {
    Write-Output "skills=$agentsDest (flattened junctions + command-skills linked incl. `$b3-ship; gitignored, not copied)"
} elseif ($HostName -eq 'antigravity') {
    Write-Output "skills=$agentsDest (flattened junctions + command-skills linked; gitignored, not copied; use adapters/install-global.ps1 -HostName antigravity if Cursor also opens this repo)"
} elseif ($HostName -eq 'claude') {
    Write-Output "skills=$claudeSkillsDest (flattened junctions + command-skills linked) + $claudeAgentsDest -> $b3Agents (gitignored, not copied)"
} elseif ($HostName -eq 'all') {
    Write-Output "skills=$agentsDest + $claudeSkillsDest (flattened junctions + command-skills linked incl. `$b3-ship) + .cursor/commands"
} else {
    Write-Output "skills=user-level ~/.cursor/skills/<name> via adapters/install-global.ps1 -HostName cursor (not copied into product)"
}
Write-Output "note: this proves files were written, not host slash-command or skill discovery"
