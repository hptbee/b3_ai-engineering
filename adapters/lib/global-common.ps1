# Shared PowerShell primitives for B3 global host installers (Cursor & Antigravity).
# Windows PowerShell 5.1+ and PowerShell 7+ compatible; pure ASCII (no BOM).

$script:B3Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

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
    $lf = $Content.Replace("`r`n", "`n").Replace("`r", "`n")
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($Path, $lf, $script:B3Utf8NoBom)
}

function Get-BytesSha256([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($Bytes)
        return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-TextSha256([string]$Text) {
    return (Get-BytesSha256 ($script:B3Utf8NoBom.GetBytes($Text.Replace("`r`n", "`n").Replace("`r", "`n"))))
}

function Get-FileSha256([string]$FilePath) {
    return (Get-BytesSha256 ([IO.File]::ReadAllBytes($FilePath)))
}

function Read-FileInfo([string]$FilePath) {
    $bytes = [IO.File]::ReadAllBytes($FilePath)
    return [PSCustomObject]@{
        Bytes  = $bytes
        Length = $bytes.Length
        Text   = $script:B3Utf8NoBom.GetString($bytes)
        Sha256 = (Get-BytesSha256 $bytes)
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
        Fail "refusing to remove non-link entry: $LinkPath"
    }
    if ($item.PSIsContainer -and ($env:OS -eq 'Windows_NT')) {
        & cmd.exe /c rmdir "`"$LinkPath`"" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0 -or $null -ne (Get-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue)) {
            Fail "could not remove link directory: $LinkPath"
        }
        return
    }
    Remove-Item -LiteralPath $LinkPath -Force
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

function Test-LinkTarget([string]$LinkPath, [string]$ExpectedDir, [switch]$RawTargetOnly) {
    if (-not (Test-IsReparseLink $LinkPath)) { return $false }
    try {
        $expectedFull = [IO.Path]::GetFullPath($ExpectedDir).TrimEnd('\', '/')
        $item = Get-Item -LiteralPath $LinkPath -Force
        if (-not $RawTargetOnly -and -not $item.PSIsContainer) { return $false }
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
        if (-not $candidate -and -not $RawTargetOnly -and (Test-Path -LiteralPath $LinkPath -PathType Container)) {
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

function Assert-RegularDirOrMissing([string]$DirPath, [string]$Label = '') {
    if ((Test-Path -LiteralPath $DirPath) -or (Test-IsReparseLink $DirPath)) {
        if (Test-IsReparseLink $DirPath) {
            $desc = if ($Label) { " ${Label}" } else { '' }
            Fail "refusing to traverse link directory${desc}: $DirPath"
        }
        if (-not (Test-Path -LiteralPath $DirPath -PathType Container)) {
            $desc = if ($Label) { " ${Label}" } else { ' directory' }
            Fail "existing non-directory path blocks${desc}: $DirPath"
        }
    }
}

function Assert-RegularFileOrMissing([string]$FilePath, [string]$Label = '') {
    if (Test-IsReparseLink $FilePath) {
        $desc = if ($Label) { $Label } else { $FilePath }
        Fail "existing link blocks ${desc}: $FilePath"
    }
    if ((Test-Path -LiteralPath $FilePath) -and -not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        $desc = if ($Label) { $Label } else { $FilePath }
        Fail "existing non-file path blocks ${desc}: $FilePath"
    }
}

function Remove-EmptyRegularDir([string]$DirPath) {
    if ((Test-Path -LiteralPath $DirPath -PathType Container) -and -not (Test-IsReparseLink $DirPath)) {
        if (@(Get-ChildItem -LiteralPath $DirPath -Force).Count -eq 0) {
            Remove-Item -LiteralPath $DirPath -Force
        }
    }
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
        [Array]::Sort($arr, [System.Comparison[System.IO.FileInfo]]{
            param($a, $b)
            [System.StringComparer]::Ordinal.Compare($a.FullName, $b.FullName)
        })
    }
    return $arr
}

function Split-YamlFrontmatter([string]$FilePath, [switch]$RequireFrontmatter) {
    $raw = ([IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8)).Replace("`r`n", "`n").Replace("`r", "`n")
    $lines = $raw -split "`n"
    if ($lines.Count -ge 3 -and $lines[0].Trim() -eq '---') {
        $endIdx = -1
        for ($i = 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Trim() -eq '---') { $endIdx = $i; break }
        }
        if ($endIdx -lt 0) {
            if ($RequireFrontmatter) { Fail "canonical markdown unclosed YAML frontmatter: $FilePath" }
            return [PSCustomObject]@{ HasFrontmatter = $false; Frontmatter = ''; FmLines = @(); Body = $raw.Trim() }
        }
        $fmLines = @($lines[0..$endIdx])
        $bodyLines = if ($endIdx + 1 -lt $lines.Count) { @($lines[($endIdx + 1)..($lines.Count - 1)]) } else { @() }
        return [PSCustomObject]@{
            HasFrontmatter = $true
            Frontmatter    = ($fmLines -join "`n")
            FmLines        = $fmLines
            Body           = (($bodyLines -join "`n").TrimStart("`n")).TrimEnd()
        }
    }
    if ($RequireFrontmatter) { Fail "canonical markdown missing YAML frontmatter: $FilePath" }
    return [PSCustomObject]@{ HasFrontmatter = $false; Frontmatter = ''; FmLines = @(); Body = $raw.Trim() }
}

function Get-SkillNameFromFile([string]$SkillFile) {
    $parsed = Split-YamlFrontmatter $SkillFile
    foreach ($line in $parsed.FmLines) {
        if ($line -match '^\s*name:\s*([a-z0-9-]+)\s*$') {
            return $Matches[1]
        }
    }
    return (Split-Path -Leaf (Split-Path -Parent $SkillFile))
}

function Add-CanonicalSkills([string]$RootDir, [hashtable]$AllMap, [hashtable]$BucketMap) {
    $files = Sort-FilesOrdinalByFullName @(Get-ChildItem -LiteralPath $RootDir -Recurse -Filter 'SKILL.md' -File -ErrorAction SilentlyContinue)
    foreach ($sf in $files) {
        $sname = Get-SkillNameFromFile $sf.FullName
        if ($AllMap.ContainsKey($sname)) {
            Fail "duplicate canonical skill name '$sname': $($AllMap[$sname]) and $($sf.FullName)"
        }
        $srcDir = Normalize-Path (Split-Path -Parent $sf.FullName)
        $AllMap[$sname] = $srcDir
        if ($null -ne $BucketMap) { $BucketMap[$sname] = $srcDir }
    }
    return $files.Count
}

function Read-B3Manifest([string]$ManifestPath) {
    $sections = @{
        skill   = @{}
        command = @{}
        agent   = @{}
        file    = @{}
        link    = @{}
    }
    $m = [PSCustomObject]@{
        Exists     = $false
        Corrupt    = $false
        Schema     = ''
        B3Home     = ''
        PluginRoot = ''
        Sections   = $sections
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
        if ($parts.Count -lt 3 -or -not $sections.ContainsKey($parts[0]) -or -not $parts[1]) {
            $m.Corrupt = $true
            continue
        }
        $sections[$parts[0]][$parts[1]] = $parts[2]
    }
    return $m
}

function Get-SkillOverlaps([string]$RootDir, [string[]]$SkillNames) {
    $overlaps = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $RootDir -PathType Container)) { return @() }
    foreach ($sn in $SkillNames) {
        $p = Join-Path $RootDir $sn
        if ((Test-Path -LiteralPath $p) -or (Test-IsReparseLink $p)) {
            $overlaps.Add($sn)
        }
    }
    return @($overlaps)
}
