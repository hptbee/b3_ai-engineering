# Shared sandbox test helpers for global Cursor and Antigravity validation suites.
# ASCII-only, no BOM, Windows PowerShell 5.1+ compatible.

$script:HelpersRepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:FailedCount = 0
$script:PassedCount = 0
if (-not $env:B3_BIN) {
    $b3BinNameH = if ([IO.Path]::DirectorySeparatorChar -eq '\') { 'b3.exe' } else { 'b3' }
    $relB3H = Join-Path $script:HelpersRepoRoot "target\release\$b3BinNameH"
    if (Test-Path -LiteralPath $relB3H -PathType Leaf) {
        $env:B3_BIN = $relB3H
    }
}

function Resolve-B3BashPath {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:ProgramFiles) {
        $candidates.Add((Join-Path $env:ProgramFiles 'Git\bin\bash.exe'))
    }
    if (${env:ProgramFiles(x86)}) {
        $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe'))
    }
    $candidates.Add('C:\Program Files\Git\bin\bash.exe')
    $candidates.Add('C:\Program Files (x86)\Git\bin\bash.exe')

    foreach ($cand in $candidates) {
        if ($cand -and (Test-Path -LiteralPath $cand -PathType Leaf)) {
            return $cand
        }
    }

    foreach ($bashCmd in @(Get-Command bash -All -CommandType Application -ErrorAction SilentlyContinue)) {
        $src = $bashCmd.Source
        if (-not $src) { continue }
        if ($src -match '[\\/]Windows[\\/]System32[\\/]bash\.exe$') { continue }
        if ($src -match '[\\/]Microsoft[\\/]WindowsApps[\\/]bash\.exe$') { continue }
        if (Test-Path -LiteralPath $src -PathType Leaf) {
            return $src
        }
    }
    return ''
}

$script:GitBash = Resolve-B3BashPath
$script:HasBash = (-not [string]::IsNullOrEmpty($script:GitBash)) -and (Test-Path -LiteralPath $script:GitBash -PathType Leaf)
if (-not $script:HasBash) {
    Write-Output 'WARNING: bash not found; cross-shell .sh checks skipped (INCOMPLETE)'
}

function Pass([string]$Name) {
    $script:PassedCount++
    Write-Output "PASS $Name"
}

function FailCheck([string]$Name, [string]$Detail) {
    Write-Output "FAIL $Name :: $Detail"
    $script:FailedCount++
}

function Complete-ValidationSuite {
    param(
        [switch]$AllowIncompleteBash
    )
    if ($script:FailedCount -gt 0) {
        Write-Output "$($script:FailedCount) check(s) failed"
        exit 1
    }
    if (-not $script:HasBash) {
        if ($AllowIncompleteBash) {
            Write-Output 'ok (PS-only; bash skipped - AllowIncompleteBash)'
            exit 0
        }
        Write-Output 'INCOMPLETE: bash unavailable (use -AllowIncompleteBash to accept PS-only)'
        exit 2
    }
    Write-Output 'ok'
    exit 0
}

$script:InProcRunspace = $null
$script:ParamMetaCache = @{}
$script:SnapshotSeedCache = @{}
$script:RepoSeedRoot = Join-Path $env:TEMP ("b3-repo-seed-" + $PID)
$script:RepoSeedCache = @{}
$script:B3Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -SupportEvent -Action ([scriptblock]::Create("if (Test-Path -LiteralPath '$($script:RepoSeedRoot.Replace("'", "''"))') { Remove-Item -LiteralPath '$($script:RepoSeedRoot.Replace("'", "''"))' -Recurse -Force -ErrorAction SilentlyContinue }"))

function Write-B3LfFile([string]$Path, [string]$Content) {
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, ($Content -replace "`r`n", "`n"), $script:B3Utf8NoBom)
}

function Get-B3ScriptParamMeta([string]$FullPath) {
    $item = Get-Item -LiteralPath $FullPath -ErrorAction Stop
    $key = "$($item.FullName)|$($item.LastWriteTimeUtc.Ticks)"
    if ($script:ParamMetaCache.ContainsKey($key)) {
        return $script:ParamMetaCache[$key]
    }
    $escapedPath = [System.Management.Automation.WildcardPattern]::Escape($item.FullName)
    $cmdInfo = Get-Command -Name $escapedPath -CommandType ExternalScript -ErrorAction Stop
    $allNames = New-Object System.Collections.Generic.List[string]
    $typeByName = @{}
    foreach ($kv in $cmdInfo.Parameters.GetEnumerator()) {
        $canon = $kv.Key
        $isSw = ($kv.Value.ParameterType -eq [switch])
        $allNames.Add($canon)
        $typeByName[$canon.ToLowerInvariant()] = @{ Name = $canon; IsSwitch = $isSw }
        foreach ($al in $kv.Value.Aliases) {
            $allNames.Add($al)
            $typeByName[$al.ToLowerInvariant()] = @{ Name = $canon; IsSwitch = $isSw }
        }
    }
    $meta = @{ Names = $allNames.ToArray(); Map = $typeByName }
    $script:ParamMetaCache[$key] = $meta
    return $meta
}

