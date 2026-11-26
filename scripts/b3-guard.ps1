param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('fingerprint', 'check-freshness', 'precommit', 'snapshot', 'diff-scope', 'mechanical-check', 'check-wave', 'new-run', 'resolve-run', 'list-runs', 'prune', 'verify-run', 'verify-check', 'symbol-check', 'check-worktree', 'review-inventory', 'review-ledger', 'evidence-check', 'merge-policy-check', 'context-cache')]
    [string]$Command,
    [string]$DependsOn = '',
    [string]$Scope = '',
    [string[]]$Criteria = @(),
    [string]$RepoRoot = '.',
    [string]$ApproachAtSha = '',
    [string]$TaskBaseSha = '',
    [string]$BaseSha = '',
    [string]$PrevSha = '',
    [string]$TargetRef = '',
    [string]$WatchedPaths = '',
    [string]$OwnedFiles = '',
    [string]$IgnoreDirtyPaths = '',
    [string]$AllowedPaths = '',
    [string]$Obsoletes = '',
    [string]$WaveSpecs = '',
    [string]$Slug = '',
    [string]$Timestamp = '',
    [string]$RunId = '',
    [int]$Keep = 10,
    [string]$Namespace = 'ship',
    [string]$VerifyCmd = '',
    [string]$ReceiptPath = '',
    [string]$TaskId = '',
    [string]$RelevantPaths = '',
    [string]$LogPath = '',
    [string]$RequireVerifyReceipt = '',
    [switch]$AllowMassDelete,
    [string]$WaveReads = '',
    [string]$ExpectedBaseSha = '',
    [string]$ExpectedRoot = '',
    [string]$ExpectedCmd = '',
    [string]$Action = '',
    [string]$LedgerPath = '',
    [int]$MaxConcurrency = 4,
    [int]$MaxPasses = -1,
    [string]$UnitId = '',
    [string]$Status = '',
    [string]$Findings = '',
    [string]$Specialists = '',
    [string]$Rationale = '',
    [string]$CrossUnitStatus = '',
    [string]$BudgetStatus = '',
    [string]$ReviewIndependence = '',
    [int]$PassesUsed = -1,
    [string]$SourcePaths = '',
    [string]$ManifestPath = '',
    [switch]$WriteManifest,
    [string]$PolicyPath = '',
    [string]$PrState = 'NONE',
    [string]$CiStatus = 'UNKNOWN',
    [string]$ReviewStatus = 'UNKNOWN',
    [int]$BlockingFindings = 0,
    [string]$GovernanceStatus = 'CLEAR',
    [string]$ChangedPaths = '',
    [switch]$PostMerge,
    [string]$MergedSha = '',
    [string]$MainRef = '',
    [string]$PrNumber = '',
    [string]$Repo = '',
    [string]$TargetBranch = '',
    [switch]$LocalOnly,
    [string]$CachePath = '',
    [string]$ScopeId = '',
    [string]$AnchorPaths = '',
    [string]$ScopePaths = '',
    [string]$GraphIndexSha = '',
    [string]$SummaryRef = '',
    [switch]$Partition,
    [string]$ProtectedPaths = '',
    [switch]$CheckDirtyScope,
    [string]$PeerRoots = '',
    [string]$WorkerChanges = '',
    [string]$WorkerRoots = '',
    [string]$DirtyDigests = '',
    [string]$AuthorityRef = '',
    [string]$HeadSha = '',
    [string]$TargetCommitSha = '',
    [switch]$RequireRemoteCi,
    [switch]$Force,
    [switch]$RequireIsolated
)

$ErrorActionPreference = 'Stop'

