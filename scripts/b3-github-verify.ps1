[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Mode = '',
    [string]$RepoRoot = '',
    [string]$Repo = '',
    [string]$PrNumber = '',
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ExtraArgs = @()
)

$ErrorActionPreference = 'Stop'

function Fail-GhError([string]$Reason) {
    Write-Output "GH_VERIFY_ERROR: $Reason"
    exit 1
}

function Fail-GhUnavailable([string]$Reason) {
    Write-Output "GH_VERIFY_UNAVAILABLE: $Reason"
    exit 2
}

$hasRepoRoot = $PSBoundParameters.ContainsKey('RepoRoot')
for ($i = 0; $i -lt $ExtraArgs.Count; $i++) {
    $a = $ExtraArgs[$i]
    switch -Exact ($a) {
        '--mode' { if ($i + 1 -ge $ExtraArgs.Count) { Fail-GhError "missing_value($a)" }; $Mode = $ExtraArgs[++$i] }
        '--repo-root' { if ($i + 1 -ge $ExtraArgs.Count) { Fail-GhError "missing_value($a)" }; $RepoRoot = $ExtraArgs[++$i]; $hasRepoRoot = $true }
        '--repo' { if ($i + 1 -ge $ExtraArgs.Count) { Fail-GhError "missing_value($a)" }; $Repo = $ExtraArgs[++$i] }
        '--pr-number' { if ($i + 1 -ge $ExtraArgs.Count) { Fail-GhError "missing_value($a)" }; $PrNumber = $ExtraArgs[++$i] }
        default { Fail-GhError "unknown_option($a)" }
    }
}

$modeTrim = if ($Mode) { $Mode.Trim() } else { '' }
if ($modeTrim -cnotin @('pre-merge', 'post-merge')) { Fail-GhError 'invalid_mode' }

$prTrim = if ($PrNumber) { $PrNumber.Trim() } else { '' }
if ($prTrim -cnotmatch '^[1-9][0-9]*$') { Fail-GhError 'invalid_pr_number' }

$repoTrim = if ($Repo) { $Repo.Trim() } else { '' }
if ($repoTrim -and ($repoTrim -cnotmatch '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' -or $repoTrim.Contains('..'))) {
    Fail-GhError 'invalid_repo'
}

function Parse-GhSlug([string]$RemoteUrl) {
    if (-not $RemoteUrl) { return '' }
    $u = $RemoteUrl.Trim()
    if ($u -match '^https://(?:[^/@\s]+@)?github\.com/([A-Za-z0-9._-]+/[A-Za-z0-9._-]+?)(?:\.git)?/?$') {
        if (-not $Matches[1].Contains('..')) { return $Matches[1] }
    } elseif ($u -match '^(?:ssh://)?git@github\.com[:/]([A-Za-z0-9._-]+/[A-Za-z0-9._-]+?)(?:\.git)?/?$') {
        if (-not $Matches[1].Contains('..')) { return $Matches[1] }
    }
    return ''
}

$resolvedRepo = $repoTrim
if ($hasRepoRoot -or -not $repoTrim) {
    $rootCheck = if ($hasRepoRoot -and $RepoRoot.Trim()) { $RepoRoot.Trim() } else { '.' }
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $origOut = @()
    $origRc = 1
    try {
        $origOut = @(& git -C $rootCheck remote get-url origin 2>$null)
        $origRc = $LASTEXITCODE
    } catch {
        $origRc = 1
    } finally {
        $ErrorActionPreference = $prevEap
    }
    if ($origRc -ne 0) { Fail-GhError 'origin_remote_missing' }
    $originSlug = Parse-GhSlug (($origOut -join "`n").Trim())
    if (-not $originSlug) { Fail-GhError 'origin_remote_not_github' }
    if ($repoTrim -and -not $repoTrim.Equals($originSlug, [System.StringComparison]::OrdinalIgnoreCase)) {
        Fail-GhError 'repo_mismatch'
    }
    $resolvedRepo = $originSlug
}