function Resolve-B3ParamToken([hashtable]$Meta, [string]$RawName) {
    $low = $RawName.ToLowerInvariant()
    if ($Meta.Map.ContainsKey($low)) {
        return $Meta.Map[$low]
    }
    $matchesList = New-Object System.Collections.Generic.List[object]
    $seenCanon = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $Meta.Names) {
        if ($n.ToLowerInvariant().StartsWith($low, [System.StringComparison]::Ordinal)) {
            $entry = $Meta.Map[$n.ToLowerInvariant()]
            if ($seenCanon.Add($entry.Name)) {
                $matchesList.Add($entry)
            }
        }
    }
    if ($matchesList.Count -eq 1) {
        return $matchesList[0]
    }
    return $null
}

function Invoke-PsScript([string]$ScriptPath, [string[]]$ScriptArgs) {
    if ($env:B3_TEST_OUT_OF_PROC_PS -eq '1' -or -not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $raw = & powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @ScriptArgs 2>&1
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prev
        }
        $lines = @($raw | ForEach-Object { ([string]$_).TrimEnd("`r") })
        return @{ Code = $code; Lines = $lines; Text = ($lines -join "`n") }
    }

    if ($null -eq $script:InProcRunspace) {
        $script:InProcRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $script:InProcRunspace.Open()
    }

    $resolvedScript = (Resolve-Path -LiteralPath $ScriptPath).ProviderPath
    $meta = Get-B3ScriptParamMeta -FullPath $resolvedScript
    if ($null -eq $ScriptArgs -or $ScriptArgs.Count -eq 0) {
        $argArr = [string[]]@()
    } else {
        $argArr = New-Object 'string[]' $ScriptArgs.Count
        [System.Array]::Copy($ScriptArgs, $argArr, $ScriptArgs.Count)
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('Set-Location -LiteralPath $b3Cwd; $global:LASTEXITCODE = 0; $ErrorActionPreference = "Continue"; try { & $b3Script ')
    $expectVal = $false
    for ($i = 0; $i -lt $argArr.Count; $i++) {
        $tok = $argArr[$i]
        if (-not $expectVal -and $null -ne $tok -and $tok -match '^-([A-Za-z][A-Za-z0-9_]*)(?::(.*))?$') {
            $rawParam = $Matches[1]
            $hasColon = $tok.Contains(':')
            $colonVal = $Matches[2]
            $pInfo = Resolve-B3ParamToken -Meta $meta -RawName $rawParam
            if ($null -ne $pInfo) {
                if ($pInfo.IsSwitch) {
                    if ($hasColon) {
                        $bLit = if ($colonVal -match '^(true|\$true|1)$') { '$true' } else { '$false' }
                        [void]$sb.Append("-$($pInfo.Name):$bLit ")
                    } else {
                        [void]$sb.Append("-$($pInfo.Name) ")
                    }
                    continue
                } else {
                    if ($hasColon) {
                        $argArr[$i] = [string]$colonVal
                        [void]$sb.Append("-$($pInfo.Name) `$b3Args[$i] ")
                    } else {
                        [void]$sb.Append("-$($pInfo.Name) ")
                        $expectVal = $true
                    }
                    continue
                }
            } elseif (-not $hasColon) {
                # Unknown -Param token: let PowerShell emit native ParameterBindingException
                [void]$sb.Append("-$rawParam ")
                continue
            }
        }
        [void]$sb.Append("`$b3Args[$i] ")
        $expectVal = $false
    }
    [void]$sb.Append('2>&1 | ForEach-Object { if ($null -ne $_) { [Console]::Out.WriteLine([string]$_) } }; $b3Exit = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 } } catch { [Console]::Out.WriteLine($_.ToString()); $b3Exit = 1 }; [PSCustomObject]@{ B3ExitCode = $b3Exit }')

    $callerCwd = (Get-Location).ProviderPath
    $callerSysCwd = [System.Environment]::CurrentDirectory
    $needEnvSnap = ($resolvedScript -notmatch '[\\/]scripts[\\/]b3-guard\.ps1$')
    $envSnap = $null
    if ($needEnvSnap) {
        $envSnap = @{}
        foreach ($de in [System.Environment]::GetEnvironmentVariables().GetEnumerator()) {
            $envSnap[[string]$de.Key] = [string]$de.Value
        }
    }

    $origOut = [Console]::Out
    $origErr = [Console]::Error
    $swCapture = New-Object System.IO.StringWriter
    $ps = [powershell]::Create()
    $ps.Runspace = $script:InProcRunspace
    $code = 0
    try {
        [System.Environment]::CurrentDirectory = $callerCwd
        $script:InProcRunspace.SessionStateProxy.SetVariable('b3Cwd', $callerCwd)
        $script:InProcRunspace.SessionStateProxy.SetVariable('b3Script', $resolvedScript)
        $script:InProcRunspace.SessionStateProxy.SetVariable('b3Args', $argArr)
        [Console]::SetOut($swCapture)
        [Console]::SetError($swCapture)
        $res = $ps.AddScript($sb.ToString()).Invoke()
        foreach ($item in $res) {
            if ($item -is [PSCustomObject] -and $null -ne $item.PSObject.Properties['B3ExitCode']) {
                $code = [int]$item.B3ExitCode
            }
        }
    } finally {
        [Console]::SetOut($origOut)
        [Console]::SetError($origErr)
        $ps.Dispose()
        [System.Environment]::CurrentDirectory = $callerSysCwd
        if ($needEnvSnap) {
            $curEnv = [System.Environment]::GetEnvironmentVariables()
            foreach ($de in @($curEnv.GetEnumerator())) {
                $k = [string]$de.Key
                if (-not $envSnap.ContainsKey($k)) {
                    [System.Environment]::SetEnvironmentVariable($k, $null)
                } elseif ([string]$de.Value -cne $envSnap[$k]) {
                    [System.Environment]::SetEnvironmentVariable($k, $envSnap[$k])
                }
            }
            foreach ($kv in $envSnap.GetEnumerator()) {
                if (-not $curEnv.Contains($kv.Key)) {
                    [System.Environment]::SetEnvironmentVariable($kv.Key, $kv.Value)
                }
            }
        }
    }

    $capturedText = $swCapture.ToString()
    $swCapture.Dispose()
    $lines = if ([string]::IsNullOrEmpty($capturedText)) {
        @()
    } else {
        $split = $capturedText -split "`r?`n"
        if ($split.Count -gt 0 -and $split[$split.Count - 1] -eq '') {
            if ($split.Count -eq 1) { @() } else { @($split[0..($split.Count - 2)]) }
        } else {
            @($split)
        }
    }
    return @{ Code = $code; Lines = $lines; Text = ($lines -join "`n") }
}

