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

if ($env:B3_USE_LEGACY -ne '1') {
    $b3Home = Split-Path -Parent $PSScriptRoot
    $b3BinName = if ([IO.Path]::DirectorySeparatorChar -eq '\') { 'b3.exe' } else { 'b3' }
    $b3Candidate = if ($env:B3_BIN -and (Test-Path -LiteralPath $env:B3_BIN -PathType Leaf)) {
        $env:B3_BIN
    } else {
        $relBin = Join-Path $b3Home "target\release\$b3BinName"
        if (Test-Path -LiteralPath $relBin -PathType Leaf) { $relBin } else { $null }
    }
    if ($b3Candidate) {
        $fwdArgs = New-Object System.Collections.Generic.List[string]
        [void]$fwdArgs.Add('pr')
        [void]$fwdArgs.Add('verify')
        if ($PSBoundParameters.ContainsKey('Mode')) { [void]$fwdArgs.Add("--mode=$Mode") }
        if ($PSBoundParameters.ContainsKey('RepoRoot')) { [void]$fwdArgs.Add("--repo-root=$RepoRoot") }
        if ($PSBoundParameters.ContainsKey('Repo')) { [void]$fwdArgs.Add("--repo=$Repo") }
        if ($PSBoundParameters.ContainsKey('PrNumber')) { [void]$fwdArgs.Add("--pr-number=$PrNumber") }
        foreach ($ea in @($ExtraArgs)) { [void]$fwdArgs.Add([string]$ea) }

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
$mjsPath = Join-Path $PSScriptRoot 'lib\b3-github-verify.mjs'
if (-not (Test-Path -LiteralPath $mjsPath -PathType Leaf)) { Fail-GhError 'missing_verifier_module' }

$nodeCmd = Get-Command node -CommandType Application -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Source -and
        (-not $isWin -or (($_.Source -replace '/', '\') -inotmatch '\\microsoft\\windowsapps\\')) -and
        (Test-Path -LiteralPath $_.Source -PathType Leaf)
    } |
    Select-Object -First 1
if (-not $nodeCmd) { Fail-GhUnavailable 'node_runtime_unavailable' }

$nodeArgs = @($mjsPath, '--mode', $modeTrim, '--repo', $resolvedRepo, '--pr-number', $prTrim)
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