$isWin = ([IO.Path]::DirectorySeparatorChar -eq '\')
$pathDirs = @(($env:PATH -split [IO.Path]::PathSeparator) | Where-Object { $_ })

function Test-IsWindowsAppsStub([string]$FilePath) {
    if (-not $isWin -or -not $FilePath) { return $false }
    return (($FilePath -replace '/', '\') -imatch '\\microsoft\\windowsapps\\')
}

function Test-ValidExecutable([string]$FilePath) {
    if (-not $FilePath -or $FilePath -match '[\x00-\x1F\x7F]') { return $false }
    if (Test-IsWindowsAppsStub $FilePath) { return $false }
    return (Test-Path -LiteralPath $FilePath -PathType Leaf)
}

function Resolve-GhBinPath {
    $cand = if ($env:B3_GH_BIN) { $env:B3_GH_BIN.Trim() } else { '' }
    if ($cand) {
        if ($cand -match '[\x00-\x1F\x7F]') { return '' }
        if ($cand.Contains('/') -or $cand.Contains('\') -or ($isWin -and $cand -match '^[A-Za-z]:')) {
            if (Test-ValidExecutable $cand) { return $cand }
            if ($isWin -and $cand -notmatch '\.[A-Za-z0-9]+$') {
                foreach ($ext in @('.exe', '.com', '.cmd', '.bat')) {
                    if (Test-ValidExecutable ($cand + $ext)) { return ($cand + $ext) }
                }
            }
            return ''
        }
        $names = if ($isWin -and $cand -notmatch '\.[A-Za-z0-9]+$') { @("$cand.exe", "$cand.com", "$cand.cmd", "$cand.bat", $cand) } else { @($cand) }
        foreach ($d in $pathDirs) {
            foreach ($n in $names) {
                $f = Join-Path $d $n
                if (Test-ValidExecutable $f) { return $f }
            }
        }
        return ''
    }
    $names = if ($isWin) { @('gh.exe', 'gh.com', 'gh.cmd', 'gh.bat', 'gh') } else { @('gh') }
    foreach ($d in $pathDirs) {
        foreach ($n in $names) {
            $f = Join-Path $d $n
            if (Test-ValidExecutable $f) { return $f }
        }
    }
    return ''
}

function Resolve-BashBinPath {
    $bCand = if ($env:B3_BASH_BIN) { $env:B3_BASH_BIN.Trim() } else { '' }
    if ($bCand -and (Test-ValidExecutable $bCand)) { return $bCand }
    if ($isWin) {
        $winCands = New-Object System.Collections.Generic.List[string]
        if ($env:ProgramFiles) {
            [void]$winCands.Add((Join-Path $env:ProgramFiles 'Git\bin\bash.exe'))
            [void]$winCands.Add((Join-Path $env:ProgramFiles 'Git\usr\bin\bash.exe'))
        }
        [void]$winCands.Add('C:\Program Files\Git\bin\bash.exe')
        [void]$winCands.Add('C:\Program Files\Git\usr\bin\bash.exe')
        [void]$winCands.Add('C:\Program Files (x86)\Git\bin\bash.exe')
        foreach ($c in $winCands) {
            if ($c -and (Test-ValidExecutable $c)) { return $c }
        }
    }
    $bName = if ($isWin) { 'bash.exe' } else { 'bash' }
    foreach ($d in $pathDirs) {
        $f = Join-Path $d $bName
        if ($isWin) {
            $nb = $f -replace '/', '\'
            if ($nb -imatch '\\windows\\(system32|sysnative)\\bash\.exe$') { continue }
        }
        if (Test-ValidExecutable $f) { return $f }
    }
    return ''
}

$ghBin = Resolve-GhBinPath
if (-not $ghBin) { Fail-GhUnavailable 'gh_cli_unavailable' }
$bashBin = if ($isWin -and $ghBin -notmatch '\.(exe|com|cmd|bat)$') { Resolve-BashBinPath } else { '' }
if ($isWin -and $ghBin -notmatch '\.(exe|com|cmd|bat)$' -and -not $bashBin) { Fail-GhUnavailable 'gh_cli_unavailable' }

$mjsPath = Join-Path $PSScriptRoot 'lib\b3-github-verify.mjs'
if (-not (Test-Path -LiteralPath $mjsPath -PathType Leaf)) { Fail-GhError 'missing_verifier_module' }

$nodeCmd = Get-Command node -CommandType Application -ErrorAction SilentlyContinue |
    Where-Object { Test-ValidExecutable $_.Source } |
    Select-Object -First 1
if (-not $nodeCmd) { Fail-GhUnavailable 'node_runtime_unavailable' }

$nodeArgs = @($mjsPath, '--mode', $modeTrim, '--repo', $resolvedRepo, '--pr-number', $prTrim, '--gh-bin', $ghBin)
if ($bashBin) { $nodeArgs += @('--bash-bin', $bashBin) }
$psiN = New-Object System.Diagnostics.ProcessStartInfo
$psiN.FileName = $nodeCmd.Source
$psiN.UseShellExecute = $false
$psiN.RedirectStandardOutput = $true
$psiN.RedirectStandardError = $true
$psiN.CreateNoWindow = $true
$psiN.StandardOutputEncoding = [System.Text.Encoding]::UTF8
$psiN.StandardErrorEncoding = [System.Text.Encoding]::UTF8
if ($psiN.PSObject.Properties['ArgumentList']) {
    foreach ($na in $nodeArgs) { [void]$psiN.ArgumentList.Add($na) }
} else {
    $psiN.Arguments = (($nodeArgs | ForEach-Object {
        if ($null -eq $_ -or $_.Length -eq 0) { '""' }
        elseif ($_ -match '[\s"]') { '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }
        else { $_ }
    }) -join ' ')
}
$pN = [System.Diagnostics.Process]::Start($psiN)
$oTask = $pN.StandardOutput.ReadToEndAsync()
$eTask = $pN.StandardError.ReadToEndAsync()
if (-not $pN.WaitForExit(65000)) {
    try { $pN.Kill() } catch {}
    $pN.Dispose()
    Fail-GhUnavailable 'github_cli_timeout'
}
$oTxt = $oTask.GetAwaiter().GetResult()
$eTxt = $eTask.GetAwaiter().GetResult()
$ec = $pN.ExitCode
$pN.Dispose()
if ($oTxt) {
    foreach ($ln in ($oTxt.TrimEnd("`r", "`n") -split "\r?\n")) { Write-Output $ln }
} elseif ($ec -ne 0 -and $eTxt) {
    Fail-GhError ("verifier_failed($($eTxt.Trim().Split("`n")[0]))")
}
exit $ec