function Invoke-ShScript([string]$ScriptPosix, [string]$ArgsLine) {
    if (-not $script:HasBash) {
        return @{ Code = 127; Lines = @('bash not found'); Text = 'bash not found' }
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & $script:GitBash -c "'$ScriptPosix' $ArgsLine" 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    $lines = @($raw | ForEach-Object { ([string]$_).TrimEnd("`r") })
    return @{ Code = $code; Lines = $lines; Text = ($lines -join "`n") }
}

function Copy-B3Snapshot {
    param(
        [Parameter(Mandatory = $true)][string]$DestDir,
        [string]$RepoRoot = $script:HelpersRepoRoot,
        [switch]$IncludeCommandSkills
    )
    $cacheKey = "$RepoRoot|$($IncludeCommandSkills.IsPresent)"
    if (-not $script:SnapshotSeedCache.ContainsKey($cacheKey) -or -not (Test-Path -LiteralPath $script:SnapshotSeedCache[$cacheKey])) {
        New-Item -ItemType Directory -Path $script:RepoSeedRoot -Force | Out-Null
        $seedSnap = Join-Path $script:RepoSeedRoot ('snap-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
        New-Item -ItemType Directory -Path $seedSnap -Force | Out-Null

        $dirs = @('skills', 'commands', 'agents', 'rules', 'workflows')
        if ($IncludeCommandSkills) {
            $dirs += 'adapters\command-skills'
        }
        foreach ($sub in $dirs) {
            $srcDir = Join-Path $RepoRoot $sub
            $dstDir = Join-Path $seedSnap $sub
            $dstParent = Split-Path -Parent $dstDir
            if (-not (Test-Path -LiteralPath $dstParent)) {
                New-Item -ItemType Directory -Path $dstParent -Force | Out-Null
            }
            Copy-Item -LiteralPath $srcDir -Destination $dstDir -Recurse -Force
        }

        $files = @(
            'adapters\install-global.ps1',
            'adapters\install-global.sh',
            'adapters\cursor\install-global.ps1',
            'adapters\cursor\install-global.sh',
            'adapters\antigravity\install-plugin.ps1',
            'adapters\antigravity\install-plugin.sh'
        )
        foreach ($relFile in $files) {
            $srcFile = Join-Path $RepoRoot $relFile
            $dstFile = Join-Path $seedSnap $relFile
            $dstParent = Split-Path -Parent $dstFile
            if (-not (Test-Path -LiteralPath $dstParent)) {
                New-Item -ItemType Directory -Path $dstParent -Force | Out-Null
            }
            Copy-Item -LiteralPath $srcFile -Destination $dstFile -Force
        }
        $script:SnapshotSeedCache[$cacheKey] = $seedSnap
    }
    Copy-B3DirectoryTree -SourceDir $script:SnapshotSeedCache[$cacheKey] -DestDir $DestDir
}

function New-B3SyncFixture {
    param(
        [Parameter(Mandatory = $true)][string]$FixtureDir,
        [string]$RepoRoot = $script:HelpersRepoRoot,
        [switch]$IncludeCommands,
        [switch]$IncludeAgents,
        [switch]$IncludeCommandSkills,
        [switch]$IncludeBash,
        [switch]$IncludeModelsExample
    )
    New-Item -ItemType Directory -Path (Join-Path $FixtureDir 'adapters'), (Join-Path $FixtureDir 'skills\eng\demo') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'adapters\sync-skills.ps1') -Destination (Join-Path $FixtureDir 'adapters\sync-skills.ps1') -Force
    if ($IncludeBash) {
        Copy-Item -LiteralPath (Join-Path $RepoRoot 'adapters\sync-skills.sh') -Destination (Join-Path $FixtureDir 'adapters\sync-skills.sh') -Force
    }
    Write-B3LfFile (Join-Path $FixtureDir 'skills\eng\demo\SKILL.md') "---`nname: demo`ndescription: demo`n---`n# demo`n"
    if ($IncludeCommands) {
        New-Item -ItemType Directory -Path (Join-Path $FixtureDir 'commands') -Force | Out-Null
        Write-B3LfFile (Join-Path $FixtureDir 'commands\b3-plan.md') "# b3-plan`n"
    }
    if ($IncludeAgents) {
        New-Item -ItemType Directory -Path (Join-Path $FixtureDir 'agents') -Force | Out-Null
        Write-B3LfFile (Join-Path $FixtureDir 'agents\b3-reviewer.md') "# b3-reviewer`n"
    }
    if ($IncludeCommandSkills) {
        New-Item -ItemType Directory -Path (Join-Path $FixtureDir 'adapters\command-skills\b3-ship') -Force | Out-Null
        Write-B3LfFile (Join-Path $FixtureDir 'adapters\command-skills\b3-ship\SKILL.md') "---`nname: b3-ship`ndescription: ship cmd`n---`n# Ship`n"
        if ($IncludeCommands) {
            Write-B3LfFile (Join-Path $FixtureDir 'commands\b3-ship.md') "# Ship`n"
        }
    }
    if ($IncludeModelsExample) {
        New-Item -ItemType Directory -Path (Join-Path $FixtureDir 'config') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $RepoRoot 'config\models.example.md') -Destination (Join-Path $FixtureDir 'config\models.example.md') -Force
    }
}

