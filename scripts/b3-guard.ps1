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
    [string]$MainRef = 'HEAD',
    [string]$CachePath = '',
    [string]$ScopeId = '',
    [string]$AnchorPaths = '',
    [string]$ScopePaths = '',
    [string]$GraphIndexSha = '',
    [string]$SummaryRef = ''
)

$ErrorActionPreference = 'Stop'
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

function Fail([string]$Message, [int]$Code = 1) {
    Write-Output $Message
    exit $Code
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

function Test-CheckpointPath([string]$PathVal) {
    if (-not $PathVal) { return $false }
    return ($PathVal -match '^\.b3/(ship|research-ship|autodev)(/|$)')
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
    if (-not $p -or $p -eq '.' -or $p.StartsWith('/') -or $p.StartsWith('~') -or $p.Contains(':') -or ($p -match '(^|/)\.\.(/|$)')) {
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
    $rootSlash = ($Root -replace '\\', '/').TrimEnd('/')
    $full = $null
    try {
        $full = Resolve-TargetPath $Root $p
    } catch {
        return $null
    }
    if (-not $full) { return $null }
    $fullSlash = ($full -replace '\\', '/').TrimEnd('/')
    $cmp = if ([IO.Path]::DirectorySeparatorChar -eq '\') {
        [System.StringComparison]::OrdinalIgnoreCase
    } else {
        [System.StringComparison]::Ordinal
    }
    if ($rootSlash -eq '') {
        if (-not $fullSlash.StartsWith('/', $cmp) -or $fullSlash -eq '') { return $null }
    } else {
        if ($fullSlash.Equals($rootSlash, $cmp) -or (-not $fullSlash.StartsWith("$rootSlash/", $cmp))) {
            return $null
        }
    }
    $segCur = $Root
    foreach ($seg in ($p -split '/')) {
        if (-not $seg -or $seg -eq '.') { continue }
        $segCur = Join-Path $segCur $seg
        $segItem = Get-Item -LiteralPath $segCur -Force -ErrorAction SilentlyContinue
        if ($segItem) {
            if (Test-IsReparseItem $segItem) { return $null }
            try {
                $attrs = [IO.File]::GetAttributes($segCur)
                if (($attrs -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $null }
            } catch { return $null }
        } elseif (Test-Path -LiteralPath $segCur) {
            return $null
        }
    }
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

function Invoke-GitCommand([string]$Root, [string[]]$GitArgs, [string]$StdInText = '', [hashtable]$ExtraEnv = $null) {
    $useStdIn = $PSBoundParameters.ContainsKey('StdInText')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
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
    $allArgs = @('-C', $Root, '-c', 'core.quotepath=false') + @($GitArgs)
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
        $proc.WaitForExit()
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

function Invoke-GitLines([string]$Root, [string[]]$GitArgs) {
    $res = Invoke-GitCommand $Root $GitArgs
    if ($res.ExitCode -ne 0) {
        $detail = if ($res.StdErr -and $res.StdErr.Trim()) { $res.StdErr.Trim() } else { $res.StdOut.Trim() }
        Fail "GIT_ERROR: git $($GitArgs -join ' ') failed: $detail" 1
    }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($res.StdOut -split "\r?\n")) {
        $norm = Normalize-PathValue ([string]$line)
        if ($norm -and -not $lines.Contains($norm)) {
            $lines.Add($norm)
        }
    }
    return @($lines)
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
    $changed = Invoke-GitCommand $Root @('diff', '--no-renames', '--diff-filter=d', '--name-only', 'HEAD', '--')
    $untracked = Invoke-GitCommand $Root @('ls-files', '--others', '--exclude-standard')
    if ($changed.ExitCode -ne 0 -or $untracked.ExitCode -ne 0) {
        Fail "${FailPrefix}: unable to inspect snapshot paths" 1
    }
    foreach ($line in (($changed.StdOut + "`n" + $untracked.StdOut) -split "\r?\n")) {
        $p = Normalize-PathValue ([string]$line)
        if ($p -and (Test-SecretPath $p)) {
            Fail "${FailPrefix}: sensitive path cannot be snapshotted ($p)" 1
        }
    }
    $links = Invoke-GitCommand $Root @('ls-files', '--stage')
    if ($links.ExitCode -ne 0) { Fail "${FailPrefix}: unable to inspect submodules" 1 }
    foreach ($entry in ($links.StdOut -split "\r?\n")) {
        if ($entry -cnotmatch '^160000 [0-9a-f]{40} [0-3]\t(.+)$') { continue }
        $rel = $Matches[1]
        $sub = Join-Path $Root ($rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath (Join-Path $sub '.git'))) { continue }
        $state = Invoke-GitCommand $sub @('status', '--porcelain', '--untracked-files=all', '--ignore-submodules=none')
        if ($state.ExitCode -ne 0) { Fail "${FailPrefix}: unable to inspect submodule ($rel)" 1 }
        if ($state.StdOut.Trim()) { Fail "${FailPrefix}: dirty submodule cannot be snapshotted ($rel)" 1 }
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
            $ch = Invoke-GitCommand $Root @('diff', '--no-renames', '--diff-filter=d', '--name-only', 'HEAD', '--')
            if ($ch.ExitCode -eq 0) {
                foreach ($line in ($ch.StdOut -split "\r?\n")) {
                    $sp = Normalize-PathValue ([string]$line)
                    if ($sp -and (Test-SecretPath $sp)) {
                        [void]$trackedSecrets.Add($sp)
                    }
                }
            }
        } else {
            $st = Invoke-GitCommand $Root @('ls-files', '--cached')
            if ($st.ExitCode -eq 0) {
                foreach ($line in ($st.StdOut -split "\r?\n")) {
                    $sp = Normalize-PathValue ([string]$line)
                    if ($sp -and (Test-SecretPath $sp)) {
                        [void]$unbornStagedSecrets.Add($sp)
                    }
                }
            }
        }
    } else {
        Assert-SnapshotSafe $Root $FailPrefix
    }
    $un = Invoke-GitCommand $Root @('ls-files', '--others', '--exclude-standard')
    if ($un.ExitCode -eq 0) {
        foreach ($line in ($un.StdOut -split "\r?\n")) {
            $sp = Normalize-PathValue ([string]$line)
            if (-not $sp) { continue }
            if (Test-CheckpointPath $sp) { continue }
            if ($ExcludeSensitive -and (Test-SecretPath $sp)) { continue }
            [void]$untrackedToAdd.Add($sp)
        }
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
            $wtDiffRes = Invoke-GitCommand $Root @('diff', '--no-renames', '--name-only', '--') -ExtraEnv $envMap
            if ($wtDiffRes.ExitCode -ne 0) {
                $detail = if ($wtDiffRes.StdErr.Trim()) { $wtDiffRes.StdErr.Trim() } else { $wtDiffRes.StdOut.Trim() }
                Fail "${FailPrefix}: git diff tracked failed: $detail" 1
            }
            $trackedSecretSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
            foreach ($ts in $trackedSecrets) { [void]$trackedSecretSet.Add($ts) }
            $nonSecretTracked = New-Object System.Collections.Generic.List[string]
            foreach ($line in ($wtDiffRes.StdOut -split "\r?\n")) {
                $sp = Normalize-PathValue ([string]$line)
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
    $diffRes = Invoke-GitCommand $Root @('diff', '--no-renames', '--name-only', 'HEAD')
    $unRes = Invoke-GitCommand $Root @('ls-files', '--others', '--exclude-standard')
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($diffRes.ExitCode -eq 0) {
        foreach ($row in ($diffRes.StdOut -split "\r?\n")) {
            $p = Normalize-PathValue ([string]$row)
            if ($p) { $candidates.Add($p) }
        }
    }
    if ($unRes.ExitCode -eq 0) {
        foreach ($row in ($unRes.StdOut -split "\r?\n")) {
            $p = Normalize-PathValue ([string]$row)
            if ($p) { $candidates.Add($p) }
        }
    }
    foreach ($p in $candidates) {
        if (Test-CheckpointPath $p) { continue }
        if ($IgnoredPaths -and (Test-PathMatch $p $IgnoredPaths)) { continue }
        return 'HEAD'
    }

    $headRes = Invoke-GitCommand $Root @('rev-parse', 'HEAD')
    $headSha = $headRes.StdOut.Trim()
    if ($headRes.ExitCode -eq 0 -and $headSha) {
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
    if (-not [IO.Path]::IsPathRooted($gd)) {
        $gd = Join-Path $Root ($gd -replace '/', '\')
    }
    return $gd
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
    if ([IO.Path]::IsPathRooted($p)) {
        return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($p)
    }
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((Join-Path $Root ($p -replace '/', '\')))
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

function Resolve-SafeRepoWritePath([string]$Root, [string]$PathArg) {
    if ([string]::IsNullOrWhiteSpace($PathArg)) { return $null }
    $trimmed = $PathArg.Trim()
    $slashArg = $trimmed -replace '\\', '/'
    if (-not $slashArg -or $slashArg -eq '.' -or $slashArg.StartsWith('~') -or $slashArg.EndsWith('/')) { return $null }
    if ($trimmed -match '[\x00-\x1F\x7F]') { return $null }
    if ($slashArg -match '(^|/)\.\.(/|$)') { return $null }
    if ([IO.Path]::DirectorySeparatorChar -eq '\' -and $slashArg -match '^[A-Za-z]:' -and $slashArg -notmatch '^[A-Za-z]:/') { return $null }

    $full = $null
    try {
        $full = Resolve-TargetPath $Root $trimmed
    } catch {
        return $null
    }
    if (-not $full) { return $null }

    $rootSlash = ($Root -replace '\\', '/').TrimEnd('/')
    $fullSlash = ($full -replace '\\', '/').TrimEnd('/')
    $cmp = if ([IO.Path]::DirectorySeparatorChar -eq '\') {
        [System.StringComparison]::OrdinalIgnoreCase
    } else {
        [System.StringComparison]::Ordinal
    }
    if ($rootSlash -eq '') {
        if (-not $fullSlash.StartsWith('/', $cmp) -or $fullSlash -eq '') { return $null }
    } else {
        if ($fullSlash.Equals($rootSlash, $cmp) -or (-not $fullSlash.StartsWith("$rootSlash/", $cmp))) {
            return $null
        }
    }

    $rel = Get-RepoRelativePath $Root $full
    if (-not $rel -or $rel -eq '.' -or [IO.Path]::IsPathRooted($rel) -or $rel.StartsWith('/') -or $rel.StartsWith('~') -or ($rel -match '^[A-Za-z]:') -or ($rel -match '(^|/)\.\.(/|$)') -or ($rel -match '^\.git(/|$)')) {
        return $null
    }

    $segCur = $Root
    foreach ($seg in ($rel -split '/')) {
        if (-not $seg -or $seg -eq '.') { continue }
        $segCur = Join-Path $segCur $seg
        $segItem = Get-Item -LiteralPath $segCur -Force -ErrorAction SilentlyContinue
        if ($segItem) {
            if (Test-IsReparseItem $segItem) { return $null }
            try {
                $attrs = [IO.File]::GetAttributes($segCur)
                if (($attrs -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $null }
            } catch {
                return $null
            }
        } elseif (Test-Path -LiteralPath $segCur) {
            return $null
        }
    }

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
    $hRes = Invoke-GitCommand $Root @('hash-object', '--stdin') -StdInText $Text
    $hOut = $hRes.StdOut.Trim()
    if ($hRes.ExitCode -ne 0 -or $hOut -cnotmatch '^[0-9a-f]{40}$') {
        $detail = if ($hRes.StdErr.Trim()) { $hRes.StdErr.Trim() } else { $hOut }
        Fail "${FailPrefix}: git hash-object ${FailDesc}: $detail" 1
    }
    return $hOut
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

        $stRes = Invoke-GitCommand $subFull @('status', '--porcelain', '-uall', '--ignore-submodules=none')
        if ($stRes.ExitCode -ne 0) {
            $detail = if ($stRes.StdErr.Trim()) { $stRes.StdErr.Trim() } else { $stRes.StdOut.Trim() }
            Fail "GIT_ERROR: submodule status failed for ${RelPath}: $detail" 1
        }
        $stList = New-Object System.Collections.Generic.List[string]
        foreach ($rawSt in ($stRes.StdOut -split "\r?\n")) {
            $cleanSt = ([string]$rawSt).TrimEnd("`r")
            if ($cleanSt -and $cleanSt.Trim()) {
                $stList.Add($cleanSt)
            }
        }
        if ($stList.Count -eq 0) {
            return "160000 commit $subHead"
        }

        $sbDirty = New-Object System.Text.StringBuilder
        foreach ($sl in @(Sort-Ordinal $stList.ToArray())) {
            [void]$sbDirty.Append("S $sl`n")
        }
        $sWt = if ($hasHead) { @(Invoke-GitLines $subFull @('diff', '--no-renames', '--name-only', '--ignore-submodules=none', 'HEAD')) } else { @() }
        $sCa = @(Invoke-GitLines $subFull @('diff', '--no-renames', '--cached', '--name-only'))
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

function Get-TreeFingerprint([string]$Root, [string[]]$RelPaths, [string[]]$IgnPaths) {
    $headRes = Invoke-GitCommand $Root @('rev-parse', 'HEAD')
    $headSha = $headRes.StdOut.Trim()
    if ($headRes.ExitCode -ne 0 -or $headSha -notmatch '^[0-9a-f]{40}$') {
        $detail = if ($headRes.StdErr.Trim()) { $headRes.StdErr.Trim() } else { $headSha }
        Fail "GIT_ERROR: git rev-parse HEAD failed: $detail" 1
    }

    $fmRes = Invoke-GitCommand $Root @('config', '--bool', 'core.filemode')
    $isWinOs = ($env:OS -eq 'Windows_NT')
    $coreFilemode = if ($fmRes.ExitCode -eq 0) {
        ($fmRes.StdOut.Trim() -ceq 'true')
    } else {
        (-not $isWinOs)
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
    $lsArgs = @('ls-tree', '-r', 'HEAD')
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

    $scopeSuffix = if ($cleanRel.Count -gt 0) { @('--') + $cleanRel } else { @() }
    $hdRes = Invoke-GitCommand $Root (@('diff', '--raw', '--no-renames', '--no-abbrev', '--ignore-submodules=none', 'HEAD') + $scopeSuffix)
    if ($hdRes.ExitCode -ne 0) {
        $detail = if ($hdRes.StdErr.Trim()) { $hdRes.StdErr.Trim() } else { $hdRes.StdOut.Trim() }
        Fail "GIT_ERROR: git diff --raw HEAD failed: $detail" 1
    }
    $caRes = Invoke-GitCommand $Root (@('diff', '--cached', '--raw', '--no-renames', '--no-abbrev', '--ignore-submodules=none') + $scopeSuffix)
    if ($caRes.ExitCode -ne 0) {
        $detail = if ($caRes.StdErr.Trim()) { $caRes.StdErr.Trim() } else { $caRes.StdOut.Trim() }
        Fail "GIT_ERROR: git diff --cached --raw failed: $detail" 1
    }
    $iwRes = Invoke-GitCommand $Root (@('diff', '--raw', '--no-renames', '--no-abbrev', '--ignore-submodules=none') + $scopeSuffix)
    if ($iwRes.ExitCode -ne 0) {
        $detail = if ($iwRes.StdErr.Trim()) { $iwRes.StdErr.Trim() } else { $iwRes.StdOut.Trim() }
        Fail "GIT_ERROR: git diff --raw index-wt failed: $detail" 1
    }
    $untracked = @(Invoke-GitLines $Root (@('ls-files', '--others', '--exclude-standard') + $scopeSuffix))

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

    $indexDiv = New-Object 'System.Collections.Hashtable' ([System.StringComparer]::Ordinal)
    foreach ($p in @(Sort-Ordinal @($cachedDiff.Keys))) {
        $c = $cachedDiff[$p]
        $hasEff = $effective.ContainsKey($p)
        $effMode = if ($hasEff) { ($effective[$p] -split ' ', 2)[0] } else { '' }
        if (($c.NewMode -ceq '000000' -and $hasEff) -or
            ($c.NewMode -cne '000000' -and ((-not $hasEff) -or ($effMode -cne $c.NewMode)))) {
            $cType = Get-GitEntryType $c.NewMode
            $indexDiv[$p] = "$($c.NewMode) $cType $($c.NewOid)"
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

function Test-VerifyReceipt([string]$Root, [string]$ReceiptArg, [string[]]$IgnPaths, [string]$ExpectedCmdArg = '', [string]$ReqRelPathsArg = '') {
    $trimArg = $ReceiptArg.Trim()
    if (-not $trimArg) {
        return @{ Code = 1; Message = 'VERIFY_MISSING: empty receipt path' }
    }
    $fullReceipt = Resolve-TargetPath $Root $trimArg
    $dispPath = Get-RepoRelativePath $Root $fullReceipt
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
        $relSpec = @(Split-CsvList $kv['relevant_paths'] -AsPaths)
        $validRel = @($relSpec | Where-Object { $_ -and (-not (Test-CheckpointPath $_)) })
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
        $reqSpec = @(Split-CsvList $ReqRelPathsArg -AsPaths)
        $validReq = @($reqSpec | Where-Object { $_ -and (-not (Test-CheckpointPath $_)) })
        if ($validReq.Count -lt 1) {
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

    $cur = Get-TreeFingerprint $Root $relSpec $IgnPaths
    if ($cur.HeadSha -cne $kv['head_sha']) {
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

function Get-CanonicalGitCommonDir([string]$Dir) {
    $res = Invoke-GitCommand $Dir @('rev-parse', '--git-common-dir')
    $gd = $res.StdOut.Trim()
    if ($res.ExitCode -ne 0 -or -not $gd) { return $null }
    if (-not [IO.Path]::IsPathRooted($gd)) {
        $gd = Join-Path $Dir ($gd -replace '/', '\')
    }
    return (Normalize-PathValue ([IO.Path]::GetFullPath($gd)))
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
    if ($LineLower -match '(^|[^a-z0-9_])(useframe|requestanimationframe|instancedmesh|webglrenderer|asnotracking|json\.stringify|json\.parse)') {
        Add-SignalTag $Map $PathVal 'perf_hot_path'
    }
}

function Invoke-CollectScopeData([string]$Root, [string]$ResolvedBase, [string]$TargetCommitSha, [string[]]$IgnPaths, [string]$FailPrefix) {
    $nsArgs = if ($TargetCommitSha) {
        @('diff', '--no-renames', '--numstat', $ResolvedBase, $TargetCommitSha, '--')
    } else {
        @('diff', '--no-renames', '--numstat', $ResolvedBase, '--')
    }
    $nsRes = Invoke-GitCommand $Root $nsArgs
    if ($nsRes.ExitCode -ne 0) {
        $detail = if ($nsRes.StdErr.Trim()) { $nsRes.StdErr.Trim() } else { $nsRes.StdOut.Trim() }
        Fail ("${FailPrefix}: git diff --numstat failed: $detail") 1
    }

    $stArgs = if ($TargetCommitSha) {
        @('diff', '--no-renames', '--name-status', $ResolvedBase, $TargetCommitSha, '--')
    } else {
        @('diff', '--no-renames', '--name-status', $ResolvedBase, '--')
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
            @('diff', '--no-renames', '-U0', $ResolvedBase, $TargetCommitSha, '--')
        } else {
            @('diff', '--no-renames', '-U0', $ResolvedBase, '--')
        }
        $dRes = Invoke-GitCommand $Root $dArgs
        if ($dRes.ExitCode -eq 0 -and $dRes.StdOut) {
            $hdrOldPath = ''
            $curPath = ''
            $curScan = $false
            foreach ($dl in ($dRes.StdOut -split "\r?\n")) {
                if ($dl.StartsWith('diff --git ')) {
                    $hdrOldPath = ''; $curPath = ''; $curScan = $false
                    continue
                }
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
                if ($curScan -and $curPath -and (($dl.StartsWith('+') -and -not $dl.StartsWith('+++')) -or ($dl.StartsWith('-') -and -not $dl.StartsWith('---')))) {
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
                if (-not $sigs.Contains($s)) { [void]$sigs.Add($s) }
                if ($s -ceq 'public_api_contract' -or $s -ceq 'db_migration_tx') { $hasContractSig = $true }
            }
        } else {
            $tmpMap = @{}
            Scan-PathRiskSignals $tmpMap $p
            if ($tmpMap.ContainsKey($p)) {
                foreach ($s in @($tmpMap[$p])) {
                    if ($s -ceq '_db_destructive') { $hasDestructive = $true; continue }
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

function Get-DefaultMaxPasses([string]$SizeClass) {
    switch (Normalize-SizeClass $SizeClass) {
        'L' { return 12 }
        'XL' { return 12 }
        'XXL' { return 24 }
        default { return 5 }
    }
}

function Test-WaiverAttempt([string]$RationaleVal) {
    $t = if ($RationaleVal) { $RationaleVal.Trim() } else { '' }
    return ($t -match '^WAIVER:')
}

function Get-InitialPassChain([string]$Root, [string]$BaseSha) {
    return (Invoke-GitTextHash $Root "b3-pass-v1|init|$BaseSha|0`n" 'LEDGER_FAIL')
}

function Step-PassChain([string]$Root, [string]$PrevChain, [int]$Seq, [string]$ScopeId, [string]$Kind, [int]$Delta, [string]$RefSha) {
    return (Invoke-GitTextHash $Root "b3-pass-v1|step|$PrevChain|$Seq|$ScopeId|$Kind|$Delta|$RefSha`n" 'LEDGER_FAIL')
}

function Verify-LedgerPassChain([string]$Root, [hashtable]$Ledger) {
    if (-not $Ledger.HasPassChain) { return }
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
    foreach ($k in @('schema', 'base_sha', 'head_sha', 'target_ref', 'target_sha', 'snapshot_sha', 'size_class', 'normalized_legacy_size', 'risk_level', 'risk_signals', 'recommended_specialists', 'l1_specialists', 'l1_skip_rationale', 'contract_files', 'generated_files', 'max_concurrency', 'max_passes', 'passes_used', 'pass_chain', 'budget_status', 'cross_unit_status', 'cross_unit_tree_hash', 'unit_count')) {
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
    $hasChain = $meta.ContainsKey('pass_chain')
    if ($hasChain) {
        if ($meta['pass_chain'] -cnotmatch '^[0-9a-f]{40}$') { Fail 'LEDGER_CORRUPT: invalid pass_chain' 1 }
    } elseif ($passLog.Count -gt 0) {
        Fail 'LEDGER_CORRUPT: pass_chain missing with non-empty pass log' 1
    }
    if (-not $meta.ContainsKey('l1_specialists') -or $meta['l1_specialists'] -eq '') { $meta['l1_specialists'] = 'none' }
    if (-not $meta.ContainsKey('l1_skip_rationale') -or $meta['l1_skip_rationale'] -eq '') { $meta['l1_skip_rationale'] = 'none' }
    $normSize = Normalize-SizeClass $meta['size_class']
    if (-not $normSize) { Fail "LEDGER_CORRUPT: invalid size_class '$($meta['size_class'])'" 1 }
    if ([int]$meta['unit_count'] -ne $units.Count) { Fail 'LEDGER_CORRUPT: unit_count mismatch' 1 }
    $meta['HasPassChain'] = $hasChain
    $meta['Units'] = @($units)
    $meta['PassLog'] = $passLog
    return $meta
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
        $wRes = Invoke-GitCommand $Root (@('diff', '--no-renames', '--name-only', '--ignore-submodules=none', $GraphSha, '--') + $ProbePaths)
        if ($wRes.ExitCode -ne 0) { Fail 'CONTEXT_ERROR: git diff failed' 1 }
        $cRes = Invoke-GitCommand $Root (@('diff', '--no-renames', '--cached', '--name-only', '--ignore-submodules=none', $GraphSha, '--') + $ProbePaths)
        if ($cRes.ExitCode -ne 0) { Fail 'CONTEXT_ERROR: git diff --cached failed' 1 }
        $uRes = Invoke-GitCommand $Root (@('ls-files', '--others', '--exclude-standard', '--') + $ProbePaths)
        if ($uRes.ExitCode -ne 0) { Fail 'CONTEXT_ERROR: git ls-files failed' 1 }
        foreach ($rawOut in @($wRes.StdOut, $cRes.StdOut, $uRes.StdOut)) {
            foreach ($line in ($rawOut -split "\r?\n")) {
                $p = Normalize-PathValue ([string]$line)
                if (-not $p) { continue }
                if (Test-CheckpointPath $p) { continue }
                if ($IgnPaths -and (Test-PathMatch $p $IgnPaths)) { continue }
                return $false
            }
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
        $watched = @(Split-CsvList $WatchedPaths -AsPaths)
        if ($watched.Count -lt 1) { Fail 'FRESHNESS_FAIL: missing -WatchedPaths' 1 }
        $owned = @(Split-CsvList $OwnedFiles -AsPaths)
        $ignored = @(Split-CsvList $IgnoreDirtyPaths -AsPaths)

        $mbRes = Invoke-GitCommand $RepoRoot @('merge-base', '--is-ancestor', $TaskBaseSha, 'HEAD')
        if ($mbRes.ExitCode -ne 0) {
            Fail 'STALE: HEAD is not a descendant of task_base' 2
        }

        $committed = @(Invoke-GitLines $RepoRoot @('diff', '--no-renames', '--name-only', $ApproachAtSha, 'HEAD'))
        $committedHits = @($committed | Where-Object {
            (-not (Test-CheckpointPath $_)) -and (Test-PathMatch $_ $watched)
        } | Sort-Object -Unique)
        if ($committedHits.Count -gt 0) {
            Fail ("STALE: committed change in watched_paths (" + ($committedHits -join ', ') + ")") 2
        }

        $readOnlyWatched = @($watched | Where-Object { -not (Test-PathMatch $_ $owned) })
        if ($readOnlyWatched.Count -gt 0) {
            $wtDiff = @(Invoke-GitLines $RepoRoot @('diff', '--no-renames', '--name-only', $ApproachAtSha))
            $cached = @(Invoke-GitLines $RepoRoot @('diff', '--no-renames', '--cached', '--name-only'))
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

        $allowed = @(Split-CsvList $AllowedPaths -AsPaths)
        $staged = @(Invoke-GitLines $RepoRoot @('diff', '--no-renames', '--cached', '--name-only'))
        if ($staged.Count -lt 1) {
            Fail 'PRECOMMIT_FAIL: nothing staged' 1
        }

        $checkpointHits = @($staged | Where-Object {
            (Test-CheckpointPath $_) -or (($_ -match '^\.b3(/|$)') -and -not (Test-PathMatch $_ $allowed))
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
            $idxVsWt = @(Invoke-GitLines $RepoRoot (@('diff', '--no-renames', '--ignore-submodules=none', '--name-only', '--') + $staged))
            foreach ($p in $idxVsWt) { $wtMismatch.Add($p) }
            $stagedDel = @(Invoke-GitLines $RepoRoot @('diff', '--no-renames', '--cached', '--diff-filter=D', '--name-only'))
            foreach ($d in $stagedDel) {
                if ((Test-Path -LiteralPath (Join-Path $RepoRoot ($d -replace '/', '\'))) -and -not $wtMismatch.Contains($d)) {
                    $wtMismatch.Add($d)
                }
            }
            if ($wtMismatch.Count -gt 0) {
                $sortedMm = (Sort-Ordinal $wtMismatch.ToArray()) -join ', '
                Fail "PRECOMMIT_FAIL: staged content differs from working tree ($sortedMm)" 1
            }

            $ignored = @(Split-CsvList $IgnoreDirtyPaths -AsPaths)
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
                Invoke-GitLines $RepoRoot @('diff', '--no-renames', '--ignore-submodules=none', '--name-only')
            } else {
                Invoke-GitLines $RepoRoot (@('diff', '--no-renames', '--ignore-submodules=none', '--name-only', '--') + $recScopePaths)
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
        $ignored = @(Split-CsvList $IgnoreDirtyPaths -AsPaths)
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
            $deltaRes = Invoke-GitCommand $RepoRoot @('diff', '--no-renames', '--name-only', $prevTrim, $deltaEnd, '--')
            if ($deltaRes.ExitCode -ne 0) {
                $detail = if ($deltaRes.StdErr.Trim()) { $deltaRes.StdErr.Trim() } else { $deltaRes.StdOut.Trim() }
                Fail ("DIFF_SCOPE_FAIL: git diff -PrevSha failed: $detail") 1
            }
            $deltaFiles = New-Object System.Collections.Generic.List[string]
            foreach ($row in ($deltaRes.StdOut -split "\r?\n")) {
                $dp = Normalize-PathValue ([string]$row)
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
        $allowed = @(Split-CsvList $AllowedPaths -AsPaths)
        $ignored = @(Split-CsvList $IgnoreDirtyPaths -AsPaths)
        $obsoletesList = @(Split-CsvList $Obsoletes)
        $scopeTarget = Resolve-ScopeTargetAndBase $RepoRoot $TargetRef $BaseSha $ignored 'MECHANICAL_FAIL' 'object'
        $targetTrim = $scopeTarget.TargetRef
        $targetCommitSha = $scopeTarget.TargetCommitSha
        $resolvedBase = $scopeTarget.BaseSha

        $chArgs = if ($targetTrim) {
            @('diff', '--no-renames', '--name-only', $resolvedBase, $targetCommitSha, '--')
        } else {
            @('diff', '--no-renames', '--name-only', $resolvedBase, '--')
        }
        $chRes = Invoke-GitCommand $RepoRoot $chArgs
        if ($chRes.ExitCode -ne 0) {
            $detail = if ($chRes.StdErr.Trim()) { $chRes.StdErr.Trim() } else { $chRes.StdOut.Trim() }
            Fail ("MECHANICAL_FAIL: git diff --name-only failed: $detail") 1
        }
        $nonDelArgs = if ($targetTrim) {
            @('diff', '--no-renames', '--diff-filter=d', '--name-only', $resolvedBase, $targetCommitSha, '--')
        } else {
            @('diff', '--no-renames', '--diff-filter=d', '--name-only', $resolvedBase, '--')
        }
        $nonDelRes = Invoke-GitCommand $RepoRoot $nonDelArgs
        if ($nonDelRes.ExitCode -ne 0) {
            $detail = if ($nonDelRes.StdErr.Trim()) { $nonDelRes.StdErr.Trim() } else { $nonDelRes.StdOut.Trim() }
            Fail ("MECHANICAL_FAIL: git diff --diff-filter=d failed: $detail") 1
        }
        $untracked = if ($targetTrim) { @() } else { @(Invoke-GitLines $RepoRoot @('ls-files', '--others', '--exclude-standard')) }

        $allChanged = New-Object System.Collections.Generic.List[string]
        foreach ($row in ($chRes.StdOut -split "\r?\n")) {
            $p = Normalize-PathValue ([string]$row)
            if (-not $p -or (Test-CheckpointPath $p) -or (Test-PathMatch $p $ignored)) { continue }
            if (-not $allChanged.Contains($p)) { $allChanged.Add($p) }
        }
        foreach ($u in $untracked) {
            if (-not $u -or (Test-CheckpointPath $u) -or (Test-PathMatch $u $ignored)) { continue }
            if (-not $allChanged.Contains($u)) { $allChanged.Add($u) }
        }

        $nonDelChanged = New-Object System.Collections.Generic.List[string]
        foreach ($row in ($nonDelRes.StdOut -split "\r?\n")) {
            $p = Normalize-PathValue ([string]$row)
            if (-not $p -or (Test-CheckpointPath $p) -or (Test-PathMatch $p $ignored)) { continue }
            if (-not $nonDelChanged.Contains($p)) { $nonDelChanged.Add($p) }
        }
        foreach ($u in $untracked) {
            if (-not $u -or (Test-CheckpointPath $u) -or (Test-PathMatch $u $ignored)) { continue }
            if (-not $nonDelChanged.Contains($u)) { $nonDelChanged.Add($u) }
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
            @('diff', '--no-renames', '-U0', $resolvedBase, $targetCommitSha, '--')
        } else {
            @('diff', '--no-renames', '-U0', $resolvedBase, '--')
        }
        $dlRes = Invoke-GitCommand $RepoRoot $dlArgs
        if ($dlRes.ExitCode -ne 0) {
            $detail = if ($dlRes.StdErr.Trim()) { $dlRes.StdErr.Trim() } else { $dlRes.StdOut.Trim() }
            Fail ("MECHANICAL_FAIL: git diff -U0 failed: $detail") 1
        }

        $curFile = ''
        $curLine = 0
        $skipFile = $true
        $inHunk = $false
        foreach ($rawLine in ($dlRes.StdOut -split "\r?\n")) {
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
                    $leftoverHits.Add("${curFile}:${curLine}:${tag}")
                }
                if (-not (Test-TestPath $curFile) -and (Find-DestructiveSql $body) -and $sqlHitCount -lt 10) {
                    $safetyHits.Add("destructive_sql:${curFile}:${curLine}")
                    $sqlHitCount++
                }
                $curLine++
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

        $delTarget = if ($targetTrim) { $targetCommitSha } else { New-WorkingTreeOid $RepoRoot 'MECHANICAL_FAIL' -ExcludeSensitive }
        $delArgs = @('diff', '-M', '--diff-filter=D', '--name-only', $resolvedBase, $delTarget, '--')
        $delRes = Invoke-GitCommand $RepoRoot $delArgs
        if ($delRes.ExitCode -ne 0) {
            $detail = if ($delRes.StdErr.Trim()) { $delRes.StdErr.Trim() } else { $delRes.StdOut.Trim() }
            Fail ("MECHANICAL_FAIL: git diff --diff-filter=D failed: $detail") 1
        }
        $deletedList = New-Object System.Collections.Generic.List[string]
        foreach ($row in ($delRes.StdOut -split "\r?\n")) {
            $dp = Normalize-PathValue ([string]$row)
            if (-not $dp -or (Test-CheckpointPath $dp) -or (Test-PathMatch $dp $ignored) -or (Test-NoiseFile $dp)) { continue }
            if (-not $deletedList.Contains($dp)) { $deletedList.Add($dp) }
        }
        if ($deletedList.Count -ge 10 -and -not $AllowMassDelete) {
            $safetyHits.Add("mass_delete:$($deletedList.Count)f")
        }

        $obsoleteHits = New-Object System.Collections.Generic.List[string]
        foreach ($tok in $obsoletesList) {
            $normTok = Normalize-PathValue $tok
            $existsPath = $false
            if ($normTok) {
                if ($targetTrim) {
                    $ceRes = Invoke-GitCommand $RepoRoot @('cat-file', '-e', "${targetCommitSha}:${normTok}")
                    $existsPath = ($ceRes.ExitCode -eq 0)
                } else {
                    $existsPath = Test-Path -LiteralPath (Join-Path $RepoRoot ($normTok -replace '/', '\'))
                }
            }
            $grepArgs = if ($targetTrim) {
                @('grep', '-l', '-F', '-e', $tok, $targetCommitSha, '--', '.', ':(exclude).b3/ship', ':(exclude).b3/research-ship', ':(exclude).b3/autodev')
            } else {
                @('grep', '--untracked', '-l', '-F', '-e', $tok, '--', '.', ':(exclude).b3/ship', ':(exclude).b3/research-ship', ':(exclude).b3/autodev')
            }
            $grepRes = Invoke-GitCommand $RepoRoot $grepArgs
            if ($grepRes.ExitCode -gt 1) {
                Fail "MECHANICAL_FAIL: git grep failed for obsolete '$tok'" 1
            }
            $grepCount = 0
            if ($grepRes.ExitCode -eq 0) {
                $obsPrefix = "${targetCommitSha}:"
                foreach ($row in ($grepRes.StdOut -split "\r?\n")) {
                    $gp = ([string]$row).Trim()
                    if (-not $gp) { continue }
                    if ($targetTrim -and $gp.StartsWith($obsPrefix)) { $gp = $gp.Substring($obsPrefix.Length) }
                    $gp = Normalize-PathValue $gp
                    if (-not $gp -or (Test-CheckpointPath $gp) -or ($ignored -and (Test-PathMatch $gp $ignored))) { continue }
                    $grepCount++
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

        $scOut = if ($scopeCreep.Count -gt 0) { (Sort-Ordinal $scopeCreep.ToArray()) -join ',' } else { 'none' }
        $loOut = if ($leftoverHits.Count -gt 0) { $leftoverHits -join ',' } else { 'none' }
        $obOut = if ($obsoleteHits.Count -gt 0) { (Sort-Ordinal $obsoleteHits.ToArray()) -join ',' } else { 'none' }
        $sfOut = if ($safetyHits.Count -gt 0) { (Sort-Ordinal $safetyHits.ToArray()) -join ',' } else { 'none' }

        Write-Output "scope_creep=$scOut"
        Write-Output "leftovers=$loOut"
        Write-Output "obsolete_hits=$obOut"
        Write-Output "safety_hits=$sfOut"
        if ($scOut -eq 'none' -and $loOut -eq 'none' -and $obOut -eq 'none' -and $sfOut -eq 'none') {
            Write-Output 'MECHANICAL_OK'
            exit 0
        }
        Write-Output 'MECHANICAL_FINDINGS'
        exit 2
    }

    'check-wave' {
        if (-not $WaveSpecs -or -not $WaveSpecs.Trim()) { Fail 'WAVE_FAIL: missing -WaveSpecs' 1 }

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

        $taskOrder = New-Object System.Collections.Generic.List[string]
        $taskPaths = @{}
        $totalPaths = 0

        foreach ($entry in ($WaveSpecs -split ';')) {
            $trimEntry = $entry.Trim()
            if (-not $trimEntry) { continue }
            $eqIdx = $trimEntry.IndexOf('=')
            if ($eqIdx -lt 0) { Fail "WAVE_FAIL: invalid entry '$trimEntry' (expected TaskId=path1,path2)" 1 }
            $tid = $trimEntry.Substring(0, $eqIdx).Trim()
            $rawCsv = $trimEntry.Substring($eqIdx + 1)
            if (-not $tid) { Fail "WAVE_FAIL: empty task id in '$trimEntry'" 1 }
            if ($taskPaths.ContainsKey($tid)) { Fail "WAVE_FAIL: duplicate task id '$tid'" 1 }
            $paths = @(Split-CsvList $rawCsv -AsPaths)
            if ($paths.Count -lt 1) { Fail "WAVE_FAIL: task '$tid' has no owned paths" 1 }
            $taskOrder.Add($tid)
            $taskPaths[$tid] = $paths
            $totalPaths += $paths.Count
        }
        if ($taskOrder.Count -lt 1) { Fail 'WAVE_FAIL: no tasks in -WaveSpecs' 1 }

        $readPaths = @{}
        if ($WaveReads -and $WaveReads.Trim()) {
            foreach ($entry in ($WaveReads -split ';')) {
                $trimEntry = $entry.Trim()
                if (-not $trimEntry) { continue }
                $eqIdx = $trimEntry.IndexOf('=')
                if ($eqIdx -lt 0) { Fail "WAVE_FAIL: invalid WaveReads entry '$trimEntry' (expected TaskId=path1,path2)" 1 }
                $rtid = $trimEntry.Substring(0, $eqIdx).Trim()
                $rCsv = $trimEntry.Substring($eqIdx + 1)
                if (-not $rtid) { Fail "WAVE_FAIL: empty task id in WaveReads '$trimEntry'" 1 }
                if ($readPaths.ContainsKey($rtid)) { Fail "WAVE_FAIL: duplicate task id '$rtid' in WaveReads" 1 }
                $rArr = @(Split-CsvList $rCsv -AsPaths)
                $readPaths[$rtid] = $rArr
            }
        }

        $conflicts = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $taskOrder.Count; $i++) {
            for ($j = $i + 1; $j -lt $taskOrder.Count; $j++) {
                $ti = $taskOrder[$i]
                $tj = $taskOrder[$j]
                foreach ($pi in $taskPaths[$ti]) {
                    foreach ($pj in $taskPaths[$tj]) {
                        if ($pi -eq $pj) {
                            $conflicts.Add("${pi}(${ti},${tj})")
                        } elseif ($pi -eq '.' -or $pj -eq '.' -or $pi.StartsWith("$pj/") -or $pj.StartsWith("$pi/")) {
                            $conflicts.Add("${pi}<->${pj}(${ti},${tj})")
                        }
                    }
                }
            }
        }

        foreach ($ti in $taskOrder) {
            foreach ($tj in @($readPaths.Keys)) {
                if ($ti -ceq $tj) { continue }
                foreach ($pi in $taskPaths[$ti]) {
                    foreach ($rj in $readPaths[$tj]) {
                        if ($pi -eq $rj) {
                            $conflicts.Add("rw:${pi}(${ti}->${tj})")
                        } elseif ($pi -eq '.' -or $rj -eq '.' -or $pi.StartsWith("$rj/") -or $rj.StartsWith("$pi/")) {
                            $conflicts.Add("rw:${pi}<->${rj}(${ti}->${tj})")
                        }
                    }
                }
            }
        }

        if ($conflicts.Count -gt 0) {
            $sortedConflicts = (Sort-Ordinal $conflicts.ToArray()) -join ', '
            Fail "WAVE_CONFLICT: $sortedConflicts" 2
        }
        Write-Output "WAVE_OK: disjoint ($($taskOrder.Count) tasks, $totalPaths paths)"
        exit 0
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
        $ignored = @(Split-CsvList $IgnoreDirtyPaths -AsPaths)
        $relArr = @(Split-CsvList $RelevantPaths -AsPaths)

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
        Push-Location $RepoRoot
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $rawOut = & $psExe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encCmd 2>&1
            $cmdExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prevEap
            Pop-Location
        }
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
            "command=$singleCmd",
            "log_path=$logDisp",
            "timestamp_utc=$tsUtc"
        ) -join "`n"
        Write-AtomicLfFile $fullReceipt "$receiptBody`n"

        $shortTree = $fp.TreeHash.Substring(0, 12)
        if ($cmdExit -eq 0) {
            Write-Output "VERIFY_PASS: exit=0 tree=$shortTree receipt=$receiptRel"
            exit 0
        }
        Write-Output "VERIFY_FAIL: exit=$cmdExit tree=$shortTree receipt=$receiptRel log=$logDisp"
        $cap = [Math]::Min(35, $outLines.Count)
        for ($i = 0; $i -lt $cap; $i++) {
            Write-Output $outLines[$i]
        }
        exit 1
    }

    'verify-check' {
        $ignored = @(Split-CsvList $IgnoreDirtyPaths -AsPaths)
        $res = Test-VerifyReceipt $RepoRoot $ReceiptPath $ignored $ExpectedCmd $RelevantPaths
        Write-Output $res.Message
        exit $res.Code
    }

    'symbol-check' {
        $ignored = @(Split-CsvList $IgnoreDirtyPaths -AsPaths)
        $scopeTarget = Resolve-ScopeTargetAndBase $RepoRoot $TargetRef $BaseSha $ignored 'SYMBOL_FAIL' 'object'
        $targetTrim = $scopeTarget.TargetRef
        $targetCommitSha = $scopeTarget.TargetCommitSha
        $resolvedBase = $scopeTarget.BaseSha

        $dlArgs = if ($targetTrim) {
            @('diff', '--no-renames', '-U0', $resolvedBase, $targetCommitSha, '--')
        } else {
            @('diff', '--no-renames', '-U0', $resolvedBase, '--')
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
        if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) {
            Fail "WORKTREE_UNSAFE: missing_repo_root($RepoRoot)" 2
        }
        $topRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--show-toplevel')
        $topRaw = $topRes.StdOut.Trim()
        $headRes = Invoke-GitCommand $RepoRoot @('rev-parse', 'HEAD')
        $headRaw = $headRes.StdOut.Trim()
        if ($topRes.ExitCode -ne 0 -or -not $topRaw) {
            Fail 'WORKTREE_UNSAFE: not_a_git_repo' 2
        }
        if ($headRes.ExitCode -ne 0 -or $headRaw -notmatch '^[0-9a-f]{40}$') {
            Fail 'WORKTREE_UNSAFE: unborn_or_invalid_head' 2
        }
        $actualRootNorm = Normalize-PathValue $topRaw

        $midOp = Test-GitMidOperation $RepoRoot
        if ($midOp) {
            Fail "WORKTREE_UNSAFE: git_op_in_progress($midOp)" 2
        }

        if ($ExpectedRoot -and $ExpectedRoot.Trim()) {
            $expDir = $ExpectedRoot.Trim()
            if (-not (Test-Path -LiteralPath $expDir -PathType Container)) {
                Fail "WORKTREE_UNSAFE: expected_root_missing($expDir)" 2
            }
            $expTopRes = Invoke-GitCommand $expDir @('rev-parse', '--show-toplevel')
            $expTopRaw = $expTopRes.StdOut.Trim()
            if ($expTopRes.ExitCode -ne 0 -or -not $expTopRaw) {
                Fail "WORKTREE_UNSAFE: expected_root_not_git($expDir)" 2
            }
            $expTopNorm = Normalize-PathValue $expTopRaw
            $actCommon = Get-CanonicalGitCommonDir $RepoRoot
            $expCommon = Get-CanonicalGitCommonDir $expDir

            $isWin = ([IO.Path]::DirectorySeparatorChar -eq '\')
            $topSame = if ($isWin) { $actualRootNorm -ieq $expTopNorm } else { $actualRootNorm -ceq $expTopNorm }
            $commonSame = $false
            if ($actCommon -and $expCommon) {
                $commonSame = if ($isWin) { $actCommon -ieq $expCommon } else { $actCommon -ceq $expCommon }
            }
            if (-not $topSame -and -not $commonSame) {
                Fail "WORKTREE_UNSAFE: root_mismatch(expected=$expTopNorm,actual=$actualRootNorm)" 2
            }
        }

        if ($ExpectedBaseSha -and $ExpectedBaseSha.Trim()) {
            $expSha = $ExpectedBaseSha.Trim()
            if ($headRaw -cne $expSha) {
                Fail "WORKTREE_UNSAFE: base_mismatch(expected=$expSha,actual=$headRaw)" 2
            }
        }

        Write-Output "WORKTREE_OK: root=$actualRootNorm head=$headRaw"
        exit 0
    }

    'review-inventory' {
        $ignored = @(Split-CsvList $IgnoreDirtyPaths -AsPaths)
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
        $ignored = @(Split-CsvList $IgnoreDirtyPaths -AsPaths)

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
            $scopeTarget = Resolve-ScopeTargetAndBase $RepoRoot $TargetRef $BaseSha $ignored 'LEDGER_FAIL' 'commit'
            $targetTrim = $scopeTarget.TargetRef
            $targetCommitSha = $scopeTarget.TargetCommitSha
            $resolvedBase = $scopeTarget.BaseSha
            $headSha = if ($targetCommitSha) { $targetCommitSha } else { Assert-ValidGitRev $RepoRoot 'HEAD' 'commit' 'LEDGER_FAIL' 'HEAD' }

            $inv = Invoke-BuildInventory $RepoRoot $resolvedBase $targetCommitSha $ignored $MaxConcurrency 'LEDGER_FAIL'
            if ($inv.IsEmpty) { Fail 'LEDGER_FAIL: EMPTY_DIFF' 2 }
            if ($inv.PartitionError) { Fail $inv.PartitionError 2 }
            $effectiveMaxPasses = if ($maxPassesExplicit) { $MaxPasses } else { Get-DefaultMaxPasses $inv.SizeClass }

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
            $passesUsedExplicit = $PSBoundParameters.ContainsKey('PassesUsed')
            if ($passesUsedExplicit -and $PassesUsed -lt 0) {
                Fail 'LEDGER_FAIL: -PassesUsed must be non-negative' 1
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

            if (-not $ledger.HasPassChain) {
                $bootChain = Get-InitialPassChain $RepoRoot $ledger['base_sha']
                $bootList = New-Object System.Collections.Generic.List[hashtable]
                if ($curPasses -gt 0) {
                    $bootChain = Step-PassChain $RepoRoot $bootChain 1 'legacy' 'bootstrap' $curPasses 'none'
                    [void]$bootList.Add(@{ seq = 1; scope = 'legacy'; kind = 'bootstrap'; delta = $curPasses; ref_sha = 'none'; chain_hash = $bootChain })
                }
                $ledger['pass_chain'] = $bootChain
                $ledger['HasPassChain'] = $true
                $ledger['PassLog'] = $bootList
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
            } elseif ($maxPassesExplicit -and $ledger['budget_status'] -ceq 'EXHAUSTED' -and $newPasses -le $effMaxP) {
                $ledger['budget_status'] = 'OK'
            }
            Write-AtomicLfFile $ledgerFull (Serialize-ReviewLedger $ledger)
            Write-Output "LEDGER_UPDATED: path=$ledgerRel"
            exit 0
        }

        # check
        Verify-LedgerPassChain $RepoRoot $ledger
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
            $trChkRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--verify', '--quiet', "${targetRefVal}^{commit}")
            $trChkSha = $trChkRes.StdOut.Trim()
            if ($trChkRes.ExitCode -ne 0 -or $trChkSha -cnotmatch '^[0-9a-f]{40}$') {
                Fail "LEDGER_STALE: target_ref '$targetRefVal' cannot be resolved" 2
            }
            if ($trChkSha -cne $targetCommitSha) {
                Fail "LEDGER_STALE: target_ref '$targetRefVal' moved (${targetCommitSha}->${trChkSha})" 2
            }
        }

        $liveScope = Invoke-CollectScopeData $RepoRoot $ledger['base_sha'] $targetCommitSha $ignored 'LEDGER_FAIL'
        if ($liveScope.ReviewFiles.Count -eq 0 -and $liveScope.NoiseFiles.Count -eq 0) {
            Fail 'LEDGER_INCOMPLETE: empty diff target' 2
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
        foreach ($u in $ledger.Units) {
            $uid = $u.unit_id
            if ($u.status -ceq 'BLOCKED') { Fail "LEDGER_BLOCKED: unit $uid" 2 }
            if ($u.status -ceq 'STALE') { Fail "LEDGER_STALE: unit $uid" 2 }
            if ($u.status -cne 'REVIEWED') { Fail "LEDGER_INCOMPLETE: unit $uid status=$($u.status)" 2 }
            if ($u.findings -cmatch '(^|[,:; ])(OPEN|FIXED)($|[,:; ])') {
                Fail "LEDGER_INCOMPLETE: unresolved findings in $uid ($($u.findings))" 2
            }

            $uFiles = @(Split-CsvList $u.files_csv -AsPaths)
            $liveURisk = Eval-RiskForSubset $uFiles $liveScope.FileSignals $liveScope.FileLines
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
                    } else {
                        $ratTrim = if ($u.rationale) { $u.rationale.Trim() } else { '' }
                        if ($ratTrim -ceq 'none' -or $ratTrim.Length -lt 5) {
                            Fail "LEDGER_INCOMPLETE: missing specialist ($($missingSp -join ',')) or rationale on $uid" 2
                        }
                    }
                }
            }

            $curUHash = Get-ScopePathsTreeHash $RepoRoot $targetCommitSha ($uFiles + $liveContracts) $ignored
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
                $vr = Test-VerifyReceipt $RepoRoot $u.verify_receipt $ignored '' $u.files_csv
                if ($vr.Code -eq 2) { Fail "LEDGER_STALE: unit $uid receipt invalid ($($vr.Message))" 2 }
                if ($vr.Code -ne 0) { Fail "LEDGER_INCOMPLETE: unit $uid receipt invalid ($($vr.Message))" 2 }
            }
        }

        if ($normSize -in @('L', 'XL', 'XXL') -and $unitCount -gt 1) {
            if ($ledger['cross_unit_status'] -ceq 'BLOCKED') { Fail 'LEDGER_BLOCKED: cross_unit blocked' 2 }
            if ($ledger['cross_unit_status'] -ceq 'STALE') { Fail 'LEDGER_STALE: cross_unit stale' 2 }
            if ($ledger['cross_unit_status'] -cne 'REVIEWED') { Fail "LEDGER_INCOMPLETE: cross_unit_status=$($ledger['cross_unit_status'])" 2 }
            $cuPaths = if ($liveContracts.Count -gt 0) { $liveContracts } else { $liveScope.ReviewFiles }
            $curCuHash = Get-ScopePathsTreeHash $RepoRoot $targetCommitSha $cuPaths $ignored
            if ($curCuHash -cne $ledger['cross_unit_tree_hash']) {
                Fail 'LEDGER_STALE: cross_unit invalidated' 2
            }
        }

        $normTag = if ($origRawSize -cne $normSize) { " normalized_from=$origRawSize" } else { '' }
        Write-Output "LEDGER_GATE_PASS: size=$normSize risk=$($ledger['risk_level']) units=$unitCount/$unitCount cross_unit=$($ledger['cross_unit_status'])${normTag}"
        exit 0
    }

    'evidence-check' {
        $mSpec = Test-ContainedRepoPath $RepoRoot $ManifestPath
        if (-not $mSpec) {
            Fail 'EVIDENCE_MISSING: invalid manifest path' 1
        }
        $srcList = @(Split-CsvList $SourcePaths -AsPaths)

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

        if ($PostMerge) {
            if ($prSt -cne 'MERGED') { Fail "POST_MERGE_FAILED: pr_state=$prSt" 1 }
            $mSha = if ($MergedSha) { $MergedSha.Trim() } else { '' }
            $mRef = if ($MainRef) { $MainRef.Trim() } else { 'HEAD' }
            if (-not $mSha -or $mSha.StartsWith('-') -or -not $mRef -or $mRef.StartsWith('-')) {
                Fail 'POST_MERGE_FAILED: invalid_ref' 1
            }
            $mergedRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--verify', '--quiet', "${mSha}^{commit}")
            $resMerged = $mergedRes.StdOut.Trim()
            $mainRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--verify', '--quiet', "${mRef}^{commit}")
            $resMain = $mainRes.StdOut.Trim()
            if ($mergedRes.ExitCode -ne 0 -or $resMerged -notmatch '^[0-9a-f]{40}$' -or $mainRes.ExitCode -ne 0 -or $resMain -notmatch '^[0-9a-f]{40}$') {
                Fail 'POST_MERGE_FAILED: unresolvable_commit' 1
            }
            $ancRes = Invoke-GitCommand $RepoRoot @('merge-base', '--is-ancestor', $resMerged, $resMain)
            if ($ancRes.ExitCode -ne 0) {
                Fail "POST_MERGE_FAILED: sha_not_in_main(sha=$resMerged,main_ref=$mRef)" 1
            }
            Write-Output "POST_MERGE_VERIFIED: sha=$resMerged main_ref=$mRef runtime_served=NOT_VERIFIED deployed=NOT_VERIFIED"
            exit 0
        }

        $autoMerge = 'disabled'
        $protectedPaths = @()
        $allowProtected = $false
        $requireCi = $true
        $requireReview = $true

        $polFileFull = $null
        if ($PolicyPath -and $PolicyPath.Trim()) {
            $pSpec = Test-ContainedRepoPath $RepoRoot $PolicyPath
            if (-not $pSpec) { Fail 'MERGE_BLOCKED: invalid_policy_path' 1 }
            if (-not (Test-Path -LiteralPath $pSpec.Full -PathType Leaf)) { Fail 'MERGE_BLOCKED: missing_policy' 1 }
            $polFileFull = $pSpec.Full
        } else {
            $defPolRaw = Join-Path $RepoRoot '.b3\research-policy.json'
            $defPolItem = Get-Item -LiteralPath $defPolRaw -Force -ErrorAction SilentlyContinue
            if ($defPolItem) {
                $defSpec = Test-ContainedRepoPath $RepoRoot '.b3/research-policy.json'
                if (-not $defSpec) { Fail 'MERGE_BLOCKED: invalid_policy_path' 1 }
                if (-not (Test-Path -LiteralPath $defSpec.Full -PathType Leaf)) { Fail 'MERGE_BLOCKED: invalid_policy_path' 1 }
                $polFileFull = $defSpec.Full
            }
        }

        if ($polFileFull) {
            try {
                $polObj = (Get-Content -LiteralPath $polFileFull -Raw | ConvertFrom-Json)
            } catch {
                Fail 'MERGE_BLOCKED: invalid_policy_json' 1
            }
            if ($null -eq $polObj -or ($polObj -isnot [System.Management.Automation.PSCustomObject])) {
                Fail 'MERGE_BLOCKED: invalid_policy_json' 1
            }
            $amProp = $polObj.PSObject.Properties['auto_merge']
            if ($null -ne $amProp) {
                if ($null -eq $amProp.Value -or ($amProp.Value -isnot [string])) { Fail 'MERGE_BLOCKED: invalid_policy_json' 1 }
                $amVal = $amProp.Value.Trim()
                if ($amVal -cnotin @('disabled', 'authorized')) { Fail "MERGE_BLOCKED: invalid_auto_merge=$amVal" 1 }
                $autoMerge = $amVal
            }
            $apProp = $polObj.PSObject.Properties['allow_protected_paths']
            if ($null -ne $apProp) {
                if ($apProp.Value -isnot [bool]) { Fail 'MERGE_BLOCKED: invalid_policy_json' 1 }
                $allowProtected = [bool]$apProp.Value
            }
            $rcProp = $polObj.PSObject.Properties['require_ci']
            if ($null -ne $rcProp) {
                if ($rcProp.Value -isnot [bool]) { Fail 'MERGE_BLOCKED: invalid_policy_json' 1 }
                $requireCi = [bool]$rcProp.Value
            }
            $rrProp = $polObj.PSObject.Properties['require_review']
            if ($null -ne $rrProp) {
                if ($rrProp.Value -isnot [bool]) { Fail 'MERGE_BLOCKED: invalid_policy_json' 1 }
                $requireReview = [bool]$rrProp.Value
            }
            $ppProp = $polObj.PSObject.Properties['protected_paths']
            if ($null -ne $ppProp) {
                if ($null -eq $ppProp.Value -or ($ppProp.Value -isnot [array])) { Fail 'MERGE_BLOCKED: invalid_policy_json' 1 }
                $ppList = New-Object System.Collections.Generic.List[string]
                foreach ($pp in $ppProp.Value) {
                    if ($null -eq $pp -or ($pp -isnot [string]) -or ($pp -match '[\r\n\0]')) {
                        Fail 'MERGE_BLOCKED: invalid_policy_json' 1
                    }
                    $np = Normalize-PathValue $pp
                    if ($np) { $ppList.Add($np) }
                }
                $protectedPaths = @($ppList)
            }
        }

        if ($govSt -cne 'CLEAR') { Fail "MERGE_BLOCKED: governance=$govSt" 1 }

        $changedArr = @(Split-CsvList $ChangedPaths -AsPaths)
        if ($protectedPaths.Count -gt 0 -and -not $allowProtected -and $changedArr.Count -gt 0) {
            $protHits = New-Object System.Collections.Generic.List[string]
            foreach ($cp in $changedArr) {
                if (Test-PathMatch $cp $protectedPaths) {
                    if (-not $protHits.Contains($cp)) { $protHits.Add($cp) }
                    continue
                }
                foreach ($pp in $protectedPaths) {
                    if ($cp -ceq '.' -or $pp.StartsWith("$cp/")) {
                        if (-not $protHits.Contains($cp)) { $protHits.Add($cp) }
                        break
                    }
                }
            }
            if ($protHits.Count -gt 0) {
                Fail ("MERGE_BLOCKED: protected_paths=" + ((Sort-Ordinal $protHits.ToArray()) -join ',')) 1
            }
        }

        if ($BlockingFindings -gt 0) { Fail "MERGE_BLOCKED: blocking_findings=$BlockingFindings" 1 }
        if ($requireCi -and $ciSt -cne 'PASS') { Fail "MERGE_BLOCKED: ci_status=$ciSt" 1 }
        if ($requireReview -and $revSt -cne 'PASS') { Fail "MERGE_BLOCKED: review_status=$revSt" 1 }
        if ($prSt -cne 'OPEN') { Fail "MERGE_BLOCKED: pr_state=$prSt" 1 }
        if ($protectedPaths.Count -gt 0 -and -not $allowProtected -and $changedArr.Count -eq 0) {
            Fail 'MERGE_BLOCKED: missing_changed_paths' 1
        }
        if ($autoMerge -cne 'authorized') { Fail 'PR_READY: auto_merge=disabled' 2 }

        Write-Output 'MERGE_AUTHORIZED: auto_merge=authorized ci=PASS review=PASS governance=CLEAR'
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

        $anchorStatus = 'FRESH'
        if (($reasons -ccontains 'head_diverged') -or ($reasons -ccontains 'anchor_scope_changed') -or ($reasons -ccontains 'anchor_changed')) {
            $anchorStatus = 'STALE'
        }

        if ($reasons.Count -gt 0) {
            $reasonCsv = $reasons.ToArray() -join ','
            Fail "CONTEXT_STALE: scope=$($kv['scope_id']) reasons=$reasonCsv anchor_status=$anchorStatus graph_index=$graphIndexStatus live_lsp_eligible=true" 2
        }

        Write-Output "CONTEXT_FRESH: scope=$($kv['scope_id']) head=$liveHeadSha anchor_status=FRESH graph_index=$graphIndexStatus live_lsp_eligible=true"
        exit 0
    }
}
