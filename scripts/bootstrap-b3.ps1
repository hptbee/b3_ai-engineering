# Checksum-verified bootstrap & rollback helper for the native `b3` binary.
# Supports local offline release bundles (-ReleaseDir) or GitHub Releases (-Version).
# Usage:
#   .\scripts\bootstrap-b3.ps1 [-Version latest|v0.1.0] [-ReleaseDir <dir>] [-InstallDir <dir>] [-Repo hptbee/b3_ai-engineering] [-Target x86_64-pc-windows-msvc] [-Rollback] [-DryRun]
param(
    [string]$Version = 'latest',
    [string]$ReleaseDir = '',
    [string]$InstallDir = '',
    [string]$Repo = 'hptbee/b3_ai-engineering',
    [string]$Target = '',
    [switch]$Rollback,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$allowedTargets = @(
    'x86_64-pc-windows-msvc',
    'x86_64-unknown-linux-gnu',
    'aarch64-apple-darwin',
    'x86_64-apple-darwin'
)

function Assert-ValidStringArg([string]$Value, [string]$Name, [bool]$AllowEmpty) {
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace($Value)) {
        if (-not $AllowEmpty) {
            throw "BOOTSTRAP_FAIL: invalid $Name (empty)"
        }
        return
    }
    if ($Value -match '[\x00-\x1f\x7f]') {
        throw "BOOTSTRAP_FAIL: invalid $Name (control characters)"
    }
}

function Assert-NoTraversal([string]$PathVal, [string]$Name) {
    foreach ($seg in ($PathVal -split '[\\/]')) {
        if ($seg -eq '..') {
            throw "BOOTSTRAP_FAIL: invalid $Name (path traversal '..' not allowed)"
        }
    }
}

