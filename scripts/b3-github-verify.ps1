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

function Resolve-GhBinPath {
    $cand = if ($env:B3_GH_BIN) { $env:B3_GH_BIN.Trim() } else { '' }
    if ($cand) {
        if ($cand.Contains('/') -or $cand.Contains('\') -or ($isWin -and $cand -match '^[A-Za-z]:')) {
            if (Test-Path -LiteralPath $cand -PathType Leaf) { return $cand }
            return ''
        }
        $names = if ($isWin -and $cand -notmatch '\.[A-Za-z0-9]+$') { @("$cand.exe", "$cand.com", "$cand.cmd", "$cand.bat", $cand) } else { @($cand) }
        foreach ($d in $pathDirs) {
            foreach ($n in $names) {
                $f = Join-Path $d $n
                if (Test-Path -LiteralPath $f -PathType Leaf) { return $f }
            }
        }
        return ''
    }
    $names = if ($isWin) { @('gh.exe', 'gh.com', 'gh.cmd', 'gh.bat', 'gh') } else { @('gh') }
    foreach ($d in $pathDirs) {
        foreach ($n in $names) {
            $f = Join-Path $d $n
            if (Test-Path -LiteralPath $f -PathType Leaf) { return $f }
        }
    }
    return ''
}

function Resolve-BashBinPath {
    if ($env:B3_BASH_BIN -and (Test-Path -LiteralPath $env:B3_BASH_BIN.Trim() -PathType Leaf)) { return $env:B3_BASH_BIN.Trim() }
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
            if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return $c }
        }
    }
    $bName = if ($isWin) { 'bash.exe' } else { 'bash' }
    foreach ($d in $pathDirs) {
        $f = Join-Path $d $bName
        if ($isWin) {
            $nb = $f -replace '/', '\'
            if ($nb -imatch '\\windows\\(system32|sysnative)\\bash\.exe$' -or $nb -imatch '\\microsoft\\windowsapps\\bash\.exe$') { continue }
        }
        if (Test-Path -LiteralPath $f -PathType Leaf) { return $f }
    }
    return ''
}

$ghBin = Resolve-GhBinPath
if (-not $ghBin) { Fail-GhUnavailable 'gh_cli_unavailable' }
$bashBin = if ($isWin -and $ghBin -notmatch '\.(exe|com|cmd|bat)$') { Resolve-BashBinPath } else { '' }
if ($isWin -and $ghBin -notmatch '\.(exe|com|cmd|bat)$' -and -not $bashBin) { Fail-GhUnavailable 'gh_cli_unavailable' }