function Remove-ReparseLinksUnder([string]$DirPath) {
    if (-not (Test-Path -LiteralPath $DirPath)) { return }
    $rootItem = Get-Item -LiteralPath $DirPath -Force -ErrorAction SilentlyContinue
    if (-not $rootItem) { return }
    if ((($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) -or ($rootItem.LinkType -in @('Junction', 'SymbolicLink'))) {
        if ($rootItem.PSIsContainer) {
            [System.IO.Directory]::Delete($rootItem.FullName, $false)
        } else {
            Remove-Item -LiteralPath $rootItem.FullName -Force -ErrorAction SilentlyContinue
        }
        return
    }
    if (-not $rootItem.PSIsContainer) { return }
    foreach ($child in @(Get-ChildItem -LiteralPath $rootItem.FullName -Force -ErrorAction SilentlyContinue)) {
        if ((($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) -or ($child.LinkType -in @('Junction', 'SymbolicLink'))) {
            if ($child.PSIsContainer) {
                [System.IO.Directory]::Delete($child.FullName, $false)
            } else {
                Remove-Item -LiteralPath $child.FullName -Force -ErrorAction SilentlyContinue
            }
        } elseif ($child.PSIsContainer) {
            Remove-ReparseLinksUnder -DirPath $child.FullName
        }
    }
}

function New-TempGitRepo {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [string]$SubDir = '',
        [string]$SubFileName = '',
        [string]$SubFileContent = '',
        [string]$RootFileName = 'AGENTS.md',
        [string]$RootFileContent = ''
    )
    New-Item -ItemType Directory -Path $RepoPath -Force | Out-Null
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    if ($SubDir -and $SubFileName) {
        $subPath = Join-Path $RepoPath $SubDir
        New-Item -ItemType Directory -Path $subPath -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $subPath $SubFileName), "$SubFileContent`n", $utf8NoBom)
    }
    if ($RootFileName) {
        [System.IO.File]::WriteAllText((Join-Path $RepoPath $RootFileName), "$RootFileContent`n", $utf8NoBom)
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Push-Location $RepoPath
    try {
        foreach ($gitArgs in @(@('init', '-q'), @('config', 'user.email', 't@e.com'), @('config', 'user.name', 'T'), @('add', '.'), @('commit', '-qm', 'init'))) {
            $out = & git @gitArgs 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "git $($gitArgs -join ' ') failed in ${RepoPath}: $($out -join ' ')"
            }
        }
    } finally {
        Pop-Location
        $ErrorActionPreference = $prev
    }
}