function Assert-NotReparseLink([string]$PathVal, [string]$Label) {
    $attrs = $null
    $item = Get-Item -LiteralPath $PathVal -Force -ErrorAction SilentlyContinue
    if ($null -ne $item) {
        $attrs = $item.Attributes
    } else {
        try { $attrs = [IO.File]::GetAttributes($PathVal) } catch {}
    }
    if ($null -ne $attrs -and (($attrs -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "BOOTSTRAP_FAIL: refusing symlink/junction $Label at $PathVal"
    }
}

function Get-NormalizedFullPath([string]$RawPath) {
    $cwd = $ExecutionContext.SessionState.Path.CurrentFileSystemLocation.ProviderPath
    $full = [IO.Path]::GetFullPath([IO.Path]::Combine($cwd, $RawPath))
    if ($full.Length -gt 3) {
        $full = $full.TrimEnd('\', '/')
    }
    return $full
}

function Assert-AncestorsNotReparse([string]$FullPath) {
    $chain = [System.Collections.Generic.List[string]]::new()
    $cur = $FullPath
    while ($cur) {
        $chain.Add($cur)
        $parent = [IO.Path]::GetDirectoryName($cur)
        if (-not $parent -or $parent -eq $cur) { break }
        $cur = $parent
    }
    $chain.Reverse()
    foreach ($p in $chain) {
        Assert-NotReparseLink $p 'ancestor/InstallDir'
    }
}

function Test-HostMatchesTarget([string]$TargetVal) {
    $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    if ($IsLinux) {
        return ($TargetVal -eq 'x86_64-unknown-linux-gnu' -and ($arch -eq 'x64' -or $arch -eq 'x86_64' -or $arch -eq 'amd64'))
    } elseif ($IsMacOS) {
        if ($arch -eq 'arm64' -or $arch -eq 'aarch64') { return ($TargetVal -eq 'aarch64-apple-darwin') }
        if ($arch -eq 'x64' -or $arch -eq 'x86_64' -or $arch -eq 'amd64') { return ($TargetVal -eq 'x86_64-apple-darwin') }
        return $false
    } else {
        return ($TargetVal -eq 'x86_64-pc-windows-msvc' -and ($arch -eq 'x64' -or $arch -eq 'x86_64' -or $arch -eq 'amd64'))
    }
}

function Invoke-SmokeCheck([string]$BinPath, [string]$TargetVal) {
    if (-not (Test-HostMatchesTarget $TargetVal)) {
        return '(cross-target; smoke skipped)'
    }
    $proc = $null
    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new($BinPath, '--version')
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit()
        $verOut = $outTask.GetAwaiter().GetResult().Trim()
        $verErr = $errTask.GetAwaiter().GetResult().Trim()
        if ($proc.ExitCode -ne 0 -or ($verOut -notmatch '^b3 ')) {
            throw "smoke check failed (exit=$($proc.ExitCode) out='$verOut' err='$verErr')"
        }
        return ($verOut -split "`r?`n" | Select-Object -First 1)
    } catch {
        $msg = $_.Exception.Message
        if ($msg.StartsWith('BOOTSTRAP_FAIL:') -or $msg.StartsWith('ROLLBACK_FAIL:')) {
            throw
        }
        throw "BOOTSTRAP_FAIL: smoke check failed: $msg"
    } finally {
        if ($null -ne $proc) { $proc.Dispose() }
    }
}

function Acquire-BootstrapLock([string]$LockPath) {
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        Assert-NotReparseLink $LockPath '.b3-bootstrap.lock'
        try {
            return [IO.FileStream]::new($LockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        } catch [IO.IOException] {
            if ($attempt -eq 9) { throw 'BOOTSTRAP_FAIL: concurrent bootstrap in progress' }
            Start-Sleep -Milliseconds 100
        } catch [UnauthorizedAccessException] {
            if (-not (Test-Path -LiteralPath $LockPath) -or $attempt -eq 9) {
                throw 'BOOTSTRAP_FAIL: concurrent bootstrap in progress'
            }
            Start-Sleep -Milliseconds 100
        }
    }
    throw 'BOOTSTRAP_FAIL: concurrent bootstrap in progress'
}

function Remove-StaleOldFiles([string]$DirPath, [string]$DestName) {
    Get-ChildItem -LiteralPath $DirPath -Filter "$DestName.old.*" -Force -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Replace-BinaryAtomic([string]$StagedPath, [string]$DestPath, [string]$OldTmp) {
    if (Test-Path -LiteralPath $DestPath -PathType Leaf) {
        Move-Item -LiteralPath $DestPath -Destination $OldTmp -Force
        try {
            Move-Item -LiteralPath $StagedPath -Destination $DestPath -Force
        } catch {
            Move-Item -LiteralPath $OldTmp -Destination $DestPath -Force -ErrorAction SilentlyContinue
            throw
        }
        Remove-Item -LiteralPath $OldTmp -Force -ErrorAction SilentlyContinue
    } else {
        Move-Item -LiteralPath $StagedPath -Destination $DestPath -Force
    }
}

$exitCode = 0
$staging = $null
$lockStream = $null
$lockPath = $null
$sameFsStaged = $null
$prevTmp = $null
$rbTmp = $null

try {
    # 1. Strict input validation before constructing paths/URLs
    if ($PSBoundParameters.ContainsKey('InstallDir')) {
        Assert-ValidStringArg $InstallDir 'InstallDir' $false
        Assert-NoTraversal $InstallDir 'InstallDir'
        $effInstallDir = $InstallDir
    } else {
        $effInstallDir = [IO.Path]::Combine($repoRoot, 'target', 'release')
    }
    if ($PSBoundParameters.ContainsKey('ReleaseDir')) {
        Assert-ValidStringArg $ReleaseDir 'ReleaseDir' $false
        Assert-NoTraversal $ReleaseDir 'ReleaseDir'
    }
    Assert-ValidStringArg $Repo 'Repo' $false
    if ($Repo -notmatch '^([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)$') {
        throw "BOOTSTRAP_FAIL: invalid Repo '$Repo'"
    }
    $repoOwner = $Matches[1]
    $repoName = $Matches[2]
    if ($repoOwner -in @('.', '..') -or $repoName -in @('.', '..') -or $Repo.Contains('..')) {
        throw "BOOTSTRAP_FAIL: invalid Repo '$Repo'"
    }

    Assert-ValidStringArg $Version 'Version' $false
    if ($Version -ne 'latest') {
        if ($Version.Contains('..') -or $Version -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+([+-][A-Za-z0-9.-]+)?$') {
            throw "BOOTSTRAP_FAIL: invalid Version '$Version'"
        }
    }

    if (-not $Target) {
        $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
        if ($IsLinux) {
            $Target = if ($arch -eq 'arm64' -or $arch -eq 'aarch64') { 'aarch64-unknown-linux-gnu' } else { 'x86_64-unknown-linux-gnu' }
        } elseif ($IsMacOS) {
            $Target = if ($arch -eq 'arm64' -or $arch -eq 'aarch64') { 'aarch64-apple-darwin' } else { 'x86_64-apple-darwin' }
        } else {
            $Target = 'x86_64-pc-windows-msvc'
        }
    }
    Assert-ValidStringArg $Target 'Target' $false
    if ($allowedTargets -notcontains $Target) {
        throw "BOOTSTRAP_FAIL: unsupported target '$Target'"
    }

    $isWinTarget = $Target -like '*windows*'
    $destName = if ($isWinTarget) { 'b3.exe' } else { 'b3' }
    $artifactName = if ($isWinTarget) { "b3-$Target.exe" } else { "b3-$Target" }

    $normInstallDir = Get-NormalizedFullPath $effInstallDir
    $destPath = Join-Path $normInstallDir $destName
    $prevPath = "$destPath.prev"
    $lockPath = Join-Path $normInstallDir '.b3-bootstrap.lock'

    # 2. Ancestor & destination reparse/symlink rejection
    Assert-AncestorsNotReparse $normInstallDir
    if (Test-Path -LiteralPath $normInstallDir -PathType Leaf) {
        throw "BOOTSTRAP_FAIL: InstallDir is a file: $normInstallDir"
    }
    Assert-NotReparseLink $destPath $destName
    if (Test-Path -LiteralPath $destPath -PathType Container) {
        throw "BOOTSTRAP_FAIL: destination is a directory: $destPath"
    }
    Assert-NotReparseLink $prevPath "$destName.prev"
    if (Test-Path -LiteralPath $prevPath -PathType Container) {
        throw "BOOTSTRAP_FAIL: backup path is a directory: $prevPath"
    }
    Assert-NotReparseLink $lockPath '.b3-bootstrap.lock'

    if ($Rollback) {
        if (-not (Test-Path -LiteralPath $prevPath -PathType Leaf)) {
            throw "ROLLBACK_FAIL: missing backup binary at $prevPath"
        }
        $prevItem = Get-Item -LiteralPath $prevPath -Force
        if ($prevItem.Length -le 0) {
            throw "ROLLBACK_FAIL: empty backup binary at $prevPath"
        }
        try {
            $null = Invoke-SmokeCheck $prevPath $Target
        } catch {
            throw "ROLLBACK_FAIL: backup binary failed smoke check: $_"
        }
        if ($DryRun) {
            Write-Output "DRY_RUN: would restore $prevPath -> $destPath"
            return
        }

        $lockStream = Acquire-BootstrapLock $lockPath
        Assert-AncestorsNotReparse $normInstallDir
        Assert-NotReparseLink $destPath $destName
        Assert-NotReparseLink $prevPath "$destName.prev"
        if (-not (Test-Path -LiteralPath $prevPath -PathType Leaf) -or (Get-Item -LiteralPath $prevPath -Force).Length -le 0) {
            throw "ROLLBACK_FAIL: missing or empty backup binary at $prevPath"
        }
        try {
            $null = Invoke-SmokeCheck $prevPath $Target
        } catch {
            throw "ROLLBACK_FAIL: backup binary failed smoke check: $_"
        }

        Remove-StaleOldFiles $normInstallDir $destName
        $rand = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $rbTmp = "$destPath.rb.$PID.$rand"
        $oldTmp = "$destPath.old.$PID.$rand"
        [IO.File]::Copy($prevPath, $rbTmp, $true)
        Replace-BinaryAtomic $rbTmp $destPath $oldTmp
        $rbTmp = $null
        Write-Output "ROLLBACK_OK: restored=$destPath"
        return
    }

    # 3. Temp staging + strict SHA256SUMS.txt verification
    $staging = Join-Path ([IO.Path]::GetTempPath()) ("b3-bootstrap-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    $sumsFile = Join-Path $staging 'SHA256SUMS.txt'
    $stagedBin = Join-Path $staging $artifactName

    if ($ReleaseDir) {
        if (-not (Test-Path -LiteralPath $ReleaseDir -PathType Container)) {
            throw "BOOTSTRAP_FAIL: ReleaseDir not found: $ReleaseDir"
        }
        $srcSums = Join-Path $ReleaseDir 'SHA256SUMS.txt'
        $srcBin = Join-Path $ReleaseDir $artifactName
        if (-not (Test-Path -LiteralPath $srcSums -PathType Leaf)) {
            throw "BOOTSTRAP_FAIL: missing SHA256SUMS.txt in $ReleaseDir"
        }
        if (-not (Test-Path -LiteralPath $srcBin -PathType Leaf)) {
            throw "BOOTSTRAP_FAIL: missing release binary $artifactName in $ReleaseDir"
        }
        Copy-Item -LiteralPath $srcSums -Destination $sumsFile -Force
        Copy-Item -LiteralPath $srcBin -Destination $stagedBin -Force
    } else {
        $baseUrl = if ($Version -eq 'latest') {
            "https://github.com/$Repo/releases/latest/download"
        } else {
            "https://github.com/$Repo/releases/download/$Version"
        }
        Invoke-WebRequest -Uri "$baseUrl/SHA256SUMS.txt" -OutFile $sumsFile -UseBasicParsing
        Invoke-WebRequest -Uri "$baseUrl/$artifactName" -OutFile $stagedBin -UseBasicParsing
    }

    $seen = @{}
    $nonBlankCount = 0
    $expectedSha = $null
    foreach ($rawLn in (Get-Content -LiteralPath $sumsFile)) {
        $ln = $rawLn.TrimEnd("`r")
        if ([string]::IsNullOrWhiteSpace($ln)) { continue }
        $nonBlankCount++
        if ($ln -notmatch '^([0-9a-fA-F]{64})[ \t]+\*?(\./)?([A-Za-z0-9._-]+)$') {
            throw "BOOTSTRAP_FAIL: malformed SHA256SUMS.txt line: $ln"
        }
        $hashCand = $Matches[1].ToLowerInvariant()
        $fileCand = $Matches[3]
        if ($fileCand -eq '.' -or $fileCand -eq '..' -or $fileCand.Contains('..')) {
            throw "BOOTSTRAP_FAIL: invalid filename in SHA256SUMS.txt: $fileCand"
        }
        if ($seen.ContainsKey($fileCand)) {
            throw "BOOTSTRAP_FAIL: duplicate/ambiguous checksum entry for $fileCand in SHA256SUMS.txt"
        }
        $seen[$fileCand] = $hashCand
        if ($fileCand -eq $artifactName) {
            $expectedSha = $hashCand
        }
    }
    if ($nonBlankCount -eq 0) {
        throw 'BOOTSTRAP_FAIL: empty SHA256SUMS.txt manifest'
    }
    if (-not $expectedSha) {
        throw "BOOTSTRAP_FAIL: no checksum entry for $artifactName in SHA256SUMS.txt"
    }

    $shaProv = [System.Security.Cryptography.SHA256]::Create()
    try {
        $fsHash = [IO.File]::OpenRead($stagedBin)
        try {
            $hashBytes = $shaProv.ComputeHash($fsHash)
            $actualSha = ([BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant()
        } finally {
            $fsHash.Dispose()
        }
    } finally {
        $shaProv.Dispose()
    }
    if ($actualSha -ne $expectedSha) {
        throw "BOOTSTRAP_FAIL: sha256 mismatch for $artifactName (expected=$expectedSha actual=$actualSha)"
    }

    if ($DryRun) {
        $null = Invoke-SmokeCheck $stagedBin $Target
        Write-Output "DRY_RUN: verified sha256=$actualSha target=$Target dest=$destPath"
        return
    }

    # 4. Safe InstallDir creation, lock, same-FS staging, pre-activation smoke check, atomic replace
    if (-not (Test-Path -LiteralPath $normInstallDir)) {
        New-Item -ItemType Directory -Path $normInstallDir -Force | Out-Null
    }
    Assert-AncestorsNotReparse $normInstallDir
    Assert-NotReparseLink $destPath $destName
    Assert-NotReparseLink $prevPath "$destName.prev"
    $lockStream = Acquire-BootstrapLock $lockPath
    Assert-AncestorsNotReparse $normInstallDir
    Assert-NotReparseLink $destPath $destName
    Assert-NotReparseLink $prevPath "$destName.prev"

    Remove-StaleOldFiles $normInstallDir $destName
    $rand = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $sameFsStaged = "$destPath.new.$PID.$rand"
    [IO.File]::Copy($stagedBin, $sameFsStaged, $true)
    Assert-NotReparseLink $sameFsStaged 'staged-binary'

    $verStr = Invoke-SmokeCheck $sameFsStaged $Target

    if (Test-Path -LiteralPath $destPath -PathType Leaf) {
        $prevTmp = "$destPath.prev.tmp.$PID.$rand"
        $oldTmp = "$destPath.old.$PID.$rand"
        [IO.File]::Copy($destPath, $prevTmp, $true)
        Replace-BinaryAtomic $sameFsStaged $destPath $oldTmp
        $sameFsStaged = $null
        Move-Item -LiteralPath $prevTmp -Destination $prevPath -Force
        $prevTmp = $null
    } else {
        Move-Item -LiteralPath $sameFsStaged -Destination $destPath -Force
        $sameFsStaged = $null
    }

    Write-Output "BOOTSTRAP_OK: target=$Target dest=$destPath sha256=$actualSha version=$verStr"
} catch {
    [Console]::Error.WriteLine("$($_.Exception.Message)")
    $exitCode = 1
} finally {
    if ($null -ne $sameFsStaged) { Remove-Item -LiteralPath $sameFsStaged -Force -ErrorAction SilentlyContinue }
    if ($null -ne $prevTmp) { Remove-Item -LiteralPath $prevTmp -Force -ErrorAction SilentlyContinue }
    if ($null -ne $rbTmp) { Remove-Item -LiteralPath $rbTmp -Force -ErrorAction SilentlyContinue }
    if ($null -ne $lockStream) {
        try { $lockStream.Dispose() } catch {}
        if ($null -ne $lockPath) { Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue }
    }
    if ($null -ne $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
}
exit $exitCode
