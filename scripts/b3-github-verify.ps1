param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('pre-merge', 'post-merge')]
    [string]$Mode,
    [Parameter(Mandatory = $true)]
    [string]$Repo,
    [Parameter(Mandatory = $true)]
    [string]$PrNumber
)

$ErrorActionPreference = 'Stop'

function Fail-GhVerify([string]$Reason) {
    Write-Output "GH_VERIFY_ERROR: $Reason"
    exit 1
}

function Test-Ctrl([string]$Val) {
    if ($null -eq $Val) { return $false }
    return ($Val -match '[\x00-\x1F\x7F]')
}

function Assert-SafeText([string]$Val, [string]$Field) {
    if (Test-Ctrl $Val) {
        Fail-GhVerify "control_chars_in_response($Field)"
    }
    return $Val
}

function Get-PropValue([object]$Obj, [string]$Name) {
    if ($null -eq $Obj) { return $null }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Sort-OrdinalUnique([string[]]$Items) {
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($it in @($Items)) {
        if (-not [string]::IsNullOrEmpty($it) -and $seen.Add($it)) {
            [void]$list.Add($it)
        }
    }
    $arr = $list.ToArray()
    [System.Array]::Sort($arr, [System.StringComparer]::Ordinal)
    return ,$arr
}

$repoTrim = if ($Repo) { $Repo.Trim() } else { '' }
if ($repoTrim -cnotmatch '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' -or $repoTrim.Contains('..')) {
    Fail-GhVerify 'invalid_repo'
}

$prTrim = if ($PrNumber) { $PrNumber.Trim() } else { '' }
if ($prTrim -cnotmatch '^[1-9][0-9]*$') {
    Fail-GhVerify 'invalid_pr_number'
}

$ghCmd = Get-Command gh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $ghCmd) {
    Fail-GhVerify 'gh_cli_unavailable'
}

