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
$script:CaptureFailMode = $false
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
if ($env:B3_USE_LEGACY -ne '1' -and $Command -in @('fingerprint', 'check-freshness', 'snapshot', 'new-run', 'resolve-run', 'list-runs', 'prune', 'precommit', 'verify-run', 'verify-check', 'check-worktree', 'check-wave', 'symbol-check', 'diff-scope', 'mechanical-check')) {
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
        }
        $b3Res = Invoke-B3Native $b3Candidate @($fwdArgs.ToArray())
        foreach ($ln in @($b3Res.Lines)) { Write-Output $ln }
        exit ([int]$b3Res.Code)
    }
}

function Fail([string]$Message, [int]$Code = 1) {
    if ($script:CaptureFailMode) {
        throw [System.Exception]::new("B3_GUARD_FAIL|${Code}|${Message}")
    }
    [Console]::Out.WriteLine($Message)
    [Console]::Out.Flush()
    exit $Code
}

function Invoke-CapturedGuardCall([scriptblock]$Action) {
    $prevCap = $script:CaptureFailMode
    $script:CaptureFailMode = $true
    try {
        $res = & $Action
        return @{ Ok = $true; Code = 0; Message = ''; Result = $res }
    } catch {
        $exMsg = $_.Exception.Message
        if ($exMsg -match '^B3_GUARD_FAIL\|(\d+)\|(.*)$') {
            return @{ Ok = $false; Code = [int]$Matches[1]; Message = $Matches[2]; Result = $null }
        }
        return @{ Ok = $false; Code = 1; Message = $exMsg; Result = $null }
    } finally {
        $script:CaptureFailMode = $prevCap
    }
}

function Normalize-PathValue([string]$PathValue) {
    $norm = $PathValue.Trim() -replace '\\', '/'
    while ($norm.StartsWith('./')) {
        $norm = $norm.Substring(2)
    }
    return $norm.TrimEnd('/')
}

function Split-CsvList([string]$Csv, [switch]$AsPaths) {
    $list = New-Object System.Collections.Generic.List[string]
    if (-not $Csv) { return @() }
    $cleaned = $Csv.Trim()
    if ($cleaned -eq '[]' -or $cleaned -eq 'none') { return @() }
    if ($cleaned.StartsWith('[') -and $cleaned.EndsWith(']')) {
        $cleaned = $cleaned.Substring(1, $cleaned.Length - 2)
    }
    foreach ($part in ($cleaned -split ',')) {
        $item = $part.Trim()
        if (-not $item -or $item -eq 'none') { continue }
        if ($AsPaths) {
            $item = Normalize-PathValue $item
        }
        if ($item -and -not $list.Contains($item)) {
            $list.Add($item)
        }
    }
    return @($list)
}

function Split-PathCsvChecked([string]$Csv, [string]$ErrorPrefix, [switch]$RejectDot, [string]$DotMessage = '') {
    $list = New-Object System.Collections.Generic.List[string]
    if (-not $Csv) { return @() }
    if ($Csv -match '[\x00-\x1F\x7F]') {
        Fail "${ErrorPrefix}: invalid path control character" 1
    }
    $cleaned = $Csv.Trim()
    if (-not $cleaned -or $cleaned -ceq '[]' -or $cleaned -ceq 'none') { return @() }
    if ($cleaned.StartsWith('[') -and $cleaned.EndsWith(']')) {
        $cleaned = $cleaned.Substring(1, $cleaned.Length - 2)
    }
    foreach ($part in ($cleaned -split ',')) {
        $tok = $part.Trim()
        if (-not $tok -or $tok -ceq 'none') { continue }
        if ($tok -match '[\*\?]') {
            Fail "${ErrorPrefix}: invalid glob in path '$tok'" 1
        }
        $slash = $tok -replace '\\', '/'
        if ($slash.Contains(':') -or $slash.StartsWith('/') -or ($slash -match '(^|/)\.\.(/|$)')) {
            Fail "${ErrorPrefix}: invalid path '$tok'" 1
        }
        $item = if ($slash -ceq '.' -or $slash -ceq './') { '.' } else { Normalize-PathValue $tok }
        if (-not $item) { continue }
        if ($RejectDot -and ($item -ceq '.')) {
            $msg = if ($DotMessage) { $DotMessage } else { "${ErrorPrefix}: invalid ignore-dirty path '.'" }
            Fail $msg 1
        }
        if (-not $list.Contains($item)) {
            $list.Add($item)
        }
    }
    return @($list)
}

function Test-CheckpointPath([string]$PathVal) {
    if (-not $PathVal) { return $false }
    return ($PathVal -match '^\.b3/(ship|research-ship|autodev)(/|$)')
}

function ConvertTo-WavePaths([string]$Csv, [switch]$RejectProtected, [switch]$RejectDot, [string]$ErrorPrefix = 'WAVE_FAIL') {
    $list = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    if (-not $Csv) { return @{ Error = ''; Paths = @(); ExplicitEmpty = $false } }
    $cleaned = $Csv.Trim()
    if ($cleaned -ceq '[]' -or $cleaned -ceq 'none') {
        return @{ Error = ''; Paths = @(); ExplicitEmpty = $true }
    }
    if ($cleaned.StartsWith('[') -and $cleaned.EndsWith(']')) {
        $cleaned = $cleaned.Substring(1, $cleaned.Length - 2)
    }
    foreach ($part in ($cleaned -split ',')) {
        if ($part -match '[\x00-\x1F\x7F]') {
            $disp = $part.Trim()
            if (-not $disp) { $disp = $part }
            return @{ Error = "${ErrorPrefix}: invalid path '$disp'"; Paths = @(); ExplicitEmpty = $false }
        }
        $tok = $part.Trim()
        if (-not $tok -or $tok -ceq 'none') { continue }
        $slash = $tok -replace '\\', '/'
        if ($slash.Contains('|') -or $slash.Contains(':') -or $slash.StartsWith('/') -or $slash.Contains('//') -or ($slash -match '(^|/)\.\.(/|$)') -or ($slash -match '[\*\?]')) {
            return @{ Error = "${ErrorPrefix}: invalid path '$tok'"; Paths = @(); ExplicitEmpty = $false }
        }
        $norm = ''
        if ($slash -eq '.' -or $slash -eq './') {
            $norm = '.'
        } else {
            if ($slash.Contains('/./') -or $slash.EndsWith('/.')) {
                return @{ Error = "${ErrorPrefix}: invalid path '$tok'"; Paths = @(); ExplicitEmpty = $false }
            }
            $norm = $slash
            if ($norm.StartsWith('./')) {
                $norm = $norm.Substring(2)
            }
            $norm = $norm.TrimEnd('/')
            if (-not $norm -or $norm -eq '.' -or $norm -eq '..') {
                return @{ Error = "${ErrorPrefix}: invalid path '$tok'"; Paths = @(); ExplicitEmpty = $false }
            }
            foreach ($seg in ($norm -split '/')) {
                if (-not $seg -or $seg -eq '.' -or $seg -eq '..' -or $seg.EndsWith('.') -or $seg.EndsWith(' ')) {
                    return @{ Error = "${ErrorPrefix}: invalid path '$tok'"; Paths = @(); ExplicitEmpty = $false }
                }
            }
        }
        if ($RejectProtected) {
            if (($norm -imatch '^\.b3(/|$)') -or ($norm -imatch '(^|/)\.git(/|$)') -or ($norm -imatch '(^|/)\.gitmodules$')) {
                return @{ Error = "${ErrorPrefix}: protected path '$norm' cannot be worker-owned"; Paths = @(); ExplicitEmpty = $false }
            }
        }
        if ($RejectDot -and ($norm -ceq '.')) {
            return @{ Error = "${ErrorPrefix}: protected path '.' cannot be worker-owned in parallel partition"; Paths = @(); ExplicitEmpty = $false }
        }
        if ($seen.Add($norm)) {
            $list.Add($norm)
        }
    }
    return @{ Error = ''; Paths = @($list); ExplicitEmpty = $false }
}

function ConvertTo-WaveTaskMap {
    param(
        [string]$Specs,
        [string]$Root,
        [string]$ErrorPrefix = 'WAVE_FAIL',
        [string]$SpecLabel = 'WaveSpecs',
        [string]$EmptyArgLabel = '-WaveSpecs',
        [switch]$RejectProtected,
        [switch]$RejectDot,
        [switch]$AllowEmpty,
        [hashtable]$AllowedTaskIds = $null
    )
    $order = New-Object System.Collections.Generic.List[string]
    $map = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
    $totalPaths = 0
    $repoExists = ($Root -and (Test-Path -LiteralPath $Root -PathType Container))
    $entryLabel = if ($SpecLabel -ceq 'WaveSpecs') { 'entry' } else { "$SpecLabel entry" }

    foreach ($entry in ($Specs -split ';')) {
        $trimEntry = $entry.Trim()
        if (-not $trimEntry) { continue }
        $eqIdx = $trimEntry.IndexOf('=')
        if ($eqIdx -lt 0) { Fail "${ErrorPrefix}: invalid $entryLabel '$trimEntry' (expected TaskId=path1,path2)" 1 }
        $tid = $trimEntry.Substring(0, $eqIdx).Trim()
        $rawCsv = $trimEntry.Substring($eqIdx + 1)
        if (-not $tid) { Fail "${ErrorPrefix}: empty task id in '$trimEntry'" 1 }
        if ($tid -cnotmatch '\A[A-Za-z0-9._-]+\z') { Fail "${ErrorPrefix}: invalid task id '$tid'" 1 }
        if ($map.ContainsKey($tid)) {
            $dupSuffix = if ($SpecLabel -ceq 'WaveSpecs') { '' } else { " in $SpecLabel" }
            Fail "${ErrorPrefix}: duplicate task id '$tid'$dupSuffix" 1
        }
        if ($null -ne $AllowedTaskIds -and (-not $AllowedTaskIds.ContainsKey($tid))) {
            Fail "${ErrorPrefix}: unknown task id '$tid' in $SpecLabel" 1
        }
        $parsed = ConvertTo-WavePaths $rawCsv -RejectProtected:$RejectProtected -RejectDot:$RejectDot -ErrorPrefix $ErrorPrefix
        if ($parsed.Error) { Fail $parsed.Error 1 }
        $paths = @($parsed.Paths)
        if ($paths.Count -lt 1 -and (-not ($AllowEmpty -and $parsed.ExplicitEmpty))) {
            Fail "${ErrorPrefix}: task '$tid' has no owned paths" 1
        }
        if ($repoExists) {
            foreach ($wp in $paths) {
                if (-not (Test-WavePathContained $Root $wp)) {
                    Fail "${ErrorPrefix}: unsafe symlink or junction alias in path '$wp'" 1
                }
            }
        }
        $order.Add($tid)
        $map[$tid] = $paths
        $totalPaths += $paths.Count
    }
    if ($order.Count -lt 1) { Fail "${ErrorPrefix}: no tasks in $EmptyArgLabel" 1 }
    return @{ Order = $order; Map = $map; TotalPaths = $totalPaths }
}

function Test-ResolvedPathWithinRoot([string]$Root, [string]$Full) {
    if (-not $Full) { return $false }
    $rootSlash = ($Root -replace '\\', '/').TrimEnd('/')
    $fullSlash = ($Full -replace '\\', '/').TrimEnd('/')
    $cmp = if ([IO.Path]::DirectorySeparatorChar -eq '\') {
        [System.StringComparison]::OrdinalIgnoreCase
    } else {
        [System.StringComparison]::Ordinal
    }
    if ($rootSlash -eq '') {
        return ($fullSlash.StartsWith('/', $cmp) -and $fullSlash -ne '')
    }
    return ((-not $fullSlash.Equals($rootSlash, $cmp)) -and $fullSlash.StartsWith("$rootSlash/", $cmp))
}

function Test-NoReparseSegments([string]$Root, [string]$RelPath) {
    $segCur = $Root
    foreach ($seg in ($RelPath -split '/')) {
        if (-not $seg -or $seg -eq '.') { continue }
        $segCur = Join-Path $segCur $seg
        $segItem = Get-Item -LiteralPath $segCur -Force -ErrorAction SilentlyContinue
        if ($segItem) {
            if (Test-IsReparseItem $segItem) { return $false }
            try {
                $attrs = [IO.File]::GetAttributes($segCur)
                if (($attrs -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
            } catch {
                return $false
            }
        } elseif (Test-Path -LiteralPath $segCur) {
            return $false
        }
    }
    return $true
}

function Test-WavePathContained([string]$Root, [string]$NormPath) {
    if (-not $Root -or -not (Test-Path -LiteralPath $Root -PathType Container)) { return $true }
    if (-not $NormPath -or $NormPath -ceq '.') { return $true }
    $full = $null
    try {
        $full = Resolve-TargetPath $Root $NormPath
    } catch {
        return $false
    }
    if (-not (Test-ResolvedPathWithinRoot $Root $full)) { return $false }
    if (-not (Test-NoReparseSegments $Root $NormPath)) { return $false }
    if (Test-Path -LiteralPath $full -PathType Container) {
        $dirStack = New-Object System.Collections.Generic.Stack[string]
        $dirStack.Push($full)
        while ($dirStack.Count -gt 0) {
            $dirCur = $dirStack.Pop()
            foreach ($child in @(Get-ChildItem -LiteralPath $dirCur -Force -ErrorAction SilentlyContinue)) {
                if ($null -eq $child) { continue }
                if ($child.Name -ieq '.git') { continue }
                if (Test-IsReparseItem $child) { return $false }
                try {
                    $cAttrs = [IO.File]::GetAttributes($child.FullName)
                    if (($cAttrs -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
                } catch {
                    return $false
                }
                if ($child.PSIsContainer) {
                    $dirStack.Push($child.FullName)
                }
            }
        }
    }
    return $true
}

function Test-WavePathOverlap([string]$PathA, [string]$PathB, [bool]$CaseInsensitive) {
    $a = if ($CaseInsensitive) { $PathA.ToLowerInvariant() } else { $PathA }
    $b = if ($CaseInsensitive) { $PathB.ToLowerInvariant() } else { $PathB }
    if ($a -ceq $b) { return 'equal' }
    if ($a -ceq '.' -or $b -ceq '.' -or $a.StartsWith("$b/", [System.StringComparison]::Ordinal) -or $b.StartsWith("$a/", [System.StringComparison]::Ordinal)) {
        return 'prefix'
    }
    return 'none'
}

function Resolve-NamespaceDir([string]$Root, [string]$Ns) {
    $n = if ($Ns) { $Ns.Trim() } else { 'ship' }
    if ($n -ceq 'ship') { return (Join-Path $Root '.b3\ship') }
    if ($n -ceq 'research-ship') { return (Join-Path $Root '.b3\research-ship') }
    Fail "INVALID_NAMESPACE: $n" 1
}

function Test-ContainedRepoPath([string]$Root, [string]$PathArg) {
    if ([string]::IsNullOrEmpty($PathArg)) { return $null }
    if ($PathArg -match '[\x00-\x1F\x7F]') { return $null }
    if ([string]::IsNullOrWhiteSpace($PathArg)) { return $null }
    if ($PathArg.EndsWith(' ')) { return $null }
    $trimmed = $PathArg.Trim()
    if ($trimmed.Contains(':')) { return $null }
    $rawSlash = $trimmed -replace '\\', '/'
    if (-not $rawSlash -or $rawSlash.EndsWith('/')) { return $null }
    $p = Normalize-PathValue $trimmed
    if (-not $p -or $p -eq '.' -or $p.StartsWith('/') -or $p.StartsWith('~') -or $p.Contains(':') -or ($p -match '(^|/)\.\.(/|$)') -or ($p -match '[\*\?\[]')) {
        return $null
    }
    foreach ($seg in ($p -split '/')) {
        if (-not $seg -or $seg.EndsWith('.') -or $seg.EndsWith(' ')) {
            return $null
        }
    }
    if ($p -imatch '(^|/)\.git(/|$)') {
        return $null
    }
    $full = $null
    try {
        $full = Resolve-TargetPath $Root $p
    } catch {
        return $null
    }
    if (-not (Test-ResolvedPathWithinRoot $Root $full)) { return $null }
    if (-not (Test-NoReparseSegments $Root $p)) { return $null }
    return @{ Rel = $p; Full = $full }
}

function Test-PathMatch([string]$Candidate, [string[]]$Patterns) {
    if (-not $Candidate) { return $false }
    foreach ($p in $Patterns) {
        if ($p -ceq '.') { return $true }
        if ($Candidate -ceq $p) { return $true }
        if ($p -and $Candidate.StartsWith("$p/", [System.StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

function Test-OwnershipPathMatch([string]$Candidate, [string[]]$Patterns, [bool]$CaseInsensitive) {
    if (-not $Candidate -or -not $Patterns -or $Patterns.Count -eq 0) { return $false }
    $cmp = if ($CaseInsensitive) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    foreach ($p in $Patterns) {
        if ($p -ceq '.') { return $true }
        if ($Candidate.Equals($p, $cmp)) { return $true }
        if ($p -and $Candidate.StartsWith("$p/", $cmp)) { return $true }
    }
    return $false
}

function Test-WorktreeRootOverlap([string]$RootA, [string]$RootB, [bool]$CaseInsensitive) {
    $a = if ($CaseInsensitive) { $RootA.ToLowerInvariant() } else { $RootA }
    $b = if ($CaseInsensitive) { $RootB.ToLowerInvariant() } else { $RootB }
    if ($a -ceq $b) { return $true }
    $aBase = $a.TrimEnd('/')
    $bBase = $b.TrimEnd('/')
    if ($aBase -eq '' -or $bBase -eq '') { return $false }
    return ($a.StartsWith("$bBase/", [System.StringComparison]::Ordinal) -or $b.StartsWith("$aBase/", [System.StringComparison]::Ordinal))
}

function Invoke-GitCommand([string]$Root, [string[]]$GitArgs, [string]$StdInText = '', [hashtable]$ExtraEnv = $null, [int]$TimeoutMs = 0) {
    $useStdIn = $PSBoundParameters.ContainsKey('StdInText')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $gitExeName = 'git'
    $gCmd = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($gCmd -and $gCmd.Source -and ($gCmd.Source -imatch '[\\/]mingw(?:32|64)[\\/]bin[\\/]git\.exe$')) {
        $cmdWrap = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $gCmd.Source))) 'cmd\git.exe'
        if (Test-Path -LiteralPath $cmdWrap -PathType Leaf) { $gitExeName = $cmdWrap }
    }
    $psi.FileName = $gitExeName
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables.Remove('MSYS2_ARG_CONV_EXCL')
    if ($ExtraEnv) {
        foreach ($kv in $ExtraEnv.GetEnumerator()) {
            $psi.EnvironmentVariables[[string]$kv.Key] = [string]$kv.Value
        }
    }
    if ($useStdIn) {
        $psi.RedirectStandardInput = $true
    }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    $useLitPs = $true
    foreach ($ga in $GitArgs) {
        if ([string]$ga -ceq '--') { break }
        if ([string]$ga -ceq 'grep') { $useLitPs = $false; break }
    }
    $allArgs = New-Object System.Collections.Generic.List[string]
    if ($useLitPs) { [void]$allArgs.Add('--literal-pathspecs') }
    foreach ($baseGArg in @('-C', $Root, '-c', 'core.quotepath=false', '-c', 'diff.noprefix=false', '-c', 'diff.mnemonicPrefix=false', '-c', 'diff.srcPrefix=a/', '-c', 'diff.dstPrefix=b/')) {
        [void]$allArgs.Add($baseGArg)
    }
    foreach ($ga in @($GitArgs)) { [void]$allArgs.Add([string]$ga) }
    if ($psi.PSObject.Properties['ArgumentList']) {
        foreach ($a in $allArgs) { [void]$psi.ArgumentList.Add($a) }
    } else {
        $psi.Arguments = (($allArgs | ForEach-Object { Format-WinArg $_ }) -join ' ')
    }
    $proc = [System.Diagnostics.Process]::Start($psi)
    if (-not $proc) {
        Fail "GIT_ERROR: failed to start git process" 1
    }
    try {
        $errTask = $proc.StandardError.ReadToEndAsync()
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        if ($useStdIn) {
            $inBytes = $utf8.GetBytes($StdInText)
            if ($inBytes.Length -gt 0) {
                $proc.StandardInput.BaseStream.Write($inBytes, 0, $inBytes.Length)
                $proc.StandardInput.BaseStream.Flush()
            }
            $proc.StandardInput.Close()
        }
        if ($TimeoutMs -gt 0) {
            if (-not $proc.WaitForExit($TimeoutMs)) {
                try { $proc.Kill() } catch {}
                return [PSCustomObject]@{ ExitCode = 124; StdOut = ''; StdErr = 'timeout' }
            }
        } else {
            $proc.WaitForExit()
        }
        $stdout = $outTask.GetAwaiter().GetResult()
        $stderr = $errTask.GetAwaiter().GetResult()
        $code = $proc.ExitCode
    } finally {
        $proc.Dispose()
    }
    return [PSCustomObject]@{
        ExitCode = $code
        StdOut   = $stdout
        StdErr   = $stderr
    }
}

function Test-RepoCaseInsensitive([string]$Root) {
    if ($Root -and (Test-Path -LiteralPath $Root -PathType Container)) {
        $cfg = Invoke-GitCommand $Root @('config', '--bool', 'core.ignorecase')
        if ($cfg.ExitCode -eq 0) {
            $v = $cfg.StdOut.Trim().ToLowerInvariant()
            if ($v -ceq 'true') { return $true }
            if ($v -ceq 'false') { return $false }
        }
    }
    return (($env:OS -eq 'Windows_NT') -or ($IsMacOS -eq $true))
}

function Test-ValidLiteralGitPath([string]$PathValue) {
    if ([string]::IsNullOrEmpty($PathValue)) { return $false }
    if ($PathValue -match '[\x00-\x1F\x7F]') { return $false }
    if ($PathValue.StartsWith('/')) { return $false }
    foreach ($seg in ($PathValue -split '/')) {
        if ([string]::IsNullOrEmpty($seg) -or $seg -ceq '.' -or $seg -ceq '..') { return $false }
    }
    return $true
}

function Invoke-GitPathsZ([string]$Root, [string[]]$GitArgs, [string]$Mode = 'names', [string]$FailPrefix = 'GIT_ERROR', [hashtable]$ExtraEnv = $null) {
    $res = Invoke-GitCommand $Root $GitArgs -ExtraEnv $ExtraEnv
    if ($res.ExitCode -ne 0) {
        $detail = if ($res.StdErr -and $res.StdErr.Trim()) { $res.StdErr.Trim() } else { $res.StdOut.Trim() }
        Fail "${FailPrefix}: git $($GitArgs -join ' ') failed: $detail" 1
    }
    $out = $res.StdOut
    if ([string]::IsNullOrEmpty($out)) { return @() }
    $nul = [char]0
    $toks = $out.Split($nul)
    $len = $toks.Length
    if ($len -gt 0 -and $toks[$len - 1] -eq '') { $len-- }
    $paths = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $addLit = {
        param([string]$pVal)
        if ($pVal.Length -gt 1 -and $pVal.EndsWith('/')) { $pVal = $pVal.Substring(0, $pVal.Length - 1) }
        if (-not (Test-ValidLiteralGitPath $pVal)) {
            Fail "${FailPrefix}: unsupported_literal_git_path" 1
        }
        if ($seen.Add($pVal)) { [void]$paths.Add($pVal) }
    }
    if ($Mode -ceq 'names' -or $Mode -ceq 'ls-tree-z') {
        for ($i = 0; $i -lt $len; $i++) {
            & $addLit $toks[$i]
        }
    } elseif ($Mode -ceq 'name-status-z') {
        $i = 0
        while ($i -lt $len) {
            $st = $toks[$i++]
            if ([string]::IsNullOrEmpty($st) -or $st -match '[\x00-\x1F\x7F]') {
                Fail "${FailPrefix}: git_parser_failed(name-status)" 1
            }
            if ($i -ge $len) { Fail "${FailPrefix}: git_parser_failed(name-status)" 1 }
            $p1 = $toks[$i++]
            & $addLit $p1
            if ($st.StartsWith('R') -or $st.StartsWith('C')) {
                if ($i -ge $len) { Fail "${FailPrefix}: git_parser_failed(name-status-rename)" 1 }
                $p2 = $toks[$i++]
                & $addLit $p2
            }
        }
    } elseif ($Mode -ceq 'status-z') {
        $i = 0
        while ($i -lt $len) {
            $rec = $toks[$i++]
            if ([string]::IsNullOrEmpty($rec) -or $rec.Length -lt 4 -or $rec[2] -cne ' ') {
                Fail "${FailPrefix}: git_parser_failed(status-z)" 1
            }
            $xy = $rec.Substring(0, 2)
            $p1 = $rec.Substring(3)
            if ($p1.Length -gt 1 -and $p1.EndsWith('/')) { $p1 = $p1.Substring(0, $p1.Length - 1) }
            & $addLit $p1
            if ($xy[0] -ceq 'R' -or $xy[0] -ceq 'C' -or $xy[1] -ceq 'R' -or $xy[1] -ceq 'C') {
                if ($i -ge $len) { Fail "${FailPrefix}: git_parser_failed(status-z-rename)" 1 }
                $p2 = $toks[$i++]
                if ($p2.Length -gt 1 -and $p2.EndsWith('/')) { $p2 = $p2.Substring(0, $p2.Length - 1) }
                & $addLit $p2
            }
        }
    } elseif ($Mode -ceq 'ls-tree-full-z' -or $Mode -ceq 'ls-files-stage-z') {
        for ($i = 0; $i -lt $len; $i++) {
            $rec = $toks[$i]
            $tab = $rec.IndexOf("`t")
            if ($tab -le 0) { Fail "${FailPrefix}: git_parser_failed($Mode)" 1 }
            $p = $rec.Substring($tab + 1)
            & $addLit $p
        }
    } else {
        Fail "${FailPrefix}: unsupported_git_paths_mode($Mode)" 1
    }
    return @($paths)
}

function Invoke-GitLines([string]$Root, [string[]]$GitArgs) {
    $hasZ = ($GitArgs -contains '-z')
    if ($hasZ) {
        return @(Invoke-GitPathsZ $Root $GitArgs 'names' 'GIT_ERROR')
    }
    $ddIdx = [Array]::IndexOf($GitArgs, '--')
    $zArgs = New-Object System.Collections.Generic.List[string]
    if ($ddIdx -ge 0) {
        for ($i = 0; $i -lt $ddIdx; $i++) { [void]$zArgs.Add($GitArgs[$i]) }
        [void]$zArgs.Add('-z')
        for ($i = $ddIdx; $i -lt $GitArgs.Length; $i++) { [void]$zArgs.Add($GitArgs[$i]) }
    } else {
        foreach ($ga in $GitArgs) { [void]$zArgs.Add($ga) }
        [void]$zArgs.Add('-z')
    }
    return @(Invoke-GitPathsZ $Root $zArgs.ToArray() 'names' 'GIT_ERROR')
}

function Test-ValidRunId([string]$Id) {
    if (-not $Id) { return $false }
    if ($Id -match '\.\.' -or $Id -match '[/\\]') { return $false }
    return ($Id -match '^[a-zA-Z0-9][a-zA-Z0-9._-]*$')
}

function Get-SanitizedSlug([string]$RawSlug) {
    $s = $RawSlug.ToLowerInvariant() -replace '[^a-z0-9]+', '-'
    $s = $s.Trim('-')
    if ($s.Length -gt 40) {
        $s = $s.Substring(0, 40).Trim('-')
    }
    return $s
}

function Get-CurrentRunId([string]$ShipDir) {
    $curFile = Join-Path $ShipDir 'CURRENT'
    if (-not (Test-Path -LiteralPath $curFile -PathType Leaf)) { return $null }
    return ([IO.File]::ReadAllText($curFile)).Trim()
}

function Sort-Ordinal([string[]]$Items, [switch]$Descending) {
    if (-not $Items -or $Items.Count -eq 0) { return @() }
    $uniq = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $arr = New-Object System.Collections.Generic.List[string]
    foreach ($it in $Items) {
        if ($null -ne $it -and $uniq.Add($it)) { $arr.Add($it) }
    }
    $out = $arr.ToArray()
    [Array]::Sort($out, [System.StringComparer]::Ordinal)
    if ($Descending) { [Array]::Reverse($out) }
    return @($out)
}

function Get-RunStatus([string]$RunDir) {
    $prog = Join-Path $RunDir 'progress.md'
    if (-not (Test-Path -LiteralPath $prog -PathType Leaf)) { return 'unknown' }
    $raw = [IO.File]::ReadAllText($prog)
    if ($raw -match '(?m)^-[ \t]*run_status:[ \t]*([^\r\n]*)\r?$') {
        $st = $Matches[1].Trim()
        if ($st) { return $st }
    }
    return 'unknown'
}

function Test-BinaryFile([string]$FullPath) {
    if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) { return $false }
    try {
        $fs = [IO.File]::OpenRead($FullPath)
        try {
            $buf = New-Object byte[] 8192
            $n = $fs.Read($buf, 0, $buf.Length)
            for ($i = 0; $i -lt $n; $i++) {
                if ($buf[$i] -eq 0) { return $true }
            }
            return $false
        } finally {
            $fs.Dispose()
        }
    } catch {
        return $false
    }
}

function Assert-ValidGitRev([string]$Root, [string]$Rev, [string]$Kind, [string]$FailPrefix, [string]$OptionName) {
    if (-not $Rev -or $Rev.StartsWith('-')) {
        Fail "${FailPrefix}: invalid $OptionName '$Rev'" 1
    }
    $res = Invoke-GitCommand $Root @('rev-parse', '--verify', '--quiet', "${Rev}^{${Kind}}")
    $sha = $res.StdOut.Trim()
    if ($res.ExitCode -ne 0 -or -not $sha) {
        Fail "${FailPrefix}: invalid $OptionName '$Rev'" 1
    }
    return $sha
}

function Assert-SnapshotSafe([string]$Root, [string]$FailPrefix) {
    # A temporary index still creates permanent Git blobs: reject non-deleted sensitive changes first.
    $changedPaths = @(Invoke-GitPathsZ $Root @('diff', '--no-ext-diff', '--no-renames', '--diff-filter=d', '--name-only', '-z', 'HEAD', '--') 'names' $FailPrefix)
    $untrackedPaths = @(Invoke-GitPathsZ $Root @('ls-files', '--others', '--exclude-standard', '-z') 'names' $FailPrefix)
    foreach ($p in (@($changedPaths) + @($untrackedPaths))) {
        if ($p -and (Test-SecretPath $p)) {
            Fail "${FailPrefix}: sensitive path cannot be snapshotted ($p)" 1
        }
    }
    $stageRes = Invoke-GitCommand $Root @('ls-files', '--stage', '-z')
    if ($stageRes.ExitCode -ne 0) { Fail "${FailPrefix}: unable to inspect submodules" 1 }
    if ($stageRes.StdOut) {
        $nul = [char]0
        foreach ($entry in ($stageRes.StdOut.Split($nul))) {
            if (-not $entry) { continue }
            if ($entry -cnotmatch '^160000 [0-9a-f]{40} [0-3]\t(.+)$') { continue }
            $rel = $Matches[1]
            if (-not (Test-ValidLiteralGitPath $rel)) { Fail "${FailPrefix}: unsupported_literal_git_path" 1 }
            $sub = Join-Path $Root ($rel -replace '/', '\')
            if (-not (Test-Path -LiteralPath (Join-Path $sub '.git'))) { continue }
            $subDirty = @(Invoke-GitPathsZ $sub @('status', '--porcelain', '--untracked-files=all', '--ignore-submodules=none', '-z') 'status-z' $FailPrefix)
            if ($subDirty.Count -gt 0) { Fail "${FailPrefix}: dirty submodule cannot be snapshotted ($rel)" 1 }
        }
    }
}

function Invoke-ChunkedGitWithIndex(
    [string]$Root,
    [hashtable]$EnvMap,
    [string]$FailPrefix,
    [string]$FailLabel,
    [string[]]$BaseArgs,
    [System.Collections.Generic.List[string]]$Paths
) {
    if ($null -eq $Paths -or $Paths.Count -eq 0) { return }
    for ($i = 0; $i -lt $Paths.Count; $i += 50) {
        $end = [Math]::Min($i + 49, $Paths.Count - 1)
        $cmdArgs = New-Object System.Collections.Generic.List[string]
        foreach ($ba in $BaseArgs) { [void]$cmdArgs.Add($ba) }
        for ($j = $i; $j -le $end; $j++) { [void]$cmdArgs.Add($Paths[$j]) }
        $cmdRes = Invoke-GitCommand $Root $cmdArgs.ToArray() -ExtraEnv $EnvMap
        if ($cmdRes.ExitCode -ne 0) {
            $detail = if ($cmdRes.StdErr.Trim()) { $cmdRes.StdErr.Trim() } else { $cmdRes.StdOut.Trim() }
            Fail "${FailPrefix}: ${FailLabel}: $detail" 1
        }
    }
}

function New-WorkingTreeOid([string]$Root, [string]$FailPrefix, [switch]$ExcludeSensitive) {
    $hasHead = (Invoke-GitCommand $Root @('rev-parse', '--verify', '--quiet', 'HEAD')).ExitCode -eq 0
    $trackedSecrets = New-Object System.Collections.Generic.List[string]
    $unbornStagedSecrets = New-Object System.Collections.Generic.List[string]
    $untrackedToAdd = New-Object System.Collections.Generic.List[string]
    if ($ExcludeSensitive) {
        if ($hasHead) {
            foreach ($sp in @(Invoke-GitPathsZ $Root @('diff', '--no-ext-diff', '--no-renames', '--diff-filter=d', '--name-only', '-z', 'HEAD', '--') 'names' $FailPrefix)) {
                if ($sp -and (Test-SecretPath $sp)) {
                    [void]$trackedSecrets.Add($sp)
                }
            }
        } else {
            foreach ($sp in @(Invoke-GitPathsZ $Root @('ls-files', '--cached', '-z') 'names' $FailPrefix)) {
                if ($sp -and (Test-SecretPath $sp)) {
                    [void]$unbornStagedSecrets.Add($sp)
                }
            }
        }
    } else {
        Assert-SnapshotSafe $Root $FailPrefix
    }
    foreach ($sp in @(Invoke-GitPathsZ $Root @('ls-files', '--others', '--exclude-standard', '-z') 'names' $FailPrefix)) {
        if (-not $sp) { continue }
        if (Test-CheckpointPath $sp) { continue }
        if ($ExcludeSensitive -and (Test-SecretPath $sp)) { continue }
        [void]$untrackedToAdd.Add($sp)
    }
    $idxRes = Invoke-GitCommand $Root @('rev-parse', '--git-path', 'index')
    if ($idxRes.ExitCode -ne 0) {
        Fail "${FailPrefix}: failed to locate git index" 1
    }
    $realIdxRaw = $idxRes.StdOut.Trim()
    $realIdx = Resolve-TargetPath $Root $realIdxRaw
    $tmpIdx = Join-Path ([IO.Path]::GetTempPath()) ("b3-snap-idx-" + [guid]::NewGuid().ToString('N') + ".tmp")
    $envMap = @{ GIT_INDEX_FILE = $tmpIdx }
    try {
        if (Test-Path -LiteralPath $realIdx -PathType Leaf) {
            [IO.File]::Copy($realIdx, $tmpIdx, $true)
        }
        if ($ExcludeSensitive -and $unbornStagedSecrets.Count -gt 0) {
            Invoke-ChunkedGitWithIndex $Root $envMap $FailPrefix 'git rm cached secrets failed' @('rm', '-r', '--cached', '--ignore-unmatch', '-q', '--') $unbornStagedSecrets
        }
        if ($ExcludeSensitive -and $trackedSecrets.Count -gt 0) {
            $wtDiffPaths = @(Invoke-GitPathsZ $Root @('diff', '--no-ext-diff', '--no-renames', '--name-only', '-z', '--') 'names' $FailPrefix -ExtraEnv $envMap)
            $trackedSecretSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
            foreach ($ts in $trackedSecrets) { [void]$trackedSecretSet.Add($ts) }
            $nonSecretTracked = New-Object System.Collections.Generic.List[string]
            foreach ($sp in $wtDiffPaths) {
                if ($sp -and -not $trackedSecretSet.Contains($sp)) {
                    [void]$nonSecretTracked.Add($sp)
                }
            }
            Invoke-ChunkedGitWithIndex $Root $envMap $FailPrefix 'git add -u filtered failed' @('add', '-u', '--') $nonSecretTracked
            Invoke-ChunkedGitWithIndex $Root $envMap $FailPrefix 'git reset HEAD failed' @('reset', '-q', 'HEAD', '--') $trackedSecrets
        } else {
            $addRes = Invoke-GitCommand $Root @('add', '-u') -ExtraEnv $envMap
            if ($addRes.ExitCode -ne 0) {
                $detail = if ($addRes.StdErr.Trim()) { $addRes.StdErr.Trim() } else { $addRes.StdOut.Trim() }
                Fail "${FailPrefix}: git add -u failed: $detail" 1
            }
        }
        Invoke-ChunkedGitWithIndex $Root $envMap $FailPrefix 'git add untracked failed' @('add', '--') $untrackedToAdd
        $rmRes = Invoke-GitCommand $Root @('rm', '-r', '--cached', '--ignore-unmatch', '--quiet', '--', '.b3/ship', '.b3/research-ship', '.b3/autodev') -ExtraEnv $envMap
        if ($rmRes.ExitCode -ne 0) {
            $detail = if ($rmRes.StdErr.Trim()) { $rmRes.StdErr.Trim() } else { $rmRes.StdOut.Trim() }
            Fail "${FailPrefix}: git rm checkpoint failed: $detail" 1
        }
        $wtRes = Invoke-GitCommand $Root @('write-tree') -ExtraEnv $envMap
        $treeSha = $wtRes.StdOut.Trim()
        if ($wtRes.ExitCode -ne 0 -or -not $treeSha) {
            $detail = if ($wtRes.StdErr.Trim()) { $wtRes.StdErr.Trim() } else { $wtRes.StdOut.Trim() }
            Fail "${FailPrefix}: git write-tree failed: $detail" 1
        }
        return $treeSha
    } finally {
        Remove-Item -LiteralPath $tmpIdx -Force -ErrorAction SilentlyContinue
    }
}

function Test-NoiseFile([string]$PathVal) {
    $leaf = ($PathVal -split '/')[-1]
    if ($leaf -in @('package-lock.json', 'pnpm-lock.yaml', 'yarn.lock', 'bun.lockb', 'packages.lock.json', 'Cargo.lock', 'poetry.lock')) {
        return $true
    }
    if ($leaf -match '\.(min\.js|min\.css|snap|Designer\.cs|g\.cs|map)$') {
        return $true
    }
    return $false
}

function Find-LeftoverTag([string]$Line) {
    if ($Line -cmatch '(^|[^a-zA-Z0-9_])debugger([^a-zA-Z0-9_]|$)') { return 'debugger' }
    if ($Line -cmatch '\.only\(') { return '.only(' }
    if ($Line -cmatch '@ts-ignore') { return '@ts-ignore' }
    if ($Line -cmatch 'eslint-disable') { return 'eslint-disable' }
    if ($Line -cmatch '(^|[^a-zA-Z0-9_])(TODO|FIXME)[ \t]*:?[ \t]*$') { return 'empty-todo' }
    return $null
}

function Resolve-AutoBaseSha([string]$Root, [string[]]$IgnoredPaths) {
    $headRes = Invoke-GitCommand $Root @('rev-parse', '--verify', '--quiet', 'HEAD')
    $hasHead = ($headRes.ExitCode -eq 0 -and $headRes.StdOut.Trim() -cmatch '^[0-9a-f]{40}$')
    $headSha = if ($hasHead) { $headRes.StdOut.Trim() } else { '' }
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($hasHead) {
        foreach ($p in @(Invoke-GitPathsZ $Root @('diff', '--no-ext-diff', '--no-renames', '--name-only', '-z', 'HEAD', '--') 'names' 'GIT_ERROR')) {
            if ($p) { $candidates.Add($p) }
        }
    }
    foreach ($p in @(Invoke-GitPathsZ $Root @('ls-files', '--others', '--exclude-standard', '-z') 'names' 'GIT_ERROR')) {
        if ($p) { $candidates.Add($p) }
    }
    foreach ($p in $candidates) {
        if (Test-CheckpointPath $p) { continue }
        if ($IgnoredPaths -and (Test-PathMatch $p $IgnoredPaths)) { continue }
        return 'HEAD'
    }

    if ($hasHead -and $headSha) {
        foreach ($ref in @('origin/HEAD', 'origin/main', 'origin/master', 'main', 'master')) {
            $refRes = Invoke-GitCommand $Root @('rev-parse', '--verify', '--quiet', $ref)
            if ($refRes.ExitCode -eq 0) {
                $mbRes = Invoke-GitCommand $Root @('merge-base', $ref, 'HEAD')
                $mb = $mbRes.StdOut.Trim()
                if ($mbRes.ExitCode -eq 0 -and $mb -and $mb -ne $headSha) {
                    return $mb
                }
            }
        }
    }
    return 'HEAD'
}

function Resolve-AutoBaseForTarget([string]$Root, [string]$TargetCommitSha) {
    foreach ($ref in @('origin/HEAD', 'origin/main', 'origin/master', 'main', 'master', 'HEAD')) {
        $refRes = Invoke-GitCommand $Root @('rev-parse', '--verify', '--quiet', $ref)
        if ($refRes.ExitCode -eq 0) {
            $mbRes = Invoke-GitCommand $Root @('merge-base', $ref, $TargetCommitSha)
            $mb = $mbRes.StdOut.Trim()
            if ($mbRes.ExitCode -eq 0 -and $mb -and $mb -ne $TargetCommitSha) {
                return $mb
            }
        }
    }
    $parRes = Invoke-GitCommand $Root @('rev-parse', '--verify', '--quiet', "${TargetCommitSha}^")
    $par = $parRes.StdOut.Trim()
    if ($parRes.ExitCode -eq 0 -and $par) {
        return $par
    }
    return $TargetCommitSha
}

function Resolve-ScopeTargetAndBase([string]$Root, [string]$TargetRefRaw, [string]$BaseShaRaw, [string[]]$IgnoredPaths, [string]$FailPrefix, [string]$BaseRevKind = 'object') {
    $targetTrim = $TargetRefRaw.Trim()
    $targetCommitSha = ''
    if ($targetTrim) {
        if ($targetTrim -match '[\r\n]') {
            Fail "${FailPrefix}: invalid -TargetRef '$targetTrim'" 1
        }
        $targetCommitSha = Assert-ValidGitRev $Root $targetTrim 'commit' $FailPrefix '-TargetRef'
    }
    $resolvedBase = $BaseShaRaw.Trim()
    if (-not $resolvedBase -or $resolvedBase -eq 'auto') {
        $resolvedBase = if ($targetTrim) { Resolve-AutoBaseForTarget $Root $targetCommitSha } else { Resolve-AutoBaseSha $Root $IgnoredPaths }
    }
    $validBaseSha = Assert-ValidGitRev $Root $resolvedBase $BaseRevKind $FailPrefix '-BaseSha'
    return @{
        TargetRef = $targetTrim
        TargetCommitSha = $targetCommitSha
        BaseSha = if ($BaseRevKind -eq 'commit') { $validBaseSha } else { $resolvedBase }
    }
}

function Test-SecretPath([string]$PathVal) {
    $leaf = (($PathVal -split '/')[-1]).ToLowerInvariant()
    if (-not $leaf) { return $false }
    if ($leaf -eq '.env') { return $true }
    if ($leaf.StartsWith('.env.')) {
        if ($leaf -match '^\.env\.(example|sample|template)$') { return $false }
        return $true
    }
    if ($leaf -match '\.(pem|key|p12|pfx)$') { return $true }
    if ($leaf -in @('id_rsa', 'id_ed25519', 'credentials.json')) { return $true }
    return $false
}

function Get-ResolvedGitDir([string]$Root) {
    $res = Invoke-GitCommand $Root @('rev-parse', '--git-dir')
    $gd = $res.StdOut.Trim()
    if ($res.ExitCode -ne 0 -or -not $gd) { return $null }
    return (Resolve-TargetPath $Root $gd)
}

function Test-GitMidOperation([string]$Root) {
    $gitDir = Get-ResolvedGitDir $Root
    if (-not $gitDir) { return $null }
    foreach ($marker in @('MERGE_HEAD', 'REBASE_HEAD', 'rebase-merge', 'rebase-apply', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'BISECT_LOG')) {
        if (Test-Path -LiteralPath (Join-Path $gitDir $marker)) {
            return $marker
        }
    }
    return $null
}

function Resolve-TargetPath([string]$Root, [string]$PathArg) {
    $p = $PathArg.Trim()
    if (-not $p) { return $null }
    $pNative = $p -replace '[\\/]', [IO.Path]::DirectorySeparatorChar
    if ([IO.Path]::IsPathRooted($pNative)) {
        return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($pNative)
    }
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((Join-Path $Root $pNative))
}

function Get-RepoRelativePath([string]$Root, [string]$FullPath) {
    $rootNorm = Normalize-PathValue $Root
    $fullNorm = Normalize-PathValue $FullPath
    if ($rootNorm -eq '.') { return $fullNorm }
    if ($fullNorm.StartsWith("$rootNorm/", [System.StringComparison]::OrdinalIgnoreCase)) {
        return $fullNorm.Substring($rootNorm.Length + 1)
    }
    if ($fullNorm.Equals($rootNorm, [System.StringComparison]::OrdinalIgnoreCase)) {
        return '.'
    }
    return $fullNorm
}

function Test-IsReparseItem([System.IO.FileSystemInfo]$Item) {
    if (-not $Item) { return $false }
    if ($Item.LinkType -in @('Junction', 'SymbolicLink')) { return $true }
    return (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Test-IsReparsePath([string]$PathValue) {
    if (-not $PathValue) { return $false }
    $item = Get-Item -LiteralPath $PathValue -Force -ErrorAction SilentlyContinue
    return (Test-IsReparseItem $item)
}

function Remove-DirTreeSafely([string]$TargetDir) {
    $item = Get-Item -LiteralPath $TargetDir -Force -ErrorAction SilentlyContinue
    if (-not $item) { return }
    if (Test-IsReparseItem $item) {
        Fail "PRUNE_FAIL: refusing recursive delete of link path: $TargetDir" 1
    }
    if (-not $item.PSIsContainer) {
        Remove-Item -LiteralPath $TargetDir -Force
        return
    }
    foreach ($child in @(Get-ChildItem -LiteralPath $TargetDir -Force)) {
        if ($null -eq $child) { continue }
        if (Test-IsReparseItem $child) {
            if ($child.PSIsContainer) {
                [System.IO.Directory]::Delete($child.FullName, $false)
            } else {
                Remove-Item -LiteralPath $child.FullName -Force
            }
        } elseif ($child.PSIsContainer) {
            Remove-DirTreeSafely $child.FullName
        } else {
            Remove-Item -LiteralPath $child.FullName -Force
        }
    }
    [System.IO.Directory]::Delete($TargetDir, $false)
}

function Test-SafeRepoPathSegments([string]$PathValue, [bool]$BlockGit = $true) {
    if ([string]::IsNullOrEmpty($PathValue)) { return $false }
    if ($PathValue -match '[\x00-\x1F\x7F]') { return $false }
    $s = $PathValue -replace '\\', '/'
    if ($s.Contains(':') -or $s.StartsWith('/') -or $s.EndsWith('/') -or $s.StartsWith('~') -or ($s -match '[\*\?]')) { return $false }
    foreach ($seg in ($s -split '/')) {
        if ([string]::IsNullOrEmpty($seg) -or $seg -ceq '.' -or $seg -ceq '..' -or ($seg -match '[\. ]$')) {
            return $false
        }
    }
    if ($BlockGit -and ($s -imatch '(^|/)\.git(/|$)')) {
        return $false
    }
    return $true
}

function Resolve-SafeRepoWritePath([string]$Root, [string]$PathArg) {
    if ([string]::IsNullOrWhiteSpace($PathArg)) { return $null }
    if ($PathArg -match '[\x00-\x1F\x7F]' -or $PathArg.EndsWith(' ')) { return $null }
    $trimmed = $PathArg.Trim()
    $slashArg = $trimmed -replace '\\', '/'
    if (-not $slashArg -or $slashArg -eq '.' -or $slashArg.StartsWith('~') -or $slashArg.EndsWith('/')) { return $null }

    $rawTail = if (([IO.Path]::DirectorySeparatorChar -eq '\') -and ($slashArg -match '^[A-Za-z]:/')) {
        $slashArg.Substring(3)
    } elseif ($slashArg.StartsWith('/')) {
        $slashArg.Substring(1)
    } else {
        $slashArg
    }
    if (-not (Test-SafeRepoPathSegments $rawTail $false)) { return $null }

    $full = $null
    try {
        $full = Resolve-TargetPath $Root $trimmed
    } catch {
        return $null
    }
    if (-not (Test-ResolvedPathWithinRoot $Root $full)) { return $null }

    $rel = Get-RepoRelativePath $Root $full
    if (-not $rel -or [IO.Path]::IsPathRooted($rel) -or -not (Test-SafeRepoPathSegments $rel $true)) {
        return $null
    }
    if (-not (Test-NoReparseSegments $Root $rel)) { return $null }

    return @{ FullPath = $full; RelPath = $rel }
}

function Write-AtomicLfFile([string]$DestPath, [string]$Text) {
    if ((Test-Path -LiteralPath $DestPath -PathType Container) -or (Test-IsReparsePath $DestPath)) {
        Fail "WRITE_ERROR: refusing to write over directory or link: $DestPath" 1
    }
    $parent = Split-Path -Parent $DestPath
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $lfText = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    $tmp = "$DestPath.tmp.${PID}." + ([guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        [IO.File]::WriteAllText($tmp, $lfText, $utf8NoBom)
        Move-Item -LiteralPath $tmp -Destination $DestPath -Force
    } finally {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-GitEntryType([string]$Mode) {
    switch ($Mode) {
        '160000' { return 'commit' }
        '000000' { return 'deleted' }
        '040000' { return 'tree' }
        default  { return 'blob' }
    }
}

function Parse-GitRawDiff([string]$RawOut, [string[]]$IgnPaths, [string[]]$CleanRel) {
    $map = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::Ordinal)
    if (-not $RawOut) { return $map }
    foreach ($rawLine in ($RawOut -split "\r?\n")) {
        if (-not $rawLine -or -not $rawLine.StartsWith(':') -or $rawLine.StartsWith('::')) { continue }
        $tabIdx = $rawLine.IndexOf("`t")
        if ($tabIdx -lt 2) { continue }
        $meta = $rawLine.Substring(1, $tabIdx - 1).Trim() -split '\s+'
        if ($meta.Count -lt 5) { continue }
        $newMode = $meta[1]
        $newOid = $meta[3]
        if ($newMode -cnotmatch '^[0-9]{6}$' -or $newOid -cnotmatch '^[0-9a-f]{40}$') { continue }
        $p = Normalize-PathValue ($rawLine.Substring($tabIdx + 1))
        if (-not $p -or (Test-CheckpointPath $p)) { continue }
        if ($IgnPaths -and (Test-PathMatch $p $IgnPaths)) { continue }
        if ($CleanRel.Count -gt 0 -and -not (Test-PathMatch $p $CleanRel)) { continue }
        if ($map.ContainsKey($p) -and $newMode -ceq '000000' -and $map[$p].NewMode -cne '000000') { continue }
        $map[$p] = @{
            NewMode = $newMode
            NewOid  = $newOid
            Status  = $meta[4]
        }
    }
    return $map
}

function Invoke-GitTextHash([string]$Root, [string]$Text, [string]$FailPrefix = 'GIT_ERROR', [string]$FailDesc = 'failed') {
    $utf8 = [System.Text.Encoding]::UTF8
    $payload = if ($null -eq $Text) { [byte[]]@() } else { $utf8.GetBytes($Text) }
    $header = $utf8.GetBytes("blob $($payload.Length)`0")
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        [void]$sha1.TransformBlock($header, 0, $header.Length, $null, 0)
        [void]$sha1.TransformFinalBlock($payload, 0, $payload.Length)
        return ([System.BitConverter]::ToString($sha1.Hash).Replace('-', '').ToLowerInvariant())
    } finally {
        $sha1.Dispose()
    }
}

function Get-SymlinkBlobOid([string]$Root, [string]$RelPath) {
    $full = Join-Path $Root ($RelPath -replace '/', '\')
    $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
    if ($item -and (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        $isSym = (-not $item.PSObject.Properties['LinkType']) -or ($item.LinkType -ceq 'SymbolicLink')
        if ($isSym -and $item.PSObject.Properties['Target'] -and $item.Target) {
            $tgt = ([string](@($item.Target)[0])) -replace '\\', '/'
            return (Invoke-GitTextHash $Root $tgt 'GIT_ERROR' "symlink failed for ${RelPath}")
        }
    }
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        $wRes = Invoke-GitCommand $Root @('hash-object', '--', $RelPath)
        $wSha = $wRes.StdOut.Trim()
        if ($wRes.ExitCode -ne 0 -or $wSha -notmatch '^[0-9a-f]{40}$') {
            $detail = if ($wRes.StdErr.Trim()) { $wRes.StdErr.Trim() } else { $wSha }
            Fail "GIT_ERROR: git hash-object failed for ${RelPath}: $detail" 1
        }
        return $wSha
    }
    return $null
}

function Get-SubmoduleEntryIdentity([string]$Root, [string]$RelPath, [string]$FallbackOid, [int]$Depth = 0) {
    $subFull = Join-Path $Root ($RelPath -replace '/', '\')
    $zeroOid = '0000000000000000000000000000000000000000'
    $hasFallback = ($FallbackOid -and $FallbackOid -cne $zeroOid -and $FallbackOid -cmatch '^[0-9a-f]{40}$')
    $subGit = Join-Path $subFull '.git'
    if ((Test-Path -LiteralPath $subFull -PathType Container) -and (Test-Path -LiteralPath $subGit)) {
        $shRes = Invoke-GitCommand $subFull @('rev-parse', 'HEAD')
        $shTrim = $shRes.StdOut.Trim()
        $hasHead = ($shRes.ExitCode -eq 0 -and $shTrim -cmatch '^[0-9a-f]{40}$')
        $subHead = if ($hasHead) { $shTrim } elseif ($hasFallback) { $FallbackOid } else { 'UNBORN' }

        $stRes = Invoke-GitCommand $subFull @('status', '--porcelain', '-uall', '--ignore-submodules=none', '-z')
        if ($stRes.ExitCode -ne 0) {
            $detail = if ($stRes.StdErr.Trim()) { $stRes.StdErr.Trim() } else { $stRes.StdOut.Trim() }
            Fail "GIT_ERROR: submodule status failed for ${RelPath}: $detail" 1
        }
        $stList = New-Object System.Collections.Generic.List[string]
        if ($stRes.StdOut) {
            $nulSub = [char]0
            foreach ($rawSt in ($stRes.StdOut.Split($nulSub))) {
                if (-not [string]::IsNullOrEmpty($rawSt)) { $stList.Add($rawSt) }
            }
        }
        if ($stList.Count -eq 0) {
            return "160000 commit $subHead"
        }

        $sbDirty = New-Object System.Text.StringBuilder
        foreach ($sl in @(Sort-Ordinal $stList.ToArray())) {
            [void]$sbDirty.Append("S $sl`n")
        }
        $sWt = if ($hasHead) { @(Invoke-GitLines $subFull @('diff', '--no-ext-diff', '--no-renames', '--name-only', '--ignore-submodules=none', 'HEAD', '--')) } else { @() }
        $sCa = @(Invoke-GitLines $subFull @('diff', '--no-ext-diff', '--no-renames', '--cached', '--name-only', '--'))
        $sUn = @(Invoke-GitLines $subFull @('ls-files', '--others', '--exclude-standard'))
        $sCand = New-Object System.Collections.Generic.List[string]
        foreach ($sp in (@($sWt) + @($sCa) + @($sUn))) {
            if ($sp) { $sCand.Add($sp) }
        }
        foreach ($sp in @(Sort-Ordinal $sCand.ToArray())) {
            $spFull = Join-Path $subFull ($sp -replace '/', '\')
            $spItem = Get-Item -LiteralPath $spFull -Force -ErrorAction SilentlyContinue
            if ($spItem -and (($spItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
                $lSha = Get-SymlinkBlobOid $subFull $sp
                if ($lSha) { [void]$sbDirty.Append("C $sp 120000:$lSha`n") }
                else { [void]$sbDirty.Append("C $sp DELETED`n") }
            } elseif (Test-Path -LiteralPath $spFull -PathType Leaf) {
                $fRes = Invoke-GitCommand $subFull @('hash-object', '--', $sp)
                $fSha = $fRes.StdOut.Trim()
                if ($fRes.ExitCode -ne 0 -or $fSha -notmatch '^[0-9a-f]{40}$') {
                    $detail = if ($fRes.StdErr.Trim()) { $fRes.StdErr.Trim() } else { $fSha }
                    Fail "GIT_ERROR: submodule hash-object failed for ${RelPath}/${sp}: $detail" 1
                }
                [void]$sbDirty.Append("C $sp $fSha`n")
            } elseif (Test-Path -LiteralPath $spFull -PathType Container) {
                if (Test-Path -LiteralPath (Join-Path $spFull '.git')) {
                    if ($Depth -ge 5) {
                        Fail "GIT_ERROR: nested submodule depth exceeded for ${RelPath}/${sp}" 1
                    }
                    $nestedIdentity = Get-SubmoduleEntryIdentity $subFull $sp '' ($Depth + 1)
                    $nestedTag = if ($nestedIdentity) { $nestedIdentity } else { 'DIR' }
                    [void]$sbDirty.Append("D $sp $nestedTag`n")
                } else {
                    [void]$sbDirty.Append("D $sp DIR`n")
                }
            } else {
                [void]$sbDirty.Append("C $sp DELETED`n")
            }
        }
        $dSha = Invoke-GitTextHash $Root $sbDirty.ToString() 'GIT_ERROR' "submodule digest failed for ${RelPath}"
        return "160000 commit ${subHead}+dirty:${dSha}"
    }
    if ($hasFallback) {
        return "160000 commit $FallbackOid"
    }
    return $null
}

function Get-TreeFingerprint([string]$Root, [string[]]$RelPaths, [string[]]$IgnPaths, [string]$TargetCommitSha = '') {
    $hasTargetCommit = -not [string]::IsNullOrWhiteSpace($TargetCommitSha)
    if ($hasTargetCommit) {
        $tArg = $TargetCommitSha.Trim()
        if ($tArg.StartsWith('-')) {
            Fail "GIT_ERROR: invalid target commit sha: $tArg" 1
        }
        $headRes = Invoke-GitCommand $Root @('rev-parse', '--verify', "$tArg^{commit}")
        $headSha = $headRes.StdOut.Trim()
        if ($headRes.ExitCode -ne 0 -or $headSha -cnotmatch '^[0-9a-f]{40}$') {
            $detail = if ($headRes.StdErr.Trim()) { $headRes.StdErr.Trim() } else { $headSha }
            Fail "GIT_ERROR: git rev-parse $tArg failed: $detail" 1
        }
    } else {
        $headRes = Invoke-GitCommand $Root @('rev-parse', 'HEAD')
        $headSha = $headRes.StdOut.Trim()
        if ($headRes.ExitCode -ne 0 -or $headSha -notmatch '^[0-9a-f]{40}$') {
            $detail = if ($headRes.StdErr.Trim()) { $headRes.StdErr.Trim() } else { $headSha }
            Fail "GIT_ERROR: git rev-parse HEAD failed: $detail" 1
        }
    }

    $cleanRel = @()
    if ($RelPaths -and $RelPaths.Count -gt 0) {
        $relFiltered = New-Object System.Collections.Generic.List[string]
        foreach ($rp in $RelPaths) {
            $np = Normalize-PathValue $rp
            if (-not $np -or (Test-CheckpointPath $np)) { continue }
            if ($IgnPaths -and (Test-PathMatch $np $IgnPaths)) { continue }
            $relFiltered.Add($np)
        }
        $cleanRel = @(Sort-Ordinal $relFiltered.ToArray())
        if ($cleanRel.Count -eq 0) {
            Fail 'TREE_FP_FAIL: relevant paths resolved to empty after exclusions' 1
        }
    }
    $pathsCsv = if ($cleanRel.Count -gt 0) { $cleanRel -join ',' } else { 'ALL' }

    $effective = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::Ordinal)
    $treeRef = if ($hasTargetCommit) { $headSha } else { 'HEAD' }
    $lsArgs = @('ls-tree', '-r', $treeRef)
    if ($cleanRel.Count -gt 0) {
        $lsArgs += '--'
        $lsArgs += $cleanRel
    }
    $lsRes = Invoke-GitCommand $Root $lsArgs
    if ($lsRes.ExitCode -ne 0) {
        $detail = if ($lsRes.StdErr.Trim()) { $lsRes.StdErr.Trim() } else { $lsRes.StdOut.Trim() }
        Fail "GIT_ERROR: git ls-tree failed: $detail" 1
    }
    foreach ($rawLine in ($lsRes.StdOut -split "\r?\n")) {
        if (-not $rawLine) { continue }
        $tabIdx = $rawLine.IndexOf("`t")
        if ($tabIdx -lt 1) { continue }
        $meta = $rawLine.Substring(0, $tabIdx).Trim() -split '\s+'
        if ($meta.Count -lt 3 -or $meta[0] -cnotmatch '^[0-9]{6}$' -or ($meta[1] -cne 'blob' -and $meta[1] -cne 'commit') -or $meta[2] -cnotmatch '^[0-9a-f]{40}$') { continue }
        $p = Normalize-PathValue ($rawLine.Substring($tabIdx + 1))
        if (-not $p -or (Test-CheckpointPath $p)) { continue }
        if ($IgnPaths -and (Test-PathMatch $p $IgnPaths)) { continue }
        if ($cleanRel.Count -gt 0 -and -not (Test-PathMatch $p $cleanRel)) { continue }
        $effective[$p] = "$($meta[0]) $($meta[1]) $($meta[2])"
    }

    $indexDiv = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::Ordinal)
    if (-not $hasTargetCommit) {
        $fmRes = Invoke-GitCommand $Root @('config', '--bool', 'core.filemode')
        $isWinOs = ($env:OS -eq 'Windows_NT')
        $coreFilemode = if ($fmRes.ExitCode -eq 0) {
            ($fmRes.StdOut.Trim() -ceq 'true')
        } else {
            (-not $isWinOs)
        }

        $scopeSuffix = if ($cleanRel.Count -gt 0) { @('--') + $cleanRel } else { @('--') }
        $hdRes = Invoke-GitCommand $Root (@('diff', '--no-ext-diff', '--raw', '--no-renames', '--no-abbrev', '--ignore-submodules=none', 'HEAD') + $scopeSuffix)
        if ($hdRes.ExitCode -ne 0) {
            $detail = if ($hdRes.StdErr.Trim()) { $hdRes.StdErr.Trim() } else { $hdRes.StdOut.Trim() }
            Fail "GIT_ERROR: git diff --raw HEAD failed: $detail" 1
        }
        $caRes = Invoke-GitCommand $Root (@('diff', '--no-ext-diff', '--cached', '--raw', '--no-renames', '--no-abbrev', '--ignore-submodules=none') + $scopeSuffix)
        if ($caRes.ExitCode -ne 0) {
            $detail = if ($caRes.StdErr.Trim()) { $caRes.StdErr.Trim() } else { $caRes.StdOut.Trim() }
            Fail "GIT_ERROR: git diff --cached --raw failed: $detail" 1
        }
        $iwRes = Invoke-GitCommand $Root (@('diff', '--no-ext-diff', '--raw', '--no-renames', '--no-abbrev', '--ignore-submodules=none') + $scopeSuffix)
        if ($iwRes.ExitCode -ne 0) {
            $detail = if ($iwRes.StdErr.Trim()) { $iwRes.StdErr.Trim() } else { $iwRes.StdOut.Trim() }
            Fail "GIT_ERROR: git diff --raw index-wt failed: $detail" 1
        }
        $lsUnScope = if ($cleanRel.Count -gt 0) { @('--') + $cleanRel } else { @() }
        $untracked = @(Invoke-GitPathsZ $Root (@('ls-files', '--others', '--exclude-standard', '-z') + $lsUnScope) 'names' 'GIT_ERROR')

        $headDiff = Parse-GitRawDiff $hdRes.StdOut $IgnPaths $cleanRel
        $cachedDiff = Parse-GitRawDiff $caRes.StdOut $IgnPaths $cleanRel
        $idxWtDiff = Parse-GitRawDiff $iwRes.StdOut $IgnPaths $cleanRel

        $zeroOid = '0000000000000000000000000000000000000000'
        foreach ($p in @(Sort-Ordinal @($headDiff.Keys))) {
            $entry = $headDiff[$p]
            $m = $entry.NewMode
            $oid = $entry.NewOid
            $full = Join-Path $Root ($p -replace '/', '\')
            if ($m -ceq '000000') {
                if ($effective.ContainsKey($p)) { $effective.Remove($p) }
                continue
            }
            if ($m -ceq '160000') {
                $fbOid = if ($oid -cne $zeroOid) {
                    $oid
                } elseif ($cachedDiff.ContainsKey($p) -and $cachedDiff[$p].NewMode -ceq '160000' -and $cachedDiff[$p].NewOid -cne $zeroOid) {
                    $cachedDiff[$p].NewOid
                } else {
                    ''
                }
                $subVal = Get-SubmoduleEntryIdentity $Root $p $fbOid
                if ($subVal) {
                    $effective[$p] = $subVal
                } elseif ($effective.ContainsKey($p)) {
                    $effective.Remove($p)
                }
                continue
            }
            if ($m -ceq '120000') {
                if ($oid -cne $zeroOid) {
                    $effective[$p] = "120000 blob $oid"
                } elseif ($cachedDiff.ContainsKey($p) -and $cachedDiff[$p].NewMode -ceq '120000' -and $cachedDiff[$p].NewOid -cne $zeroOid -and (-not $idxWtDiff.ContainsKey($p))) {
                    $effective[$p] = "120000 blob $($cachedDiff[$p].NewOid)"
                } else {
                    $lSha = Get-SymlinkBlobOid $Root $p
                    if ($lSha) {
                        $effective[$p] = "120000 blob $lSha"
                    } elseif ($effective.ContainsKey($p)) {
                        $effective.Remove($p)
                    }
                }
                continue
            }
            if ($oid -cne $zeroOid) {
                $effective[$p] = "$m blob $oid"
            } elseif ($cachedDiff.ContainsKey($p) -and $cachedDiff[$p].NewMode -ceq $m -and $cachedDiff[$p].NewOid -cne $zeroOid -and (-not $idxWtDiff.ContainsKey($p))) {
                $effective[$p] = "$m blob $($cachedDiff[$p].NewOid)"
            } elseif (Test-Path -LiteralPath $full -PathType Leaf) {
                $wRes = Invoke-GitCommand $Root @('hash-object', '--', $p)
                $wSha = $wRes.StdOut.Trim()
                if ($wRes.ExitCode -ne 0 -or $wSha -notmatch '^[0-9a-f]{40}$') {
                    $detail = if ($wRes.StdErr.Trim()) { $wRes.StdErr.Trim() } else { $wSha }
                    Fail "GIT_ERROR: git hash-object failed for ${p}: $detail" 1
                }
                $effective[$p] = "$m blob $wSha"
            } elseif ($effective.ContainsKey($p)) {
                $effective.Remove($p)
            }
        }

        foreach ($p in @(Sort-Ordinal $untracked)) {
            if (-not $p -or (Test-CheckpointPath $p)) { continue }
            if ($IgnPaths -and (Test-PathMatch $p $IgnPaths)) { continue }
            if ($cleanRel.Count -gt 0 -and -not (Test-PathMatch $p $cleanRel)) { continue }
            if ($headDiff.ContainsKey($p) -and $headDiff[$p].NewMode -cne '000000') { continue }
            $full = Join-Path $Root ($p -replace '/', '\')
            $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
            if ($item -and (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -and ((-not $item.PSObject.Properties['LinkType']) -or ($item.LinkType -ceq 'SymbolicLink'))) {
                $lSha = Get-SymlinkBlobOid $Root $p
                if ($lSha) { $effective[$p] = "120000 blob $lSha" }
            } elseif (Test-Path -LiteralPath $full -PathType Leaf) {
                $wRes = Invoke-GitCommand $Root @('hash-object', '--', $p)
                $wSha = $wRes.StdOut.Trim()
                if ($wRes.ExitCode -ne 0 -or $wSha -notmatch '^[0-9a-f]{40}$') {
                    $detail = if ($wRes.StdErr.Trim()) { $wRes.StdErr.Trim() } else { $wSha }
                    Fail "GIT_ERROR: git hash-object failed for ${p}: $detail" 1
                }
                $uMode = '100644'
                if ($coreFilemode -and (-not $isWinOs) -and (Get-Command test -ErrorAction SilentlyContinue)) {
                    & test -x $full 2>$null
                    if ($LASTEXITCODE -eq 0) { $uMode = '100755' }
                }
                $effective[$p] = "$uMode blob $wSha"
            } elseif ((Test-Path -LiteralPath $full -PathType Container) -and (Test-Path -LiteralPath (Join-Path $full '.git'))) {
                $subVal = Get-SubmoduleEntryIdentity $Root $p ''
                if ($subVal) { $effective[$p] = $subVal }
            }
        }

        foreach ($p in @(Sort-Ordinal @($cachedDiff.Keys))) {
            $c = $cachedDiff[$p]
            $hasEff = $effective.ContainsKey($p)
            $cType = Get-GitEntryType $c.NewMode
            $cEntry = "$($c.NewMode) $cType $($c.NewOid)"
            if (($c.NewMode -ceq '000000' -and $hasEff) -or
                ($c.NewMode -cne '000000' -and ((-not $hasEff) -or ($effective[$p] -cne $cEntry)))) {
                $indexDiv[$p] = $cEntry
            }
        }
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("PATHS=$pathsCsv`n")
    foreach ($ep in @(Sort-Ordinal @($effective.Keys))) {
        [void]$sb.Append("E $($effective[$ep]) $ep`n")
    }
    foreach ($ip in @(Sort-Ordinal @($indexDiv.Keys))) {
        [void]$sb.Append("I $($indexDiv[$ip]) $ip`n")
    }

    $treeHash = Invoke-GitTextHash $Root ($sb.ToString()) 'GIT_ERROR' 'manifest failed'
    return @{ HeadSha = $headSha; TreeHash = $treeHash; PathsCsv = $pathsCsv }
}

function Test-VerifyReceipt([string]$Root, [string]$ReceiptArg, [string[]]$IgnPaths, [string]$ExpectedCmdArg = '', [string]$ReqRelPathsArg = '', [string]$TargetCommitSha = '') {
    $trimArg = $ReceiptArg.Trim()
    if (-not $trimArg) {
        return @{ Code = 1; Message = 'VERIFY_MISSING: empty receipt path' }
    }
    $recSpec = Test-ContainedRepoPath $Root $trimArg
    if (-not $recSpec) {
        return @{ Code = 1; Message = 'VERIFY_CORRUPT: invalid receipt_path' }
    }
    $fullReceipt = $recSpec.Full
    $dispPath = $recSpec.Rel
    if (-not (Test-Path -LiteralPath $fullReceipt -PathType Leaf)) {
        return @{ Code = 1; Message = "VERIFY_MISSING: $dispPath" }
    }

    $rawText = [IO.File]::ReadAllText($fullReceipt)
    $kv = @{}
    foreach ($rawLine in ($rawText -split "\r?\n")) {
        $ln = $rawLine.Trim()
        if (-not $ln) { continue }
        $eqIdx = $ln.IndexOf('=')
        if ($eqIdx -lt 1) {
            return @{ Code = 1; Message = 'VERIFY_CORRUPT: malformed line in receipt' }
        }
        $k = $ln.Substring(0, $eqIdx).Trim()
        $v = $ln.Substring($eqIdx + 1).Trim()
        if ($kv.ContainsKey($k)) {
            return @{ Code = 1; Message = "VERIFY_CORRUPT: duplicate field '$k'" }
        }
        $kv[$k] = $v
    }

    foreach ($reqKey in @('schema', 'task_id', 'scope', 'head_sha', 'tree_hash', 'relevant_paths', 'exit_code', 'status', 'command', 'log_path', 'timestamp_utc')) {
        if (-not $kv.ContainsKey($reqKey) -or -not $kv[$reqKey]) {
            return @{ Code = 1; Message = "VERIFY_CORRUPT: missing field '$reqKey'" }
        }
    }
    if ($kv['schema'] -cne 'b3-verify-v1') {
        return @{ Code = 1; Message = "VERIFY_CORRUPT: unsupported schema '$($kv['schema'])'" }
    }
    if ($kv['head_sha'] -cnotmatch '^[0-9a-f]{40}$') {
        return @{ Code = 1; Message = 'VERIFY_CORRUPT: invalid head_sha' }
    }
    if ($kv['tree_hash'] -cnotmatch '^[0-9a-f]{40}$') {
        return @{ Code = 1; Message = 'VERIFY_CORRUPT: invalid tree_hash' }
    }
    if ($kv['exit_code'] -notmatch '^-?[0-9]{1,9}$') {
        return @{ Code = 1; Message = 'VERIFY_CORRUPT: invalid exit_code' }
    }
    if ($kv['status'] -cnotin @('PASS', 'FAIL')) {
        return @{ Code = 1; Message = "VERIFY_CORRUPT: invalid status '$($kv['status'])'" }
    }
    if ($kv['timestamp_utc'] -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$') {
        return @{ Code = 1; Message = 'VERIFY_CORRUPT: invalid timestamp_utc' }
    }
    if ($kv.ContainsKey('duration_ms')) {
        if ($kv['duration_ms'] -cnotmatch '^[0-9]+$') {
            return @{ Code = 1; Message = 'VERIFY_CORRUPT: invalid duration_ms' }
        }
    }
    if ($kv['log_path'] -cne 'none') {
        $lpSlash = $kv['log_path'].Trim() -replace '\\', '/'
        if (-not $lpSlash -or $lpSlash -eq '.' -or $lpSlash.StartsWith('/') -or $lpSlash.StartsWith('~') -or ($lpSlash -match '^[A-Za-z]:') -or ($lpSlash -match '(^|/)\.\.(/|$)')) {
            return @{ Code = 1; Message = 'VERIFY_CORRUPT: invalid log_path' }
        }
        $logInfo = Resolve-SafeRepoWritePath $Root $lpSlash
        if (-not $logInfo) {
            return @{ Code = 1; Message = 'VERIFY_CORRUPT: invalid log_path' }
        }
        if (-not (Test-Path -LiteralPath $logInfo.FullPath -PathType Leaf)) {
            return @{ Code = 1; Message = 'VERIFY_CORRUPT: missing log_path' }
        }
    }

    if ([int]$kv['exit_code'] -ne 0 -or $kv['status'] -cne 'PASS') {
        return @{ Code = 1; Message = "VERIFY_FAILED_RECEIPT: exit=$($kv['exit_code']) status=$($kv['status'])" }
    }

    $relSpec = @()
    if ($kv['relevant_paths'] -cne 'ALL') {
        $rawRelKv = $kv['relevant_paths'].Trim()
        if ($rawRelKv.StartsWith('[') -and $rawRelKv.EndsWith(']')) {
            $rawRelKv = $rawRelKv.Substring(1, $rawRelKv.Length - 2)
        }
        if ($rawRelKv -match '[\*\?]') {
            return @{ Code = 1; Message = 'VERIFY_CORRUPT: invalid relevant_paths' }
        }
        $relSpec = @(Split-CsvList $kv['relevant_paths'] -AsPaths)
        $validRel = @($relSpec | Where-Object { $_ -and (-not (Test-CheckpointPath $_)) -and (-not ($_.Contains(':') -or $_.StartsWith('/') -or ($_ -match '(^|/)\.\.(/|$)'))) })
        if ($validRel.Count -lt 1 -or $validRel.Count -ne $relSpec.Count) {
            return @{ Code = 1; Message = 'VERIFY_CORRUPT: invalid relevant_paths' }
        }
    }

    if ($ExpectedCmdArg -and $ExpectedCmdArg.Trim()) {
        $normExpected = ($ExpectedCmdArg -replace '[\r\n]+', ' ').Trim()
        if ($kv['command'] -cne $normExpected) {
            return @{ Code = 1; Message = 'VERIFY_MISMATCH: command mismatch' }
        }
    }

    if ($ReqRelPathsArg -and $ReqRelPathsArg.Trim()) {
        $rawReqRel = $ReqRelPathsArg.Trim()
        if ($rawReqRel.StartsWith('[') -and $rawReqRel.EndsWith(']')) {
            $rawReqRel = $rawReqRel.Substring(1, $rawReqRel.Length - 2)
        }
        if ($rawReqRel -match '[\*\?]') {
            return @{ Code = 1; Message = 'VERIFY_CHECK_FAIL: invalid relevant_paths' }
        }
        $reqSpec = @(Split-CsvList $ReqRelPathsArg -AsPaths)
        $validReq = @($reqSpec | Where-Object { $_ -and (-not (Test-CheckpointPath $_)) -and (-not ($_.Contains(':') -or $_.StartsWith('/') -or ($_ -match '(^|/)\.\.(/|$)'))) })
        if ($validReq.Count -lt 1 -or $validReq.Count -ne $reqSpec.Count) {
            return @{ Code = 1; Message = 'VERIFY_CHECK_FAIL: invalid relevant_paths' }
        }
        if ($kv['relevant_paths'] -cne 'ALL') {
            $uncovered = @($validReq | Where-Object { -not (Test-PathMatch $_ $relSpec) })
            if ($uncovered.Count -gt 0) {
                $sortedUnc = (Sort-Ordinal $uncovered) -join ','
                return @{ Code = 1; Message = "VERIFY_SCOPE_MISMATCH: uncovered path ($sortedUnc)" }
            }
        }
    }

    $targetTrim = if ($TargetCommitSha) { $TargetCommitSha.Trim() } else { '' }
    $fpCall = Invoke-CapturedGuardCall { Get-TreeFingerprint $Root $relSpec $IgnPaths $targetTrim }
    if (-not $fpCall.Ok -or $null -eq $fpCall.Result) {
        $errOut = if ($fpCall.Message) { $fpCall.Message } else { 'TREE_FP_FAIL: fingerprint failed' }
        return @{ Code = 1; Message = $errOut }
    }
    $cur = $fpCall.Result
    if ($targetTrim) {
        if ($cur.HeadSha -cne $kv['head_sha']) {
            $recHeadShort = $kv['head_sha'].Substring(0, 12)
            $curHeadShort = $cur.HeadSha.Substring(0, 12)
            return @{ Code = 2; Message = "VERIFY_STALE: head_sha=$recHeadShort target=$curHeadShort" }
        }
    } elseif ($cur.HeadSha -cne $kv['head_sha']) {
        $ancRes = Invoke-GitCommand $Root @('merge-base', '--is-ancestor', $kv['head_sha'], $cur.HeadSha)
        if ($ancRes.ExitCode -ne 0) {
            $recShort = $kv['tree_hash'].Substring(0, 12)
            $curShort = $cur.TreeHash.Substring(0, 12)
            return @{ Code = 2; Message = "VERIFY_STALE: receipt=$recShort current=$curShort" }
        }
    }
    if ($cur.TreeHash -cne $kv['tree_hash']) {
        $recShort = $kv['tree_hash'].Substring(0, 12)
        $curShort = $cur.TreeHash.Substring(0, 12)
        return @{ Code = 2; Message = "VERIFY_STALE: receipt=$recShort current=$curShort" }
    }

    $shortTree = $kv['tree_hash'].Substring(0, 12)
    return @{ Code = 0; Message = "VERIFY_VALID: task=$($kv['task_id']) scope=$($kv['scope']) tree=$shortTree"; RelevantPathsCsv = $kv['relevant_paths'] }
}

function Test-TestPath([string]$PathVal) {
    return ($PathVal -match '(?i)(^|/)(tests?|__tests__)/|\.(test|spec)\.')
}

function Test-CodePath([string]$PathVal) {
    return ($PathVal -match '\.(js|jsx|ts|tsx|mjs|cjs|py|go|cs|java|rs|ps1|sh)$')
}

function Find-DestructiveSql([string]$Line) {
    return ($Line -match '(?i)\b(DROP\s+TABLE|DROP\s+DATABASE|TRUNCATE\s+TABLE)\b')
}

$script:SkipSymbolNames = @('main', 'init', 'constructor', 'render', 'setup', 'teardown', 'default', 'handler', 'index', 'test', 'describe')

function Extract-SymbolDecl([string]$FilePath, [string]$LineBody) {
    $norm = $FilePath.ToLowerInvariant()
    if ($norm -notmatch '(\.[a-z0-9]+)$') { return $null }
    $ext = $Matches[1]
    $symName = $null
    $isExp = $false

    switch ($ext) {
        { $_ -in @('.js', '.jsx', '.ts', '.tsx', '.mjs', '.cjs') } {
            if ($LineBody -cmatch '^[ \t]*(export[ \t]+)?(?:default[ \t]+)?(?:async[ \t]+)?(?:function|class|interface|type)[ \t]+([A-Za-z_][A-Za-z0-9_]{2,})') {
                $isExp = [bool]$Matches[1]
                $symName = $Matches[2]
            } elseif ($LineBody -cmatch '^[ \t]*(export[ \t]+)?(?:const|let)[ \t]+([A-Za-z_][A-Za-z0-9_]{2,})[ \t]*=[ \t]*(?:async[ \t]+)?(?:\([^)]*\)[ \t]*=>|function([^a-zA-Z0-9_]|$))') {
                $isExp = [bool]$Matches[1]
                $symName = $Matches[2]
            }
        }
        '.py' {
            if ($LineBody -cmatch '^[ \t]*(?:async[ \t]+)?(?:def|class)[ \t]+([A-Za-z_][A-Za-z0-9_]{2,})') {
                $symName = $Matches[1]
                $isExp = -not $symName.StartsWith('_')
            }
        }
        '.go' {
            if ($LineBody -cmatch '^func[ \t]+(?:\([^)]+\)[ \t]+)?([A-Za-z_][A-Za-z0-9_]{2,})[ \t]*\(') {
                $symName = $Matches[1]
                $isExp = ($symName.Substring(0, 1) -cmatch '^[A-Z]$')
            } elseif ($LineBody -cmatch '^type[ \t]+([A-Za-z_][A-Za-z0-9_]{2,})[ \t]+') {
                $symName = $Matches[1]
                $isExp = ($symName.Substring(0, 1) -cmatch '^[A-Z]$')
            }
        }
        { $_ -in @('.cs', '.java') } {
            if ($LineBody -cmatch '^[ \t]*(public|private|internal|protected)[ \t]+(?:(?:static|async|virtual|override|sealed|abstract)[ \t]+)*(?:class|interface|struct|record|enum)[ \t]+([A-Za-z_][A-Za-z0-9_]{2,})') {
                $symName = $Matches[2]
                $isExp = ($Matches[1] -ceq 'public')
            }
        }
        '.rs' {
            if ($LineBody -cmatch '^[ \t]*(pub(?:\([^)]*\))?[ \t]+)?(?:async[ \t]+)?(?:fn|struct|enum|trait)[ \t]+([A-Za-z_][A-Za-z0-9_]{2,})') {
                $isExp = [bool]$Matches[1]
                $symName = $Matches[2]
            }
        }
        { $_ -in @('.ps1', '.sh') } {
            if ($LineBody -cmatch '^[ \t]*function[ \t]+([A-Za-z_][A-Za-z0-9_-]{2,})') {
                $symName = $Matches[1]
                $isExp = $false
            } elseif ($ext -eq '.sh' -and $LineBody -cmatch '^([A-Za-z_][A-Za-z0-9_]{2,})\(\)[ \t]*\{') {
                $symName = $Matches[1]
                $isExp = $false
            }
        }
    }

    if (-not $symName) { return $null }
    if ($script:SkipSymbolNames -ccontains $symName) { return $null }
    return @{ Name = $symName; Exported = $isExp }
}

function Get-CanonicalGitPath([string]$Dir, [string]$RevFlag) {
    $res = Invoke-GitCommand $Dir @('rev-parse', $RevFlag)
    $gd = $res.StdOut.Trim()
    if ($res.ExitCode -ne 0 -or -not $gd) { return $null }
    $resolved = Resolve-TargetPath $Dir $gd
    if (-not $resolved) { return $null }
    return (Normalize-PathValue $resolved)
}

function Get-CanonicalGitCommonDir([string]$Dir) {
    return (Get-CanonicalGitPath $Dir '--git-common-dir')
}

function Get-CanonicalGitDir([string]$Dir) {
    return (Get-CanonicalGitPath $Dir '--git-dir')
}

function Normalize-LogicalPath([string]$RawPath) {
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RawPath)
    $baseRoot = [IO.Path]::GetPathRoot($resolved)
    if ($resolved -eq '/' -or $resolved -eq '\') {
        return '/'
    } elseif ($resolved -match '^([A-Za-z]:)[\\/]?$') {
        return "$($Matches[1])\"
    } elseif (-not ($baseRoot -and $resolved.Equals($baseRoot, [System.StringComparison]::OrdinalIgnoreCase))) {
        $trimmed = $resolved.TrimEnd('\', '/')
        if (-not $trimmed) { return '/' }
        return $trimmed
    }
    return $resolved
}

function Find-ReparseInPathHierarchy([string]$AbsPath) {
    if (-not $AbsPath) { return $null }
    $clean = $AbsPath.TrimEnd('\', '/')
    if (-not $clean) { return $null }
    if ($clean -match '^[A-Za-z]:$') { return $null }
    $root = [IO.Path]::GetPathRoot($clean)
    if ($root -and $clean.Equals($root.TrimEnd('\', '/'), [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }
    $relPart = if ($root) { $clean.Substring($root.Length).TrimStart('\', '/') } else { $clean.TrimStart('\', '/') }
    $cur = if ($root) { $root } else { [string][IO.Path]::DirectorySeparatorChar }
    $isMac = ($IsMacOS -eq $true)
    foreach ($seg in ($relPart -split '[\\/]')) {
        if (-not $seg -or $seg -eq '.') { continue }
        $cur = Join-Path $cur $seg
        if ($isMac -and ($cur -ceq '/var' -or $cur -ceq '/tmp')) {
            continue
        }
        if (Test-IsReparsePath $cur) {
            return $cur
        }
    }
    return $null
}

function Resolve-SafeWorktreeIdentity([string]$RawPath, [string]$MissingCode, [string]$NotGitCode, [switch]$RequireHead) {
    $logical = Normalize-LogicalPath $RawPath
    $reparseHit = Find-ReparseInPathHierarchy $logical
    if ($reparseHit) {
        Fail "WORKTREE_UNSAFE: unsafe_reparse_root($reparseHit)" 2
    }
    if (-not (Test-Path -LiteralPath $logical -PathType Container)) {
        Fail "WORKTREE_UNSAFE: ${MissingCode}($RawPath)" 2
    }
    $dotGit = Join-Path $logical '.git'
    if (Test-IsReparsePath $dotGit) {
        Fail "WORKTREE_UNSAFE: unsafe_reparse_root($dotGit)" 2
    }
    $topRes = Invoke-GitCommand $logical @('rev-parse', '--show-toplevel')
    $topRaw = $topRes.StdOut.Trim()
    if ($topRes.ExitCode -ne 0 -or -not $topRaw) {
        if ($NotGitCode -ceq 'not_a_git_repo') {
            Fail 'WORKTREE_UNSAFE: not_a_git_repo' 2
        }
        Fail "WORKTREE_UNSAFE: ${NotGitCode}($RawPath)" 2
    }
    $headRaw = ''
    if ($RequireHead) {
        $headRes = Invoke-GitCommand $logical @('rev-parse', 'HEAD')
        $headRaw = $headRes.StdOut.Trim()
        if ($headRes.ExitCode -ne 0 -or $headRaw -cnotmatch '\A[0-9a-f]{40}\z') {
            Fail 'WORKTREE_UNSAFE: unborn_or_invalid_head' 2
        }
    }
    $topResolved = Resolve-TargetPath $logical $topRaw
    $topFull = Normalize-LogicalPath $topResolved
    $topReparseHit = Find-ReparseInPathHierarchy $topFull
    if ($topReparseHit) {
        Fail "WORKTREE_UNSAFE: unsafe_reparse_root($topReparseHit)" 2
    }
    $topDotGit = Join-Path $topFull '.git'
    if (Test-IsReparsePath $topDotGit) {
        Fail "WORKTREE_UNSAFE: unsafe_reparse_root($topDotGit)" 2
    }
    $topNorm = Normalize-PathValue $topFull
    $commonDir = Get-CanonicalGitCommonDir $logical
    $gitDir = Get-CanonicalGitDir $logical
    if (-not $commonDir -or -not $gitDir) {
        if ($NotGitCode -ceq 'not_a_git_repo') {
            Fail 'WORKTREE_UNSAFE: not_a_git_repo' 2
        }
        Fail "WORKTREE_UNSAFE: ${NotGitCode}($RawPath)" 2
    }
    return @{
        Logical = $logical
        TopFull = $topFull
        TopNorm = $topNorm
        CommonDir = $commonDir
        GitDir = $gitDir
        Head = $headRaw
    }
}

function Get-TShirtSize([int]$FilesCount, [int]$LinesCount) {
    if ($FilesCount -eq 0) { return 'NOISE_ONLY' }
    if ($FilesCount -le 3 -and $LinesCount -le 100) { return 'XS' }
    if ($FilesCount -le 8 -and $LinesCount -le 300) { return 'S' }
    if ($FilesCount -le 20 -and $LinesCount -le 800) { return 'M' }
    if ($FilesCount -lt 50 -and $LinesCount -lt 2000) { return 'L' }
    if ($FilesCount -le 100 -and $LinesCount -le 5000) { return 'XL' }
    return 'XXL'
}

function Normalize-SizeClass([string]$RawSize) {
    if (-not $RawSize) { return $null }
    $u = $RawSize.Trim().ToUpperInvariant()
    switch ($u) {
        'SMALL' { return 'S' }
        'MEDIUM' { return 'M' }
        'LARGE' { return 'L' }
        'VERY_LARGE' { return 'XL' }
        'XS' { return 'XS' }
        'S' { return 'S' }
        'M' { return 'M' }
        'L' { return 'L' }
        'XL' { return 'XL' }
        'XXL' { return 'XXL' }
        'NOISE_ONLY' { return 'NOISE_ONLY' }
        'CLEAN_AFTER_FIX' { return 'CLEAN_AFTER_FIX' }
        'EMPTY_DIFF' { return 'EMPTY_DIFF' }
        default { return $null }
    }
}

function Test-DocOrAssetPath([string]$PathVal) {
    $low = $PathVal.ToLowerInvariant()
    if ($low -match '(^|/)evals/.*\.ya?ml$') { return $true }
    return ($low -match '\.(md|mdx|txt|rst|adoc|png|jpg|jpeg|gif|svg|ico|woff|woff2|ttf|eot|pdf)$')
}

function Test-GeneratedCodePath([string]$PathVal) {
    return ($PathVal.ToLowerInvariant() -match '\.generated\.|\.pb\.|(^|/)(generated|gen)(/|$)|\.(g|designer)\.cs$')
}

function Test-ContractPath([string]$PathVal) {
    $low = $PathVal.ToLowerInvariant()
    if ((Test-DocOrAssetPath $low) -or (Test-TestPath $low) -or (Test-NoiseFile $low)) { return $false }
    return ($low -match '(^|/)(openapi|swagger|proto|graphql|contracts?|schemas?|interfaces?|shared-types|api-types)(/|$|\.)|\.(proto|graphql|gql|sql)$|(^|/)(package\.json|pnpm-workspace\.yaml|go\.mod|cargo\.toml|pyproject\.toml)$|\.(csproj|sln)$')
}

function Get-RawModuleGroup([string]$PathVal) {
    if ($PathVal -match '^([^/]+)/([^/]+)/') {
        return "$($Matches[1])/$($Matches[2])"
    }
    if ($PathVal -match '^([^/]+)/') {
        return $Matches[1]
    }
    return 'root'
}

function Add-SignalTag([System.Collections.Hashtable]$Map, [string]$PathKey, [string]$Tag) {
    if (-not $Map.ContainsKey($PathKey)) {
        $Map[$PathKey] = New-Object System.Collections.Generic.List[string]
    }
    if (-not $Map[$PathKey].Contains($Tag)) {
        [void]$Map[$PathKey].Add($Tag)
    }
}

function Scan-PathRiskSignals([System.Collections.Hashtable]$Map, [string]$PathVal) {
    $low = $PathVal.ToLowerInvariant()
    if (Test-GeneratedCodePath $low) { Add-SignalTag $Map $PathVal 'generated_code' }
    if ((Test-DocOrAssetPath $low) -or (Test-TestPath $low)) { return }
    if ((Test-SecretPath $low) -or ($low -match '(^|/)(auth|authn|authz|oauth|oidc|jwt|rbac|acl|sessions?|security|crypto|cipher|secrets?|tokens?|credentials?|permissions?|polic(y|ies))(/|$|[^/]*\.)')) {
        Add-SignalTag $Map $PathVal 'auth_security'
    }
    if ($low -match '(^|/)(b3-guard|install[^/]*|sync[^/]*)\.(ps1|sh)$') {
        Add-SignalTag $Map $PathVal 'fs_git_security'
    }
    if ($low -match '(^|/)(migrations?|schema|prisma|alembic|flyway|liquibase|db|database|persistence|repositories|efcore)(/|$)|\.sql$') {
        Add-SignalTag $Map $PathVal 'db_migration_tx'
    }
    if ($low -match '(^|/)(openapi|swagger|proto|graphql|contracts?|api|routes?|controllers?|endpoints?|schemas?|interfaces?|public)(/|$)|\.(proto|graphql|gql)$|(^|/)(contracts?|shared-types|api-types)\.[^/]+$') {
        Add-SignalTag $Map $PathVal 'public_api_contract'
    }
    if ($low -match '(^|/)(cache|redis|queue|worker|lock|mutex|concurrency|scheduler|state|store)(/|$)') {
        Add-SignalTag $Map $PathVal 'concurrency_state_cache'
    }
    if ($low -match '(^|/)(render|renderer|shader|three|canvas|scene|webgl|engine|query|queries|indexer|serializer|stream)(/|$)') {
        Add-SignalTag $Map $PathVal 'perf_hot_path'
    }
}

function Scan-LineRiskSignals([System.Collections.Hashtable]$Map, [string]$PathVal, [string]$LineLower) {
    if ($LineLower -match 'verifytoken|jwt\.|bcrypt|argon2|pbkdf2|crypto\.|\[authorize|allowanonymous|eval\(|execsync|child_process|dangerouslysetinnerhtml|rejectunauthorized[ \t]*:[ \t]*false|chmod[ \t]+777') {
        Add-SignalTag $Map $PathVal 'auth_security'
    }
    if ($LineLower -match 'git_index_file|reparsepoint|symboliclink|junction|rm[ \t]+-rf|remove-item.*-recurse|git[ \t]+push|git[ \t]+reset[ \t]+--hard') {
        Add-SignalTag $Map $PathVal 'fs_git_security'
    }
    if ($LineLower -match '(^|[^a-z0-9_])(drop[ \t]+table|drop[ \t]+database|alter[ \t]+table|truncate[ \t]+table|begin[ \t]+transaction|isolationlevel|savechanges|migrate\()') {
        Add-SignalTag $Map $PathVal 'db_migration_tx'
        if ($LineLower -match '(^|[^a-z0-9_])(drop[ \t]+table|drop[ \t]+database|truncate[ \t]+table)([^a-z0-9_]|$)') {
            Add-SignalTag $Map $PathVal '_db_destructive'
        }
    }
    if ($LineLower -match '(^|[^a-z0-9_])(mutex|semaphore|concurrentdictionary|channel<|promise\.all|abortcontroller|imemorycache|distributedcache)') {
        Add-SignalTag $Map $PathVal 'concurrency_state_cache'
    }
    if ($LineLower -match '(^|[^a-z0-9_])(useframe|requestanimationframe|instancedmesh|webglrenderer|asnotracking)') {
        Add-SignalTag $Map $PathVal 'perf_hot_path'
    }
    if ($LineLower -match '(^|[^a-z0-9_])(json\.stringify|json\.parse)') {
        Add-SignalTag $Map $PathVal '_json_serde'
    }
    if ($LineLower -match '(^|[^a-z0-9_])(for[ \t]*\(|while[ \t]*\(|foreach|readline|createreadstream|createwritestream|readable|writable|transform|stream|buffer|uint8array|arraybuffer|chunk|ndjson|jsonl|batch|bulk|maxbuffer)|\.map\(|\.flatmap\(|\.reduce\(|1024[ \t]*\*') {
        Add-SignalTag $Map $PathVal '_serde_hot_ctx'
    }
    if ($Map.ContainsKey($PathVal) -and $Map[$PathVal].Contains('_json_serde') -and $Map[$PathVal].Contains('_serde_hot_ctx')) {
        Add-SignalTag $Map $PathVal 'perf_hot_path'
    }
}

function Invoke-CollectScopeData([string]$Root, [string]$ResolvedBase, [string]$TargetCommitSha, [string[]]$IgnPaths, [string]$FailPrefix) {
    $nsArgs = if ($TargetCommitSha) {
        @('diff', '--no-ext-diff', '--no-renames', '--numstat', $ResolvedBase, $TargetCommitSha, '--')
    } else {
        @('diff', '--no-ext-diff', '--no-renames', '--numstat', $ResolvedBase, '--')
    }
    $nsRes = Invoke-GitCommand $Root $nsArgs
    if ($nsRes.ExitCode -ne 0) {
        $detail = if ($nsRes.StdErr.Trim()) { $nsRes.StdErr.Trim() } else { $nsRes.StdOut.Trim() }
        Fail ("${FailPrefix}: git diff --numstat failed: $detail") 1
    }

    $stArgs = if ($TargetCommitSha) {
        @('diff', '--no-ext-diff', '--no-renames', '--name-status', $ResolvedBase, $TargetCommitSha, '--')
    } else {
        @('diff', '--no-ext-diff', '--no-renames', '--name-status', $ResolvedBase, '--')
    }
    $stRes = Invoke-GitCommand $Root $stArgs
    if ($stRes.ExitCode -ne 0) {
        $detail = if ($stRes.StdErr.Trim()) { $stRes.StdErr.Trim() } else { $stRes.StdOut.Trim() }
        Fail ("${FailPrefix}: git diff --name-status failed: $detail") 1
    }

    $untracked = if ($TargetCommitSha) { @() } else { @(Invoke-GitLines $Root @('ls-files', '--others', '--exclude-standard')) }

    $reviewFiles = New-Object System.Collections.Generic.List[string]
    $noiseFiles = New-Object System.Collections.Generic.List[string]
    $fileLines = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::Ordinal)
    $fileSignals = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::Ordinal)
    $changeMap = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::Ordinal)
    $untrackedSet = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::Ordinal)
    $scanContentSet = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::Ordinal)
    $totalLines = 0

    foreach ($sRow in ($stRes.StdOut -split "\r?\n")) {
        $stLine = ([string]$sRow).Trim()
        if (-not $stLine) { continue }
        $sp = $stLine -split "`t", 2
        if ($sp.Count -lt 2) { continue }
        $ch = $sp[0].Substring(0, 1).ToUpperInvariant()
        if ($ch -notin @('A', 'M', 'D')) { $ch = 'M' }
        $fp = Normalize-PathValue $sp[1]
        if ($fp -and -not (Test-CheckpointPath $fp) -and -not (Test-PathMatch $fp $IgnPaths)) {
            $changeMap[$fp] = $ch
        }
    }

    foreach ($row in ($nsRes.StdOut -split "\r?\n")) {
        $lineStr = ([string]$row).Trim()
        if (-not $lineStr) { continue }
        $parts = $lineStr -split "`t", 3
        if ($parts.Count -lt 3) { continue }
        $p = Normalize-PathValue $parts[2]
        if (-not $p -or (Test-CheckpointPath $p) -or (Test-PathMatch $p $IgnPaths)) { continue }
        Scan-PathRiskSignals $fileSignals $p
        if (Test-NoiseFile $p) {
            if (-not $noiseFiles.Contains($p)) { $noiseFiles.Add($p) }
            continue
        }
        if (-not $reviewFiles.Contains($p)) { $reviewFiles.Add($p) }
        $fLc = 0
        if ($parts[0] -match '^\d+$') { $fLc += [int]$parts[0] }
        if ($parts[1] -match '^\d+$') { $fLc += [int]$parts[1] }
        $fileLines[$p] = $fLc
        $totalLines += $fLc
        if (-not ((Test-DocOrAssetPath $p) -or (Test-TestPath $p))) {
            $scanContentSet[$p] = $true
        }
    }

    foreach ($u in $untracked) {
        if (-not $u -or (Test-CheckpointPath $u) -or (Test-PathMatch $u $IgnPaths)) { continue }
        Scan-PathRiskSignals $fileSignals $u
        if (Test-NoiseFile $u) {
            if (-not $noiseFiles.Contains($u)) { $noiseFiles.Add($u) }
            continue
        }
        if (-not $reviewFiles.Contains($u)) {
            $reviewFiles.Add($u)
            $untrackedSet[$u] = $true
            $changeMap[$u] = 'U'
            $full = Join-Path $Root ($u -replace '/', '\')
            $fLc = 0
            if ((Test-Path -LiteralPath $full -PathType Leaf) -and -not (Test-BinaryFile $full)) {
                $isTextCode = -not ((Test-DocOrAssetPath $u) -or (Test-TestPath $u))
                $linesArr = [IO.File]::ReadAllLines($full)
                $fLc = $linesArr.Length
                if ($isTextCode) {
                    foreach ($uln in $linesArr) {
                        Scan-LineRiskSignals $fileSignals $u ($uln.ToLowerInvariant())
                    }
                }
            }
            $fileLines[$u] = $fLc
            $totalLines += $fLc
        }
    }

    if ($scanContentSet.Count -gt 0) {
        $dArgs = if ($TargetCommitSha) {
            @('diff', '--no-ext-diff', '--no-renames', '-U0', $ResolvedBase, $TargetCommitSha, '--')
        } else {
            @('diff', '--no-ext-diff', '--no-renames', '-U0', $ResolvedBase, '--')
        }
        $dRes = Invoke-GitCommand $Root $dArgs
        if ($dRes.ExitCode -ne 0) {
            $detail = if ($dRes.StdErr.Trim()) { $dRes.StdErr.Trim() } else { $dRes.StdOut.Trim() }
            Fail ("${FailPrefix}: git diff -U0 failed: $detail") 1
        }
        if ($dRes.StdOut) {
            $hdrOldPath = ''
            $curPath = ''
            $curScan = $false
            $inHunk = $false
            foreach ($dl in ($dRes.StdOut -split "\r?\n")) {
                if ($dl.StartsWith('diff --git ')) {
                    $hdrOldPath = ''; $curPath = ''; $curScan = $false; $inHunk = $false
                    continue
                }
                if (-not $inHunk) {
                    if ($dl.StartsWith('--- ')) {
                        $hdrOldPath = if ($dl -cne '--- /dev/null' -and $dl.Length -gt 6) { Normalize-PathValue ($dl.Substring(6)) } else { '' }
                        continue
                    }
                    if ($dl.StartsWith('+++ ')) {
                        if ($dl -cne '+++ /dev/null' -and $dl.Length -gt 6) {
                            $curPath = Normalize-PathValue ($dl.Substring(6))
                        } else {
                            $curPath = $hdrOldPath
                        }
                        $curScan = ($curPath -and $scanContentSet.ContainsKey($curPath))
                        continue
                    }
                    if ($dl.StartsWith('@@ ')) {
                        $inHunk = $true
                        continue
                    }
                    continue
                }
                if ($dl.StartsWith('@@ ')) {
                    continue
                }
                if ($curScan -and $curPath -and ($dl.StartsWith('+') -or $dl.StartsWith('-'))) {
                    Scan-LineRiskSignals $fileSignals $curPath ($dl.Substring(1).ToLowerInvariant())
                }
            }
        }
    }

    $cntA = 0; $cntM = 0; $cntD = 0; $cntU = 0
    foreach ($rf in $reviewFiles) {
        $ct = if ($changeMap.ContainsKey($rf)) { $changeMap[$rf] } else { 'M' }
        switch ($ct) {
            'A' { $cntA++ }
            'D' { $cntD++ }
            'U' { $cntU++ }
            default { $cntM++ }
        }
    }

    $sortedRev = if ($reviewFiles.Count -gt 0) { @(Sort-Ordinal $reviewFiles.ToArray()) } else { @() }
    $sortedNoise = if ($noiseFiles.Count -gt 0) { @(Sort-Ordinal $noiseFiles.ToArray()) } else { @() }
    return @{
        ReviewFiles = $sortedRev
        NoiseFiles = $sortedNoise
        FileLines = $fileLines
        FileSignals = $fileSignals
        TotalLines = $totalLines
        ChangeTypes = "A:$cntA,M:$cntM,D:$cntD,U:$cntU"
        UntrackedSet = $untrackedSet
    }
}

function Eval-RiskForSubset([string[]]$PathsList, [System.Collections.Hashtable]$FileSignalsMap, [System.Collections.Hashtable]$FileLinesMap) {
    $sigs = New-Object System.Collections.Generic.List[string]
    $hasDestructive = $false
    $codeGroups = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::Ordinal)
    $hasContractSig = $false
    $codeFileCnt = 0
    $codeLineCnt = 0

    foreach ($p in @($PathsList)) {
        if (-not $p) { continue }
        if ($FileSignalsMap -and $FileSignalsMap.ContainsKey($p)) {
            foreach ($s in @($FileSignalsMap[$p])) {
                if ($s -ceq '_db_destructive') { $hasDestructive = $true; continue }
                if ($s.StartsWith('_', [System.StringComparison]::Ordinal)) { continue }
                if (-not $sigs.Contains($s)) { [void]$sigs.Add($s) }
                if ($s -ceq 'public_api_contract' -or $s -ceq 'db_migration_tx') { $hasContractSig = $true }
            }
        } else {
            $tmpMap = @{}
            Scan-PathRiskSignals $tmpMap $p
            if ($tmpMap.ContainsKey($p)) {
                foreach ($s in @($tmpMap[$p])) {
                    if ($s -ceq '_db_destructive') { $hasDestructive = $true; continue }
                    if ($s.StartsWith('_', [System.StringComparison]::Ordinal)) { continue }
                    if (-not $sigs.Contains($s)) { [void]$sigs.Add($s) }
                    if ($s -ceq 'public_api_contract' -or $s -ceq 'db_migration_tx') { $hasContractSig = $true }
                }
            }
        }
        if (-not ((Test-DocOrAssetPath $p) -or (Test-TestPath $p) -or (Test-GeneratedCodePath $p) -or (Test-NoiseFile $p))) {
            $grp = Get-RawModuleGroup $p
            $codeGroups[$grp] = $true
            if ((Test-CodePath $p) -or (Test-ContractPath $p)) {
                $codeFileCnt++
                if ($FileLinesMap -and $FileLinesMap.ContainsKey($p)) { $codeLineCnt += [int]$FileLinesMap[$p] }
            }
        }
    }

    $crossHigh = $false
    if ($codeGroups.Count -ge 4 -and $hasContractSig) {
        if (-not $sigs.Contains('cross_module_blast')) { [void]$sigs.Add('cross_module_blast') }
        $crossHigh = $true
    } elseif ($codeGroups.Count -ge 3) {
        if (-not $sigs.Contains('cross_module_blast')) { [void]$sigs.Add('cross_module_blast') }
    }

    $maxSev = 1
    $specs = New-Object System.Collections.Generic.List[string]
    foreach ($s in $sigs) {
        switch ($s) {
            'auth_security' {
                if ($maxSev -lt 4) { $maxSev = 4 }
                if (-not $specs.Contains('b3-security-reviewer')) { [void]$specs.Add('b3-security-reviewer') }
            }
            'fs_git_security' {
                if ($maxSev -lt 4) { $maxSev = 4 }
                if (-not $specs.Contains('b3-security-reviewer')) { [void]$specs.Add('b3-security-reviewer') }
            }
            'db_migration_tx' {
                $dbSev = if ($hasDestructive) { 4 } else { 3 }
                if ($maxSev -lt $dbSev) { $maxSev = $dbSev }
                if (-not $specs.Contains('b3-architecture-reviewer')) { [void]$specs.Add('b3-architecture-reviewer') }
                if ($hasDestructive -and -not $specs.Contains('b3-security-reviewer')) { [void]$specs.Add('b3-security-reviewer') }
            }
            'public_api_contract' {
                if ($maxSev -lt 3) { $maxSev = 3 }
                if (-not $specs.Contains('b3-architecture-reviewer')) { [void]$specs.Add('b3-architecture-reviewer') }
            }
            'concurrency_state_cache' {
                if ($maxSev -lt 3) { $maxSev = 3 }
                if (-not $specs.Contains('b3-architecture-reviewer')) { [void]$specs.Add('b3-architecture-reviewer') }
                if (-not $specs.Contains('b3-performance-reviewer')) { [void]$specs.Add('b3-performance-reviewer') }
            }
            'perf_hot_path' {
                if ($maxSev -lt 3) { $maxSev = 3 }
                if (-not $specs.Contains('b3-performance-reviewer')) { [void]$specs.Add('b3-performance-reviewer') }
            }
            'generated_code' {
                if ($maxSev -lt 2) { $maxSev = 2 }
            }
            'cross_module_blast' {
                $cSev = if ($crossHigh) { 3 } else { 2 }
                if ($maxSev -lt $cSev) { $maxSev = $cSev }
                if ($crossHigh -and -not $specs.Contains('b3-architecture-reviewer')) { [void]$specs.Add('b3-architecture-reviewer') }
            }
        }
    }

    if ($maxSev -lt 2 -and ($codeFileCnt -gt 1 -or $codeLineCnt -gt 100)) {
        if (-not $sigs.Contains('general_code_change')) { [void]$sigs.Add('general_code_change') }
        $maxSev = 2
    }

    $riskLabel = switch ($maxSev) {
        4 { 'CRITICAL' }
        3 { 'HIGH' }
        2 { 'MEDIUM' }
        default { 'LOW' }
    }
    $sigOut = if ($sigs.Count -gt 0) { (Sort-Ordinal $sigs.ToArray()) -join ',' } else { 'none' }
    $specOut = if ($specs.Count -gt 0) { (Sort-Ordinal $specs.ToArray()) -join ',' } else { 'none' }
    return @{
        RiskLevel = $riskLabel
        RiskSignals = $sigOut
        RecommendedSpecialists = $specOut
    }
}

function Test-IsOversizedUnit([int]$FilesCnt, [int]$LinesCnt) {
    return ($LinesCnt -gt 5000 -or ($FilesCnt -gt 100 -and $LinesCnt -gt 1000))
}

function Get-UnitMetrics([hashtable]$GrpEntry, [hashtable]$FileLines, [hashtable]$FileSignals) {
    $filesSorted = @(Sort-Ordinal @($GrpEntry.Files))
    $linesSum = 0
    foreach ($f in $filesSorted) {
        if ($FileLines -and $FileLines.ContainsKey($f)) { $linesSum += [int]$FileLines[$f] }
    }
    $ev = Eval-RiskForSubset $filesSorted $FileSignals $FileLines
    $topSeg = if ($GrpEntry.Group -eq 'root' -or $GrpEntry.Group.StartsWith('(')) { $GrpEntry.Group } else { ($GrpEntry.Group -split '/')[0] }
    return @{
        Group = $GrpEntry.Group
        Members = @($GrpEntry.Members)
        TopSeg = $topSeg
        Files = $filesSorted
        FilesCnt = $filesSorted.Count
        LinesCnt = $linesSum
        Risk = $ev.RiskLevel
        Specialists = $ev.RecommendedSpecialists
        Signals = $ev.RiskSignals
        FilesCsv = ($filesSorted -join ',')
        FeatureTokens = @($GrpEntry.FeatureTokens)
    }
}

function Get-FileFeatureToken([string]$PathVal) {
    $leaf = ($PathVal -split '/')[-1]
    $stem = $leaf -replace '\.[^.]+$', ''
    $stem = $stem -replace '\.(test|spec|generated|pb|g|designer)$', ''
    $spaced = ($stem -replace '[-_.]+', ' ')
    $spaced = [regex]::Replace($spaced, '([a-z0-9])([A-Z])', '$1 $2')
    $rawWords = @($spaced.ToLowerInvariant().Trim() -split '\s+' | Where-Object { $_ -ne '' })
    if ($rawWords.Count -eq 0) { return 'misc' }
    $layerSet = @('controller','controllers','service','services','repository','repositories','repo','handler','handlers','model','models','types','type','schema','schemas','utils','util','helper','helpers','view','views','component','components','slice','store','routes','route','router','api','client','impl','dto','dtos','spec','test')
    $end = $rawWords.Count
    while ($end -gt 1 -and ($layerSet -contains $rawWords[$end - 1])) {
        $end--
    }
    return ($rawWords[0..($end - 1)] -join '-')
}

function Get-StemKeyNoExt([string]$PathVal) {
    $low = $PathVal.ToLowerInvariant()
    return ($low -replace '\.(?:tsx|ts|jsx|js|mjs|cjs|py|go|rs|cpp|hpp|c|h|cs|java|proto|graphql|gql)$', '')
}

function Resolve-RelImportTarget([string]$FromFile, [string]$RelSpec) {
    $cleanSpec = ($RelSpec -replace '\\', '/' -replace '[?#].*$', '').Trim()
    if (-not $cleanSpec -or -not ($cleanSpec.StartsWith('./') -or $cleanSpec.StartsWith('../'))) { return '' }
    $dirParts = @()
    $slashIdx = $FromFile.LastIndexOf('/')
    if ($slashIdx -gt 0) {
        $dirParts = @($FromFile.Substring(0, $slashIdx) -split '/' | Where-Object { $_ -ne '' })
    }
    $stk = New-Object System.Collections.Generic.List[string]
    foreach ($dp in $dirParts) { [void]$stk.Add($dp) }
    foreach ($seg in ($cleanSpec -split '/')) {
        if (-not $seg -or $seg -eq '.') { continue }
        if ($seg -eq '..') {
            if ($stk.Count -gt 0) { $stk.RemoveAt($stk.Count - 1) } else { return '' }
        } else {
            [void]$stk.Add($seg)
        }
    }
    if ($stk.Count -eq 0) { return '' }
    return (Get-StemKeyNoExt ($stk -join '/'))
}

function Get-SourceContentLines([string]$Root, [string]$TargetCommitSha, [string]$RelPath) {
    if ($TargetCommitSha) {
        $shRes = Invoke-GitCommand $Root @('show', "${TargetCommitSha}:${RelPath}")
        if ($shRes.ExitCode -ne 0) { return @() }
        return ($shRes.StdOut -split "\r?\n")
    }
    $full = Join-Path $Root ($RelPath -replace '/', '\')
    if (-not (Test-Path -LiteralPath $full -PathType Leaf) -or (Test-BinaryFile $full)) { return @() }
    return @([IO.File]::ReadLines($full))
}

function Attach-TestsToSubBuckets([string]$ParentGroup, [System.Collections.Generic.List[hashtable]]$SubBuckets, [string[]]$TestFiles) {
    $extraTests = New-Object System.Collections.Generic.List[string]
    foreach ($tf in $TestFiles) {
        $assignedIdx = -1
        # 1. Deeper prefix match inside ParentGroup
        if ($ParentGroup -ne 'root') {
            $pfx = "$ParentGroup/"
            if ($tf.StartsWith($pfx)) {
                $tRem = $tf.Substring($pfx.Length)
                $tSeg = if ($tRem.Contains('/')) { "$ParentGroup/$($tRem.Split('/')[0])" } else { '' }
                if ($tSeg) {
                    for ($i = 0; $i -lt $SubBuckets.Count; $i++) {
                        if ($SubBuckets[$i].Group -ceq $tSeg) { $assignedIdx = $i; break }
                    }
                }
            }
        }
        # 2. Stem or feature-token unique match
        if ($assignedIdx -lt 0) {
            $tfLeaf = ($tf -split '/')[-1]
            $tfStem = ($tfLeaf -replace '\.[^.]+$', '' -replace '\.(test|spec)$', '').ToLowerInvariant()
            $matchedIdxs = New-Object System.Collections.Generic.List[int]
            for ($i = 0; $i -lt $SubBuckets.Count; $i++) {
                $hit = $false
                foreach ($rf in $SubBuckets[$i].Files) {
                    $rfLeaf = ($rf -split '/')[-1]
                    $rfStem = ($rfLeaf -replace '\.[^.]+$', '').ToLowerInvariant()
                    if ($rfStem -ceq $tfStem) { $hit = $true; break }
                }
                if ($hit) { [void]$matchedIdxs.Add($i) }
            }
            if ($matchedIdxs.Count -eq 0) {
                $tFeat = Get-FileFeatureToken $tf
                for ($i = 0; $i -lt $SubBuckets.Count; $i++) {
                    if ($SubBuckets[$i].FeatureTokens -contains $tFeat) { [void]$matchedIdxs.Add($i) }
                }
            }
            if ($matchedIdxs.Count -eq 1) {
                $assignedIdx = $matchedIdxs[0]
            }
        }
        if ($assignedIdx -ge 0) {
            [void]$SubBuckets[$assignedIdx].Files.Add($tf)
        } else {
            [void]$extraTests.Add($tf)
        }
    }
    if ($extraTests.Count -gt 0) {
        $tGrp = if ($ParentGroup -eq 'root') { '(tests)' } else { "$ParentGroup/(tests)" }
        [void]$SubBuckets.Add(@{
            Group = $tGrp
            Members = @($tGrp)
            Files = $extraTests
            FeatureTokens = @()
        })
    }
}

function Coalesce-TinySubBuckets([System.Collections.Generic.List[hashtable]]$SubBuckets, [hashtable]$FileLines, [hashtable]$FileSignals) {
    $cur = New-Object System.Collections.Generic.List[hashtable]
    foreach ($sb in $SubBuckets) { [void]$cur.Add((Get-UnitMetrics $sb $FileLines $FileSignals)) }
    while ($cur.Count -gt 4) {
        $tinyIdx = -1
        $tinyLines = [int]::MaxValue
        for ($i = 0; $i -lt $cur.Count; $i++) {
            $u = $cur[$i]
            $hasContract = (@($u.Files | Where-Object { Test-ContractPath $_ })).Count -gt 0
            if ($u.FilesCnt -lt 2 -and $u.LinesCnt -lt 200 -and $u.Risk -cne 'CRITICAL' -and -not $hasContract) {
                if ($u.LinesCnt -lt $tinyLines) { $tinyLines = $u.LinesCnt; $tinyIdx = $i }
            }
        }
        if ($tinyIdx -lt 0) { break }
        $tu = $cur[$tinyIdx]
        $bestTarget = -1
        $bestScore = [long]::MaxValue
        for ($j = 0; $j -lt $cur.Count; $j++) {
            if ($j -eq $tinyIdx) { continue }
            $cand = $cur[$j]
            $combFiles = $tu.FilesCnt + $cand.FilesCnt
            $combLines = $tu.LinesCnt + $cand.LinesCnt
            if (Test-IsOversizedUnit $combFiles $combLines) { continue }
            $score = [long]$combLines
            if ($cand.Risk -cne $tu.Risk) { $score += 100000 }
            if ($cand.Risk -ceq 'CRITICAL') { $score += 500000 }
            if ($score -lt $bestScore) { $bestScore = $score; $bestTarget = $j }
        }
        if ($bestTarget -lt 0) { break }
        $tgt = $cur[$bestTarget]
        $mergedFiles = New-Object System.Collections.Generic.List[string]
        foreach ($f in ($tu.Files + $tgt.Files)) { [void]$mergedFiles.Add($f) }
        $mems = @($tu.Members + $tgt.Members | Select-Object -Unique)
        $mGroup = if ($tgt.Group.Length -ge $tu.Group.Length) { $tgt.Group } else { $tu.Group }
        $feats = @($tu.FeatureTokens + $tgt.FeatureTokens | Select-Object -Unique)
        $merged = Get-UnitMetrics @{ Group = $mGroup; Members = $mems; Files = $mergedFiles; FeatureTokens = $feats } $FileLines $FileSignals
        $hi = [Math]::Max($tinyIdx, $bestTarget); $lo = [Math]::Min($tinyIdx, $bestTarget)
        $cur.RemoveAt($hi); $cur.RemoveAt($lo)
        [void]$cur.Add($merged)
    }
    return $cur
}

function Expand-OversizedUnit([string]$Root, [string]$TargetCommitSha, [hashtable]$Unit, [hashtable]$FileLines, [hashtable]$FileSignals, [int]$Depth) {
    foreach ($f in $Unit.Files) {
        $fl = if ($FileLines.ContainsKey($f)) { [int]$FileLines[$f] } else { 0 }
        if ($fl -gt 5000) {
            return @{ PartitionError = "PARTITION_INCOMPLETE: single file '$f' (${fl}L) exceeds max unit bound (5000L); refactor or split PR" }
        }
    }

    $nonTest = New-Object System.Collections.Generic.List[string]
    $tests = New-Object System.Collections.Generic.List[string]
    foreach ($f in $Unit.Files) {
        if (Test-TestPath $f) { [void]$tests.Add($f) } else { [void]$nonTest.Add($f) }
    }

    $rawGroup = $Unit.Group
    $baseGroup = $rawGroup -replace '/\((root|contracts)\)$', ''
    $prefix = if ($baseGroup -eq 'root' -or $baseGroup.StartsWith('(')) { '' } else { "$baseGroup/" }

    # Boundary 1: deeper directory hierarchy
    if ($Depth -lt 4) {
        $dirMap = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::Ordinal)
        $hasDeeperDir = $false
        foreach ($f in $nonTest) {
            $rem = if ($prefix -and $f.StartsWith($prefix)) { $f.Substring($prefix.Length) } elseif (-not $prefix) { $f } else { '' }
            if ($rem -and $rem.Contains('/')) {
                $hasDeeperDir = $true
                $childKey = if ($prefix) { "$prefix$($rem.Split('/')[0])" } else { $rem.Split('/')[0] }
            } elseif (Test-ContractPath $f) {
                $childKey = if ($baseGroup -eq 'root') { '(contracts)' } else { "$baseGroup/(contracts)" }
            } else {
                $childKey = if ($baseGroup -eq 'root') { '(root)' } else { "$baseGroup/(root)" }
            }
            if (-not $dirMap.ContainsKey($childKey)) {
                $dirMap[$childKey] = New-Object System.Collections.Generic.List[string]
            }
            [void]$dirMap[$childKey].Add($f)
        }
        if ($hasDeeperDir -and $dirMap.Count -ge 2) {
            $subBuckets = New-Object System.Collections.Generic.List[hashtable]
            foreach ($k in (Sort-Ordinal @($dirMap.Keys))) {
                $fts = New-Object System.Collections.Generic.List[string]
                foreach ($rf in $dirMap[$k]) { [void]$fts.Add((Get-FileFeatureToken $rf)) }
                [void]$subBuckets.Add(@{ Group = $k; Members = @($k); Files = $dirMap[$k]; FeatureTokens = @($fts | Select-Object -Unique) })
            }
            Attach-TestsToSubBuckets $baseGroup $subBuckets $tests.ToArray()
            $coalesced = Coalesce-TinySubBuckets $subBuckets $FileLines $FileSignals
            $outUnits = New-Object System.Collections.Generic.List[hashtable]
            foreach ($cu in $coalesced) {
                if (Test-IsOversizedUnit $cu.FilesCnt $cu.LinesCnt) {
                    $subRes = Expand-OversizedUnit $Root $TargetCommitSha $cu $FileLines $FileSignals ($Depth + 1)
                    if ($subRes.PartitionError) { return $subRes }
                    foreach ($su in $subRes.Units) { [void]$outUnits.Add($su) }
                } else {
                    [void]$outUnits.Add($cu)
                }
            }
            return @{ Units = $outUnits }
        }
    }

    # Boundary 2: contract separation + feature token + local relative imports connected components
    $contracts = New-Object System.Collections.Generic.List[string]
    $regular = New-Object System.Collections.Generic.List[string]
    foreach ($f in $nonTest) {
        if (Test-ContractPath $f) { [void]$contracts.Add($f) } else { [void]$regular.Add($f) }
    }

    $b2Buckets = New-Object System.Collections.Generic.List[hashtable]
    if ($contracts.Count -gt 0 -and $regular.Count -gt 0) {
        $cGrp = if ($baseGroup -eq 'root' -or $baseGroup.StartsWith('(')) { '(contracts)' } else { "$baseGroup/(contracts)" }
        [void]$b2Buckets.Add(@{ Group = $cGrp; Members = @($cGrp); Files = $contracts; FeatureTokens = @('contracts') })
    } elseif ($contracts.Count -gt 0) {
        foreach ($cf in $contracts) { [void]$regular.Add($cf) }
    }

    $n = $regular.Count
    if ($n -gt 0) {
        $parent = New-Object int[] $n
        $feats = New-Object string[] $n
        $fileExts = New-Object string[] $n
        $stemMap = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::Ordinal)
        $featFirstIdx = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::Ordinal)
        for ($i = 0; $i -lt $n; $i++) {
            $parent[$i] = $i
            $rf = $regular[$i]
            $ft = Get-FileFeatureToken $rf
            $feats[$i] = $ft
            $rfLeaf = ($rf -split '/')[-1]
            $dotPos = $rfLeaf.LastIndexOf('.')
            $fileExts[$i] = if ($dotPos -ge 0 -and $dotPos -lt ($rfLeaf.Length - 1)) { $rfLeaf.Substring($dotPos + 1).ToLowerInvariant() } else { 'noext' }
            $sk = Get-StemKeyNoExt $rf
            if (-not $stemMap.ContainsKey($sk)) { $stemMap[$sk] = $i }
            if ($sk.EndsWith('/index')) {
                $dirStem = $sk.Substring(0, $sk.Length - 6)
                if ($dirStem -and -not $stemMap.ContainsKey($dirStem)) { $stemMap[$dirStem] = $i }
            }
        }
        $ufFind = {
            param([int]$x)
            while ($parent[$x] -ne $x) {
                $parent[$x] = $parent[$parent[$x]]
                $x = $parent[$x]
            }
            return $x
        }
        $ufUnion = {
            param([int]$a, [int]$b)
            $ra = & $ufFind $a
            $rb = & $ufFind $b
            if ($ra -ne $rb) {
                if ($ra -lt $rb) { $parent[$rb] = $ra } else { $parent[$ra] = $rb }
            }
        }
        $impEdges = New-Object System.Collections.Generic.List[hashtable]
        for ($i = 0; $i -lt $n; $i++) {
            $ft = $feats[$i]
            if ($featFirstIdx.ContainsKey($ft)) {
                & $ufUnion ([int]$featFirstIdx[$ft]) $i
            } else {
                $featFirstIdx[$ft] = $i
            }
            $lines = Get-SourceContentLines $Root $TargetCommitSha $regular[$i]
            foreach ($ln in $lines) {
                foreach ($m in ([regex]::Matches([string]$ln, '["''](\.\.?/[^"''\r\n]+)["'']'))) {
                    $tgtStem = Resolve-RelImportTarget $regular[$i] $m.Groups[1].Value
                    if ($tgtStem -and $stemMap.ContainsKey($tgtStem)) {
                        $tIdx = [int]$stemMap[$tgtStem]
                        & $ufUnion $i $tIdx
                        [void]$impEdges.Add(@{ a = $i; b = $tIdx })
                    }
                }
            }
        }
        $compHasCrossExt = New-Object 'System.Collections.Hashtable'
        foreach ($ed in $impEdges) {
            if ($fileExts[$ed.a] -cne $fileExts[$ed.b]) {
                $rEd = & $ufFind $ed.a
                $compHasCrossExt[$rEd] = $true
            }
        }
        $compFiles = New-Object 'System.Collections.Hashtable'
        $compIdxs = New-Object 'System.Collections.Hashtable'
        $compFeats = New-Object 'System.Collections.Hashtable'
        for ($i = 0; $i -lt $n; $i++) {
            $rIdx = & $ufFind $i
            if (-not $compFiles.ContainsKey($rIdx)) {
                $compFiles[$rIdx] = New-Object System.Collections.Generic.List[string]
                $compIdxs[$rIdx] = New-Object System.Collections.Generic.List[int]
                $compFeats[$rIdx] = New-Object System.Collections.Generic.List[string]
            }
            [void]$compFiles[$rIdx].Add($regular[$i])
            [void]$compIdxs[$rIdx].Add($i)
            if (-not $compFeats[$rIdx].Contains($feats[$i])) { [void]$compFeats[$rIdx].Add($feats[$i]) }
        }
        foreach ($rKey in @($compFiles.Keys | Sort-Object)) {
            $sortedFt = @(Sort-Ordinal $compFeats[$rKey].ToArray())
            $ftLabel = $sortedFt[0]
            $subGrp = if ($baseGroup -eq 'root' -or $baseGroup.StartsWith('(')) { $ftLabel } else { "$baseGroup/$ftLabel" }
            $cList = $compFiles[$rKey]
            $cLines = 0
            foreach ($cfItem in $cList) {
                if ($FileLines.ContainsKey($cfItem)) { $cLines += [int]$FileLines[$cfItem] }
            }
            if ((Test-IsOversizedUnit $cList.Count $cLines) -and $cList.Count -ge 2 -and (-not $compHasCrossExt.ContainsKey($rKey))) {
                $extMap = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::Ordinal)
                foreach ($idxItem in $compIdxs[$rKey]) {
                    $extV = $fileExts[$idxItem]
                    if (-not $extMap.ContainsKey($extV)) {
                        $extMap[$extV] = New-Object System.Collections.Generic.List[string]
                    }
                    [void]$extMap[$extV].Add($regular[$idxItem])
                }
                if ($extMap.Count -ge 2) {
                    foreach ($extK in (Sort-Ordinal @($extMap.Keys))) {
                        $extSubGrp = "${subGrp}(${extK})"
                        [void]$b2Buckets.Add(@{ Group = $extSubGrp; Members = @($extSubGrp); Files = $extMap[$extK]; FeatureTokens = $sortedFt })
                    }
                    continue
                }
            }
            [void]$b2Buckets.Add(@{ Group = $subGrp; Members = @($subGrp); Files = $cList; FeatureTokens = $sortedFt })
        }
    }

    if ($b2Buckets.Count -ge 2) {
        Attach-TestsToSubBuckets $baseGroup $b2Buckets $tests.ToArray()
        $coalesced = Coalesce-TinySubBuckets $b2Buckets $FileLines $FileSignals
        foreach ($cu in $coalesced) {
            if (Test-IsOversizedUnit $cu.FilesCnt $cu.LinesCnt) {
                return @{ PartitionError = "PARTITION_INCOMPLETE: oversized unit '$($cu.Group)' ($($cu.FilesCnt)f, $($cu.LinesCnt)L) cannot be cohesively partitioned without arbitrary LOC splitting" }
            }
        }
        return @{ Units = $coalesced }
    }

    return @{ PartitionError = "PARTITION_INCOMPLETE: oversized unit '$rawGroup' ($($Unit.FilesCnt)f, $($Unit.LinesCnt)L) cannot be cohesively partitioned without arbitrary LOC splitting" }
}

function Merge-CohesiveUnitsToCap([System.Collections.Generic.List[hashtable]]$Units, [hashtable]$FileLines, [hashtable]$FileSignals, [string]$SizeClass) {
    while ($Units.Count -gt 4) {
        $bestI = -1; $bestJ = -1
        $bestTop = [int]::MaxValue; $bestCrit = [int]::MaxValue; $bestRisk = [int]::MaxValue
        $bestLines = [int]::MaxValue; $bestFiles = [int]::MaxValue
        $bestGA = ''; $bestGB = ''
        for ($i = 0; $i -lt $Units.Count; $i++) {
            for ($j = $i + 1; $j -lt $Units.Count; $j++) {
                $ui = $Units[$i]; $uj = $Units[$j]
                $cFiles = $ui.FilesCnt + $uj.FilesCnt
                $cLines = $ui.LinesCnt + $uj.LinesCnt
                if (Test-IsOversizedUnit $cFiles $cLines) { continue }
                $dTop = if ($ui.TopSeg -ceq $uj.TopSeg) { 0 } else { 1 }
                $dCrit = if (($ui.Risk -ceq 'CRITICAL') -ne ($uj.Risk -ceq 'CRITICAL')) { 1 } else { 0 }
                $dRisk = if ($ui.Risk -ceq $uj.Risk) { 0 } else { 1 }
                $gA = if ([string]::CompareOrdinal($ui.Group, $uj.Group) -le 0) { $ui.Group } else { $uj.Group }
                $gB = if ($gA -ceq $ui.Group) { $uj.Group } else { $ui.Group }
                $better = $false
                if ($dTop -lt $bestTop) { $better = $true }
                elseif ($dTop -eq $bestTop) {
                    if ($dCrit -lt $bestCrit) { $better = $true }
                    elseif ($dCrit -eq $bestCrit) {
                        if ($dRisk -lt $bestRisk) { $better = $true }
                        elseif ($dRisk -eq $bestRisk) {
                            if ($cLines -lt $bestLines) { $better = $true }
                            elseif ($cLines -eq $bestLines) {
                                if ($cFiles -lt $bestFiles) { $better = $true }
                                elseif ($cFiles -eq $bestFiles) {
                                    $cmpA = [string]::CompareOrdinal($gA, $bestGA)
                                    if ($cmpA -lt 0 -or ($cmpA -eq 0 -and [string]::CompareOrdinal($gB, $bestGB) -lt 0)) { $better = $true }
                                }
                            }
                        }
                    }
                }
                if ($better) {
                    $bestI = $i; $bestJ = $j
                    $bestTop = $dTop; $bestCrit = $dCrit; $bestRisk = $dRisk
                    $bestLines = $cLines; $bestFiles = $cFiles; $bestGA = $gA; $bestGB = $gB
                }
            }
        }
        if ($bestI -lt 0) {
            return @{ PartitionError = "PARTITION_INCOMPLETE: cannot bound $SizeClass PR to <= 4 cohesive units without exceeding unit bounds" }
        }
        $ua = $Units[$bestI]; $ub = $Units[$bestJ]
        $mFiles = New-Object System.Collections.Generic.List[string]
        foreach ($f in ($ua.Files + $ub.Files)) { [void]$mFiles.Add($f) }
        $mems = @(Sort-Ordinal @($ua.Members + $ub.Members | Select-Object -Unique))
        $mGroup = if ($mems.Count -eq 2) { "$($mems[0])+$($mems[1])" } else { "$($mems[0])+$($mems.Count - 1)more" }
        $mFeats = @($ua.FeatureTokens + $ub.FeatureTokens | Select-Object -Unique)
        $merged = Get-UnitMetrics @{ Group = $mGroup; Members = $mems; Files = $mFiles; FeatureTokens = $mFeats } $FileLines $FileSignals
        $Units.RemoveAt($bestJ); $Units.RemoveAt($bestI)
        [void]$Units.Add($merged)
    }
    return @{ Units = $Units }
}

function Build-UnitAssignments([string]$Root, [string]$TargetCommitSha, [string[]]$ReviewFiles, [hashtable]$FileLines, [hashtable]$FileSignals, [string]$SizeClass) {
    $groupsMap = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::Ordinal)
    $nonTestGroups = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::Ordinal)
    foreach ($f in $ReviewFiles) {
        if (Test-TestPath $f) { continue }
        $g = Get-RawModuleGroup $f
        $nonTestGroups[$g] = $true
        if (-not $groupsMap.ContainsKey($g)) {
            $groupsMap[$g] = New-Object System.Collections.Generic.List[string]
        }
        [void]$groupsMap[$g].Add($f)
    }

    $activeNtKeys = @(Sort-Ordinal @($nonTestGroups.Keys))
    foreach ($f in $ReviewFiles) {
        if (-not (Test-TestPath $f)) { continue }
        $g = Get-RawModuleGroup $f
        $assigned = $g
        if (-not $nonTestGroups.ContainsKey($g)) {
            $token = ''
            if ($f -match '^(?:tests?|__tests__)/([^/]+)/') {
                $token = $Matches[1]
            } elseif ($f -match '(?:^|/)([^/]+)\.(?:test|spec)\.[^./]+$') {
                $token = $Matches[1]
            }
            if ($token) {
                $matchesNt = @($activeNtKeys | Where-Object { $_ -ceq $token -or $_.EndsWith("/$token") })
                if ($matchesNt.Count -eq 1) {
                    $assigned = $matchesNt[0]
                }
            }
        }
        if (-not $groupsMap.ContainsKey($assigned)) {
            $groupsMap[$assigned] = New-Object System.Collections.Generic.List[string]
        }
        [void]$groupsMap[$assigned].Add($f)
    }

    $workUnits = New-Object System.Collections.Generic.List[hashtable]
    foreach ($grp in (Sort-Ordinal @($groupsMap.Keys))) {
        $uRaw = Get-UnitMetrics @{ Group = $grp; Members = @($grp); Files = $groupsMap[$grp]; FeatureTokens = @() } $FileLines $FileSignals
        if (Test-IsOversizedUnit $uRaw.FilesCnt $uRaw.LinesCnt) {
            $expRes = Expand-OversizedUnit $Root $TargetCommitSha $uRaw $FileLines $FileSignals 0
            if ($expRes.PartitionError) { return $expRes }
            foreach ($eu in $expRes.Units) { [void]$workUnits.Add($eu) }
        } else {
            [void]$workUnits.Add($uRaw)
        }
    }

    if ($SizeClass -in @('L', 'XL') -and $workUnits.Count -gt 4) {
        $capRes = Merge-CohesiveUnitsToCap $workUnits $FileLines $FileSignals $SizeClass
        if ($capRes.PartitionError) { return $capRes }
        $workUnits = $capRes.Units
    }

    $sortedUnits = @($workUnits | Sort-Object -Property @{ Expression = { $_.Group } }, @{ Expression = { if ($_.Files.Count -gt 0) { $_.Files[0] } else { '' } } })
    $finalUnits = New-Object System.Collections.Generic.List[hashtable]
    $idx = 1
    foreach ($su in $sortedUnits) {
        $uId = 'U{0:D2}' -f $idx
        $idx++
        $su['UnitId'] = $uId
        [void]$finalUnits.Add($su)
    }
    return @{ Units = @($finalUnits) }
}

function Eval-Level1Dispatch([string[]]$ContractFiles, [string]$RecommendedSpecialists, [string]$RiskLevel, [string[]]$ReviewFiles) {
    $recArr = if ($RecommendedSpecialists -and $RecommendedSpecialists -cne 'none') { @(Split-CsvList $RecommendedSpecialists) } else { @() }
    $l1 = New-Object System.Collections.Generic.List[string]
    if ($ContractFiles.Count -gt 0 -or ($recArr -contains 'b3-architecture-reviewer')) {
        [void]$l1.Add('b3-architecture-reviewer')
    }
    if ($recArr -contains 'b3-security-reviewer' -and -not $l1.Contains('b3-security-reviewer')) {
        [void]$l1.Add('b3-security-reviewer')
    }
    if ($recArr -contains 'b3-performance-reviewer' -and -not $l1.Contains('b3-performance-reviewer')) {
        [void]$l1.Add('b3-performance-reviewer')
    }
    $l1Out = if ($l1.Count -gt 0) { (Sort-Ordinal $l1.ToArray()) -join ',' } else { 'none' }
    $skipRat = 'none'
    if ($l1Out -ceq 'none') {
        $allDocs = ($ReviewFiles.Count -gt 0 -and (@($ReviewFiles | Where-Object { -not (Test-DocOrAssetPath $_) })).Count -eq 0)
        if ($allDocs) {
            $skipRat = 'low-risk-docs-only'
        } elseif ($RiskLevel -ceq 'LOW') {
            $skipRat = 'low-risk-isolated-no-contracts'
        } else {
            $skipRat = 'no-contract-or-arch-signals'
        }
    }
    return @{
        L1Specialists = $l1Out
        L1SkipRationale = $skipRat
    }
}

function Invoke-BuildInventory([string]$Root, [string]$ResolvedBase, [string]$TargetCommitSha, [string[]]$IgnPaths, [int]$Conc, [string]$FailPrefix) {
    $scope = Invoke-CollectScopeData $Root $ResolvedBase $TargetCommitSha $IgnPaths $FailPrefix
    if ($scope.ReviewFiles.Count -eq 0 -and $scope.NoiseFiles.Count -eq 0) {
        return @{ IsEmpty = $true }
    }
    $sizeClass = Get-TShirtSize $scope.ReviewFiles.Count $scope.TotalLines
    $riskAllSet = if ($scope.ReviewFiles.Count -gt 0) { $scope.ReviewFiles } else { $scope.NoiseFiles }
    $overallRisk = Eval-RiskForSubset $riskAllSet $scope.FileSignals $scope.FileLines

    $contractFiles = @($scope.ReviewFiles | Where-Object { Test-ContractPath $_ })
    $genAll = @()
    foreach ($gf in @($scope.ReviewFiles + $scope.NoiseFiles)) {
        if (Test-GeneratedCodePath $gf) { $genAll += $gf }
    }
    $generatedFiles = if ($genAll.Count -gt 0) { @(Sort-Ordinal $genAll) } else { @() }
    $testFiles = @($scope.ReviewFiles | Where-Object { Test-TestPath $_ })

    $l1Eval = Eval-Level1Dispatch $contractFiles $overallRisk.RecommendedSpecialists $overallRisk.RiskLevel $scope.ReviewFiles

    $units = @()
    if ($scope.ReviewFiles.Count -gt 0) {
        $partRes = Build-UnitAssignments $Root $TargetCommitSha $scope.ReviewFiles $scope.FileLines $scope.FileSignals $sizeClass
        if ($partRes.PartitionError) {
            return @{ IsEmpty = $false; PartitionError = $partRes.PartitionError }
        }
        $units = @($partRes.Units)
    }

    $clampedConc = [Math]::Max(1, [Math]::Min(4, $Conc))
    $splitRec = ($sizeClass -in @('L', 'XL', 'XXL') -and ($units.Count -ge 2 -or $scope.TotalLines -gt 800))
    return @{
        IsEmpty = $false
        SizeClass = $sizeClass
        FilesCount = $scope.ReviewFiles.Count
        LinesCount = $scope.TotalLines
        RiskLevel = $overallRisk.RiskLevel
        RiskSignals = $overallRisk.RiskSignals
        RecommendedSpecialists = $overallRisk.RecommendedSpecialists
        L1Specialists = $l1Eval.L1Specialists
        L1SkipRationale = $l1Eval.L1SkipRationale
        ChangeTypes = $scope.ChangeTypes
        ContractFiles = $contractFiles
        GeneratedFiles = $generatedFiles
        TestFiles = $testFiles
        NoiseFiles = $scope.NoiseFiles
        ReviewFiles = $scope.ReviewFiles
        SplitRecommended = $splitRec
        MaxConcurrency = $clampedConc
        Units = $units
    }
}

function Get-ScopePathsTreeHash([string]$Root, [string]$TargetCommitSha, [string[]]$PathsArr, [string[]]$IgnPaths) {
    $clean = New-Object System.Collections.Generic.List[string]
    foreach ($p in @($PathsArr)) {
        $np = Normalize-PathValue ([string]$p)
        if (-not $np -or (Test-CheckpointPath $np)) { continue }
        if ($IgnPaths -and (Test-PathMatch $np $IgnPaths)) { continue }
        if (-not $clean.Contains($np)) { [void]$clean.Add($np) }
    }
    if ($clean.Count -eq 0) { return 'none' }
    $sorted = @(Sort-Ordinal $clean.ToArray())
    if (-not $TargetCommitSha) {
        return (Get-TreeFingerprint $Root $sorted $IgnPaths).TreeHash
    }
    $lsArgs = @('ls-tree', '-r', $TargetCommitSha, '--') + $sorted
    $lsRes = Invoke-GitCommand $Root $lsArgs
    if ($lsRes.ExitCode -ne 0) {
        $detail = if ($lsRes.StdErr.Trim()) { $lsRes.StdErr.Trim() } else { $lsRes.StdOut.Trim() }
        Fail "GIT_ERROR: git ls-tree target paths failed: $detail" 1
    }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($ln in ($lsRes.StdOut -split "\r?\n")) {
        if ($ln.Trim()) { [void]$lines.Add($ln.Trim()) }
    }
    $manifest = "PATHS=" + ($sorted -join ',') + "`n" + ((Sort-Ordinal $lines.ToArray()) -join "`n") + "`n"
    return (Invoke-GitTextHash $Root $manifest 'GIT_ERROR')
}

function Get-DefaultMaxPasses([string]$SizeClass, [int]$UnitCount = 1) {
    switch (Normalize-SizeClass $SizeClass) {
        'L' { return 12 }
        'XL' { return 12 }
        'XXL' {
            $u = if ($UnitCount -gt 1) { $UnitCount } else { 1 }
            $scaled = [int]([Math]::Floor((5.0 * $u + 1.0) / 2.0)) + 2
            return [Math]::Max(24, $scaled)
        }
        default { return 5 }
    }
}

function Get-SizeRank([string]$SizeClass) {
    switch (Normalize-SizeClass $SizeClass) {
        'XS' { return 0 }
        'S' { return 1 }
        'M' { return 2 }
        'L' { return 3 }
        'XL' { return 4 }
        'XXL' { return 5 }
        default { return -1 }
    }
}

function Test-WaiverAttempt([string]$RationaleVal) {
    $t = if ($RationaleVal) { $RationaleVal.Trim() } else { '' }
    return ($t -match '^WAIVER:')
}

function Test-HighSkipRationale([string]$RationaleVal) {
    $t = if ($RationaleVal) { $RationaleVal.Trim() } else { '' }
    if (-not $t -or $t.Equals('none', [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    if (Test-WaiverAttempt $t) { return $false }
    if ($t.Length -lt 15) { return $false }
    $low = $t.ToLowerInvariant()
    if ($low -cmatch '(.)\1\1\1') { return $false }
    $wordMatches = [regex]::Matches($low, '[a-z]{3,}')
    $uniq = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($m in $wordMatches) {
        [void]$uniq.Add($m.Value)
    }
    return ($uniq.Count -ge 2)
}

function Normalize-MergePolicyPath([string]$RawPath) {
    if ([string]::IsNullOrEmpty($RawPath)) { return $null }
    if ($RawPath -match '[\x00-\x1F\x7F]') { return $null }
    $s = $RawPath -replace '\\', '/'
    if ($s -ceq '.' -or $s -ceq './') { return '.' }
    if ($s.EndsWith('/')) {
        $s = $s.Substring(0, $s.Length - 1)
    }
    if ($s.Contains(':') -or $s.StartsWith('/') -or $s.StartsWith('~') -or ($s -match '[\*\?]')) { return $null }
    if (-not (Test-ValidLiteralGitPath $s)) { return $null }
    return $s
}

function Test-ProtectedPathMatchCI([string]$Candidate, [string[]]$Patterns, [bool]$CaseInsensitive = $true) {
    if (-not $Candidate -or -not $Patterns -or $Patterns.Count -eq 0) { return $false }
    $cmp = if ($CaseInsensitive) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    foreach ($p in $Patterns) {
        if (-not $p) { continue }
        if ($p -ceq '.' -or $Candidate -ceq '.' -or $Candidate.Equals($p, $cmp) -or $Candidate.StartsWith("$p/", $cmp) -or $p.StartsWith("$Candidate/", $cmp)) {
            return $true
        }
    }
    return $false
}

function Invoke-GitLsRemoteRefs([string]$Root, [string[]]$FullRefs) {
    $cleanRefs = @($FullRefs | Where-Object { $_ -and $_.Trim() } | Select-Object -Unique)
    $refsMap = @{}
    if ($cleanRefs.Count -eq 0) {
        return @{ Status = 'OK'; Refs = $refsMap }
    }
    $envLs = @{
        GIT_TERMINAL_PROMPT = '0'
        GCM_INTERACTIVE     = 'never'
        GIT_ASKPASS         = ''
        SSH_ASKPASS         = ''
    }
    $lsRes = Invoke-GitCommand $Root (@('-c', 'credential.helper=', 'ls-remote', 'origin') + $cleanRefs) -ExtraEnv $envLs -TimeoutMs 8000
    if ($lsRes.ExitCode -ne 0) {
        return @{ Status = 'UNREACHABLE'; Refs = $refsMap }
    }
    if ($lsRes.StdOut) {
        foreach ($ln in ($lsRes.StdOut -split "\r?\n")) {
            if ($ln -cmatch "^([0-9a-f]{40})\t(\S+)$") {
                $refsMap[$Matches[2]] = $Matches[1]
            }
        }
    }
    return @{ Status = 'OK'; Refs = $refsMap }
}

function Invoke-GitLsRemoteRef([string]$Root, [string]$FullRef) {
    $res = Invoke-GitLsRemoteRefs $Root @($FullRef)
    if ($res.Status -ceq 'UNREACHABLE') {
        return @{ Status = 'UNREACHABLE'; Sha = '' }
    }
    if ($res.Refs.ContainsKey($FullRef)) {
        return @{ Status = 'OK'; Sha = $res.Refs[$FullRef] }
    }
    return @{ Status = 'MISSING'; Sha = '' }
}

function Get-CanonicalTrunkAuthority([string]$Root, [bool]$HasOrigin, [bool]$AllowLocalFallback) {
    $symFull = ''
    $branch = ''
    $sha = ''
    if ($HasOrigin) {
        $ohSym = Invoke-GitCommand $Root @('symbolic-ref', '-q', 'refs/remotes/origin/HEAD')
        if ($ohSym.ExitCode -eq 0 -and $ohSym.StdOut.Trim().StartsWith('refs/remotes/origin/', [System.StringComparison]::Ordinal)) {
            $ohFull = $ohSym.StdOut.Trim()
            $ohChk = Invoke-GitCommand $Root @('rev-parse', '--verify', '--quiet', "${ohFull}^{commit}")
            if ($ohChk.ExitCode -eq 0 -and $ohChk.StdOut.Trim() -cmatch '^[0-9a-f]{40}$') {
                $symFull = $ohFull
                $branch = $ohFull.Substring('refs/remotes/origin/'.Length)
                $sha = $ohChk.StdOut.Trim()
            }
        }
        if (-not $sha) {
            foreach ($candBr in @('main', 'master')) {
                $cFull = "refs/remotes/origin/$candBr"
                $cChk = Invoke-GitCommand $Root @('rev-parse', '--verify', '--quiet', "${cFull}^{commit}")
                if ($cChk.ExitCode -eq 0 -and $cChk.StdOut.Trim() -cmatch '^[0-9a-f]{40}$') {
                    $symFull = $cFull
                    $branch = $candBr
                    $sha = $cChk.StdOut.Trim()
                    break
                }
            }
        }
    }
    if (-not $sha -and $AllowLocalFallback) {
        foreach ($candBr in @('main', 'master')) {
            $cFull = "refs/heads/$candBr"
            $cChk = Invoke-GitCommand $Root @('rev-parse', '--verify', '--quiet', "${cFull}^{commit}")
            if ($cChk.ExitCode -eq 0 -and $cChk.StdOut.Trim() -cmatch '^[0-9a-f]{40}$') {
                $symFull = $cFull
                $branch = $candBr
                $sha = $cChk.StdOut.Trim()
                break
            }
        }
    }
    return @{ SymFull = $symFull; Branch = $branch; Sha = $sha }
}

function Assert-MergeDirtyWorktreeClean([string]$Root, [string[]]$PolicyProtectedArr, [bool]$CaseInsensitive, [string]$PolViolationReason) {
    $dirtyCmds = @(
        @{ Args = @('diff', '--no-ext-diff', '--cached', '--name-status', '-z', '--'); Mode = 'name-status-z' },
        @{ Args = @('diff', '--no-ext-diff', '--name-status', '-z', '--'); Mode = 'name-status-z' },
        @{ Args = @('ls-files', '--others', '--exclude-standard', '-z'); Mode = 'names' }
    )
    $hasDirty = $false
    foreach ($dSpec in $dirtyCmds) {
        $dPaths = @(Invoke-GitPathsZ $Root $dSpec.Args $dSpec.Mode 'MERGE_BLOCKED')
        foreach ($dp in $dPaths) {
            if (-not $dp) { continue }
            if (Test-CheckpointPath $dp) { continue }
            if (Test-ProtectedPathMatchCI $dp $PolicyProtectedArr $CaseInsensitive) {
                Fail "MERGE_BLOCKED: $PolViolationReason" 1
            }
            $hasDirty = $true
        }
    }
    if ($hasDirty) {
        Fail 'MERGE_BLOCKED: dirty_worktree' 1
    }
}

function Invoke-MergeLedgerGate([string]$Root, [string]$LedgerPathArg, [string]$ExpectedBaseSha, [string]$ExpectedHeadSha) {
    if (-not $LedgerPathArg -or -not $LedgerPathArg.Trim()) { Fail 'MERGE_BLOCKED: missing_ledger_path' 1 }
    $ledSpec = Test-ContainedRepoPath $Root $LedgerPathArg
    if (-not $ledSpec) { Fail 'MERGE_BLOCKED: invalid_ledger_path' 1 }
    if (-not (Test-Path -LiteralPath $ledSpec.Full -PathType Leaf)) { Fail 'MERGE_BLOCKED: missing_ledger_path' 1 }
    $ledCall = Invoke-CapturedGuardCall { Invoke-ReviewLedgerCheck $Root $ledSpec.Full $ledSpec.Rel @() }
    $ledChkRes = $ledCall.Result
    if (-not $ledCall.Ok -or -not $ledChkRes -or $ledChkRes.Code -ne 0 -or -not $ledChkRes.Ledger) {
        $detailMsg = if ($ledChkRes -and $ledChkRes.Message) { $ledChkRes.Message } elseif ($ledCall.Message) { $ledCall.Message } else { 'unknown' }
        Fail "MERGE_BLOCKED: ledger_check_failed ($detailMsg)" 1
    }
    if ($ledChkRes.Ledger['base_sha'] -cne $ExpectedBaseSha) {
        Fail 'MERGE_BLOCKED: ledger_target_mismatch' 1
    }
    if ($ledChkRes.Ledger['head_sha'] -cne $ExpectedHeadSha -or ($ledChkRes.Ledger['target_ref'] -cne 'working_tree' -and $ledChkRes.Ledger['target_sha'] -cne $ExpectedHeadSha)) {
        Fail 'MERGE_BLOCKED: ledger_head_mismatch' 1
    }
    if ($ledChkRes.Ledger['review_independence'] -ceq 'SINGLE_AGENT_LIMIT') {
        Fail 'MERGE_BLOCKED: single_agent_limit' 1
    }
    if ($ledChkRes.Ledger['review_independence'] -cne 'INDEPENDENT') {
        Fail 'MERGE_BLOCKED: review_independence_unknown' 1
    }
    return $ledChkRes.Ledger
}

function Assert-SingleVerifyReceiptMatchesTarget([string]$Root, [string]$RecPath, [string[]]$IgnPaths, [string]$HeadSha, [string[]]$RequiredPaths, [bool]$CaseInsensitive) {
    if (-not $HeadSha -or $HeadSha -cnotmatch '^[0-9a-f]{40}$') {
        Fail 'MERGE_BLOCKED: ci_evidence_invalid(invalid_head_sha)' 1
    }
    $vr = Test-VerifyReceipt $Root $RecPath $IgnPaths '' '' $HeadSha
    if (-not $vr -or $vr.Code -ne 0) {
        $msg = if ($vr -and $vr.Message) { $vr.Message } else { 'unknown' }
        Fail "MERGE_BLOCKED: ci_evidence_invalid($msg)" 1
    }
    $relCsv = if ($vr.RelevantPathsCsv) { [string]$vr.RelevantPathsCsv } else { '' }
    if ($relCsv -cne 'ALL') {
        if (-not $RequiredPaths -or $RequiredPaths.Count -eq 0) {
            Fail 'MERGE_BLOCKED: ci_evidence_invalid(VERIFY_SCOPE_MISMATCH)' 1
        }
        $recList = @(Split-CsvList $relCsv -AsPaths)
        foreach ($cp in $RequiredPaths) {
            if (-not (Test-OwnershipPathMatch $cp $recList $CaseInsensitive)) {
                Fail "MERGE_BLOCKED: ci_evidence_invalid(VERIFY_SCOPE_MISMATCH: $cp)" 1
            }
        }
    }
}

function Assert-LocalCiEvidence([string]$Root, [string]$HeadSha, [string[]]$ChangedPaths, [string]$RecPath, [hashtable]$LedgerObj, [string[]]$IgnPaths, [string]$CallerCiStatus, [bool]$RequireCi, [bool]$CaseInsensitive) {
    $hasExplicitReceipt = [bool]($RecPath -and $RecPath.Trim())
    if ($hasExplicitReceipt) {
        Assert-SingleVerifyReceiptMatchesTarget $Root $RecPath $IgnPaths $HeadSha $ChangedPaths $CaseInsensitive
        return 'LOCAL_VERIFIED'
    }
    if (-not $RequireCi) {
        return 'NOT_REQUIRED'
    }
    if ($null -ne $LedgerObj -and $LedgerObj.Units -and $LedgerObj.Units.Count -gt 0) {
        $hasAllScope = $false
        $coveredList = New-Object System.Collections.Generic.List[string]
        $vrCache = if ($LedgerObj.VerifiedReceipts) { $LedgerObj.VerifiedReceipts } else { @{} }
        foreach ($u in $LedgerObj.Units) {
            $ur = if ($u.verify_receipt) { [string]$u.verify_receipt } else { 'none' }
            if (-not $ur -or $ur -ceq 'none') {
                Fail "MERGE_BLOCKED: ci_evidence_invalid(ledger_unit_missing_verify_receipt:$($u.unit_id))" 1
            }
            $vrU = $null
            if ($vrCache.ContainsKey($u.unit_id)) {
                $cachedU = $vrCache[$u.unit_id]
                if ($cachedU.Receipt -ceq $ur -and $cachedU.TargetCommitSha -ceq $HeadSha -and $cachedU.Vr -and $cachedU.Vr.Code -eq 0) {
                    $vrU = $cachedU.Vr
                }
            }
            if ($null -eq $vrU) {
                $vrU = Test-VerifyReceipt $Root $ur $IgnPaths '' '' $HeadSha
                if (-not $vrU -or $vrU.Code -ne 0) {
                    $msgU = if ($vrU -and $vrU.Message) { $vrU.Message } else { 'unknown' }
                    Fail "MERGE_BLOCKED: ci_evidence_invalid($msgU)" 1
                }
            }
            if ($vrU.RelevantPathsCsv -ceq 'ALL') {
                $hasAllScope = $true
            } else {
                foreach ($rp in @(Split-CsvList $vrU.RelevantPathsCsv -AsPaths)) {
                    if ($rp -and -not $coveredList.Contains($rp)) { $coveredList.Add($rp) }
                }
            }
        }
        if (-not $hasAllScope) {
            if (-not $ChangedPaths -or $ChangedPaths.Count -eq 0) {
                Fail 'MERGE_BLOCKED: ci_evidence_invalid(VERIFY_SCOPE_MISMATCH)' 1
            }
            $covArr = @($coveredList)
            foreach ($cp in $ChangedPaths) {
                if (-not (Test-OwnershipPathMatch $cp $covArr $CaseInsensitive)) {
                    Fail "MERGE_BLOCKED: ci_evidence_invalid(VERIFY_SCOPE_MISMATCH: $cp)" 1
                }
            }
        }
        return 'LOCAL_VERIFIED'
    }
    if ($CallerCiStatus -ceq 'PASS') {
        Fail 'MERGE_BLOCKED: ci_evidence_unverified(caller_reported_ci_cannot_authorize)' 1
    }
    Fail 'MERGE_BLOCKED: ci_evidence_missing' 1
}

function Parse-MergePolicyJsonText([string]$RawJson) {
    $trimJson = if ($null -ne $RawJson) { $RawJson.TrimStart([char]0xFEFF).Trim() } else { '' }
    if (-not $trimJson -or -not ($trimJson.StartsWith('{') -and $trimJson.EndsWith('}'))) {
        Fail 'MERGE_BLOCKED: invalid_policy_json' 1
    }
    try {
        $polObj = ($trimJson | ConvertFrom-Json)
    } catch {
        Fail 'MERGE_BLOCKED: invalid_policy_json' 1
    }
    if ($null -eq $polObj -or ($polObj -isnot [System.Management.Automation.PSCustomObject])) {
        Fail 'MERGE_BLOCKED: invalid_policy_json' 1
    }
    $getExactProp = {
        param([string]$KeyName)
        $m = @($polObj.PSObject.Properties | Where-Object { $_.Name -ceq $KeyName })
        if ($m.Count -gt 1) { Fail 'MERGE_BLOCKED: invalid_policy_json' 1 }
        if ($m.Count -eq 1) { return $m[0] }
        return $null
    }
    $res = @{
        AutoMerge = 'disabled'
        AllowProtected = $false
        RequireCi = $true
        RequireReview = $true
        ProtectedPaths = @()
        AllowedTargetBranches = @()
    }
    $amProp = & $getExactProp 'auto_merge'
    if ($null -ne $amProp) {
        if ($null -eq $amProp.Value -or ($amProp.Value -isnot [string]) -or ($amProp.Value -match '[\x00-\x1F\x7F]')) { Fail 'MERGE_BLOCKED: invalid_policy_json' 1 }
        $amVal = $amProp.Value.Trim()
        if ($amVal -cnotin @('disabled', 'authorized')) { Fail "MERGE_BLOCKED: invalid_auto_merge=$amVal" 1 }
        $res.AutoMerge = $amVal
    }
    $apProp = & $getExactProp 'allow_protected_paths'
    if ($null -ne $apProp) {
        if ($apProp.Value -isnot [bool]) { Fail 'MERGE_BLOCKED: invalid_policy_json' 1 }
        $res.AllowProtected = [bool]$apProp.Value
    }
    $rcProp = & $getExactProp 'require_ci'
    if ($null -ne $rcProp) {
        if ($rcProp.Value -isnot [bool]) { Fail 'MERGE_BLOCKED: invalid_policy_json' 1 }
        $res.RequireCi = [bool]$rcProp.Value
    }
    $rrProp = & $getExactProp 'require_review'
    if ($null -ne $rrProp) {
        if ($rrProp.Value -isnot [bool]) { Fail 'MERGE_BLOCKED: invalid_policy_json' 1 }
        $res.RequireReview = [bool]$rrProp.Value
    }
    $ppProp = & $getExactProp 'protected_paths'
    if ($null -ne $ppProp) {
        if ($null -eq $ppProp.Value -or ($ppProp.Value -isnot [array])) { Fail 'MERGE_BLOCKED: invalid_policy_json' 1 }
        $ppList = New-Object System.Collections.Generic.List[string]
        foreach ($pp in $ppProp.Value) {
            if ($null -eq $pp -or ($pp -isnot [string]) -or ($pp -match '[\r\n\0]')) {
                Fail 'MERGE_BLOCKED: invalid_policy_json' 1
            }
            $np = Normalize-MergePolicyPath $pp
            if (-not $np) { Fail 'MERGE_BLOCKED: invalid_policy_json' 1 }
            if (-not $ppList.Contains($np)) { $ppList.Add($np) }
        }
        $res.ProtectedPaths = @($ppList)
    }
    $atbProp = & $getExactProp 'allowed_target_branches'
    if ($null -ne $atbProp) {
        if ($null -eq $atbProp.Value -or ($atbProp.Value -isnot [array])) { Fail 'MERGE_BLOCKED: invalid_policy_json' 1 }
        $atbList = New-Object System.Collections.Generic.List[string]
        foreach ($bp in $atbProp.Value) {
            if ($null -eq $bp -or ($bp -isnot [string]) -or ($bp -match '[\x00-\x1F\x7F\s]')) {
                Fail 'MERGE_BLOCKED: invalid_policy_json' 1
            }
            $bTrim = $bp.Trim()
            if (-not $bTrim -or $bTrim.StartsWith('-') -or $bTrim.Contains('..')) {
                Fail 'MERGE_BLOCKED: invalid_policy_json' 1
            }
            if (-not $atbList.Contains($bTrim)) { $atbList.Add($bTrim) }
        }
        $res.AllowedTargetBranches = @($atbList)
    }
    return $res
}

function Test-BranchPatternMatch([string]$BranchName, [string[]]$Patterns) {
    if (-not $BranchName) { return $false }
    foreach ($pat in @($Patterns)) {
        if (-not $pat) { continue }
        $rx = '^' + ([regex]::Escape($pat) -replace '\\\*', '.*') + '$'
        if ($BranchName -cmatch $rx) { return $true }
    }
    return $false
}

function Invoke-B3GitHubVerify([string]$Mode, [string]$RootDir, [string]$ExplicitRepo, [string]$PrNum, [string]$ErrPrefix) {
    $adapterPath = Join-Path $PSScriptRoot 'b3-github-verify.ps1'
    if (-not (Test-Path -LiteralPath $adapterPath -PathType Leaf)) {
        Fail "${ErrPrefix}: github_adapter_missing" 1
    }
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $rawOut = @()
    $rc = 1
    try {
        if ($ExplicitRepo -and $ExplicitRepo.Trim()) {
            $rawOut = @(& $adapterPath -Mode $Mode -RepoRoot $RootDir -Repo $ExplicitRepo.Trim() -PrNumber $PrNum 2>&1)
        } else {
            $rawOut = @(& $adapterPath -Mode $Mode -RepoRoot $RootDir -PrNumber $PrNum 2>&1)
        }
        $rc = $LASTEXITCODE
    } catch {
        $rawOut = @("GH_VERIFY_ERROR: adapter_exception")
        $rc = 1
    } finally {
        $ErrorActionPreference = $prevEap
    }
    $lines = @($rawOut | ForEach-Object { ([string]$_).TrimEnd("`r") })
    if ($rc -ne 0) {
        $first = if ($lines.Count -gt 0 -and $lines[0]) { $lines[0] } else { 'unknown' }
        $detail = ($first -replace '^(?:GH_VERIFY_UNAVAILABLE|GH_VERIFY_ERROR):\s*', '').Trim()
        if (-not $detail) { $detail = 'unknown' }
        if ($rc -eq 2) {
            Fail "PROVIDER_UNAVAILABLE: github_verification_failed($detail)" 2
        }
        if ($detail -cin @('origin_remote_missing', 'origin_remote_not_github', 'repo_mismatch', 'invalid_repo')) {
            Fail "${ErrPrefix}: $detail" 1
        }
        Fail "${ErrPrefix}: github_verification_failed($detail)" 1
    }
    $data = @{}
    $changedFiles = New-Object System.Collections.Generic.List[string]
    foreach ($ln in $lines) {
        if (-not $ln) { continue }
        $eq = $ln.IndexOf('=')
        if ($eq -lt 1) { Fail "${ErrPrefix}: github_verification_failed(malformed_adapter_output)" 1 }
        $k = $ln.Substring(0, $eq)
        $v = $ln.Substring($eq + 1)
        if ($k -ceq 'pr_changed_file') {
            if ($v) { [void]$changedFiles.Add($v) }
        } else {
            if ($data.ContainsKey($k)) { Fail "${ErrPrefix}: github_verification_failed(duplicate_adapter_key)" 1 }
            $data[$k] = $v
        }
    }
    if (($data['schema'] -cnotin @('b3-gh-verify-v2', 'b3-gh-verify-v1')) -or $data['mode'] -cne $Mode) {
        Fail "${ErrPrefix}: github_verification_failed(invalid_adapter_schema)" 1
    }
    $data['PrChangedFiles'] = @($changedFiles)
    return $data
}

function Get-InitialPassChain([string]$Root, [string]$BaseSha) {
    return (Invoke-GitTextHash $Root "b3-pass-v1|init|$BaseSha|0`n" 'LEDGER_FAIL')
}

function Step-PassChain([string]$Root, [string]$PrevChain, [int]$Seq, [string]$ScopeId, [string]$Kind, [int]$Delta, [string]$RefSha) {
    return (Invoke-GitTextHash $Root "b3-pass-v1|step|$PrevChain|$Seq|$ScopeId|$Kind|$Delta|$RefSha`n" 'LEDGER_FAIL')
}

function Verify-LedgerPassChain([string]$Root, [hashtable]$Ledger) {
    $cur = Get-InitialPassChain $Root $Ledger['base_sha']
    $sum = 0
    $logList = @($Ledger.PassLog)
    for ($i = 0; $i -lt $logList.Count; $i++) {
        $entry = $logList[$i]
        if ([int]$entry.seq -ne ($i + 1) -or [int]$entry.delta -lt 1) {
            Fail "LEDGER_CORRUPT: passes_used tamper detected (invalid sequence or delta at index $($i + 1))" 1
        }
        $sum += [int]$entry.delta
        $cur = Step-PassChain $Root $cur ([int]$entry.seq) $entry.scope $entry.kind ([int]$entry.delta) $entry.ref_sha
        if ($cur -cne $entry.chain_hash) {
            Fail "LEDGER_CORRUPT: passes_used tamper detected (chain hash mismatch at seq $($entry.seq))" 1
        }
    }
    if ($sum -ne [int]$Ledger['passes_used'] -or $cur -cne $Ledger['pass_chain']) {
        Fail "LEDGER_CORRUPT: passes_used tamper detected (passes=$($Ledger['passes_used']) log_sum=$sum)" 1
    }
}

function Serialize-ReviewLedger([hashtable]$L) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("# B3 Review Coverage Ledger`n")
    foreach ($k in @('schema', 'base_sha', 'head_sha', 'target_ref', 'target_sha', 'snapshot_sha', 'size_class', 'normalized_legacy_size', 'risk_level', 'risk_signals', 'recommended_specialists', 'l1_specialists', 'l1_skip_rationale', 'contract_files', 'generated_files', 'max_concurrency', 'max_passes', 'passes_used', 'pass_chain', 'budget_status', 'review_independence', 'cross_unit_status', 'cross_unit_tree_hash', 'unit_count')) {
        if ($L.ContainsKey($k)) {
            [void]$sb.Append("${k}=$($L[$k])`n")
        }
    }
    [void]$sb.Append("`n## Units`n")
    [void]$sb.Append("| unit_id | group | files_cnt | lines_cnt | risk | specialists | rationale | status | findings | verify_receipt | unit_tree_hash | files_csv |`n")
    [void]$sb.Append("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |`n")
    foreach ($u in @($L.Units)) {
        [void]$sb.Append("| $($u.unit_id) | $($u.group) | $($u.files_cnt) | $($u.lines_cnt) | $($u.risk) | $($u.specialists) | $($u.rationale) | $($u.status) | $($u.findings) | $($u.verify_receipt) | $($u.unit_tree_hash) | $($u.files_csv) |`n")
    }
    if ($L.ContainsKey('PassLog')) {
        [void]$sb.Append("`n## Pass Log`n")
        foreach ($pe in @($L.PassLog)) {
            [void]$sb.Append("pass|$($pe.seq)|$($pe.scope)|$($pe.kind)|$($pe.delta)|$($pe.ref_sha)|$($pe.chain_hash)`n")
        }
    }
    return $sb.ToString()
}

function Parse-ReviewLedger([string]$FullPath) {
    $raw = [IO.File]::ReadAllText($FullPath)
    $meta = @{}
    $units = New-Object System.Collections.Generic.List[hashtable]
    $passLog = New-Object System.Collections.Generic.List[hashtable]
    foreach ($rawLn in ($raw -split "\r?\n")) {
        $ln = $rawLn.Trim()
        if (-not $ln -or $ln.StartsWith('#')) { continue }
        if ($ln.StartsWith('|')) {
            $cols = @($ln.Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
            if ($cols.Count -ne 12) { Fail 'LEDGER_CORRUPT: malformed unit row column count' 1 }
            if ($cols[0] -eq 'unit_id' -or $cols[0] -eq '---') { continue }
            if ($cols[0] -notmatch '^U[0-9]{2,}$') { Fail "LEDGER_CORRUPT: invalid unit_id '$($cols[0])'" 1 }
            if ($cols[2] -notmatch '^[0-9]+$' -or $cols[3] -notmatch '^[0-9]+$') { Fail 'LEDGER_CORRUPT: invalid unit row numeric field' 1 }
            [void]$units.Add(@{
                unit_id = $cols[0]
                group = $cols[1]
                files_cnt = [int]$cols[2]
                lines_cnt = [int]$cols[3]
                risk = $cols[4]
                specialists = $cols[5]
                rationale = $cols[6]
                status = $cols[7]
                findings = $cols[8]
                verify_receipt = $cols[9]
                unit_tree_hash = $cols[10]
                files_csv = $cols[11]
            })
            continue
        }
        if ($ln.StartsWith('pass|')) {
            if ($ln -cnotmatch '^pass\|([0-9]+)\|([^|\r\n]+)\|([^|\r\n]+)\|([0-9]+)\|([0-9a-f]{40}|none)\|([0-9a-f]{40})$') {
                Fail "LEDGER_CORRUPT: malformed pass log entry '$ln'" 1
            }
            [void]$passLog.Add(@{
                seq = [int]$Matches[1]
                scope = $Matches[2]
                kind = $Matches[3]
                delta = [int]$Matches[4]
                ref_sha = $Matches[5]
                chain_hash = $Matches[6]
            })
            continue
        }
        $eq = $ln.IndexOf('=')
        if ($eq -lt 1) { Fail "LEDGER_CORRUPT: unexpected line '$ln'" 1 }
        $k = $ln.Substring(0, $eq).Trim()
        $v = $ln.Substring($eq + 1).Trim()
        if ($meta.ContainsKey($k)) { Fail "LEDGER_CORRUPT: duplicate key '$k'" 1 }
        $meta[$k] = $v
    }
    foreach ($req in @('schema', 'base_sha', 'head_sha', 'target_ref', 'snapshot_sha', 'size_class', 'normalized_legacy_size', 'risk_level', 'risk_signals', 'recommended_specialists', 'contract_files', 'generated_files', 'max_concurrency', 'max_passes', 'passes_used', 'budget_status', 'cross_unit_status', 'cross_unit_tree_hash', 'unit_count')) {
        if (-not $meta.ContainsKey($req) -or $meta[$req] -eq '') { Fail "LEDGER_CORRUPT: missing key '$req'" 1 }
    }
    if ($meta['schema'] -cne 'b3-review-ledger-v1') { Fail "LEDGER_CORRUPT: unsupported schema '$($meta['schema'])'" 1 }
    if ($meta['base_sha'] -cnotmatch '^[0-9a-f]{40}$') { Fail 'LEDGER_CORRUPT: invalid base_sha' 1 }
    if ($meta['head_sha'] -cnotmatch '^[0-9a-f]{40}$') { Fail 'LEDGER_CORRUPT: invalid head_sha' 1 }
    if (-not $meta.ContainsKey('target_sha') -or $meta['target_sha'] -eq '') {
        if ($meta['target_ref'] -ceq 'working_tree') {
            $meta['target_sha'] = 'none'
        } elseif ($meta['target_ref'] -cmatch '^[0-9a-f]{40}$') {
            $meta['target_sha'] = $meta['target_ref']
        } else {
            Fail 'LEDGER_CORRUPT: missing target_sha for symbolic target_ref' 1
        }
    }
    if ($meta['target_ref'] -ceq 'working_tree') {
        if ($meta['target_sha'] -cne 'none') { Fail 'LEDGER_CORRUPT: invalid target_sha' 1 }
    } elseif ($meta['target_sha'] -cnotmatch '^[0-9a-f]{40}$') {
        Fail 'LEDGER_CORRUPT: invalid target_sha' 1
    }
    if ($meta['max_passes'] -cnotmatch '^[0-9]+$' -or $meta['passes_used'] -cnotmatch '^[0-9]+$') {
        Fail 'LEDGER_CORRUPT: invalid pass counter' 1
    }
    if (-not $meta.ContainsKey('pass_chain') -or $meta['pass_chain'] -eq '') {
        Fail 'LEDGER_CORRUPT: missing pass_chain' 1
    }
    if ($meta['pass_chain'] -cnotmatch '^[0-9a-f]{40}$') { Fail 'LEDGER_CORRUPT: invalid pass_chain' 1 }
    if (-not $meta.ContainsKey('review_independence') -or $meta['review_independence'] -eq '') {
        Fail 'LEDGER_CORRUPT: missing review_independence' 1
    }
    if ($meta['review_independence'] -cnotin @('UNKNOWN', 'INDEPENDENT', 'SINGLE_AGENT_LIMIT')) {
        Fail "LEDGER_CORRUPT: invalid review_independence '$($meta['review_independence'])'" 1
    }
    if (-not $meta.ContainsKey('l1_specialists') -or $meta['l1_specialists'] -eq '') { $meta['l1_specialists'] = 'none' }
    if (-not $meta.ContainsKey('l1_skip_rationale') -or $meta['l1_skip_rationale'] -eq '') { $meta['l1_skip_rationale'] = 'none' }
    $normSize = Normalize-SizeClass $meta['size_class']
    if (-not $normSize) { Fail "LEDGER_CORRUPT: invalid size_class '$($meta['size_class'])'" 1 }
    if ([int]$meta['unit_count'] -ne $units.Count) { Fail 'LEDGER_CORRUPT: unit_count mismatch' 1 }
    $meta['Units'] = @($units)
    $meta['PassLog'] = $passLog
    return $meta
}

function Invoke-ReviewLedgerCheck([string]$Root, [string]$LedgerFull, [string]$LedgerRel, [string[]]$IgnPaths) {
    if (-not (Test-Path -LiteralPath $LedgerFull -PathType Leaf)) {
        Fail "LEDGER_MISSING: $LedgerRel" 1
    }
    $ledger = Parse-ReviewLedger $LedgerFull
    $origRawSize = $ledger['size_class']
    $normSize = Normalize-SizeClass $origRawSize
    $legacyNormNote = if ($origRawSize -cne $normSize) { "${origRawSize}:${normSize}" } else { $ledger['normalized_legacy_size'] }
    $ledger['size_class'] = $normSize
    $ledger['normalized_legacy_size'] = $legacyNormNote
    $targetRefVal = $ledger['target_ref']
    $targetCommitSha = if ($targetRefVal -cne 'working_tree') { $ledger['target_sha'] } else { '' }

    Verify-LedgerPassChain $Root $ledger
    $maxP = [int]$ledger['max_passes']
    $usedP = [int]$ledger['passes_used']
    if ($maxP -le 0) {
        Fail "LEDGER_INCOMPLETE: unbounded or invalid max_passes ($maxP)" 2
    }
    if ($ledger['budget_status'] -ceq 'EXHAUSTED' -or $usedP -gt $maxP) {
        Fail "LEDGER_INCOMPLETE: budget exhausted (passes=$usedP/$maxP)" 2
    }
    $reviewedCntChk = @($ledger.Units | Where-Object { $_.status -ceq 'REVIEWED' }).Count
    $minReqPasses = $reviewedCntChk + $(if ($ledger['cross_unit_status'] -ceq 'REVIEWED') { 1 } else { 0 })
    if ($usedP -lt $minReqPasses) {
        Fail "LEDGER_INCOMPLETE: passes_used ($usedP) below minimum reviewed passes ($minReqPasses)" 2
    }
    if ($normSize -in @('L', 'XL') -and $ledger.Units.Count -gt 4) {
        Fail "LEDGER_INCOMPLETE: $normSize PR exceeds max 4 units ($($ledger.Units.Count))" 2
    }
    foreach ($uChkBound in $ledger.Units) {
        if (Test-IsOversizedUnit $uChkBound.files_cnt $uChkBound.lines_cnt) {
            Fail "LEDGER_INCOMPLETE: oversized unit $($uChkBound.unit_id) ($($uChkBound.files_cnt)f, $($uChkBound.lines_cnt)L)" 2
        }
    }
    if ($targetRefVal -cne 'working_tree') {
        $trChkRes = Invoke-GitCommand $Root @('rev-parse', '--verify', '--quiet', "${targetRefVal}^{commit}")
        $trChkSha = $trChkRes.StdOut.Trim()
        if ($trChkRes.ExitCode -ne 0 -or $trChkSha -cnotmatch '^[0-9a-f]{40}$') {
            Fail "LEDGER_STALE: target_ref '$targetRefVal' cannot be resolved" 2
        }
        if ($trChkSha -cne $targetCommitSha) {
            Fail "LEDGER_STALE: target_ref '$targetRefVal' moved (${targetCommitSha}->${trChkSha})" 2
        }
        if ($ledger['head_sha'] -cne $trChkSha) {
            Fail "LEDGER_STALE: head_sha moved ($($ledger['head_sha'])->${trChkSha})" 2
        }
    } else {
        $hdChkRes = Invoke-GitCommand $Root @('rev-parse', '--verify', '--quiet', 'HEAD^{commit}')
        $hdChkSha = $hdChkRes.StdOut.Trim()
        if ($hdChkRes.ExitCode -ne 0 -or $hdChkSha -cnotmatch '^[0-9a-f]{40}$') {
            Fail 'LEDGER_STALE: HEAD cannot be resolved' 2
        }
        if ($hdChkSha -cne $ledger['head_sha']) {
            Fail "LEDGER_STALE: head_sha moved ($($ledger['head_sha'])->${hdChkSha})" 2
        }
    }

    $liveScope = Invoke-CollectScopeData $Root $ledger['base_sha'] $targetCommitSha $IgnPaths 'LEDGER_FAIL'
    if ($liveScope.ReviewFiles.Count -eq 0 -and $liveScope.NoiseFiles.Count -eq 0) {
        Fail 'LEDGER_INCOMPLETE: empty diff target' 2
    }

    $liveSize = Get-TShirtSize $liveScope.ReviewFiles.Count $liveScope.TotalLines
    if ((Get-SizeRank $liveSize) -gt (Get-SizeRank $normSize)) {
        Fail "LEDGER_STALE: size_class escalated ($normSize->$liveSize)" 2
    }

    $riskEvalPaths = if ($liveScope.ReviewFiles.Count -gt 0) { $liveScope.ReviewFiles } else { $liveScope.NoiseFiles }
    $liveOverallRisk = Eval-RiskForSubset $riskEvalPaths $liveScope.FileSignals $liveScope.FileLines
    if ($ledger['review_independence'] -ceq 'SINGLE_AGENT_LIMIT' -and $liveOverallRisk.RiskLevel -in @('HIGH', 'CRITICAL')) {
        Fail 'LEDGER_INCOMPLETE: single_agent_limit_blocks_high_risk' 2
    }
    if ($ledger['review_independence'] -ceq 'UNKNOWN' -and $liveOverallRisk.RiskLevel -in @('HIGH', 'CRITICAL')) {
        Fail 'LEDGER_INCOMPLETE: review_independence_unknown_blocks_high_risk' 2
    }

    $assignedSet = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::Ordinal)
    foreach ($u in $ledger.Units) {
        foreach ($uf in @(Split-CsvList $u.files_csv -AsPaths)) { $assignedSet[$uf] = $true }
    }
    $uncovered = @($liveScope.ReviewFiles | Where-Object { -not $assignedSet.ContainsKey($_) })
    if ($uncovered.Count -gt 0) {
        Fail ("LEDGER_INCOMPLETE: uncovered files ($((Sort-Ordinal $uncovered) -join ','))") 2
    }

    $liveContracts = @($liveScope.ReviewFiles | Where-Object { Test-ContractPath $_ })
    $unitCount = $ledger.Units.Count
    $verifiedReceipts = @{}
    foreach ($u in $ledger.Units) {
        $uid = $u.unit_id
        if ($u.status -ceq 'BLOCKED') { Fail "LEDGER_BLOCKED: unit $uid" 2 }
        if ($u.status -ceq 'STALE') { Fail "LEDGER_STALE: unit $uid" 2 }
        if ($u.status -cne 'REVIEWED') { Fail "LEDGER_INCOMPLETE: unit $uid status=$($u.status)" 2 }
        if ($u.findings -cmatch '(^|[^A-Za-z0-9_])(OPEN|FIXED|CONFIRMED|NEW|INVESTIGATING)([^A-Za-z0-9_]|$)') {
            Fail "LEDGER_INCOMPLETE: unresolved findings in $uid ($($u.findings))" 2
        }

        $uFiles = @(Split-CsvList $u.files_csv -AsPaths)
        $liveURisk = Eval-RiskForSubset $uFiles $liveScope.FileSignals $liveScope.FileLines
        if ($ledger['review_independence'] -ceq 'SINGLE_AGENT_LIMIT' -and $liveURisk.RiskLevel -in @('HIGH', 'CRITICAL')) {
            Fail 'LEDGER_INCOMPLETE: single_agent_limit_blocks_high_risk' 2
        }
        if ($ledger['review_independence'] -ceq 'UNKNOWN' -and $liveURisk.RiskLevel -in @('HIGH', 'CRITICAL')) {
            Fail 'LEDGER_INCOMPLETE: review_independence_unknown_blocks_high_risk' 2
        }
        if ($liveURisk.RiskLevel -cne $u.risk) {
            Fail "LEDGER_STALE: unit $uid risk changed ($($u.risk)->$($liveURisk.RiskLevel))" 2
        }
        if ($liveURisk.RecommendedSpecialists -cne 'none') {
            $recSp = @(Split-CsvList $u.specialists)
            $missingSp = @((Split-CsvList $liveURisk.RecommendedSpecialists) | Where-Object { $_ -notin $recSp })
            if ($missingSp.Count -gt 0) {
                if ($liveURisk.RiskLevel -ceq 'CRITICAL') {
                    if (Test-WaiverAttempt $u.rationale) {
                        Fail "LEDGER_BLOCKED: unverified CRITICAL specialist waiver rejected on $uid (missing $($missingSp -join ','); self-declared waivers are disabled without trusted owner approval)" 2
                    }
                    Fail "LEDGER_INCOMPLETE: mandatory CRITICAL specialist ($($missingSp -join ',')) required on $uid (waivers disabled without trusted owner approval)" 2
                } elseif ($liveURisk.RiskLevel -ceq 'HIGH') {
                    if (-not (Test-HighSkipRationale $u.rationale)) {
                        Fail "LEDGER_INCOMPLETE: missing specialist ($($missingSp -join ',')) or valid HIGH skip rationale on $uid" 2
                    }
                } else {
                    $ratTrim = if ($u.rationale) { $u.rationale.Trim() } else { '' }
                    if ($ratTrim -ceq 'none' -or $ratTrim.Length -lt 5 -or (Test-WaiverAttempt $ratTrim)) {
                        Fail "LEDGER_INCOMPLETE: missing specialist ($($missingSp -join ',')) or rationale on $uid" 2
                    }
                }
            }
        }

        $curUHash = Get-ScopePathsTreeHash $Root $targetCommitSha ($uFiles + $liveContracts) $IgnPaths
        if ($curUHash -cne $u.unit_tree_hash) {
            Fail "LEDGER_STALE: unit $uid invalidated (files or shared contracts changed)" 2
        }

        $liveUFiles = $uFiles.Count
        $liveULines = 0
        foreach ($ufItem in $uFiles) {
            if ($liveScope.FileLines.ContainsKey($ufItem)) { $liveULines += [int]$liveScope.FileLines[$ufItem] }
        }
        if (Test-IsOversizedUnit $liveUFiles $liveULines) {
            Fail "LEDGER_INCOMPLETE: oversized unit $uid (${liveUFiles}f, ${liveULines}L)" 2
        }

        $hasCodeFile = (@($uFiles | Where-Object { -not ((Test-DocOrAssetPath $_) -or (Test-TestPath $_)) })).Count -gt 0
        if ($u.verify_receipt -ceq 'none') {
            if ($hasCodeFile -and $u.risk -in @('HIGH', 'CRITICAL')) {
                Fail "LEDGER_INCOMPLETE: missing verify_receipt for $($u.risk) unit $uid" 2
            }
        } else {
            $vr = Test-VerifyReceipt $Root $u.verify_receipt $IgnPaths '' $u.files_csv $targetCommitSha
            if ($vr.Code -eq 2) { Fail "LEDGER_STALE: unit $uid receipt invalid ($($vr.Message))" 2 }
            if ($vr.Code -ne 0) { Fail "LEDGER_INCOMPLETE: unit $uid receipt invalid ($($vr.Message))" 2 }
            if ($targetCommitSha) {
                $verifiedReceipts[$uid] = @{ Receipt = $u.verify_receipt; TargetCommitSha = $targetCommitSha; Vr = $vr }
            }
        }
    }
    $ledger.VerifiedReceipts = $verifiedReceipts

    if ($normSize -in @('L', 'XL', 'XXL') -and $unitCount -gt 1) {
        if ($ledger['cross_unit_status'] -ceq 'BLOCKED') { Fail 'LEDGER_BLOCKED: cross_unit blocked' 2 }
        if ($ledger['cross_unit_status'] -ceq 'STALE') { Fail 'LEDGER_STALE: cross_unit stale' 2 }
        if ($ledger['cross_unit_status'] -cne 'REVIEWED') { Fail "LEDGER_INCOMPLETE: cross_unit_status=$($ledger['cross_unit_status'])" 2 }
        $cuPaths = if ($liveContracts.Count -gt 0) { $liveContracts } else { $liveScope.ReviewFiles }
        $curCuHash = Get-ScopePathsTreeHash $Root $targetCommitSha $cuPaths $IgnPaths
        if ($curCuHash -cne $ledger['cross_unit_tree_hash']) {
            Fail 'LEDGER_STALE: cross_unit invalidated' 2
        }
    }

    $normTag = if ($origRawSize -cne $normSize) { " normalized_from=$origRawSize" } else { '' }
    return @{
        Code = 0
        Message = "LEDGER_GATE_PASS: size=$normSize risk=$($ledger['risk_level']) units=$unitCount/$unitCount cross_unit=$($ledger['cross_unit_status']) review_independence=$($ledger['review_independence'])${normTag}"
        Ledger = $ledger
    }
}

function Test-HasControlChars([string]$Val) {
    if ([string]::IsNullOrEmpty($Val)) { return $false }
    return ($Val -match '[\x00-\x1F\x7F]')
}

function Test-ValidContextScopeId([string]$Val) {
    if ([string]::IsNullOrEmpty($Val)) { return $false }
    if ($Val -cnotmatch '^[A-Za-z0-9._/-]{1,80}$') { return $false }
    if ($Val -ceq '.' -or $Val.StartsWith('/') -or $Val.EndsWith('/')) { return $false }
    if ($Val.Contains('//')) { return $false }
    if (($Val -match '(^|/)\.\.(/|$)') -or ($Val -match '(^|/)\.(/|$)')) { return $false }
    return $true
}

function Test-CheckpointFilePath([string]$Root, [string]$PathArg) {
    if ([string]::IsNullOrEmpty($PathArg)) { return @{ Status = 'INVALID'; Rel = ''; Full = '' } }
    if ($PathArg -match '[\x00-\x1F\x7F]') { return @{ Status = 'INVALID'; Rel = ''; Full = '' } }
    if ([string]::IsNullOrWhiteSpace($PathArg)) { return @{ Status = 'INVALID'; Rel = ''; Full = '' } }
    if ($PathArg.EndsWith(' ')) { return @{ Status = 'INVALID'; Rel = ''; Full = '' } }
    $trimmed = $PathArg.Trim()
    if ($trimmed.Contains(':')) { return @{ Status = 'INVALID'; Rel = ''; Full = '' } }
    $rawSlash = $trimmed -replace '\\', '/'
    if (-not $rawSlash -or $rawSlash.EndsWith('/')) { return @{ Status = 'INVALID'; Rel = ''; Full = '' } }
    $p = Normalize-PathValue $trimmed
    if (-not $p -or $p -eq '.' -or $p.StartsWith('/') -or $p.StartsWith('~') -or $p.Contains(':') -or $p.Contains('//') -or ($p -match '(^|/)\.\.(/|$)') -or ($p -match '(^|/)\.(/|$)')) {
        return @{ Status = 'INVALID'; Rel = ''; Full = '' }
    }
    foreach ($seg in ($p -split '/')) {
        if (-not $seg -or $seg.EndsWith('.') -or $seg.EndsWith(' ')) {
            return @{ Status = 'INVALID'; Rel = ''; Full = '' }
        }
    }
    if ($p -cnotmatch '^\.b3/(ship|research-ship)/.+$') {
        return @{ Status = 'INVALID'; Rel = ''; Full = '' }
    }
    if (Test-SecretPath $p) {
        return @{ Status = 'INVALID'; Rel = ''; Full = '' }
    }
    $c = Test-ContainedRepoPath $Root $p
    if (-not $c) {
        return @{ Status = 'SYMLINK_OR_DIR'; Rel = $p; Full = '' }
    }
    if ((Test-Path -LiteralPath $c.Full -PathType Container) -or (Test-IsReparsePath $c.Full)) {
        return @{ Status = 'SYMLINK_OR_DIR'; Rel = $c.Rel; Full = $c.Full }
    }
    return @{ Status = 'OK'; Rel = $c.Rel; Full = $c.Full }
}

function Split-StrictPaths([string]$Root, [string]$Csv, [bool]$AllowEmptySentinel = $true, [bool]$BlockB3AndSecrets = $true) {
    if ([string]::IsNullOrEmpty($Csv)) {
        if ($AllowEmptySentinel) { return @{ Ok = $true; Items = @(); BadToken = '' } }
        return @{ Ok = $false; Items = @(); BadToken = '<empty>' }
    }
    if ($Csv -match '[\x00-\x1F\x7F]') {
        return @{ Ok = $false; Items = @(); BadToken = $Csv }
    }
    $cleaned = $Csv.Trim()
    if ($AllowEmptySentinel -and (-not $cleaned -or $Csv -ceq 'none' -or $Csv -ceq '[]')) {
        return @{ Ok = $true; Items = @(); BadToken = '' }
    }
    if (-not $cleaned) {
        return @{ Ok = $false; Items = @(); BadToken = '<empty>' }
    }
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($rawPart in ($Csv -split ',')) {
        $tok = $rawPart.TrimStart(' ')
        if (-not $tok) {
            return @{ Ok = $false; Items = @(); BadToken = '<empty>' }
        }
        if ($tok -ceq 'none' -or $tok.StartsWith('-') -or $tok.Contains(':') -or ($tok -match '[\*\?\[\]]')) {
            return @{ Ok = $false; Items = @(); BadToken = $tok }
        }
        $c = Test-ContainedRepoPath $Root $tok
        if (-not $c) {
            return @{ Ok = $false; Items = @(); BadToken = $tok }
        }
        $rel = $c.Rel
        if (-not $rel -or $rel -ceq '.' -or $rel.StartsWith('-') -or $rel.Contains('//') -or ($rel -match '(^|/)\.(/|$)') -or ($rel -imatch '(^|/)\.git(/|$)')) {
            return @{ Ok = $false; Items = @(); BadToken = $tok }
        }
        if ($BlockB3AndSecrets -and (($rel -imatch '^\.b3(/|$)') -or (Test-SecretPath $rel))) {
            return @{ Ok = $false; Items = @(); BadToken = $tok }
        }
        $list.Add($rel)
    }
    if ($list.Count -eq 0 -and -not $AllowEmptySentinel) {
        return @{ Ok = $false; Items = @(); BadToken = '<empty>' }
    }
    $sorted = @(Sort-Ordinal $list.ToArray())
    return @{ Ok = $true; Items = $sorted; BadToken = '' }
}

function Test-IgnoreOverlapsPaths([string[]]$IgnPaths, [string[]]$TargetPaths) {
    if (-not $IgnPaths -or $IgnPaths.Count -eq 0 -or -not $TargetPaths -or $TargetPaths.Count -eq 0) {
        return $false
    }
    foreach ($p in $TargetPaths) {
        if (-not $p) { continue }
        foreach ($ign in $IgnPaths) {
            if (-not $ign) { continue }
            if ($p -ceq $ign -or $p.StartsWith("$ign/", [System.StringComparison]::Ordinal) -or $ign.StartsWith("$p/", [System.StringComparison]::Ordinal)) {
                return $true
            }
        }
    }
    return $false
}

function Resolve-StrictCommitSha([string]$Root, [string]$Rev) {
    if ([string]::IsNullOrWhiteSpace($Rev)) { return $null }
    $r = $Rev.Trim()
    if ($r.StartsWith('-') -or ($r -match '\s')) { return $null }
    $res = Invoke-GitCommand $Root @('rev-parse', '--verify', '--quiet', "${r}^{commit}")
    if ($res.ExitCode -ne 0) { return $null }
    $sha = $res.StdOut.Trim()
    if ($sha -cnotmatch '^[0-9a-f]{40}$') { return $null }
    return $sha
}

function Test-GraphIndexFresh([string]$Root, [string]$GraphSha, [string]$LiveHeadSha, [string[]]$ProbePaths, [string[]]$IgnPaths) {
    if ($GraphSha -cne $LiveHeadSha) {
        return $false
    }
    if ($ProbePaths -and $ProbePaths.Count -gt 0) {
        $wList = @(Invoke-GitPathsZ $Root (@('diff', '--no-ext-diff', '--no-renames', '--name-only', '--ignore-submodules=none', '-z', $GraphSha, '--') + $ProbePaths) 'names' 'CONTEXT_ERROR')
        $cList = @(Invoke-GitPathsZ $Root (@('diff', '--no-ext-diff', '--no-renames', '--cached', '--name-only', '--ignore-submodules=none', '-z', $GraphSha, '--') + $ProbePaths) 'names' 'CONTEXT_ERROR')
        $uList = @(Invoke-GitPathsZ $Root (@('ls-files', '--others', '--exclude-standard', '-z', '--') + $ProbePaths) 'names' 'CONTEXT_ERROR')
        foreach ($p in (@($wList) + @($cList) + @($uList))) {
            if (-not $p) { continue }
            if (Test-CheckpointPath $p) { continue }
            if ($IgnPaths -and (Test-PathMatch $p $IgnPaths)) { continue }
            return $false
        }
        return $true
    }

    $stRes = Invoke-GitCommand $Root @('status', '--porcelain', '--untracked-files=all', '--ignore-submodules=none', '-z')
    if ($stRes.ExitCode -ne 0) { Fail 'CONTEXT_ERROR: git status failed' 1 }
    $nul = [char]0
    $records = $stRes.StdOut.Split($nul)
    $recLen = $records.Length
    if ($recLen -gt 0 -and $records[$recLen - 1] -eq '') { $recLen-- }
    for ($i = 0; $i -lt $recLen; $i++) {
        $rec = $records[$i]
        if ([string]::IsNullOrEmpty($rec)) { continue }
        if ($rec.Length -lt 4) { return $false }
        $xy = $rec.Substring(0, 2)
        $p1 = ($rec.Substring(3)).TrimEnd('/')
        if (-not $p1) { return $false }
        $p1Ign = (Test-CheckpointPath $p1) -or ($IgnPaths -and (Test-PathMatch $p1 $IgnPaths))
        if ($xy[0] -ceq 'R' -or $xy[0] -ceq 'C' -or $xy[1] -ceq 'R' -or $xy[1] -ceq 'C') {
            $i++
            if ($i -ge $recLen) { return $false }
            $p2 = ($records[$i]).TrimEnd('/')
            if (-not $p2) { return $false }
            $p2Ign = (Test-CheckpointPath $p2) -or ($IgnPaths -and (Test-PathMatch $p2 $IgnPaths))
            if (-not ($p1Ign -and $p2Ign)) { return $false }
        } else {
            if (-not $p1Ign) { return $false }
        }
    }
    return $true
}

function Get-EffectiveRepoPathState([string]$Root, [string]$RelPath, [string]$FailPrefix = 'MECHANICAL_FAIL') {
    $full = Join-Path $Root ($RelPath -replace '/', '\')
    $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
    if (-not (Test-WavePathContained $Root $RelPath)) {
        if ($item -and (Test-IsReparseItem $item)) {
            $isSymLeaf = (-not $item.PSObject.Properties['LinkType']) -or ($item.LinkType -ceq 'SymbolicLink')
            if ($isSymLeaf) {
                $parentRel = (Split-Path -Parent ($RelPath -replace '/', '\')) -replace '\\', '/'
                if ((-not $parentRel) -or $parentRel -ceq '.' -or (Test-WavePathContained $Root $parentRel)) {
                    $lSha = Get-SymlinkBlobOid $Root $RelPath
                    if ($lSha) { return "120000:$lSha" }
                }
            }
        }
        return 'UNSAFE_REPARSE'
    }
    $hasHeadEff = (Invoke-GitCommand $Root @('rev-parse', '--verify', '--quiet', 'HEAD')).ExitCode -eq 0
    if ($hasHeadEff) {
        $caHeadRes = Invoke-GitCommand $Root @('diff', '--no-ext-diff', '--cached', '--no-renames', '--name-only', '-z', 'HEAD', '--', $RelPath)
        if ($caHeadRes.ExitCode -ne 0) { Fail "${FailPrefix}: git diff --cached failed for ${RelPath}" 1 }
        if ($caHeadRes.StdOut) {
            $iwRes = Invoke-GitCommand $Root @('diff', '--no-ext-diff', '--no-renames', '--name-only', '-z', '--', $RelPath)
            if ($iwRes.ExitCode -ne 0) { Fail "${FailPrefix}: git diff failed for ${RelPath}" 1 }
            $caDelRes = Invoke-GitCommand $Root @('diff', '--no-ext-diff', '--cached', '--no-renames', '--diff-filter=D', '--name-only', '-z', '--', $RelPath)
            if ($caDelRes.ExitCode -ne 0) { Fail "${FailPrefix}: git diff --cached -D failed for ${RelPath}" 1 }
            $existsNow = ($null -ne $item) -or (Test-Path -LiteralPath $full)
            if ($iwRes.StdOut -or ($caDelRes.StdOut -and $existsNow)) {
                return 'INDEX_WT_DIVERGED'
            }
        }
    }
    if ($null -eq $item -and (-not (Test-Path -LiteralPath $full))) {
        return 'DELETED'
    }
    if ($item -and (Test-IsReparseItem $item)) {
        $isSym = (-not $item.PSObject.Properties['LinkType']) -or ($item.LinkType -ceq 'SymbolicLink')
        if ($isSym) {
            $lSha = Get-SymlinkBlobOid $Root $RelPath
            if ($lSha) { return "120000:$lSha" }
        }
        return 'UNSAFE_REPARSE'
    }
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        $hRes = Invoke-GitCommand $Root @('hash-object', '--', $RelPath)
        $hSha = $hRes.StdOut.Trim()
        if ($hRes.ExitCode -ne 0 -or $hSha -cnotmatch '^[0-9a-f]{40}$') {
            $detail = if ($hRes.StdErr.Trim()) { $hRes.StdErr.Trim() } else { $hSha }
            Fail "${FailPrefix}: git hash-object failed for ${RelPath}: $detail" 1
        }
        return "blob:$hSha"
    }
    if (Test-Path -LiteralPath $full -PathType Container) {
        if (Test-Path -LiteralPath (Join-Path $full '.git')) {
            $subId = Get-SubmoduleEntryIdentity $Root $RelPath ''
            if ($subId) { return "sub:$subId" }
        }
        return 'DIR'
    }
    return 'DELETED'
}

switch ($Command) {
    'fingerprint' {
        $trimmedScope = $Scope.Trim()
        if (-not $trimmedScope) { Fail 'FINGERPRINT_FAIL: missing -Scope' 1 }

        $critList = New-Object System.Collections.Generic.List[string]
        foreach ($entry in @($Criteria)) {
            foreach ($piece in ([string]$entry -split ';')) {
                $t = $piece.Trim()
                if ($t) { $critList.Add($t) }
            }
        }
        if ($critList.Count -lt 1) { Fail 'FINGERPRINT_FAIL: missing -Criteria' 1 }

        $depItems = @(Sort-Ordinal (Split-CsvList $DependsOn))
        $depText = if ($depItems.Count -gt 0) { $depItems -join ',' } else { '[]' }
        $critText = $critList -join '; '
        Write-Output "depends_on=$depText|scope=$trimmedScope|acceptance_criteria=$critText"
        exit 0
    }

    'check-freshness' {
        if (-not $ApproachAtSha) { Fail 'FRESHNESS_FAIL: missing -ApproachAtSha' 1 }
        if (-not $TaskBaseSha) { Fail 'FRESHNESS_FAIL: missing -TaskBaseSha' 1 }
        $watched = @(Split-PathCsvChecked $WatchedPaths 'FRESHNESS_FAIL')
        if ($watched.Count -lt 1) { Fail 'FRESHNESS_FAIL: missing -WatchedPaths' 1 }
        $owned = @(Split-PathCsvChecked $OwnedFiles 'FRESHNESS_FAIL')
        $ignored = @(Split-PathCsvChecked $IgnoreDirtyPaths 'FRESHNESS_FAIL' -RejectDot)

        $resolvedApproachSha = Assert-ValidGitRev $RepoRoot ($ApproachAtSha.Trim()) 'commit' 'FRESHNESS_FAIL' '-ApproachAtSha'
        $resolvedTaskBaseSha = Assert-ValidGitRev $RepoRoot ($TaskBaseSha.Trim()) 'commit' 'FRESHNESS_FAIL' '-TaskBaseSha'
        $resolvedHeadSha = Assert-ValidGitRev $RepoRoot 'HEAD' 'commit' 'FRESHNESS_FAIL' 'HEAD'

        $mbRes = Invoke-GitCommand $RepoRoot @('merge-base', '--is-ancestor', $resolvedTaskBaseSha, $resolvedHeadSha)
        if ($mbRes.ExitCode -eq 1) {
            Fail 'STALE: HEAD is not a descendant of task_base' 2
        } elseif ($mbRes.ExitCode -ne 0) {
            $detail = if ($mbRes.StdErr.Trim()) { $mbRes.StdErr.Trim() } else { $mbRes.StdOut.Trim() }
            Fail "FRESHNESS_FAIL: git merge-base failed: $detail" 1
        }

        $mbAppRes = Invoke-GitCommand $RepoRoot @('merge-base', '--is-ancestor', $resolvedApproachSha, $resolvedHeadSha)
        if ($mbAppRes.ExitCode -eq 1) {
            Fail 'STALE: HEAD is not a descendant of approach_at_sha' 2
        } elseif ($mbAppRes.ExitCode -ne 0) {
            $detail = if ($mbAppRes.StdErr.Trim()) { $mbAppRes.StdErr.Trim() } else { $mbAppRes.StdOut.Trim() }
            Fail "FRESHNESS_FAIL: git merge-base failed: $detail" 1
        }

        $committed = @(Invoke-GitLines $RepoRoot @('diff', '--no-ext-diff', '--no-renames', '--name-only', $resolvedApproachSha, $resolvedHeadSha, '--'))
        $committedHits = @($committed | Where-Object {
            (-not (Test-CheckpointPath $_)) -and (Test-PathMatch $_ $watched)
        } | Sort-Object -Unique)
        if ($committedHits.Count -gt 0) {
            Fail ("STALE: committed change in watched_paths (" + ($committedHits -join ', ') + ")") 2
        }

        $readOnlyWatched = @($watched | Where-Object { -not (Test-PathMatch $_ $owned) })
        if ($readOnlyWatched.Count -gt 0) {
            $wtDiff = @(Invoke-GitLines $RepoRoot @('diff', '--no-ext-diff', '--no-renames', '--name-only', $resolvedApproachSha, '--'))
            $cached = @(Invoke-GitLines $RepoRoot @('diff', '--no-ext-diff', '--no-renames', '--cached', '--name-only', '--'))
            $untracked = @(Invoke-GitLines $RepoRoot @('ls-files', '--others', '--exclude-standard'))

            $uncommitted = New-Object System.Collections.Generic.List[string]
            foreach ($p in (@($wtDiff) + @($cached) + @($untracked))) {
                if (-not $p) { continue }
                if (Test-CheckpointPath $p) { continue }
                if (Test-PathMatch $p $ignored) { continue }
                if (-not $uncommitted.Contains($p)) { $uncommitted.Add($p) }
            }

            $roHits = @($uncommitted | Where-Object {
                (-not (Test-PathMatch $_ $owned)) -and (Test-PathMatch $_ $readOnlyWatched)
            } | Sort-Object -Unique)
            if ($roHits.Count -gt 0) {
                Fail ("STALE: uncommitted change in read_only_deps (" + ($roHits -join ', ') + ")") 2
            }
        }

        Write-Output 'FRESH'
        exit 0
    }

    'precommit' {
        $midOp = Test-GitMidOperation $RepoRoot
        if ($midOp) {
            Fail "PRECOMMIT_FAIL: git operation in progress ($midOp)" 1
        }

        $allowed = @(Split-PathCsvChecked $AllowedPaths 'PRECOMMIT_FAIL')
        $ignored = @(Split-PathCsvChecked $IgnoreDirtyPaths 'PRECOMMIT_FAIL' -RejectDot)
        $staged = @(Invoke-GitLines $RepoRoot @('diff', '--no-ext-diff', '--no-renames', '--cached', '--name-only', '--'))
        if ($staged.Count -lt 1) {
            Fail 'PRECOMMIT_FAIL: nothing staged' 1
        }

        $checkpointHits = @($staged | Where-Object {
            (Test-CheckpointPath $_) -or (($_ -imatch '^\.b3(/|$)') -and -not (Test-PathMatch $_ $allowed))
        })
        if ($checkpointHits.Count -gt 0) {
            Fail ("PRECOMMIT_FAIL: checkpoint staged (" + ($checkpointHits -join ', ') + ")") 1
        }

        if ($allowed.Count -lt 1) {
            Fail 'PRECOMMIT_FAIL: missing -AllowedPaths' 1
        }

        $secretHits = New-Object System.Collections.Generic.List[string]
        foreach ($p in $staged) {
            if (Test-SecretPath $p) {
                $exactOk = $false
                foreach ($a in $allowed) {
                    if ($p -ceq $a) { $exactOk = $true; break }
                }
                if (-not $exactOk) { $secretHits.Add($p) }
            }
        }
        if ($secretHits.Count -gt 0) {
            Fail ("PRECOMMIT_FAIL: secret path staged without exact allow (" + ($secretHits -join ', ') + ")") 1
        }

        $undeclared = @($staged | Where-Object { -not (Test-PathMatch $_ $allowed) })
        if ($undeclared.Count -gt 0) {
            Fail ("PRECOMMIT_FAIL: undeclared staged path (" + ($undeclared -join ', ') + ")") 1
        }

        if ($RequireVerifyReceipt -and $RequireVerifyReceipt.Trim()) {
            $wtMismatch = New-Object System.Collections.Generic.List[string]
            $idxVsWt = @(Invoke-GitLines $RepoRoot (@('diff', '--no-ext-diff', '--no-renames', '--ignore-submodules=none', '--name-only', '--') + $staged))
            foreach ($p in $idxVsWt) { $wtMismatch.Add($p) }
            $stagedDel = @(Invoke-GitLines $RepoRoot @('diff', '--no-ext-diff', '--no-renames', '--cached', '--diff-filter=D', '--name-only', '--'))
            foreach ($d in $stagedDel) {
                if ((Test-Path -LiteralPath (Join-Path $RepoRoot ($d -replace '/', '\'))) -and -not $wtMismatch.Contains($d)) {
                    $wtMismatch.Add($d)
                }
            }
            if ($wtMismatch.Count -gt 0) {
                $sortedMm = (Sort-Ordinal $wtMismatch.ToArray()) -join ', '
                Fail "PRECOMMIT_FAIL: staged content differs from working tree ($sortedMm)" 1
            }

            if ($ignored.Count -gt 0) {
                $stagedIgnored = @($staged | Where-Object { Test-PathMatch $_ $ignored })
                if ($stagedIgnored.Count -gt 0) {
                    $sortedSi = (Sort-Ordinal $stagedIgnored) -join ', '
                    Fail "PRECOMMIT_FAIL: staged path excluded by ignore-dirty-paths ($sortedSi)" 1
                }
            }
            $vr = Test-VerifyReceipt $RepoRoot $RequireVerifyReceipt $ignored
            if ($vr.Code -ne 0) {
                Fail "PRECOMMIT_FAIL: verification receipt check failed ($($vr.Message))" 1
            }
            if ($vr.RelevantPathsCsv -cne 'ALL') {
                $recPaths = @(Split-CsvList $vr.RelevantPathsCsv -AsPaths)
                $outside = @($staged | Where-Object { -not (Test-PathMatch $_ $recPaths) })
                if ($outside.Count -gt 0) {
                    $sortedOut = (Sort-Ordinal $outside) -join ', '
                    Fail "PRECOMMIT_FAIL: staged path outside receipt scope ($sortedOut)" 1
                }
            }

            $scopeAll = ($vr.RelevantPathsCsv -ceq 'ALL')
            $recScopePaths = @()
            if (-not $scopeAll) {
                $recScopePaths = @(Split-CsvList $vr.RelevantPathsCsv -AsPaths)
                if ($recScopePaths -contains '.') { $scopeAll = $true }
            }
            $unstagedRaw = @(if ($scopeAll) {
                Invoke-GitLines $RepoRoot @('diff', '--no-ext-diff', '--no-renames', '--ignore-submodules=none', '--name-only', '--')
            } else {
                Invoke-GitLines $RepoRoot (@('diff', '--no-ext-diff', '--no-renames', '--ignore-submodules=none', '--name-only', '--') + $recScopePaths)
            })
            $untrackedScopeRaw = @(if ($scopeAll) {
                Invoke-GitLines $RepoRoot @('ls-files', '--others', '--exclude-standard')
            } else {
                Invoke-GitLines $RepoRoot (@('ls-files', '--others', '--exclude-standard', '--') + $recScopePaths)
            })
            $unstagedInScope = New-Object System.Collections.Generic.List[string]
            foreach ($u in (@($unstagedRaw) + @($untrackedScopeRaw))) {
                if (-not $u -or (Test-CheckpointPath $u)) { continue }
                if ($ignored -and (Test-PathMatch $u $ignored)) { continue }
                if (-not $scopeAll -and -not (Test-PathMatch $u $recScopePaths)) { continue }
                if (-not $unstagedInScope.Contains($u)) { $unstagedInScope.Add($u) }
            }
            if ($unstagedInScope.Count -gt 0) {
                $sortedUn = (Sort-Ordinal $unstagedInScope.ToArray()) -join ', '
                Fail "PRECOMMIT_FAIL: unstaged changes in receipt scope ($sortedUn)" 1
            }
        }

        Write-Output 'PRECOMMIT_OK'
        exit 0
    }

    'snapshot' {
        $headSha = Assert-ValidGitRev $RepoRoot 'HEAD' 'commit' 'SNAPSHOT_FAIL' 'HEAD'
        $headTreeRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--verify', '--quiet', 'HEAD^{tree}')
        $headTree = $headTreeRes.StdOut.Trim()
        if ($headTreeRes.ExitCode -ne 0 -or -not $headTree) {
            Fail 'SNAPSHOT_FAIL: failed to resolve HEAD^{tree}' 1
        }
        $curTree = New-WorkingTreeOid $RepoRoot 'SNAPSHOT_FAIL'
        if ($curTree -ceq $headTree) {
            $sha = $headSha
        } else {
            $ctRes = Invoke-GitCommand $RepoRoot @('commit-tree', $curTree, '-p', $headSha, '-m', 'b3-snapshot')
            $sha = $ctRes.StdOut.Trim()
            if ($ctRes.ExitCode -ne 0 -or -not $sha) {
                $detail = if ($ctRes.StdErr.Trim()) { $ctRes.StdErr.Trim() } else { $ctRes.StdOut.Trim() }
                Fail ("SNAPSHOT_FAIL: git commit-tree failed: $detail") 1
            }
        }
        $typeRes = Invoke-GitCommand $RepoRoot @('cat-file', '-t', $sha)
        $objType = $typeRes.StdOut.Trim()
        if ($typeRes.ExitCode -ne 0 -or $objType -ne 'commit') {
            Fail "SNAPSHOT_FAIL: invalid snapshot commit '$sha'" 1
        }
        Write-Output $sha
        exit 0
    }

    'diff-scope' {
        $ignored = @(Split-PathCsvChecked $IgnoreDirtyPaths 'DIFF_SCOPE_FAIL' -RejectDot)
        $scopeTarget = Resolve-ScopeTargetAndBase $RepoRoot $TargetRef $BaseSha $ignored 'DIFF_SCOPE_FAIL' 'object'
        $targetTrim = $scopeTarget.TargetRef
        $targetCommitSha = $scopeTarget.TargetCommitSha
        $resolvedBase = $scopeTarget.BaseSha

        $scopeData = Invoke-CollectScopeData $RepoRoot $resolvedBase $targetCommitSha $ignored 'DIFF_SCOPE_FAIL'
        $reviewFiles = $scopeData.ReviewFiles
        $noiseFiles = $scopeData.NoiseFiles
        $totalLines = [int]$scopeData.TotalLines

        $dfOut = $null
        $deltaArr = @()
        if ($PrevSha -and $PrevSha.Trim()) {
            $prevTrim = $PrevSha.Trim()
            [void](Assert-ValidGitRev $RepoRoot $prevTrim 'commit' 'DIFF_SCOPE_FAIL' '-PrevSha')
            $deltaEnd = if ($targetTrim) { $targetCommitSha } else { New-WorkingTreeOid $RepoRoot 'DIFF_SCOPE_FAIL' }
            $deltaPaths = @(Invoke-GitPathsZ $RepoRoot @('diff', '--no-ext-diff', '--no-renames', '--name-only', '-z', $prevTrim, $deltaEnd, '--') 'names' 'DIFF_SCOPE_FAIL')
            $deltaFiles = New-Object System.Collections.Generic.List[string]
            foreach ($dp in $deltaPaths) {
                if (-not $dp -or (Test-CheckpointPath $dp) -or (Test-PathMatch $dp $ignored)) { continue }
                if (Test-NoiseFile $dp) { continue }
                if (-not $deltaFiles.Contains($dp)) { $deltaFiles.Add($dp) }
            }
            $deltaArr = if ($deltaFiles.Count -gt 0) { @(Sort-Ordinal $deltaFiles.ToArray()) } else { @() }
            $dfOut = if ($deltaArr.Count -gt 0) { $deltaArr -join ',' } else { 'none' }
        }

        if ($reviewFiles.Count -eq 0 -and $noiseFiles.Count -eq 0) {
            if ($null -eq $dfOut -or $dfOut -eq 'none') { Fail 'EMPTY_DIFF' 2 }
            $cleanRisk = Eval-RiskForSubset $deltaArr $null $null
            Write-Output 'size_class=CLEAN_AFTER_FIX'
            Write-Output 'files=0'
            Write-Output 'lines=0'
            Write-Output 'review_files=none'
            Write-Output 'noise_files=none'
            Write-Output "delta_files=$dfOut"
            Write-Output "risk_level=$($cleanRisk.RiskLevel)"
            Write-Output "risk_signals=$($cleanRisk.RiskSignals)"
            Write-Output "recommended_specialists=$($cleanRisk.RecommendedSpecialists)"
            exit 0
        }

        $fileCount = $reviewFiles.Count
        $sizeClass = Get-TShirtSize $fileCount $totalLines
        $riskTarget = if ($reviewFiles.Count -gt 0) { $reviewFiles } else { $noiseFiles }
        $riskRes = Eval-RiskForSubset $riskTarget $scopeData.FileSignals $scopeData.FileLines

        $rfOut = if ($reviewFiles.Count -gt 0) { $reviewFiles -join ',' } else { 'none' }
        $nfOut = if ($noiseFiles.Count -gt 0) { $noiseFiles -join ',' } else { 'none' }
        Write-Output "size_class=$sizeClass"
        Write-Output "files=$fileCount"
        Write-Output "lines=$totalLines"
        Write-Output "review_files=$rfOut"
        Write-Output "noise_files=$nfOut"
        if ($null -ne $dfOut) {
            Write-Output "delta_files=$dfOut"
        }
        Write-Output "risk_level=$($riskRes.RiskLevel)"
        Write-Output "risk_signals=$($riskRes.RiskSignals)"
        Write-Output "recommended_specialists=$($riskRes.RecommendedSpecialists)"
        exit 0
    }

    'mechanical-check' {
        $mcCaseInsensitive = Test-RepoCaseInsensitive $RepoRoot
        $cmpExact = if ($mcCaseInsensitive) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
        $cmpSet = if ($mcCaseInsensitive) { [System.StringComparer]::OrdinalIgnoreCase } else { [System.StringComparer]::Ordinal }
        $repoExistsMc = ($RepoRoot -and (Test-Path -LiteralPath $RepoRoot -PathType Container))

        $hasWaveSpecs = [bool]($WaveSpecs -and $WaveSpecs.Trim())
        $hasWorkerChanges = [bool]($WorkerChanges -and $WorkerChanges.Trim())
        $hasWorkerRoots = [bool]($WorkerRoots -and $WorkerRoots.Trim())
        $hasProtectedArg = [bool]($ProtectedPaths -and $ProtectedPaths.Trim())
        $hasDirtyDigestsArg = $PSBoundParameters.ContainsKey('DirtyDigests')

        if ($hasWorkerChanges -and $hasWorkerRoots) {
            Fail 'MECHANICAL_FAIL: cannot specify both -WorkerChanges and -WorkerRoots' 1
        }
        if ($hasWorkerChanges -and -not $hasWaveSpecs) {
            Fail 'MECHANICAL_FAIL: -WorkerChanges requires -WaveSpecs' 1
        }
        if ($hasWorkerRoots -and -not $hasWaveSpecs) {
            Fail 'MECHANICAL_FAIL: -WorkerRoots requires -WaveSpecs' 1
        }
        if ($hasWorkerRoots -and ($TargetRef -and $TargetRef.Trim())) {
            Fail 'MECHANICAL_FAIL: -WorkerRoots cannot be combined with -TargetRef' 1
        }

        $protectedList = @()
        if ($hasProtectedArg) {
            $parsedProt = ConvertTo-WavePaths $ProtectedPaths -ErrorPrefix 'MECHANICAL_FAIL'
            if ($parsedProt.Error) { Fail $parsedProt.Error 1 }
            $protectedList = @($parsedProt.Paths)
            foreach ($prot in $protectedList) {
                if ($prot -ceq '.') {
                    Fail "MECHANICAL_FAIL: invalid protected path '.'" 1
                }
                if ($repoExistsMc -and (-not (Test-WavePathContained $RepoRoot $prot))) {
                    Fail "MECHANICAL_FAIL: unsafe symlink or junction alias in path '$prot'" 1
                }
            }
        }

        $dirtyDigestMap = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
        $dirtyDigestKeyMap = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
        if ($hasDirtyDigestsArg) {
            if ($DirtyDigests -match '[\x00-\x1F\x7F]') {
                Fail 'MECHANICAL_FAIL: invalid -DirtyDigests' 1
            }
            $ddTrim = if ($null -ne $DirtyDigests) { $DirtyDigests.Trim() } else { '' }
            if ($ddTrim -and $ddTrim -cne 'none' -and $ddTrim -cne '[]') {
                foreach ($ddEntry in ($ddTrim -split ';')) {
                    $ddPart = $ddEntry.Trim()
                    if (-not $ddPart) { continue }
                    $eqIdx = $ddPart.IndexOf('=')
                    if ($eqIdx -lt 1) {
                        Fail "MECHANICAL_FAIL: invalid DirtyDigests entry '$ddPart'" 1
                    }
                    $rawDp = $ddPart.Substring(0, $eqIdx).Trim()
                    $rawDig = $ddPart.Substring($eqIdx + 1).Trim()
                    if ($rawDp.Contains(',')) {
                        Fail "MECHANICAL_FAIL: invalid DirtyDigests path '$rawDp'" 1
                    }
                    $parsedDp = ConvertTo-WavePaths $rawDp -RejectDot -ErrorPrefix 'MECHANICAL_FAIL'
                    if ($parsedDp.Error -or $parsedDp.Paths.Count -ne 1) {
                        Fail "MECHANICAL_FAIL: invalid DirtyDigests path '$rawDp'" 1
                    }
                    $dpNorm = $parsedDp.Paths[0]
                    if (Test-CheckpointPath $dpNorm) {
                        Fail "MECHANICAL_FAIL: invalid DirtyDigests path '$dpNorm'" 1
                    }
                    if ($repoExistsMc -and (-not (Test-WavePathContained $RepoRoot $dpNorm))) {
                        Fail "MECHANICAL_FAIL: unsafe symlink or junction alias in path '$dpNorm'" 1
                    }
                    if ($rawDig -cne 'DELETED' -and $rawDig -notmatch '^[0-9a-fA-F]{64}$') {
                        Fail "MECHANICAL_FAIL: invalid DirtyDigests digest for '$dpNorm'" 1
                    }
                    $normDig = if ($rawDig -ceq 'DELETED') { 'DELETED' } else { $rawDig.ToLowerInvariant() }
                    $ddKey = if ($mcCaseInsensitive) { $dpNorm.ToLowerInvariant() } else { $dpNorm }
                    if ($dirtyDigestKeyMap.ContainsKey($ddKey)) {
                        Fail "MECHANICAL_FAIL: duplicate DirtyDigests path '$dpNorm'" 1
                    }
                    $dirtyDigestMap[$dpNorm] = $normDig
                    $dirtyDigestKeyMap[$ddKey] = $dpNorm
                }
            }
        }

        $wsParsed = $null
        $wcParsed = $null
        $wrOrder = New-Object System.Collections.Generic.List[string]
        $wrMap = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
        $isAttributing = ($hasWorkerChanges -or $hasWorkerRoots)
        if ($hasWaveSpecs) {
            $wsParsed = ConvertTo-WaveTaskMap -Specs $WaveSpecs -Root $RepoRoot -ErrorPrefix 'MECHANICAL_FAIL' -SpecLabel 'WaveSpecs' -EmptyArgLabel '-WaveSpecs' -RejectProtected -RejectDot -AllowEmpty
            foreach ($ti in $wsParsed.Order) {
                foreach ($pi in $wsParsed.Map[$ti]) {
                    foreach ($prot in $protectedList) {
                        $ovProt = Test-WavePathOverlap $pi $prot $mcCaseInsensitive
                        if ($ovProt -eq 'equal' -or $ovProt -eq 'prefix') {
                            Fail "MECHANICAL_FAIL: protected path '$pi' overlaps single-writer boundary '$prot'" 1
                        }
                    }
                }
            }
            if ($isAttributing) {
                $baseRawAttr = if ($BaseSha) { $BaseSha.Trim() } else { '' }
                if ($baseRawAttr -cnotmatch '^[0-9a-fA-F]{40}$') {
                    Fail 'MECHANICAL_FAIL: worker attribution requires explicit 40-hex -BaseSha' 1
                }
                $midOpMc = Test-GitMidOperation $RepoRoot
                if ($midOpMc) {
                    Fail "MECHANICAL_FAIL: git operation in progress ($midOpMc)" 1
                }
                for ($i = 0; $i -lt $wsParsed.Order.Count; $i++) {
                    for ($j = $i + 1; $j -lt $wsParsed.Order.Count; $j++) {
                        $ti = $wsParsed.Order[$i]
                        $tj = $wsParsed.Order[$j]
                        foreach ($pi in $wsParsed.Map[$ti]) {
                            foreach ($pj in $wsParsed.Map[$tj]) {
                                $ovW = Test-WavePathOverlap $pi $pj $mcCaseInsensitive
                                if ($ovW -ne 'none') {
                                    Fail "MECHANICAL_FAIL: overlapping WaveSpecs '$pi' and '$pj' ($ti,$tj)" 1
                                }
                            }
                        }
                    }
                }
            }
            if ($hasWorkerChanges) {
                $wcParsed = ConvertTo-WaveTaskMap -Specs $WorkerChanges -Root $RepoRoot -ErrorPrefix 'MECHANICAL_FAIL' -SpecLabel 'WorkerChanges' -EmptyArgLabel '-WorkerChanges' -RejectDot -AllowEmpty -AllowedTaskIds $wsParsed.Map
            }
            if ($hasWorkerRoots) {
                if ($WorkerRoots -match '[\x00-\x1F\x7F]') {
                    Fail 'MECHANICAL_FAIL: invalid -WorkerRoots' 1
                }
                foreach ($wrEntry in ($WorkerRoots -split ';')) {
                    $wrTrim = $wrEntry.Trim()
                    if (-not $wrTrim) { continue }
                    $eqIdx = $wrTrim.IndexOf('=')
                    if ($eqIdx -lt 0) {
                        Fail "MECHANICAL_FAIL: invalid WorkerRoots entry '$wrTrim' (expected TaskId=worktree_path)" 1
                    }
                    $tid = $wrTrim.Substring(0, $eqIdx).Trim()
                    $wtVal = $wrTrim.Substring($eqIdx + 1).Trim()
                    if (-not $tid -or $tid -cnotmatch '\A[A-Za-z0-9._-]+\z') {
                        Fail "MECHANICAL_FAIL: invalid task id '$tid' in WorkerRoots" 1
                    }
                    if ($wrMap.ContainsKey($tid)) {
                        Fail "MECHANICAL_FAIL: duplicate task id '$tid' in WorkerRoots" 1
                    }
                    if (-not $wsParsed.Map.ContainsKey($tid)) {
                        Fail "MECHANICAL_FAIL: unknown task id '$tid' in WorkerRoots" 1
                    }
                    if (-not $wtVal) {
                        Fail "MECHANICAL_FAIL: empty worktree root for task '$tid' in WorkerRoots" 1
                    }
                    $wrOrder.Add($tid)
                    $wrMap[$tid] = if ($wtVal -ceq 'none' -or $wtVal -ceq '[]') { '' } else { $wtVal }
                }
                if ($wrOrder.Count -lt 1) {
                    Fail 'MECHANICAL_FAIL: no tasks in -WorkerRoots' 1
                }
            }
        }

        $allowed = @(Split-PathCsvChecked $AllowedPaths 'MECHANICAL_FAIL')
        $ignored = @(Split-PathCsvChecked $IgnoreDirtyPaths 'MECHANICAL_FAIL' -RejectDot)
        $obsoletesList = @(Split-CsvList $Obsoletes)
        $baseKindMc = if ($isAttributing) { 'commit' } else { 'object' }
        $scopeTarget = Resolve-ScopeTargetAndBase $RepoRoot $TargetRef $BaseSha $ignored 'MECHANICAL_FAIL' $baseKindMc
        $targetTrim = $scopeTarget.TargetRef
        $targetCommitSha = $scopeTarget.TargetCommitSha
        $resolvedBase = $scopeTarget.BaseSha

        $chArgs = if ($targetTrim) {
            @('diff', '--no-ext-diff', '--no-renames', '--name-only', '-z', $resolvedBase, $targetCommitSha, '--')
        } else {
            @('diff', '--no-ext-diff', '--no-renames', '--name-only', '-z', $resolvedBase, '--')
        }
        $chPaths = @(Invoke-GitPathsZ $RepoRoot $chArgs 'names' 'MECHANICAL_FAIL')
        $nonDelArgs = if ($targetTrim) {
            @('diff', '--no-ext-diff', '--no-renames', '--diff-filter=d', '--name-only', '-z', $resolvedBase, $targetCommitSha, '--')
        } else {
            @('diff', '--no-ext-diff', '--no-renames', '--diff-filter=d', '--name-only', '-z', $resolvedBase, '--')
        }
        $nonDelPaths = @(Invoke-GitPathsZ $RepoRoot $nonDelArgs 'names' 'MECHANICAL_FAIL')
        $untracked = if ($targetTrim) { @() } else { @(Invoke-GitPathsZ $RepoRoot @('ls-files', '--others', '--exclude-standard', '-z') 'names' 'MECHANICAL_FAIL') }
        $caBaseChPaths = @()
        $caBaseNonDelPaths = @()
        if (-not $targetTrim) {
            $caBaseChPaths = @(Invoke-GitPathsZ $RepoRoot @('diff', '--no-ext-diff', '--cached', '--no-renames', '--name-only', '-z', $resolvedBase, '--') 'names' 'MECHANICAL_FAIL')
            if ($caBaseChPaths.Count -gt 0) {
                $caBaseNonDelPaths = @(Invoke-GitPathsZ $RepoRoot @('diff', '--no-ext-diff', '--cached', '--no-renames', '--diff-filter=d', '--name-only', '-z', $resolvedBase, '--') 'names' 'MECHANICAL_FAIL')
            }
        }

        # Collect raw changed/dirty paths BEFORE $ignored stripping for ProtectedPaths and DirtyDigests tamper gates
        $rawChangedBeforeIgn = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($rp in (@($chPaths) + @($caBaseChPaths) + @($untracked))) {
            if ($rp -and (-not (Test-CheckpointPath $rp))) { [void]$rawChangedBeforeIgn.Add($rp) }
        }
        if ((-not $targetTrim) -and ($hasProtectedArg -or $hasDirtyDigestsArg)) {
            $hdDirtyPaths = @(Invoke-GitPathsZ $RepoRoot @('diff', '--no-ext-diff', '--no-renames', '--name-only', '-z', 'HEAD', '--') 'names' 'MECHANICAL_FAIL')
            $caDirtyPaths = @(Invoke-GitPathsZ $RepoRoot @('diff', '--no-ext-diff', '--no-renames', '--cached', '--name-only', '-z', '--') 'names' 'MECHANICAL_FAIL')
            $wtDirtyPaths = @(Invoke-GitPathsZ $RepoRoot @('diff', '--no-ext-diff', '--no-renames', '--name-only', '-z', '--') 'names' 'MECHANICAL_FAIL')
            foreach ($rp in (@($hdDirtyPaths) + @($caDirtyPaths) + @($wtDirtyPaths))) {
                if ($rp -and (-not (Test-CheckpointPath $rp))) { [void]$rawChangedBeforeIgn.Add($rp) }
            }
        }

        $protectedViolations = New-Object System.Collections.Generic.List[string]
        if ($protectedList.Count -gt 0) {
            foreach ($rp in @($rawChangedBeforeIgn)) {
                if (Test-OwnershipPathMatch $rp $protectedList $mcCaseInsensitive) {
                    $protectedViolations.Add($rp)
                }
            }
        }

        $dirtyTamperList = New-Object System.Collections.Generic.List[string]
        if ($hasDirtyDigestsArg) {
            foreach ($dp in @(Sort-Ordinal @($dirtyDigestMap.Keys))) {
                $expDig = $dirtyDigestMap[$dp]
                $fullDp = Join-Path $RepoRoot ($dp -replace '/', '\')
                $dpItem = Get-Item -LiteralPath $fullDp -Force -ErrorAction SilentlyContinue
                if ($expDig -ceq 'DELETED') {
                    if ($null -ne $dpItem -or (Test-Path -LiteralPath $fullDp)) {
                        $dirtyTamperList.Add($dp)
                    }
                } else {
                    if ($null -eq $dpItem -or $dpItem.PSIsContainer -or (Test-IsReparseItem $dpItem) -or (-not (Test-Path -LiteralPath $fullDp -PathType Leaf))) {
                        $dirtyTamperList.Add($dp)
                    } else {
                        $actDig = (Get-FileHash -LiteralPath $fullDp -Algorithm SHA256).Hash.ToLowerInvariant()
                        if ($actDig -cne $expDig) {
                            $dirtyTamperList.Add($dp)
                        }
                    }
                }
            }
            if ($ignored.Count -gt 0) {
                foreach ($rp in @($rawChangedBeforeIgn)) {
                    if (Test-OwnershipPathMatch $rp $ignored $mcCaseInsensitive) {
                        $rpKey = if ($mcCaseInsensitive) { $rp.ToLowerInvariant() } else { $rp }
                        if (-not $dirtyDigestKeyMap.ContainsKey($rpKey)) {
                            if (-not $dirtyTamperList.Contains($rp)) {
                                $dirtyTamperList.Add($rp)
                            }
                        }
                    }
                }
            }
        }

        $allChanged = New-Object System.Collections.Generic.List[string]
        $allChangedSet = New-Object 'System.Collections.Generic.HashSet[string]' ($cmpSet)
        foreach ($p in (@($chPaths) + @($untracked) + @($caBaseChPaths))) {
            if (-not $p -or (Test-CheckpointPath $p) -or (Test-OwnershipPathMatch $p $ignored $mcCaseInsensitive)) { continue }
            if ($allChangedSet.Add($p)) { $allChanged.Add($p) }
        }

        $nonDelChanged = New-Object System.Collections.Generic.List[string]
        $nonDelSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($p in (@($nonDelPaths) + @($untracked) + @($caBaseNonDelPaths))) {
            if (-not $p -or (Test-CheckpointPath $p) -or (Test-OwnershipPathMatch $p $ignored $mcCaseInsensitive)) { continue }
            if ($nonDelSet.Add($p)) { $nonDelChanged.Add($p) }
        }

        $scopeCreep = New-Object System.Collections.Generic.List[string]
        if ($allowed.Count -gt 0) {
            foreach ($p in $allChanged) {
                if (-not (Test-PathMatch $p $allowed)) { $scopeCreep.Add($p) }
            }
        }

        $leftoverHits = New-Object System.Collections.Generic.List[string]
        $safetyHits = New-Object System.Collections.Generic.List[string]
        foreach ($p in $nonDelChanged) {
            if (Test-SecretPath $p) {
                $safetyHits.Add("secret_path:$p")
            }
        }
        $sqlHitCount = 0

        $dlArgs = if ($targetTrim) {
            @('diff', '--no-ext-diff', '--no-renames', '-U0', $resolvedBase, $targetCommitSha, '--')
        } else {
            @('diff', '--no-ext-diff', '--no-renames', '-U0', $resolvedBase, '--')
        }
        $dlRes = Invoke-GitCommand $RepoRoot $dlArgs
        if ($dlRes.ExitCode -ne 0) {
            $detail = if ($dlRes.StdErr.Trim()) { $dlRes.StdErr.Trim() } else { $dlRes.StdOut.Trim() }
            Fail ("MECHANICAL_FAIL: git diff -U0 failed: $detail") 1
        }
        $diffTextsToScan = New-Object System.Collections.Generic.List[string]
        if ($dlRes.StdOut) { [void]$diffTextsToScan.Add($dlRes.StdOut) }
        if ((-not $targetTrim) -and $caBaseChPaths.Count -gt 0) {
            $dlCaRes = Invoke-GitCommand $RepoRoot @('diff', '--no-ext-diff', '--cached', '--no-renames', '-U0', $resolvedBase, '--')
            if ($dlCaRes.ExitCode -ne 0) {
                $detail = if ($dlCaRes.StdErr.Trim()) { $dlCaRes.StdErr.Trim() } else { $dlCaRes.StdOut.Trim() }
                Fail ("MECHANICAL_FAIL: git diff --cached -U0 failed: $detail") 1
            }
            if ($dlCaRes.StdOut) { [void]$diffTextsToScan.Add($dlCaRes.StdOut) }
        }

        foreach ($diffTxt in $diffTextsToScan) {
            $curFile = ''
            $curLine = 0
            $skipFile = $true
            $inHunk = $false
            foreach ($rawLine in ($diffTxt -split "\r?\n")) {
                $ln = [string]$rawLine
                if ($ln.StartsWith('diff --git ')) {
                    $curFile = ''
                    $skipFile = $true
                    $inHunk = $false
                    continue
                }
                if (-not $inHunk -and $ln.StartsWith('+++ ')) {
                    if ($ln -eq '+++ /dev/null') {
                        $curFile = ''
                        $skipFile = $true
                    } else {
                        $cand = $ln.Substring(4)
                        if ($cand.StartsWith('b/')) { $cand = $cand.Substring(2) }
                        $curFile = Normalize-PathValue $cand
                        $skipFile = (-not $curFile) -or (Test-CheckpointPath $curFile) -or (Test-PathMatch $curFile $ignored) -or (Test-NoiseFile $curFile) -or ($curFile -match '\.md$')
                    }
                    continue
                }
                if ($ln -match '^@@ -[0-9,]+ \+([0-9]+)(,[0-9]+)? @@') {
                    $curLine = [int]$Matches[1]
                    $inHunk = $true
                    continue
                }
                if (-not $inHunk -or $skipFile) { continue }
                if ($ln.StartsWith('+')) {
                    $body = $ln.Substring(1)
                    $tag = Find-LeftoverTag $body
                    if ($tag -and $leftoverHits.Count -lt 10) {
                        $lhEntry = "${curFile}:${curLine}:${tag}"
                        if (-not $leftoverHits.Contains($lhEntry)) {
                            $leftoverHits.Add($lhEntry)
                        }
                    }
                    if (-not (Test-TestPath $curFile) -and (Find-DestructiveSql $body) -and $sqlHitCount -lt 10) {
                        $shEntry = "destructive_sql:${curFile}:${curLine}"
                        if (-not $safetyHits.Contains($shEntry)) {
                            $safetyHits.Add($shEntry)
                            $sqlHitCount++
                        }
                    }
                    $curLine++
                }
            }
        }

        foreach ($u in @(Sort-Ordinal $untracked)) {
            if ($leftoverHits.Count -ge 10 -and $sqlHitCount -ge 10) { break }
            if (-not $u -or (Test-CheckpointPath $u) -or (Test-PathMatch $u $ignored) -or (Test-NoiseFile $u) -or ($u -match '\.md$')) { continue }
            $full = Join-Path $RepoRoot ($u -replace '/', '\')
            if (-not (Test-Path -LiteralPath $full -PathType Leaf) -or (Test-BinaryFile $full)) { continue }
            $isUTest = Test-TestPath $u
            $lno = 0
            foreach ($fl in @(Get-Content -LiteralPath $full -ErrorAction SilentlyContinue)) {
                $lno++
                $flStr = [string]$fl
                $tag = Find-LeftoverTag $flStr
                if ($tag -and $leftoverHits.Count -lt 10) {
                    $leftoverHits.Add("${u}:${lno}:${tag}")
                }
                if (-not $isUTest -and (Find-DestructiveSql $flStr) -and $sqlHitCount -lt 10) {
                    $safetyHits.Add("destructive_sql:${u}:${lno}")
                    $sqlHitCount++
                }
            }
        }

        $candidateDelSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($dp in $chPaths) {
            if (-not $dp -or (Test-CheckpointPath $dp) -or (Test-OwnershipPathMatch $dp $ignored $mcCaseInsensitive) -or (Test-NoiseFile $dp)) { continue }
            if (-not $nonDelSet.Contains($dp)) {
                [void]$candidateDelSet.Add($dp)
            }
        }
        if ((-not $AllowMassDelete) -and ($candidateDelSet.Count -ge 10)) {
            $delTarget = if ($targetTrim) { $targetCommitSha } else { New-WorkingTreeOid $RepoRoot 'MECHANICAL_FAIL' -ExcludeSensitive }
            $delArgs = @('diff', '--no-ext-diff', '-M', '--diff-filter=D', '--name-only', '-z', $resolvedBase, $delTarget, '--')
            $delPaths = @(Invoke-GitPathsZ $RepoRoot $delArgs 'names' 'MECHANICAL_FAIL')
            $deletedList = New-Object System.Collections.Generic.List[string]
            foreach ($dp in $delPaths) {
                if (-not $dp -or (Test-CheckpointPath $dp) -or (Test-OwnershipPathMatch $dp $ignored $mcCaseInsensitive) -or (Test-NoiseFile $dp)) { continue }
                if (-not $deletedList.Contains($dp)) { $deletedList.Add($dp) }
            }
            if ($deletedList.Count -ge 10) {
                $safetyHits.Add("mass_delete:$($deletedList.Count)f")
            }
        }

        $obsoleteHits = New-Object System.Collections.Generic.List[string]
        if ($obsoletesList.Count -gt 0) {
            $targetExistingPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
            if ($targetTrim) {
                $lsPathArgs = New-Object System.Collections.Generic.List[string]
                foreach ($tok in $obsoletesList) {
                    $nt = Normalize-PathValue $tok
                    if ($nt -and (-not $nt.StartsWith('-')) -and (-not $nt.Contains(':')) -and ($nt -notmatch '(^|/)\.\.(/|$)')) {
                        if (-not $lsPathArgs.Contains($nt)) { $lsPathArgs.Add($nt) }
                    }
                }
                if ($lsPathArgs.Count -gt 0) {
                    $lsObsPaths = @(Invoke-GitPathsZ $RepoRoot (@('ls-tree', '--name-only', '-z', $targetCommitSha, '--') + $lsPathArgs.ToArray()) 'ls-tree-z' 'MECHANICAL_FAIL')
                    foreach ($lp in $lsObsPaths) {
                        if ($lp) { [void]$targetExistingPaths.Add($lp) }
                    }
                }
            }

            $batchGrepArgs = New-Object System.Collections.Generic.List[string]
            [void]$batchGrepArgs.Add('grep')
            if (-not $targetTrim) { [void]$batchGrepArgs.Add('--untracked') }
            [void]$batchGrepArgs.Add('-l')
            [void]$batchGrepArgs.Add('-F')
            foreach ($tok in $obsoletesList) {
                [void]$batchGrepArgs.Add('-e')
                [void]$batchGrepArgs.Add($tok)
            }
            if ($targetTrim) { [void]$batchGrepArgs.Add($targetCommitSha) }
            [void]$batchGrepArgs.Add('--')
            [void]$batchGrepArgs.Add('.')
            [void]$batchGrepArgs.Add(':(exclude).b3/ship')
            [void]$batchGrepArgs.Add(':(exclude).b3/research-ship')
            [void]$batchGrepArgs.Add(':(exclude).b3/autodev')

            $batchRes = Invoke-GitCommand $RepoRoot $batchGrepArgs.ToArray()
            if ($batchRes.ExitCode -gt 1) {
                Fail 'MECHANICAL_FAIL: git grep failed for obsoletes' 1
            }
            $batchHitFiles = New-Object System.Collections.Generic.List[string]
            if ($batchRes.ExitCode -eq 0 -and $batchRes.StdOut) {
                $obsPrefix = "${targetCommitSha}:"
                foreach ($row in ($batchRes.StdOut -split "\r?\n")) {
                    $gp = ([string]$row).Trim()
                    if (-not $gp) { continue }
                    if ($targetTrim -and $gp.StartsWith($obsPrefix)) { $gp = $gp.Substring($obsPrefix.Length) }
                    $gp = Normalize-PathValue $gp
                    if (-not $gp -or (Test-CheckpointPath $gp) -or ($ignored -and (Test-PathMatch $gp $ignored))) { continue }
                    if (-not $batchHitFiles.Contains($gp)) { $batchHitFiles.Add($gp) }
                }
            }

            foreach ($tok in $obsoletesList) {
                $normTok = Normalize-PathValue $tok
                $existsPath = $false
                if ($normTok) {
                    if ($targetTrim) {
                        if ($normTok.StartsWith('-') -or $normTok.Contains(':') -or ($normTok -match '(^|/)\.\.(/|$)')) {
                            $ceRes = Invoke-GitCommand $RepoRoot @('cat-file', '-e', "${targetCommitSha}:${normTok}")
                            $existsPath = ($ceRes.ExitCode -eq 0)
                        } else {
                            $existsPath = $targetExistingPaths.Contains($normTok)
                        }
                    } else {
                        $existsPath = Test-Path -LiteralPath (Join-Path $RepoRoot ($normTok -replace '/', '\'))
                    }
                }
                $grepCount = 0
                if ($batchHitFiles.Count -gt 0) {
                    if ($obsoletesList.Count -eq 1) {
                        $grepCount = $batchHitFiles.Count
                    } else {
                        $singleArgs = New-Object System.Collections.Generic.List[string]
                        [void]$singleArgs.Add('grep')
                        if (-not $targetTrim) { [void]$singleArgs.Add('--untracked') }
                        [void]$singleArgs.Add('-l')
                        [void]$singleArgs.Add('-F')
                        [void]$singleArgs.Add('-e')
                        [void]$singleArgs.Add($tok)
                        if ($targetTrim) { [void]$singleArgs.Add($targetCommitSha) }
                        [void]$singleArgs.Add('--')
                        foreach ($hf in $batchHitFiles) { [void]$singleArgs.Add($hf) }
                        $singleRes = Invoke-GitCommand $RepoRoot $singleArgs.ToArray()
                        if ($singleRes.ExitCode -gt 1) {
                            Fail "MECHANICAL_FAIL: git grep failed for obsolete '$tok'" 1
                        }
                        if ($singleRes.ExitCode -eq 0 -and $singleRes.StdOut) {
                            $obsPrefix = "${targetCommitSha}:"
                            foreach ($row in ($singleRes.StdOut -split "\r?\n")) {
                                $gp = ([string]$row).Trim()
                                if (-not $gp) { continue }
                                if ($targetTrim -and $gp.StartsWith($obsPrefix)) { $gp = $gp.Substring($obsPrefix.Length) }
                                $gp = Normalize-PathValue $gp
                                if (-not $gp -or (Test-CheckpointPath $gp) -or ($ignored -and (Test-PathMatch $gp $ignored))) { continue }
                                $grepCount++
                            }
                        }
                    }
                }
                if ($existsPath -and $grepCount -gt 0) {
                    $obsoleteHits.Add("${tok}(exists+${grepCount}f)")
                } elseif ($existsPath) {
                    $obsoleteHits.Add("${tok}(exists)")
                } elseif ($grepCount -gt 0) {
                    $obsoleteHits.Add("${tok}(${grepCount}f)")
                }
            }
        }

        $ovStatus = ''
        $ovViolationsOut = ''
        if ($hasWaveSpecs) {
            if (-not $isAttributing) {
                $ovStatus = 'UNVERIFIED_COMBINED_ONLY'
                $ovViolationsOut = 'unverified'
            } else {
                $resolveMisowned = {
                    param([string]$PathArg, [string]$OwnerTid)
                    $otherOwners = New-Object System.Collections.Generic.List[string]
                    foreach ($otherTid in $wsParsed.Order) {
                        if ($otherTid -ceq $OwnerTid) { continue }
                        if (Test-OwnershipPathMatch $PathArg @($wsParsed.Map[$otherTid]) $mcCaseInsensitive) {
                            $otherOwners.Add($otherTid)
                        }
                    }
                    if ($otherOwners.Count -gt 0) {
                        $sortedOther = @(Sort-Ordinal $otherOwners.ToArray())
                        return "${PathArg}(${OwnerTid}->$($sortedOther[0]))"
                    }
                    return "${PathArg}(${OwnerTid}->unowned)"
                }
                $ovViolations = New-Object System.Collections.Generic.List[string]
                $attributedPaths = New-Object System.Collections.Generic.List[string]
                $presentTaskMap = $null
                if ($hasWorkerChanges) {
                    $presentTaskMap = $wcParsed.Map
                    foreach ($tid in $wcParsed.Order) {
                        $tidOwned = @($wsParsed.Map[$tid])
                        foreach ($wp in @($wcParsed.Map[$tid])) {
                            $attributedPaths.Add($wp)
                            if (($wp -imatch '^\.b3(/|$)') -or ($wp -imatch '(^|/)\.git(/|$)') -or ($wp -imatch '(^|/)\.gitmodules$') -or (Test-OwnershipPathMatch $wp $protectedList $mcCaseInsensitive)) {
                                $ovViolations.Add("${wp}(${tid}->protected)")
                                continue
                            }
                            if (Test-OwnershipPathMatch $wp $ignored $mcCaseInsensitive) {
                                $ovViolations.Add("${wp}(${tid}->user_dirty)")
                                continue
                            }
                            if (Test-OwnershipPathMatch $wp $tidOwned $mcCaseInsensitive) {
                                if (-not $allChangedSet.Contains($wp)) {
                                    $ovViolations.Add("${wp}(${tid}->phantom)")
                                }
                                continue
                            }
                            $ovViolations.Add((& $resolveMisowned $wp $tid))
                        }
                    }
                } else {
                    $presentTaskMap = $wrMap
                    $parentWtId = Resolve-SafeWorktreeIdentity $RepoRoot 'missing_repo_root' 'not_a_git_repo' -RequireHead
                    $parentTopNorm = $parentWtId.TopNorm
                    $parentCommon = $parentWtId.CommonDir

                    $seenWtTops = New-Object System.Collections.Generic.List[string]
                    $seenWtTops.Add($parentTopNorm)

                    foreach ($tid in $wrOrder) {
                        $wtRawPath = $wrMap[$tid]
                        if (-not $wtRawPath) { continue }
                        $wId = Resolve-SafeWorktreeIdentity $wtRawPath 'missing_worker_root' 'worker_not_git' -RequireHead
                        $wMid = Test-GitMidOperation $wId.Logical
                        if ($wMid) {
                            Fail "WORKTREE_UNSAFE: git_op_in_progress($wMid)" 2
                        }
                        $commonSame = if ($mcCaseInsensitive) { $wId.CommonDir -ieq $parentCommon } else { $wId.CommonDir -ceq $parentCommon }
                        if (-not $commonSame) {
                            Fail "WORKTREE_UNSAFE: peer_repo_mismatch(expected=$parentCommon,actual=$($wId.CommonDir))" 2
                        }
                        $wtSameGit = if ($mcCaseInsensitive) { $wId.GitDir -ieq $wId.CommonDir } else { $wId.GitDir -ceq $wId.CommonDir }
                        if ($wtSameGit -or (Test-WorktreeRootOverlap $wId.TopNorm $parentTopNorm $mcCaseInsensitive)) {
                            Fail "WORKTREE_UNSAFE: not_isolated_linked_worktree(parent=$parentTopNorm,worker=$($wId.TopNorm))" 2
                        }
                        foreach ($prevTop in $seenWtTops) {
                            if (Test-WorktreeRootOverlap $wId.TopNorm $prevTop $mcCaseInsensitive) {
                                Fail "WORKTREE_UNSAFE: duplicate_or_nested_worktree($($wId.TopNorm))" 2
                            }
                        }
                        $seenWtTops.Add($wId.TopNorm)

                        $ancWtRes = Invoke-GitCommand $wId.TopFull @('merge-base', '--is-ancestor', $resolvedBase, $wId.Head)
                        if ($ancWtRes.ExitCode -ne 0) {
                            Fail "WORKTREE_UNSAFE: base_not_ancestor_of_worker(task=$tid,base=$resolvedBase,head=$($wId.Head))" 2
                        }

                        $wDiffPaths = @(Invoke-GitPathsZ $wId.TopFull @('diff', '--no-ext-diff', '--no-renames', '--name-only', '-z', $resolvedBase, '--') 'names' 'MECHANICAL_FAIL')
                        $wCaDiffPaths = @(Invoke-GitPathsZ $wId.TopFull @('diff', '--no-ext-diff', '--cached', '--no-renames', '--name-only', '-z', $resolvedBase, '--') 'names' 'MECHANICAL_FAIL')
                        $wUntracked = @(Invoke-GitPathsZ $wId.TopFull @('ls-files', '--others', '--exclude-standard', '-z') 'names' 'MECHANICAL_FAIL')
                        $wChanged = New-Object System.Collections.Generic.List[string]
                        $wSeen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
                        foreach ($wp in (@($wDiffPaths) + @($wCaDiffPaths) + @($wUntracked))) {
                            if (-not $wp -or (Test-CheckpointPath $wp)) { continue }
                            if ($wSeen.Add($wp)) { $wChanged.Add($wp) }
                        }

                        $tidOwned = @($wsParsed.Map[$tid])
                        foreach ($wp in $wChanged) {
                            $attributedPaths.Add($wp)
                            if (($wp -imatch '^\.b3(/|$)') -or ($wp -imatch '(^|/)\.git(/|$)') -or ($wp -imatch '(^|/)\.gitmodules$') -or (Test-OwnershipPathMatch $wp $protectedList $mcCaseInsensitive)) {
                                $ovViolations.Add("${wp}(${tid}->protected)")
                                continue
                            }
                            if (Test-OwnershipPathMatch $wp $ignored $mcCaseInsensitive) {
                                $ovViolations.Add("${wp}(${tid}->user_dirty)")
                                continue
                            }
                            if (-not (Test-OwnershipPathMatch $wp $tidOwned $mcCaseInsensitive)) {
                                $ovViolations.Add((& $resolveMisowned $wp $tid))
                                continue
                            }
                            if (-not $allChangedSet.Contains($wp)) {
                                $ovViolations.Add("${wp}(${tid}->content_mismatch)")
                                continue
                            }
                            $wtState = Get-EffectiveRepoPathState $wId.TopFull $wp 'MECHANICAL_FAIL'
                            $rootState = Get-EffectiveRepoPathState $RepoRoot $wp 'MECHANICAL_FAIL'
                            if ($wtState -ceq 'UNSAFE_REPARSE' -or $rootState -ceq 'UNSAFE_REPARSE' -or $wtState -ceq 'INDEX_WT_DIVERGED' -or $rootState -ceq 'INDEX_WT_DIVERGED' -or ($wtState -cne $rootState)) {
                                $ovViolations.Add("${wp}(${tid}->content_mismatch)")
                            }
                        }
                    }
                }
                foreach ($gp in $allChanged) {
                    $isAttrib = $false
                    foreach ($ap in $attributedPaths) {
                        if ($gp.Equals($ap, $cmpExact)) {
                            $isAttrib = $true
                            break
                        }
                    }
                    if (-not $isAttrib) {
                        $ovViolations.Add("${gp}(unattributed)")
                    }
                }
                foreach ($pv in $protectedViolations) {
                    $ovViolations.Add("${pv}(protected)")
                }
                foreach ($dt in $dirtyTamperList) {
                    $ovViolations.Add("${dt}(dirty_tamper)")
                }
                $missingWorkers = New-Object System.Collections.Generic.List[string]
                foreach ($tid in $wsParsed.Order) {
                    if (-not $presentTaskMap.ContainsKey($tid)) {
                        $missingWorkers.Add("${tid}(missing_worker)")
                    }
                }
                if ($ovViolations.Count -gt 0) {
                    $ovStatus = 'VIOLATION'
                    $ovViolationsOut = (Sort-Ordinal $ovViolations.ToArray()) -join ','
                } elseif ($missingWorkers.Count -gt 0) {
                    $ovStatus = 'PARTIAL_ATTRIBUTION'
                    $ovViolationsOut = (Sort-Ordinal $missingWorkers.ToArray()) -join ','
                } else {
                    $ovStatus = if ($hasWorkerChanges) { 'CALLER_ATTRIBUTED' } else { 'VERIFIED_PER_WORKER' }
                    $ovViolationsOut = 'none'
                }
            }
        }

        $scOut = if ($scopeCreep.Count -gt 0) { (Sort-Ordinal $scopeCreep.ToArray()) -join ',' } else { 'none' }
        $loOut = if ($leftoverHits.Count -gt 0) { $leftoverHits -join ',' } else { 'none' }
        $obOut = if ($obsoleteHits.Count -gt 0) { (Sort-Ordinal $obsoleteHits.ToArray()) -join ',' } else { 'none' }
        $sfOut = if ($safetyHits.Count -gt 0) { (Sort-Ordinal $safetyHits.ToArray()) -join ',' } else { 'none' }
        $pvOut = if ($protectedViolations.Count -gt 0) { (Sort-Ordinal $protectedViolations.ToArray()) -join ',' } else { 'none' }
        $dtOut = if ($dirtyTamperList.Count -gt 0) { (Sort-Ordinal $dirtyTamperList.ToArray()) -join ',' } else { 'none' }

        Write-Output "scope_creep=$scOut"
        Write-Output "leftovers=$loOut"
        Write-Output "obsolete_hits=$obOut"
        Write-Output "safety_hits=$sfOut"
        if ($hasProtectedArg) {
            Write-Output "protected_violations=$pvOut"
        }
        if ($hasDirtyDigestsArg) {
            Write-Output "dirty_tamper=$dtOut"
        }
        if ($hasWaveSpecs) {
            Write-Output "ownership_verification=$ovStatus"
            Write-Output "ownership_violations=$ovViolationsOut"
        }
        $ovOk = (-not $hasWaveSpecs) -or ($ovStatus -cin @('UNVERIFIED_COMBINED_ONLY', 'CALLER_ATTRIBUTED', 'VERIFIED_PER_WORKER'))
        if ($scOut -eq 'none' -and $loOut -eq 'none' -and $obOut -eq 'none' -and $sfOut -eq 'none' -and $pvOut -eq 'none' -and $dtOut -eq 'none' -and $ovOk) {
            Write-Output 'MECHANICAL_OK'
            exit 0
        }
        Write-Output 'MECHANICAL_FINDINGS'
        exit 2
    }

    'check-wave' {
        if (-not $WaveSpecs -or -not $WaveSpecs.Trim()) { Fail 'WAVE_FAIL: missing -WaveSpecs' 1 }
        if (-not $RepoRoot) { Fail 'WAVE_FAIL: missing -RepoRoot' 1 }
        $waveMaxConc = if ($PSBoundParameters.ContainsKey('MaxConcurrency')) { $MaxConcurrency } else { 3 }
        if ($waveMaxConc -lt 1 -or $waveMaxConc -gt 4) {
            Fail 'WAVE_FAIL: -MaxConcurrency must be between 1 and 4' 1
        }
        if (Find-ReparseInPathHierarchy $RepoRoot) {
            Fail "WAVE_FAIL: unsafe symlink or junction alias in path '.'" 1
        }

        if ($ExpectedBaseSha -and $ExpectedBaseSha.Trim()) {
            $expBase = $ExpectedBaseSha.Trim()
            $midOp = Test-GitMidOperation $RepoRoot
            if ($midOp) {
                Fail "WAVE_BASE_MISMATCH: git_op_in_progress($midOp)" 2
            }
            $headRes = Invoke-GitCommand $RepoRoot @('rev-parse', 'HEAD')
            $actHead = $headRes.StdOut.Trim()
            if ($headRes.ExitCode -ne 0 -or -not $actHead) {
                Fail 'WAVE_BASE_MISMATCH: git rev-parse HEAD failed' 2
            }
            if ($actHead -cne $expBase) {
                Fail "WAVE_BASE_MISMATCH: expected=$expBase actual=$actHead" 2
            }
        }

        $repoExists = (Test-Path -LiteralPath $RepoRoot -PathType Container)
        $waveParsed = ConvertTo-WaveTaskMap -Specs $WaveSpecs -Root $RepoRoot -ErrorPrefix 'WAVE_FAIL' -SpecLabel 'WaveSpecs' -EmptyArgLabel '-WaveSpecs' -RejectProtected -RejectDot:$Partition -AllowEmpty
        $taskOrder = $waveParsed.Order
        $taskPaths = $waveParsed.Map
        $totalPaths = $waveParsed.TotalPaths

        $readPaths = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
        if ($WaveReads -and $WaveReads.Trim()) {
            foreach ($entry in ($WaveReads -split ';')) {
                $trimEntry = $entry.Trim()
                if (-not $trimEntry) { continue }
                $eqIdx = $trimEntry.IndexOf('=')
                if ($eqIdx -lt 0) { Fail "WAVE_FAIL: invalid WaveReads entry '$trimEntry' (expected TaskId=path1,path2)" 1 }
                $rtid = $trimEntry.Substring(0, $eqIdx).Trim()
                $rCsv = $trimEntry.Substring($eqIdx + 1)
                if (-not $rtid) { Fail "WAVE_FAIL: empty task id in WaveReads '$trimEntry'" 1 }
                if ($rtid -cnotmatch '\A[A-Za-z0-9._-]+\z') { Fail "WAVE_FAIL: invalid task id '$rtid'" 1 }
                if ($readPaths.ContainsKey($rtid)) { Fail "WAVE_FAIL: duplicate task id '$rtid' in WaveReads" 1 }
                if (-not $taskPaths.ContainsKey($rtid)) { Fail "WAVE_FAIL: unknown task id '$rtid' in WaveReads" 1 }
                $parsedR = ConvertTo-WavePaths $rCsv
                if ($parsedR.Error) { Fail $parsedR.Error 1 }
                $rArr = @($parsedR.Paths)
                if ($repoExists) {
                    foreach ($rp in $rArr) {
                        if (-not (Test-WavePathContained $RepoRoot $rp)) {
                            Fail "WAVE_FAIL: unsafe symlink or junction alias in path '$rp'" 1
                        }
                    }
                }
                $readPaths[$rtid] = $rArr
            }
        }

        $waveCaseInsensitive = Test-RepoCaseInsensitive $RepoRoot
        $protectedList = @()
        if ($ProtectedPaths -and $ProtectedPaths.Trim()) {
            $parsedProt = ConvertTo-WavePaths $ProtectedPaths
            if ($parsedProt.Error) { Fail $parsedProt.Error 1 }
            $protectedList = @($parsedProt.Paths)
            foreach ($prot in $protectedList) {
                if ($prot -ceq '.') {
                    Fail "WAVE_FAIL: invalid protected path '.'" 1
                }
                if ($repoExists -and (-not (Test-WavePathContained $RepoRoot $prot))) {
                    Fail "WAVE_FAIL: unsafe symlink or junction alias in path '$prot'" 1
                }
            }
        }

        foreach ($ti in $taskOrder) {
            foreach ($pi in $taskPaths[$ti]) {
                foreach ($prot in $protectedList) {
                    $ovProt = Test-WavePathOverlap $pi $prot $waveCaseInsensitive
                    if ($ovProt -eq 'equal' -or $ovProt -eq 'prefix') {
                        Fail "WAVE_FAIL: protected path '$pi' overlaps single-writer boundary '$prot'" 1
                    }
                }
            }
        }

        $nTasks = $taskOrder.Count
        $taskIndexMap = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
        for ($idx = 0; $idx -lt $nTasks; $idx++) {
            $taskIndexMap[$taskOrder[$idx]] = $idx
        }
        $hasConflict = New-Object 'bool[,]' $nTasks, $nTasks
        $conflicts = New-Object System.Collections.Generic.List[string]

        for ($i = 0; $i -lt $nTasks; $i++) {
            for ($j = $i + 1; $j -lt $nTasks; $j++) {
                $ti = $taskOrder[$i]
                $tj = $taskOrder[$j]
                foreach ($pi in $taskPaths[$ti]) {
                    foreach ($pj in $taskPaths[$tj]) {
                        $ov = Test-WavePathOverlap $pi $pj $waveCaseInsensitive
                        if ($ov -eq 'equal') {
                            $conflicts.Add("${pi}(${ti},${tj})")
                            $hasConflict[$i, $j] = $true
                            $hasConflict[$j, $i] = $true
                        } elseif ($ov -eq 'prefix') {
                            $conflicts.Add("${pi}<->${pj}(${ti},${tj})")
                            $hasConflict[$i, $j] = $true
                            $hasConflict[$j, $i] = $true
                        }
                    }
                }
            }
        }

        for ($i = 0; $i -lt $nTasks; $i++) {
            $ti = $taskOrder[$i]
            foreach ($tj in @($readPaths.Keys)) {
                if ($ti -ceq $tj) { continue }
                $j = [int]$taskIndexMap[$tj]
                foreach ($pi in $taskPaths[$ti]) {
                    foreach ($rj in $readPaths[$tj]) {
                        $ov = Test-WavePathOverlap $pi $rj $waveCaseInsensitive
                        if ($ov -eq 'equal') {
                            $conflicts.Add("rw:${pi}(${ti}->${tj})")
                            $hasConflict[$i, $j] = $true
                            $hasConflict[$j, $i] = $true
                        } elseif ($ov -eq 'prefix') {
                            $conflicts.Add("rw:${pi}<->${rj}(${ti}->${tj})")
                            $hasConflict[$i, $j] = $true
                            $hasConflict[$j, $i] = $true
                        }
                    }
                }
            }
        }

        $runDirtyCheck = [bool]($CheckDirtyScope -or ($IgnoreDirtyPaths -and $IgnoreDirtyPaths.Trim()) -or ($Partition -and $ExpectedBaseSha -and $ExpectedBaseSha.Trim()))
        $dirtyBlocked = New-Object 'bool[]' $nTasks
        $userDirtyList = New-Object System.Collections.Generic.List[string]
        $unexpectedDirtyList = New-Object System.Collections.Generic.List[string]
        $dirtyScopeVal = 'not_checked'
        $userDirtyCsv = 'none'
        $unexpectedDirtyCsv = 'none'
        $blockedTasksCsv = 'none'

        if ($runDirtyCheck) {
            $ignoreList = @()
            if ($IgnoreDirtyPaths -and $IgnoreDirtyPaths.Trim()) {
                $parsedIgn = ConvertTo-WavePaths $IgnoreDirtyPaths
                if ($parsedIgn.Error) { Fail $parsedIgn.Error 1 }
                $ignoreList = @($parsedIgn.Paths)
                foreach ($ign in $ignoreList) {
                    if ($ign -ceq '.') {
                        Fail "WAVE_FAIL: invalid ignore-dirty path '.'" 1
                    }
                    if ($repoExists -and (-not (Test-WavePathContained $RepoRoot $ign))) {
                        Fail "WAVE_FAIL: unsafe symlink or junction alias in path '$ign'" 1
                    }
                }
            }

            $midOpDirty = Test-GitMidOperation $RepoRoot
            if ($midOpDirty) {
                Fail "WAVE_BASE_MISMATCH: git_op_in_progress($midOpDirty)" 2
            }

            $diffHeadRes = Invoke-GitCommand $RepoRoot @('diff', '--no-ext-diff', '--no-renames', '--name-only', '-z', 'HEAD', '--')
            if ($diffHeadRes.ExitCode -ne 0) {
                Fail 'WAVE_BASE_MISMATCH: git diff HEAD failed' 2
            }
            $diffCachedRes = Invoke-GitCommand $RepoRoot @('diff', '--no-ext-diff', '--no-renames', '--cached', '--name-only', '-z', '--')
            if ($diffCachedRes.ExitCode -ne 0) {
                Fail 'WAVE_BASE_MISMATCH: git diff HEAD failed' 2
            }
            $lsUntrackedRes = Invoke-GitCommand $RepoRoot @('ls-files', '--others', '--exclude-standard', '-z')
            if ($lsUntrackedRes.ExitCode -ne 0) {
                Fail 'WAVE_BASE_MISMATCH: git diff HEAD failed' 2
            }

            $dirtySeen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
            $nulWave = [char]0
            foreach ($chunk in @($diffHeadRes.StdOut, $diffCachedRes.StdOut, $lsUntrackedRes.StdOut)) {
                if (-not $chunk) { continue }
                foreach ($dp in ($chunk.Split($nulWave))) {
                    if (-not $dp) { continue }
                    if (-not (Test-ValidLiteralGitPath $dp)) { Fail 'WAVE_FAIL: unsupported_literal_git_path' 1 }
                    if (Test-CheckpointPath $dp) { continue }
                    [void]$dirtySeen.Add($dp)
                }
            }

            $allDirtySorted = Sort-Ordinal ([string[]]$dirtySeen)
            $dirtyEntries = New-Object System.Collections.Generic.List[hashtable]
            foreach ($d in $allDirtySorted) {
                $dCmp = if ($waveCaseInsensitive) { $d.ToLowerInvariant() } else { $d }
                $isUserDirty = $false
                foreach ($ign in $ignoreList) {
                    $ignCmp = if ($waveCaseInsensitive) { $ign.ToLowerInvariant() } else { $ign }
                    if ($dCmp -ceq $ignCmp -or (($ign -cne '.') -and $dCmp.StartsWith("$ignCmp/", [System.StringComparison]::Ordinal))) {
                        $isUserDirty = $true
                        break
                    }
                }
                if ($isUserDirty) {
                    $userDirtyList.Add($d)
                    $dirtyEntries.Add(@{ Path = $d; Tag = 'USER_DIRTY' })
                } else {
                    $unexpectedDirtyList.Add($d)
                    $dirtyEntries.Add(@{ Path = $d; Tag = 'UNEXPECTED_DIRTY' })
                }
            }

            for ($i = 0; $i -lt $nTasks; $i++) {
                $ti = $taskOrder[$i]
                $taskAllPaths = New-Object System.Collections.Generic.List[string]
                foreach ($wp in $taskPaths[$ti]) { $taskAllPaths.Add($wp) }
                if ($readPaths.ContainsKey($ti)) {
                    foreach ($rp in $readPaths[$ti]) { $taskAllPaths.Add($rp) }
                }
                foreach ($de in $dirtyEntries) {
                    foreach ($tp in $taskAllPaths) {
                        $ov = Test-WavePathOverlap $de.Path $tp $waveCaseInsensitive
                        if ($ov -eq 'equal' -or $ov -eq 'prefix') {
                            $dirtyBlocked[$i] = $true
                            $conflicts.Add("dirty:$($de.Path)($($de.Tag)->${ti})")
                            break
                        }
                    }
                }
            }

            if ($unexpectedDirtyList.Count -gt 0) {
                $dirtyScopeVal = 'unexpected'
            } elseif ($userDirtyList.Count -gt 0) {
                $dirtyScopeVal = 'user_only'
            } else {
                $dirtyScopeVal = 'clean'
            }
            if ($userDirtyList.Count -gt 0) {
                $userDirtyCsv = ($userDirtyList.ToArray()) -join ','
            }
            if ($unexpectedDirtyList.Count -gt 0) {
                $unexpectedDirtyCsv = ($unexpectedDirtyList.ToArray()) -join ','
            }
            $blockedNames = New-Object System.Collections.Generic.List[string]
            for ($i = 0; $i -lt $nTasks; $i++) {
                if ($dirtyBlocked[$i]) { $blockedNames.Add($taskOrder[$i]) }
            }
            if ($blockedNames.Count -gt 0) {
                $blockedTasksCsv = ($blockedNames.ToArray()) -join ','
            }
        }

        if (-not $Partition) {
            if ($runDirtyCheck -and $unexpectedDirtyList.Count -gt 0) {
                Fail "WAVE_BASE_MISMATCH: unexpected_dirty($unexpectedDirtyCsv)" 2
            }
            $anyDirtyBlocked = $false
            for ($i = 0; $i -lt $nTasks; $i++) {
                if ($dirtyBlocked[$i]) { $anyDirtyBlocked = $true; break }
            }
            if ($anyDirtyBlocked -or $conflicts.Count -gt 0) {
                $sortedConflicts = (Sort-Ordinal $conflicts.ToArray()) -join ', '
                Fail "WAVE_CONFLICT: $sortedConflicts" 2
            }
            Write-Output "WAVE_OK: disjoint ($nTasks tasks, $totalPaths paths)"
            exit 0
        }

        $eligibleIndices = New-Object System.Collections.Generic.List[int]
        for ($i = 0; $i -lt $nTasks; $i++) {
            if (-not $dirtyBlocked[$i]) { $eligibleIndices.Add($i) }
        }
        $eligibleCount = $eligibleIndices.Count
        $blockedCount = $nTasks - $eligibleCount

        $waves = New-Object System.Collections.Generic.List[object]
        foreach ($i in $eligibleIndices) {
            $placed = $false
            for ($w = 0; $w -lt $waves.Count; $w++) {
                $members = $waves[$w]
                if ($members.Count -ge $waveMaxConc) { continue }
                $ok = $true
                foreach ($m in $members) {
                    if ($hasConflict[$i, $m]) { $ok = $false; break }
                }
                if ($ok) {
                    $members.Add($i)
                    $placed = $true
                    break
                }
            }
            if (-not $placed) {
                $newWave = New-Object System.Collections.Generic.List[int]
                $newWave.Add($i)
                $waves.Add($newWave)
            }
        }

        $wCount = $waves.Count
        $maxParallel = 0
        foreach ($waveMembers in $waves) {
            if ($waveMembers.Count -gt $maxParallel) { $maxParallel = $waveMembers.Count }
        }
        $conflictsCsv = if ($conflicts.Count -gt 0) { (Sort-Ordinal $conflicts.ToArray()) -join ',' } else { 'none' }

        Write-Output "dirty_scope=$dirtyScopeVal"
        Write-Output "user_dirty=$userDirtyCsv"
        Write-Output "unexpected_dirty=$unexpectedDirtyCsv"
        Write-Output "blocked_tasks=$blockedTasksCsv"
        Write-Output "wave_count=$wCount"
        Write-Output "max_concurrency=$waveMaxConc"
        Write-Output "max_parallel=$maxParallel"
        Write-Output "conflicts=$conflictsCsv"

        for ($w = 0; $w -lt $wCount; $w++) {
            $waveMembers = $waves[$w]
            $cnt = $waveMembers.Count
            $tNames = @()
            foreach ($m in $waveMembers) { $tNames += $taskOrder[$m] }
            $tasksCsv = $tNames -join ','
            if ($cnt -ge 2) {
                Write-Output "wave|$($w + 1)|PARALLEL|agents=$cnt|tasks=$tasksCsv|reason=independent_ready_tasks"
            } else {
                $t = $waveMembers[0]
                if ($eligibleCount -eq 1) {
                    $wReason = 'single_ready_task'
                } else {
                    $bounded = $false
                    for ($k = 0; $k -lt $w; $k++) {
                        $prior = $waves[$k]
                        if ($prior.Count -eq $waveMaxConc) {
                            $priorConflict = $false
                            foreach ($pm in $prior) {
                                if ($hasConflict[$t, $pm]) { $priorConflict = $true; break }
                            }
                            if (-not $priorConflict) {
                                $bounded = $true
                                break
                            }
                        }
                    }
                    if (-not $bounded -and $waveMaxConc -eq 1) {
                        $anyConf = $false
                        foreach ($u in $eligibleIndices) {
                            if ($u -ne $t -and $hasConflict[$t, $u]) { $anyConf = $true; break }
                        }
                        if (-not $anyConf) { $bounded = $true }
                    }
                    $wReason = if ($bounded) { 'bounded_concurrency' } else { 'shared_write_conflict' }
                }
                Write-Output "wave|$($w + 1)|SEQUENTIAL|agents=1|tasks=$tasksCsv|reason=$wReason"
            }
        }

        $eligibleHasPairConflict = $false
        for ($ei = 0; $ei -lt $eligibleCount; $ei++) {
            for ($ej = $ei + 1; $ej -lt $eligibleCount; $ej++) {
                if ($hasConflict[$eligibleIndices[$ei], $eligibleIndices[$ej]]) {
                    $eligibleHasPairConflict = $true
                    break
                }
            }
            if ($eligibleHasPairConflict) { break }
        }

        if ($runDirtyCheck -and $unexpectedDirtyList.Count -gt 0) {
            Write-Output "WAVE_BASE_MISMATCH: unexpected_dirty($unexpectedDirtyCsv)"
            exit 2
        } elseif ($eligibleCount -eq 0) {
            Write-Output "WAVE_SEQUENTIAL: waves=0 max_parallel=0 reason=dirty_scope_conflict"
            exit 2
        } elseif ($blockedCount -gt 0) {
            if ($maxParallel -ge 2) {
                Write-Output "WAVE_PARTITIONED: waves=$wCount max_parallel=$maxParallel reason=dirty_scope_partial_split"
                exit 0
            } else {
                Write-Output "WAVE_SEQUENTIAL: waves=$wCount max_parallel=1 reason=dirty_scope_partial_split"
                if (-not $eligibleHasPairConflict) { exit 0 } else { exit 2 }
            }
        } elseif ($wCount -eq 1 -and $conflictsCsv -eq 'none') {
            Write-Output "WAVE_OK: disjoint ($nTasks tasks, $totalPaths paths)"
            exit 0
        } elseif ($maxParallel -ge 2) {
            $termReason = if ($conflictsCsv -eq 'none') { 'bounded_concurrency_split' } else { 'conflicting_wave_split' }
            Write-Output "WAVE_PARTITIONED: waves=$wCount max_parallel=$maxParallel reason=$termReason"
            exit 0
        } elseif ($conflictsCsv -eq 'none') {
            Write-Output "WAVE_SEQUENTIAL: waves=$wCount max_parallel=1 reason=bounded_concurrency"
            exit 0
        } else {
            Write-Output "WAVE_SEQUENTIAL: waves=$wCount max_parallel=1 reason=shared_write_conflict"
            exit 2
        }
    }

    'new-run' {
        if (-not $Slug -or -not $Slug.Trim()) { Fail 'NEW_RUN_FAIL: missing -Slug' 1 }
        $cleanSlug = Get-SanitizedSlug $Slug
        if (-not $cleanSlug) { Fail 'NEW_RUN_FAIL: slug has no alphanumeric characters' 1 }

        $ts = if ($Timestamp) { $Timestamp.Trim() } else { (Get-Date).ToString('yyyyMMdd-HHmm') }
        if ($ts -notmatch '^[0-9]{8}-[0-9]{4}$') {
            Fail "NEW_RUN_FAIL: invalid timestamp '$ts' (expected YYYYMMDD-HHMM)" 1
        }

        $dotB3Dir = Join-Path $RepoRoot '.b3'
        $NsDir = Resolve-NamespaceDir $RepoRoot $Namespace
        $runsDir = Join-Path $NsDir 'runs'
        if ((Test-IsReparsePath $dotB3Dir) -or (Test-IsReparsePath $NsDir) -or (Test-IsReparsePath $runsDir)) {
            Fail 'NEW_RUN_FAIL: runs directory is a link' 1
        }
        New-Item -ItemType Directory -Path $runsDir -Force | Out-Null

        $baseId = "$ts-$cleanSlug"
        $candidate = $baseId
        $suffix = 2
        while (Test-Path -LiteralPath (Join-Path $runsDir $candidate)) {
            $candidate = "$baseId-$suffix"
            $suffix++
        }

        $runDir = Join-Path $runsDir $candidate
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null
        Write-AtomicLfFile (Join-Path $NsDir 'CURRENT') "$candidate`n"

        Write-Output $candidate
        exit 0
    }

    'resolve-run' {
        $nsTrim = if ($Namespace) { $Namespace.Trim() } else { 'ship' }
        $dotB3Dir = Join-Path $RepoRoot '.b3'
        $NsDir = Resolve-NamespaceDir $RepoRoot $nsTrim
        $nsRel = if ($nsTrim -ceq 'ship') { '.b3/ship' } else { '.b3/research-ship' }
        $runsDir = Join-Path $NsDir 'runs'
        if ((Test-IsReparsePath $dotB3Dir) -or (Test-IsReparsePath $NsDir) -or (Test-IsReparsePath $runsDir)) {
            Fail 'RESOLVE_FAIL: runs directory is a link' 1
        }
        $AutodevDir = Join-Path $RepoRoot '.b3\autodev'
        $autodevRunsDir = Join-Path $AutodevDir 'runs'

        if ($RunId) {
            $trimmed = $RunId.Trim()
            if (-not (Test-ValidRunId $trimmed)) {
                Fail "RESOLVE_FAIL: invalid run id '$RunId'" 1
            }
            $target = Join-Path $runsDir $trimmed
            if ((Test-Path -LiteralPath $target -PathType Container) -and -not (Test-IsReparsePath $target)) {
                Write-Output "$nsRel/runs/$trimmed"
                exit 0
            }
            if ($nsTrim -ceq 'ship') {
                $legacyTarget = Join-Path $autodevRunsDir $trimmed
                if ((Test-Path -LiteralPath $legacyTarget -PathType Container) -and -not (Test-IsReparsePath $legacyTarget)) {
                    Write-Output ".b3/autodev/runs/$trimmed"
                    exit 0
                }
            }
            Fail "RESOLVE_FAIL: run not found '$trimmed'" 1
        }

        $curFile = Join-Path $NsDir 'CURRENT'
        if ((Test-Path -LiteralPath $curFile -PathType Leaf) -and -not (Test-IsReparsePath $curFile)) {
            $curId = ([IO.File]::ReadAllText($curFile)).Trim()
            if (-not (Test-ValidRunId $curId)) {
                Fail "RESOLVE_FAIL: CURRENT contains invalid run id '$curId'" 1
            }
            $target = Join-Path $runsDir $curId
            if (-not (Test-Path -LiteralPath $target -PathType Container) -or (Test-IsReparsePath $target)) {
                Fail "RESOLVE_FAIL: CURRENT points to missing run '$curId'" 1
            }
            Write-Output "$nsRel/runs/$curId"
            exit 0
        }

        if ($nsTrim -ceq 'ship') {
            if (Test-Path -LiteralPath (Join-Path $NsDir 'progress.md') -PathType Leaf) {
                Write-Output '.b3/ship'
                exit 0
            }

            $autodevCur = Join-Path $AutodevDir 'CURRENT'
            if (Test-Path -LiteralPath $autodevCur -PathType Leaf) {
                $acId = ([IO.File]::ReadAllText($autodevCur)).Trim()
                if (-not (Test-ValidRunId $acId)) {
                    Fail "RESOLVE_FAIL: CURRENT contains invalid run id '$acId'" 1
                }
                $acTarget = Join-Path $autodevRunsDir $acId
                if (-not (Test-Path -LiteralPath $acTarget -PathType Container)) {
                    Fail "RESOLVE_FAIL: CURRENT points to missing run '$acId'" 1
                }
                Write-Output ".b3/autodev/runs/$acId"
                exit 0
            }

            if (Test-Path -LiteralPath (Join-Path $AutodevDir 'progress.md') -PathType Leaf) {
                Write-Output '.b3/autodev'
                exit 0
            }
        }

        Fail 'NO_ACTIVE_RUN' 1
    }

    'list-runs' {
        $nsTrim = if ($Namespace) { $Namespace.Trim() } else { 'ship' }
        $dotB3Dir = Join-Path $RepoRoot '.b3'
        $NsDir = Resolve-NamespaceDir $RepoRoot $nsTrim
        $runsDir = Join-Path $NsDir 'runs'
        if ((Test-IsReparsePath $dotB3Dir) -or (Test-IsReparsePath $NsDir) -or (Test-IsReparsePath $runsDir)) {
            Fail 'LIST_FAIL: runs directory is a link' 1
        }
        $curId = Get-CurrentRunId $NsDir

        $dirNames = @()
        if (Test-Path -LiteralPath $runsDir -PathType Container) {
            $rawNames = @(Get-ChildItem -LiteralPath $runsDir -Directory -Force | Where-Object { -not (Test-IsReparseItem $_) } | ForEach-Object { $_.Name })
            $dirNames = @(Sort-Ordinal $rawNames -Descending)
        }
        if ($dirNames.Count -gt 0) {
            foreach ($id in $dirNames) {
                $st = Get-RunStatus (Join-Path $runsDir $id)
                $mark = if ($curId -and ($id -ceq $curId)) { '* ' } else { '  ' }
                Write-Output "$mark$id [$st]"
            }
            exit 0
        }

        if ($nsTrim -ceq 'ship') {
            if (Test-Path -LiteralPath (Join-Path $NsDir 'progress.md') -PathType Leaf) {
                $st = Get-RunStatus $NsDir
                Write-Output "* legacy [$st]"
                exit 0
            }

            $AutodevDir = Join-Path $RepoRoot '.b3\autodev'
            $autodevRunsDir = Join-Path $AutodevDir 'runs'
            $autodevCur = Get-CurrentRunId $AutodevDir
            $adNames = @()
            if (Test-Path -LiteralPath $autodevRunsDir -PathType Container) {
                $rawAd = @(Get-ChildItem -LiteralPath $autodevRunsDir -Directory | ForEach-Object { $_.Name })
                $adNames = @(Sort-Ordinal $rawAd -Descending)
            }
            if ($adNames.Count -gt 0) {
                foreach ($id in $adNames) {
                    $st = Get-RunStatus (Join-Path $autodevRunsDir $id)
                    $mark = if ($autodevCur -and ($id -ceq $autodevCur)) { '* ' } else { '  ' }
                    Write-Output "$mark$id [$st] (legacy-autodev)"
                }
                exit 0
            }
            if (Test-Path -LiteralPath (Join-Path $AutodevDir 'progress.md') -PathType Leaf) {
                $st = Get-RunStatus $AutodevDir
                Write-Output "* legacy (legacy-autodev) [$st]"
                exit 0
            }
        }

        Write-Output 'NO_RUNS'
        exit 0
    }

    'prune' {
        if ($Keep -lt 0) { Fail 'PRUNE_FAIL: -Keep must be >= 0' 1 }
        $dotB3Dir = Join-Path $RepoRoot '.b3'
        $NsDir = Resolve-NamespaceDir $RepoRoot $Namespace
        $runsDir = Join-Path $NsDir 'runs'
        if ((Test-IsReparsePath $dotB3Dir) -or (Test-IsReparsePath $NsDir) -or (Test-IsReparsePath $runsDir)) {
            Fail 'PRUNE_FAIL: runs directory is a link' 1
        }
        if (-not (Test-Path -LiteralPath $runsDir -PathType Container)) {
            Write-Output 'PRUNE_OK: 0 removed'
            exit 0
        }

        $curId = Get-CurrentRunId $NsDir
        $rawNames = @(Get-ChildItem -LiteralPath $runsDir -Directory -Force | Where-Object { -not (Test-IsReparseItem $_) } | ForEach-Object { $_.Name })
        $dirNames = @(Sort-Ordinal $rawNames -Descending)
        $passCount = 0
        $pruned = New-Object System.Collections.Generic.List[string]

        foreach ($id in $dirNames) {
            $fullDir = Join-Path $runsDir $id
            $st = Get-RunStatus $fullDir
            $isCurrent = ($curId -and ($id -ceq $curId))
            if ($st -ceq 'PASS') {
                $passCount++
                if ($passCount -gt $Keep -and -not $isCurrent) {
                    Remove-DirTreeSafely $fullDir
                    $pruned.Add($id)
                }
            }
        }

        if ($pruned.Count -eq 0) {
            Write-Output 'PRUNE_OK: 0 removed'
        } else {
            foreach ($p in $pruned) { Write-Output "pruned: $p" }
            Write-Output "PRUNE_OK: $($pruned.Count) removed"
        }
        exit 0
    }

    'verify-run' {
        if (-not $VerifyCmd -or -not $VerifyCmd.Trim()) { Fail 'VERIFY_RUN_FAIL: missing -VerifyCmd' 1 }
        if (-not $ReceiptPath -or -not $ReceiptPath.Trim()) { Fail 'VERIFY_RUN_FAIL: missing -ReceiptPath' 1 }

        $receiptInfo = Resolve-SafeRepoWritePath $RepoRoot $ReceiptPath
        if (-not $receiptInfo -or (Test-Path -LiteralPath $receiptInfo.FullPath -PathType Container)) { Fail 'VERIFY_RUN_FAIL: invalid receipt_path' 1 }

        $effLogArg = if ($LogPath -and $LogPath.Trim()) { $LogPath } else { "$($receiptInfo.RelPath).log" }
        $logInfo = Resolve-SafeRepoWritePath $RepoRoot $effLogArg
        if (-not $logInfo -or (Test-Path -LiteralPath $logInfo.FullPath -PathType Container)) { Fail 'VERIFY_RUN_FAIL: invalid log_path' 1 }

        $effTaskId = if ($TaskId -and $TaskId.Trim()) { ($TaskId.Trim() -replace '[\r\n]+', ' ') } else { 'unknown' }
        $effScope = if ($Scope -and $Scope.Trim()) { ($Scope.Trim() -replace '[\r\n]+', ' ') } else { 'scoped' }
        $ignored = @(Split-PathCsvChecked $IgnoreDirtyPaths 'VERIFY_RUN_FAIL' -RejectDot)
        $relArr = @(Split-PathCsvChecked $RelevantPaths 'VERIFY_RUN_FAIL')

        $fullReceipt = $receiptInfo.FullPath
        $receiptRel = $receiptInfo.RelPath

        $psExe = $null
        try {
            $procPath = (Get-Process -Id $PID -ErrorAction SilentlyContinue).Path
            if ($procPath -and ($procPath -match '(powershell|pwsh)(\.exe)?$')) { $psExe = $procPath }
        } catch {}
        if (-not $psExe) {
            $psExe = if (Get-Command powershell -ErrorAction SilentlyContinue) { 'powershell' } else { 'pwsh' }
        }
        $wrapper = "`$global:LASTEXITCODE = 0`n& {`n$VerifyCmd`n}`nif (-not `$?) { if (`$LASTEXITCODE -and `$LASTEXITCODE -ne 0) { exit `$LASTEXITCODE } else { exit 1 } }`nif (`$LASTEXITCODE -and `$LASTEXITCODE -ne 0) { exit `$LASTEXITCODE }`nexit 0"
        $encCmd = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($wrapper))

        $outLines = New-Object System.Collections.Generic.List[string]
        $swVerify = [System.Diagnostics.Stopwatch]::StartNew()
        Push-Location $RepoRoot
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $rawOut = & $psExe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encCmd 2>&1
            $cmdExit = $LASTEXITCODE
        } finally {
            $swVerify.Stop()
            $ErrorActionPreference = $prevEap
            Pop-Location
        }
        $durationMs = [Math]::Max(0L, [long]$swVerify.ElapsedMilliseconds)
        foreach ($item in @($rawOut)) {
            if ($null -eq $item) { continue }
            $s = if ($item -is [System.Management.Automation.ErrorRecord]) { $item.ToString() } else { [string]$item }
            foreach ($sub in ($s -split "\r?\n")) {
                $outLines.Add($sub)
            }
        }

        $fp = Get-TreeFingerprint $RepoRoot $relArr $ignored
        $statusVal = if ($cmdExit -eq 0) { 'PASS' } else { 'FAIL' }

        $logDisp = 'none'
        if ($cmdExit -ne 0 -or $outLines.Count -gt 35) {
            $fullLog = $logInfo.FullPath
            $logBody = if ($outLines.Count -gt 0) { ($outLines.ToArray() -join "`n") + "`n" } else { '' }
            Write-AtomicLfFile $fullLog $logBody
            $logDisp = $logInfo.RelPath
        }

        $singleCmd = ($VerifyCmd -replace '[\r\n]+', ' ').Trim()
        $tsUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $receiptBody = @(
            "schema=b3-verify-v1",
            "task_id=$effTaskId",
            "scope=$effScope",
            "head_sha=$($fp.HeadSha)",
            "tree_hash=$($fp.TreeHash)",
            "relevant_paths=$($fp.PathsCsv)",
            "exit_code=$cmdExit",
            "status=$statusVal",
            "duration_ms=$durationMs",
            "command=$singleCmd",
            "log_path=$logDisp",
            "timestamp_utc=$tsUtc"
        ) -join "`n"
        Write-AtomicLfFile $fullReceipt "$receiptBody`n"

        $shortTree = $fp.TreeHash.Substring(0, 12)
        if ($cmdExit -eq 0) {
            Write-Output "VERIFY_PASS: exit=0 tree=$shortTree receipt=$receiptRel duration_ms=$durationMs"
            exit 0
        }
        Write-Output "VERIFY_FAIL: exit=$cmdExit tree=$shortTree receipt=$receiptRel log=$logDisp duration_ms=$durationMs"
        $cap = [Math]::Min(35, $outLines.Count)
        for ($i = 0; $i -lt $cap; $i++) {
            Write-Output $outLines[$i]
        }
        exit 1
    }

    'verify-check' {
        if ($PSBoundParameters.ContainsKey('TargetCommitSha') -and (-not $TargetCommitSha -or -not $TargetCommitSha.Trim())) {
            Fail 'VERIFY_CHECK_FAIL: empty -TargetCommitSha' 1
        }
        $ignored = @(Split-PathCsvChecked $IgnoreDirtyPaths 'VERIFY_CHECK_FAIL' -RejectDot)
        $res = Test-VerifyReceipt $RepoRoot $ReceiptPath $ignored $ExpectedCmd $RelevantPaths $TargetCommitSha
        Write-Output $res.Message
        exit $res.Code
    }

    'symbol-check' {
        $ignored = @(Split-PathCsvChecked $IgnoreDirtyPaths 'SYMBOL_FAIL' -RejectDot)
        $scopeTarget = Resolve-ScopeTargetAndBase $RepoRoot $TargetRef $BaseSha $ignored 'SYMBOL_FAIL' 'object'
        $targetTrim = $scopeTarget.TargetRef
        $targetCommitSha = $scopeTarget.TargetCommitSha
        $resolvedBase = $scopeTarget.BaseSha

        $dlArgs = if ($targetTrim) {
            @('diff', '--no-ext-diff', '--no-renames', '-U0', $resolvedBase, $targetCommitSha, '--')
        } else {
            @('diff', '--no-ext-diff', '--no-renames', '-U0', $resolvedBase, '--')
        }
        $dlRes = Invoke-GitCommand $RepoRoot $dlArgs
        if ($dlRes.ExitCode -ne 0) {
            $detail = if ($dlRes.StdErr.Trim()) { $dlRes.StdErr.Trim() } else { $dlRes.StdOut.Trim() }
            Fail ("SYMBOL_FAIL: git diff -U0 failed: $detail") 1
        }

        $removedByFile = @{}
        $addedByFile = @{}
        $oldFile = ''
        $newFile = ''
        $skipOld = $true
        $skipNew = $true
        $inHunk = $false

        foreach ($rawLine in ($dlRes.StdOut -split "\r?\n")) {
            $ln = ([string]$rawLine).Replace("`r", '')
            if ($ln.StartsWith('diff --git ')) {
                $oldFile = ''; $newFile = ''; $skipOld = $true; $skipNew = $true; $inHunk = $false
                continue
            }
            if (-not $inHunk -and $ln.StartsWith('--- ')) {
                if ($ln -eq '--- /dev/null') {
                    $oldFile = ''; $skipOld = $true
                } else {
                    $cand = $ln.Substring(4)
                    if ($cand.StartsWith('a/')) { $cand = $cand.Substring(2) }
                    $oldFile = Normalize-PathValue $cand
                    $skipOld = (-not $oldFile) -or (Test-CheckpointPath $oldFile) -or (Test-PathMatch $oldFile $ignored) -or (Test-NoiseFile $oldFile) -or (-not (Test-CodePath $oldFile))
                }
                continue
            }
            if (-not $inHunk -and $ln.StartsWith('+++ ')) {
                if ($ln -eq '+++ /dev/null') {
                    $newFile = ''; $skipNew = $true
                } else {
                    $cand = $ln.Substring(4)
                    if ($cand.StartsWith('b/')) { $cand = $cand.Substring(2) }
                    $newFile = Normalize-PathValue $cand
                    $skipNew = (-not $newFile) -or (Test-CheckpointPath $newFile) -or (Test-PathMatch $newFile $ignored) -or (Test-NoiseFile $newFile) -or (-not (Test-CodePath $newFile))
                }
                continue
            }
            if ($ln -match '^@@ -[0-9,]+ \+[0-9,]+ @@') {
                $inHunk = $true
                continue
            }
            if (-not $inHunk) { continue }
            if ($ln.StartsWith('-') -and -not $skipOld) {
                $sym = Extract-SymbolDecl $oldFile $ln.Substring(1)
                if ($sym) {
                    if (-not $removedByFile.ContainsKey($oldFile)) { $removedByFile[$oldFile] = @{} }
                    $prevExp = if ($removedByFile[$oldFile].ContainsKey($sym.Name)) { [bool]$removedByFile[$oldFile][$sym.Name] } else { $false }
                    $removedByFile[$oldFile][$sym.Name] = ($prevExp -or $sym.Exported)
                }
            } elseif ($ln.StartsWith('+') -and -not $skipNew) {
                $sym = Extract-SymbolDecl $newFile $ln.Substring(1)
                if ($sym) {
                    if (-not $addedByFile.ContainsKey($newFile)) { $addedByFile[$newFile] = @{} }
                    $prevExp = if ($addedByFile[$newFile].ContainsKey($sym.Name)) { [bool]$addedByFile[$newFile][$sym.Name] } else { $false }
                    $addedByFile[$newFile][$sym.Name] = ($prevExp -or $sym.Exported)
                }
            }
        }

        if (-not $targetTrim) {
            $untracked = @(Invoke-GitLines $RepoRoot @('ls-files', '--others', '--exclude-standard'))
            foreach ($u in @(Sort-Ordinal $untracked)) {
                if (-not $u -or (Test-CheckpointPath $u) -or (Test-PathMatch $u $ignored) -or (Test-NoiseFile $u) -or (-not (Test-CodePath $u))) { continue }
                $full = Join-Path $RepoRoot ($u -replace '/', '\')
                if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
                foreach ($fl in @(Get-Content -LiteralPath $full -ErrorAction SilentlyContinue)) {
                    $sym = Extract-SymbolDecl $u ([string]$fl)
                    if ($sym) {
                        if (-not $addedByFile.ContainsKey($u)) { $addedByFile[$u] = @{} }
                        $prevExp = if ($addedByFile[$u].ContainsKey($sym.Name)) { [bool]$addedByFile[$u][$sym.Name] } else { $false }
                        $addedByFile[$u][$sym.Name] = ($prevExp -or $sym.Exported)
                    }
                }
            }
        }

        $removedSyms = New-Object System.Collections.Generic.List[string]
        $exportedRemoved = New-Object System.Collections.Generic.List[string]
        $danglingRefs = New-Object System.Collections.Generic.List[string]
        $orphanInternal = New-Object System.Collections.Generic.List[string]

        $addedAnywhere = @{}
        $removedAnywhere = @{}
        foreach ($af in @($addedByFile.Keys)) {
            foreach ($as in @($addedByFile[$af].Keys)) {
                $isAddExp = [bool]$addedByFile[$af][$as]
                $prevAny = if ($addedAnywhere.ContainsKey($as)) { [bool]$addedAnywhere[$as] } else { $false }
                $addedAnywhere[$as] = ($prevAny -or $isAddExp)
            }
        }
        foreach ($rf in @($removedByFile.Keys)) {
            foreach ($rs in @($removedByFile[$rf].Keys)) {
                $removedAnywhere[$rs] = $true
            }
        }

        $remChecked = @{}
        foreach ($f in @($removedByFile.Keys)) {
            foreach ($sName in @($removedByFile[$f].Keys)) {
                $isExp = [bool]$removedByFile[$f][$sName]
                $inSameFile = ($addedByFile.ContainsKey($f) -and $addedByFile[$f].ContainsKey($sName))
                $sameFileExp = if ($inSameFile) { [bool]$addedByFile[$f][$sName] } else { $false }
                $inAnyFile = $addedAnywhere.ContainsKey($sName)
                $anyFileExp = if ($inAnyFile) { [bool]$addedAnywhere[$sName] } else { $false }

                if ($inSameFile) {
                    if (-not $isExp -or $sameFileExp) { continue }
                } elseif ($inAnyFile) {
                    if (-not $isExp -or $anyFileExp) { continue }
                }

                if (-not $removedSyms.Contains($sName)) { $removedSyms.Add($sName) }
                if ($isExp -and -not $exportedRemoved.Contains($sName)) { $exportedRemoved.Add($sName) }
                if ($remChecked.ContainsKey($sName)) { continue }
                $remChecked[$sName] = $true

                $gArgs = if ($targetTrim) {
                    @('grep', '-w', '-F', '-l', '-e', $sName, $targetCommitSha, '--', '.', ':(exclude).b3', ':(exclude)*.md')
                } else {
                    @('grep', '--untracked', '-w', '-F', '-l', '-e', $sName, '--', '.', ':(exclude).b3', ':(exclude)*.md')
                }
                $gRes = Invoke-GitCommand $RepoRoot $gArgs
                if ($gRes.ExitCode -gt 1) { Fail "SYMBOL_FAIL: git grep failed for '$sName'" 1 }
                if ($gRes.ExitCode -eq 0) {
                    $hitFiles = New-Object System.Collections.Generic.List[string]
                    $commitPrefix = "${targetCommitSha}:"
                    foreach ($row in ($gRes.StdOut -split "\r?\n")) {
                        $rStr = ([string]$row).Trim()
                        if (-not $rStr) { continue }
                        if ($targetTrim -and $rStr.StartsWith($commitPrefix)) { $rStr = $rStr.Substring($commitPrefix.Length) }
                        $np = Normalize-PathValue $rStr
                        if (-not $np -or (Test-CheckpointPath $np) -or (Test-PathMatch $np $ignored) -or (Test-NoiseFile $np) -or (-not (Test-CodePath $np))) { continue }
                        if ($inSameFile -and $np -ceq $f) { continue }
                        if (-not $hitFiles.Contains($np)) { $hitFiles.Add($np) }
                    }
                    if ($hitFiles.Count -gt 0) {
                        $danglingRefs.Add("${sName}($($hitFiles.Count)f)")
                    }
                }
            }
        }

        foreach ($f in @($addedByFile.Keys)) {
            if (Test-TestPath $f) { continue }
            foreach ($sName in @($addedByFile[$f].Keys)) {
                $isExp = [bool]$addedByFile[$f][$sName]
                if ($isExp) { continue }
                if ($removedAnywhere.ContainsKey($sName)) { continue }

                $gnArgs = if ($targetTrim) {
                    @('grep', '-w', '-F', '-n', '-e', $sName, $targetCommitSha, '--', '.', ':(exclude).b3', ':(exclude)*.md')
                } else {
                    @('grep', '--untracked', '-w', '-F', '-n', '-e', $sName, '--', '.', ':(exclude).b3', ':(exclude)*.md')
                }
                $gnRes = Invoke-GitCommand $RepoRoot $gnArgs
                if ($gnRes.ExitCode -gt 1) { Fail "SYMBOL_FAIL: git grep -n failed for '$sName'" 1 }
                $lineHits = 0
                if ($gnRes.ExitCode -eq 0) {
                    $commitPrefix = "${targetCommitSha}:"
                    foreach ($row in ($gnRes.StdOut -split "\r?\n")) {
                        $rStr = ([string]$row).Trim()
                        if (-not $rStr) { continue }
                        if ($targetTrim -and $rStr.StartsWith($commitPrefix)) { $rStr = $rStr.Substring($commitPrefix.Length) }
                        $cIdx = $rStr.IndexOf(':')
                        if ($cIdx -lt 1) { continue }
                        $np = Normalize-PathValue ($rStr.Substring(0, $cIdx))
                        if (-not $np -or (Test-CheckpointPath $np) -or (Test-PathMatch $np $ignored) -or (Test-NoiseFile $np) -or (-not (Test-CodePath $np))) { continue }
                        $lineHits++
                    }
                }
                if ($lineHits -le 1) {
                    $orphanInternal.Add("${f}:${sName}")
                }
            }
        }

        $remOut = if ($removedSyms.Count -gt 0) { (Sort-Ordinal $removedSyms.ToArray()) -join ',' } else { 'none' }
        $expOut = if ($exportedRemoved.Count -gt 0) { (Sort-Ordinal $exportedRemoved.ToArray()) -join ',' } else { 'none' }
        $danOut = if ($danglingRefs.Count -gt 0) { (Sort-Ordinal $danglingRefs.ToArray()) -join ',' } else { 'none' }
        $orpOut = if ($orphanInternal.Count -gt 0) { (Sort-Ordinal $orphanInternal.ToArray()) -join ',' } else { 'none' }

        Write-Output "removed_symbols=$remOut"
        Write-Output "exported_removed=$expOut"
        Write-Output "dangling_refs=$danOut"
        Write-Output "orphan_internal=$orpOut"
        if ($danOut -eq 'none' -and $orpOut -eq 'none') {
            Write-Output 'SYMBOL_OK'
            exit 0
        }
        Write-Output 'SYMBOL_FINDINGS'
        exit 2
    }

    'check-worktree' {
        $repoId = Resolve-SafeWorktreeIdentity $RepoRoot 'missing_repo_root' 'not_a_git_repo' -RequireHead
        $actualRootNorm = $repoId.TopNorm
        $actCommon = $repoId.CommonDir
        $actGitDir = $repoId.GitDir
        $headRaw = $repoId.Head

        $midOp = Test-GitMidOperation $repoId.Logical
        if ($midOp) {
            Fail "WORKTREE_UNSAFE: git_op_in_progress($midOp)" 2
        }

        $isWin = ([IO.Path]::DirectorySeparatorChar -eq '\')
        $isCaseInsensitive = $isWin -or ($IsMacOS -eq $true)
        $sameGitDir = if ($isCaseInsensitive) { $actGitDir -ieq $actCommon } else { $actGitDir -ceq $actCommon }
        $isLinked = if (-not $sameGitDir) { 'true' } else { 'false' }

        $peerRawTrim = if ($PeerRoots) { $PeerRoots.Trim() } else { '' }
        $peerList = New-Object System.Collections.Generic.List[string]
        if ($peerRawTrim -and $peerRawTrim -cne '[]' -and $peerRawTrim -cne 'none') {
            $peerInner = if ($peerRawTrim.StartsWith('[') -and $peerRawTrim.EndsWith(']')) {
                $peerRawTrim.Substring(1, $peerRawTrim.Length - 2)
            } else {
                $peerRawTrim
            }
            foreach ($pPart in ($peerInner -split ',')) {
                $pTok = $pPart.Trim()
                if (-not $pTok -or $pTok -ceq 'none') { continue }
                $peerList.Add($pTok)
            }
        }

        $hasExpectedRoot = [bool]($ExpectedRoot -and $ExpectedRoot.Trim())
        if ($RequireIsolated -and -not $hasExpectedRoot) {
            Fail 'WORKTREE_UNSAFE: missing_expected_root_for_isolation' 2
        }
        $checkIsolation = [bool]($RequireIsolated -or ($hasExpectedRoot -and $peerList.Count -gt 0))

        $expTopNorm = ''
        $commonSame = $false
        if ($hasExpectedRoot) {
            $expId = Resolve-SafeWorktreeIdentity ($ExpectedRoot.Trim()) 'expected_root_missing' 'expected_root_not_git'
            $expTopNorm = $expId.TopNorm
            $expCommon = $expId.CommonDir

            $topSame = if ($isCaseInsensitive) { $actualRootNorm -ieq $expTopNorm } else { $actualRootNorm -ceq $expTopNorm }
            if ($actCommon -and $expCommon) {
                $commonSame = if ($isCaseInsensitive) { $actCommon -ieq $expCommon } else { $actCommon -ceq $expCommon }
            }
            if (-not $topSame -and -not $commonSame) {
                Fail "WORKTREE_UNSAFE: root_mismatch(expected=$expTopNorm,actual=$actualRootNorm)" 2
            }
            if ($checkIsolation) {
                if (Test-WorktreeRootOverlap $actualRootNorm $expTopNorm $isCaseInsensitive) {
                    Fail "WORKTREE_UNSAFE: parent_root_reused_or_nested(parent=$expTopNorm,worker=$actualRootNorm)" 2
                }
                if ($isLinked -cne 'true' -or -not $commonSame) {
                    Fail "WORKTREE_UNSAFE: not_isolated_linked_worktree(parent=$expTopNorm,worker=$actualRootNorm)" 2
                }
            }
        }

        if ($peerList.Count -gt 0) {
            $seenTops = New-Object System.Collections.Generic.List[string]
            $seenTops.Add($actualRootNorm)
            foreach ($peer in $peerList) {
                $peerId = Resolve-SafeWorktreeIdentity $peer 'missing_peer_root' 'peer_not_git'
                $peerTopNorm = $peerId.TopNorm
                $peerCommon = $peerId.CommonDir
                $peerCommonSame = if ($isCaseInsensitive) { $actCommon -ieq $peerCommon } else { $actCommon -ceq $peerCommon }
                if (-not $peerCommonSame) {
                    Fail "WORKTREE_UNSAFE: peer_repo_mismatch(expected=$actCommon,actual=$peerCommon)" 2
                }
                if ($checkIsolation -and $hasExpectedRoot) {
                    if (Test-WorktreeRootOverlap $peerTopNorm $expTopNorm $isCaseInsensitive) {
                        Fail "WORKTREE_UNSAFE: parent_root_reused_or_nested(parent=$expTopNorm,worker=$peerTopNorm)" 2
                    }
                }
                foreach ($prevTop in $seenTops) {
                    if (Test-WorktreeRootOverlap $peerTopNorm $prevTop $isCaseInsensitive) {
                        Fail "WORKTREE_UNSAFE: duplicate_or_nested_worktree($peerTopNorm)" 2
                    }
                }
                $seenTops.Add($peerTopNorm)
            }
        }

        if ($ExpectedBaseSha -and $ExpectedBaseSha.Trim()) {
            $expSha = $ExpectedBaseSha.Trim()
            if ($headRaw -cne $expSha) {
                Fail "WORKTREE_UNSAFE: base_mismatch(expected=$expSha,actual=$headRaw)" 2
            }
        }

        $isIsolated = if ($hasExpectedRoot -and $commonSame -and ($isLinked -ceq 'true') -and (-not (Test-WorktreeRootOverlap $actualRootNorm $expTopNorm $isCaseInsensitive))) {
            'true'
        } else {
            'false'
        }
        Write-Output "WORKTREE_OK: root=$actualRootNorm head=$headRaw common_dir=$actCommon linked=$isLinked isolated=$isIsolated"
        exit 0
    }

    'review-inventory' {
        $ignored = @(Split-PathCsvChecked $IgnoreDirtyPaths 'INVENTORY_FAIL' -RejectDot)
        $scopeTarget = Resolve-ScopeTargetAndBase $RepoRoot $TargetRef $BaseSha $ignored 'INVENTORY_FAIL' 'object'
        $targetTrim = $scopeTarget.TargetRef
        $targetCommitSha = $scopeTarget.TargetCommitSha
        $resolvedBase = $scopeTarget.BaseSha

        $inv = Invoke-BuildInventory $RepoRoot $resolvedBase $targetCommitSha $ignored $MaxConcurrency 'INVENTORY_FAIL'
        if ($inv.IsEmpty) { Fail 'EMPTY_DIFF' 2 }
        if ($inv.PartitionError) { Fail $inv.PartitionError 2 }

        $cfOut = if ($inv.ContractFiles.Count -gt 0) { $inv.ContractFiles -join ',' } else { 'none' }
        $gfOut = if ($inv.GeneratedFiles.Count -gt 0) { $inv.GeneratedFiles -join ',' } else { 'none' }
        $tfOut = if ($inv.TestFiles.Count -gt 0) { $inv.TestFiles -join ',' } else { 'none' }
        $nfOut = if ($inv.NoiseFiles.Count -gt 0) { $inv.NoiseFiles -join ',' } else { 'none' }
        $splitStr = if ($inv.SplitRecommended) { 'true' } else { 'false' }

        Write-Output "size_class=$($inv.SizeClass)"
        Write-Output "files=$($inv.FilesCount)"
        Write-Output "lines=$($inv.LinesCount)"
        Write-Output "risk_level=$($inv.RiskLevel)"
        Write-Output "risk_signals=$($inv.RiskSignals)"
        Write-Output "recommended_specialists=$($inv.RecommendedSpecialists)"
        Write-Output "l1_specialists=$($inv.L1Specialists)"
        Write-Output "l1_skip_rationale=$($inv.L1SkipRationale)"
        Write-Output "change_types=$($inv.ChangeTypes)"
        Write-Output "contract_files=$cfOut"
        Write-Output "generated_files=$gfOut"
        Write-Output "test_files=$tfOut"
        Write-Output "noise_files=$nfOut"
        Write-Output "split_recommended=$splitStr"
        Write-Output "max_concurrency=$($inv.MaxConcurrency)"
        Write-Output "unit_count=$($inv.Units.Count)"
        foreach ($u in $inv.Units) {
            Write-Output "unit|$($u.UnitId)|$($u.Group)|$($u.FilesCnt)|$($u.LinesCnt)|$($u.Risk)|$($u.Specialists)|$($u.Signals)|$($u.FilesCsv)"
        }
        exit 0
    }

    'review-ledger' {
        $act = $Action.Trim().ToLowerInvariant()
        if ($act -notin @('init', 'update', 'normalize', 'check')) {
            Fail "LEDGER_FAIL: -Action must be init, update, normalize, or check" 1
        }
        if ($act -eq 'normalize' -and -not $LedgerPath.Trim()) {
            if (-not $Scope.Trim()) { Fail 'LEDGER_FAIL: -LedgerPath or -Scope required for normalize' 1 }
            $norm = Normalize-SizeClass $Scope
            if (-not $norm) { Fail "LEDGER_FAIL: unknown size class '$Scope'" 1 }
            Write-Output $norm
            exit 0
        }

        $safeInfo = Resolve-SafeRepoWritePath $RepoRoot $LedgerPath
        if (-not $safeInfo) { Fail 'LEDGER_FAIL: invalid -LedgerPath' 1 }
        $ledgerFull = $safeInfo.FullPath
        $ledgerRel = $safeInfo.RelPath
        $ignored = @(Split-PathCsvChecked $IgnoreDirtyPaths 'LEDGER_FAIL' -RejectDot)

        if ($act -eq 'normalize') {
            if (-not (Test-Path -LiteralPath $ledgerFull -PathType Leaf)) {
                Fail "LEDGER_MISSING: $ledgerRel" 1
            }
            $orig = [IO.File]::ReadAllText($ledgerFull)
            $script:normChanges = 0
            $updated = [regex]::Replace($orig, '(?im)^(-?\s*size_class\s*[:=]\s*)(SMALL|MEDIUM|LARGE|VERY_LARGE)\b', {
                param($m)
                $n = Normalize-SizeClass $m.Groups[2].Value
                $script:normChanges++
                return "$($m.Groups[1].Value)$n"
            })
            if (($updated -cmatch '(?m)^schema=b3-review-ledger-v1\r?$') -and ($updated -cnotmatch '(?m)^review_independence=')) {
                if ($updated -cmatch '(?m)^budget_status=[^\r\n]*') {
                    $updated = [regex]::Replace($updated, '(?m)^(budget_status=[^\r\n]*)', "`$1`nreview_independence=UNKNOWN", 1)
                    $script:normChanges++
                }
            }
            if ($script:normChanges -gt 0) {
                Write-AtomicLfFile $ledgerFull $updated
            }
            Write-Output "LEDGER_NORMALIZED: path=$ledgerRel changes=$($script:normChanges)"
            exit 0
        }

        if ($act -eq 'init') {
            if (Test-Path -LiteralPath $ledgerFull -PathType Container) { Fail 'LEDGER_FAIL: -LedgerPath is a directory' 1 }
            $maxPassesExplicit = $PSBoundParameters.ContainsKey('MaxPasses')
            if ($maxPassesExplicit -and $MaxPasses -le 0) {
                Fail 'LEDGER_FAIL: -MaxPasses must be a positive integer' 1
            }
            $riInit = if ($ReviewIndependence -and $ReviewIndependence.Trim()) { $ReviewIndependence.Trim().ToUpperInvariant() } else { 'UNKNOWN' }
            if ($riInit -cnotin @('UNKNOWN', 'INDEPENDENT', 'SINGLE_AGENT_LIMIT')) {
                Fail "LEDGER_FAIL: invalid -ReviewIndependence '$riInit'" 1
            }
            $scopeTarget = Resolve-ScopeTargetAndBase $RepoRoot $TargetRef $BaseSha $ignored 'LEDGER_FAIL' 'commit'
            $targetTrim = $scopeTarget.TargetRef
            $targetCommitSha = $scopeTarget.TargetCommitSha
            $resolvedBase = $scopeTarget.BaseSha
            $headSha = if ($targetCommitSha) { $targetCommitSha } else { Assert-ValidGitRev $RepoRoot 'HEAD' 'commit' 'LEDGER_FAIL' 'HEAD' }

            if ((-not $Force) -and (Test-Path -LiteralPath $ledgerFull -PathType Leaf)) {
                $initCall = Invoke-CapturedGuardCall {
                    $led = Parse-ReviewLedger $ledgerFull
                    Verify-LedgerPassChain $RepoRoot $led
                    return $led
                }
                if (-not $initCall.Ok -or $null -eq $initCall.Result) {
                    Fail "LEDGER_CORRUPT: cannot overwrite corrupt ledger '$ledgerRel' without --force" 1
                }
                $existingLed = $initCall.Result
                if ($existingLed['base_sha'] -ceq $resolvedBase) {
                    if ([int]$existingLed['passes_used'] -gt 0 -or $existingLed['budget_status'] -ceq 'EXHAUSTED' -or $existingLed['review_independence'] -ceq 'SINGLE_AGENT_LIMIT') {
                        Fail "LEDGER_FAIL: cannot reset active ledger '$ledgerRel' on same base_sha without --force" 1
                    }
                }
            }

            $inv = Invoke-BuildInventory $RepoRoot $resolvedBase $targetCommitSha $ignored $MaxConcurrency 'LEDGER_FAIL'
            if ($inv.IsEmpty) { Fail 'LEDGER_FAIL: EMPTY_DIFF' 2 }
            if ($inv.PartitionError) { Fail $inv.PartitionError 2 }
            $effectiveMaxPasses = if ($maxPassesExplicit) { $MaxPasses } else { Get-DefaultMaxPasses $inv.SizeClass $inv.Units.Count }

            if ($targetCommitSha) {
                $snapSha = $targetCommitSha
            } else {
                $headTree = Assert-ValidGitRev $RepoRoot 'HEAD' 'tree' 'LEDGER_FAIL' 'HEAD^{tree}'
                $wtTree = New-WorkingTreeOid $RepoRoot 'LEDGER_FAIL'
                if ($wtTree -ceq $headTree) {
                    $snapSha = $headSha
                } else {
                    $ctRes = Invoke-GitCommand $RepoRoot @('commit-tree', $wtTree, '-p', $headSha, '-m', 'b3-ledger-snapshot')
                    $snapSha = $ctRes.StdOut.Trim()
                    if ($ctRes.ExitCode -ne 0 -or $snapSha -notmatch '^[0-9a-f]{40}$') { Fail 'LEDGER_FAIL: git commit-tree failed' 1 }
                }
            }

            $initChain = Get-InitialPassChain $RepoRoot $resolvedBase

            $unitRows = New-Object System.Collections.Generic.List[hashtable]
            foreach ($u in $inv.Units) {
                $fpPaths = @($u.Files) + @($inv.ContractFiles)
                $uHash = Get-ScopePathsTreeHash $RepoRoot $targetCommitSha $fpPaths $ignored
                [void]$unitRows.Add(@{
                    unit_id = $u.UnitId
                    group = $u.Group
                    files_cnt = $u.FilesCnt
                    lines_cnt = $u.LinesCnt
                    risk = $u.Risk
                    specialists = 'none'
                    rationale = 'none'
                    status = 'PENDING'
                    findings = 'none'
                    verify_receipt = 'none'
                    unit_tree_hash = $uHash
                    files_csv = $u.FilesCsv
                })
            }

            $needCross = ($inv.SizeClass -in @('L', 'XL', 'XXL') -and $unitRows.Count -gt 1)
            $crossStatus = if ($needCross) { 'PENDING' } else { 'N_A' }
            $crossPaths = if ($inv.ContractFiles.Count -gt 0) { $inv.ContractFiles } else { $inv.ReviewFiles }
            $crossHash = if ($needCross) { Get-ScopePathsTreeHash $RepoRoot $targetCommitSha $crossPaths $ignored } else { 'none' }

            $ledger = @{
                schema = 'b3-review-ledger-v1'
                base_sha = $resolvedBase
                head_sha = $headSha
                target_ref = if ($targetTrim) { $targetTrim } else { 'working_tree' }
                target_sha = if ($targetCommitSha) { $targetCommitSha } else { 'none' }
                snapshot_sha = $snapSha
                size_class = $inv.SizeClass
                normalized_legacy_size = 'none'
                risk_level = $inv.RiskLevel
                risk_signals = $inv.RiskSignals
                recommended_specialists = $inv.RecommendedSpecialists
                l1_specialists = $inv.L1Specialists
                l1_skip_rationale = $inv.L1SkipRationale
                contract_files = if ($inv.ContractFiles.Count -gt 0) { $inv.ContractFiles -join ',' } else { 'none' }
                generated_files = if ($inv.GeneratedFiles.Count -gt 0) { $inv.GeneratedFiles -join ',' } else { 'none' }
                max_concurrency = [string]$inv.MaxConcurrency
                max_passes = [string]$effectiveMaxPasses
                passes_used = '0'
                pass_chain = $initChain
                budget_status = 'OK'
                review_independence = $riInit
                cross_unit_status = $crossStatus
                cross_unit_tree_hash = $crossHash
                unit_count = [string]$unitRows.Count
                Units = @($unitRows)
                PassLog = (New-Object System.Collections.Generic.List[hashtable])
            }
            Write-AtomicLfFile $ledgerFull (Serialize-ReviewLedger $ledger)
            Write-Output "LEDGER_INIT: path=$ledgerRel size=$($inv.SizeClass) risk=$($inv.RiskLevel) units=$($unitRows.Count) max_passes=$effectiveMaxPasses snapshot=$snapSha"
            exit 0
        }

        if (-not (Test-Path -LiteralPath $ledgerFull -PathType Leaf)) {
            Fail "LEDGER_MISSING: $ledgerRel" 1
        }
        $ledger = Parse-ReviewLedger $ledgerFull
        $origRawSize = $ledger['size_class']
        $normSize = Normalize-SizeClass $origRawSize
        $legacyNormNote = if ($origRawSize -cne $normSize) { "${origRawSize}:${normSize}" } else { $ledger['normalized_legacy_size'] }
        $ledger['size_class'] = $normSize
        $ledger['normalized_legacy_size'] = $legacyNormNote
        $targetRefVal = $ledger['target_ref']
        $targetCommitSha = if ($targetRefVal -cne 'working_tree') { $ledger['target_sha'] } else { '' }

        if ($act -eq 'update') {
            Verify-LedgerPassChain $RepoRoot $ledger
            $maxPassesExplicit = $PSBoundParameters.ContainsKey('MaxPasses')
            if ($maxPassesExplicit -and $MaxPasses -le 0) {
                Fail 'LEDGER_FAIL: -MaxPasses must be a positive integer' 1
            }
            if ($maxPassesExplicit -and $MaxPasses -gt [int]$ledger['max_passes']) {
                Fail "LEDGER_CORRUPT: cannot raise max_passes ($($ledger['max_passes'])->$MaxPasses)" 1
            }
            $passesUsedExplicit = $PSBoundParameters.ContainsKey('PassesUsed')
            if ($passesUsedExplicit -and $PassesUsed -lt 0) {
                Fail 'LEDGER_FAIL: -PassesUsed must be non-negative' 1
            }
            $origHeadSha = $ledger['head_sha']
            $riExplicit = [bool]($ReviewIndependence -and $ReviewIndependence.Trim())
            if ($riExplicit) {
                $riUpd = $ReviewIndependence.Trim().ToUpperInvariant()
                if ($riUpd -cnotin @('UNKNOWN', 'INDEPENDENT', 'SINGLE_AGENT_LIMIT')) {
                    Fail "LEDGER_FAIL: invalid -ReviewIndependence '$riUpd'" 1
                }
                if ($ledger['review_independence'] -ceq 'SINGLE_AGENT_LIMIT' -and $riUpd -ceq 'INDEPENDENT') {
                    Fail 'LEDGER_FAIL: cannot upgrade SINGLE_AGENT_LIMIT to INDEPENDENT' 1
                }
                if ($ledger['review_independence'] -ceq 'SINGLE_AGENT_LIMIT' -and $riUpd -ceq 'UNKNOWN') {
                    Fail 'LEDGER_FAIL: cannot clear SINGLE_AGENT_LIMIT' 1
                }
                $ledger['review_independence'] = $riUpd
            }
            $liveScopeUpd = $null
            $liveContractsUpd = @()
            $found = $null
            $stVal = ''
            $addedNewSpec = $false
            $cuVal = if ($CrossUnitStatus.Trim()) { $CrossUnitStatus.Trim().ToUpperInvariant() } else { '' }
            if ($UnitId.Trim()) {
                $targetU = $UnitId.Trim()
                foreach ($u in $ledger.Units) {
                    if ($u.unit_id -ceq $targetU) { $found = $u; break }
                }
                if (-not $found) { Fail "LEDGER_FAIL: unknown -UnitId '$targetU'" 1 }
                if ($Status.Trim()) {
                    $stVal = $Status.Trim().ToUpperInvariant()
                    if ($stVal -notin @('PENDING', 'IN_PROGRESS', 'REVIEWED', 'INCOMPLETE', 'STALE', 'BLOCKED')) {
                        Fail "LEDGER_FAIL: invalid unit -Status '$stVal'" 1
                    }
                    $found.status = $stVal
                }
                if ($Findings.Trim()) { $found.findings = ($Findings.Trim() -replace '[\r\n|]+', ';') }
                if ($Specialists.Trim()) {
                    $oldSpList = @($found.specialists -split ',' | Where-Object { $_ -and $_ -cne 'none' })
                    $spArr = @(Split-CsvList $Specialists)
                    foreach ($nsItem in $spArr) {
                        if ($nsItem -notin $oldSpList) { $addedNewSpec = $true; break }
                    }
                    $found.specialists = if ($spArr.Count -gt 0) { (Sort-Ordinal $spArr) -join ',' } else { 'none' }
                }
                if ($Rationale.Trim()) { $found.rationale = ($Rationale.Trim() -replace '[\r\n|]+', ' ') }
                if ($ReceiptPath.Trim()) {
                    if ($ReceiptPath.Trim() -ceq 'none') {
                        $found.verify_receipt = 'none'
                    } else {
                        $rSafe = Resolve-SafeRepoWritePath $RepoRoot $ReceiptPath
                        if (-not $rSafe) { Fail 'LEDGER_FAIL: invalid -ReceiptPath' 1 }
                        $found.verify_receipt = $rSafe.RelPath
                    }
                }
            }
            if (($found -and $stVal -ceq 'REVIEWED') -or ($cuVal -ceq 'REVIEWED')) {
                if ($targetRefVal -cne 'working_tree') {
                    $trLiveRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--verify', '--quiet', "${targetRefVal}^{commit}")
                    $trLiveSha = $trLiveRes.StdOut.Trim()
                    if ($trLiveRes.ExitCode -ne 0 -or $trLiveSha -cnotmatch '^[0-9a-f]{40}$') {
                        Fail "LEDGER_STALE: target_ref '$targetRefVal' cannot be resolved" 2
                    }
                    $targetCommitSha = $trLiveSha
                    $ledger['target_sha'] = $trLiveSha
                    $ledger['head_sha'] = $trLiveSha
                    $ledger['snapshot_sha'] = $trLiveSha
                }
                $liveScopeUpd = Invoke-CollectScopeData $RepoRoot $ledger['base_sha'] $targetCommitSha $ignored 'LEDGER_FAIL'
                $liveContractsUpd = @($liveScopeUpd.ReviewFiles | Where-Object { Test-ContractPath $_ })
                $ledger['contract_files'] = if ($liveContractsUpd.Count -gt 0) { $liveContractsUpd -join ',' } else { 'none' }
                if ($liveScopeUpd.ReviewFiles.Count -gt 0) {
                    $overallUpdRisk = Eval-RiskForSubset $liveScopeUpd.ReviewFiles $liveScopeUpd.FileSignals $liveScopeUpd.FileLines
                    $ledger['risk_level'] = $overallUpdRisk.RiskLevel
                    $ledger['risk_signals'] = $overallUpdRisk.RiskSignals
                    $ledger['recommended_specialists'] = $overallUpdRisk.RecommendedSpecialists
                    $l1Upd = Eval-Level1Dispatch $liveContractsUpd $overallUpdRisk.RecommendedSpecialists $overallUpdRisk.RiskLevel $liveScopeUpd.ReviewFiles
                    $ledger['l1_specialists'] = $l1Upd.L1Specialists
                    $ledger['l1_skip_rationale'] = $l1Upd.L1SkipRationale
                }
            }
            if ($found -and $stVal -ceq 'REVIEWED') {
                $uFiles = @(Split-CsvList $found.files_csv -AsPaths)
                $liveULinesUpd = 0
                foreach ($ufItem in $uFiles) {
                    if ($liveScopeUpd.FileLines.ContainsKey($ufItem)) { $liveULinesUpd += [int]$liveScopeUpd.FileLines[$ufItem] }
                }
                $liveURiskUpd = Eval-RiskForSubset $uFiles $liveScopeUpd.FileSignals $liveScopeUpd.FileLines
                $found.files_cnt = $uFiles.Count
                $found.lines_cnt = $liveULinesUpd
                $found.risk = $liveURiskUpd.RiskLevel
                $found.unit_tree_hash = Get-ScopePathsTreeHash $RepoRoot $targetCommitSha ($uFiles + $liveContractsUpd) $ignored
                $ledger['head_sha'] = if ($targetCommitSha) { $targetCommitSha } else { Assert-ValidGitRev $RepoRoot 'HEAD' 'commit' 'LEDGER_FAIL' 'HEAD' }
            }
            if ($cuVal) {
                if ($cuVal -notin @('N_A', 'PENDING', 'REVIEWED', 'INCOMPLETE', 'STALE', 'BLOCKED')) {
                    Fail "LEDGER_FAIL: invalid -CrossUnitStatus '$cuVal'" 1
                }
                $ledger['cross_unit_status'] = $cuVal
                if ($cuVal -ceq 'REVIEWED') {
                    $allUnitFiles = New-Object System.Collections.Generic.List[string]
                    foreach ($u in $ledger.Units) {
                        foreach ($uf in @(Split-CsvList $u.files_csv -AsPaths)) {
                            if (-not $allUnitFiles.Contains($uf)) { [void]$allUnitFiles.Add($uf) }
                        }
                    }
                    $cuPaths = if ($liveContractsUpd.Count -gt 0) { $liveContractsUpd } else { $allUnitFiles.ToArray() }
                    $ledger['cross_unit_tree_hash'] = Get-ScopePathsTreeHash $RepoRoot $targetCommitSha $cuPaths $ignored
                }
            }
            if ($ledger['head_sha'] -cne $origHeadSha -and -not $riExplicit -and $ledger['review_independence'] -ceq 'INDEPENDENT') {
                $ledger['review_independence'] = 'UNKNOWN'
            }

            $passEvents = New-Object System.Collections.Generic.List[hashtable]
            if ($found -and $stVal -in @('REVIEWED', 'INCOMPLETE', 'BLOCKED')) {
                [void]$passEvents.Add(@{ scope = $found.unit_id; kind = "unit:$stVal"; delta = 1 })
            } elseif ($found -and $addedNewSpec) {
                [void]$passEvents.Add(@{ scope = $found.unit_id; kind = 'specialist'; delta = 1 })
            }
            if ($cuVal -in @('REVIEWED', 'INCOMPLETE', 'BLOCKED')) {
                [void]$passEvents.Add(@{ scope = 'cross_unit'; kind = "cross_unit:$cuVal"; delta = 1 })
            }
            $autoDelta = 0
            foreach ($pe in $passEvents) { $autoDelta += [int]$pe.delta }
            $curPasses = [int]$ledger['passes_used']
            $minNextPasses = $curPasses + $autoDelta
            if ($passesUsedExplicit) {
                if ($PassesUsed -lt $curPasses) {
                    Fail "LEDGER_FAIL: passes_used cannot be reduced or reset (${curPasses}->${PassesUsed})" 1
                }
                if ($PassesUsed -lt $minNextPasses) {
                    Fail "LEDGER_FAIL: passes_used ($PassesUsed) cannot bypass consumed passes (minimum $minNextPasses)" 1
                }
                $newPasses = $PassesUsed
                $extraManual = $newPasses - $minNextPasses
                if ($extraManual -gt 0) {
                    [void]$passEvents.Add(@{ scope = 'manual'; kind = 'manual'; delta = $extraManual })
                }
            } else {
                $newPasses = $minNextPasses
            }

            $curChain = $ledger['pass_chain']
            $evtRefSha = if ($targetCommitSha) { $targetCommitSha } elseif ($ledger['head_sha'] -cmatch '^[0-9a-f]{40}$') { $ledger['head_sha'] } else { 'none' }
            foreach ($pe in $passEvents) {
                $nextSeq = $ledger.PassLog.Count + 1
                $curChain = Step-PassChain $RepoRoot $curChain $nextSeq $pe.scope $pe.kind ([int]$pe.delta) $evtRefSha
                [void]$ledger.PassLog.Add(@{
                    seq = $nextSeq
                    scope = $pe.scope
                    kind = $pe.kind
                    delta = [int]$pe.delta
                    ref_sha = $evtRefSha
                    chain_hash = $curChain
                })
            }
            $ledger['passes_used'] = [string]$newPasses
            $ledger['pass_chain'] = $curChain

            if ($maxPassesExplicit) { $ledger['max_passes'] = [string]$MaxPasses }
            $effMaxP = [int]$ledger['max_passes']
            if ($BudgetStatus.Trim()) {
                $bs = $BudgetStatus.Trim().ToUpperInvariant()
                if ($bs -notin @('OK', 'EXHAUSTED')) { Fail "LEDGER_FAIL: invalid -BudgetStatus '$bs'" 1 }
                if ($bs -ceq 'OK' -and $effMaxP -gt 0 -and $newPasses -gt $effMaxP) {
                    Fail "LEDGER_FAIL: cannot set budget_status=OK while passes_used ($newPasses) exceeds max_passes ($effMaxP)" 1
                }
                $ledger['budget_status'] = $bs
            } elseif ($effMaxP -gt 0 -and $newPasses -gt $effMaxP) {
                $ledger['budget_status'] = 'EXHAUSTED'
            }
            Write-AtomicLfFile $ledgerFull (Serialize-ReviewLedger $ledger)
            Write-Output "LEDGER_UPDATED: path=$ledgerRel"
            exit 0
        }

        # check
        $chkRes = Invoke-ReviewLedgerCheck $RepoRoot $ledgerFull $ledgerRel $ignored
        Write-Output $chkRes.Message
        exit $chkRes.Code
    }

    'evidence-check' {
        $mSpec = Test-ContainedRepoPath $RepoRoot $ManifestPath
        if (-not $mSpec) {
            Fail 'EVIDENCE_MISSING: invalid manifest path' 1
        }
        $srcList = @(Split-PathCsvChecked $SourcePaths 'EVIDENCE_MISSING' -RejectDot -DotMessage 'EVIDENCE_MISSING: invalid path .')

        if ($WriteManifest) {
            if ($srcList.Count -lt 1) {
                Fail 'EVIDENCE_MISSING: missing -SourcePaths' 1
            }
            $checked = New-Object System.Collections.Generic.List[string]
            foreach ($sp in $srcList) {
                $c = Test-ContainedRepoPath $RepoRoot $sp
                if (-not $c) { Fail "EVIDENCE_MISSING: invalid path $sp" 1 }
                $checked.Add($c.Rel)
            }
            $sortedSrc = @(Sort-Ordinal $checked.ToArray())
            $missingList = New-Object System.Collections.Generic.List[string]
            $entries = New-Object System.Collections.Generic.List[string]
            foreach ($rel in $sortedSrc) {
                $full = Resolve-TargetPath $RepoRoot $rel
                if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
                    $missingList.Add($rel)
                } else {
                    $hashHex = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
                    $entries.Add("file=$hashHex $rel")
                }
            }
            if ($missingList.Count -gt 0) {
                Fail ("EVIDENCE_MISSING: " + ($missingList.ToArray() -join ',')) 1
            }

            $headRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--verify', '--quiet', 'HEAD')
            $rawHead = $headRes.StdOut.Trim()
            $headSha = if ($headRes.ExitCode -eq 0 -and $rawHead -match '^[0-9a-f]{40}$') { $rawHead } else { 'NO_HEAD' }
            $tsUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
            $bodyLines = New-Object System.Collections.Generic.List[string]
            $bodyLines.Add('schema=b3-evidence-v1')
            $bodyLines.Add("head_sha=$headSha")
            $bodyLines.Add("timestamp_utc=$tsUtc")
            foreach ($e in $entries) { $bodyLines.Add($e) }
            Write-AtomicLfFile $mSpec.Full (($bodyLines.ToArray() -join "`n") + "`n")
            Write-Output "EVIDENCE_WRITTEN: $($entries.Count) files -> $($mSpec.Rel)"
            exit 0
        }

        if (-not (Test-Path -LiteralPath $mSpec.Full -PathType Leaf)) {
            Fail "EVIDENCE_MISSING: missing manifest ($($mSpec.Rel))" 1
        }
        $rawManifest = [IO.File]::ReadAllText($mSpec.Full)
        $hasSchema = $false
        $hasHead = $false
        $hasTs = $false
        $manifestMap = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)
        $manifestOrder = New-Object System.Collections.Generic.List[string]
        foreach ($rawLine in ($rawManifest -split "\r?\n")) {
            $ln = $rawLine.Trim()
            if (-not $ln) { continue }
            if ($ln -ceq 'schema=b3-evidence-v1') { $hasSchema = $true; continue }
            if ($ln -match '^head_sha=([0-9a-f]{40}|NO_HEAD)$') { $hasHead = $true; continue }
            if ($ln -match '^timestamp_utc=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$') { $hasTs = $true; continue }
            if ($ln -match '^file=([0-9a-f]{64})[ \t]+(.+)$') {
                $h = $Matches[1]
                $rp = $Matches[2].Trim()
                $c = Test-ContainedRepoPath $RepoRoot $rp
                if (-not $c) { Fail "EVIDENCE_MISSING: invalid path $rp" 1 }
                if ($manifestMap.ContainsKey($c.Rel)) { Fail "EVIDENCE_MISSING: duplicate entry $($c.Rel)" 1 }
                $manifestMap[$c.Rel] = $h
                $manifestOrder.Add($c.Rel)
                continue
            }
            Fail "EVIDENCE_MISSING: invalid manifest ($($mSpec.Rel))" 1
        }
        if (-not $hasSchema -or -not $hasHead -or -not $hasTs -or $manifestOrder.Count -lt 1) {
            Fail "EVIDENCE_MISSING: invalid manifest ($($mSpec.Rel))" 1
        }

        if ($srcList.Count -gt 0) {
            $uncovered = New-Object System.Collections.Generic.List[string]
            foreach ($sp in $srcList) {
                $c = Test-ContainedRepoPath $RepoRoot $sp
                if (-not $c) { Fail "EVIDENCE_MISSING: invalid path $sp" 1 }
                if (-not $manifestMap.ContainsKey($c.Rel) -and -not ($uncovered -ccontains $c.Rel)) {
                    $uncovered.Add($c.Rel)
                }
            }
            if ($uncovered.Count -gt 0) {
                $sortedUnc = (Sort-Ordinal $uncovered.ToArray()) -join ','
                Fail "EVIDENCE_MISSING: uncovered $sortedUnc" 1
            }
        }

        $missingFiles = New-Object System.Collections.Generic.List[string]
        $staleFiles = New-Object System.Collections.Generic.List[string]
        foreach ($rel in $manifestOrder) {
            $c = Test-ContainedRepoPath $RepoRoot $rel
            if (-not $c) { Fail "EVIDENCE_MISSING: invalid path $rel" 1 }
            if (-not (Test-Path -LiteralPath $c.Full -PathType Leaf)) {
                $missingFiles.Add($rel)
            } else {
                $curHash = (Get-FileHash -LiteralPath $c.Full -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($curHash -cne $manifestMap[$rel]) {
                    $staleFiles.Add($rel)
                }
            }
        }
        if ($missingFiles.Count -gt 0) {
            Fail ("EVIDENCE_MISSING: " + ((Sort-Ordinal $missingFiles.ToArray()) -join ',')) 1
        }
        if ($staleFiles.Count -gt 0) {
            Fail ("EVIDENCE_STALE: " + ((Sort-Ordinal $staleFiles.ToArray()) -join ',')) 2
        }
        Write-Output "EVIDENCE_FRESH: $($manifestOrder.Count) files"
        exit 0
    }

    'merge-policy-check' {
        $mpErrPrefix = if ($PostMerge) { 'POST_MERGE_FAILED' } else { 'MERGE_BLOCKED' }
        [void](Split-PathCsvChecked $IgnoreDirtyPaths $mpErrPrefix -RejectDot)

        $prStateExplicit = $PSBoundParameters.ContainsKey('PrState')
        $ciStatusExplicit = $PSBoundParameters.ContainsKey('CiStatus')
        $revStatusExplicit = $PSBoundParameters.ContainsKey('ReviewStatus')

        $prSt = if ($PrState) { $PrState.Trim() } else { 'NONE' }
        if ($prSt -cnotin @('OPEN', 'MERGED', 'CLOSED', 'NONE')) { Fail "MERGE_BLOCKED: invalid_pr_state=$prSt" 1 }
        $ciSt = if ($CiStatus) { $CiStatus.Trim() } else { 'UNKNOWN' }
        if ($ciSt -cnotin @('PASS', 'FAIL', 'PENDING', 'UNKNOWN')) { Fail "MERGE_BLOCKED: invalid_ci_status=$ciSt" 1 }
        $revSt = if ($ReviewStatus) { $ReviewStatus.Trim() } else { 'UNKNOWN' }
        if ($revSt -cnotin @('PASS', 'BLOCKED', 'PENDING', 'UNKNOWN')) { Fail "MERGE_BLOCKED: invalid_review_status=$revSt" 1 }
        $govSt = if ($GovernanceStatus) { $GovernanceStatus.Trim() } else { 'CLEAR' }
        if ($govSt -cnotin @('CLEAR', 'BLOCKED', 'MISSING_OWNER_DECISION', 'WITHHELD_PROMOTION', 'UNAUTHORIZED_AUTHORITY', 'INVALID_EDITORIAL_REVIEW', 'UNAUTHORIZED_REVIEWER')) {
            Fail "MERGE_BLOCKED: invalid_governance=$govSt" 1
        }
        if ($BlockingFindings -lt 0) { Fail "MERGE_BLOCKED: invalid_blocking_findings=$BlockingFindings" 1 }
        $prNumTrim = if ($PrNumber) { $PrNumber.Trim() } else { '' }
        $targetBrTrim = if ($TargetBranch) { $TargetBranch.Trim() } else { '' }
        if ($targetBrTrim -and ($targetBrTrim.StartsWith('-') -or ($targetBrTrim -match '[\s\x00-\x1F\x7F]') -or $targetBrTrim.Contains('..'))) {
            Fail "${mpErrPrefix}: invalid_target_branch" 1
        }
        $tRefArgTrim = if ($TargetRef) { $TargetRef.Trim() } else { '' }
        $mRefArgTrim = if ($MainRef) { $MainRef.Trim() } else { '' }
        if ($tRefArgTrim -and $mRefArgTrim -and ($tRefArgTrim -cne $mRefArgTrim)) {
            Fail "${mpErrPrefix}: conflicting_target_ref" 1
        }
        $effTargetRefArg = if ($tRefArgTrim) { $tRefArgTrim } else { $mRefArgTrim }
        $authRefArgTrim = if ($AuthorityRef) { $AuthorityRef.Trim() } else { '' }
        $headShaArgTrim = if ($HeadSha) { $HeadSha.Trim() } else { '' }

        if ($PostMerge) {
            if ($prStateExplicit -and $prSt -cne 'MERGED') { Fail "POST_MERGE_FAILED: pr_state=$prSt" 1 }
            $mRef = $effTargetRefArg
            if (-not $mRef) {
                Fail 'POST_MERGE_FAILED: missing_main_ref' 1
            }
            if ($mRef.StartsWith('-') -or ($mRef -match '[\s\x00-\x1F\x7F]') -or ($mRef -imatch '^(HEAD([~^].*)?|@([~^{].*)?)$')) {
                Fail 'POST_MERGE_FAILED: invalid_main_ref' 1
            }
            $symRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--symbolic-full-name', $mRef)
            $symFull = $symRes.StdOut.Trim()
            if ($symRes.ExitCode -ne 0 -or (-not ($symFull.StartsWith('refs/heads/', [System.StringComparison]::Ordinal) -or $symFull.StartsWith('refs/remotes/', [System.StringComparison]::Ordinal)))) {
                Fail 'POST_MERGE_FAILED: invalid_main_ref' 1
            }
            $localTargetBranch = ''
            if ($symFull.StartsWith('refs/heads/', [System.StringComparison]::Ordinal)) {
                $localTargetBranch = $symFull.Substring('refs/heads/'.Length)
            } elseif ($symFull -cmatch '^refs/remotes/[^/]+/(.+)$') {
                $localTargetBranch = $Matches[1]
            }
            if (-not $localTargetBranch) {
                Fail 'POST_MERGE_FAILED: invalid_main_ref' 1
            }
            if ($targetBrTrim -and $targetBrTrim -cne $localTargetBranch) {
                Fail "POST_MERGE_FAILED: target_branch_mismatch(expected=$targetBrTrim,got=$localTargetBranch)" 1
            }
            $mSha = if ($MergedSha) { $MergedSha.Trim() } else { '' }
            if ($mSha -and $mSha.StartsWith('-')) {
                Fail 'POST_MERGE_FAILED: invalid_ref' 1
            }
            if ($headShaArgTrim -and $headShaArgTrim.StartsWith('-')) {
                Fail 'POST_MERGE_FAILED: invalid_ref' 1
            }

            if ($prNumTrim) {
                if ($prNumTrim -cnotmatch '^[1-9][0-9]*$') {
                    Fail 'POST_MERGE_FAILED: invalid_pr_number' 1
                }
                $ghPost = Invoke-B3GitHubVerify 'post-merge' $RepoRoot $Repo $prNumTrim 'POST_MERGE_FAILED'
                if ($ghPost['pr_number'] -cne $prNumTrim) {
                    Fail 'POST_MERGE_FAILED: pr_identity_mismatch' 1
                }
                if ($Repo -and $Repo.Trim() -and (-not $ghPost['base_repo'].Equals($Repo.Trim(), [System.StringComparison]::OrdinalIgnoreCase))) {
                    Fail 'POST_MERGE_FAILED: pr_identity_mismatch' 1
                }
                if ($ghPost['pr_merged'] -cne 'true' -or $ghPost['pr_state'] -cne 'CLOSED') {
                    Fail "POST_MERGE_FAILED: pr_not_merged(state=$($ghPost['pr_state']),merged=$($ghPost['pr_merged']))" 1
                }
                $ghMergeSha = $ghPost['merge_commit_sha']
                $ghBaseRef = $ghPost['base_ref']
                $ghHeadSha = $ghPost['head_sha']
                if ($ghMergeSha -cnotmatch '^[0-9a-f]{40}$') {
                    Fail 'POST_MERGE_FAILED: missing_merge_commit_sha' 1
                }
                if ($localTargetBranch -cne $ghBaseRef) {
                    Fail "POST_MERGE_FAILED: target_branch_mismatch(expected=$ghBaseRef,got=$localTargetBranch)" 1
                }
                if ($targetBrTrim -and $targetBrTrim -cne $ghBaseRef) {
                    Fail "POST_MERGE_FAILED: target_branch_mismatch(expected=$ghBaseRef,got=$targetBrTrim)" 1
                }
                if ($mSha) {
                    $callerMRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--verify', '--quiet', "${mSha}^{commit}")
                    $callerMSha = $callerMRes.StdOut.Trim()
                    if ($callerMRes.ExitCode -ne 0 -or $callerMSha -cnotmatch '^[0-9a-f]{40}$') {
                        Fail 'POST_MERGE_FAILED: unresolvable_commit' 1
                    }
                    if ($callerMSha -cne $ghMergeSha) {
                        Fail "POST_MERGE_FAILED: merge_commit_sha_mismatch(expected=$ghMergeSha,got=$callerMSha)" 1
                    }
                }
                if ($headShaArgTrim) {
                    $callerHRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--verify', '--quiet', "${headShaArgTrim}^{commit}")
                    $callerHSha = $callerHRes.StdOut.Trim()
                    if ($callerHRes.ExitCode -ne 0 -or $callerHSha -cnotmatch '^[0-9a-f]{40}$') {
                        Fail 'POST_MERGE_FAILED: invalid_head_sha' 1
                    }
                    if ($callerHSha -cne $ghHeadSha) {
                        Fail "POST_MERGE_FAILED: head_sha_mismatch(expected=$ghHeadSha,got=$callerHSha)" 1
                    }
                }
                if ($ghPost['compare_status'] -cnotin @('identical', 'ahead') -or $ghPost['compare_behind_by'] -cne '0') {
                    Fail "POST_MERGE_FAILED: merge_commit_not_in_remote_target(status=$($ghPost['compare_status']),target_ref=$ghBaseRef)" 1
                }

                $mergedRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--verify', '--quiet', "${ghMergeSha}^{commit}")
                $resMerged = $mergedRes.StdOut.Trim()
                $mainRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--verify', '--quiet', "${mRef}^{commit}")
                $resMain = $mainRes.StdOut.Trim()
                if ($mergedRes.ExitCode -ne 0 -or $resMerged -cnotmatch '^[0-9a-f]{40}$' -or $mainRes.ExitCode -ne 0 -or $resMain -cnotmatch '^[0-9a-f]{40}$') {
                    Fail 'POST_MERGE_FAILED: unresolvable_commit' 1
                }
                $ancRes = Invoke-GitCommand $RepoRoot @('merge-base', '--is-ancestor', $resMerged, $resMain)
                if ($ancRes.ExitCode -ne 0) {
                    Fail "POST_MERGE_FAILED: sha_not_in_target(sha=$resMerged,target_ref=$ghBaseRef,main_ref=$mRef)" 1
                }

                # Enforce allowed_target_branches strictly from remote policy_authority_sha on default_branch
                $ghPmAuthRef = $ghPost['policy_authority_ref']
                $ghPmAuthSha = $ghPost['policy_authority_sha']
                if (-not $ghPmAuthRef -or $ghPmAuthSha -cnotmatch '^[0-9a-f]{40}$') {
                    Fail 'POST_MERGE_FAILED: incomplete_pr_metadata' 1
                }
                $pmAuthLocRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--verify', '--quiet', "${ghPmAuthSha}^{commit}")
                if ($pmAuthLocRes.ExitCode -ne 0 -or $pmAuthLocRes.StdOut.Trim() -cne $ghPmAuthSha) {
                    Fail 'POST_MERGE_FAILED: policy_authority_not_fetched' 1
                }
                $ghPmPolLs = Invoke-GitCommand $RepoRoot @('ls-tree', $ghPmAuthSha, '--', '.b3/research-policy.json')
                if ($ghPmPolLs.ExitCode -ne 0) {
                    Fail 'POST_MERGE_FAILED: policy_authority_not_fetched' 1
                }
                $ghPmPolLn = $ghPmPolLs.StdOut.Trim()
                if ($ghPmPolLn) {
                    if ($ghPmPolLn -cnotmatch "^(100644|100755) blob ([0-9a-f]{40})`t\.b3/research-policy\.json$") {
                        Fail 'POST_MERGE_FAILED: invalid_policy_path' 1
                    }
                    $ghPmPolShow = Invoke-GitCommand $RepoRoot @('show', "${ghPmAuthSha}:.b3/research-policy.json")
                    if ($ghPmPolShow.ExitCode -ne 0) {
                        Fail 'POST_MERGE_FAILED: policy_not_in_authority' 1
                    }
                    $polCallGhPm = Invoke-CapturedGuardCall {
                        $polObj = Parse-MergePolicyJsonText $ghPmPolShow.StdOut
                        return @($polObj.AllowedTargetBranches)
                    }
                    if (-not $polCallGhPm.Ok) {
                        if ($polCallGhPm.Message -match '^MERGE_BLOCKED: (.+)$') {
                            Fail "POST_MERGE_FAILED: $($Matches[1])" 1
                        }
                        Fail 'POST_MERGE_FAILED: invalid_policy_json' 1
                    }
                    $ghPmAllowed = @($polCallGhPm.Result)
                    if ($ghPmAllowed.Count -gt 0 -and (-not (Test-BranchPatternMatch $ghBaseRef $ghPmAllowed))) {
                        Fail "POST_MERGE_FAILED: target_branch_not_allowed($ghBaseRef)" 1
                    }
                }

                $parRes = Invoke-GitCommand $RepoRoot @('rev-list', '--parents', '-n', '1', $resMerged)
                if ($parRes.ExitCode -ne 0) { Fail 'POST_MERGE_FAILED: unresolvable_commit' 1 }
                $parToks = @($parRes.StdOut.Trim() -split '\s+' | Where-Object { $_ })
                $parCnt = $parToks.Count - 1
                $mergeKind = 'squash_or_rebase'
                if ($parCnt -ge 2) {
                    $mergeKind = 'merge_commit'
                    $headAncRes = Invoke-GitCommand $RepoRoot @('merge-base', '--is-ancestor', $ghHeadSha, $resMerged)
                    if ($headAncRes.ExitCode -ne 0) {
                        Fail 'POST_MERGE_FAILED: merge_commit_head_mismatch' 1
                    }
                } elseif ($resMerged -ceq $ghHeadSha) {
                    $mergeKind = 'fast_forward'
                }

                Write-Output "POST_MERGE_VERIFIED: mode=github pr=$($ghPost['base_repo'])#$prNumTrim pr_status=PR_MERGED sha=$resMerged target_ref=$ghBaseRef main_ref=$mRef merge_kind=$mergeKind runtime_served=NOT_VERIFIED deployed=NOT_VERIFIED"
                exit 0
            }

            # Provider-neutral local post-merge verification (no -PrNumber)
            if (-not $mSha) { Fail 'POST_MERGE_FAILED: missing_merged_sha' 1 }
            if ($mSha -notmatch '^[0-9a-fA-F]{40}$') { Fail 'POST_MERGE_FAILED: invalid_merged_sha' 1 }
            if (-not $headShaArgTrim) { Fail 'POST_MERGE_FAILED: missing_head_sha' 1 }
            if ($headShaArgTrim -notmatch '^[0-9a-fA-F]{40}$') { Fail 'POST_MERGE_FAILED: invalid_head_sha' 1 }

            $mergedRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--verify', '--quiet', "${mSha}^{commit}")
            $resMerged = $mergedRes.StdOut.Trim()
            $headPmRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--verify', '--quiet', "${headShaArgTrim}^{commit}")
            $resHeadPm = $headPmRes.StdOut.Trim()
            $mainRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--verify', '--quiet', "${mRef}^{commit}")
            $resMain = $mainRes.StdOut.Trim()
            if ($mergedRes.ExitCode -ne 0 -or $resMerged -cnotmatch '^[0-9a-f]{40}$' -or
                $headPmRes.ExitCode -ne 0 -or $resHeadPm -cnotmatch '^[0-9a-f]{40}$' -or
                $mainRes.ExitCode -ne 0 -or $resMain -cnotmatch '^[0-9a-f]{40}$') {
                Fail 'POST_MERGE_FAILED: unresolvable_commit' 1
            }

            $resBasePm = ''
            $basePmTrim = if ($BaseSha) { $BaseSha.Trim() } else { '' }
            if ($basePmTrim) {
                if ($basePmTrim.StartsWith('-') -or $basePmTrim -notmatch '^[0-9a-fA-F]{40}$') {
                    Fail 'POST_MERGE_FAILED: invalid_base_sha' 1
                }
                $basePmRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--verify', '--quiet', "${basePmTrim}^{commit}")
                $resBasePm = $basePmRes.StdOut.Trim()
                if ($basePmRes.ExitCode -ne 0 -or $resBasePm -cnotmatch '^[0-9a-f]{40}$') {
                    Fail 'POST_MERGE_FAILED: invalid_base_sha' 1
                }
                if ($resBasePm -ceq $resMerged) { Fail 'POST_MERGE_FAILED: base_sha_equals_merged_sha' 1 }
                if ($resBasePm -ceq $resHeadPm) { Fail 'POST_MERGE_FAILED: base_sha_equals_head' 1 }
                $ancBm = Invoke-GitCommand $RepoRoot @('merge-base', '--is-ancestor', $resBasePm, $resMerged)
                if ($ancBm.ExitCode -ne 0) { Fail 'POST_MERGE_FAILED: base_not_ancestor_of_merged' 1 }
                $ancBh = Invoke-GitCommand $RepoRoot @('merge-base', '--is-ancestor', $resBasePm, $resHeadPm)
                if ($ancBh.ExitCode -ne 0) { Fail 'POST_MERGE_FAILED: base_not_ancestor_of_head' 1 }
            }

            $remListPm = Invoke-GitCommand $RepoRoot @('remote')
            $remotesPm = @()
            if ($remListPm.ExitCode -eq 0 -and $remListPm.StdOut) {
                $remotesPm = @($remListPm.StdOut -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            }
            $hasOriginPm = ($remotesPm -ccontains 'origin')
            if ((-not $LocalOnly) -and ($remotesPm.Count -gt 0) -and (-not $hasOriginPm)) {
                Fail 'POST_MERGE_FAILED: origin_remote_missing' 1
            }

            # Resolve canonical trunk branch & policy to prevent unmerged feature self-targeting
            $pmTrunk = Get-CanonicalTrunkAuthority $RepoRoot $hasOriginPm $true
            $pmTrunkSha = $pmTrunk.Sha
            $pmTrunkBranch = $pmTrunk.Branch
            $pmAllowedBranches = @()
            if ($pmTrunkSha) {
                $pmPolLs = Invoke-GitCommand $RepoRoot @('ls-tree', $pmTrunkSha, '--', '.b3/research-policy.json')
                $pmPolLine = $pmPolLs.StdOut.Trim()
                if ($pmPolLs.ExitCode -eq 0 -and $pmPolLine -cmatch "^(100644|100755) blob ([0-9a-f]{40})`t\.b3/research-policy\.json$") {
                    $pmPolShow = Invoke-GitCommand $RepoRoot @('show', "${pmTrunkSha}:.b3/research-policy.json")
                    if ($pmPolShow.ExitCode -eq 0) {
                        $polCallPm = Invoke-CapturedGuardCall {
                            $polObj = Parse-MergePolicyJsonText $pmPolShow.StdOut
                            return @($polObj.AllowedTargetBranches)
                        }
                        if (-not $polCallPm.Ok) {
                            if ($polCallPm.Message -match '^MERGE_BLOCKED: (.+)$') {
                                Fail "POST_MERGE_FAILED: $($Matches[1])" 1
                            }
                            Fail 'POST_MERGE_FAILED: invalid_policy_json' 1
                        }
                        $pmAllowedBranches = @($polCallPm.Result)
                    }
                }
            }
            if ($pmAllowedBranches.Count -gt 0) {
                if (-not (Test-BranchPatternMatch $localTargetBranch $pmAllowedBranches)) {
                    Fail "POST_MERGE_FAILED: target_branch_not_allowed($localTargetBranch)" 1
                }
            } elseif ($pmTrunkBranch) {
                if ($localTargetBranch -cne $pmTrunkBranch) {
                    Fail "POST_MERGE_FAILED: target_branch_not_allowed($localTargetBranch)" 1
                }
            } else {
                Fail 'POST_MERGE_FAILED: canonical_trunk_missing' 1
            }

            $ancRes = Invoke-GitCommand $RepoRoot @('merge-base', '--is-ancestor', $resMerged, $resMain)
            if ($ancRes.ExitCode -ne 0) {
                Fail "POST_MERGE_FAILED: sha_not_in_target(sha=$resMerged,target_ref=$localTargetBranch,main_ref=$mRef)" 1
            }
            if ($hasOriginPm -and (-not $LocalOnly)) {
                $remTargetRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--verify', '--quiet', "refs/remotes/origin/${localTargetBranch}^{commit}")
                $remTargetSha = $remTargetRes.StdOut.Trim()
                if ($remTargetRes.ExitCode -ne 0 -or $remTargetSha -cnotmatch '^[0-9a-f]{40}$') {
                    Fail 'POST_MERGE_FAILED: remote_target_not_fetched' 1
                }
                $pmTgtRef = "refs/heads/${localTargetBranch}"
                $pmQueryRefs = New-Object System.Collections.Generic.List[string]
                [void]$pmQueryRefs.Add($pmTgtRef)
                $pmAuthRef = if ($pmTrunkBranch -and $pmTrunkBranch -cne $localTargetBranch) { "refs/heads/${pmTrunkBranch}" } else { '' }
                if ($pmAuthRef) { [void]$pmQueryRefs.Add($pmAuthRef) }
                $pmLsBatch = Invoke-GitLsRemoteRefs $RepoRoot $pmQueryRefs.ToArray()
                if ($pmLsBatch.Status -ceq 'UNREACHABLE') {
                    Fail 'PROVIDER_UNAVAILABLE: post_merge_remote_unverifiable' 2
                }
                if (-not $pmLsBatch.Refs.ContainsKey($pmTgtRef)) {
                    Fail 'POST_MERGE_FAILED: remote_target_ref_missing' 1
                }
                $pmLiveTargetSha = $pmLsBatch.Refs[$pmTgtRef]
                if ($pmLiveTargetSha -cne $remTargetSha) {
                    Fail "POST_MERGE_FAILED: stale_remote_target_ref(local=$remTargetSha remote=$pmLiveTargetSha)" 1
                }
                if ($pmTrunkBranch) {
                    if ($pmAuthRef) {
                        if (-not $pmLsBatch.Refs.ContainsKey($pmAuthRef)) {
                            Fail 'POST_MERGE_FAILED: remote_authority_ref_missing' 1
                        }
                        if ($pmLsBatch.Refs[$pmAuthRef] -cne $pmTrunkSha) {
                            Fail "POST_MERGE_FAILED: stale_remote_authority_ref(local=$pmTrunkSha remote=$($pmLsBatch.Refs[$pmAuthRef]))" 1
                        }
                    } elseif ($pmLiveTargetSha -cne $pmTrunkSha) {
                        Fail "POST_MERGE_FAILED: stale_remote_authority_ref(local=$pmTrunkSha remote=$pmLiveTargetSha)" 1
                    }
                }
                $ancRemRes = Invoke-GitCommand $RepoRoot @('merge-base', '--is-ancestor', $resMerged, $remTargetSha)
                if ($ancRemRes.ExitCode -ne 0) {
                    Fail "POST_MERGE_FAILED: merge_commit_not_in_remote_target(target_ref=$localTargetBranch)" 1
                }
            }

            $parRes = Invoke-GitCommand $RepoRoot @('rev-list', '--parents', '-n', '1', $resMerged)
            if ($parRes.ExitCode -ne 0) { Fail 'POST_MERGE_FAILED: unresolvable_commit' 1 }
            $parToks = @($parRes.StdOut.Trim() -split '\s+' | Where-Object { $_ })
            $parCnt = $parToks.Count - 1
            $mergeKind = ''
            if ($resMerged -ceq $resHeadPm) {
                $mergeKind = 'fast_forward'
            } elseif ($parCnt -ge 2) {
                $inFirstPar = (Invoke-GitCommand $RepoRoot @('merge-base', '--is-ancestor', $resHeadPm, $parToks[1])).ExitCode -eq 0
                $inMergedPar = $false
                for ($pIdx = 2; $pIdx -lt $parToks.Count; $pIdx++) {
                    if ((Invoke-GitCommand $RepoRoot @('merge-base', '--is-ancestor', $resHeadPm, $parToks[$pIdx])).ExitCode -eq 0) {
                        $inMergedPar = $true
                        break
                    }
                }
                if (-not $inMergedPar -or $inFirstPar) {
                    Fail 'POST_MERGE_FAILED: merge_commit_head_mismatch' 1
                }
                $mergeKind = 'merge_commit'
            } elseif ($parCnt -eq 1) {
                if (-not $resBasePm) {
                    Fail 'POST_MERGE_FAILED: squash_or_rebase_requires_base_sha' 1
                }
                $p1Sha = $parToks[1]
                if ((Invoke-GitCommand $RepoRoot @('merge-base', '--is-ancestor', $resBasePm, $p1Sha)).ExitCode -ne 0) {
                    Fail 'POST_MERGE_FAILED: base_not_ancestor_of_merged_parent' 1
                }
                $mTreeRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--verify', '--quiet', "${resMerged}^{tree}")
                $hTreeRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--verify', '--quiet', "${resHeadPm}^{tree}")
                $mTree = $mTreeRes.StdOut.Trim()
                $hTree = $hTreeRes.StdOut.Trim()
                $treeOk = ($mTree -cmatch '^[0-9a-f]{40}$') -and (($p1Sha -ceq $resBasePm -and $mTree -ceq $hTree))
                if (-not $treeOk -and ($mTree -cmatch '^[0-9a-f]{40}$')) {
                    $mtRes = Invoke-GitCommand $RepoRoot @('merge-tree', '--write-tree', $p1Sha, $resHeadPm)
                    if ($mtRes.ExitCode -eq 0) {
                        $mtLine = (@($mtRes.StdOut -split "\r?\n")[0]).Trim()
                        if ($mtLine -ceq $mTree) { $treeOk = $true }
                    }
                }
                if (-not $treeOk) {
                    Fail 'POST_MERGE_FAILED: squash_tree_mismatch' 1
                }
                $mergeKind = 'squash_or_rebase'
            } else {
                Fail 'POST_MERGE_FAILED: merge_commit_head_mismatch' 1
            }

            Write-Output "POST_MERGE_VERIFIED: mode=local sha=$resMerged target_ref=$localTargetBranch main_ref=$mRef merge_kind=$mergeKind runtime_served=NOT_VERIFIED deployed=NOT_VERIFIED"
            exit 0
        }

        # --- Unified Provider-Neutral Pre-Merge Pipeline ---
        $mpCaseInsensitive = Test-RepoCaseInsensitive $RepoRoot
        $dotB3Raw = Join-Path $RepoRoot '.b3'
        if (Test-IsReparsePath $dotB3Raw) {
            Fail 'MERGE_BLOCKED: invalid_policy_path' 1
        }
        $defPolRaw = Join-Path $RepoRoot '.b3\research-policy.json'
        $defPolItem = Get-Item -LiteralPath $defPolRaw -Force -ErrorAction SilentlyContinue
        $defPolFileFull = $null
        if ($null -ne $defPolItem -or (Test-Path -LiteralPath $defPolRaw)) {
            $defSpec = Test-ContainedRepoPath $RepoRoot '.b3/research-policy.json'
            if (-not $defSpec -or (-not (Test-Path -LiteralPath $defSpec.Full -PathType Leaf)) -or (Test-IsReparsePath $defSpec.Full)) {
                Fail 'MERGE_BLOCKED: invalid_policy_path' 1
            }
            $defPolFileFull = $defSpec.Full
        }

        $polExplicit = [bool]($PolicyPath -and $PolicyPath.Trim())
        $polFileFull = $null
        $polRel = ''
        if ($polExplicit) {
            $pSpec = Test-ContainedRepoPath $RepoRoot $PolicyPath
            if (-not $pSpec) { Fail 'MERGE_BLOCKED: invalid_policy_path' 1 }
            if (-not (Test-Path -LiteralPath $pSpec.Full -PathType Leaf)) { Fail 'MERGE_BLOCKED: missing_policy' 1 }
            $polFileFull = $pSpec.Full
            $polRel = $pSpec.Rel
        }

        $changedList = New-Object System.Collections.Generic.List[string]
        if ($ChangedPaths -and $ChangedPaths.Trim()) {
            $rawCp = $ChangedPaths
            $trimCp = $ChangedPaths.Trim()
            if ($trimCp -cne '[]' -and $trimCp -cne 'none') {
                if ($trimCp.StartsWith('[') -and $trimCp.EndsWith(']')) {
                    $rawCp = $trimCp.Substring(1, $trimCp.Length - 2)
                }
                foreach ($part in ($rawCp -split ',')) {
                    if ([string]::IsNullOrEmpty($part)) { Fail 'MERGE_BLOCKED: invalid_changed_path' 1 }
                    $tok = $part -replace '\\', '/'
                    if ($tok -ceq './') { $tok = '.' }
                    if ($tok -cne '.' -and -not (Test-ValidLiteralGitPath $tok)) {
                        $trimmedTok = $tok.TrimStart(' ')
                        if (Test-ValidLiteralGitPath $trimmedTok) { $tok = $trimmedTok }
                        else { Fail 'MERGE_BLOCKED: invalid_changed_path' 1 }
                    }
                    if (-not $changedList.Contains($tok)) { $changedList.Add($tok) }
                }
            }
        }
        $changedArr = @($changedList)

        if ($effTargetRefArg) {
            if ($effTargetRefArg.StartsWith('-') -or ($effTargetRefArg -match '[\s\x00-\x1F\x7F]') -or ($effTargetRefArg -imatch '^(HEAD([~^].*)?|@([~^{].*)?)$')) {
                Fail 'MERGE_BLOCKED: invalid_target_ref' 1
            }
        }
        if ($authRefArgTrim) {
            if ($authRefArgTrim.StartsWith('-') -or ($authRefArgTrim -match '[\s\x00-\x1F\x7F]') -or ($authRefArgTrim -imatch '^(HEAD([~^].*)?|@([~^{].*)?)$')) {
                Fail 'MERGE_BLOCKED: invalid_authority_ref' 1
            }
        }

        $headPreRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--verify', '--quiet', 'HEAD^{commit}')
        $liveHeadSha = if ($headPreRes.ExitCode -eq 0 -and $headPreRes.StdOut.Trim() -cmatch '^[0-9a-f]{40}$') { $headPreRes.StdOut.Trim() } else { '' }
        if ($headShaArgTrim) {
            if ($headShaArgTrim.StartsWith('-')) { Fail 'MERGE_BLOCKED: invalid_head' 1 }
            $callerHeadRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--verify', '--quiet', "${headShaArgTrim}^{commit}")
            $callerHeadSha = $callerHeadRes.StdOut.Trim()
            if ($callerHeadRes.ExitCode -ne 0 -or $callerHeadSha -cnotmatch '^[0-9a-f]{40}$' -or -not $liveHeadSha) {
                Fail 'MERGE_BLOCKED: invalid_head' 1
            }
            if ($callerHeadSha -cne $liveHeadSha) {
                Fail 'MERGE_BLOCKED: head_sha_mismatch' 1
            }
        }

        $remListRes = Invoke-GitCommand $RepoRoot @('remote')
        $remotesList = @()
        if ($remListRes.ExitCode -eq 0 -and $remListRes.StdOut) {
            $remotesList = @($remListRes.StdOut -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
        $hasAnyRemote = ($remotesList.Count -gt 0)
        $hasOrigin = ($remotesList -ccontains 'origin')

        $curSymRes = Invoke-GitCommand $RepoRoot @('symbolic-ref', '-q', 'HEAD')
        $curSymFull = if ($curSymRes.ExitCode -eq 0) { $curSymRes.StdOut.Trim() } else { '' }

        $canonTrunk = Get-CanonicalTrunkAuthority $RepoRoot $hasOrigin (-not $hasAnyRemote)
        $canonAuthFull = $canonTrunk.SymFull
        $canonAuthBranch = $canonTrunk.Branch
        $canonAuthSha = $canonTrunk.Sha

        $callerAuthSymFull = ''
        $callerAuthBranch = ''
        if ($authRefArgTrim) {
            $aSymRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--symbolic-full-name', $authRefArgTrim)
            $callerAuthSymFull = $aSymRes.StdOut.Trim()
            if ($aSymRes.ExitCode -ne 0 -or (-not ($callerAuthSymFull.StartsWith('refs/heads/', [System.StringComparison]::Ordinal) -or $callerAuthSymFull.StartsWith('refs/remotes/', [System.StringComparison]::Ordinal)))) {
                Fail 'MERGE_BLOCKED: invalid_authority_ref' 1
            }
            if ($curSymFull -and ($callerAuthSymFull -ceq $curSymFull)) {
                Fail 'MERGE_BLOCKED: invalid_authority_ref' 1
            }
            if ($callerAuthSymFull.StartsWith('refs/heads/', [System.StringComparison]::Ordinal)) {
                $callerAuthBranch = $callerAuthSymFull.Substring('refs/heads/'.Length)
            } elseif ($callerAuthSymFull -cmatch '^refs/remotes/[^/]+/(.+)$') {
                $callerAuthBranch = $Matches[1]
            }
            if ($canonAuthFull -and ($callerAuthSymFull -cne $canonAuthFull)) {
                Fail 'MERGE_BLOCKED: authority_ref_mismatch' 1
            }
        }

        $effectivePolRel = if ($polRel) { $polRel } else { '.b3/research-policy.json' }
        $polIsDefaultPath = (-not $polExplicit) -or $effectivePolRel.Equals('.b3/research-policy.json', [System.StringComparison]::OrdinalIgnoreCase)
        $policyProtected = New-Object System.Collections.Generic.List[string]
        $policyProtected.Add('.b3/research-policy.json')
        if (-not $polIsDefaultPath) {
            $policyProtected.Add($effectivePolRel)
        }
        $policyProtectedArr = @($policyProtected)

        # Default policy if absent from authority
        $autoMerge = 'disabled'
        $polProtectedPaths = @()
        $allowProtected = $false
        $requireCi = $false
        $requireReview = $true
        $allowedTargetBranches = @()

        $fallbackLocalTrunkSha = ''
        if (-not $canonAuthSha -and -not $hasAnyRemote) {
            foreach ($candBr in @('main', 'master')) {
                $fbRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--verify', '--quiet', "refs/heads/${candBr}^{commit}")
                if ($fbRes.ExitCode -eq 0 -and $fbRes.StdOut.Trim() -cmatch '^[0-9a-f]{40}$') {
                    $fallbackLocalTrunkSha = $fbRes.StdOut.Trim()
                    break
                }
            }
        }
        $inspectAuthSha = if ($canonAuthSha) { $canonAuthSha } else { $fallbackLocalTrunkSha }
        $isGithubPrMode = ([bool]$prNumTrim -and (-not $LocalOnly))
        if ((-not $isGithubPrMode) -and (-not $LocalOnly) -and $hasAnyRemote -and (-not $hasOrigin)) {
            Fail 'MERGE_BLOCKED: origin_remote_missing' 1
        }

        if (-not $polIsDefaultPath) {
            $polParsed = Parse-MergePolicyJsonText ([IO.File]::ReadAllText($polFileFull))
            $autoMerge = $polParsed.AutoMerge
            $allowProtected = $polParsed.AllowProtected
            $requireCi = $polParsed.RequireCi
            $requireReview = $polParsed.RequireReview
            $polProtectedPaths = $polParsed.ProtectedPaths
            $allowedTargetBranches = $polParsed.AllowedTargetBranches
            if ((-not $isGithubPrMode) -and $inspectAuthSha) {
                $tLs = Invoke-GitCommand $RepoRoot @('ls-tree', $inspectAuthSha, '--', '.b3/research-policy.json')
                if ($tLs.ExitCode -eq 0 -and $tLs.StdOut.Trim() -cmatch "^(100644|100755) blob ([0-9a-f]{40})`t\.b3/research-policy\.json$") {
                    $tShow = Invoke-GitCommand $RepoRoot @('show', "${inspectAuthSha}:.b3/research-policy.json")
                    if ($tShow.ExitCode -eq 0) {
                        $trunkPol = Parse-MergePolicyJsonText $tShow.StdOut
                        $requireCi = ($requireCi -or $trunkPol.RequireCi)
                        $requireReview = ($requireReview -or $trunkPol.RequireReview)
                        if ($trunkPol.ProtectedPaths.Count -gt 0) {
                            $mergedPp = New-Object System.Collections.Generic.List[string]
                            foreach ($pp in @($polProtectedPaths)) { if (-not $mergedPp.Contains($pp)) { $mergedPp.Add($pp) } }
                            foreach ($pp in @($trunkPol.ProtectedPaths)) { if (-not $mergedPp.Contains($pp)) { $mergedPp.Add($pp) } }
                            $polProtectedPaths = @($mergedPp)
                            if (-not $trunkPol.AllowProtected) { $allowProtected = $false }
                        }
                    }
                }
            }
        } elseif (-not $isGithubPrMode) {
            $authHasCommittedPol = $false
            if ($inspectAuthSha) {
                $aLs = Invoke-GitCommand $RepoRoot @('ls-tree', $inspectAuthSha, '--', '.b3/research-policy.json')
                $aLsLine = $aLs.StdOut.Trim()
                if ($aLs.ExitCode -eq 0 -and $aLsLine -cmatch "^(100644|100755) blob ([0-9a-f]{40})`t\.b3/research-policy\.json$") {
                    $authHasCommittedPol = $true
                    $aShow = Invoke-GitCommand $RepoRoot @('show', "${inspectAuthSha}:.b3/research-policy.json")
                    if ($aShow.ExitCode -ne 0) { Fail 'MERGE_BLOCKED: policy_not_in_authority' 1 }
                    $polParsed = Parse-MergePolicyJsonText $aShow.StdOut
                    $autoMerge = $polParsed.AutoMerge
                    $allowProtected = $polParsed.AllowProtected
                    $requireCi = $polParsed.RequireCi
                    $requireReview = $polParsed.RequireReview
                    $polProtectedPaths = $polParsed.ProtectedPaths
                    $allowedTargetBranches = $polParsed.AllowedTargetBranches
                }
            }
            if ($authHasCommittedPol) {
                if ($inspectAuthSha -and $liveHeadSha -and ($inspectAuthSha -cne $liveHeadSha)) {
                    $mbInsp = Invoke-GitCommand $RepoRoot @('merge-base', $inspectAuthSha, $liveHeadSha)
                    if ($mbInsp.ExitCode -eq 0 -and $mbInsp.StdOut.Trim() -cmatch '^[0-9a-f]{40}$') {
                        $crPolPaths = @(Invoke-GitPathsZ $RepoRoot @('diff', '--no-ext-diff', '--name-status', '-z', "$($mbInsp.StdOut.Trim())..${liveHeadSha}", '--', '.b3/research-policy.json') 'name-status-z' 'MERGE_BLOCKED')
                        if ($crPolPaths.Count -gt 0) {
                            Fail 'MERGE_BLOCKED: policy_modified_in_pr' 1
                        }
                    } elseif ($mbInsp.ExitCode -gt 1) {
                        Fail 'MERGE_BLOCKED: git_diff_failed' 1
                    }
                }
                foreach ($dArgsPol in @(
                    @('diff', '--no-ext-diff', '--cached', '--name-status', '-z', '--', '.b3/research-policy.json'),
                    @('diff', '--no-ext-diff', '--name-status', '-z', '--', '.b3/research-policy.json'),
                    @('diff', '--no-ext-diff', '--name-status', '-z', 'HEAD', '--', '.b3/research-policy.json')
                )) {
                    $dPolPaths = @(Invoke-GitPathsZ $RepoRoot $dArgsPol 'name-status-z' 'MERGE_BLOCKED')
                    if ($dPolPaths.Count -gt 0) {
                        Fail 'MERGE_BLOCKED: policy_modified_in_pr' 1
                    }
                }
            } else {
                if ($inspectAuthSha -and $liveHeadSha -and ($inspectAuthSha -cne $liveHeadSha)) {
                    $mbInsp = Invoke-GitCommand $RepoRoot @('merge-base', $inspectAuthSha, $liveHeadSha)
                    if ($mbInsp.ExitCode -eq 0 -and $mbInsp.StdOut.Trim() -cmatch '^[0-9a-f]{40}$') {
                        $crPolPaths = @(Invoke-GitPathsZ $RepoRoot @('diff', '--no-ext-diff', '--name-status', '-z', "$($mbInsp.StdOut.Trim())..${liveHeadSha}", '--', '.b3/research-policy.json') 'name-status-z' 'MERGE_BLOCKED')
                        if ($crPolPaths.Count -gt 0) {
                            Fail 'MERGE_BLOCKED: policy_not_in_authority' 1
                        }
                    } elseif ($mbInsp.ExitCode -gt 1) {
                        Fail 'MERGE_BLOCKED: git_diff_failed' 1
                    }
                    if ($defPolFileFull) {
                        Fail 'MERGE_BLOCKED: policy_not_in_authority' 1
                    }
                } elseif ($defPolFileFull) {
                    $wtPol = Parse-MergePolicyJsonText ([IO.File]::ReadAllText($defPolFileFull))
                    if ($wtPol.AutoMerge -ceq 'authorized') {
                        Fail 'MERGE_BLOCKED: policy_not_in_authority' 1
                    }
                    $autoMerge = 'disabled'
                    $allowProtected = [bool]$wtPol.AllowProtected
                    $requireCi = [bool]$wtPol.RequireCi
                    $requireReview = $true
                    $polProtectedPaths = $wtPol.ProtectedPaths
                    $allowedTargetBranches = $wtPol.AllowedTargetBranches
                }
            }
        }

        if ($govSt -cne 'CLEAR') { Fail "MERGE_BLOCKED: governance=$govSt" 1 }

        $localPreChanged = New-Object System.Collections.Generic.List[string]
        foreach ($cp in $changedArr) {
            if (-not $localPreChanged.Contains($cp)) { $localPreChanged.Add($cp) }
        }
        if ((-not $isGithubPrMode) -and $inspectAuthSha -and $liveHeadSha -and ($inspectAuthSha -cne $liveHeadSha)) {
            $mbChg = Invoke-GitCommand $RepoRoot @('merge-base', $inspectAuthSha, $liveHeadSha)
            if ($mbChg.ExitCode -eq 0 -and $mbChg.StdOut.Trim() -cmatch '^[0-9a-f]{40}$') {
                $locDiffPaths = @(Invoke-GitPathsZ $RepoRoot @('diff', '--no-ext-diff', '--name-status', '-z', "$($mbChg.StdOut.Trim())..${liveHeadSha}", '--') 'name-status-z' 'MERGE_BLOCKED')
                foreach ($lp in $locDiffPaths) {
                    if ($lp -and (-not (Test-CheckpointPath $lp)) -and (-not $localPreChanged.Contains($lp))) {
                        $localPreChanged.Add($lp)
                    }
                }
            } elseif ($mbChg.ExitCode -gt 1) {
                Fail 'MERGE_BLOCKED: git_diff_failed' 1
            }
        }
        $localPreChangedArr = @($localPreChanged)

        if ($polProtectedPaths.Count -gt 0 -and -not $allowProtected -and $localPreChangedArr.Count -gt 0) {
            $protHits = New-Object System.Collections.Generic.List[string]
            foreach ($cp in $localPreChangedArr) {
                if (Test-ProtectedPathMatchCI $cp $polProtectedPaths $mpCaseInsensitive) {
                    if (-not $protHits.Contains($cp)) { $protHits.Add($cp) }
                }
            }
            if ($protHits.Count -gt 0) {
                Fail ("MERGE_BLOCKED: protected_paths=" + ((Sort-Ordinal $protHits.ToArray()) -join ',')) 1
            }
        }
        if ($changedArr.Count -gt 0) {
            foreach ($cp in $changedArr) {
                if (Test-ProtectedPathMatchCI $cp $policyProtectedArr $mpCaseInsensitive) {
                    Fail 'MERGE_BLOCKED: policy_modified_in_pr' 1
                }
            }
        }

        if ($BlockingFindings -gt 0) { Fail "MERGE_BLOCKED: blocking_findings=$BlockingFindings" 1 }

        # Caller-supplied negative signals always tighten (can block, never authorize)
        if ($ciStatusExplicit -and $ciSt -cin @('FAIL', 'PENDING')) { Fail "MERGE_BLOCKED: ci_status=$ciSt" 1 }
        if ($revStatusExplicit -and $revSt -cin @('BLOCKED', 'PENDING')) { Fail "MERGE_BLOCKED: review_status=$revSt" 1 }
        if ($prStateExplicit -and $prSt -cin @('CLOSED', 'MERGED')) { Fail "MERGE_BLOCKED: pr_state=$prSt" 1 }

        if (-not $polIsDefaultPath) {
            if ($isGithubPrMode -or $autoMerge -ceq 'authorized' -or ($inspectAuthSha -and $liveHeadSha -and ($inspectAuthSha -cne $liveHeadSha))) {
                Fail 'MERGE_BLOCKED: policy_path_override_not_allowed' 1
            }
        }

        # --- GitHub PR Authorization Path (when -PrNumber is supplied and !-LocalOnly) ---
        if ($isGithubPrMode) {
            if ($prNumTrim -cnotmatch '^[1-9][0-9]*$') {
                Fail 'MERGE_BLOCKED: invalid_pr_number' 1
            }
            $gh = Invoke-B3GitHubVerify 'pre-merge' $RepoRoot $Repo $prNumTrim 'MERGE_BLOCKED'

            if ($gh['pr_number'] -cne $prNumTrim) { Fail 'MERGE_BLOCKED: pr_identity_mismatch' 1 }
            if ($Repo -and $Repo.Trim() -and (-not $gh['base_repo'].Equals($Repo.Trim(), [System.StringComparison]::OrdinalIgnoreCase))) {
                Fail 'MERGE_BLOCKED: cross_repo_mismatch' 1
            }
            if ($gh['same_repo'] -cne 'true') { Fail 'MERGE_BLOCKED: cross_repo_head_pr' 1 }
            if ($gh['pr_state'] -cne 'OPEN' -or $gh['pr_merged'] -ceq 'true') { Fail "MERGE_BLOCKED: pr_state=$($gh['pr_state'])" 1 }
            if ($gh['pr_draft'] -ceq 'true') { Fail 'MERGE_BLOCKED: pr_is_draft' 1 }

            $ghBaseRef = $gh['base_ref']
            $ghPrBaseSha = $gh['pr_base_sha']
            $ghLiveTargetSha = $gh['live_target_sha']
            $ghHeadSha = $gh['head_sha']
            $ghAuthRef = $gh['policy_authority_ref']
            $ghAuthSha = $gh['policy_authority_sha']
            if (-not $ghBaseRef -or -not $ghAuthRef -or
                $ghPrBaseSha -cnotmatch '^[0-9a-f]{40}$' -or
                $ghLiveTargetSha -cnotmatch '^[0-9a-f]{40}$' -or
                $ghHeadSha -cnotmatch '^[0-9a-f]{40}$' -or
                $ghAuthSha -cnotmatch '^[0-9a-f]{40}$') {
                Fail 'MERGE_BLOCKED: incomplete_pr_metadata' 1
            }

            if ($ghLiveTargetSha -cne $ghPrBaseSha) {
                Fail 'MERGE_BLOCKED: target_branch_moved' 1
            }
            if ($targetBrTrim -and $targetBrTrim -cne $ghBaseRef) {
                Fail 'MERGE_BLOCKED: target_ref_mismatch' 1
            }
            if ($effTargetRefArg) {
                $tSymGhRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--symbolic-full-name', $effTargetRefArg)
                $tSymGh = $tSymGhRes.StdOut.Trim()
                $tBrGh = ''
                if ($tSymGhRes.ExitCode -eq 0) {
                    if ($tSymGh.StartsWith('refs/heads/', [System.StringComparison]::Ordinal)) {
                        $tBrGh = $tSymGh.Substring('refs/heads/'.Length)
                    } elseif ($tSymGh -cmatch '^refs/remotes/origin/(.+)$') {
                        $tBrGh = $Matches[1]
                    }
                }
                if (-not $tBrGh -or $tBrGh -cne $ghBaseRef) {
                    Fail 'MERGE_BLOCKED: target_ref_mismatch' 1
                }
            }
            if ($callerAuthBranch -and $callerAuthBranch -cne $ghAuthRef) {
                Fail 'MERGE_BLOCKED: authority_ref_mismatch' 1
            }

            $baseTrim = if ($BaseSha) { $BaseSha.Trim() } else { '' }
            if ($baseTrim) {
                if ($baseTrim.StartsWith('-')) { Fail 'MERGE_BLOCKED: invalid_base_sha' 1 }
                $baseRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--verify', '--quiet', "${baseTrim}^{commit}")
                $callerBaseSha = $baseRes.StdOut.Trim()
                if ($baseRes.ExitCode -ne 0 -or $callerBaseSha -cnotmatch '^[0-9a-f]{40}$') {
                    Fail 'MERGE_BLOCKED: invalid_base_sha' 1
                }
                if ($callerBaseSha -cne $ghLiveTargetSha) {
                    if ($liveHeadSha -and $callerBaseSha -ceq $liveHeadSha) {
                        Fail 'MERGE_BLOCKED: base_sha_equals_head' 1
                    }
                    Fail 'MERGE_BLOCKED: base_sha_mismatch' 1
                }
            }
            $resolvedBaseSha = $ghLiveTargetSha

            if (-not $liveHeadSha) {
                Fail 'MERGE_BLOCKED: invalid_head' 1
            }
            if ($liveHeadSha -cne $ghHeadSha) {
                Fail 'MERGE_BLOCKED: head_sha_mismatch' 1
            }
            if ($resolvedBaseSha -ceq $liveHeadSha) {
                Fail 'MERGE_BLOCKED: base_sha_equals_head' 1
            }

            $tLocalRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--verify', '--quiet', "${resolvedBaseSha}^{commit}")
            if ($tLocalRes.ExitCode -ne 0 -or $tLocalRes.StdOut.Trim() -cne $resolvedBaseSha) {
                Fail 'MERGE_BLOCKED: target_sha_not_fetched' 1
            }
            $aLocalRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--verify', '--quiet', "${ghAuthSha}^{commit}")
            if ($aLocalRes.ExitCode -ne 0 -or $aLocalRes.StdOut.Trim() -cne $ghAuthSha) {
                Fail 'MERGE_BLOCKED: policy_authority_not_fetched' 1
            }

            $remTrackRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--verify', '--quiet', "refs/remotes/origin/${ghBaseRef}^{commit}")
            if ($remTrackRes.ExitCode -eq 0) {
                $remTrackSha = $remTrackRes.StdOut.Trim()
                if ($remTrackSha -cmatch '^[0-9a-f]{40}$' -and $remTrackSha -cne $resolvedBaseSha) {
                    Fail 'MERGE_BLOCKED: target_branch_moved' 1
                }
            }
            $ancTargetRes = Invoke-GitCommand $RepoRoot @('merge-base', '--is-ancestor', $resolvedBaseSha, $liveHeadSha)
            if ($ancTargetRes.ExitCode -ne 0) {
                Fail 'MERGE_BLOCKED: target_branch_moved' 1
            }

            $authLs = Invoke-GitCommand $RepoRoot @('ls-tree', $ghAuthSha, '--', '.b3/research-policy.json')
            $authLsLine = $authLs.StdOut.Trim()
            $authHasPolicy = ($authLs.ExitCode -eq 0 -and $authLsLine -cmatch "^(100644|100755) blob ([0-9a-f]{40})`t\.b3/research-policy\.json$")
            $authPol = $null
            if ($authHasPolicy) {
                $authShow = Invoke-GitCommand $RepoRoot @('show', "${ghAuthSha}:.b3/research-policy.json")
                if ($authShow.ExitCode -ne 0) { Fail 'MERGE_BLOCKED: policy_not_in_authority' 1 }
                $authPol = Parse-MergePolicyJsonText $authShow.StdOut
            } else {
                if ($polExplicit -or $defPolFileFull) {
                    Fail 'MERGE_BLOCKED: policy_not_in_authority' 1
                }
                $authPol = @{
                    AutoMerge = 'disabled'
                    AllowProtected = $false
                    RequireCi = $false
                    RequireReview = $true
                    ProtectedPaths = @()
                    AllowedTargetBranches = @()
                }
            }
            $ghPolViolationReason = if ($authHasPolicy) { 'policy_modified_in_pr' } else { 'policy_not_in_authority' }

            if ($ghBaseRef -cne $ghAuthRef) {
                $mbAuthRes = Invoke-GitCommand $RepoRoot @('merge-base', $ghAuthSha, $resolvedBaseSha)
                $mbAuthSha = $mbAuthRes.StdOut.Trim()
                if ($mbAuthRes.ExitCode -ne 0 -or $mbAuthSha -cnotmatch '^[0-9a-f]{40}$') {
                    Fail 'MERGE_BLOCKED: target_branch_unrelated_to_authority' 1
                }
                $tPolPaths = @(Invoke-GitPathsZ $RepoRoot @('diff', '--no-ext-diff', '--name-status', '-z', "${mbAuthSha}..${resolvedBaseSha}", '--') 'name-status-z' 'MERGE_BLOCKED')
                foreach ($tp in $tPolPaths) {
                    if (-not $tp) { continue }
                    if (Test-ProtectedPathMatchCI $tp $policyProtectedArr $mpCaseInsensitive) {
                        Fail 'MERGE_BLOCKED: target_branch_modified_policy' 1
                    }
                }
            }

            Assert-MergeDirtyWorktreeClean $RepoRoot $policyProtectedArr $mpCaseInsensitive $ghPolViolationReason

            $allChanged = New-Object System.Collections.Generic.List[string]
            foreach ($cp in $changedArr) {
                if (-not $allChanged.Contains($cp)) { $allChanged.Add($cp) }
            }
            foreach ($ghf in @($gh['PrChangedFiles'])) {
                if (-not (Test-ValidLiteralGitPath $ghf)) { Fail 'MERGE_BLOCKED: invalid_pr_changed_path' 1 }
                if (-not $allChanged.Contains($ghf)) { $allChanged.Add($ghf) }
            }
            $cDiffPaths = @(Invoke-GitPathsZ $RepoRoot @('diff', '--no-ext-diff', '--name-status', '-z', "${resolvedBaseSha}..${liveHeadSha}", '--') 'name-status-z' 'MERGE_BLOCKED')
            foreach ($gp in $cDiffPaths) {
                if (-not $gp) { continue }
                if (Test-CheckpointPath $gp) { continue }
                if (-not $allChanged.Contains($gp)) { $allChanged.Add($gp) }
            }
            $allChangedArr = @($allChanged)

            foreach ($cp in $allChangedArr) {
                if (Test-ProtectedPathMatchCI $cp $policyProtectedArr $mpCaseInsensitive) {
                    Fail "MERGE_BLOCKED: $ghPolViolationReason" 1
                }
            }
            if ($authPol.ProtectedPaths.Count -gt 0 -and -not $authPol.AllowProtected) {
                if ($allChangedArr.Count -eq 0) { Fail 'MERGE_BLOCKED: missing_changed_paths' 1 }
                $protHits = New-Object System.Collections.Generic.List[string]
                foreach ($cp in $allChangedArr) {
                    if (Test-ProtectedPathMatchCI $cp $authPol.ProtectedPaths $mpCaseInsensitive) {
                        if (-not $protHits.Contains($cp)) { $protHits.Add($cp) }
                    }
                }
                if ($protHits.Count -gt 0) {
                    Fail ("MERGE_BLOCKED: protected_paths=" + ((Sort-Ordinal $protHits.ToArray()) -join ',')) 1
                }
            }

            if ($authPol.AllowedTargetBranches.Count -gt 0) {
                if (-not (Test-BranchPatternMatch $ghBaseRef $authPol.AllowedTargetBranches)) {
                    Fail "MERGE_BLOCKED: target_branch_not_allowed($ghBaseRef)" 1
                }
            }

            $mState = $gh['mergeable_state']
            if ($gh['mergeable'] -ceq 'false') {
                Fail "MERGE_BLOCKED: pr_not_mergeable(mergeable=$($gh['mergeable']),state=$mState)" 1
            }
            if ($mState -ceq 'dirty') {
                Fail "MERGE_BLOCKED: mergeable_state=$mState" 1
            }

            $effReqCi = ($authPol.RequireCi -or $RequireRemoteCi)
            $ghCi = $gh['gh_ci_status']
            if ($effReqCi) {
                if ($ghCi -cne 'PASS') {
                    Fail "MERGE_BLOCKED: ci_status=$ghCi" 1
                }
            } elseif ($ghCi -ceq 'FAIL' -or $ghCi -ceq 'PENDING') {
                Fail "MERGE_BLOCKED: ci_status=$ghCi" 1
            }

            if ($authPol.AutoMerge -cne 'authorized') {
                if ($LedgerPath -and $LedgerPath.Trim()) {
                    $lOptGh = Test-ContainedRepoPath $RepoRoot $LedgerPath
                    if (-not $lOptGh) { Fail 'MERGE_BLOCKED: invalid_ledger_path' 1 }
                }
                Fail 'PR_READY: auto_merge=disabled' 2
            }

            [void](Invoke-MergeLedgerGate $RepoRoot $LedgerPath $resolvedBaseSha $liveHeadSha)

            Write-Output "MERGE_AUTHORIZED: mode=github pr=$($gh['base_repo'])#$prNumTrim target_ref=$ghBaseRef target_sha=$resolvedBaseSha head_sha=$liveHeadSha policy_authority=${ghAuthRef}@${ghAuthSha} auto_merge=authorized ci=$ghCi governance=CLEAR"
            exit 0
        }

        # --- Provider-Neutral Local / -LocalOnly / auto_merge=disabled Path ---
        if ($RequireRemoteCi) {
            Fail 'PROVIDER_UNAVAILABLE: remote_ci_requires_provider_verification' 2
        }
        if ($autoMerge -cne 'authorized') {
            $optLedObj = $null
            if ($LedgerPath -and $LedgerPath.Trim()) {
                $lOptSpec = Test-ContainedRepoPath $RepoRoot $LedgerPath
                if (-not $lOptSpec) { Fail 'MERGE_BLOCKED: invalid_ledger_path' 1 }
                if ((Test-Path -LiteralPath $lOptSpec.Full -PathType Leaf) -and $requireCi -and (-not ($ReceiptPath -and $ReceiptPath.Trim()))) {
                    $disCall = Invoke-CapturedGuardCall { Invoke-ReviewLedgerCheck $RepoRoot $lOptSpec.Full $lOptSpec.Rel @() }
                    if ($disCall.Ok -and $disCall.Result -and $disCall.Result.Code -eq 0 -and $disCall.Result.Ledger) {
                        $optLedObj = $disCall.Result.Ledger
                    }
                }
            }
            if ($polProtectedPaths.Count -gt 0 -and -not $allowProtected -and $localPreChangedArr.Count -eq 0) {
                Fail 'MERGE_BLOCKED: missing_changed_paths' 1
            }
            if ($requireCi -or ($ReceiptPath -and $ReceiptPath.Trim())) {
                [void](Assert-LocalCiEvidence $RepoRoot $liveHeadSha $localPreChangedArr $ReceiptPath $optLedObj $ignored $ciSt $requireCi $mpCaseInsensitive)
            }
            if ($requireReview -and $revSt -cne 'PASS' -and (-not ($LedgerPath -and $LedgerPath.Trim()))) {
                Fail "MERGE_BLOCKED: review_status=$revSt" 1
            }
            if ($BaseSha -and $BaseSha.Trim()) {
                $bt = $BaseSha.Trim()
                if ($bt.StartsWith('-')) { Fail 'MERGE_BLOCKED: invalid_base_sha' 1 }
                $bChk = Invoke-GitCommand $RepoRoot @('rev-parse', '--verify', '--quiet', "${bt}^{commit}")
                if ($bChk.ExitCode -ne 0 -or $bChk.StdOut.Trim() -cnotmatch '^[0-9a-f]{40}$') {
                    Fail 'MERGE_BLOCKED: invalid_base_sha' 1
                }
            }
            Fail 'PR_READY: auto_merge=disabled' 2
        }

        # auto_merge == 'authorized' without -PrNumber (or with -LocalOnly)
        if ($polExplicit -and $effectivePolRel -cne '.b3/research-policy.json') {
            Fail 'MERGE_BLOCKED: policy_path_override_not_allowed' 1
        }
        if (-not $liveHeadSha) {
            Fail 'MERGE_BLOCKED: invalid_head' 1
        }

        # Require clean working tree & index outside checkpoint dirs
        Assert-MergeDirtyWorktreeClean $RepoRoot $policyProtectedArr $mpCaseInsensitive 'policy_modified_in_pr'

        if (-not $LocalOnly) {
            if ($RequireRemoteCi) {
                Fail 'MERGE_BLOCKED: missing_pr_number' 1
            }
            if ($hasAnyRemote -and (-not $hasOrigin)) {
                Fail 'MERGE_BLOCKED: origin_remote_missing' 1
            }
            if ($hasOrigin -and (-not $canonAuthSha)) {
                Fail 'MERGE_BLOCKED: missing_pr_number' 1
            }
        }

        $effAuthSymFull = if ($canonAuthFull) { $canonAuthFull } else { '' }
        $effAuthBranch = if ($canonAuthBranch) { $canonAuthBranch } else { '' }
        $effAuthSha = if ($canonAuthSha) { $canonAuthSha } else { $fallbackLocalTrunkSha }
        if (-not $effAuthSha) {
            Fail 'MERGE_BLOCKED: policy_not_in_authority' 1
        }

        # Re-verify policy strictly from canonical authority commit
        $authLocLs = Invoke-GitCommand $RepoRoot @('ls-tree', $effAuthSha, '--', '.b3/research-policy.json')
        $authLocLine = $authLocLs.StdOut.Trim()
        if ($authLocLs.ExitCode -ne 0 -or $authLocLine -cnotmatch "^(100644|100755) blob ([0-9a-f]{40})`t\.b3/research-policy\.json$") {
            Fail 'MERGE_BLOCKED: policy_not_in_authority' 1
        }
        $authLocShow = Invoke-GitCommand $RepoRoot @('show', "${effAuthSha}:.b3/research-policy.json")
        if ($authLocShow.ExitCode -ne 0) { Fail 'MERGE_BLOCKED: policy_not_in_authority' 1 }
        $authLocPol = Parse-MergePolicyJsonText $authLocShow.StdOut
        if ($authLocPol.AutoMerge -cne 'authorized') {
            Fail 'PR_READY: auto_merge=disabled' 2
        }

        # Resolve symbolic <target_ref>
        $targetSymFull = ''
        $targetBranchName = ''
        $resolvedBaseSha = ''
        if ($effTargetRefArg) {
            $tSymLocRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--symbolic-full-name', $effTargetRefArg)
            $targetSymFull = $tSymLocRes.StdOut.Trim()
            if ($tSymLocRes.ExitCode -ne 0 -or (-not ($targetSymFull.StartsWith('refs/heads/', [System.StringComparison]::Ordinal) -or $targetSymFull.StartsWith('refs/remotes/', [System.StringComparison]::Ordinal)))) {
                Fail 'MERGE_BLOCKED: invalid_target_ref' 1
            }
            if ($curSymFull -and ($targetSymFull -ceq $curSymFull)) {
                Fail 'MERGE_BLOCKED: invalid_target_ref' 1
            }
            if ((-not $LocalOnly) -and $hasOrigin -and (-not $targetSymFull.StartsWith('refs/remotes/origin/', [System.StringComparison]::Ordinal))) {
                Fail 'MERGE_BLOCKED: remote_tracking_target_required' 1
            }
            if ((-not $LocalOnly) -and (-not $hasAnyRemote) -and (-not $targetSymFull.StartsWith('refs/heads/', [System.StringComparison]::Ordinal))) {
                Fail 'MERGE_BLOCKED: invalid_target_ref' 1
            }
            if ($targetSymFull.StartsWith('refs/heads/', [System.StringComparison]::Ordinal)) {
                $targetBranchName = $targetSymFull.Substring('refs/heads/'.Length)
            } elseif ($targetSymFull -cmatch '^refs/remotes/[^/]+/(.+)$') {
                $targetBranchName = $Matches[1]
            }
            if ($targetBrTrim -and ($targetBrTrim -cne $targetBranchName)) {
                Fail 'MERGE_BLOCKED: target_ref_mismatch' 1
            }
            $tShaLocRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--verify', '--quiet', "${targetSymFull}^{commit}")
            $resolvedBaseSha = $tShaLocRes.StdOut.Trim()
            if ($tShaLocRes.ExitCode -ne 0 -or $resolvedBaseSha -cnotmatch '^[0-9a-f]{40}$') {
                Fail 'MERGE_BLOCKED: invalid_target_ref' 1
            }
        } elseif ($targetBrTrim) {
            $candRefs = if ($hasOrigin) {
                if ($LocalOnly) { @("refs/remotes/origin/$targetBrTrim", "refs/heads/$targetBrTrim") } else { @("refs/remotes/origin/$targetBrTrim") }
            } else {
                @("refs/heads/$targetBrTrim")
            }
            foreach ($cr in $candRefs) {
                $cRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--verify', '--quiet', "${cr}^{commit}")
                if ($cRes.ExitCode -eq 0 -and $cRes.StdOut.Trim() -cmatch '^[0-9a-f]{40}$') {
                    $targetSymFull = $cr
                    $targetBranchName = $targetBrTrim
                    $resolvedBaseSha = $cRes.StdOut.Trim()
                    break
                }
            }
            if (-not $resolvedBaseSha) {
                Fail 'MERGE_BLOCKED: target_sha_not_fetched' 1
            }
            if ($curSymFull -and ($targetSymFull -ceq $curSymFull)) {
                Fail 'MERGE_BLOCKED: invalid_target_ref' 1
            }
        } elseif ($effAuthSymFull) {
            if ($curSymFull -and ($effAuthSymFull -ceq $curSymFull)) {
                if (-not $LocalOnly) {
                    Fail 'MERGE_BLOCKED: base_sha_equals_head' 1
                }
            } else {
                $targetSymFull = $effAuthSymFull
                $targetBranchName = $effAuthBranch
                $resolvedBaseSha = $effAuthSha
            }
        }

        $baseTrimLoc = if ($BaseSha) { $BaseSha.Trim() } else { '' }
        if ($baseTrimLoc) {
            if ($baseTrimLoc.StartsWith('-')) { Fail 'MERGE_BLOCKED: invalid_base_sha' 1 }
            $bLocRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--verify', '--quiet', "${baseTrimLoc}^{commit}")
            $callerBaseLoc = $bLocRes.StdOut.Trim()
            if ($bLocRes.ExitCode -ne 0 -or $callerBaseLoc -cnotmatch '^[0-9a-f]{40}$') {
                Fail 'MERGE_BLOCKED: invalid_base_sha' 1
            }
            if ($callerBaseLoc -ceq $liveHeadSha) {
                Fail 'MERGE_BLOCKED: base_sha_equals_head' 1
            }
            if ($resolvedBaseSha) {
                if ($callerBaseLoc -cne $resolvedBaseSha) {
                    if ($LocalOnly -and (-not $effTargetRefArg) -and (-not $targetBrTrim)) {
                        $resolvedBaseSha = $callerBaseLoc
                    } else {
                        Fail 'MERGE_BLOCKED: base_sha_mismatch' 1
                    }
                }
            } elseif ($LocalOnly) {
                $resolvedBaseSha = $callerBaseLoc
            }
        }

        if (-not $resolvedBaseSha) {
            if ($LocalOnly) { Fail 'MERGE_BLOCKED: missing_base_sha' 1 }
            Fail 'MERGE_BLOCKED: invalid_target_ref' 1
        }
        if ($resolvedBaseSha -ceq $liveHeadSha) {
            Fail 'MERGE_BLOCKED: base_sha_equals_head' 1
        }
        if ((Invoke-GitCommand $RepoRoot @('merge-base', '--is-ancestor', $resolvedBaseSha, $liveHeadSha)).ExitCode -ne 0) {
            Fail 'MERGE_BLOCKED: target_branch_moved' 1
        }

        if ($targetBranchName -and $authLocPol.AllowedTargetBranches.Count -gt 0) {
            if (-not (Test-BranchPatternMatch $targetBranchName $authLocPol.AllowedTargetBranches)) {
                Fail "MERGE_BLOCKED: target_branch_not_allowed($targetBranchName)" 1
            }
        }

        if ($resolvedBaseSha -cne $effAuthSha) {
            $mbAuthLoc = Invoke-GitCommand $RepoRoot @('merge-base', $effAuthSha, $resolvedBaseSha)
            $mbAuthLocSha = $mbAuthLoc.StdOut.Trim()
            if ($mbAuthLoc.ExitCode -ne 0 -or $mbAuthLocSha -cnotmatch '^[0-9a-f]{40}$') {
                Fail 'MERGE_BLOCKED: target_branch_unrelated_to_authority' 1
            }
            $tPolLocPaths = @(Invoke-GitPathsZ $RepoRoot @('diff', '--no-ext-diff', '--name-status', '-z', "${mbAuthLocSha}..${resolvedBaseSha}", '--') 'name-status-z' 'MERGE_BLOCKED')
            foreach ($tp in $tPolLocPaths) {
                if ($tp -and (Test-ProtectedPathMatchCI $tp $policyProtectedArr $mpCaseInsensitive)) {
                    Fail 'MERGE_BLOCKED: target_branch_modified_policy' 1
                }
            }
        }

        $allChangedLoc = New-Object System.Collections.Generic.List[string]
        foreach ($cp in $changedArr) {
            if (-not $allChangedLoc.Contains($cp)) { $allChangedLoc.Add($cp) }
        }
        $cDiffLocPaths = @(Invoke-GitPathsZ $RepoRoot @('diff', '--no-ext-diff', '--name-status', '-z', "${resolvedBaseSha}..${liveHeadSha}", '--') 'name-status-z' 'MERGE_BLOCKED')
        foreach ($gp in $cDiffLocPaths) {
            if (-not $gp) { continue }
            if (Test-CheckpointPath $gp) { continue }
            if (-not $allChangedLoc.Contains($gp)) { $allChangedLoc.Add($gp) }
        }
        $allChangedLocArr = @($allChangedLoc)

        foreach ($cp in $allChangedLocArr) {
            if (Test-ProtectedPathMatchCI $cp $policyProtectedArr $mpCaseInsensitive) {
                Fail 'MERGE_BLOCKED: policy_modified_in_pr' 1
            }
        }
        if ($authLocPol.ProtectedPaths.Count -gt 0 -and -not $authLocPol.AllowProtected) {
            if ($allChangedLocArr.Count -eq 0) { Fail 'MERGE_BLOCKED: missing_changed_paths' 1 }
            $protHitsLoc = New-Object System.Collections.Generic.List[string]
            foreach ($cp in $allChangedLocArr) {
                if (Test-ProtectedPathMatchCI $cp $authLocPol.ProtectedPaths $mpCaseInsensitive) {
                    if (-not $protHitsLoc.Contains($cp)) { $protHitsLoc.Add($cp) }
                }
            }
            if ($protHitsLoc.Count -gt 0) {
                Fail ("MERGE_BLOCKED: protected_paths=" + ((Sort-Ordinal $protHitsLoc.ToArray()) -join ',')) 1
            }
        }

        $ledLocObj = Invoke-MergeLedgerGate $RepoRoot $LedgerPath $resolvedBaseSha $liveHeadSha
        [void](Assert-LocalCiEvidence $RepoRoot $liveHeadSha $allChangedLocArr $ReceiptPath $ledLocObj $ignored $ciSt ([bool]$authLocPol.RequireCi) $mpCaseInsensitive)

        if (-not $targetSymFull -or -not $effAuthSymFull) {
            Fail 'MERGE_BLOCKED: invalid_target_ref' 1
        }
        if ($hasOrigin -and (-not $LocalOnly) -and (-not $targetSymFull.StartsWith('refs/remotes/origin/', [System.StringComparison]::Ordinal))) {
            Fail 'MERGE_BLOCKED: remote_tracking_target_required' 1
        }
        if ((-not $hasAnyRemote) -and ((-not $targetSymFull.StartsWith('refs/heads/', [System.StringComparison]::Ordinal)) -or ($curSymFull -and ($targetSymFull -ceq $curSymFull)))) {
            Fail 'MERGE_BLOCKED: invalid_target_ref' 1
        }

        if ($hasAnyRemote) {
            $remoteAuthState = 'no_provider_verification'
            if ($hasOrigin) {
                $locQueryRefs = New-Object System.Collections.Generic.List[string]
                $authFullRef = if ($effAuthBranch) { "refs/heads/$effAuthBranch" } else { '' }
                $tgtFullRef = if ($targetBranchName) { "refs/heads/$targetBranchName" } else { '' }
                if ($authFullRef) { [void]$locQueryRefs.Add($authFullRef) }
                if ($tgtFullRef -and $tgtFullRef -cne $authFullRef) { [void]$locQueryRefs.Add($tgtFullRef) }
                $locLsBatch = Invoke-GitLsRemoteRefs $RepoRoot $locQueryRefs.ToArray()
                if ($locLsBatch.Status -ceq 'UNREACHABLE') {
                    $remoteAuthState = 'remote_ref_unverifiable'
                } else {
                    if ($authFullRef) {
                        if (-not $locLsBatch.Refs.ContainsKey($authFullRef)) {
                            Fail 'MERGE_BLOCKED: remote_authority_ref_missing' 1
                        }
                        if ($locLsBatch.Refs[$authFullRef] -cne $effAuthSha) {
                            Fail "MERGE_BLOCKED: stale_remote_ref(authority local=$effAuthSha remote=$($locLsBatch.Refs[$authFullRef]))" 1
                        }
                    }
                    if ($tgtFullRef) {
                        if (-not $locLsBatch.Refs.ContainsKey($tgtFullRef)) {
                            Fail 'MERGE_BLOCKED: remote_target_ref_missing' 1
                        }
                        if ($locLsBatch.Refs[$tgtFullRef] -cne $resolvedBaseSha) {
                            Fail "MERGE_BLOCKED: stale_remote_ref(target local=$resolvedBaseSha remote=$($locLsBatch.Refs[$tgtFullRef]))" 1
                        }
                    }
                }
            } else {
                $remoteAuthState = 'no_origin_remote'
            }
            Fail "LOCAL_ELIGIBLE_ONLY: engineering_ready=true remote_authorization=UNVERIFIED($remoteAuthState) auto_merge=authorized target_ref=$targetSymFull target_sha=$resolvedBaseSha head_sha=$liveHeadSha policy_authority=${effAuthSymFull}@${effAuthSha} governance=CLEAR" 2
        }

        if ($LocalOnly) {
            Fail 'LOCAL_ELIGIBLE_ONLY: engineering_ready=true auto_merge=authorized' 2
        }

        Write-Output "MERGE_AUTHORIZED: mode=local target_ref=$targetSymFull target_sha=$resolvedBaseSha head_sha=$liveHeadSha policy_authority=${effAuthSymFull}@${effAuthSha} auto_merge=authorized governance=CLEAR"
        exit 0
    }

    'context-cache' {
        foreach ($rawArg in @($Action, $CachePath, $ScopeId, $AnchorPaths, $ScopePaths, $GraphIndexSha, $SummaryRef, $IgnoreDirtyPaths)) {
            if (Test-HasControlChars $rawArg) {
                Fail 'CONTEXT_ERROR: control characters not allowed' 1
            }
        }
        $act = if ($Action) { $Action.Trim() } else { '' }
        if ($act -cnotin @('record', 'check')) {
            Fail 'CONTEXT_ERROR: invalid action' 1
        }
        $midOp = Test-GitMidOperation $RepoRoot
        if ($midOp) {
            Fail 'CONTEXT_ERROR: mid-operation git state' 1
        }
        $liveHeadSha = Resolve-StrictCommitSha $RepoRoot 'HEAD'
        if (-not $liveHeadSha) {
            Fail 'CONTEXT_ERROR: invalid HEAD' 1
        }

        $cacheSpec = Test-CheckpointFilePath $RepoRoot $CachePath
        if ($act -ceq 'record') {
            if ($cacheSpec.Status -cne 'OK') {
                Fail 'CONTEXT_ERROR: invalid cache_path' 1
            }
            $scopeVal = if ($ScopeId) { $ScopeId.Trim() } else { '' }
            if (-not (Test-ValidContextScopeId $scopeVal)) {
                Fail 'CONTEXT_ERROR: invalid scope_id' 1
            }

            $ancParsed = Split-StrictPaths $RepoRoot $AnchorPaths $true $true
            if (-not $ancParsed.Ok) {
                Fail "CONTEXT_ERROR: invalid path $($ancParsed.BadToken)" 1
            }
            $ancArr = @($ancParsed.Items)

            $recScopeParsed = Split-StrictPaths $RepoRoot $ScopePaths $true $true
            if (-not $recScopeParsed.Ok) {
                Fail "CONTEXT_ERROR: invalid path $($recScopeParsed.BadToken)" 1
            }
            $recScopeArr = @($recScopeParsed.Items)

            $ignParsed = Split-StrictPaths $RepoRoot $IgnoreDirtyPaths $true $false
            if (-not $ignParsed.Ok) {
                Fail 'CONTEXT_ERROR: invalid ignore path' 1
            }
            $ignArr = @($ignParsed.Items)
            if ((Test-IgnoreOverlapsPaths $ignArr $ancArr) -or (Test-IgnoreOverlapsPaths $ignArr $recScopeArr)) {
                Fail 'CONTEXT_ERROR: invalid ignore path' 1
            }

            $graphTrim = if ($GraphIndexSha) { $GraphIndexSha.Trim() } else { '' }
            $graphVal = 'none'
            if ($graphTrim -and $graphTrim -cne 'none') {
                $resGraph = Resolve-StrictCommitSha $RepoRoot $graphTrim
                if (-not $resGraph) {
                    Fail 'CONTEXT_ERROR: invalid graph_index_sha' 1
                }
                $graphVal = $resGraph
            }

            if ($ancArr.Count -eq 0 -and $graphVal -ceq 'none') {
                Fail 'CONTEXT_ERROR: empty cache (anchor_paths or graph_index_sha required)' 1
            }

            $sumTrim = if ($SummaryRef) { $SummaryRef.Trim() } else { '' }
            $sumRefVal = 'none'
            $sumShaVal = 'none'
            if ($sumTrim -and $sumTrim -cne 'none') {
                $sumSpec = Test-CheckpointFilePath $RepoRoot $sumTrim
                if ($sumSpec.Status -cne 'OK') {
                    Fail 'CONTEXT_ERROR: invalid summary_ref' 1
                }
                if (-not (Test-Path -LiteralPath $sumSpec.Full -PathType Leaf) -or (Test-IsReparsePath $sumSpec.Full)) {
                    Fail 'CONTEXT_ERROR: missing summary_ref' 1
                }
                $sumShaVal = (Get-FileHash -LiteralPath $sumSpec.Full -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($sumShaVal -cnotmatch '^[0-9a-f]{64}$') {
                    Fail 'CONTEXT_ERROR: sha256 computation failed' 1
                }
                $sumRefVal = $sumSpec.Rel
            }

            $anchorPathsVal = 'none'
            $anchorHashVal = 'none'
            if ($ancArr.Count -gt 0) {
                $anchorPathsVal = $ancArr -join ','
                $fp = Get-TreeFingerprint $RepoRoot $ancArr $ignArr
                $anchorHashVal = $fp.TreeHash
            }

            $tsUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
            $bodyLines = @(
                'schema=b3-context-v1',
                "scope_id=$scopeVal",
                "head_sha=$liveHeadSha",
                "anchor_paths=$anchorPathsVal",
                "anchor_hash=$anchorHashVal",
                "graph_index_sha=$graphVal",
                "summary_ref=$sumRefVal",
                "summary_sha256=$sumShaVal",
                "timestamp_utc=$tsUtc"
            )
            Write-AtomicLfFile $cacheSpec.Full (($bodyLines -join "`n") + "`n")
            Write-Output "CONTEXT_RECORDED: $($cacheSpec.Rel) scope=$scopeVal head=$liveHeadSha anchor_hash=$anchorHashVal graph_index_sha=$graphVal"
            exit 0
        }

        if ($cacheSpec.Status -ceq 'INVALID') {
            Fail 'CONTEXT_ERROR: invalid cache_path' 1
        }
        if ($cacheSpec.Status -ceq 'SYMLINK_OR_DIR') {
            Fail 'CONTEXT_CORRUPT: invalid cache_path' 1
        }

        $callerScope = if ($ScopeId) { $ScopeId.Trim() } else { '' }
        if ($callerScope -and -not (Test-ValidContextScopeId $callerScope)) {
            Fail 'CONTEXT_ERROR: invalid scope_id' 1
        }

        $hasCallerAnchor = $false
        $callerAnchorArr = @()
        $callerAnchorCsv = 'none'
        $ancRawTrim = if ($AnchorPaths) { $AnchorPaths.Trim() } else { '' }
        if ($ancRawTrim.Length -gt 0) {
            $hasCallerAnchor = $true
            $cAncParsed = Split-StrictPaths $RepoRoot $AnchorPaths $true $true
            if (-not $cAncParsed.Ok) {
                Fail "CONTEXT_ERROR: invalid path $($cAncParsed.BadToken)" 1
            }
            $callerAnchorArr = @($cAncParsed.Items)
            if ($callerAnchorArr.Count -gt 0) {
                $callerAnchorCsv = $callerAnchorArr -join ','
            }
        }

        $scopeParsed = Split-StrictPaths $RepoRoot $ScopePaths $true $true
        if (-not $scopeParsed.Ok) {
            Fail "CONTEXT_ERROR: invalid path $($scopeParsed.BadToken)" 1
        }
        $scopeArr = @($scopeParsed.Items)

        $ignParsed = Split-StrictPaths $RepoRoot $IgnoreDirtyPaths $true $false
        if (-not $ignParsed.Ok) {
            Fail 'CONTEXT_ERROR: invalid ignore path' 1
        }
        $ignArr = @($ignParsed.Items)

        $hasCallerGraph = $false
        $callerGraphVal = 'none'
        $callerGraphTrim = if ($GraphIndexSha) { $GraphIndexSha.Trim() } else { '' }
        if ($callerGraphTrim.Length -gt 0) {
            $hasCallerGraph = $true
            if ($callerGraphTrim -ceq 'none') {
                $callerGraphVal = 'none'
            } else {
                $resCallerGraph = Resolve-StrictCommitSha $RepoRoot $callerGraphTrim
                if (-not $resCallerGraph) {
                    Fail 'CONTEXT_ERROR: invalid graph_index_sha' 1
                }
                $callerGraphVal = $resCallerGraph
            }
        }

        $hasCallerSummary = $false
        $callerSummaryVal = 'none'
        $sumRawTrim = if ($SummaryRef) { $SummaryRef.Trim() } else { '' }
        if ($sumRawTrim.Length -gt 0) {
            $hasCallerSummary = $true
            if ($sumRawTrim -ceq 'none') {
                $callerSummaryVal = 'none'
            } else {
                $cSumSpec = Test-CheckpointFilePath $RepoRoot $sumRawTrim
                if ($cSumSpec.Status -cne 'OK') {
                    Fail 'CONTEXT_ERROR: invalid summary_ref' 1
                }
                $callerSummaryVal = $cSumSpec.Rel
            }
        }

        if (($hasCallerAnchor -and (Test-IgnoreOverlapsPaths $ignArr $callerAnchorArr)) -or (Test-IgnoreOverlapsPaths $ignArr $scopeArr)) {
            Fail 'CONTEXT_ERROR: invalid ignore path' 1
        }

        if (-not (Test-Path -LiteralPath $cacheSpec.Full -PathType Leaf)) {
            Fail "CONTEXT_MISSING: $($cacheSpec.Rel)" 1
        }
        if (Test-IsReparsePath $cacheSpec.Full) {
            Fail 'CONTEXT_CORRUPT: invalid cache_path' 1
        }

        $rawBytes = [IO.File]::ReadAllBytes($cacheSpec.Full)
        $utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
        $rawText = ''
        try {
            $rawText = $utf8Strict.GetString($rawBytes)
        } catch {
            Fail 'CONTEXT_CORRUPT: invalid utf8 encoding' 1
        }
        if ($rawText -match '[\x00-\x09\x0B-\x1F\x7F]') {
            Fail 'CONTEXT_CORRUPT: control character or CRLF in cache' 1
        }

        $allowedKeys = @('schema', 'scope_id', 'head_sha', 'anchor_paths', 'anchor_hash', 'graph_index_sha', 'summary_ref', 'summary_sha256', 'timestamp_utc')
        $kv = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::Ordinal)
        if ($rawText.Length -gt 0) {
            $bodyText = if ($rawText.EndsWith("`n")) { $rawText.Substring(0, $rawText.Length - 1) } else { $rawText }
            foreach ($rawLine in ($bodyText -split "`n")) {
                $eqIdx = $rawLine.IndexOf('=')
                if ($eqIdx -lt 1) {
                    Fail 'CONTEXT_CORRUPT: malformed line' 1
                }
                $k = $rawLine.Substring(0, $eqIdx)
                $v = $rawLine.Substring($eqIdx + 1)
                if ($k -cnotin $allowedKeys) {
                    Fail "CONTEXT_CORRUPT: unknown field '$k'" 1
                }
                if ($kv.ContainsKey($k)) {
                    Fail "CONTEXT_CORRUPT: duplicate field '$k'" 1
                }
                if (-not $v) {
                    Fail "CONTEXT_CORRUPT: empty field '$k'" 1
                }
                $kv[$k] = $v
            }
        }
        foreach ($reqKey in $allowedKeys) {
            if (-not $kv.ContainsKey($reqKey)) {
                Fail "CONTEXT_CORRUPT: missing field '$reqKey'" 1
            }
        }

        if ($kv['schema'] -cne 'b3-context-v1') {
            Fail 'CONTEXT_CORRUPT: invalid schema' 1
        }
        if (-not (Test-ValidContextScopeId $kv['scope_id'])) {
            Fail 'CONTEXT_CORRUPT: invalid scope_id' 1
        }
        if ($kv['head_sha'] -cnotmatch '^[0-9a-f]{40}$') {
            Fail 'CONTEXT_CORRUPT: invalid head_sha' 1
        }

        $recAnchorArr = @()
        $recAnchorCsv = 'none'
        if ($kv['anchor_paths'] -ceq 'none') {
            if ($kv['anchor_hash'] -cne 'none') {
                Fail 'CONTEXT_CORRUPT: invalid anchor_hash' 1
            }
        } else {
            if ($kv['anchor_hash'] -cnotmatch '^[0-9a-f]{40}$') {
                Fail 'CONTEXT_CORRUPT: invalid anchor_hash' 1
            }
            $recAncParsed = Split-StrictPaths $RepoRoot $kv['anchor_paths'] $false $true
            if (-not $recAncParsed.Ok -or $recAncParsed.Items.Count -lt 1) {
                Fail 'CONTEXT_CORRUPT: invalid anchor_paths' 1
            }
            $recAnchorArr = @($recAncParsed.Items)
            $recAnchorCsv = $recAnchorArr -join ','
        }

        if ($kv['graph_index_sha'] -cne 'none' -and $kv['graph_index_sha'] -cnotmatch '^[0-9a-f]{40}$') {
            Fail 'CONTEXT_CORRUPT: invalid graph_index_sha' 1
        }
        if ($kv['anchor_paths'] -ceq 'none' -and $kv['graph_index_sha'] -ceq 'none') {
            Fail 'CONTEXT_CORRUPT: empty cache (anchor_paths or graph_index_sha required)' 1
        }

        $recSumSpec = $null
        if ($kv['summary_ref'] -ceq 'none') {
            if ($kv['summary_sha256'] -cne 'none') {
                Fail 'CONTEXT_CORRUPT: invalid summary_sha256' 1
            }
        } else {
            if ($kv['summary_sha256'] -cnotmatch '^[0-9a-f]{64}$') {
                Fail 'CONTEXT_CORRUPT: invalid summary_sha256' 1
            }
            $recSumSpec = Test-CheckpointFilePath $RepoRoot $kv['summary_ref']
            if ($recSumSpec.Status -cne 'OK') {
                Fail 'CONTEXT_CORRUPT: missing or invalid summary_ref' 1
            }
        }

        if ($kv['timestamp_utc'] -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$') {
            Fail 'CONTEXT_CORRUPT: invalid timestamp_utc' 1
        }

        if ($callerScope -and $callerScope -cne $kv['scope_id']) {
            Fail "CONTEXT_MISMATCH: scope_id expected=$callerScope got=$($kv['scope_id'])" 1
        }

        if ($hasCallerSummary -and $callerSummaryVal -cne $kv['summary_ref']) {
            Fail "CONTEXT_MISMATCH: summary_ref expected=$callerSummaryVal got=$($kv['summary_ref'])" 1
        }

        if (Test-IgnoreOverlapsPaths $ignArr $recAnchorArr) {
            Fail 'CONTEXT_ERROR: invalid ignore path' 1
        }

        $reasons = New-Object System.Collections.Generic.List[string]

        $ancRes = Invoke-GitCommand $RepoRoot @('merge-base', '--is-ancestor', $kv['head_sha'], $liveHeadSha)
        if ($ancRes.ExitCode -ne 0) {
            [void]$reasons.Add('head_diverged')
        }

        if ($hasCallerAnchor -and ($callerAnchorCsv -cne $recAnchorCsv)) {
            [void]$reasons.Add('anchor_scope_changed')
        }

        if ($recAnchorArr.Count -gt 0) {
            $liveFp = Get-TreeFingerprint $RepoRoot $recAnchorArr $ignArr
            if ($liveFp.TreeHash -cne $kv['anchor_hash']) {
                [void]$reasons.Add('anchor_changed')
            }
        }

        if ($kv['summary_ref'] -cne 'none') {
            if (-not $recSumSpec -or -not (Test-Path -LiteralPath $recSumSpec.Full -PathType Leaf) -or (Test-IsReparsePath $recSumSpec.Full)) {
                Fail 'CONTEXT_CORRUPT: missing or invalid summary_ref' 1
            }
            $liveSumSha = (Get-FileHash -LiteralPath $recSumSpec.Full -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($liveSumSha -cne $kv['summary_sha256']) {
                [void]$reasons.Add('summary_changed')
            }
        }

        $recGraphSha = $kv['graph_index_sha']
        $graphIndexStatus = 'NOT_RECORDED'
        if (($recGraphSha -cne 'none') -or ($hasCallerGraph -and ($callerGraphVal -cne 'none'))) {
            $probePaths = @()
            if ($scopeArr.Count -gt 0) {
                $probeRaw = New-Object System.Collections.Generic.List[string]
                foreach ($rp in $recAnchorArr) { [void]$probeRaw.Add($rp) }
                if ($hasCallerAnchor) {
                    foreach ($cp in $callerAnchorArr) { [void]$probeRaw.Add($cp) }
                }
                foreach ($sp in $scopeArr) { [void]$probeRaw.Add($sp) }
                $probePaths = @(Sort-Ordinal $probeRaw.ToArray())
            }
            if ($recGraphSha -cne 'none') {
                $graphMismatch = $hasCallerGraph -and ($callerGraphVal -cne $recGraphSha)
                $recFresh = Test-GraphIndexFresh $RepoRoot $recGraphSha $liveHeadSha $probePaths $ignArr
                if ($graphMismatch) {
                    [void]$reasons.Add('graph_index_mismatch')
                }
                if (-not $recFresh) {
                    [void]$reasons.Add('graph_index_stale')
                }
                if ($graphMismatch -or (-not $recFresh)) {
                    $graphIndexStatus = 'STALE'
                } else {
                    $graphIndexStatus = 'FRESH'
                }
            } else {
                $graphIndexStatus = 'STALE'
                [void]$reasons.Add('graph_index_mismatch')
                if (-not (Test-GraphIndexFresh $RepoRoot $callerGraphVal $liveHeadSha $probePaths $ignArr)) {
                    [void]$reasons.Add('graph_index_stale')
                }
            }
        }

        $anchorStatus = if ($kv['anchor_paths'] -ceq 'none') { 'NOT_RECORDED' } else { 'FRESH' }
        if (($reasons -ccontains 'head_diverged') -or ($reasons -ccontains 'anchor_scope_changed') -or ($reasons -ccontains 'anchor_changed')) {
            $anchorStatus = 'STALE'
        }

        if ($reasons.Count -gt 0) {
            $reasonCsv = $reasons.ToArray() -join ','
            Fail "CONTEXT_STALE: scope=$($kv['scope_id']) reasons=$reasonCsv anchor_status=$anchorStatus graph_index=$graphIndexStatus live_lsp_eligible=true" 2
        }

        Write-Output "CONTEXT_FRESH: scope=$($kv['scope_id']) head=$liveHeadSha anchor_status=$anchorStatus graph_index=$graphIndexStatus live_lsp_eligible=true"
        exit 0
    }
}