function Format-WinArg([string]$Arg) {
    if ($null -eq $Arg) { return '""' }
    if ($Arg.Length -gt 0 -and $Arg -notmatch '[\s"]') { return $Arg }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0
    for ($i = 0; $i -lt $Arg.Length; $i++) {
        $ch = $Arg[$i]
        if ($ch -eq '\') {
            $bs++
        } elseif ($ch -eq '"') {
            [void]$sb.Append(('\' * ($bs * 2 + 1)) + '"')
            $bs = 0
        } else {
            if ($bs -gt 0) { [void]$sb.Append(('\' * $bs)); $bs = 0 }
            [void]$sb.Append($ch)
        }
    }
    if ($bs -gt 0) { [void]$sb.Append(('\' * ($bs * 2))) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Resolve-B3Bin([string]$RepoBase) {
    $binName = if ([IO.Path]::DirectorySeparatorChar -eq '\') { 'b3.exe' } else { 'b3' }
    if ($env:B3_BIN) {
        if (Test-Path -LiteralPath $env:B3_BIN -PathType Leaf) { return $env:B3_BIN }
        [Console]::Error.WriteLine("b3 native binary not found; build with 'cargo build --release' or set B3_BIN")
        exit 1
    }
    foreach ($rel in @("target\release\$binName", "target\debug\$binName")) {
        $cand = Join-Path $RepoBase $rel
        if (Test-Path -LiteralPath $cand -PathType Leaf) { return $cand }
    }
    $cmdBin = Get-Command b3 -CommandType Application -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -and (($_.Source -replace '/', '\') -inotmatch '\\microsoft\\windowsapps\\') } |
        Select-Object -First 1
    if ($cmdBin) { return $cmdBin.Source }
    [Console]::Error.WriteLine("b3 native binary not found; build with 'cargo build --release' or set B3_BIN")
    exit 1
}

function Invoke-B3Native([string]$ExePath, [string[]]$B3Args) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ExePath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    if (-not $env:B3_GITHUB_VERIFY_ADAPTER) {
        $psi.EnvironmentVariables['B3_GITHUB_VERIFY_ADAPTER'] = Join-Path $PSScriptRoot 'b3-github-verify.ps1'
    }
    if ($psi.PSObject.Properties['ArgumentList']) {
        foreach ($a in $B3Args) { [void]$psi.ArgumentList.Add($a) }
    } else {
        $psi.Arguments = (($B3Args | ForEach-Object { Format-WinArg $_ }) -join ' ')
    }
    $proc = [System.Diagnostics.Process]::Start($psi)
    if (-not $proc) { exit 1 }
    try {
        $errTask = $proc.StandardError.ReadToEndAsync()
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $proc.WaitForExit()
        $stdout = $outTask.GetAwaiter().GetResult()
        $stderr = $errTask.GetAwaiter().GetResult()
        $outLines = New-Object System.Collections.Generic.List[string]
        if ($stdout) {
            $lines = $stdout -split "\r?\n"
            $end = $lines.Length
            if ($end -gt 0 -and $lines[$end - 1] -eq '') { $end-- }
            for ($i = 0; $i -lt $end; $i++) {
                [void]$outLines.Add($lines[$i])
            }
        }
        if ($stderr) {
            [Console]::Error.Write($stderr)
            [Console]::Error.Flush()
        }
        return @{ Code = [int]$proc.ExitCode; Lines = $outLines.ToArray() }
    } finally {
        $proc.Dispose()
    }
}

if ($Command -cne 'fingerprint') {
    $RepoRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RepoRoot)
    $repoRootBase = [IO.Path]::GetPathRoot($RepoRoot)
    if ($RepoRoot -eq '/' -or $RepoRoot -eq '\') {
        $RepoRoot = '/'
    } elseif ($RepoRoot -match '^([A-Za-z]:)[\\/]?$') {
        $RepoRoot = "$($Matches[1])\"
    } elseif (-not ($repoRootBase -and $RepoRoot.Equals($repoRootBase, [System.StringComparison]::OrdinalIgnoreCase))) {
        $RepoRoot = $RepoRoot.TrimEnd('\', '/')
        if (-not $RepoRoot) { $RepoRoot = '/' }
    }
}

$b3Candidate = Resolve-B3Bin (Split-Path -Parent $PSScriptRoot)
$fwdArgs = New-Object System.Collections.Generic.List[string]
[void]$fwdArgs.Add('guard')
[void]$fwdArgs.Add($Command)
if ($Command -cne 'fingerprint') {
    [void]$fwdArgs.Add("--repo-root=$RepoRoot")
}
switch ($Command) {
    'fingerprint' {
        if ($PSBoundParameters.ContainsKey('DependsOn')) { [void]$fwdArgs.Add("--depends-on=$DependsOn") }
        if ($PSBoundParameters.ContainsKey('Scope')) { [void]$fwdArgs.Add("--scope=$Scope") }
        if ($PSBoundParameters.ContainsKey('Criteria')) {
            foreach ($c in @($Criteria)) { [void]$fwdArgs.Add("--criteria=$c") }
        }
    }
    'check-freshness' {
        if ($PSBoundParameters.ContainsKey('ApproachAtSha')) { [void]$fwdArgs.Add("--approach-at-sha=$ApproachAtSha") }
        if ($PSBoundParameters.ContainsKey('TaskBaseSha')) { [void]$fwdArgs.Add("--task-base-sha=$TaskBaseSha") }
        if ($PSBoundParameters.ContainsKey('WatchedPaths')) { [void]$fwdArgs.Add("--watched-paths=$WatchedPaths") }
        if ($PSBoundParameters.ContainsKey('OwnedFiles')) { [void]$fwdArgs.Add("--owned-files=$OwnedFiles") }
        if ($PSBoundParameters.ContainsKey('IgnoreDirtyPaths')) { [void]$fwdArgs.Add("--ignore-dirty-paths=$IgnoreDirtyPaths") }
    }
    'snapshot' {}
    'new-run' {
        if ($PSBoundParameters.ContainsKey('Slug')) { [void]$fwdArgs.Add("--slug=$Slug") }
        if ($PSBoundParameters.ContainsKey('Timestamp')) { [void]$fwdArgs.Add("--timestamp=$Timestamp") }
        if ($PSBoundParameters.ContainsKey('Namespace')) { [void]$fwdArgs.Add("--namespace=$Namespace") }
    }
    'resolve-run' {
        if ($PSBoundParameters.ContainsKey('RunId')) { [void]$fwdArgs.Add("--run-id=$RunId") }
        if ($PSBoundParameters.ContainsKey('Namespace')) { [void]$fwdArgs.Add("--namespace=$Namespace") }
    }
    'list-runs' {
        if ($PSBoundParameters.ContainsKey('Namespace')) { [void]$fwdArgs.Add("--namespace=$Namespace") }
    }
    'prune' {
        if ($PSBoundParameters.ContainsKey('Keep')) { [void]$fwdArgs.Add("--keep=$Keep") }
        if ($PSBoundParameters.ContainsKey('Namespace')) { [void]$fwdArgs.Add("--namespace=$Namespace") }
    }
    'precommit' {
        if ($PSBoundParameters.ContainsKey('AllowedPaths')) { [void]$fwdArgs.Add("--allowed-paths=$AllowedPaths") }
        if ($PSBoundParameters.ContainsKey('RequireVerifyReceipt')) { [void]$fwdArgs.Add("--require-verify-receipt=$RequireVerifyReceipt") }
        if ($PSBoundParameters.ContainsKey('IgnoreDirtyPaths')) { [void]$fwdArgs.Add("--ignore-dirty-paths=$IgnoreDirtyPaths") }
    }
    'verify-run' {
        if ($PSBoundParameters.ContainsKey('VerifyCmd')) { [void]$fwdArgs.Add("--verify-cmd=$VerifyCmd") }
        if ($PSBoundParameters.ContainsKey('ReceiptPath')) { [void]$fwdArgs.Add("--receipt-path=$ReceiptPath") }
        if ($PSBoundParameters.ContainsKey('TaskId')) { [void]$fwdArgs.Add("--task-id=$TaskId") }
        if ($PSBoundParameters.ContainsKey('Scope')) { [void]$fwdArgs.Add("--scope=$Scope") }
        if ($PSBoundParameters.ContainsKey('RelevantPaths')) { [void]$fwdArgs.Add("--relevant-paths=$RelevantPaths") }
        if ($PSBoundParameters.ContainsKey('IgnoreDirtyPaths')) { [void]$fwdArgs.Add("--ignore-dirty-paths=$IgnoreDirtyPaths") }
        if ($PSBoundParameters.ContainsKey('LogPath')) { [void]$fwdArgs.Add("--log-path=$LogPath") }
    }
    'verify-check' {
        if ($PSBoundParameters.ContainsKey('ReceiptPath')) { [void]$fwdArgs.Add("--receipt-path=$ReceiptPath") }
        if ($PSBoundParameters.ContainsKey('ExpectedCmd')) { [void]$fwdArgs.Add("--expected-cmd=$ExpectedCmd") }
        if ($PSBoundParameters.ContainsKey('RelevantPaths')) { [void]$fwdArgs.Add("--relevant-paths=$RelevantPaths") }
        if ($PSBoundParameters.ContainsKey('IgnoreDirtyPaths')) { [void]$fwdArgs.Add("--ignore-dirty-paths=$IgnoreDirtyPaths") }
        if ($PSBoundParameters.ContainsKey('TargetCommitSha')) { [void]$fwdArgs.Add("--target-commit-sha=$TargetCommitSha") }
    }
    'check-worktree' {
        if ($PSBoundParameters.ContainsKey('ExpectedRoot')) { [void]$fwdArgs.Add("--expected-root=$ExpectedRoot") }
        if ($PSBoundParameters.ContainsKey('ExpectedBaseSha')) { [void]$fwdArgs.Add("--expected-base-sha=$ExpectedBaseSha") }
        if ($PSBoundParameters.ContainsKey('PeerRoots')) { [void]$fwdArgs.Add("--peer-roots=$PeerRoots") }
        if ($RequireIsolated) { [void]$fwdArgs.Add('--require-isolated') }
    }
    'check-wave' {
        if ($PSBoundParameters.ContainsKey('WaveSpecs')) { [void]$fwdArgs.Add("--wave-specs=$WaveSpecs") }
        if ($PSBoundParameters.ContainsKey('WaveReads')) { [void]$fwdArgs.Add("--wave-reads=$WaveReads") }
        if ($PSBoundParameters.ContainsKey('ExpectedBaseSha')) { [void]$fwdArgs.Add("--expected-base-sha=$ExpectedBaseSha") }
        if ($PSBoundParameters.ContainsKey('MaxConcurrency')) { [void]$fwdArgs.Add("--max-concurrency=$MaxConcurrency") }
        if ($Partition) { [void]$fwdArgs.Add('--partition') }
        if ($PSBoundParameters.ContainsKey('ProtectedPaths')) { [void]$fwdArgs.Add("--protected-paths=$ProtectedPaths") }
        if ($CheckDirtyScope) { [void]$fwdArgs.Add('--check-dirty-scope') }
        if ($PSBoundParameters.ContainsKey('IgnoreDirtyPaths')) { [void]$fwdArgs.Add("--ignore-dirty-paths=$IgnoreDirtyPaths") }
    }
    'symbol-check' {
        if ($PSBoundParameters.ContainsKey('BaseSha')) { [void]$fwdArgs.Add("--base-sha=$BaseSha") }
        if ($PSBoundParameters.ContainsKey('TargetRef')) { [void]$fwdArgs.Add("--target-ref=$TargetRef") }
        if ($PSBoundParameters.ContainsKey('IgnoreDirtyPaths')) { [void]$fwdArgs.Add("--ignore-dirty-paths=$IgnoreDirtyPaths") }
    }
    'diff-scope' {
        if ($PSBoundParameters.ContainsKey('BaseSha')) { [void]$fwdArgs.Add("--base-sha=$BaseSha") }
        if ($PSBoundParameters.ContainsKey('PrevSha')) { [void]$fwdArgs.Add("--prev-sha=$PrevSha") }
        if ($PSBoundParameters.ContainsKey('TargetRef')) { [void]$fwdArgs.Add("--target-ref=$TargetRef") }
        if ($PSBoundParameters.ContainsKey('IgnoreDirtyPaths')) { [void]$fwdArgs.Add("--ignore-dirty-paths=$IgnoreDirtyPaths") }
    }
    'mechanical-check' {
        if ($PSBoundParameters.ContainsKey('BaseSha')) { [void]$fwdArgs.Add("--base-sha=$BaseSha") }
        if ($PSBoundParameters.ContainsKey('TargetRef')) { [void]$fwdArgs.Add("--target-ref=$TargetRef") }
        if ($PSBoundParameters.ContainsKey('AllowedPaths')) { [void]$fwdArgs.Add("--allowed-paths=$AllowedPaths") }
        if ($PSBoundParameters.ContainsKey('IgnoreDirtyPaths')) { [void]$fwdArgs.Add("--ignore-dirty-paths=$IgnoreDirtyPaths") }
        if ($PSBoundParameters.ContainsKey('Obsoletes')) { [void]$fwdArgs.Add("--obsoletes=$Obsoletes") }
        if ($AllowMassDelete) { [void]$fwdArgs.Add('--allow-mass-delete') }
        if ($PSBoundParameters.ContainsKey('WaveSpecs')) { [void]$fwdArgs.Add("--wave-specs=$WaveSpecs") }
        if ($PSBoundParameters.ContainsKey('WorkerChanges')) { [void]$fwdArgs.Add("--worker-changes=$WorkerChanges") }
        if ($PSBoundParameters.ContainsKey('WorkerRoots')) { [void]$fwdArgs.Add("--worker-roots=$WorkerRoots") }
        if ($PSBoundParameters.ContainsKey('ProtectedPaths')) { [void]$fwdArgs.Add("--protected-paths=$ProtectedPaths") }
        if ($PSBoundParameters.ContainsKey('DirtyDigests')) { [void]$fwdArgs.Add("--dirty-digests=$DirtyDigests") }
    }
    'review-inventory' {
        if ($PSBoundParameters.ContainsKey('BaseSha')) { [void]$fwdArgs.Add("--base-sha=$BaseSha") }
        if ($PSBoundParameters.ContainsKey('TargetRef')) { [void]$fwdArgs.Add("--target-ref=$TargetRef") }
        if ($PSBoundParameters.ContainsKey('IgnoreDirtyPaths')) { [void]$fwdArgs.Add("--ignore-dirty-paths=$IgnoreDirtyPaths") }
        if ($PSBoundParameters.ContainsKey('MaxConcurrency')) { [void]$fwdArgs.Add("--max-concurrency=$MaxConcurrency") }
    }
    'review-ledger' {
        if ($PSBoundParameters.ContainsKey('Action')) { [void]$fwdArgs.Add("--action=$Action") }
        if ($PSBoundParameters.ContainsKey('LedgerPath')) { [void]$fwdArgs.Add("--ledger-path=$LedgerPath") }
        if ($PSBoundParameters.ContainsKey('BaseSha')) { [void]$fwdArgs.Add("--base-sha=$BaseSha") }
        if ($PSBoundParameters.ContainsKey('TargetRef')) { [void]$fwdArgs.Add("--target-ref=$TargetRef") }
        if ($PSBoundParameters.ContainsKey('IgnoreDirtyPaths')) { [void]$fwdArgs.Add("--ignore-dirty-paths=$IgnoreDirtyPaths") }
        if ($PSBoundParameters.ContainsKey('MaxConcurrency')) { [void]$fwdArgs.Add("--max-concurrency=$MaxConcurrency") }
        if ($PSBoundParameters.ContainsKey('MaxPasses')) { [void]$fwdArgs.Add("--max-passes=$MaxPasses") }
        if ($PSBoundParameters.ContainsKey('UnitId')) { [void]$fwdArgs.Add("--unit-id=$UnitId") }
        if ($PSBoundParameters.ContainsKey('Status')) { [void]$fwdArgs.Add("--status=$Status") }
        if ($PSBoundParameters.ContainsKey('Findings')) { [void]$fwdArgs.Add("--findings=$Findings") }
        if ($PSBoundParameters.ContainsKey('Specialists')) { [void]$fwdArgs.Add("--specialists=$Specialists") }
        if ($PSBoundParameters.ContainsKey('Rationale')) { [void]$fwdArgs.Add("--rationale=$Rationale") }
        if ($PSBoundParameters.ContainsKey('ReceiptPath')) { [void]$fwdArgs.Add("--receipt-path=$ReceiptPath") }
        if ($PSBoundParameters.ContainsKey('CrossUnitStatus')) { [void]$fwdArgs.Add("--cross-unit-status=$CrossUnitStatus") }
        if ($PSBoundParameters.ContainsKey('BudgetStatus')) { [void]$fwdArgs.Add("--budget-status=$BudgetStatus") }
        if ($PSBoundParameters.ContainsKey('ReviewIndependence')) { [void]$fwdArgs.Add("--review-independence=$ReviewIndependence") }
        if ($PSBoundParameters.ContainsKey('PassesUsed')) { [void]$fwdArgs.Add("--passes-used=$PassesUsed") }
        if ($PSBoundParameters.ContainsKey('Scope')) { [void]$fwdArgs.Add("--scope=$Scope") }
        if ($Force) { [void]$fwdArgs.Add('--force') }
    }
    'context-cache' {
        if ($PSBoundParameters.ContainsKey('Action')) { [void]$fwdArgs.Add("--action=$Action") }
        if ($PSBoundParameters.ContainsKey('CachePath')) { [void]$fwdArgs.Add("--cache-path=$CachePath") }
        if ($PSBoundParameters.ContainsKey('ScopeId')) { [void]$fwdArgs.Add("--scope-id=$ScopeId") }
        if ($PSBoundParameters.ContainsKey('AnchorPaths')) { [void]$fwdArgs.Add("--anchor-paths=$AnchorPaths") }
        if ($PSBoundParameters.ContainsKey('ScopePaths')) { [void]$fwdArgs.Add("--scope-paths=$ScopePaths") }
        if ($PSBoundParameters.ContainsKey('GraphIndexSha')) { [void]$fwdArgs.Add("--graph-index-sha=$GraphIndexSha") }
        if ($PSBoundParameters.ContainsKey('SummaryRef')) { [void]$fwdArgs.Add("--summary-ref=$SummaryRef") }
        if ($PSBoundParameters.ContainsKey('IgnoreDirtyPaths')) { [void]$fwdArgs.Add("--ignore-dirty-paths=$IgnoreDirtyPaths") }
    }
    'evidence-check' {
        if ($PSBoundParameters.ContainsKey('SourcePaths')) { [void]$fwdArgs.Add("--source-paths=$SourcePaths") }
        if ($PSBoundParameters.ContainsKey('ManifestPath')) { [void]$fwdArgs.Add("--manifest-path=$ManifestPath") }
        if ($WriteManifest) { [void]$fwdArgs.Add('--write-manifest') }
    }
    'merge-policy-check' {
        if ($PSBoundParameters.ContainsKey('PolicyPath')) { [void]$fwdArgs.Add("--policy-path=$PolicyPath") }
        if ($PSBoundParameters.ContainsKey('PrState')) { [void]$fwdArgs.Add("--pr-state=$PrState") }
        if ($PSBoundParameters.ContainsKey('CiStatus')) { [void]$fwdArgs.Add("--ci-status=$CiStatus") }
        if ($PSBoundParameters.ContainsKey('ReviewStatus')) { [void]$fwdArgs.Add("--review-status=$ReviewStatus") }
        if ($PSBoundParameters.ContainsKey('BlockingFindings')) { [void]$fwdArgs.Add("--blocking-findings=$BlockingFindings") }
        if ($PSBoundParameters.ContainsKey('GovernanceStatus')) { [void]$fwdArgs.Add("--governance-status=$GovernanceStatus") }
        if ($PSBoundParameters.ContainsKey('ChangedPaths')) { [void]$fwdArgs.Add("--changed-paths=$ChangedPaths") }
        if ($PostMerge) { [void]$fwdArgs.Add('--post-merge') }
        if ($PSBoundParameters.ContainsKey('MergedSha')) { [void]$fwdArgs.Add("--merged-sha=$MergedSha") }
        if ($PSBoundParameters.ContainsKey('MainRef')) { [void]$fwdArgs.Add("--main-ref=$MainRef") }
        if ($PSBoundParameters.ContainsKey('TargetRef')) { [void]$fwdArgs.Add("--target-ref=$TargetRef") }
        if ($PSBoundParameters.ContainsKey('AuthorityRef')) { [void]$fwdArgs.Add("--authority-ref=$AuthorityRef") }
        if ($PSBoundParameters.ContainsKey('BaseSha')) { [void]$fwdArgs.Add("--base-sha=$BaseSha") }
        if ($PSBoundParameters.ContainsKey('HeadSha')) { [void]$fwdArgs.Add("--head-sha=$HeadSha") }
        if ($PSBoundParameters.ContainsKey('LedgerPath')) { [void]$fwdArgs.Add("--ledger-path=$LedgerPath") }
        if ($PSBoundParameters.ContainsKey('ReceiptPath')) { [void]$fwdArgs.Add("--receipt-path=$ReceiptPath") }
        if ($PSBoundParameters.ContainsKey('IgnoreDirtyPaths')) { [void]$fwdArgs.Add("--ignore-dirty-paths=$IgnoreDirtyPaths") }
        if ($PSBoundParameters.ContainsKey('PrNumber')) { [void]$fwdArgs.Add("--pr-number=$PrNumber") }
        if ($PSBoundParameters.ContainsKey('Repo')) { [void]$fwdArgs.Add("--repo=$Repo") }
        if ($PSBoundParameters.ContainsKey('TargetBranch')) { [void]$fwdArgs.Add("--target-branch=$TargetBranch") }
        if ($LocalOnly) { [void]$fwdArgs.Add('--local-only') }
        if ($RequireRemoteCi) { [void]$fwdArgs.Add('--require-remote-ci') }
    }
}

$b3Res = Invoke-B3Native $b3Candidate @($fwdArgs.ToArray())
foreach ($ln in @($b3Res.Lines)) { Write-Output $ln }
exit ([int]$b3Res.Code)