function Invoke-GhApi([string[]]$ApiArgs) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ghCmd.Source
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $allArgs = @('api') + $ApiArgs
    if ($psi.PSObject.Properties['ArgumentList']) {
        foreach ($a in $allArgs) { [void]$psi.ArgumentList.Add($a) }
    } else {
        $escaped = @()
        foreach ($a in $allArgs) {
            if ($a -match '[\s"]') {
                $escaped += ('"' + ($a -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"')
            } else {
                $escaped += $a
            }
        }
        $psi.Arguments = ($escaped -join ' ')
    }
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    $stdout = $outTask.GetAwaiter().GetResult()
    $stderr = $errTask.GetAwaiter().GetResult()
    return @{
        ExitCode = $proc.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
    }
}

function ConvertFrom-JsonSafe([string]$Raw, [string]$Context) {
    if ([string]::IsNullOrWhiteSpace($Raw)) {
        Fail-GhVerify "empty_json($Context)"
    }
    try {
        return ($Raw | ConvertFrom-Json)
    } catch {
        Fail-GhVerify "invalid_json($Context)"
    }
}

function Test-HttpStatus([hashtable]$Res, [int]$Code) {
    $combined = "$($Res.StdErr)`n$($Res.StdOut)"
    return ($combined -match "(?i)\bHTTP\s+$Code\b" -or $combined -match "(?i)`"status`"\s*:\s*`"$Code`"")
}

function Flatten-PaginatedArray([object]$Parsed) {
    $out = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Parsed) { return @() }
    if ($Parsed -is [System.Array]) {
        foreach ($el in $Parsed) {
            if ($el -is [System.Array]) {
                foreach ($sub in $el) {
                    if ($null -ne $sub) { [void]$out.Add($sub) }
                }
            } elseif ($null -ne $el) {
                [void]$out.Add($el)
            }
        }
    } else {
        [void]$out.Add($Parsed)
    }
    return ,($out.ToArray())
}

function Encode-BranchName([string]$Branch) {
    return [System.Uri]::EscapeDataString($Branch)
}

# 1. Fetch authoritative PR metadata
$prRes = Invoke-GhApi @("repos/$repoTrim/pulls/$prTrim")
if ($prRes.ExitCode -ne 0) {
    if (Test-HttpStatus $prRes 404) { Fail-GhVerify 'pr_not_found' }
    if (Test-HttpStatus $prRes 401) { Fail-GhVerify 'github_auth_failed' }
    if (Test-HttpStatus $prRes 403) { Fail-GhVerify 'github_access_denied' }
    Fail-GhVerify 'pr_query_failed'
}
$prObj = ConvertFrom-JsonSafe $prRes.StdOut 'pull'

$retNum = Get-PropValue $prObj 'number'
if ($null -eq $retNum -or ([string]$retNum).Trim() -cne $prTrim) {
    Fail-GhVerify 'pr_number_mismatch'
}

$baseObj = Get-PropValue $prObj 'base'
$headObj = Get-PropValue $prObj 'head'
$baseRepoObj = Get-PropValue $baseObj 'repo'
$headRepoObj = Get-PropValue $headObj 'repo'
$userObj = Get-PropValue $prObj 'user'

$baseRepoFull = Assert-SafeText ([string](Get-PropValue $baseRepoObj 'full_name')).Trim() 'base_repo'
if (-not $baseRepoFull -or -not $baseRepoFull.Equals($repoTrim, [System.StringComparison]::OrdinalIgnoreCase)) {
    Fail-GhVerify 'cross_repo_mismatch'
}
$defaultBranch = Assert-SafeText ([string](Get-PropValue $baseRepoObj 'default_branch')).Trim() 'default_branch'
if (-not $defaultBranch) { Fail-GhVerify 'missing_default_branch' }

$baseRef = Assert-SafeText ([string](Get-PropValue $baseObj 'ref')).Trim() 'base_ref'
$prBaseSha = Assert-SafeText ([string](Get-PropValue $baseObj 'sha')).Trim().ToLowerInvariant() 'pr_base_sha'
$headRef = Assert-SafeText ([string](Get-PropValue $headObj 'ref')).Trim() 'head_ref'
$headSha = Assert-SafeText ([string](Get-PropValue $headObj 'sha')).Trim().ToLowerInvariant() 'head_sha'
if (-not $baseRef -or $prBaseSha -cnotmatch '^[0-9a-f]{40}$' -or $headSha -cnotmatch '^[0-9a-f]{40}$') {
    Fail-GhVerify 'incomplete_pr_refs'
}

$prStateRaw = Assert-SafeText ([string](Get-PropValue $prObj 'state')).Trim().ToUpperInvariant() 'pr_state'
if ($prStateRaw -cnotin @('OPEN', 'CLOSED')) { Fail-GhVerify "invalid_pr_state($prStateRaw)" }

$prMergedVal = Get-PropValue $prObj 'merged'
$prMerged = ($prMergedVal -is [bool] -and $prMergedVal)
$mergedAtRaw = Get-PropValue $prObj 'merged_at'
$mergedAt = if ($mergedAtRaw -is [DateTime]) {
    $mergedAtRaw.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
} elseif ($null -ne $mergedAtRaw -and ([string]$mergedAtRaw).Trim()) {
    Assert-SafeText ([string]$mergedAtRaw).Trim() 'merged_at'
} else {
    'none'
}
$mergeCommitRaw = Get-PropValue $prObj 'merge_commit_sha'
$mergeCommitSha = if ($null -ne $mergeCommitRaw -and ([string]$mergeCommitRaw).Trim()) { Assert-SafeText ([string]$mergeCommitRaw).Trim().ToLowerInvariant() 'merge_commit_sha' } else { 'none' }
if ($mergeCommitSha -cne 'none' -and $mergeCommitSha -cnotmatch '^[0-9a-f]{40}$') {
    Fail-GhVerify 'invalid_merge_commit_sha'
}

if ($Mode -ceq 'post-merge') {
    $prCommitsVal = Get-PropValue $prObj 'commits'
    $prCommits = if ($null -ne $prCommitsVal) { [int]$prCommitsVal } else { 0 }
    $liveTargetSha = 'none'
    $compareStatus = 'not_merged'
    $compareBehind = -1

    if ($prMerged -and $mergeCommitSha -cmatch '^[0-9a-f]{40}$') {
        $encBase = Encode-BranchName $baseRef
        $brRes = Invoke-GhApi @("repos/$baseRepoFull/branches/$encBase")
        if ($brRes.ExitCode -ne 0) {
            if (Test-HttpStatus $brRes 404) {
                $compareStatus = 'target_branch_missing'
            } else {
                Fail-GhVerify 'target_branch_query_failed'
            }
        } else {
            $brObj = ConvertFrom-JsonSafe $brRes.StdOut 'target_branch'
            $brCommit = Get-PropValue $brObj 'commit'
            $ltSha = Assert-SafeText ([string](Get-PropValue $brCommit 'sha')).Trim().ToLowerInvariant() 'live_target_sha'
            if ($ltSha -cnotmatch '^[0-9a-f]{40}$') { Fail-GhVerify 'invalid_live_target_sha' }
            $liveTargetSha = $ltSha

            $cmpRes = Invoke-GhApi @("repos/$baseRepoFull/compare/${mergeCommitSha}...${liveTargetSha}")
            if ($cmpRes.ExitCode -ne 0) {
                Fail-GhVerify 'compare_query_failed'
            }
            $cmpObj = ConvertFrom-JsonSafe $cmpRes.StdOut 'compare'
            $cStat = Assert-SafeText ([string](Get-PropValue $cmpObj 'status')).Trim().ToLowerInvariant() 'compare_status'
            if ($cStat -cnotin @('identical', 'ahead', 'behind', 'diverged')) {
                Fail-GhVerify "invalid_compare_status($cStat)"
            }
            $compareStatus = $cStat
            $cbVal = Get-PropValue $cmpObj 'behind_by'
            $compareBehind = if ($null -ne $cbVal) { [int]$cbVal } else { -1 }
        }
    }

    Write-Output 'schema=b3-gh-verify-v1'
    Write-Output 'mode=post-merge'
    Write-Output "repo=$repoTrim"
    Write-Output "pr_number=$prTrim"
    Write-Output "base_repo=$baseRepoFull"
    Write-Output "default_branch=$defaultBranch"
    Write-Output "pr_state=$prStateRaw"
    Write-Output ("pr_merged=" + $(if ($prMerged) { 'true' } else { 'false' }))
    Write-Output "merged_at=$mergedAt"
    Write-Output "merge_commit_sha=$mergeCommitSha"
    Write-Output "base_ref=$baseRef"
    Write-Output "head_sha=$headSha"
    Write-Output "pr_commits=$prCommits"
    Write-Output "live_target_sha=$liveTargetSha"
    Write-Output "compare_status=$compareStatus"
    Write-Output "compare_behind_by=$compareBehind"
    exit 0
}

# --- pre-merge mode ---
$headRepoFull = if ($null -ne $headRepoObj -and (Get-PropValue $headRepoObj 'full_name')) {
    Assert-SafeText ([string](Get-PropValue $headRepoObj 'full_name')).Trim() 'head_repo'
} else {
    'none'
}
$sameRepo = ($headRepoFull -cne 'none' -and $headRepoFull.Equals($baseRepoFull, [System.StringComparison]::OrdinalIgnoreCase))

$prDraftVal = Get-PropValue $prObj 'draft'
$prDraft = ($prDraftVal -is [bool] -and $prDraftVal)
$prAuthor = Assert-SafeText ([string](Get-PropValue $userObj 'login')).Trim() 'pr_author'
if (-not $prAuthor) { Fail-GhVerify 'missing_pr_author' }

$mergeableRaw = Get-PropValue $prObj 'mergeable'
$mergeableStr = if ($mergeableRaw -is [bool]) { if ($mergeableRaw) { 'true' } else { 'false' } } else { 'unknown' }
$mergeableStateRaw = Get-PropValue $prObj 'mergeable_state'
$mergeableState = if ($null -ne $mergeableStateRaw -and ([string]$mergeableStateRaw).Trim()) {
    Assert-SafeText ([string]$mergeableStateRaw).Trim().ToLowerInvariant() 'mergeable_state'
} else {
    'unknown'
}

# 2. Live PR target branch metadata & classic protection summary
$encBaseRef = Encode-BranchName $baseRef
$baseBrRes = Invoke-GhApi @("repos/$baseRepoFull/branches/$encBaseRef")
if ($baseBrRes.ExitCode -ne 0) {
    Fail-GhVerify 'target_branch_query_failed'
}
$baseBrObj = ConvertFrom-JsonSafe $baseBrRes.StdOut 'target_branch'
$liveTargetSha = Assert-SafeText ([string](Get-PropValue (Get-PropValue $baseBrObj 'commit') 'sha')).Trim().ToLowerInvariant() 'live_target_sha'
if ($liveTargetSha -cnotmatch '^[0-9a-f]{40}$') { Fail-GhVerify 'invalid_live_target_sha' }
$brProtVal = Get-PropValue $baseBrObj 'protected'
$branchProtected = ($brProtVal -is [bool] -and $brProtVal)

$reqChecksList = New-Object System.Collections.Generic.List[string]
$reqReviewsCount = 0
$reqCodeowners = $false

$brProtObj = Get-PropValue $baseBrObj 'protection'
if ($null -ne $brProtObj) {
    $rscObj = Get-PropValue $brProtObj 'required_status_checks'
    if ($null -ne $rscObj) {
        foreach ($ctx in @(Get-PropValue $rscObj 'contexts')) {
            if ($ctx -is [string] -and $ctx.Trim()) {
                [void]$reqChecksList.Add((Assert-SafeText $ctx.Trim() 'required_check'))
            }
        }
        foreach ($chkItem in @(Get-PropValue $rscObj 'checks')) {
            $cName = Get-PropValue $chkItem 'context'
            if ($cName -is [string] -and $cName.Trim()) {
                [void]$reqChecksList.Add((Assert-SafeText $cName.Trim() 'required_check'))
            }
        }
    }
}

# 3. Policy authority branch (repository default_branch)
$policyAuthorityRef = $defaultBranch
if ($defaultBranch -ceq $baseRef) {
    $policyAuthoritySha = $liveTargetSha
} else {
    $encDef = Encode-BranchName $defaultBranch
    $defBrRes = Invoke-GhApi @("repos/$baseRepoFull/branches/$encDef")
    if ($defBrRes.ExitCode -ne 0) {
        Fail-GhVerify 'policy_authority_query_failed'
    }
    $defBrObj = ConvertFrom-JsonSafe $defBrRes.StdOut 'default_branch'
    $policyAuthoritySha = Assert-SafeText ([string](Get-PropValue (Get-PropValue $defBrObj 'commit') 'sha')).Trim().ToLowerInvariant() 'policy_authority_sha'
    if ($policyAuthoritySha -cnotmatch '^[0-9a-f]{40}$') { Fail-GhVerify 'invalid_policy_authority_sha' }
}

# 4. Branch rulesets & classic protection details
$rulesRes = Invoke-GhApi @('--paginate', '--slurp', "repos/$baseRepoFull/rules/branches/$encBaseRef?per_page=100")
if ($rulesRes.ExitCode -eq 0) {
    $rulesObj = Flatten-PaginatedArray (ConvertFrom-JsonSafe $rulesRes.StdOut 'branch_rules')
    foreach ($r in $rulesObj) {
        if ($null -eq $r) { continue }
        $rType = [string](Get-PropValue $r 'type')
        $rParams = Get-PropValue $r 'parameters'
        if ($rType -ceq 'pull_request' -and $null -ne $rParams) {
            $cnt = Get-PropValue $rParams 'required_approving_review_count'
            if ($null -ne $cnt -and ([int]$cnt) -gt $reqReviewsCount) { $reqReviewsCount = [int]$cnt }
            $co = Get-PropValue $rParams 'require_code_owner_review'
            if ($co -is [bool] -and $co) { $reqCodeowners = $true }
        } elseif ($rType -ceq 'required_status_checks' -and $null -ne $rParams) {
            foreach ($rc in @(Get-PropValue $rParams 'required_status_checks')) {
                $rcCtx = Get-PropValue $rc 'context'
                if ($rcCtx -is [string] -and $rcCtx.Trim()) {
                    [void]$reqChecksList.Add((Assert-SafeText $rcCtx.Trim() 'ruleset_check'))
                }
            }
        }
    }
} elseif (-not (Test-HttpStatus $rulesRes 404) -and -not (Test-HttpStatus $rulesRes 403)) {
    Fail-GhVerify 'branch_rules_unavailable'
}

$branchProtectionReadable = $true
if ($branchProtected) {
    $protRes = Invoke-GhApi @("repos/$baseRepoFull/branches/$encBaseRef/protection")
    if ($protRes.ExitCode -eq 0) {
        $protObj = ConvertFrom-JsonSafe $protRes.StdOut 'branch_protection'
        $pRsc = Get-PropValue $protObj 'required_status_checks'
        if ($null -ne $pRsc) {
            foreach ($ctx in @(Get-PropValue $pRsc 'contexts')) {
                if ($ctx -is [string] -and $ctx.Trim()) {
                    [void]$reqChecksList.Add((Assert-SafeText $ctx.Trim() 'prot_check'))
                }
            }
            foreach ($chkItem in @(Get-PropValue $pRsc 'checks')) {
                $cName = Get-PropValue $chkItem 'context'
                if ($cName -is [string] -and $cName.Trim()) {
                    [void]$reqChecksList.Add((Assert-SafeText $cName.Trim() 'prot_check'))
                }
            }
        }
        $pRev = Get-PropValue $protObj 'required_pull_request_reviews'
        if ($null -ne $pRev) {
            $cnt = Get-PropValue $pRev 'required_approving_review_count'
            if ($null -ne $cnt -and ([int]$cnt) -gt $reqReviewsCount) { $reqReviewsCount = [int]$cnt }
            $co = Get-PropValue $pRev 'require_code_owner_reviews'
            if ($co -is [bool] -and $co) { $reqCodeowners = $true }
        }
    } elseif ((Test-HttpStatus $protRes 403) -or (Test-HttpStatus $protRes 404)) {
        $branchProtectionReadable = $false
    } else {
        Fail-GhVerify 'branch_protection_unavailable'
    }
}

$reqChecksArr = Sort-OrdinalUnique ($reqChecksList.ToArray())

# 5. PR Changed files
$filesRes = Invoke-GhApi @('--paginate', '--slurp', "repos/$baseRepoFull/pulls/$prTrim/files?per_page=100")
if ($filesRes.ExitCode -ne 0) {
    Fail-GhVerify 'pr_files_query_failed'
}
$filesRaw = ConvertFrom-JsonSafe $filesRes.StdOut 'pr_files'
$fileItems = Flatten-PaginatedArray $filesRaw
$prChangedList = New-Object System.Collections.Generic.List[string]
foreach ($fi in $fileItems) {
    $fn = Get-PropValue $fi 'filename'
    if ($fn -is [string] -and $fn.Trim()) {
        [void]$prChangedList.Add((Assert-SafeText ($fn.Trim() -replace '\\', '/') 'pr_file'))
    }
    $pfn = Get-PropValue $fi 'previous_filename'
    if ($pfn -is [string] -and $pfn.Trim()) {
        [void]$prChangedList.Add((Assert-SafeText ($pfn.Trim() -replace '\\', '/') 'pr_prev_file'))
    }
}
$prChangedSorted = Sort-OrdinalUnique ($prChangedList.ToArray())

# 6. PR Reviews (bound strictly to exact head_sha, non-author, non-bot, repo authority)
$revRes = Invoke-GhApi @('--paginate', '--slurp', "repos/$baseRepoFull/pulls/$prTrim/reviews?per_page=100")
if ($revRes.ExitCode -ne 0) {
    Fail-GhVerify 'pr_reviews_query_failed'
}
$revRaw = ConvertFrom-JsonSafe $revRes.StdOut 'pr_reviews'
$revItems = Flatten-PaginatedArray $revRaw

$latestByReviewer = New-Object 'System.Collections.Generic.Dictionary[string,hashtable]' ([System.StringComparer]::Ordinal)
foreach ($rv in $revItems) {
    $rvState = ([string](Get-PropValue $rv 'state')).Trim().ToUpperInvariant()
    if ($rvState -cnotin @('APPROVED', 'CHANGES_REQUESTED', 'DISMISSED')) { continue }
    $rvUser = Get-PropValue $rv 'user'
    $rvLoginRaw = [string](Get-PropValue $rvUser 'login')
    $rvLogin = Assert-SafeText $rvLoginRaw.Trim() 'review_user'
    if (-not $rvLogin) { continue }
    $rvUserType = Assert-SafeText ([string](Get-PropValue $rvUser 'type')).Trim() 'review_user_type'
    $rvAssoc = Assert-SafeText ([string](Get-PropValue $rv 'author_association')).Trim().ToUpperInvariant() 'review_author_association'
    $rvCommitRaw = [string](Get-PropValue $rv 'commit_id')
    $rvCommit = if ($rvCommitRaw) { Assert-SafeText $rvCommitRaw.Trim().ToLowerInvariant() 'review_commit' } else { '' }
    $key = $rvLogin.ToLowerInvariant()
    $latestByReviewer[$key] = @{
        Login       = $rvLogin
        State       = $rvState
        Commit      = $rvCommit
        UserType    = $rvUserType
        Association = $rvAssoc
    }
}

$authorLower = $prAuthor.ToLowerInvariant()
$changesReqCnt = 0
$selfApprovedCnt = 0
$unauthApprovedCnt = 0
$staleIndepCnt = 0
$indepReviewersList = New-Object System.Collections.Generic.List[string]
foreach ($kv in $latestByReviewer.GetEnumerator()) {
    $rec = $kv.Value
    if ($rec.State -ceq 'CHANGES_REQUESTED') {
        $changesReqCnt++
    } elseif ($rec.State -ceq 'APPROVED') {
        if ($kv.Key -ceq $authorLower) {
            if ($rec.Commit -ceq $headSha) { $selfApprovedCnt++ }
        } elseif ($rec.UserType -cne 'User' -or $rec.Association -cnotin @('OWNER', 'MEMBER', 'COLLABORATOR')) {
            if ($rec.Commit -ceq $headSha) { $unauthApprovedCnt++ }
        } else {
            if ($rec.Commit -ceq $headSha) {
                [void]$indepReviewersList.Add($rec.Login)
            } else {
                $staleIndepCnt++
            }
        }
    }
}
$indepReviewersArr = Sort-OrdinalUnique ($indepReviewersList.ToArray())
$indepApprovedCnt = $indepReviewersArr.Count

$ghReviewStatus = 'PENDING'
if ($changesReqCnt -gt 0) {
    $ghReviewStatus = 'BLOCKED'
} elseif ($indepApprovedCnt -gt 0 -and $indepApprovedCnt -ge $reqReviewsCount) {
    $ghReviewStatus = 'PASS'
} elseif ($indepApprovedCnt -eq 0 -and $selfApprovedCnt -gt 0) {
    $ghReviewStatus = 'SELF_REVIEW_ONLY'
} elseif ($indepApprovedCnt -eq 0 -and $unauthApprovedCnt -gt 0) {
    $ghReviewStatus = 'UNAUTHORIZED_ONLY'
} elseif ($indepApprovedCnt -eq 0 -and $staleIndepCnt -gt 0) {
    $ghReviewStatus = 'STALE'
}

# 7. CI check-runs + commit statuses on exact head_sha
$crRes = Invoke-GhApi @('--paginate', '--slurp', "repos/$baseRepoFull/commits/$headSha/check-runs?per_page=100")
if ($crRes.ExitCode -ne 0) {
    Fail-GhVerify 'check_runs_query_failed'
}
$crRaw = ConvertFrom-JsonSafe $crRes.StdOut 'check_runs'
$crPages = if ($crRaw -is [System.Array]) { $crRaw } else { @($crRaw) }

$latestChecks = New-Object 'System.Collections.Generic.Dictionary[string,hashtable]' ([System.StringComparer]::Ordinal)
foreach ($pg in $crPages) {
    if ($null -eq $pg) { continue }
    $runs = Get-PropValue $pg 'check_runs'
    if ($null -eq $runs) { continue }
    foreach ($run in @($runs)) {
        if ($null -eq $run) { continue }
        $runSha = [string](Get-PropValue $run 'head_sha')
        if ($runSha -and $runSha.Trim().ToLowerInvariant() -cne $headSha) {
            Fail-GhVerify 'check_run_sha_mismatch'
        }
        $cName = Assert-SafeText ([string](Get-PropValue $run 'name')).Trim() 'check_name'
        if (-not $cName) { continue }
        $cApp = Get-PropValue $run 'app'
        $cAppIdVal = if ($null -ne $cApp) { Get-PropValue $cApp 'id' } else { $null }
        $cAppId = if ($null -ne $cAppIdVal) { [string]$cAppIdVal } else { '0' }
        $cKey = "$cAppId`0$cName"
        $cIdVal = Get-PropValue $run 'id'
        $cId = if ($null -ne $cIdVal) { [int64]$cIdVal } else { [int64]0 }
        $cStatus = ([string](Get-PropValue $run 'status')).Trim().ToLowerInvariant()
        $cConcRaw = Get-PropValue $run 'conclusion'
        $cConc = if ($null -ne $cConcRaw) { ([string]$cConcRaw).Trim().ToLowerInvariant() } else { '' }
        if (-not $latestChecks.ContainsKey($cKey) -or $cId -ge $latestChecks[$cKey].Id) {
            $latestChecks[$cKey] = @{ Name = $cName; Id = $cId; Status = $cStatus; Conclusion = $cConc }
        }
    }
}

$stRes = Invoke-GhApi @('--paginate', '--slurp', "repos/$baseRepoFull/commits/$headSha/status?per_page=100")
if ($stRes.ExitCode -ne 0) {
    Fail-GhVerify 'commit_status_query_failed'
}
$stRaw = ConvertFrom-JsonSafe $stRes.StdOut 'commit_status'
$stPages = if ($stRaw -is [System.Array]) { $stRaw } else { @($stRaw) }
$latestStatuses = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)
$combinedStatusFailed = $false
$combinedStatusPending = $false
foreach ($stObj in $stPages) {
    if ($null -eq $stObj) { continue }
    $stSha = [string](Get-PropValue $stObj 'sha')
    if ($stSha -and $stSha.Trim().ToLowerInvariant() -cne $headSha) {
        Fail-GhVerify 'commit_status_sha_mismatch'
    }
    $stTotalVal = Get-PropValue $stObj 'total_count'
    $stTotal = if ($null -ne $stTotalVal) { [int]$stTotalVal } else { 0 }
    $stTopState = ([string](Get-PropValue $stObj 'state')).Trim().ToLowerInvariant()
    if ($stTotal -gt 0) {
        if ($stTopState -cin @('failure', 'error')) { $combinedStatusFailed = $true }
        elseif ($stTopState -ceq 'pending') { $combinedStatusPending = $true }
    }
    foreach ($stItem in @(Get-PropValue $stObj 'statuses')) {
        if ($null -eq $stItem) { continue }
        $ctxName = Assert-SafeText ([string](Get-PropValue $stItem 'context')).Trim() 'status_context'
        if (-not $ctxName) { continue }
        $sState = ([string](Get-PropValue $stItem 'state')).Trim().ToLowerInvariant()
        if (-not $latestStatuses.ContainsKey($ctxName)) {
            $latestStatuses[$ctxName] = $sState
        }
    }
}

