param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('fingerprint', 'check-freshness', 'precommit', 'snapshot', 'diff-scope', 'mechanical-check', 'check-wave', 'new-run', 'resolve-run', 'list-runs', 'prune')]
    [string]$Command,
    [string]$DependsOn = '',
    [string]$Scope = '',
    [string[]]$Criteria = @(),
    [string]$RepoRoot = '.',
    [string]$ApproachAtSha = '',
    [string]$TaskBaseSha = '',
    [string]$BaseSha = '',
    [string]$PrevSha = '',
    [string]$WatchedPaths = '',
    [string]$OwnedFiles = '',
    [string]$IgnoreDirtyPaths = '',
    [string]$AllowedPaths = '',
    [string]$Obsoletes = '',
    [string]$WaveSpecs = '',
    [string]$Slug = '',
    [string]$Timestamp = '',
    [string]$RunId = '',
    [int]$Keep = 10
)

$ErrorActionPreference = 'Stop'
$RepoRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RepoRoot)

function Fail([string]$Message, [int]$Code = 1) {
    Write-Output $Message
    exit $Code
}

function Normalize-PathValue([string]$PathValue) {
    $norm = ($PathValue.Trim() -replace '\\', '/') -replace '^\./', ''
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

function Test-PathMatch([string]$Candidate, [string[]]$Patterns) {
    foreach ($p in $Patterns) {
        if ($Candidate -eq $p) { return $true }
        if ($p -and $Candidate.StartsWith("$p/")) { return $true }
    }
    return $false
}

function Invoke-GitLines([string]$Root, [string[]]$GitArgs) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & git -C $Root @GitArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($code -ne 0) {
        $detail = ($out | Out-String).Trim()
        Fail "GIT_ERROR: git $($GitArgs -join ' ') failed: $detail" 1
    }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($out)) {
        if ($line -is [System.Management.Automation.ErrorRecord]) { continue }
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

function Get-CurrentRunId([string]$AutodevDir) {
    $curFile = Join-Path $AutodevDir 'CURRENT'
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

        $prevMb = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & git -C $RepoRoot merge-base --is-ancestor $TaskBaseSha HEAD 2>$null
            $mbCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prevMb
        }
        if ($mbCode -ne 0) {
            Fail 'STALE: HEAD is not a descendant of task_base' 2
        }

        $committed = @(Invoke-GitLines $RepoRoot @('diff', '--no-renames', '--name-only', $ApproachAtSha, 'HEAD'))
        $committedHits = @($committed | Where-Object {
            ($_ -notmatch '^\.b3/autodev(/|$)') -and (Test-PathMatch $_ $watched)
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
            foreach ($p in @($wtDiff + $cached + $untracked)) {
                if (-not $p) { continue }
                if ($p -match '^\.b3/autodev(/|$)') { continue }
                if (Test-PathMatch $p $ignored) { continue }
                if (-not $uncommitted.Contains($p)) { $uncommitted.Add($p) }
            }

            $roHits = @($uncommitted | Where-Object { Test-PathMatch $_ $readOnlyWatched } | Sort-Object -Unique)
            if ($roHits.Count -gt 0) {
                Fail ("STALE: uncommitted change in read_only_deps (" + ($roHits -join ', ') + ")") 2
            }
        }

        Write-Output 'FRESH'
        exit 0
    }

    'precommit' {
        $allowed = @(Split-CsvList $AllowedPaths -AsPaths)
        $staged = @(Invoke-GitLines $RepoRoot @('diff', '--no-renames', '--cached', '--name-only'))
        if ($staged.Count -lt 1) {
            Fail 'PRECOMMIT_FAIL: nothing staged' 1
        }

        $checkpointHits = @($staged | Where-Object {
            ($_ -match '^\.b3/autodev(/|$)') -or (($_ -match '^\.b3(/|$)') -and -not (Test-PathMatch $_ $allowed))
        })
        if ($checkpointHits.Count -gt 0) {
            Fail ("PRECOMMIT_FAIL: checkpoint staged (" + ($checkpointHits -join ', ') + ")") 1
        }

        if ($allowed.Count -lt 1) {
            Fail 'PRECOMMIT_FAIL: missing -AllowedPaths' 1
        }
        $undeclared = @($staged | Where-Object { -not (Test-PathMatch $_ $allowed) })
        if ($undeclared.Count -gt 0) {
            Fail ("PRECOMMIT_FAIL: undeclared staged path (" + ($undeclared -join ', ') + ")") 1
        }

        Write-Output 'PRECOMMIT_OK'
        exit 0
    }

    'snapshot' {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $stashOut = & git -C $RepoRoot stash create 2>$null
            $stashCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prev
        }
        if ($stashCode -ne 0) {
            Fail 'SNAPSHOT_FAIL: git stash create failed' 1
        }
        $sha = ($stashOut | Out-String).Trim()
        if (-not $sha) {
            $ErrorActionPreference = 'Continue'
            try {
                $headOut = & git -C $RepoRoot rev-parse HEAD 2>&1
                $headCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $prev
            }
            if ($headCode -ne 0) {
                Fail ("SNAPSHOT_FAIL: git rev-parse HEAD failed: " + ($headOut | Out-String).Trim()) 1
            }
            $sha = ($headOut | Out-String).Trim()
        }
        $ErrorActionPreference = 'Continue'
        try {
            $objType = (& git -C $RepoRoot cat-file -t $sha 2>$null | Out-String).Trim()
            $typeCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prev
        }
        if ($typeCode -ne 0 -or $objType -ne 'commit') {
            Fail "SNAPSHOT_FAIL: invalid snapshot commit '$sha'" 1
        }
        Write-Output $sha
        exit 0
    }

    'diff-scope' {
        if (-not $BaseSha) { Fail 'DIFF_SCOPE_FAIL: missing -BaseSha' 1 }
        $ignored = @(Split-CsvList $IgnoreDirtyPaths -AsPaths)

        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $numstat = & git -C $RepoRoot diff --no-renames --numstat $BaseSha 2>&1
            $nsCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prev
        }
        if ($nsCode -ne 0) {
            Fail ("DIFF_SCOPE_FAIL: git diff --numstat failed: " + ($numstat | Out-String).Trim()) 1
        }

        $untracked = @(Invoke-GitLines $RepoRoot @('ls-files', '--others', '--exclude-standard'))
        $reviewFiles = New-Object System.Collections.Generic.List[string]
        $noiseFiles = New-Object System.Collections.Generic.List[string]
        $totalLines = 0

        foreach ($row in @($numstat)) {
            if ($row -is [System.Management.Automation.ErrorRecord]) { continue }
            $lineStr = ([string]$row).Trim()
            if (-not $lineStr) { continue }
            $parts = $lineStr -split "`t", 3
            if ($parts.Count -lt 3) { continue }
            $p = Normalize-PathValue $parts[2]
            if (-not $p -or $p -match '^\.b3/autodev(/|$)' -or (Test-PathMatch $p $ignored)) { continue }
            if (Test-NoiseFile $p) {
                if (-not $noiseFiles.Contains($p)) { $noiseFiles.Add($p) }
                continue
            }
            if (-not $reviewFiles.Contains($p)) { $reviewFiles.Add($p) }
            if ($parts[0] -match '^\d+$') { $totalLines += [int]$parts[0] }
            if ($parts[1] -match '^\d+$') { $totalLines += [int]$parts[1] }
        }

        foreach ($u in $untracked) {
            if (-not $u -or $u -match '^\.b3/autodev(/|$)' -or (Test-PathMatch $u $ignored)) { continue }
            if (Test-NoiseFile $u) {
                if (-not $noiseFiles.Contains($u)) { $noiseFiles.Add($u) }
                continue
            }
            if (-not $reviewFiles.Contains($u)) {
                $reviewFiles.Add($u)
                $full = Join-Path $RepoRoot ($u -replace '/', '\')
                if (Test-Path -LiteralPath $full -PathType Leaf) {
                    $totalLines += @(Get-Content -LiteralPath $full -ErrorAction SilentlyContinue).Count
                }
            }
        }

        $dfOut = $null
        if ($PrevSha -and $PrevSha.Trim()) {
            $prevTrim = $PrevSha.Trim()
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $deltaRawOut = & git -C $RepoRoot diff --no-renames --name-only $prevTrim 2>&1
                $deltaCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $prevEap
            }
            if ($deltaCode -ne 0) {
                Fail ("DIFF_SCOPE_FAIL: git diff -PrevSha failed: " + ($deltaRawOut | Out-String).Trim()) 1
            }
            $deltaFiles = New-Object System.Collections.Generic.List[string]
            foreach ($row in @($deltaRawOut)) {
                if ($row -is [System.Management.Automation.ErrorRecord]) { continue }
                $dp = Normalize-PathValue ([string]$row)
                if (-not $dp -or $dp -match '^\.b3/autodev(/|$)' -or (Test-PathMatch $dp $ignored)) { continue }
                if (Test-NoiseFile $dp) { continue }
                if (-not $deltaFiles.Contains($dp)) { $deltaFiles.Add($dp) }
            }
            foreach ($u in $untracked) {
                if (-not $u -or $u -match '^\.b3/autodev(/|$)' -or (Test-PathMatch $u $ignored)) { continue }
                if (Test-NoiseFile $u) { continue }
                if (-not $deltaFiles.Contains($u)) { $deltaFiles.Add($u) }
            }
            $dfOut = if ($deltaFiles.Count -gt 0) { (Sort-Ordinal $deltaFiles.ToArray()) -join ',' } else { 'none' }
        }

        if ($reviewFiles.Count -eq 0 -and $noiseFiles.Count -eq 0) {
            Fail 'EMPTY_DIFF' 2
        }

        $fileCount = $reviewFiles.Count
        $sizeClass = if ($fileCount -eq 0) { 'NOISE_ONLY' }
            elseif ($fileCount -le 8 -and $totalLines -le 300) { 'SMALL' }
            elseif ($fileCount -le 20 -and $totalLines -le 800) { 'MEDIUM' }
            elseif ($fileCount -le 50 -and $totalLines -le 2000) { 'LARGE' }
            else { 'VERY_LARGE' }

        $rfOut = if ($reviewFiles.Count -gt 0) { (Sort-Ordinal $reviewFiles.ToArray()) -join ',' } else { 'none' }
        $nfOut = if ($noiseFiles.Count -gt 0) { (Sort-Ordinal $noiseFiles.ToArray()) -join ',' } else { 'none' }
        Write-Output "size_class=$sizeClass"
        Write-Output "files=$fileCount"
        Write-Output "lines=$totalLines"
        Write-Output "review_files=$rfOut"
        Write-Output "noise_files=$nfOut"
        if ($null -ne $dfOut) {
            Write-Output "delta_files=$dfOut"
        }
        exit 0
    }

    'mechanical-check' {
        if (-not $BaseSha) { Fail 'MECHANICAL_FAIL: missing -BaseSha' 1 }
        $allowed = @(Split-CsvList $AllowedPaths -AsPaths)
        $ignored = @(Split-CsvList $IgnoreDirtyPaths -AsPaths)
        $obsoletesList = @(Split-CsvList $Obsoletes)

        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $changedRaw = & git -C $RepoRoot diff --no-renames --name-only $BaseSha 2>&1
            $chCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prev
        }
        if ($chCode -ne 0) {
            Fail ("MECHANICAL_FAIL: git diff --name-only failed: " + ($changedRaw | Out-String).Trim()) 1
        }
        $untracked = @(Invoke-GitLines $RepoRoot @('ls-files', '--others', '--exclude-standard'))

        $allChanged = New-Object System.Collections.Generic.List[string]
        foreach ($row in @($changedRaw)) {
            if ($row -is [System.Management.Automation.ErrorRecord]) { continue }
            $p = Normalize-PathValue ([string]$row)
            if (-not $p -or $p -match '^\.b3/autodev(/|$)' -or (Test-PathMatch $p $ignored)) { continue }
            if (-not $allChanged.Contains($p)) { $allChanged.Add($p) }
        }
        foreach ($u in $untracked) {
            if (-not $u -or $u -match '^\.b3/autodev(/|$)' -or (Test-PathMatch $u $ignored)) { continue }
            if (-not $allChanged.Contains($u)) { $allChanged.Add($u) }
        }

        $scopeCreep = New-Object System.Collections.Generic.List[string]
        if ($allowed.Count -gt 0) {
            foreach ($p in $allChanged) {
                if (-not (Test-PathMatch $p $allowed)) { $scopeCreep.Add($p) }
            }
        }

        $leftoverHits = New-Object System.Collections.Generic.List[string]
        $ErrorActionPreference = 'Continue'
        try {
            $diffLines = & git -C $RepoRoot diff --no-renames -U0 $BaseSha 2>&1
            $dlCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prev
        }
        if ($dlCode -ne 0) {
            Fail ("MECHANICAL_FAIL: git diff -U0 failed: " + ($diffLines | Out-String).Trim()) 1
        }

        $curFile = ''
        $curLine = 0
        $skipFile = $true
        $inHunk = $false
        foreach ($rawLine in @($diffLines)) {
            if ($rawLine -is [System.Management.Automation.ErrorRecord]) { continue }
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
                    $skipFile = (-not $curFile) -or ($curFile -match '^\.b3/autodev(/|$)') -or (Test-PathMatch $curFile $ignored) -or (Test-NoiseFile $curFile) -or ($curFile -match '\.md$')
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
                $curLine++
            }
        }

        foreach ($u in @(Sort-Ordinal $untracked)) {
            if ($leftoverHits.Count -ge 10) { break }
            if (-not $u -or $u -match '^\.b3/autodev(/|$)' -or (Test-PathMatch $u $ignored) -or (Test-NoiseFile $u) -or ($u -match '\.md$')) { continue }
            $full = Join-Path $RepoRoot ($u -replace '/', '\')
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
            $lno = 0
            foreach ($fl in @(Get-Content -LiteralPath $full -ErrorAction SilentlyContinue)) {
                $lno++
                $tag = Find-LeftoverTag ([string]$fl)
                if ($tag -and $leftoverHits.Count -lt 10) {
                    $leftoverHits.Add("${u}:${lno}:${tag}")
                }
            }
        }

        $obsoleteHits = New-Object System.Collections.Generic.List[string]
        foreach ($tok in $obsoletesList) {
            $normTok = Normalize-PathValue $tok
            $existsPath = $false
            if ($normTok) {
                $existsPath = Test-Path -LiteralPath (Join-Path $RepoRoot ($normTok -replace '/', '\'))
            }
            $ErrorActionPreference = 'Continue'
            try {
                $grepOut = & git -C $RepoRoot grep -l -F -- $tok -- . ':(exclude).b3/autodev' 2>$null
                $grepCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $prev
            }
            if ($grepCode -gt 1) {
                Fail "MECHANICAL_FAIL: git grep failed for obsolete '$tok'" 1
            }
            $grepCount = 0
            if ($grepCode -eq 0) {
                $grepCount = @($grepOut | Where-Object { ([string]$_).Trim() }).Count
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

        Write-Output "scope_creep=$scOut"
        Write-Output "leftovers=$loOut"
        Write-Output "obsolete_hits=$obOut"
        if ($scOut -eq 'none' -and $loOut -eq 'none' -and $obOut -eq 'none') {
            Write-Output 'MECHANICAL_OK'
            exit 0
        }
        Write-Output 'MECHANICAL_FINDINGS'
        exit 2
    }

    'check-wave' {
        if (-not $WaveSpecs -or -not $WaveSpecs.Trim()) { Fail 'WAVE_FAIL: missing -WaveSpecs' 1 }
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

        $autodevDir = Join-Path $RepoRoot '.b3\autodev'
        $runsDir = Join-Path $autodevDir 'runs'
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
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllText((Join-Path $autodevDir 'CURRENT'), "$candidate`n", $utf8NoBom)

        Write-Output $candidate
        exit 0
    }

    'resolve-run' {
        $autodevDir = Join-Path $RepoRoot '.b3\autodev'
        $runsDir = Join-Path $autodevDir 'runs'

        if ($RunId) {
            $trimmed = $RunId.Trim()
            if (-not (Test-ValidRunId $trimmed)) {
                Fail "RESOLVE_FAIL: invalid run id '$RunId'" 1
            }
            $target = Join-Path $runsDir $trimmed
            if (-not (Test-Path -LiteralPath $target -PathType Container)) {
                Fail "RESOLVE_FAIL: run not found '$trimmed'" 1
            }
            Write-Output ".b3/autodev/runs/$trimmed"
            exit 0
        }

        $curFile = Join-Path $autodevDir 'CURRENT'
        if (Test-Path -LiteralPath $curFile -PathType Leaf) {
            $curId = ([IO.File]::ReadAllText($curFile)).Trim()
            if (-not (Test-ValidRunId $curId)) {
                Fail "RESOLVE_FAIL: CURRENT contains invalid run id '$curId'" 1
            }
            $target = Join-Path $runsDir $curId
            if (-not (Test-Path -LiteralPath $target -PathType Container)) {
                Fail "RESOLVE_FAIL: CURRENT points to missing run '$curId'" 1
            }
            Write-Output ".b3/autodev/runs/$curId"
            exit 0
        }

        if (Test-Path -LiteralPath (Join-Path $autodevDir 'progress.md') -PathType Leaf) {
            Write-Output '.b3/autodev'
            exit 0
        }

        Fail 'NO_ACTIVE_RUN' 1
    }

    'list-runs' {
        $autodevDir = Join-Path $RepoRoot '.b3\autodev'
        $runsDir = Join-Path $autodevDir 'runs'
        $curId = Get-CurrentRunId $autodevDir

        $dirNames = @()
        if (Test-Path -LiteralPath $runsDir -PathType Container) {
            $rawNames = @(Get-ChildItem -LiteralPath $runsDir -Directory | ForEach-Object { $_.Name })
            $dirNames = @(Sort-Ordinal $rawNames -Descending)
        }
        if ($dirNames.Count -eq 0) {
            if (Test-Path -LiteralPath (Join-Path $autodevDir 'progress.md') -PathType Leaf) {
                $st = Get-RunStatus $autodevDir
                Write-Output "* legacy [$st]"
            } else {
                Write-Output 'NO_RUNS'
            }
            exit 0
        }

        foreach ($id in $dirNames) {
            $st = Get-RunStatus (Join-Path $runsDir $id)
            $mark = if ($curId -and ($id -ceq $curId)) { '* ' } else { '  ' }
            Write-Output "$mark$id [$st]"
        }
        exit 0
    }

    'prune' {
        if ($Keep -lt 0) { Fail 'PRUNE_FAIL: -Keep must be >= 0' 1 }
        $autodevDir = Join-Path $RepoRoot '.b3\autodev'
        $runsDir = Join-Path $autodevDir 'runs'
        if (-not (Test-Path -LiteralPath $runsDir -PathType Container)) {
            Write-Output 'PRUNE_OK: 0 removed'
            exit 0
        }

        $curId = Get-CurrentRunId $autodevDir
        $rawNames = @(Get-ChildItem -LiteralPath $runsDir -Directory | ForEach-Object { $_.Name })
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
                    Remove-Item -LiteralPath $fullDir -Recurse -Force
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
}