$mjsPath = Join-Path $PSScriptRoot 'lib\b3-github-verify.mjs'
$nodeCmd = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($nodeCmd -and (Test-Path -LiteralPath $mjsPath -PathType Leaf)) {
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
        $psiN.Arguments = (($nodeArgs | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' } else { $_ } }) -join ' ')
    }
    $pN = [System.Diagnostics.Process]::Start($psiN)
    $oTask = $pN.StandardOutput.ReadToEndAsync()
    $eTask = $pN.StandardError.ReadToEndAsync()
    $pN.WaitForExit()
    $oTxt = $oTask.GetAwaiter().GetResult()
    [void]$eTask.GetAwaiter().GetResult()
    $ec = $pN.ExitCode
    $pN.Dispose()
    if ($oTxt) {
        foreach ($ln in ($oTxt.TrimEnd("`r", "`n") -split "\r?\n")) { Write-Output $ln }
    }
    exit $ec
}

# --- Compact Native PowerShell Fallback (when node is unavailable) ---
function Assert-SafeText([string]$Val, [string]$Field) {
    if ($null -ne $Val -and $Val -match '[\x00-\x1F\x7F]') { Fail-GhError "control_chars_in_response($Field)" }
    return $(if ($null -eq $Val) { '' } else { $Val })
}
function Get-Prop([object]$Obj, [string]$Name) {
    if ($null -eq $Obj) { return $null }
    $p = $Obj.PSObject.Properties[$Name]
    return $(if ($null -eq $p) { $null } else { $p.Value })
}
function Sort-Unique([string[]]$Items) {
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($it in @($Items)) { if (-not [string]::IsNullOrEmpty($it) -and $seen.Add($it)) { [void]$list.Add($it) } }
    $arr = $list.ToArray()
    [System.Array]::Sort($arr, [System.StringComparer]::Ordinal)
    return ,$arr
}
function Invoke-GhApi([string[]]$ApiArgs) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    if ($isWin -and $ghBin -match '\.(cmd|bat)$') {
        $psi.FileName = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
        $psi.EnvironmentVariables['B3_GH_CMD_EXE'] = ($ghBin -replace '"', '')
        $fullCmdArgs = @('api') + @($ApiArgs)
        $tokens = New-Object System.Collections.Generic.List[string]
        [void]$tokens.Add('"%B3_GH_CMD_EXE%"')
        for ($idx = 0; $idx -lt $fullCmdArgs.Count; $idx++) {
            $k = "B3_GH_CMD_$idx"
            $psi.EnvironmentVariables[$k] = ([string]$fullCmdArgs[$idx] -replace '"', '\"')
            [void]$tokens.Add("`"%$k%`"")
        }
        $inner = $tokens -join ' '
        $psi.Arguments = "/d /s /c `"$inner`""
    } else {
        $execFile = if ($isWin -and $ghBin -notmatch '\.(exe|com)$') { $bashBin } else { $ghBin }
        $execArgs = if ($isWin -and $ghBin -notmatch '\.(exe|com)$') { @('--', ($ghBin -replace '\\', '/'), 'api') + $ApiArgs } else { @('api') + $ApiArgs }
        $psi.FileName = $execFile
        if ($psi.PSObject.Properties['ArgumentList']) {
            foreach ($a in $execArgs) { [void]$psi.ArgumentList.Add($a) }
        } else {
            $psi.Arguments = (($execArgs | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' } else { $_ } }) -join ' ')
        }
    }
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Fail-GhUnavailable 'gh_cli_unavailable'
    }
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    $res = @{ ExitCode = $proc.ExitCode; StdOut = $outTask.GetAwaiter().GetResult(); StdErr = $errTask.GetAwaiter().GetResult() }
    $proc.Dispose()
    return $res
}
function Test-Http([hashtable]$Res, [int]$Code) {
    $t = "$($Res.StdErr)`n$($Res.StdOut)"
    return ($t -match "(?i)\bHTTP\s+$Code\b" -or $t -match "(?i)`"status`"\s*:\s*`"?$Code`"?")
}
function Fail-Api([hashtable]$Res, [string]$Label, [string]$NotFoundReason = '') {
    $t = "$($Res.StdErr)`n$($Res.StdOut)"
    if ($NotFoundReason -and (Test-Http $Res 404)) { Fail-GhError $NotFoundReason }
    if (Test-Http $Res 401) { Fail-GhUnavailable 'github_auth_failed' }
    if (Test-Http $Res 403) { Fail-GhUnavailable 'github_access_denied' }
    if (Test-Http $Res 429) { Fail-GhUnavailable 'github_rate_limited' }
    if ($t -match '(?i)\bHTTP\s+5\d\d\b' -or $t -match '(?i)"status"\s*:\s*"?5\d\d"?') { Fail-GhUnavailable 'github_http_5xx' }
    if ($t -match '(?i)not logged into|gh auth login|bad credentials|authentication|error connecting|dial tcp|i/o timeout|timed out|connection refused|connection reset|could not resolve|no such host|network is unreachable|tls handshake') {
        Fail-GhUnavailable 'github_network_or_auth_error'
    }
    if (Test-Http $Res 404) { Fail-GhError "${Label}_not_found" }
    Fail-GhError "${Label}_query_failed"
}
function Parse-JsonSafe([string]$Raw, [string]$Ctx) {
    $clean = if ($null -eq $Raw) { '' } else { $Raw -replace [string][char]0xFEFF, '' }
    if ([string]::IsNullOrWhiteSpace($clean)) { Fail-GhError "empty_json($Ctx)" }
    try { return ($clean | ConvertFrom-Json) } catch { Fail-GhError "invalid_json($Ctx)" }
}
function Flatten-Pages([object]$Parsed) {
    $out = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Parsed) { return @() }
    if ($Parsed -is [System.Array]) {
        foreach ($el in $Parsed) {
            if ($el -is [System.Array]) { foreach ($sub in $el) { if ($null -ne $sub) { [void]$out.Add($sub) } } }
            elseif ($null -ne $el) { [void]$out.Add($el) }
        }
    } else { [void]$out.Add($Parsed) }
    return ,($out.ToArray())
}

$prRes = Invoke-GhApi @("repos/$resolvedRepo/pulls/$prTrim")
if ($prRes.ExitCode -ne 0) { Fail-Api $prRes 'pr' 'pr_not_found' }
$prObj = Parse-JsonSafe $prRes.StdOut 'pull'
if ($null -eq (Get-Prop $prObj 'number') -or ([string](Get-Prop $prObj 'number')).Trim() -cne $prTrim) { Fail-GhError 'pr_number_mismatch' }

$baseObj = Get-Prop $prObj 'base'
$headObj = Get-Prop $prObj 'head'
$baseRepoObj = Get-Prop $baseObj 'repo'
$headRepoObj = Get-Prop $headObj 'repo'
$baseRepoFull = (Assert-SafeText ([string](Get-Prop $baseRepoObj 'full_name')) 'base_repo').Trim()
if (-not $baseRepoFull -or -not $baseRepoFull.Equals($resolvedRepo, [System.StringComparison]::OrdinalIgnoreCase)) { Fail-GhError 'cross_repo_mismatch' }
$defaultBranch = (Assert-SafeText ([string](Get-Prop $baseRepoObj 'default_branch')) 'default_branch').Trim()
if (-not $defaultBranch) { Fail-GhError 'missing_default_branch' }

$baseRef = (Assert-SafeText ([string](Get-Prop $baseObj 'ref')) 'base_ref').Trim()
$prBaseSha = (Assert-SafeText ([string](Get-Prop $baseObj 'sha')) 'pr_base_sha').Trim().ToLowerInvariant()
$headRef = (Assert-SafeText ([string](Get-Prop $headObj 'ref')) 'head_ref').Trim()
$headSha = (Assert-SafeText ([string](Get-Prop $headObj 'sha')) 'head_sha').Trim().ToLowerInvariant()
if (-not $baseRef -or $prBaseSha -cnotmatch '^[0-9a-f]{40}$' -or $headSha -cnotmatch '^[0-9a-f]{40}$') { Fail-GhError 'incomplete_pr_refs' }

$prStateRaw = (Assert-SafeText ([string](Get-Prop $prObj 'state')) 'pr_state').Trim().ToUpperInvariant()
if ($prStateRaw -cnotin @('OPEN', 'CLOSED')) { Fail-GhError "invalid_pr_state($prStateRaw)" }
$prMerged = ((Get-Prop $prObj 'merged') -is [bool] -and [bool](Get-Prop $prObj 'merged'))
$mAtRaw = Get-Prop $prObj 'merged_at'
$mergedAt = if ($mAtRaw -is [DateTime]) { $mAtRaw.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } elseif ($null -ne $mAtRaw -and ([string]$mAtRaw).Trim()) { (Assert-SafeText ([string]$mAtRaw) 'merged_at').Trim() } else { 'none' }
$mcRaw = Get-Prop $prObj 'merge_commit_sha'
$mergeCommitSha = if ($null -ne $mcRaw -and ([string]$mcRaw).Trim()) { (Assert-SafeText ([string]$mcRaw) 'merge_commit_sha').Trim().ToLowerInvariant() } else { 'none' }
if ($mergeCommitSha -cne 'none' -and $mergeCommitSha -cnotmatch '^[0-9a-f]{40}$') { Fail-GhError 'invalid_merge_commit_sha' }

if ($modeTrim -ceq 'post-merge') {
    $prCommits = if ($null -ne (Get-Prop $prObj 'commits')) { [int](Get-Prop $prObj 'commits') } else { 0 }
    $liveTargetSha = 'none'; $compareStatus = 'not_merged'; $compareBehind = -1
    $policyAuthorityRef = $defaultBranch; $policyAuthoritySha = 'none'
    if ($prMerged -and $mergeCommitSha -cmatch '^[0-9a-f]{40}$') {
        $encBase = [System.Uri]::EscapeDataString($baseRef)
        $brRes = Invoke-GhApi @("repos/$baseRepoFull/branches/$encBase")
        if ($brRes.ExitCode -ne 0) {
            if (Test-Http $brRes 404) { $compareStatus = 'target_branch_missing' } else { Fail-Api $brRes 'target_branch' }
        } else {
            $brObj = Parse-JsonSafe $brRes.StdOut 'target_branch'
            $ltSha = (Assert-SafeText ([string](Get-Prop (Get-Prop $brObj 'commit') 'sha')) 'live_target_sha').Trim().ToLowerInvariant()
            if ($ltSha -cnotmatch '^[0-9a-f]{40}$') { Fail-GhError 'invalid_live_target_sha' }
            $liveTargetSha = $ltSha
            $cmpRes = Invoke-GhApi @("repos/$baseRepoFull/compare/${mergeCommitSha}...${liveTargetSha}")
            if ($cmpRes.ExitCode -ne 0) { Fail-Api $cmpRes 'compare' }
            $cmpObj = Parse-JsonSafe $cmpRes.StdOut 'compare'
            $cStat = (Assert-SafeText ([string](Get-Prop $cmpObj 'status')) 'compare_status').Trim().ToLowerInvariant()
            if ($cStat -cnotin @('identical', 'ahead', 'behind', 'diverged')) { Fail-GhError "invalid_compare_status($cStat)" }
            $compareStatus = $cStat
            $compareBehind = if ($null -ne (Get-Prop $cmpObj 'behind_by')) { [int](Get-Prop $cmpObj 'behind_by') } else { -1 }
        }
        if ($defaultBranch -ceq $baseRef) {
            $policyAuthoritySha = $liveTargetSha
        } else {
            $encDef = [System.Uri]::EscapeDataString($defaultBranch)
            $defBrRes = Invoke-GhApi @("repos/$baseRepoFull/branches/$encDef")
            if ($defBrRes.ExitCode -ne 0) { Fail-Api $defBrRes 'policy_authority' }
            $defBrObj = Parse-JsonSafe $defBrRes.StdOut 'default_branch'
            $policyAuthoritySha = (Assert-SafeText ([string](Get-Prop (Get-Prop $defBrObj 'commit') 'sha')) 'policy_authority_sha').Trim().ToLowerInvariant()
            if ($policyAuthoritySha -cnotmatch '^[0-9a-f]{40}$') { Fail-GhError 'invalid_policy_authority_sha' }
        }
    }
    @('schema=b3-gh-verify-v2', 'mode=post-merge', "repo=$resolvedRepo", "pr_number=$prTrim", "base_repo=$baseRepoFull", "default_branch=$defaultBranch", "pr_state=$prStateRaw", ("pr_merged=" + $(if ($prMerged) { 'true' } else { 'false' })), "merged_at=$mergedAt", "merge_commit_sha=$mergeCommitSha", "base_ref=$baseRef", "head_sha=$headSha", "pr_commits=$prCommits", "live_target_sha=$liveTargetSha", "policy_authority_ref=$policyAuthorityRef", "policy_authority_sha=$policyAuthoritySha", "compare_status=$compareStatus", "compare_behind_by=$compareBehind") | ForEach-Object { Write-Output $_ }
    exit 0
}

$headRepoFull = if ($null -ne $headRepoObj -and (Get-Prop $headRepoObj 'full_name')) { (Assert-SafeText ([string](Get-Prop $headRepoObj 'full_name')) 'head_repo').Trim() } else { 'none' }
$sameRepo = ($headRepoFull -cne 'none' -and $headRepoFull.Equals($baseRepoFull, [System.StringComparison]::OrdinalIgnoreCase))
$prDraft = ((Get-Prop $prObj 'draft') -is [bool] -and [bool](Get-Prop $prObj 'draft'))
$mVal = Get-Prop $prObj 'mergeable'
$mergeableStr = if ($mVal -is [bool]) { if ($mVal) { 'true' } else { 'false' } } else { 'unknown' }
$msRaw = Get-Prop $prObj 'mergeable_state'
$mergeableState = if ($null -ne $msRaw -and ([string]$msRaw).Trim()) { (Assert-SafeText ([string]$msRaw) 'mergeable_state').Trim().ToLowerInvariant() } else { 'unknown' }

$encBaseRef = [System.Uri]::EscapeDataString($baseRef)
$baseBrRes = Invoke-GhApi @("repos/$baseRepoFull/branches/$encBaseRef")
if ($baseBrRes.ExitCode -ne 0) { Fail-Api $baseBrRes 'target_branch' }
$baseBrObj = Parse-JsonSafe $baseBrRes.StdOut 'target_branch'
$liveTargetSha = (Assert-SafeText ([string](Get-Prop (Get-Prop $baseBrObj 'commit') 'sha')) 'live_target_sha').Trim().ToLowerInvariant()
if ($liveTargetSha -cnotmatch '^[0-9a-f]{40}$') { Fail-GhError 'invalid_live_target_sha' }

$policyAuthorityRef = $defaultBranch
$policyAuthoritySha = $liveTargetSha
if ($defaultBranch -cne $baseRef) {
    $encDef = [System.Uri]::EscapeDataString($defaultBranch)
    $defBrRes = Invoke-GhApi @("repos/$baseRepoFull/branches/$encDef")
    if ($defBrRes.ExitCode -ne 0) { Fail-Api $defBrRes 'policy_authority' }
    $defBrObj = Parse-JsonSafe $defBrRes.StdOut 'default_branch'
    $policyAuthoritySha = (Assert-SafeText ([string](Get-Prop (Get-Prop $defBrObj 'commit') 'sha')) 'policy_authority_sha').Trim().ToLowerInvariant()
    if ($policyAuthoritySha -cnotmatch '^[0-9a-f]{40}$') { Fail-GhError 'invalid_policy_authority_sha' }
}

$filesRes = Invoke-GhApi @('--paginate', '--slurp', "repos/$baseRepoFull/pulls/$prTrim/files?per_page=100")
if ($filesRes.ExitCode -ne 0) { Fail-Api $filesRes 'pr_files' }
$prChangedList = New-Object System.Collections.Generic.List[string]
foreach ($fi in (Flatten-Pages (Parse-JsonSafe $filesRes.StdOut 'pr_files'))) {
    $fn = Get-Prop $fi 'filename'
    if ($fn -is [string] -and $fn.Trim()) { [void]$prChangedList.Add((Assert-SafeText ($fn.Trim() -replace '\\', '/') 'pr_file')) }
    $pfn = Get-Prop $fi 'previous_filename'
    if ($pfn -is [string] -and $pfn.Trim()) { [void]$prChangedList.Add((Assert-SafeText ($pfn.Trim() -replace '\\', '/') 'pr_prev_file')) }
}
$prChangedSorted = Sort-Unique ($prChangedList.ToArray())

$crRes = Invoke-GhApi @('--paginate', '--slurp', "repos/$baseRepoFull/commits/$headSha/check-runs?per_page=100")
if ($crRes.ExitCode -ne 0) { Fail-Api $crRes 'check_runs' }
$crRaw = Parse-JsonSafe $crRes.StdOut 'check_runs'
$crPages = if ($crRaw -is [System.Array]) { $crRaw } else { @($crRaw) }
$latestChecks = New-Object 'System.Collections.Generic.Dictionary[string,hashtable]' ([System.StringComparer]::Ordinal)
foreach ($pg in $crPages) {
    if ($null -eq $pg) { continue }
    foreach ($run in @(Get-Prop $pg 'check_runs')) {
        if ($null -eq $run) { continue }
        $rSha = [string](Get-Prop $run 'head_sha')
        if ($rSha -and $rSha.Trim().ToLowerInvariant() -cne $headSha) { Fail-GhError 'check_run_sha_mismatch' }
        $cName = (Assert-SafeText ([string](Get-Prop $run 'name')) 'check_name').Trim()
        if (-not $cName) { continue }
        $appObj = Get-Prop $run 'app'
        $appId = if ($null -ne $appObj -and $null -ne (Get-Prop $appObj 'id')) { [string](Get-Prop $appObj 'id') } else { '0' }
        $cKey = "$appId`0$cName"
        $cId = if ($null -ne (Get-Prop $run 'id')) { [int64](Get-Prop $run 'id') } else { [int64]0 }
        $cSt = (Assert-SafeText ([string](Get-Prop $run 'status')) 'check_status').Trim().ToLowerInvariant()
        $cConc = if ($null -ne (Get-Prop $run 'conclusion')) { (Assert-SafeText ([string](Get-Prop $run 'conclusion')) 'check_conclusion').Trim().ToLowerInvariant() } else { '' }
        if (-not $latestChecks.ContainsKey($cKey) -or $cId -ge $latestChecks[$cKey].Id) {
            $latestChecks[$cKey] = @{ Id = $cId; Status = $cSt; Conclusion = $cConc }
        }
    }
}

$stRes = Invoke-GhApi @('--paginate', '--slurp', "repos/$baseRepoFull/commits/$headSha/status?per_page=100")
if ($stRes.ExitCode -ne 0) { Fail-Api $stRes 'commit_status' }
$stRaw = Parse-JsonSafe $stRes.StdOut 'commit_status'
$stPages = if ($stRaw -is [System.Array]) { $stRaw } else { @($stRaw) }
$latestStatuses = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)
$combFailed = $false; $combPending = $false
foreach ($stObj in $stPages) {
    if ($null -eq $stObj) { continue }
    $stSha = [string](Get-Prop $stObj 'sha')
    if ($stSha -and $stSha.Trim().ToLowerInvariant() -cne $headSha) { Fail-GhError 'commit_status_sha_mismatch' }
    $stTot = if ($null -ne (Get-Prop $stObj 'total_count')) { [int](Get-Prop $stObj 'total_count') } else { 0 }
    $stTop = (Assert-SafeText ([string](Get-Prop $stObj 'state')) 'status_top_state').Trim().ToLowerInvariant()
    if ($stTot -gt 0) {
        if ($stTop -cin @('failure', 'error')) { $combFailed = $true } elseif ($stTop -ceq 'pending') { $combPending = $true }
    }
    foreach ($stItem in @(Get-Prop $stObj 'statuses')) {
        if ($null -eq $stItem) { continue }
        $ctx = (Assert-SafeText ([string](Get-Prop $stItem 'context')) 'status_context').Trim()
        if ($ctx -and -not $latestStatuses.ContainsKey($ctx)) {
            $latestStatuses[$ctx] = (Assert-SafeText ([string](Get-Prop $stItem 'state')) 'status_state').Trim().ToLowerInvariant()
        }
    }
}

$hasFailed = $combFailed; $hasPending = $false; $totSeen = 0; $succCnt = 0
foreach ($c in $latestChecks.Values) {
    $totSeen++
    if ($c.Status -cne 'completed') { $hasPending = $true }
    elseif ($c.Conclusion -ceq 'success') { $succCnt++ }
    elseif ($c.Conclusion -cnotin @('neutral', 'skipped')) { $hasFailed = $true }
}
foreach ($sVal in $latestStatuses.Values) {
    $totSeen++
    if ($sVal -ceq 'success') { $succCnt++ }
    elseif ($sVal -ceq 'pending') { $hasPending = $true }
    else { $hasFailed = $true }
}
if ($combPending -and $latestStatuses.Count -eq 0) { $hasPending = $true }
$ghCiStatus = if ($hasFailed) { 'FAIL' } elseif ($hasPending) { 'PENDING' } elseif ($totSeen -eq 0 -or $succCnt -eq 0) { 'UNKNOWN' } else { 'PASS' }

@('schema=b3-gh-verify-v2', 'mode=pre-merge', "repo=$resolvedRepo", "pr_number=$prTrim", "base_repo=$baseRepoFull", "head_repo=$headRepoFull", ("same_repo=" + $(if ($sameRepo) { 'true' } else { 'false' })), "default_branch=$defaultBranch", "pr_state=$prStateRaw", ("pr_merged=" + $(if ($prMerged) { 'true' } else { 'false' })), ("pr_draft=" + $(if ($prDraft) { 'true' } else { 'false' })), "base_ref=$baseRef", "pr_base_sha=$prBaseSha", "live_target_sha=$liveTargetSha", "head_ref=$headRef", "head_sha=$headSha", "policy_authority_ref=$policyAuthorityRef", "policy_authority_sha=$policyAuthoritySha", "mergeable=$mergeableStr", "mergeable_state=$mergeableState", "gh_ci_status=$ghCiStatus") | ForEach-Object { Write-Output $_ }
foreach ($cf in $prChangedSorted) { Write-Output "pr_changed_file=$cf" }
exit 0