$hasFailed = $combinedStatusFailed
$hasPending = $false
$passedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
$failedNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
$totalChecksSeen = 0
$successCount = 0

foreach ($kv in $latestChecks.GetEnumerator()) {
    $totalChecksSeen++
    $c = $kv.Value
    if ($c.Status -cne 'completed') {
        $hasPending = $true
        [void]$failedNames.Add($c.Name)
    } elseif ($c.Conclusion -ceq 'success') {
        $successCount++
        [void]$passedSet.Add($c.Name)
    } elseif ($c.Conclusion -cin @('neutral', 'skipped')) {
        [void]$passedSet.Add($c.Name)
    } else {
        $hasFailed = $true
        [void]$failedNames.Add($c.Name)
    }
}

foreach ($kv in $latestStatuses.GetEnumerator()) {
    $totalChecksSeen++
    if ($kv.Value -ceq 'success') {
        $successCount++
        [void]$passedSet.Add($kv.Key)
    } elseif ($kv.Value -ceq 'pending') {
        $hasPending = $true
        [void]$failedNames.Add($kv.Key)
    } else {
        $hasFailed = $true
        [void]$failedNames.Add($kv.Key)
    }
}
if ($combinedStatusPending -and $latestStatuses.Count -eq 0) {
    $hasPending = $true
}

