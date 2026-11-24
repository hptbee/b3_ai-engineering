# Shared sandbox test helpers for global Cursor and Antigravity validation suites.
# ASCII-only, no BOM, Windows PowerShell 5.1+ compatible.

$script:HelpersRepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:FailedCount = 0
$script:PassedCount = 0

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

function Invoke-PsScript([string]$ScriptPath, [string[]]$ScriptArgs) {
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
    New-Item -ItemType Directory -Path $DestDir -Force | Out-Null

    $dirs = @('skills', 'commands', 'agents', 'rules', 'workflows', 'adapters\lib')
    if ($IncludeCommandSkills) {
        $dirs += 'adapters\command-skills'
    }
    foreach ($sub in $dirs) {
        $srcDir = Join-Path $RepoRoot $sub
        $dstDir = Join-Path $DestDir $sub
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
        $dstFile = Join-Path $DestDir $relFile
        $dstParent = Split-Path -Parent $dstFile
        if (-not (Test-Path -LiteralPath $dstParent)) {
            New-Item -ItemType Directory -Path $dstParent -Force | Out-Null
        }
        Copy-Item -LiteralPath $srcFile -Destination $dstFile -Force
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
    New-Item -ItemType Directory -Path $RepoPath -Force | Out-Null
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
