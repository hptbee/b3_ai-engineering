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
$effInstallDir = if ($InstallDir) { $InstallDir } else { Join-Path $repoRoot 'target\release' }

function Assert-NotReparseLink([string]$PathVal, [string]$Label) {
    if (Test-Path -LiteralPath $PathVal) {
        $item = Get-Item -LiteralPath $PathVal -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "BOOTSTRAP_FAIL: refusing symlink/junction $Label at $PathVal"
        }
    }
}

$arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
if (-not $Target) {
    if ($IsLinux) {
        $Target = if ($arch -eq 'arm64' -or $arch -eq 'aarch64') { 'aarch64-unknown-linux-gnu' } else { 'x86_64-unknown-linux-gnu' }
    } elseif ($IsMacOS) {
        $Target = if ($arch -eq 'arm64' -or $arch -eq 'aarch64') { 'aarch64-apple-darwin' } else { 'x86_64-apple-darwin' }
    } else {
        $Target = 'x86_64-pc-windows-msvc'
    }
}

$isWinTarget = $Target -like '*windows*'
$destName = if ($isWinTarget) { 'b3.exe' } else { 'b3' }
$artifactName = if ($isWinTarget) { "b3-$Target.exe" } else { "b3-$Target" }
$destPath = Join-Path $effInstallDir $destName
$prevPath = "$destPath.prev"

Assert-NotReparseLink $effInstallDir 'InstallDir'
Assert-NotReparseLink $destPath $destName
Assert-NotReparseLink $prevPath "$destName.prev"

if ($Rollback) {
    if (-not (Test-Path -LiteralPath $prevPath -PathType Leaf)) {
        [Console]::Error.WriteLine("ROLLBACK_FAIL: missing backup binary at $prevPath")
        exit 1
    }
    if ($DryRun) {
        Write-Output "DRY_RUN: would restore $prevPath -> $destPath"
        exit 0
    }
    Copy-Item -LiteralPath $prevPath -Destination $destPath -Force
    Write-Output "ROLLBACK_OK: restored=$destPath"
    exit 0
}

$staging = Join-Path ([IO.Path]::GetTempPath()) ("b3-bootstrap-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $staging -Force | Out-Null
try {
    $sumsFile = Join-Path $staging 'SHA256SUMS.txt'
    $stagedBin = Join-Path $staging $artifactName

    if ($ReleaseDir) {
        if (-not (Test-Path -LiteralPath $ReleaseDir -PathType Container)) {
            [Console]::Error.WriteLine("BOOTSTRAP_FAIL: ReleaseDir not found: $ReleaseDir")
            exit 1
        }
        $srcSums = Join-Path $ReleaseDir 'SHA256SUMS.txt'
        $srcBin = Join-Path $ReleaseDir $artifactName
        if (-not (Test-Path -LiteralPath $srcSums -PathType Leaf)) {
            [Console]::Error.WriteLine("BOOTSTRAP_FAIL: missing SHA256SUMS.txt in $ReleaseDir")
            exit 1
        }
        if (-not (Test-Path -LiteralPath $srcBin -PathType Leaf)) {
            [Console]::Error.WriteLine("BOOTSTRAP_FAIL: missing release binary $artifactName in $ReleaseDir")
            exit 1
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

    $expectedSha = $null
    foreach ($ln in (Get-Content -LiteralPath $sumsFile)) {
        if ($ln -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$') {
            $hashCand = $Matches[1].ToLowerInvariant()
            $fileCand = $Matches[2].Trim()
            if ($fileCand -eq $artifactName -or $fileCand -eq "./$artifactName") {
                $expectedSha = $hashCand
                break
            }
        }
    }
    if (-not $expectedSha) {
        [Console]::Error.WriteLine("BOOTSTRAP_FAIL: no checksum entry for $artifactName in SHA256SUMS.txt")
        exit 1
    }

    $actualSha = (Get-FileHash -LiteralPath $stagedBin -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha -ne $expectedSha) {
        [Console]::Error.WriteLine("BOOTSTRAP_FAIL: sha256 mismatch for $artifactName (expected=$expectedSha actual=$actualSha)")
        exit 1
    }

    if ($DryRun) {
        Write-Output "DRY_RUN: verified sha256=$actualSha target=$Target dest=$destPath"
        exit 0
    }

    if (-not (Test-Path -LiteralPath $effInstallDir)) {
        New-Item -ItemType Directory -Path $effInstallDir -Force | Out-Null
    }
    Assert-NotReparseLink $effInstallDir 'InstallDir'

    $hadPrev = $false
    if (Test-Path -LiteralPath $destPath -PathType Leaf) {
        Copy-Item -LiteralPath $destPath -Destination $prevPath -Force
        $hadPrev = $true
    }

    try {
        Copy-Item -LiteralPath $stagedBin -Destination $destPath -Force
        $verOut = & $destPath --version 2>&1
        if ($LASTEXITCODE -ne 0 -or ($verOut -notmatch '^b3 ')) {
            throw "verification failed (exit=$LASTEXITCODE out=$verOut)"
        }
        Write-Output "BOOTSTRAP_OK: target=$Target dest=$destPath sha256=$actualSha version=$($verOut | Select-Object -First 1)"
        exit 0
    } catch {
        if ($hadPrev -and (Test-Path -LiteralPath $prevPath -PathType Leaf)) {
            Copy-Item -LiteralPath $prevPath -Destination $destPath -Force
        } elseif (Test-Path -LiteralPath $destPath -PathType Leaf) {
            Remove-Item -LiteralPath $destPath -Force -ErrorAction SilentlyContinue
        }
        [Console]::Error.WriteLine("BOOTSTRAP_FAIL: post-install verification failed (rolled back): $_")
        exit 1
    }
} finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}
