param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('fingerprint', 'check-freshness', 'precommit', 'snapshot', 'diff-scope', 'mechanical-check', 'check-wave', 'new-run', 'resolve-run', 'list-runs', 'prune', 'verify-run', 'verify-check', 'symbol-check', 'check-worktree')]
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
    [string]$ExpectedCmd = ''
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
    if (-not $Candidate) { return $false }
    foreach ($p in $Patterns) {
        if ($p -eq '.') { return $true }
        if ($Candidate -eq $p) { return $true }
        if ($p -and $Candidate.StartsWith("$p/")) { return $true }
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
    # A temporary index still creates permanent Git blobs: reject sensitive changes first.
    $changed = Invoke-GitCommand $Root @('diff', '--no-renames', '--name-only', 'HEAD', '--')
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

    # Git trees cannot represent uncommitted or untracked contents inside gitlinks.
    $links = Invoke-GitCommand $Root @('ls-files', '--stage')
    if ($links.ExitCode -ne 0) { Fail "${FailPrefix}: unable to inspect submodules" 1 }
    foreach ($entry in ($links.StdOut -split "\r?\n")) {
        if ($entry -cnotmatch '^160000 [0-9a-f]{40} [0-3]`t(.+)
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
        $addRes = Invoke-GitCommand $Root @('add', '-A') -ExtraEnv $envMap
        if ($addRes.ExitCode -ne 0) {
            $detail = if ($addRes.StdErr.Trim()) { $addRes.StdErr.Trim() } else { $addRes.StdOut.Trim() }
            Fail "${FailPrefix}: git add -A failed: $detail" 1
        }
        $rmRes = Invoke-GitCommand $Root @('rm', '-r', '--cached', '--ignore-unmatch', '--quiet', '--', '.b3/ship', '.b3/autodev') -ExtraEnv $envMap
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
        if ($p -match '^\.b3/(ship|autodev)(/|$)') { continue }
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
        if (-not $p -or $p -match '^\.b3/(ship|autodev)(/|$)') { continue }
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

function Get-SymlinkBlobOid([string]$Root, [string]$RelPath) {
    $full = Join-Path $Root ($RelPath -replace '/', '\')
    $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
    if ($item -and (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        $isSym = (-not $item.PSObject.Properties['LinkType']) -or ($item.LinkType -ceq 'SymbolicLink')
        if ($isSym -and $item.PSObject.Properties['Target'] -and $item.Target) {
            $tgt = ([string](@($item.Target)[0])) -replace '\\', '/'
            $sRes = Invoke-GitCommand $Root @('hash-object', '--stdin') $tgt
            $sSha = $sRes.StdOut.Trim()
            if ($sRes.ExitCode -ne 0 -or $sSha -notmatch '^[0-9a-f]{40}$') {
                $detail = if ($sRes.StdErr.Trim()) { $sRes.StdErr.Trim() } else { $sSha }
                Fail "GIT_ERROR: git hash-object symlink failed for ${RelPath}: $detail" 1
            }
            return $sSha
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
        $dRes = Invoke-GitCommand $Root @('hash-object', '--stdin') $sbDirty.ToString()
        $dSha = $dRes.StdOut.Trim()
        if ($dRes.ExitCode -ne 0 -or $dSha -notmatch '^[0-9a-f]{40}$') {
            $detail = if ($dRes.StdErr.Trim()) { $dRes.StdErr.Trim() } else { $dSha }
            Fail "GIT_ERROR: git hash-object submodule digest failed for ${RelPath}: $detail" 1
        }
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
            if (-not $np -or $np -match '^\.b3/(ship|autodev)(/|$)') { continue }
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
        if (-not $p -or $p -match '^\.b3/(ship|autodev)(/|$)') { continue }
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
        if (-not $p -or $p -match '^\.b3/(ship|autodev)(/|$)') { continue }
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

    $thRes = Invoke-GitCommand $Root @('hash-object', '--stdin') -StdInText ($sb.ToString())
    $treeHash = $thRes.StdOut.Trim()
    if ($thRes.ExitCode -ne 0 -or $treeHash -notmatch '^[0-9a-f]{40}$') {
        $detail = if ($thRes.StdErr.Trim()) { $thRes.StdErr.Trim() } else { $treeHash }
        Fail "GIT_ERROR: git hash-object manifest failed: $detail" 1
    }
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
        $validRel = @($relSpec | Where-Object { $_ -and ($_ -notmatch '^\.b3/(ship|autodev)(/|$)') })
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
        $validReq = @($reqSpec | Where-Object { $_ -and ($_ -notmatch '^\.b3/(ship|autodev)(/|$)') })
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
            ($_ -notmatch '^\.b3/(ship|autodev)(/|$)') -and (Test-PathMatch $_ $watched)
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
                if ($p -match '^\.b3/(ship|autodev)(/|$)') { continue }
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
            ($_ -match '^\.b3/(ship|autodev)(/|$)') -or (($_ -match '^\.b3(/|$)') -and -not (Test-PathMatch $_ $allowed))
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
            $scopePaths = @()
            if (-not $scopeAll) {
                $scopePaths = @(Split-CsvList $vr.RelevantPathsCsv -AsPaths)
                if ($scopePaths -contains '.') { $scopeAll = $true }
            }
            $unstagedRaw = @(if ($scopeAll) {
                Invoke-GitLines $RepoRoot @('diff', '--no-renames', '--ignore-submodules=none', '--name-only')
            } else {
                Invoke-GitLines $RepoRoot (@('diff', '--no-renames', '--ignore-submodules=none', '--name-only', '--') + $scopePaths)
            })
            $untrackedScopeRaw = @(if ($scopeAll) {
                Invoke-GitLines $RepoRoot @('ls-files', '--others', '--exclude-standard')
            } else {
                Invoke-GitLines $RepoRoot (@('ls-files', '--others', '--exclude-standard', '--') + $scopePaths)
            })
            $unstagedInScope = New-Object System.Collections.Generic.List[string]
            foreach ($u in (@($unstagedRaw) + @($untrackedScopeRaw))) {
                if (-not $u -or $u -match '^\.b3/(ship|autodev)(/|$)') { continue }
                if ($ignored -and (Test-PathMatch $u $ignored)) { continue }
                if (-not $scopeAll -and -not (Test-PathMatch $u $scopePaths)) { continue }
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
        $targetTrim = $TargetRef.Trim()
        $targetCommitSha = ''
        if ($targetTrim) {
            if ($targetTrim.StartsWith('-')) {
                Fail "DIFF_SCOPE_FAIL: invalid -TargetRef '$targetTrim'" 1
            }
            $trRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--verify', '--quiet', "${targetTrim}^{commit}")
            $targetCommitSha = $trRes.StdOut.Trim()
            if ($trRes.ExitCode -ne 0 -or -not $targetCommitSha) {
                Fail "DIFF_SCOPE_FAIL: invalid -TargetRef '$targetTrim'" 1
            }
        }

        $resolvedBase = $BaseSha.Trim()
        if (-not $resolvedBase -or $resolvedBase -eq 'auto') {
            if ($targetTrim) {
                $resolvedBase = Resolve-AutoBaseForTarget $RepoRoot $targetCommitSha
            } else {
                $resolvedBase = Resolve-AutoBaseSha $RepoRoot $ignored
            }
        }
        [void](Assert-ValidGitRev $RepoRoot $resolvedBase 'object' 'DIFF_SCOPE_FAIL' '-BaseSha')

        $nsArgs = if ($targetTrim) {
            @('diff', '--no-renames', '--numstat', $resolvedBase, $targetCommitSha, '--')
        } else {
            @('diff', '--no-renames', '--numstat', $resolvedBase, '--')
        }
        $nsRes = Invoke-GitCommand $RepoRoot $nsArgs
        if ($nsRes.ExitCode -ne 0) {
            $detail = if ($nsRes.StdErr.Trim()) { $nsRes.StdErr.Trim() } else { $nsRes.StdOut.Trim() }
            Fail ("DIFF_SCOPE_FAIL: git diff --numstat failed: $detail") 1
        }

        $untracked = if ($targetTrim) { @() } else { @(Invoke-GitLines $RepoRoot @('ls-files', '--others', '--exclude-standard')) }
        $reviewFiles = New-Object System.Collections.Generic.List[string]
        $noiseFiles = New-Object System.Collections.Generic.List[string]
        $totalLines = 0

        foreach ($row in ($nsRes.StdOut -split "\r?\n")) {
            $lineStr = ([string]$row).Trim()
            if (-not $lineStr) { continue }
            $parts = $lineStr -split "`t", 3
            if ($parts.Count -lt 3) { continue }
            $p = Normalize-PathValue $parts[2]
            if (-not $p -or $p -match '^\.b3/(ship|autodev)(/|$)' -or (Test-PathMatch $p $ignored)) { continue }
            if (Test-NoiseFile $p) {
                if (-not $noiseFiles.Contains($p)) { $noiseFiles.Add($p) }
                continue
            }
            if (-not $reviewFiles.Contains($p)) { $reviewFiles.Add($p) }
            if ($parts[0] -match '^\d+$') { $totalLines += [int]$parts[0] }
            if ($parts[1] -match '^\d+$') { $totalLines += [int]$parts[1] }
        }

        foreach ($u in $untracked) {
            if (-not $u -or $u -match '^\.b3/(ship|autodev)(/|$)' -or (Test-PathMatch $u $ignored)) { continue }
            if (Test-NoiseFile $u) {
                if (-not $noiseFiles.Contains($u)) { $noiseFiles.Add($u) }
                continue
            }
            if (-not $reviewFiles.Contains($u)) {
                $reviewFiles.Add($u)
                $full = Join-Path $RepoRoot ($u -replace '/', '\')
                if ((Test-Path -LiteralPath $full -PathType Leaf) -and -not (Test-BinaryFile $full)) {
                    $totalLines += ([IO.File]::ReadAllLines($full)).Length
                }
            }
        }

        $dfOut = $null
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
                if (-not $dp -or $dp -match '^\.b3/(ship|autodev)(/|$)' -or (Test-PathMatch $dp $ignored)) { continue }
                if (Test-NoiseFile $dp) { continue }
                if (-not $deltaFiles.Contains($dp)) { $deltaFiles.Add($dp) }
            }
            $dfOut = if ($deltaFiles.Count -gt 0) { (Sort-Ordinal $deltaFiles.ToArray()) -join ',' } else { 'none' }
        }

        if ($reviewFiles.Count -eq 0 -and $noiseFiles.Count -eq 0) {
            if ($null -eq $dfOut -or $dfOut -eq 'none') { Fail 'EMPTY_DIFF' 2 }
            Write-Output 'size_class=CLEAN_AFTER_FIX'
            Write-Output 'files=0'
            Write-Output 'lines=0'
            Write-Output 'review_files=none'
            Write-Output 'noise_files=none'
            Write-Output "delta_files=$dfOut"
            exit 0
        }

        $fileCount = $reviewFiles.Count
        $sizeClass = if ($fileCount -eq 0) { 'NOISE_ONLY' }
            elseif ($fileCount -le 8 -and $totalLines -le 300) { 'SMALL' }
            elseif ($fileCount -le 20 -and $totalLines -le 800) { 'MEDIUM' }
            elseif ($fileCount -lt 50 -and $totalLines -lt 2000) { 'LARGE' }
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
        $allowed = @(Split-CsvList $AllowedPaths -AsPaths)
        $ignored = @(Split-CsvList $IgnoreDirtyPaths -AsPaths)
        $obsoletesList = @(Split-CsvList $Obsoletes)
        $targetTrim = $TargetRef.Trim()
        $targetCommitSha = ''
        if ($targetTrim) {
            if ($targetTrim.StartsWith('-')) {
                Fail "MECHANICAL_FAIL: invalid -TargetRef '$targetTrim'" 1
            }
            $trRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--verify', '--quiet', "${targetTrim}^{commit}")
            $targetCommitSha = $trRes.StdOut.Trim()
            if ($trRes.ExitCode -ne 0 -or -not $targetCommitSha) {
                Fail "MECHANICAL_FAIL: invalid -TargetRef '$targetTrim'" 1
            }
        }

        $resolvedBase = $BaseSha.Trim()
        if (-not $resolvedBase -or $resolvedBase -eq 'auto') {
            if ($targetTrim) {
                $resolvedBase = Resolve-AutoBaseForTarget $RepoRoot $targetCommitSha
            } else {
                $resolvedBase = Resolve-AutoBaseSha $RepoRoot $ignored
            }
        }

        [void](Assert-ValidGitRev $RepoRoot $resolvedBase 'object' 'MECHANICAL_FAIL' '-BaseSha')

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
            if (-not $p -or $p -match '^\.b3/(ship|autodev)(/|$)' -or (Test-PathMatch $p $ignored)) { continue }
            if (-not $allChanged.Contains($p)) { $allChanged.Add($p) }
        }
        foreach ($u in $untracked) {
            if (-not $u -or $u -match '^\.b3/(ship|autodev)(/|$)' -or (Test-PathMatch $u $ignored)) { continue }
            if (-not $allChanged.Contains($u)) { $allChanged.Add($u) }
        }

        $nonDelChanged = New-Object System.Collections.Generic.List[string]
        foreach ($row in ($nonDelRes.StdOut -split "\r?\n")) {
            $p = Normalize-PathValue ([string]$row)
            if (-not $p -or $p -match '^\.b3/(ship|autodev)(/|$)' -or (Test-PathMatch $p $ignored)) { continue }
            if (-not $nonDelChanged.Contains($p)) { $nonDelChanged.Add($p) }
        }
        foreach ($u in $untracked) {
            if (-not $u -or $u -match '^\.b3/(ship|autodev)(/|$)' -or (Test-PathMatch $u $ignored)) { continue }
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
                    $skipFile = (-not $curFile) -or ($curFile -match '^\.b3/(ship|autodev)(/|$)') -or (Test-PathMatch $curFile $ignored) -or (Test-NoiseFile $curFile) -or ($curFile -match '\.md$')
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
            if (-not $u -or $u -match '^\.b3/(ship|autodev)(/|$)' -or (Test-PathMatch $u $ignored) -or (Test-NoiseFile $u) -or ($u -match '\.md$')) { continue }
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

        $delTarget = if ($targetTrim) { $targetCommitSha } else { New-WorkingTreeOid $RepoRoot 'MECHANICAL_FAIL' }
        $delArgs = @('diff', '-M', '--diff-filter=D', '--name-only', $resolvedBase, $delTarget, '--')
        $delRes = Invoke-GitCommand $RepoRoot $delArgs
        if ($delRes.ExitCode -ne 0) {
            $detail = if ($delRes.StdErr.Trim()) { $delRes.StdErr.Trim() } else { $delRes.StdOut.Trim() }
            Fail ("MECHANICAL_FAIL: git diff --diff-filter=D failed: $detail") 1
        }
        $deletedList = New-Object System.Collections.Generic.List[string]
        foreach ($row in ($delRes.StdOut -split "\r?\n")) {
            $dp = Normalize-PathValue ([string]$row)
            if (-not $dp -or $dp -match '^\.b3/(ship|autodev)(/|$)' -or (Test-PathMatch $dp $ignored) -or (Test-NoiseFile $dp)) { continue }
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
                @('grep', '-l', '-F', '-e', $tok, $targetCommitSha, '--', '.', ':(exclude).b3/ship', ':(exclude).b3/autodev')
            } else {
                @('grep', '--untracked', '-l', '-F', '-e', $tok, '--', '.', ':(exclude).b3/ship', ':(exclude).b3/autodev')
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
                    if (-not $gp -or $gp -match '^\.b3/(ship|autodev)(/|$)' -or ($ignored -and (Test-PathMatch $gp $ignored))) { continue }
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

        $ShipDir = Join-Path $RepoRoot '.b3\ship'
        $runsDir = Join-Path $ShipDir 'runs'
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
        Write-AtomicLfFile (Join-Path $ShipDir 'CURRENT') "$candidate`n"

        Write-Output $candidate
        exit 0
    }

    'resolve-run' {
        $ShipDir = Join-Path $RepoRoot '.b3\ship'
        $runsDir = Join-Path $ShipDir 'runs'
        $AutodevDir = Join-Path $RepoRoot '.b3\autodev'
        $autodevRunsDir = Join-Path $AutodevDir 'runs'

        if ($RunId) {
            $trimmed = $RunId.Trim()
            if (-not (Test-ValidRunId $trimmed)) {
                Fail "RESOLVE_FAIL: invalid run id '$RunId'" 1
            }
            $target = Join-Path $runsDir $trimmed
            if (Test-Path -LiteralPath $target -PathType Container) {
                Write-Output ".b3/ship/runs/$trimmed"
                exit 0
            }
            $legacyTarget = Join-Path $autodevRunsDir $trimmed
            if (Test-Path -LiteralPath $legacyTarget -PathType Container) {
                Write-Output ".b3/autodev/runs/$trimmed"
                exit 0
            }
            Fail "RESOLVE_FAIL: run not found '$trimmed'" 1
        }

        $curFile = Join-Path $ShipDir 'CURRENT'
        if (Test-Path -LiteralPath $curFile -PathType Leaf) {
            $curId = ([IO.File]::ReadAllText($curFile)).Trim()
            if (-not (Test-ValidRunId $curId)) {
                Fail "RESOLVE_FAIL: CURRENT contains invalid run id '$curId'" 1
            }
            $target = Join-Path $runsDir $curId
            if (-not (Test-Path -LiteralPath $target -PathType Container)) {
                Fail "RESOLVE_FAIL: CURRENT points to missing run '$curId'" 1
            }
            Write-Output ".b3/ship/runs/$curId"
            exit 0
        }

        if (Test-Path -LiteralPath (Join-Path $ShipDir 'progress.md') -PathType Leaf) {
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

        Fail 'NO_ACTIVE_RUN' 1
    }

    'list-runs' {
        $ShipDir = Join-Path $RepoRoot '.b3\ship'
        $runsDir = Join-Path $ShipDir 'runs'
        $curId = Get-CurrentRunId $ShipDir

        $dirNames = @()
        if (Test-Path -LiteralPath $runsDir -PathType Container) {
            $rawNames = @(Get-ChildItem -LiteralPath $runsDir -Directory | ForEach-Object { $_.Name })
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

        if (Test-Path -LiteralPath (Join-Path $ShipDir 'progress.md') -PathType Leaf) {
            $st = Get-RunStatus $ShipDir
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

        Write-Output 'NO_RUNS'
        exit 0
    }

    'prune' {
        if ($Keep -lt 0) { Fail 'PRUNE_FAIL: -Keep must be >= 0' 1 }
        $dotB3Dir = Join-Path $RepoRoot '.b3'
        $ShipDir = Join-Path $dotB3Dir 'ship'
        $runsDir = Join-Path $ShipDir 'runs'
        if ((Test-IsReparsePath $dotB3Dir) -or (Test-IsReparsePath $ShipDir) -or (Test-IsReparsePath $runsDir)) {
            Fail 'PRUNE_FAIL: runs directory is a link' 1
        }
        if (-not (Test-Path -LiteralPath $runsDir -PathType Container)) {
            Write-Output 'PRUNE_OK: 0 removed'
            exit 0
        }

        $curId = Get-CurrentRunId $ShipDir
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
        $targetTrim = $TargetRef.Trim()
        $targetCommitSha = ''
        if ($targetTrim) {
            if ($targetTrim.StartsWith('-')) {
                Fail "SYMBOL_FAIL: invalid -TargetRef '$targetTrim'" 1
            }
            $trRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--verify', '--quiet', "${targetTrim}^{commit}")
            $targetCommitSha = $trRes.StdOut.Trim()
            if ($trRes.ExitCode -ne 0 -or -not $targetCommitSha) {
                Fail "SYMBOL_FAIL: invalid -TargetRef '$targetTrim'" 1
            }
        }

        $resolvedBase = $BaseSha.Trim()
        if (-not $resolvedBase -or $resolvedBase -eq 'auto') {
            if ($targetTrim) {
                $resolvedBase = Resolve-AutoBaseForTarget $RepoRoot $targetCommitSha
            } else {
                $resolvedBase = Resolve-AutoBaseSha $RepoRoot $ignored
            }
        }

        [void](Assert-ValidGitRev $RepoRoot $resolvedBase 'object' 'SYMBOL_FAIL' '-BaseSha')

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
                    $skipOld = (-not $oldFile) -or ($oldFile -match '^\.b3/(ship|autodev)(/|$)') -or (Test-PathMatch $oldFile $ignored) -or (Test-NoiseFile $oldFile) -or (-not (Test-CodePath $oldFile))
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
                    $skipNew = (-not $newFile) -or ($newFile -match '^\.b3/(ship|autodev)(/|$)') -or (Test-PathMatch $newFile $ignored) -or (Test-NoiseFile $newFile) -or (-not (Test-CodePath $newFile))
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
                if (-not $u -or $u -match '^\.b3/(ship|autodev)(/|$)' -or (Test-PathMatch $u $ignored) -or (Test-NoiseFile $u) -or (-not (Test-CodePath $u))) { continue }
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
                        if (-not $np -or $np -match '^\.b3/(ship|autodev)(/|$)' -or (Test-PathMatch $np $ignored) -or (Test-NoiseFile $np) -or (-not (Test-CodePath $np))) { continue }
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
                        if (-not $np -or $np -match '^\.b3/(ship|autodev)(/|$)' -or (Test-PathMatch $np $ignored) -or (Test-NoiseFile $np) -or (-not (Test-CodePath $np))) { continue }
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
}
) { continue }
        $rel = $Matches[1]
        $sub = Join-Path $Root ($rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath (Join-Path $sub '.git'))) { continue }
        $state = Invoke-GitCommand $sub @('status', '--porcelain', '--untracked-files=all', '--ignore-submodules=none')
        if ($state.ExitCode -ne 0) { Fail "${FailPrefix}: unable to inspect submodule ($rel)" 1 }
        if ($state.StdOut.Trim()) { Fail "${FailPrefix}: dirty submodule cannot be snapshotted ($rel)" 1 }
    }
}

function New-WorkingTreeOid([string]$Root, [string]$FailPrefix) {
    Assert-SnapshotSafe $Root $FailPrefix
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
        $addRes = Invoke-GitCommand $Root @('add', '-A') -ExtraEnv $envMap
        if ($addRes.ExitCode -ne 0) {
            $detail = if ($addRes.StdErr.Trim()) { $addRes.StdErr.Trim() } else { $addRes.StdOut.Trim() }
            Fail "${FailPrefix}: git add -A failed: $detail" 1
        }
        $rmRes = Invoke-GitCommand $Root @('rm', '-r', '--cached', '--ignore-unmatch', '--quiet', '--', '.b3/ship', '.b3/autodev') -ExtraEnv $envMap
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
        if ($p -match '^\.b3/(ship|autodev)(/|$)') { continue }
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
        if (-not $p -or $p -match '^\.b3/(ship|autodev)(/|$)') { continue }
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

function Get-SymlinkBlobOid([string]$Root, [string]$RelPath) {
    $full = Join-Path $Root ($RelPath -replace '/', '\')
    $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
    if ($item -and (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        $isSym = (-not $item.PSObject.Properties['LinkType']) -or ($item.LinkType -ceq 'SymbolicLink')
        if ($isSym -and $item.PSObject.Properties['Target'] -and $item.Target) {
            $tgt = ([string](@($item.Target)[0])) -replace '\\', '/'
            $sRes = Invoke-GitCommand $Root @('hash-object', '--stdin') $tgt
            $sSha = $sRes.StdOut.Trim()
            if ($sRes.ExitCode -ne 0 -or $sSha -notmatch '^[0-9a-f]{40}$') {
                $detail = if ($sRes.StdErr.Trim()) { $sRes.StdErr.Trim() } else { $sSha }
                Fail "GIT_ERROR: git hash-object symlink failed for ${RelPath}: $detail" 1
            }
            return $sSha
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
        $dRes = Invoke-GitCommand $Root @('hash-object', '--stdin') $sbDirty.ToString()
        $dSha = $dRes.StdOut.Trim()
        if ($dRes.ExitCode -ne 0 -or $dSha -notmatch '^[0-9a-f]{40}$') {
            $detail = if ($dRes.StdErr.Trim()) { $dRes.StdErr.Trim() } else { $dSha }
            Fail "GIT_ERROR: git hash-object submodule digest failed for ${RelPath}: $detail" 1
        }
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
            if (-not $np -or $np -match '^\.b3/(ship|autodev)(/|$)') { continue }
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
        if (-not $p -or $p -match '^\.b3/(ship|autodev)(/|$)') { continue }
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
        if (-not $p -or $p -match '^\.b3/(ship|autodev)(/|$)') { continue }
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

    $thRes = Invoke-GitCommand $Root @('hash-object', '--stdin') -StdInText ($sb.ToString())
    $treeHash = $thRes.StdOut.Trim()
    if ($thRes.ExitCode -ne 0 -or $treeHash -notmatch '^[0-9a-f]{40}$') {
        $detail = if ($thRes.StdErr.Trim()) { $thRes.StdErr.Trim() } else { $treeHash }
        Fail "GIT_ERROR: git hash-object manifest failed: $detail" 1
    }
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
        $validRel = @($relSpec | Where-Object { $_ -and ($_ -notmatch '^\.b3/(ship|autodev)(/|$)') })
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
        $validReq = @($reqSpec | Where-Object { $_ -and ($_ -notmatch '^\.b3/(ship|autodev)(/|$)') })
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
            ($_ -notmatch '^\.b3/(ship|autodev)(/|$)') -and (Test-PathMatch $_ $watched)
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
                if ($p -match '^\.b3/(ship|autodev)(/|$)') { continue }
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
            ($_ -match '^\.b3/(ship|autodev)(/|$)') -or (($_ -match '^\.b3(/|$)') -and -not (Test-PathMatch $_ $allowed))
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
            $scopePaths = @()
            if (-not $scopeAll) {
                $scopePaths = @(Split-CsvList $vr.RelevantPathsCsv -AsPaths)
                if ($scopePaths -contains '.') { $scopeAll = $true }
            }
            $unstagedRaw = @(if ($scopeAll) {
                Invoke-GitLines $RepoRoot @('diff', '--no-renames', '--ignore-submodules=none', '--name-only')
            } else {
                Invoke-GitLines $RepoRoot (@('diff', '--no-renames', '--ignore-submodules=none', '--name-only', '--') + $scopePaths)
            })
            $untrackedScopeRaw = @(if ($scopeAll) {
                Invoke-GitLines $RepoRoot @('ls-files', '--others', '--exclude-standard')
            } else {
                Invoke-GitLines $RepoRoot (@('ls-files', '--others', '--exclude-standard', '--') + $scopePaths)
            })
            $unstagedInScope = New-Object System.Collections.Generic.List[string]
            foreach ($u in (@($unstagedRaw) + @($untrackedScopeRaw))) {
                if (-not $u -or $u -match '^\.b3/(ship|autodev)(/|$)') { continue }
                if ($ignored -and (Test-PathMatch $u $ignored)) { continue }
                if (-not $scopeAll -and -not (Test-PathMatch $u $scopePaths)) { continue }
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
        $targetTrim = $TargetRef.Trim()
        $targetCommitSha = ''
        if ($targetTrim) {
            if ($targetTrim.StartsWith('-')) {
                Fail "DIFF_SCOPE_FAIL: invalid -TargetRef '$targetTrim'" 1
            }
            $trRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--verify', '--quiet', "${targetTrim}^{commit}")
            $targetCommitSha = $trRes.StdOut.Trim()
            if ($trRes.ExitCode -ne 0 -or -not $targetCommitSha) {
                Fail "DIFF_SCOPE_FAIL: invalid -TargetRef '$targetTrim'" 1
            }
        }

        $resolvedBase = $BaseSha.Trim()
        if (-not $resolvedBase -or $resolvedBase -eq 'auto') {
            if ($targetTrim) {
                $resolvedBase = Resolve-AutoBaseForTarget $RepoRoot $targetCommitSha
            } else {
                $resolvedBase = Resolve-AutoBaseSha $RepoRoot $ignored
            }
        }
        [void](Assert-ValidGitRev $RepoRoot $resolvedBase 'object' 'DIFF_SCOPE_FAIL' '-BaseSha')

        $nsArgs = if ($targetTrim) {
            @('diff', '--no-renames', '--numstat', $resolvedBase, $targetCommitSha, '--')
        } else {
            @('diff', '--no-renames', '--numstat', $resolvedBase, '--')
        }
        $nsRes = Invoke-GitCommand $RepoRoot $nsArgs
        if ($nsRes.ExitCode -ne 0) {
            $detail = if ($nsRes.StdErr.Trim()) { $nsRes.StdErr.Trim() } else { $nsRes.StdOut.Trim() }
            Fail ("DIFF_SCOPE_FAIL: git diff --numstat failed: $detail") 1
        }

        $untracked = if ($targetTrim) { @() } else { @(Invoke-GitLines $RepoRoot @('ls-files', '--others', '--exclude-standard')) }
        $reviewFiles = New-Object System.Collections.Generic.List[string]
        $noiseFiles = New-Object System.Collections.Generic.List[string]
        $totalLines = 0

        foreach ($row in ($nsRes.StdOut -split "\r?\n")) {
            $lineStr = ([string]$row).Trim()
            if (-not $lineStr) { continue }
            $parts = $lineStr -split "`t", 3
            if ($parts.Count -lt 3) { continue }
            $p = Normalize-PathValue $parts[2]
            if (-not $p -or $p -match '^\.b3/(ship|autodev)(/|$)' -or (Test-PathMatch $p $ignored)) { continue }
            if (Test-NoiseFile $p) {
                if (-not $noiseFiles.Contains($p)) { $noiseFiles.Add($p) }
                continue
            }
            if (-not $reviewFiles.Contains($p)) { $reviewFiles.Add($p) }
            if ($parts[0] -match '^\d+$') { $totalLines += [int]$parts[0] }
            if ($parts[1] -match '^\d+$') { $totalLines += [int]$parts[1] }
        }

        foreach ($u in $untracked) {
            if (-not $u -or $u -match '^\.b3/(ship|autodev)(/|$)' -or (Test-PathMatch $u $ignored)) { continue }
            if (Test-NoiseFile $u) {
                if (-not $noiseFiles.Contains($u)) { $noiseFiles.Add($u) }
                continue
            }
            if (-not $reviewFiles.Contains($u)) {
                $reviewFiles.Add($u)
                $full = Join-Path $RepoRoot ($u -replace '/', '\')
                if ((Test-Path -LiteralPath $full -PathType Leaf) -and -not (Test-BinaryFile $full)) {
                    $totalLines += ([IO.File]::ReadAllLines($full)).Length
                }
            }
        }

        $dfOut = $null
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
                if (-not $dp -or $dp -match '^\.b3/(ship|autodev)(/|$)' -or (Test-PathMatch $dp $ignored)) { continue }
                if (Test-NoiseFile $dp) { continue }
                if (-not $deltaFiles.Contains($dp)) { $deltaFiles.Add($dp) }
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
            elseif ($fileCount -lt 50 -and $totalLines -lt 2000) { 'LARGE' }
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
        $allowed = @(Split-CsvList $AllowedPaths -AsPaths)
        $ignored = @(Split-CsvList $IgnoreDirtyPaths -AsPaths)
        $obsoletesList = @(Split-CsvList $Obsoletes)
        $targetTrim = $TargetRef.Trim()
        $targetCommitSha = ''
        if ($targetTrim) {
            if ($targetTrim.StartsWith('-')) {
                Fail "MECHANICAL_FAIL: invalid -TargetRef '$targetTrim'" 1
            }
            $trRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--verify', '--quiet', "${targetTrim}^{commit}")
            $targetCommitSha = $trRes.StdOut.Trim()
            if ($trRes.ExitCode -ne 0 -or -not $targetCommitSha) {
                Fail "MECHANICAL_FAIL: invalid -TargetRef '$targetTrim'" 1
            }
        }

        $resolvedBase = $BaseSha.Trim()
        if (-not $resolvedBase -or $resolvedBase -eq 'auto') {
            if ($targetTrim) {
                $resolvedBase = Resolve-AutoBaseForTarget $RepoRoot $targetCommitSha
            } else {
                $resolvedBase = Resolve-AutoBaseSha $RepoRoot $ignored
            }
        }

        [void](Assert-ValidGitRev $RepoRoot $resolvedBase 'object' 'MECHANICAL_FAIL' '-BaseSha')

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
            if (-not $p -or $p -match '^\.b3/(ship|autodev)(/|$)' -or (Test-PathMatch $p $ignored)) { continue }
            if (-not $allChanged.Contains($p)) { $allChanged.Add($p) }
        }
        foreach ($u in $untracked) {
            if (-not $u -or $u -match '^\.b3/(ship|autodev)(/|$)' -or (Test-PathMatch $u $ignored)) { continue }
            if (-not $allChanged.Contains($u)) { $allChanged.Add($u) }
        }

        $nonDelChanged = New-Object System.Collections.Generic.List[string]
        foreach ($row in ($nonDelRes.StdOut -split "\r?\n")) {
            $p = Normalize-PathValue ([string]$row)
            if (-not $p -or $p -match '^\.b3/(ship|autodev)(/|$)' -or (Test-PathMatch $p $ignored)) { continue }
            if (-not $nonDelChanged.Contains($p)) { $nonDelChanged.Add($p) }
        }
        foreach ($u in $untracked) {
            if (-not $u -or $u -match '^\.b3/(ship|autodev)(/|$)' -or (Test-PathMatch $u $ignored)) { continue }
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
                    $skipFile = (-not $curFile) -or ($curFile -match '^\.b3/(ship|autodev)(/|$)') -or (Test-PathMatch $curFile $ignored) -or (Test-NoiseFile $curFile) -or ($curFile -match '\.md$')
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
            if (-not $u -or $u -match '^\.b3/(ship|autodev)(/|$)' -or (Test-PathMatch $u $ignored) -or (Test-NoiseFile $u) -or ($u -match '\.md$')) { continue }
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

        $delTarget = if ($targetTrim) { $targetCommitSha } else { New-WorkingTreeOid $RepoRoot 'MECHANICAL_FAIL' }
        $delArgs = @('diff', '-M', '--diff-filter=D', '--name-only', $resolvedBase, $delTarget, '--')
        $delRes = Invoke-GitCommand $RepoRoot $delArgs
        if ($delRes.ExitCode -ne 0) {
            $detail = if ($delRes.StdErr.Trim()) { $delRes.StdErr.Trim() } else { $delRes.StdOut.Trim() }
            Fail ("MECHANICAL_FAIL: git diff --diff-filter=D failed: $detail") 1
        }
        $deletedList = New-Object System.Collections.Generic.List[string]
        foreach ($row in ($delRes.StdOut -split "\r?\n")) {
            $dp = Normalize-PathValue ([string]$row)
            if (-not $dp -or $dp -match '^\.b3/(ship|autodev)(/|$)' -or (Test-PathMatch $dp $ignored) -or (Test-NoiseFile $dp)) { continue }
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
                @('grep', '-l', '-F', '-e', $tok, $targetCommitSha, '--', '.', ':(exclude).b3/ship', ':(exclude).b3/autodev')
            } else {
                @('grep', '--untracked', '-l', '-F', '-e', $tok, '--', '.', ':(exclude).b3/ship', ':(exclude).b3/autodev')
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
                    if (-not $gp -or $gp -match '^\.b3/(ship|autodev)(/|$)' -or ($ignored -and (Test-PathMatch $gp $ignored))) { continue }
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

        $ShipDir = Join-Path $RepoRoot '.b3\ship'
        $runsDir = Join-Path $ShipDir 'runs'
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
        Write-AtomicLfFile (Join-Path $ShipDir 'CURRENT') "$candidate`n"

        Write-Output $candidate
        exit 0
    }

    'resolve-run' {
        $ShipDir = Join-Path $RepoRoot '.b3\ship'
        $runsDir = Join-Path $ShipDir 'runs'
        $AutodevDir = Join-Path $RepoRoot '.b3\autodev'
        $autodevRunsDir = Join-Path $AutodevDir 'runs'

        if ($RunId) {
            $trimmed = $RunId.Trim()
            if (-not (Test-ValidRunId $trimmed)) {
                Fail "RESOLVE_FAIL: invalid run id '$RunId'" 1
            }
            $target = Join-Path $runsDir $trimmed
            if (Test-Path -LiteralPath $target -PathType Container) {
                Write-Output ".b3/ship/runs/$trimmed"
                exit 0
            }
            $legacyTarget = Join-Path $autodevRunsDir $trimmed
            if (Test-Path -LiteralPath $legacyTarget -PathType Container) {
                Write-Output ".b3/autodev/runs/$trimmed"
                exit 0
            }
            Fail "RESOLVE_FAIL: run not found '$trimmed'" 1
        }

        $curFile = Join-Path $ShipDir 'CURRENT'
        if (Test-Path -LiteralPath $curFile -PathType Leaf) {
            $curId = ([IO.File]::ReadAllText($curFile)).Trim()
            if (-not (Test-ValidRunId $curId)) {
                Fail "RESOLVE_FAIL: CURRENT contains invalid run id '$curId'" 1
            }
            $target = Join-Path $runsDir $curId
            if (-not (Test-Path -LiteralPath $target -PathType Container)) {
                Fail "RESOLVE_FAIL: CURRENT points to missing run '$curId'" 1
            }
            Write-Output ".b3/ship/runs/$curId"
            exit 0
        }

        if (Test-Path -LiteralPath (Join-Path $ShipDir 'progress.md') -PathType Leaf) {
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

        Fail 'NO_ACTIVE_RUN' 1
    }

    'list-runs' {
        $ShipDir = Join-Path $RepoRoot '.b3\ship'
        $runsDir = Join-Path $ShipDir 'runs'
        $curId = Get-CurrentRunId $ShipDir

        $dirNames = @()
        if (Test-Path -LiteralPath $runsDir -PathType Container) {
            $rawNames = @(Get-ChildItem -LiteralPath $runsDir -Directory | ForEach-Object { $_.Name })
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

        if (Test-Path -LiteralPath (Join-Path $ShipDir 'progress.md') -PathType Leaf) {
            $st = Get-RunStatus $ShipDir
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

        Write-Output 'NO_RUNS'
        exit 0
    }

    'prune' {
        if ($Keep -lt 0) { Fail 'PRUNE_FAIL: -Keep must be >= 0' 1 }
        $dotB3Dir = Join-Path $RepoRoot '.b3'
        $ShipDir = Join-Path $dotB3Dir 'ship'
        $runsDir = Join-Path $ShipDir 'runs'
        if ((Test-IsReparsePath $dotB3Dir) -or (Test-IsReparsePath $ShipDir) -or (Test-IsReparsePath $runsDir)) {
            Fail 'PRUNE_FAIL: runs directory is a link' 1
        }
        if (-not (Test-Path -LiteralPath $runsDir -PathType Container)) {
            Write-Output 'PRUNE_OK: 0 removed'
            exit 0
        }

        $curId = Get-CurrentRunId $ShipDir
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
        $targetTrim = $TargetRef.Trim()
        $targetCommitSha = ''
        if ($targetTrim) {
            if ($targetTrim.StartsWith('-')) {
                Fail "SYMBOL_FAIL: invalid -TargetRef '$targetTrim'" 1
            }
            $trRes = Invoke-GitCommand $RepoRoot @('rev-parse', '--verify', '--quiet', "${targetTrim}^{commit}")
            $targetCommitSha = $trRes.StdOut.Trim()
            if ($trRes.ExitCode -ne 0 -or -not $targetCommitSha) {
                Fail "SYMBOL_FAIL: invalid -TargetRef '$targetTrim'" 1
            }
        }

        $resolvedBase = $BaseSha.Trim()
        if (-not $resolvedBase -or $resolvedBase -eq 'auto') {
            if ($targetTrim) {
                $resolvedBase = Resolve-AutoBaseForTarget $RepoRoot $targetCommitSha
            } else {
                $resolvedBase = Resolve-AutoBaseSha $RepoRoot $ignored
            }
        }

        [void](Assert-ValidGitRev $RepoRoot $resolvedBase 'object' 'SYMBOL_FAIL' '-BaseSha')

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
                    $skipOld = (-not $oldFile) -or ($oldFile -match '^\.b3/(ship|autodev)(/|$)') -or (Test-PathMatch $oldFile $ignored) -or (Test-NoiseFile $oldFile) -or (-not (Test-CodePath $oldFile))
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
                    $skipNew = (-not $newFile) -or ($newFile -match '^\.b3/(ship|autodev)(/|$)') -or (Test-PathMatch $newFile $ignored) -or (Test-NoiseFile $newFile) -or (-not (Test-CodePath $newFile))
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
                if (-not $u -or $u -match '^\.b3/(ship|autodev)(/|$)' -or (Test-PathMatch $u $ignored) -or (Test-NoiseFile $u) -or (-not (Test-CodePath $u))) { continue }
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
                        if (-not $np -or $np -match '^\.b3/(ship|autodev)(/|$)' -or (Test-PathMatch $np $ignored) -or (Test-NoiseFile $np) -or (-not (Test-CodePath $np))) { continue }
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
                        if (-not $np -or $np -match '^\.b3/(ship|autodev)(/|$)' -or (Test-PathMatch $np $ignored) -or (Test-NoiseFile $np) -or (-not (Test-CodePath $np))) { continue }
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
}