$missingReqList = New-Object System.Collections.Generic.List[string]
foreach ($rcName in $reqChecksArr) {
    if (-not $passedSet.Contains($rcName) -or $failedNames.Contains($rcName)) {
        [void]$missingReqList.Add($rcName)
    }
}
$missingReqArr = Sort-OrdinalUnique ($missingReqList.ToArray())

$ghCiStatus = 'PASS'
if ($hasFailed) {
    $ghCiStatus = 'FAIL'
} elseif ($hasPending) {
    $ghCiStatus = 'PENDING'
} elseif ($missingReqArr.Count -gt 0) {
    $ghCiStatus = 'MISSING_REQUIRED'
} elseif ($totalChecksSeen -eq 0 -or $successCount -eq 0) {
    $ghCiStatus = 'UNKNOWN'
}

Write-Output 'schema=b3-gh-verify-v1'
Write-Output 'mode=pre-merge'
Write-Output "repo=$repoTrim"
Write-Output "pr_number=$prTrim"
Write-Output "base_repo=$baseRepoFull"
Write-Output "head_repo=$headRepoFull"
Write-Output ("same_repo=" + $(if ($sameRepo) { 'true' } else { 'false' }))
Write-Output "default_branch=$defaultBranch"
Write-Output "pr_state=$prStateRaw"
Write-Output ("pr_merged=" + $(if ($prMerged) { 'true' } else { 'false' }))
Write-Output ("pr_draft=" + $(if ($prDraft) { 'true' } else { 'false' }))
Write-Output "pr_author=$prAuthor"
Write-Output "base_ref=$baseRef"
Write-Output "pr_base_sha=$prBaseSha"
Write-Output "live_target_sha=$liveTargetSha"
Write-Output "head_ref=$headRef"
Write-Output "head_sha=$headSha"
Write-Output "policy_authority_ref=$policyAuthorityRef"
Write-Output "policy_authority_sha=$policyAuthoritySha"
Write-Output "mergeable=$mergeableStr"
Write-Output "mergeable_state=$mergeableState"
Write-Output ("branch_protected=" + $(if ($branchProtected) { 'true' } else { 'false' }))
Write-Output ("branch_protection_readable=" + $(if ($branchProtectionReadable) { 'true' } else { 'false' }))
Write-Output "required_approving_reviews=$reqReviewsCount"
Write-Output ("require_codeowners=" + $(if ($reqCodeowners) { 'true' } else { 'false' }))
Write-Output ("required_checks=" + $(if ($reqChecksArr.Count -gt 0) { $reqChecksArr -join ',' } else { 'none' }))
Write-Output ("missing_required_checks=" + $(if ($missingReqArr.Count -gt 0) { $missingReqArr -join ',' } else { 'none' }))
Write-Output "gh_ci_status=$ghCiStatus"
Write-Output "gh_review_status=$ghReviewStatus"
Write-Output "independent_approved_count=$indepApprovedCnt"
Write-Output "stale_independent_approved_count=$staleIndepCnt"
Write-Output "self_approved_count=$selfApprovedCnt"
Write-Output "unauthorized_approved_count=$unauthApprovedCnt"
Write-Output "changes_requested_count=$changesReqCnt"
Write-Output ("independent_reviewers=" + $(if ($indepReviewersArr.Count -gt 0) { $indepReviewersArr -join ',' } else { 'none' }))
foreach ($cf in $prChangedSorted) {
    Write-Output "pr_changed_file=$cf"
}
exit 0
