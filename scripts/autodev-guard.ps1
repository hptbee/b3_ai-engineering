param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('fingerprint', 'check-freshness', 'precommit', 'snapshot', 'diff-scope')]
    [string]$Command,
    [string]$DependsOn = '',
    [string]$Scope = '',
    [string[]]$Criteria = @(),
    [string]$RepoRoot = '.',
    [string]$ApproachAtSha = '',
    [string]$TaskBaseSha = '',
    [string]$BaseSha = '',
    [string]$WatchedPaths = '',
    [string]$OwnedFiles = '',
    [string]$IgnoreDirtyPaths = '',
    [string]$AllowedPaths = ''
)

$ErrorActionPreference = 'Stop'

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

        $depItems = @(Split-CsvList $DependsOn | Sort-Object -Unique)
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

        $committed = @(Invoke-GitLines $RepoRoot @('diff', '--name-only', $ApproachAtSha, 'HEAD'))
        $committedHits = @($committed | Where-Object {
            ($_ -notmatch '^\.b3/autodev(/|$)') -and (Test-PathMatch $_ $watched)
        } | Sort-Object -Unique)
        if ($committedHits.Count -gt 0) {
            Fail ("STALE: committed change in watched_paths (" + ($committedHits -join ', ') + ")") 2
        }

        $readOnlyWatched = @($watched | Where-Object { -not (Test-PathMatch $_ $owned) })
        if ($readOnlyWatched.Count -gt 0) {
            $wtDiff = @(Invoke-GitLines $RepoRoot @('diff', '--name-only', $ApproachAtSha))
            $cached = @(Invoke-GitLines $RepoRoot @('diff', '--cached', '--name-only'))
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
        $staged = @(Invoke-GitLines $RepoRoot @('diff', '--cached', '--name-only'))
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

        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $numstat = & git -C $RepoRoot diff --numstat $BaseSha 2>&1
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

        if ($reviewFiles.Count -eq 0 -and $noiseFiles.Count -eq 0) {
            Fail 'EMPTY_DIFF' 2
        }

        $fileCount = $reviewFiles.Count
        $sizeClass = if ($fileCount -le 8 -and $totalLines -le 300) { 'SMALL' }
            elseif ($fileCount -le 20 -and $totalLines -le 800) { 'MEDIUM' }
            elseif ($fileCount -le 50 -and $totalLines -le 2000) { 'LARGE' }
            else { 'VERY_LARGE' }

        $rfOut = if ($reviewFiles.Count -gt 0) { ($reviewFiles | Sort-Object -Unique) -join ',' } else { 'none' }
        $nfOut = if ($noiseFiles.Count -gt 0) { ($noiseFiles | Sort-Object -Unique) -join ',' } else { 'none' }
        Write-Output "size_class=$sizeClass"
        Write-Output "files=$fileCount"
        Write-Output "lines=$totalLines"
        Write-Output "review_files=$rfOut"
        Write-Output "noise_files=$nfOut"
        exit 0
    }
}