function To-PosixPath([string]$PathValue) {
    if ($null -eq $PathValue) { return '' }
    return ($PathValue -replace '\\', '/')
}

function Format-BashArg([string]$Value) {
    if ($null -eq $Value) { return "''" }
    if ($Value -match '["\x00-\x1F\x7F]') {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append("`$'")
        foreach ($ch in $Value.ToCharArray()) {
            $code = [int]$ch
            if ($ch -eq '\') { [void]$sb.Append('\\') }
            elseif ($ch -eq "'") { [void]$sb.Append("\'") }
            elseif ($ch -eq '"') { [void]$sb.Append('\x22') }
            elseif ($code -le 0x1F -or $code -eq 0x7F) { [void]$sb.Append(('\x{0:x2}' -f $code)) }
            else { [void]$sb.Append($ch) }
        }
        [void]$sb.Append("'")
        return $sb.ToString()
    }
    return ("'" + ($Value -replace "'", "'\''") + "'")
}

function Invoke-PsGuard {
    param(
        [Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][string[]]$GuardArgs,
        [string]$GuardPath = (Join-Path $script:HelpersRepoRoot 'scripts\b3-guard.ps1')
    )
    return (Invoke-PsScript -ScriptPath $GuardPath -ScriptArgs $GuardArgs)
}

function Invoke-ShGuard {
    param(
        [Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][string[]]$GuardArgs,
        [string]$GuardPosix = (To-PosixPath (Join-Path $script:HelpersRepoRoot 'scripts\b3-guard.sh'))
    )
    if (-not $script:HasBash) {
        return @{ Code = 127; Lines = @('bash not found'); Text = 'bash not found' }
    }
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add((Format-BashArg $GuardPosix))
    foreach ($a in @($GuardArgs)) {
        $parts.Add((Format-BashArg ([string]$a)))
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & $script:GitBash -c ($parts -join ' ') 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    $lines = @($raw | ForEach-Object { ([string]$_).TrimEnd("`r") })
    return @{ Code = $code; Lines = $lines; Text = ($lines -join "`n") }
}

function Invoke-ShCmd([string]$BashCmd) {
    if (-not $script:HasBash) {
        return @{ Code = 127; Lines = @('bash not found'); Text = 'bash not found' }
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & $script:GitBash -c $BashCmd 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    $lines = @($raw | ForEach-Object { ([string]$_).TrimEnd("`r") })
    return @{ Code = $code; Lines = $lines; Text = ($lines -join "`n") }
}

function Copy-B3DirectoryTree([string]$SourceDir, [string]$DestDir) {
    [System.IO.Directory]::CreateDirectory($DestDir) | Out-Null
    foreach ($dirPath in [System.IO.Directory]::GetDirectories($SourceDir, '*', [System.IO.SearchOption]::AllDirectories)) {
        $rel = $dirPath.Substring($SourceDir.Length).TrimStart('\', '/')
        [System.IO.Directory]::CreateDirectory((Join-Path $DestDir $rel)) | Out-Null
    }
    foreach ($filePath in [System.IO.Directory]::GetFiles($SourceDir, '*', [System.IO.SearchOption]::AllDirectories)) {
        $rel = $filePath.Substring($SourceDir.Length).TrimStart('\', '/')
        [System.IO.File]::Copy($filePath, (Join-Path $DestDir $rel), $true)
    }
}

function Init-B3TestRepo {
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$RepoPath,
        [string]$DefaultBranch = 'main',
        [string]$UserEmail = 'b3-test@example.com',
        [string]$UserName = 'B3 Test',
        [switch]$InitialCommit,
        [string]$InitialFileName = 'README.md',
        [string]$InitialFileContent = 'base'
    )
    $RepoPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RepoPath)
    $preExisted = (Test-Path -LiteralPath $RepoPath) -and (@(Get-ChildItem -LiteralPath $RepoPath -Force -ErrorAction SilentlyContinue).Count -gt 0)
    New-Item -ItemType Directory -Path $RepoPath -Force | Out-Null

    if (-not $preExisted) {
        $seedKey = "$DefaultBranch|$UserEmail|$UserName|$($InitialCommit.IsPresent)|$InitialFileName|$InitialFileContent"
        if (-not $script:RepoSeedCache.ContainsKey($seedKey) -or -not (Test-Path -LiteralPath $script:RepoSeedCache[$seedKey])) {
            New-Item -ItemType Directory -Path $script:RepoSeedRoot -Force | Out-Null
            $seedDir = Join-Path $script:RepoSeedRoot ([guid]::NewGuid().ToString('N').Substring(0, 12))
            New-Item -ItemType Directory -Path $seedDir -Force | Out-Null
            $prev = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            Push-Location $seedDir
            try {
                foreach ($gitArgs in @(@('init', '-q'), @('symbolic-ref', 'HEAD', "refs/heads/$DefaultBranch"), @('config', 'user.email', $UserEmail), @('config', 'user.name', $UserName))) {
                    $out = & git @gitArgs 2>&1
                    if ($LASTEXITCODE -ne 0) { throw "git $($gitArgs -join ' ') failed in ${seedDir}: $($out -join ' ')" }
                }
                if ($InitialCommit) {
                    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
                    $initTarget = Join-Path $seedDir $InitialFileName
                    $initParent = Split-Path -Parent $initTarget
                    if ($initParent -and -not (Test-Path -LiteralPath $initParent)) { New-Item -ItemType Directory -Path $initParent -Force | Out-Null }
                    [System.IO.File]::WriteAllText($initTarget, "$InitialFileContent`n", $utf8NoBom)
                    foreach ($gitArgs in @(@('add', $InitialFileName), @('commit', '-qm', 'init'))) {
                        $out = & git @gitArgs 2>&1
                        if ($LASTEXITCODE -ne 0) { throw "git $($gitArgs -join ' ') failed in ${seedDir}: $($out -join ' ')" }
                    }
                }
            } finally {
                Pop-Location
                $ErrorActionPreference = $prev
            }
            $script:RepoSeedCache[$seedKey] = $seedDir
        }
        Copy-B3DirectoryTree -SourceDir $script:RepoSeedCache[$seedKey] -DestDir $RepoPath
        return
    }

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Push-Location $RepoPath
    try {
        $cmds = @(
            @('init', '-q'),
            @('symbolic-ref', 'HEAD', "refs/heads/$DefaultBranch"),
            @('config', 'user.email', $UserEmail),
            @('config', 'user.name', $UserName)
        )
        foreach ($gitArgs in $cmds) {
            $out = & git @gitArgs 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "git $($gitArgs -join ' ') failed in ${RepoPath}: $($out -join ' ')"
            }
        }
        if ($InitialCommit) {
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText((Join-Path $RepoPath $InitialFileName), "$InitialFileContent`n", $utf8NoBom)
            foreach ($gitArgs in @(@('add', $InitialFileName), @('commit', '-qm', 'init'))) {
                $out = & git @gitArgs 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "git $($gitArgs -join ' ') failed in ${RepoPath}: $($out -join ' ')"
                }
            }
        }
    } finally {
        Pop-Location
        $ErrorActionPreference = $prev
    }
}
