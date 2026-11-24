# Dual-shell behavioral checks for MCP-aware context routing and b3-guard context-cache.
# Verifies routing contract, 6 workflow hooks + hint-only subagents, Iter 2+ cache reuse/invalidation,
# stale graph-index vs live-LSP semantics, security containment/tamper fail-closed, 4-host compat, and 0 always-on bloat.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate-context-routing.ps1
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'lib\global-test-helpers.ps1')

$guardPs = Join-Path $root 'scripts\b3-guard.ps1'
$guardShPosix = ($root -replace '\\', '/') + '/scripts/b3-guard.sh'
$measurePs = Join-Path $root 'scripts\measure-context.ps1'
$measureShPosix = ($root -replace '\\', '/') + '/scripts/measure-context.sh'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$isoEnc = [System.Text.Encoding]::GetEncoding(28591)

function To-Posix([string]$PathValue) {
    return ($PathValue -replace '\\', '/')
}

function Quote-BashArg([string]$Val) {
    if ($Val -match '["\x00-\x1F\x7F]') {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append("`$'")
        foreach ($ch in $Val.ToCharArray()) {
            $code = [int]$ch
            if ($ch -eq '\') { [void]$sb.Append('\\') }
            elseif ($ch -eq "'") { [void]$sb.Append("\'") }
            elseif ($ch -eq '"') { [void]$sb.Append('\x22') }
            elseif ($code -le 0x1F -or $code -eq 0x7F) { [void]$sb.Append(('\x{0:x2}' -f $code)) }
            else { [void]$sb.Append($ch) }
        }
        [void]$sb.Append("'")
        return $sb.ToString()
    }
    return ("'" + ($Val -replace "'", "'\''") + "'")
}

function Quote-PsSingle([string]$Val) {
    return ("'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Val) + "'")
}

function Write-LfFile([string]$PathValue, [string]$Text) {
    $parent = Split-Path -Parent $PathValue
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($PathValue, ($Text -replace "`r`n", "`n"), $utf8NoBom)
}

function Get-LfByteLength([string]$FullPath) {
    if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) { return -1 }
    return ($isoEnc.GetString([System.IO.File]::ReadAllBytes($FullPath)).Replace("`r", '')).Length
}

function Invoke-GitQuiet([string]$RepoDir, [string[]]$GitArgs) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & git -C $RepoDir @GitArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "git $($GitArgs -join ' ') failed in ${RepoDir}: $($out -join ' ')"
        }
        return (($out | ForEach-Object { ([string]$_).TrimEnd("`r") }) -join "`n").Trim()
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Init-GitRepo([string]$RepoDir) {
    New-Item -ItemType Directory -Path $RepoDir -Force | Out-Null
    [void](Invoke-GitQuiet $RepoDir @('init', '-q'))
    [void](Invoke-GitQuiet $RepoDir @('symbolic-ref', 'HEAD', 'refs/heads/main'))
    [void](Invoke-GitQuiet $RepoDir @('config', 'user.email', 'ctx-test@example.com'))
    [void](Invoke-GitQuiet $RepoDir @('config', 'user.name', 'Context Test'))
}

function Invoke-PsGuard([string[]]$GuardArgs) {
    return (Invoke-PsScript -ScriptPath $guardPs -ScriptArgs $GuardArgs)
}

function Invoke-ShScriptArgs([string]$ScriptPosix, [string[]]$ScriptArgs) {
    if (-not $script:HasBash) {
        return @{ Code = 127; Lines = @('bash not found'); Text = 'bash not found' }
    }
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add((Quote-BashArg $ScriptPosix))
    foreach ($a in @($ScriptArgs)) {
        $parts.Add((Quote-BashArg ([string]$a)))
    }
    $bashCmd = $parts -join ' '
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & $script:GitBash -c $bashCmd 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    $lines = @($raw | ForEach-Object { ([string]$_).TrimEnd("`r") })
    return @{ Code = $code; Lines = $lines; Text = ($lines -join "`n") }
}

function Invoke-ShGuard([string[]]$GuardArgs) {
    return (Invoke-ShScriptArgs -ScriptPosix $guardShPosix -ScriptArgs $GuardArgs)
}

function Assert-Parity {
    param(
        [Parameter(Mandatory = $true)][hashtable]$PsRes,
        [Parameter(Mandatory = $true)][hashtable]$ShRes,
        [Parameter(Mandatory = $true)][int]$ExpectedCode,
        [string]$MatchPattern = '',
        [string]$Label = ''
    )
    if ($PsRes.Code -ne $ExpectedCode) {
        return "[$Label] PS exit=$($PsRes.Code) expected=$ExpectedCode out=$($PsRes.Text)"
    }
    if ($MatchPattern -and ($PsRes.Text -notmatch $MatchPattern)) {
        return "[$Label] PS output did not match /$MatchPattern/ :: $($PsRes.Text)"
    }
    if ($script:HasBash) {
        if ($PsRes.Code -ne $ShRes.Code) {
            return "[$Label] code parity mismatch PS=$($PsRes.Code) SH=$($ShRes.Code) PS_OUT=$($PsRes.Text) SH_OUT=$($ShRes.Text)"
        }
        if ($PsRes.Text -cne $ShRes.Text) {
            return "[$Label] text parity mismatch PS=[$($PsRes.Text)] SH=[$($ShRes.Text)]"
        }
    }
    return ''
}

function Test-ParityCommand {
    param(
        [string[]]$PsArgs,
        [string[]]$ShArgs,
        [int]$ExpectedCode,
        [string]$MatchPattern = '',
        [string]$Label = '',
        [switch]$NoGlob,
        [switch]$NoPathConv
    )
    $ps = Invoke-PsGuard $PsArgs
    $prevMsys = $env:MSYS
    $prevConv = $env:MSYS_NO_PATHCONV
    try {
        if ($NoGlob) { $env:MSYS = 'noglob' }
        if ($NoPathConv) { $env:MSYS_NO_PATHCONV = '1' }
        $sh = Invoke-ShGuard $ShArgs
    } finally {
        if ($NoGlob) {
            if ($null -eq $prevMsys) { Remove-Item Env:MSYS -ErrorAction SilentlyContinue } else { $env:MSYS = $prevMsys }
        }
        if ($NoPathConv) {
            if ($null -eq $prevConv) { Remove-Item Env:MSYS_NO_PATHCONV -ErrorAction SilentlyContinue } else { $env:MSYS_NO_PATHCONV = $prevConv }
        }
    }
    return @{
        Err = (Assert-Parity -PsRes $ps -ShRes $sh -ExpectedCode $ExpectedCode -MatchPattern $MatchPattern -Label $Label)
        Ps  = $ps
        Sh  = $sh
    }
}

function Test-RecordParity {
    param(
        [Parameter(Mandatory = $true)][string]$RepoDir,
        [Parameter(Mandatory = $true)][string]$BaseCacheRel,
        [Parameter(Mandatory = $true)][string[]]$PsExtraArgs,
        [Parameter(Mandatory = $true)][string[]]$ShExtraArgs,
        [string]$MatchPattern = '^CONTEXT_RECORDED: ',
        [string]$Label = ''
    )
    $psRel = "$BaseCacheRel-ps.ctx"
    $shRel = "$BaseCacheRel-sh.ctx"
    $repoP = To-Posix $RepoDir

    $ps = Invoke-PsGuard (@('context-cache', '-RepoRoot', $RepoDir, '-Action', 'record', '-CachePath', $psRel) + $PsExtraArgs)
    if ($ps.Code -ne 0) {
        return @{ Ok = $false; Err = "[$Label] PS record exit=$($ps.Code) out=$($ps.Text)"; PsRel = $psRel; ShRel = $shRel; PsFull = '' }
    }
    if ($MatchPattern -and ($ps.Text -notmatch $MatchPattern)) {
        return @{ Ok = $false; Err = "[$Label] PS record did not match /$MatchPattern/ :: $($ps.Text)"; PsRel = $psRel; ShRel = $shRel; PsFull = '' }
    }
    $psFull = Join-Path $RepoDir ($psRel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $psFull -PathType Leaf)) {
        return @{ Ok = $false; Err = "[$Label] PS cache missing: $psFull"; PsRel = $psRel; ShRel = $shRel; PsFull = '' }
    }
    $psBytes = [System.IO.File]::ReadAllBytes($psFull)
    if ($psBytes.Length -ge 3 -and $psBytes[0] -eq 0xEF -and $psBytes[1] -eq 0xBB -and $psBytes[2] -eq 0xBF) {
        return @{ Ok = $false; Err = "[$Label] PS cache has UTF-8 BOM"; PsRel = $psRel; ShRel = $shRel; PsFull = '' }
    }
    $psRaw = $isoEnc.GetString($psBytes)
    if ($psRaw.Contains("`r")) {
        return @{ Ok = $false; Err = "[$Label] PS cache contains CR"; PsRel = $psRel; ShRel = $shRel; PsFull = '' }
    }

    if ($script:HasBash) {
        $sh = Invoke-ShGuard (@('context-cache', '--repo-root', $repoP, '--action', 'record', '--cache-path', $shRel) + $ShExtraArgs)
        if ($sh.Code -ne 0) {
            return @{ Ok = $false; Err = "[$Label] SH record exit=$($sh.Code) out=$($sh.Text)"; PsRel = $psRel; ShRel = $shRel; PsFull = '' }
        }
        $psNormOut = $ps.Text.Replace($psRel, '<CACHE>')
        $shNormOut = $sh.Text.Replace($shRel, '<CACHE>')
        if ($psNormOut -cne $shNormOut) {
            return @{ Ok = $false; Err = "[$Label] record stdout parity mismatch PS=[$($ps.Text)] SH=[$($sh.Text)]"; PsRel = $psRel; ShRel = $shRel; PsFull = '' }
        }
        $shFull = Join-Path $RepoDir ($shRel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $shFull -PathType Leaf)) {
            return @{ Ok = $false; Err = "[$Label] SH cache missing: $shFull"; PsRel = $psRel; ShRel = $shRel; PsFull = '' }
        }
        $shBytes = [System.IO.File]::ReadAllBytes($shFull)
        if ($shBytes.Length -ge 3 -and $shBytes[0] -eq 0xEF -and $shBytes[1] -eq 0xBB -and $shBytes[2] -eq 0xBF) {
            return @{ Ok = $false; Err = "[$Label] SH cache has UTF-8 BOM"; PsRel = $psRel; ShRel = $shRel; PsFull = '' }
        }
        $shRaw = $isoEnc.GetString($shBytes)
        if ($shRaw.Contains("`r")) {
            return @{ Ok = $false; Err = "[$Label] SH cache contains CR"; PsRel = $psRel; ShRel = $shRel; PsFull = '' }
        }
        $psNormBody = [regex]::Replace($psRaw, '(?m)^timestamp_utc=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$', 'timestamp_utc=<TS>')
        $shNormBody = [regex]::Replace($shRaw, '(?m)^timestamp_utc=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$', 'timestamp_utc=<TS>')
        if ($psNormBody -cne $shNormBody) {
            return @{ Ok = $false; Err = "[$Label] written file parity mismatch PS=[$psNormBody] SH=[$shNormBody]"; PsRel = $psRel; ShRel = $shRel; PsFull = '' }
        }
    }
    return @{ Ok = $true; Err = ''; PsRel = $psRel; ShRel = $shRel; PsFull = $psFull }
}

function Test-CrossShellCheck {
    param(
        [Parameter(Mandatory = $true)][string]$RepoDir,
        [Parameter(Mandatory = $true)][string]$PsCacheRel,
        [Parameter(Mandatory = $true)][string]$ShCacheRel,
        [Parameter(Mandatory = $true)][string[]]$PsExtraArgs,
        [Parameter(Mandatory = $true)][string[]]$ShExtraArgs,
        [Parameter(Mandatory = $true)][int]$ExpectedCode,
        [string]$MatchPattern = '',
        [string]$Label = ''
    )
    $repoP = To-Posix $RepoDir
    $rPsFile = Test-ParityCommand -Label "$Label-on-ps-file" -ExpectedCode $ExpectedCode -MatchPattern $MatchPattern `
        -PsArgs (@('context-cache', '-RepoRoot', $RepoDir, '-Action', 'check', '-CachePath', $PsCacheRel) + $PsExtraArgs) `
        -ShArgs (@('context-cache', '--repo-root', $repoP, '--action', 'check', '--cache-path', $PsCacheRel) + $ShExtraArgs)
    if ($rPsFile.Err) { return $rPsFile.Err }
    if ($script:HasBash) {
        $rShFile = Test-ParityCommand -Label "$Label-on-sh-file" -ExpectedCode $ExpectedCode -MatchPattern $MatchPattern `
            -PsArgs (@('context-cache', '-RepoRoot', $RepoDir, '-Action', 'check', '-CachePath', $ShCacheRel) + $PsExtraArgs) `
            -ShArgs (@('context-cache', '--repo-root', $repoP, '--action', 'check', '--cache-path', $ShCacheRel) + $ShExtraArgs)
        if ($rShFile.Err) { return $rShFile.Err }
        if ($rPsFile.Ps.Text -cne $rShFile.Ps.Text) {
            return "[$Label] cross-file output mismatch PS_FILE=[$($rPsFile.Ps.Text)] SH_FILE=[$($rShFile.Ps.Text)]"
        }
    }
    return ''
}

$sandbox = Join-Path $env:TEMP ('b3-context-routing-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
$prevSkipModel = $env:B3_SKIP_MODEL_INIT
$prevModelsPersonal = $env:B3_MODELS_PERSONAL
$env:B3_SKIP_MODEL_INIT = '1'
$env:B3_MODELS_PERSONAL = Join-Path $sandbox 'isolated-models.md'

try {
    # =========================================================================
    # Group 1: routing-contract-coverage
    # =========================================================================
    $g1Errs = New-Object System.Collections.Generic.List[string]
    $crPath = Join-Path $root 'workflows\references\context-routing.md'
    $crBytes = Get-LfByteLength $crPath
    if ($crBytes -lt 1 -or $crBytes -gt 3200) {
        $g1Errs.Add("context-routing.md size=$crBytes B (must be 1..3200 B LF)")
    } else {
        $crText = Get-Content -LiteralPath $crPath -Raw
        $requiredPatterns = @(
            @{ Name = 'combo-both'; Pat = '`both`:' },
            @{ Name = 'combo-codebase-memory'; Pat = '`codebase-memory` only:' },
            @{ Name = 'combo-serena'; Pat = '`serena` only:' },
            @{ Name = 'combo-neither-native'; Pat = '`neither`:.*native' },
            @{ Name = 'one-primary-per-need'; Pat = '1 primary per need' },
            @{ Name = 'direct-known-short-circuit'; Pat = 'direct-known short-circuit' },
            @{ Name = 'bounded-outputs'; Pat = 'bounded slices.*never dump repos' },
            @{ Name = 'staleness-graph-vs-lsp'; Pat = 'commit-indexed.*graph_index_sha.*Live LSP `serena`.*working tree' },
            @{ Name = 'review-loop-iter1-diff-first'; Pat = 'Review Loop Iter 1 \(diff-first\)' },
            @{ Name = 'review-loop-iter2-delta-first'; Pat = 'Review Loop Iter 2\+ \(delta-first\)' },
            @{ Name = 'research-ship-repo-evidence'; Pat = 'Research Ship:.*`repo-evidence`.*`evidence-check`' },
            @{ Name = 'graceful-fallback-no-false-pass'; Pat = 'Graceful failure:.*native fallback.*never false `PASS`' }
        )
        foreach ($req in $requiredPatterns) {
            if ($crText -notmatch $req.Pat) {
                $g1Errs.Add("missing $($req.Name)")
            }
        }
    }
    if ($g1Errs.Count -eq 0) { Pass 'routing-contract-coverage' } else { FailCheck 'routing-contract-coverage' ($g1Errs -join '; ') }

    # =========================================================================
    # Group 2: six-workflow-hooks-and-hint-only
    # =========================================================================
    $g2Errs = New-Object System.Collections.Generic.List[string]
    $hookFiles = @(
        @{ Rel = 'workflows\ship.md'; Pats = @('context-routing\.md', 'context_hint:') },
        @{ Rel = 'workflows\research-ship.md'; Pats = @('context-routing\.md', 'repo-evidence') },
        @{ Rel = 'workflows\references\research-ship-gates.md'; Pats = @('context-routing\.md', 'repo-evidence') },
        @{ Rel = 'skills\engineering\code-review\SKILL.md'; Pats = @('context-routing\.md', 'on demand') },
        @{ Rel = 'review-loop\strategy.md'; Pats = @('context-routing\.md', 'context_hint:') },
        @{ Rel = 'review-loop\hierarchical.md'; Pats = @('context-routing\.md', 'context_hint:') },
        @{ Rel = 'skills\engineering\debugging\SKILL.md'; Pats = @('context-routing\.md', 'on demand') },
        @{ Rel = 'skills\engineering\problem-solving\SKILL.md'; Pats = @('context-routing\.md', 'on demand') },
        @{ Rel = 'workflows\feature-implementation.md'; Pats = @('context-routing\.md', 'on demand') }
    )
    foreach ($hf in $hookFiles) {
        $fp = Join-Path $root $hf.Rel
        if (-not (Test-Path -LiteralPath $fp -PathType Leaf)) {
            $g2Errs.Add("missing $($hf.Rel)")
            continue
        }
        $txt = Get-Content -LiteralPath $fp -Raw
        foreach ($pat in $hf.Pats) {
            if ($txt -notmatch $pat) {
                $g2Errs.Add("$($hf.Rel) missing /$pat/")
            }
        }
    }
    foreach ($agRel in @('agents\b3-reviewer.md', 'agents\b3-fixer.md')) {
        $afp = Join-Path $root $agRel
        if (-not (Test-Path -LiteralPath $afp -PathType Leaf)) {
            $g2Errs.Add("missing $agRel")
            continue
        }
        $atxt = Get-Content -LiteralPath $afp -Raw
        if ($atxt -notmatch 'context_hint:') { $g2Errs.Add("$agRel missing context_hint:") }
        if ($atxt -notmatch 'hint-only') { $g2Errs.Add("$agRel missing hint-only") }
        if ($atxt -notmatch 'never load `context-routing\.md`') { $g2Errs.Add("$agRel missing explicit no-reload rule") }
    }
    if ($g2Errs.Count -eq 0) { Pass 'six-workflow-hooks-and-hint-only' } else { FailCheck 'six-workflow-hooks-and-hint-only' ($g2Errs -join '; ') }

    # =========================================================================
    # Group 3: context-cache-iter2-reuse-and-invalidation
    # =========================================================================
    $g3Errs = New-Object System.Collections.Generic.List[string]
    $rCache = Join-Path $sandbox 'cache-repo'
    $rCacheP = To-Posix $rCache
    Init-GitRepo $rCache

    Write-LfFile (Join-Path $rCache 'src\contracts\order.ts') "export interface Order { id: string; total: number; }`n"
    Write-LfFile (Join-Path $rCache 'src\deps\auth.ts') "export function verifyToken(t: string): boolean { return t.length > 0; }`n"
    Write-LfFile (Join-Path $rCache 'src\orders\handler.ts') "export function handleOrder(id: string): string { return id; }`n"
    [void](Invoke-GitQuiet $rCache @('add', '.'))
    [void](Invoke-GitQuiet $rCache @('commit', '-qm', 'init order module'))
    $c1Sha = Invoke-GitQuiet $rCache @('rev-parse', 'HEAD')

    $sumRel = '.b3/ship/ctx/sum.md'
    $sumFull = Join-Path $rCache '.b3\ship\ctx\sum.md'
    $sumInit = "# Iter 1 Summary`nAnchors: order contract + auth dep`n"
    Write-LfFile $sumFull $sumInit
    $anchorsCsv = 'src/contracts/order.ts,src/deps/auth.ts'

    # Iter 1 record to distinct -ps.ctx and -sh.ctx files (verify stdout + LF/no-BOM/field parity)
    $r1 = Test-RecordParity -RepoDir $rCache -BaseCacheRel '.b3/ship/ctx/iter1' -Label 'iter1-record' `
        -MatchPattern '^CONTEXT_RECORDED: \.b3/ship/ctx/iter1-ps\.ctx scope=rl-iter1 ' `
        -PsExtraArgs @('-ScopeId', 'rl-iter1', '-AnchorPaths', $anchorsCsv, '-SummaryRef', $sumRel, '-GraphIndexSha', 'none') `
        -ShExtraArgs @('--scope-id', 'rl-iter1', '--anchor-paths', $anchorsCsv, '--summary-ref', $sumRel, '--graph-index-sha', 'none')
    if ($r1.Err) { $g3Errs.Add($r1.Err) }
    $c1PsRel = $r1.PsRel
    $c1ShRel = $r1.ShRel

    # Snapshot prev_sha before Fixer edits mutable file
    $snap = Test-ParityCommand -Label 'iter1-snapshot' -ExpectedCode 0 -MatchPattern '^[0-9a-f]{40}$' `
        -PsArgs @('snapshot', '-RepoRoot', $rCache) `
        -ShArgs @('snapshot', '--repo-root', $rCacheP)
    if ($snap.Err) { $g3Errs.Add($snap.Err) }
    $prevSha = $snap.Ps.Text.Trim()

    # Fixer edits mutable src/orders/handler.ts (uncommitted) — cross-shell check BOTH -ps.ctx and -sh.ctx
    Write-LfFile (Join-Path $rCache 'src\orders\handler.ts') "export function handleOrder(id: string): string { return id.trim(); }`n"

    $err = Test-CrossShellCheck -RepoDir $rCache -PsCacheRel $c1PsRel -ShCacheRel $c1ShRel -Label 'iter2-uncommitted-fresh' -ExpectedCode 0 `
        -MatchPattern '^CONTEXT_FRESH: scope=rl-iter1 head=[0-9a-f]{40} anchor_status=FRESH graph_index=NOT_RECORDED live_lsp_eligible=true$' `
        -PsExtraArgs @('-ScopeId', 'rl-iter1', '-AnchorPaths', $anchorsCsv, '-SummaryRef', $sumRel) `
        -ShExtraArgs @('--scope-id', 'rl-iter1', '--anchor-paths', $anchorsCsv, '--summary-ref', $sumRel)
    if ($err) { $g3Errs.Add($err) }

    $dsUncomm = Test-ParityCommand -Label 'iter2-uncommitted-delta' -ExpectedCode 0 `
        -MatchPattern '(?m)^delta_files=src/orders/handler\.ts$' `
        -PsArgs @('diff-scope', '-RepoRoot', $rCache, '-BaseSha', $c1Sha, '-PrevSha', $prevSha) `
        -ShArgs @('diff-scope', '--repo-root', $rCacheP, '--base-sha', $c1Sha, '--prev-sha', $prevSha)
    if ($dsUncomm.Err) { $g3Errs.Add($dsUncomm.Err) }

    # Fixer forward-commits src/orders/handler.ts — cross-shell check BOTH -ps.ctx and -sh.ctx
    [void](Invoke-GitQuiet $rCache @('add', 'src/orders/handler.ts'))
    [void](Invoke-GitQuiet $rCache @('commit', '-qm', 'fix handler'))

    $err = Test-CrossShellCheck -RepoDir $rCache -PsCacheRel $c1PsRel -ShCacheRel $c1ShRel -Label 'iter2-forward-commit-fresh' -ExpectedCode 0 `
        -MatchPattern '^CONTEXT_FRESH: scope=rl-iter1 head=[0-9a-f]{40} anchor_status=FRESH graph_index=NOT_RECORDED live_lsp_eligible=true$' `
        -PsExtraArgs @('-ScopeId', 'rl-iter1', '-AnchorPaths', $anchorsCsv, '-SummaryRef', $sumRel) `
        -ShExtraArgs @('--scope-id', 'rl-iter1', '--anchor-paths', $anchorsCsv, '--summary-ref', $sumRel)
    if ($err) { $g3Errs.Add($err) }

    $dsComm = Test-ParityCommand -Label 'iter2-forward-commit-delta' -ExpectedCode 0 `
        -MatchPattern '(?m)^delta_files=src/orders/handler\.ts$' `
        -PsArgs @('diff-scope', '-RepoRoot', $rCache, '-BaseSha', $c1Sha, '-PrevSha', $prevSha) `
        -ShArgs @('diff-scope', '--repo-root', $rCacheP, '--base-sha', $c1Sha, '--prev-sha', $prevSha)
    if ($dsComm.Err) { $g3Errs.Add($dsComm.Err) }

    # Invalidation 1: changed dependency (src/deps/auth.ts)
    Write-LfFile (Join-Path $rCache 'src\deps\auth.ts') "export function verifyToken(t: string): boolean { return t.startsWith('v2:'); }`n"
    $err = Test-CrossShellCheck -RepoDir $rCache -PsCacheRel $c1PsRel -ShCacheRel $c1ShRel -Label 'inv-dep-changed' -ExpectedCode 2 `
        -MatchPattern '^CONTEXT_STALE: scope=rl-iter1 reasons=anchor_changed anchor_status=STALE graph_index=NOT_RECORDED live_lsp_eligible=true$' `
        -PsExtraArgs @('-ScopeId', 'rl-iter1') `
        -ShExtraArgs @('--scope-id', 'rl-iter1')
    if ($err) { $g3Errs.Add($err) }
    [void](Invoke-GitQuiet $rCache @('checkout', '--', 'src/deps/auth.ts'))

    # Invalidation 2: changed shared contract (src/contracts/order.ts)
    Write-LfFile (Join-Path $rCache 'src\contracts\order.ts') "export interface Order { id: string; total: number; currency: string; }`n"
    $err = Test-CrossShellCheck -RepoDir $rCache -PsCacheRel $c1PsRel -ShCacheRel $c1ShRel -Label 'inv-contract-changed' -ExpectedCode 2 `
        -MatchPattern '^CONTEXT_STALE: scope=rl-iter1 reasons=anchor_changed anchor_status=STALE graph_index=NOT_RECORDED live_lsp_eligible=true$' `
        -PsExtraArgs @('-ScopeId', 'rl-iter1') `
        -ShExtraArgs @('--scope-id', 'rl-iter1')
    if ($err) { $g3Errs.Add($err) }
    [void](Invoke-GitQuiet $rCache @('checkout', '--', 'src/contracts/order.ts'))

    # Invalidation 3: changed summary_ref digest
    Write-LfFile $sumFull "# Iter 1 Summary`nMutated digest`n"
    $err = Test-CrossShellCheck -RepoDir $rCache -PsCacheRel $c1PsRel -ShCacheRel $c1ShRel -Label 'inv-summary-changed' -ExpectedCode 2 `
        -MatchPattern '^CONTEXT_STALE: scope=rl-iter1 reasons=summary_changed anchor_status=FRESH graph_index=NOT_RECORDED live_lsp_eligible=true$' `
        -PsExtraArgs @('-ScopeId', 'rl-iter1') `
        -ShExtraArgs @('--scope-id', 'rl-iter1')
    if ($err) { $g3Errs.Add($err) }
    Write-LfFile $sumFull $sumInit

    # Invalidation 4: diverged HEAD (record at c2 to distinct -ps.ctx/-sh.ctx, then git reset --hard HEAD~1)
    $recC2 = Test-RecordParity -RepoDir $rCache -BaseCacheRel '.b3/ship/ctx/iter2' -Label 'record-at-c2' `
        -PsExtraArgs @('-ScopeId', 'rl-iter1', '-AnchorPaths', $anchorsCsv, '-SummaryRef', $sumRel, '-GraphIndexSha', 'none') `
        -ShExtraArgs @('--scope-id', 'rl-iter1', '--anchor-paths', $anchorsCsv, '--summary-ref', $sumRel, '--graph-index-sha', 'none')
    if ($recC2.Err) { $g3Errs.Add($recC2.Err) }
    [void](Invoke-GitQuiet $rCache @('reset', '--hard', '-q', 'HEAD~1'))
    $err = Test-CrossShellCheck -RepoDir $rCache -PsCacheRel $recC2.PsRel -ShCacheRel $recC2.ShRel -Label 'inv-head-diverged' -ExpectedCode 2 `
        -MatchPattern '^CONTEXT_STALE: scope=rl-iter1 reasons=head_diverged anchor_status=STALE graph_index=NOT_RECORDED live_lsp_eligible=true$' `
        -PsExtraArgs @('-ScopeId', 'rl-iter1') `
        -ShExtraArgs @('--scope-id', 'rl-iter1')
    if ($err) { $g3Errs.Add($err) }

    if ($g3Errs.Count -eq 0) { Pass 'context-cache-iter2-reuse-and-invalidation' } else { FailCheck 'context-cache-iter2-reuse-and-invalidation' ($g3Errs -join '; ') }

    # =========================================================================
    # Group 4: stale-graph-index-vs-live-lsp
    # =========================================================================
    $g4Errs = New-Object System.Collections.Generic.List[string]
    $subOrigin = Join-Path $sandbox 'sub-origin'
    Init-GitRepo $subOrigin
    Write-LfFile (Join-Path $subOrigin 'sub.ts') "export const subVer = 1;`n"
    [void](Invoke-GitQuiet $subOrigin @('add', '.'))
    [void](Invoke-GitQuiet $subOrigin @('commit', '-qm', 'init sub'))

    $rGraph = Join-Path $sandbox 'graph-repo'
    $rGraphP = To-Posix $rGraph
    Init-GitRepo $rGraph
    Write-LfFile (Join-Path $rGraph 'src\anchor.ts') "export const A = 1;`n"
    Write-LfFile (Join-Path $rGraph 'src\scope\mod.ts') "export const M = 1;`n"
    Write-LfFile (Join-Path $rGraph 'src\other.ts') "export const O = 1;`n"
    Write-LfFile (Join-Path $rGraph 'src\new_anchor.ts') "export const N = 1;`n"
    [void](Invoke-GitQuiet $rGraph @('add', '.'))
    [void](Invoke-GitQuiet $rGraph @('commit', '-qm', 'init graph repo'))
    [void](Invoke-GitQuiet $rGraph @('-c', 'protocol.file.allow=always', 'submodule', 'add', '-q', (To-Posix $subOrigin), 'libs/sub'))
    [void](Invoke-GitQuiet $rGraph @('commit', '-qm', 'add submodule'))
    $gHead = Invoke-GitQuiet $rGraph @('rev-parse', 'HEAD')
    $otherBlob = Invoke-GitQuiet $rGraph @('rev-parse', 'HEAD:src/other.ts')

    $gRec = Test-RecordParity -RepoDir $rGraph -BaseCacheRel '.b3/ship/ctx/graph' -Label 'graph-record' `
        -MatchPattern "^CONTEXT_RECORDED: \.b3/ship/ctx/graph-ps\.ctx scope=graph-scope head=$gHead anchor_hash=[0-9a-f]{40} graph_index_sha=$gHead$" `
        -PsExtraArgs @('-ScopeId', 'graph-scope', '-AnchorPaths', 'src/anchor.ts', '-GraphIndexSha', $gHead) `
        -ShExtraArgs @('--scope-id', 'graph-scope', '--anchor-paths', 'src/anchor.ts', '--graph-index-sha', $gHead)
    if ($gRec.Err) { $g4Errs.Add($gRec.Err) }
    $gPsRel = $gRec.PsRel
    $gShRel = $gRec.ShRel

    # 4a. Clean -> CONTEXT_FRESH across both -ps.ctx and -sh.ctx
    $err = Test-CrossShellCheck -RepoDir $rGraph -PsCacheRel $gPsRel -ShCacheRel $gShRel -Label 'graph-clean' -ExpectedCode 0 `
        -MatchPattern "^CONTEXT_FRESH: scope=graph-scope head=$gHead anchor_status=FRESH graph_index=FRESH live_lsp_eligible=true$" `
        -PsExtraArgs @('-ScopeId', 'graph-scope') `
        -ShExtraArgs @('--scope-id', 'graph-scope')
    if ($err) { $g4Errs.Add($err) }

    # 4b. Dirty WT outside anchors with omitted -ScopePaths -> CONTEXT_STALE across both -ps.ctx and -sh.ctx
    Write-LfFile (Join-Path $rGraph 'src\other.ts') "export const O = 2;`n"
    $err = Test-CrossShellCheck -RepoDir $rGraph -PsCacheRel $gPsRel -ShCacheRel $gShRel -Label 'graph-dirty-wt-no-scope' -ExpectedCode 2 `
        -MatchPattern '^CONTEXT_STALE: scope=graph-scope reasons=graph_index_stale anchor_status=FRESH graph_index=STALE live_lsp_eligible=true$' `
        -PsExtraArgs @('-ScopeId', 'graph-scope') `
        -ShExtraArgs @('--scope-id', 'graph-scope')
    if ($err) { $g4Errs.Add($err) }
    [void](Invoke-GitQuiet $rGraph @('checkout', '--', 'src/other.ts'))

    # 4c. Dirty WT inside explicit -ScopePaths -> CONTEXT_STALE
    Write-LfFile (Join-Path $rGraph 'src\scope\mod.ts') "export const M = 2;`n"
    $gDirtyInScope = Test-ParityCommand -Label 'graph-dirty-in-scope' -ExpectedCode 2 `
        -MatchPattern '^CONTEXT_STALE: scope=graph-scope reasons=graph_index_stale anchor_status=FRESH graph_index=STALE live_lsp_eligible=true$' `
        -PsArgs @('context-cache', '-RepoRoot', $rGraph, '-Action', 'check', '-CachePath', $gPsRel, '-ScopeId', 'graph-scope', '-ScopePaths', 'src/scope/mod.ts') `
        -ShArgs @('context-cache', '--repo-root', $rGraphP, '--action', 'check', '--cache-path', $gPsRel, '--scope-id', 'graph-scope', '--scope-paths', 'src/scope/mod.ts')
    if ($gDirtyInScope.Err) { $g4Errs.Add($gDirtyInScope.Err) }
    [void](Invoke-GitQuiet $rGraph @('checkout', '--', 'src/scope/mod.ts'))

    # 4d. Staged rename (R) including src-only ignored (STALE), dest-only ignored (STALE), both ignored (FRESH), and literal ' -> ' filename (--porcelain -z)
    [void](Invoke-GitQuiet $rGraph @('mv', 'src/other.ts', 'src/other-renamed.ts'))
    $gRenSrcIgn = Test-ParityCommand -Label 'graph-staged-rename-src-only-ign' -ExpectedCode 2 `
        -MatchPattern '^CONTEXT_STALE: scope=graph-scope reasons=graph_index_stale anchor_status=FRESH graph_index=STALE live_lsp_eligible=true$' `
        -PsArgs @('context-cache', '-RepoRoot', $rGraph, '-Action', 'check', '-CachePath', $gPsRel, '-ScopeId', 'graph-scope', '-IgnoreDirtyPaths', 'src/other.ts') `
        -ShArgs @('context-cache', '--repo-root', $rGraphP, '--action', 'check', '--cache-path', $gPsRel, '--scope-id', 'graph-scope', '--ignore-dirty-paths', 'src/other.ts')
    if ($gRenSrcIgn.Err) { $g4Errs.Add($gRenSrcIgn.Err) }

    $gRenDstIgn = Test-ParityCommand -Label 'graph-staged-rename-dest-only-ign' -ExpectedCode 2 `
        -MatchPattern '^CONTEXT_STALE: scope=graph-scope reasons=graph_index_stale anchor_status=FRESH graph_index=STALE live_lsp_eligible=true$' `
        -PsArgs @('context-cache', '-RepoRoot', $rGraph, '-Action', 'check', '-CachePath', $gPsRel, '-ScopeId', 'graph-scope', '-IgnoreDirtyPaths', 'src/other-renamed.ts') `
        -ShArgs @('context-cache', '--repo-root', $rGraphP, '--action', 'check', '--cache-path', $gPsRel, '--scope-id', 'graph-scope', '--ignore-dirty-paths', 'src/other-renamed.ts')
    if ($gRenDstIgn.Err) { $g4Errs.Add($gRenDstIgn.Err) }

    $gRenBothIgn = Test-ParityCommand -Label 'graph-staged-rename-both-ign' -ExpectedCode 0 `
        -MatchPattern "^CONTEXT_FRESH: scope=graph-scope head=$gHead anchor_status=FRESH graph_index=FRESH live_lsp_eligible=true$" `
        -PsArgs @('context-cache', '-RepoRoot', $rGraph, '-Action', 'check', '-CachePath', $gPsRel, '-ScopeId', 'graph-scope', '-IgnoreDirtyPaths', 'src/other.ts,src/other-renamed.ts') `
        -ShArgs @('context-cache', '--repo-root', $rGraphP, '--action', 'check', '--cache-path', $gPsRel, '--scope-id', 'graph-scope', '--ignore-dirty-paths', 'src/other.ts,src/other-renamed.ts')
    if ($gRenBothIgn.Err) { $g4Errs.Add($gRenBothIgn.Err) }
    [void](Invoke-GitQuiet $rGraph @('reset', '--hard', '-q', 'HEAD'))

    [void](Invoke-GitQuiet $rGraph @('rm', '-q', 'src/other.ts'))
    [void](Invoke-GitQuiet $rGraph @('-c', 'core.protectNTFS=false', 'update-index', '--add', '--cacheinfo', "100644,$otherBlob,src/a -> b.ts"))
    $gRenArrow = Test-ParityCommand -Label 'graph-staged-rename-arrow' -ExpectedCode 2 `
        -MatchPattern '^CONTEXT_STALE: scope=graph-scope reasons=graph_index_stale anchor_status=FRESH graph_index=STALE live_lsp_eligible=true$' `
        -PsArgs @('context-cache', '-RepoRoot', $rGraph, '-Action', 'check', '-CachePath', $gPsRel, '-ScopeId', 'graph-scope', '-IgnoreDirtyPaths', 'src/other.ts') `
        -ShArgs @('context-cache', '--repo-root', $rGraphP, '--action', 'check', '--cache-path', $gPsRel, '--scope-id', 'graph-scope', '--ignore-dirty-paths', 'src/other.ts')
    if ($gRenArrow.Err) { $g4Errs.Add($gRenArrow.Err) }
    [void](Invoke-GitQuiet $rGraph @('reset', '--hard', '-q', 'HEAD'))

    # 4e. Changed -AnchorPaths + -ScopePaths with dirty newly added anchor (callerAnchorArr) -> anchor_scope_changed,graph_index_stale
    Write-LfFile (Join-Path $rGraph 'src\new_anchor.ts') "export const N = 2;`n"
    $gNewAnc = Test-ParityCommand -Label 'graph-caller-new-anchor-dirty' -ExpectedCode 2 `
        -MatchPattern '^CONTEXT_STALE: scope=graph-scope reasons=anchor_scope_changed,graph_index_stale anchor_status=STALE graph_index=STALE live_lsp_eligible=true$' `
        -PsArgs @('context-cache', '-RepoRoot', $rGraph, '-Action', 'check', '-CachePath', $gPsRel, '-ScopeId', 'graph-scope', '-AnchorPaths', 'src/anchor.ts,src/new_anchor.ts', '-ScopePaths', 'src/scope/mod.ts') `
        -ShArgs @('context-cache', '--repo-root', $rGraphP, '--action', 'check', '--cache-path', $gPsRel, '--scope-id', 'graph-scope', '--anchor-paths', 'src/anchor.ts,src/new_anchor.ts', '--scope-paths', 'src/scope/mod.ts')
    if ($gNewAnc.Err) { $g4Errs.Add($gNewAnc.Err) }
    [void](Invoke-GitQuiet $rGraph @('checkout', '--', 'src/new_anchor.ts'))

    # 4f. Dirty submodule even with diff.ignoreSubmodules=all -> CONTEXT_STALE
    [void](Invoke-GitQuiet $rGraph @('config', 'diff.ignoreSubmodules', 'all'))
    Write-LfFile (Join-Path $rGraph 'libs\sub\sub.ts') "export const subVer = 2;`n"
    $gSubDirty = Test-ParityCommand -Label 'graph-dirty-submodule' -ExpectedCode 2 `
        -MatchPattern '^CONTEXT_STALE: scope=graph-scope reasons=graph_index_stale anchor_status=FRESH graph_index=STALE live_lsp_eligible=true$' `
        -PsArgs @('context-cache', '-RepoRoot', $rGraph, '-Action', 'check', '-CachePath', $gPsRel, '-ScopeId', 'graph-scope') `
        -ShArgs @('context-cache', '--repo-root', $rGraphP, '--action', 'check', '--cache-path', $gPsRel, '--scope-id', 'graph-scope')
    if ($gSubDirty.Err) { $g4Errs.Add($gSubDirty.Err) }
    $gSubDirtyScoped = Test-ParityCommand -Label 'graph-dirty-submodule-scoped' -ExpectedCode 2 `
        -MatchPattern '^CONTEXT_STALE: scope=graph-scope reasons=graph_index_stale anchor_status=FRESH graph_index=STALE live_lsp_eligible=true$' `
        -PsArgs @('context-cache', '-RepoRoot', $rGraph, '-Action', 'check', '-CachePath', $gPsRel, '-ScopeId', 'graph-scope', '-ScopePaths', 'libs/sub') `
        -ShArgs @('context-cache', '--repo-root', $rGraphP, '--action', 'check', '--cache-path', $gPsRel, '--scope-id', 'graph-scope', '--scope-paths', 'libs/sub')
    if ($gSubDirtyScoped.Err) { $g4Errs.Add($gSubDirtyScoped.Err) }
    [void](Invoke-GitQuiet (Join-Path $rGraph 'libs\sub') @('checkout', '--', 'sub.ts'))
    [void](Invoke-GitQuiet $rGraph @('config', '--unset', 'diff.ignoreSubmodules'))

    # 4g. Moved HEAD past graph_index_sha -> CONTEXT_STALE across both -ps.ctx and -sh.ctx
    Write-LfFile (Join-Path $rGraph 'src\other.ts') "export const O = 3;`n"
    [void](Invoke-GitQuiet $rGraph @('add', 'src/other.ts'))
    [void](Invoke-GitQuiet $rGraph @('commit', '-qm', 'advance head'))
    $err = Test-CrossShellCheck -RepoDir $rGraph -PsCacheRel $gPsRel -ShCacheRel $gShRel -Label 'graph-head-moved' -ExpectedCode 2 `
        -MatchPattern '^CONTEXT_STALE: scope=graph-scope reasons=graph_index_stale anchor_status=FRESH graph_index=STALE live_lsp_eligible=true$' `
        -PsExtraArgs @('-ScopeId', 'graph-scope') `
        -ShExtraArgs @('--scope-id', 'graph-scope')
    if ($err) { $g4Errs.Add($err) }

    if ($g4Errs.Count -eq 0) { Pass 'stale-graph-index-vs-live-lsp' } else { FailCheck 'stale-graph-index-vs-live-lsp' ($g4Errs -join '; ') }

    # =========================================================================
    # Group 5: security-containment-and-tamper-fail-closed
    # =========================================================================
    $g5Errs = New-Object System.Collections.Generic.List[string]
    $rSec = Join-Path $sandbox 'sec-repo'
    $rSecP = To-Posix $rSec
    $outSec = Join-Path $sandbox 'outside-sec'
    Init-GitRepo $rSec
    New-Item -ItemType Directory -Path $outSec -Force | Out-Null
    Write-LfFile (Join-Path $outSec 'secret.txt') "outside secret`n"
    Write-LfFile (Join-Path $rSec 'src\a.ts') "export const a = 1;`n"
    Write-LfFile (Join-Path $rSec 'src\dir\b.ts') "export const b = 2;`n"
    Write-LfFile (Join-Path $rSec 'src\MixedCase\File.ts') "export const m = 3;`n"
    [void](Invoke-GitQuiet $rSec @('add', '.'))
    [void](Invoke-GitQuiet $rSec @('commit', '-qm', 'init sec'))
    $secHead = Invoke-GitQuiet $rSec @('rev-parse', 'HEAD')

    New-Item -ItemType Junction -Path (Join-Path $rSec 'linked-out') -Target $outSec | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $rSec '.b3\ship') -Force | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $rSec '.b3\ship\linked-ctx') -Target $outSec | Out-Null

    $secSumRel = '.b3/ship/ctx/sum.md'
    $secSumFull = Join-Path $rSec '.b3\ship\ctx\sum.md'
    $secSumBody = "# Sec Summary`n"
    Write-LfFile $secSumFull $secSumBody

    $secRec = Test-RecordParity -RepoDir $rSec -BaseCacheRel '.b3/ship/ctx/valid' -Label 'sec-baseline-record' `
        -PsExtraArgs @('-ScopeId', 'sec-scope', '-AnchorPaths', 'src/a.ts', '-SummaryRef', $secSumRel) `
        -ShExtraArgs @('--scope-id', 'sec-scope', '--anchor-paths', 'src/a.ts', '--summary-ref', $secSumRel)
    $secCacheRel = $secRec.PsRel
    $validCacheRaw = ''
    if ($secRec.Ok) {
        $validCacheRaw = [System.IO.File]::ReadAllText($secRec.PsFull, $utf8NoBom)
    } else {
        $g5Errs.Add($secRec.Err)
    }

    # 5a. Forbidden anchor paths (git, nested .git, ADS :, trailing dot/space, absolute, .., junction, secret, glob, pathspec magic, leading -)
    $badAnchorCases = @(
        @{ Label = 'dotdot-git'; Val = '././.git/config'; NoGlob = $false; NoConv = $false },
        @{ Label = 'nested-git'; Val = 'src/.git/config'; NoGlob = $false; NoConv = $false },
        @{ Label = 'ads-colon'; Val = 'src/a.ts:stream'; NoGlob = $false; NoConv = $false },
        @{ Label = 'trailing-dot-git'; Val = '.git.'; NoGlob = $false; NoConv = $false },
        @{ Label = 'trailing-dot-b3'; Val = '.b3.'; NoGlob = $false; NoConv = $false },
        @{ Label = 'trailing-dot-cred'; Val = 'credentials.json.'; NoGlob = $false; NoConv = $false },
        @{ Label = 'trailing-space'; Val = 'src/a.ts '; NoGlob = $false; NoConv = $false },
        @{ Label = 'abs-path'; Val = '/etc/passwd'; NoGlob = $false; NoConv = $true },
        @{ Label = 'parent-traversal'; Val = '../outside-sec/secret.txt'; NoGlob = $false; NoConv = $false },
        @{ Label = 'junction-anchor'; Val = 'linked-out/secret.txt'; NoGlob = $false; NoConv = $false },
        @{ Label = 'secret-env'; Val = '.env'; NoGlob = $false; NoConv = $false },
        @{ Label = 'secret-cred'; Val = 'credentials.json'; NoGlob = $false; NoConv = $false },
        @{ Label = 'glob-star'; Val = 'src/*'; NoGlob = $true; NoConv = $false },
        @{ Label = 'pathspec-magic'; Val = ':(top)src/a.ts'; NoGlob = $false; NoConv = $false },
        @{ Label = 'leading-dash'; Val = '--cached'; NoGlob = $false; NoConv = $false }
    )
    foreach ($bc in $badAnchorCases) {
        $v = $bc.Val
        $res = Test-ParityCommand -Label "bad-anchor-$($bc.Label)" -ExpectedCode 1 -MatchPattern '^CONTEXT_ERROR: invalid path ' `
            -NoGlob:$bc.NoGlob -NoPathConv:$bc.NoConv `
            -PsArgs @('context-cache', '-RepoRoot', $rSec, '-Action', 'record', '-CachePath', '.b3/ship/ctx/tmp.cache', '-ScopeId', 'sec-bad', '-AnchorPaths', $v) `
            -ShArgs @('context-cache', '--repo-root', $rSecP, '--action', 'record', '--cache-path', '.b3/ship/ctx/tmp.cache', '--scope-id', 'sec-bad', '--anchor-paths', $v)
        if ($res.Err) { $g5Errs.Add($res.Err) }
    }

    # 5b. Forbidden cache_path (generic .b3/models.md, .b3/home, .b3/autodev/x, absolute, .., junction, ADS, trailing dot/space, secret)
    $badCacheCases = @(
        @{ Label = 'b3-models'; Val = '.b3/models.md'; NoConv = $false },
        @{ Label = 'b3-home'; Val = '.b3/home'; NoConv = $false },
        @{ Label = 'b3-autodev'; Val = '.b3/autodev/x'; NoConv = $false },
        @{ Label = 'abs-cache'; Val = '/tmp/x.cache'; NoConv = $true },
        @{ Label = 'trav-cache'; Val = '.b3/ship/../../escape.cache'; NoConv = $false },
        @{ Label = 'junc-cache'; Val = '.b3/ship/linked-ctx/esc.cache'; NoConv = $false },
        @{ Label = 'ads-cache'; Val = '.b3/ship/ctx/a.cache:stream'; NoConv = $false },
        @{ Label = 'dot-cache'; Val = '.b3/ship/ctx/a.cache.'; NoConv = $false },
        @{ Label = 'space-cache'; Val = '.b3/ship/ctx/a.cache '; NoConv = $false },
        @{ Label = 'secret-cache'; Val = '.b3/ship/.env'; NoConv = $false }
    )
    foreach ($cc in $badCacheCases) {
        $v = $cc.Val
        $res = Test-ParityCommand -Label "bad-cache-$($cc.Label)" -ExpectedCode 1 -MatchPattern '^CONTEXT_ERROR: invalid cache_path$' `
            -NoPathConv:$cc.NoConv `
            -PsArgs @('context-cache', '-RepoRoot', $rSec, '-Action', 'record', '-CachePath', $v, '-ScopeId', 'sec-bad', '-AnchorPaths', 'src/a.ts') `
            -ShArgs @('context-cache', '--repo-root', $rSecP, '--action', 'record', '--cache-path', $v, '--scope-id', 'sec-bad', '--anchor-paths', 'src/a.ts')
        if ($res.Err) { $g5Errs.Add($res.Err) }
    }

    # 5c. Raw control char in CLI arg ("foo`nbar") — use -EncodedCommand for PS and ANSI-C quoting for Bash
    $psCtrlCmd = "& $(Quote-PsSingle $guardPs) context-cache -RepoRoot $(Quote-PsSingle $rSec) -Action record -CachePath '.b3/ship/ctx/ctrl.cache' -ScopeId `"foo``nbar`" -AnchorPaths 'src/a.ts'"
    $psCtrlEnc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($psCtrlCmd))
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $rawPsCtrl = & powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $psCtrlEnc 2>&1
        $psCtrlCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    $psCtrlLines = @($rawPsCtrl | ForEach-Object { ([string]$_).TrimEnd("`r") })
    $psCtrl = @{ Code = $psCtrlCode; Lines = $psCtrlLines; Text = ($psCtrlLines -join "`n") }
    $shCtrl = Invoke-ShGuard @('context-cache', '--repo-root', $rSecP, '--action', 'record', '--cache-path', '.b3/ship/ctx/ctrl.cache', '--scope-id', "foo`nbar", '--anchor-paths', 'src/a.ts')
    $ctrlErr = Assert-Parity -PsRes $psCtrl -ShRes $shCtrl -ExpectedCode 1 -MatchPattern '^CONTEXT_ERROR: control characters not allowed$' -Label 'cli-ctrl-char'
    if ($ctrlErr) { $g5Errs.Add($ctrlErr) }

    # 5d. Bidirectional IgnoreDirtyPaths overlap (parent/child anchor + scope + mixed-case ordinal parity)
    $ignFailCases = @(
        @{ Label = 'ign-parent-of-anchor'; Ps = @('-AnchorPaths', 'src/dir/b.ts', '-IgnoreDirtyPaths', 'src/dir'); Sh = @('--anchor-paths', 'src/dir/b.ts', '--ignore-dirty-paths', 'src/dir') },
        @{ Label = 'ign-child-of-anchor'; Ps = @('-AnchorPaths', 'src/dir', '-IgnoreDirtyPaths', 'src/dir/b.ts'); Sh = @('--anchor-paths', 'src/dir', '--ignore-dirty-paths', 'src/dir/b.ts') },
        @{ Label = 'ign-parent-of-scope'; Ps = @('-AnchorPaths', 'src/a.ts', '-ScopePaths', 'src/dir/b.ts', '-IgnoreDirtyPaths', 'src/dir'); Sh = @('--anchor-paths', 'src/a.ts', '--scope-paths', 'src/dir/b.ts', '--ignore-dirty-paths', 'src/dir') },
        @{ Label = 'ign-child-of-scope'; Ps = @('-AnchorPaths', 'src/a.ts', '-ScopePaths', 'src/dir', '-IgnoreDirtyPaths', 'src/dir/b.ts'); Sh = @('--anchor-paths', 'src/a.ts', '--scope-paths', 'src/dir', '--ignore-dirty-paths', 'src/dir/b.ts') },
        @{ Label = 'ign-exact-mixedcase'; Ps = @('-AnchorPaths', 'src/MixedCase/File.ts', '-IgnoreDirtyPaths', 'src/MixedCase/File.ts'); Sh = @('--anchor-paths', 'src/MixedCase/File.ts', '--ignore-dirty-paths', 'src/MixedCase/File.ts') }
    )
    foreach ($ic in $ignFailCases) {
        $res = Test-ParityCommand -Label $ic.Label -ExpectedCode 1 -MatchPattern '^CONTEXT_ERROR: invalid ignore path$' `
            -PsArgs (@('context-cache', '-RepoRoot', $rSec, '-Action', 'record', '-CachePath', '.b3/ship/ctx/ign.cache', '-ScopeId', 'sec-ign') + $ic.Ps) `
            -ShArgs (@('context-cache', '--repo-root', $rSecP, '--action', 'record', '--cache-path', '.b3/ship/ctx/ign.cache', '--scope-id', 'sec-ign') + $ic.Sh)
        if ($res.Err) { $g5Errs.Add($res.Err) }
    }
    $ignOrd = Test-RecordParity -RepoDir $rSec -BaseCacheRel '.b3/ship/ctx/ign-ord' -Label 'ign-mixedcase-ordinal-nonoverlap' `
        -PsExtraArgs @('-ScopeId', 'sec-ign-ord', '-AnchorPaths', 'src/MixedCase/File.ts', '-IgnoreDirtyPaths', 'src/mixedcase/file.ts') `
        -ShExtraArgs @('--scope-id', 'sec-ign-ord', '--anchor-paths', 'src/MixedCase/File.ts', '--ignore-dirty-paths', 'src/mixedcase/file.ts')
    if ($ignOrd.Err) { $g5Errs.Add($ignOrd.Err) }

    # 5e. Cross-scope & -SummaryRef CONTEXT_MISMATCH
    $misScope = Test-ParityCommand -Label 'mismatch-scope' -ExpectedCode 1 -MatchPattern '^CONTEXT_MISMATCH: scope_id expected=other-scope got=sec-scope$' `
        -PsArgs @('context-cache', '-RepoRoot', $rSec, '-Action', 'check', '-CachePath', $secCacheRel, '-ScopeId', 'other-scope') `
        -ShArgs @('context-cache', '--repo-root', $rSecP, '--action', 'check', '--cache-path', $secCacheRel, '--scope-id', 'other-scope')
    if ($misScope.Err) { $g5Errs.Add($misScope.Err) }

    $misSum = Test-ParityCommand -Label 'mismatch-summary-ref' -ExpectedCode 1 -MatchPattern '^CONTEXT_MISMATCH: summary_ref expected=\.b3/ship/ctx/other\.md got=\.b3/ship/ctx/sum\.md$' `
        -PsArgs @('context-cache', '-RepoRoot', $rSec, '-Action', 'check', '-CachePath', $secCacheRel, '-ScopeId', 'sec-scope', '-SummaryRef', '.b3/ship/ctx/other.md') `
        -ShArgs @('context-cache', '--repo-root', $rSecP, '--action', 'check', '--cache-path', $secCacheRel, '--scope-id', 'sec-scope', '--summary-ref', '.b3/ship/ctx/other.md')
    if ($misSum.Err) { $g5Errs.Add($misSum.Err) }

    # 5f. Tampered cache files: CRLF, invalid UTF-8, duplicate/unknown/missing keys
    $tamperRel = '.b3/ship/ctx/tamper.cache'
    $tamperFull = Join-Path $rSec '.b3\ship\ctx\tamper.cache'

    [System.IO.File]::WriteAllBytes($tamperFull, $utf8NoBom.GetBytes(($validCacheRaw -replace "`n", "`r`n")))
    $tCrlf = Test-ParityCommand -Label 'tamper-crlf' -ExpectedCode 1 -MatchPattern '^CONTEXT_CORRUPT: control character or CRLF in cache$' `
        -PsArgs @('context-cache', '-RepoRoot', $rSec, '-Action', 'check', '-CachePath', $tamperRel) `
        -ShArgs @('context-cache', '--repo-root', $rSecP, '--action', 'check', '--cache-path', $tamperRel)
    if ($tCrlf.Err) { $g5Errs.Add($tCrlf.Err) }

    [System.IO.File]::WriteAllBytes($tamperFull, [byte[]]@(0xFF, 0xFE, 0x0A))
    $tUtf8 = Test-ParityCommand -Label 'tamper-invalid-utf8' -ExpectedCode 1 -MatchPattern '^CONTEXT_CORRUPT: invalid utf8 encoding$' `
        -PsArgs @('context-cache', '-RepoRoot', $rSec, '-Action', 'check', '-CachePath', $tamperRel) `
        -ShArgs @('context-cache', '--repo-root', $rSecP, '--action', 'check', '--cache-path', $tamperRel)
    if ($tUtf8.Err) { $g5Errs.Add($tUtf8.Err) }

    Write-LfFile $tamperFull ($validCacheRaw + "scope_id=dup`n")
    $tDup = Test-ParityCommand -Label 'tamper-dup-key' -ExpectedCode 1 -MatchPattern "^CONTEXT_CORRUPT: duplicate field 'scope_id'$" `
        -PsArgs @('context-cache', '-RepoRoot', $rSec, '-Action', 'check', '-CachePath', $tamperRel) `
        -ShArgs @('context-cache', '--repo-root', $rSecP, '--action', 'check', '--cache-path', $tamperRel)
    if ($tDup.Err) { $g5Errs.Add($tDup.Err) }

    Write-LfFile $tamperFull ($validCacheRaw + "evil_key=1`n")
    $tUnk = Test-ParityCommand -Label 'tamper-unknown-key' -ExpectedCode 1 -MatchPattern "^CONTEXT_CORRUPT: unknown field 'evil_key'$" `
        -PsArgs @('context-cache', '-RepoRoot', $rSec, '-Action', 'check', '-CachePath', $tamperRel) `
        -ShArgs @('context-cache', '--repo-root', $rSecP, '--action', 'check', '--cache-path', $tamperRel)
    if ($tUnk.Err) { $g5Errs.Add($tUnk.Err) }

    $missingKeyBody = (($validCacheRaw -split "`n") | Where-Object { $_ -and ($_ -notmatch '^timestamp_utc=') }) -join "`n"
    Write-LfFile $tamperFull ($missingKeyBody + "`n")
    $tMiss = Test-ParityCommand -Label 'tamper-missing-key' -ExpectedCode 1 -MatchPattern "^CONTEXT_CORRUPT: missing field 'timestamp_utc'$" `
        -PsArgs @('context-cache', '-RepoRoot', $rSec, '-Action', 'check', '-CachePath', $tamperRel) `
        -ShArgs @('context-cache', '--repo-root', $rSecP, '--action', 'check', '--cache-path', $tamperRel)
    if ($tMiss.Err) { $g5Errs.Add($tMiss.Err) }

    # 5g. Deleted summary_ref -> CONTEXT_CORRUPT
    Remove-Item -LiteralPath $secSumFull -Force
    $tDelSum = Test-ParityCommand -Label 'deleted-summary-ref' -ExpectedCode 1 -MatchPattern '^CONTEXT_CORRUPT: missing or invalid summary_ref$' `
        -PsArgs @('context-cache', '-RepoRoot', $rSec, '-Action', 'check', '-CachePath', $secCacheRel, '-ScopeId', 'sec-scope') `
        -ShArgs @('context-cache', '--repo-root', $rSecP, '--action', 'check', '--cache-path', $secCacheRel, '--scope-id', 'sec-scope')
    if ($tDelSum.Err) { $g5Errs.Add($tDelSum.Err) }
    Write-LfFile $secSumFull $secSumBody

    # 5h. Mid-merge git state (.git/MERGE_HEAD) -> CONTEXT_ERROR: mid-operation git state
    $mergeHead = Join-Path $rSec '.git\MERGE_HEAD'
    Write-LfFile $mergeHead "$secHead`n"
    $tMid = Test-ParityCommand -Label 'mid-merge-state' -ExpectedCode 1 -MatchPattern '^CONTEXT_ERROR: mid-operation git state$' `
        -PsArgs @('context-cache', '-RepoRoot', $rSec, '-Action', 'check', '-CachePath', $secCacheRel, '-ScopeId', 'sec-scope') `
        -ShArgs @('context-cache', '--repo-root', $rSecP, '--action', 'check', '--cache-path', $secCacheRel, '--scope-id', 'sec-scope')
    if ($tMid.Err) { $g5Errs.Add($tMid.Err) }
    Remove-Item -LiteralPath $mergeHead -Force

    if ($g5Errs.Count -eq 0) { Pass 'security-containment-and-tamper-fail-closed' } else { FailCheck 'security-containment-and-tamper-fail-closed' ($g5Errs -join '; ') }

    # =========================================================================
    # Group 6: four-host-compat-and-zero-always-on
    # =========================================================================
    $g6Errs = New-Object System.Collections.Generic.List[string]

    foreach ($hName in @('cursor', 'codex', 'claude')) {
        $fxDir = Join-Path $sandbox "sync-fx-$hName"
        New-Item -ItemType Directory -Path (Join-Path $fxDir 'adapters\command-skills\b3-ship'), (Join-Path $fxDir 'skills\engineering\demo'), (Join-Path $fxDir 'commands'), (Join-Path $fxDir 'agents') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $root 'adapters\sync-skills.ps1') -Destination (Join-Path $fxDir 'adapters\sync-skills.ps1') -Force
        Write-LfFile (Join-Path $fxDir 'skills\engineering\demo\SKILL.md') "---`nname: demo`ndescription: demo skill`n---`n# Demo`n"
        Write-LfFile (Join-Path $fxDir 'adapters\command-skills\b3-ship\SKILL.md') "---`nname: b3-ship`ndescription: ship cmd`n---`n# Ship`n"
        Write-LfFile (Join-Path $fxDir 'commands\b3-ship.md') "# Ship`n"
        Write-LfFile (Join-Path $fxDir 'agents\b3-reviewer.md') "# Reviewer`n"

        $syncRes = Invoke-PsScript -ScriptPath (Join-Path $fxDir 'adapters\sync-skills.ps1') -ScriptArgs @('-HostName', $hName)
        $verRes = Invoke-PsScript -ScriptPath (Join-Path $fxDir 'adapters\sync-skills.ps1') -ScriptArgs @('-HostName', $hName, '-VerifyOnly')
        if ($syncRes.Code -ne 0 -or $verRes.Code -ne 0) {
            $g6Errs.Add("sync-skills $hName failed sync=$($syncRes.Code) ver=$($verRes.Code)")
        }
    }

    $agVer = Invoke-PsScript -ScriptPath (Join-Path $root 'adapters\sync-skills.ps1') -ScriptArgs @('-HostName', 'antigravity', '-VerifyOnly')
    if ($agVer.Code -ne 0) {
        $g6Errs.Add("antigravity verify failed exit=$($agVer.Code) out=$($agVer.Text)")
    }

    $mcPs = Invoke-PsScript -ScriptPath $measurePs -ScriptArgs @('-RepoRoot', $root, '-Strict')
    $mcSh = Invoke-ShScriptArgs -ScriptPosix $measureShPosix -ScriptArgs @('--repo-root', (To-Posix $root), '--strict')
    $mcErr = Assert-Parity -PsRes $mcPs -ShRes $mcSh -ExpectedCode 0 -Label 'measure-context-strict'
    if ($mcErr) { $g6Errs.Add($mcErr) }
    if ($mcPs.Text -notmatch '(?m)^warnings\s*:\s*0$') {
        $g6Errs.Add('measure-context warnings != 0')
    }
    if ($mcPs.Text -match '(?m)^context_routing\s*:\s*(\d+)\s+B\b') {
        $crMeasured = [int]$Matches[1]
        if ($crMeasured -lt 1 -or $crMeasured -gt 3200) {
            $g6Errs.Add("context_routing measured=$crMeasured B (> 3200 B)")
        }
    } else {
        $g6Errs.Add('measure-context missing context_routing line')
    }

    $aoPattern = 'context-routing\.md|context-cache|codebase[\s-]*memory|serena'
    $agentsRaw = Get-Content -LiteralPath (Join-Path $root 'AGENTS.md') -Raw
    if ($agentsRaw -match $aoPattern) {
        $g6Errs.Add('AGENTS.md contains forbidden context-routing/MCP keyword')
    }
    foreach ($rf in @(Get-ChildItem -LiteralPath (Join-Path $root 'rules') -Filter '*.md' -File)) {
        $rRaw = Get-Content -LiteralPath $rf.FullName -Raw
        if ($rRaw -match $aoPattern) {
            $g6Errs.Add("rules/$($rf.Name) contains forbidden context-routing/MCP keyword")
        }
    }
    foreach ($skillRoot in @('skills', 'adapters\command-skills')) {
        $srFull = Join-Path $root $skillRoot
        if (-not (Test-Path -LiteralPath $srFull -PathType Container)) { continue }
        foreach ($sf in @(Get-ChildItem -LiteralPath $srFull -Recurse -Filter 'SKILL.md' -File)) {
            $lf = $isoEnc.GetString([System.IO.File]::ReadAllBytes($sf.FullName)).Replace("`r", '')
            if ($lf -match '(?s)\A---\n(.*?)\n---(?:\n|\z)') {
                if ($Matches[1] -match $aoPattern) {
                    $relSf = $sf.FullName.Substring($root.Length + 1) -replace '\\', '/'
                    $g6Errs.Add("$relSf frontmatter contains forbidden context-routing/MCP keyword")
                }
            }
        }
    }

    if ($g6Errs.Count -eq 0) { Pass 'four-host-compat-and-zero-always-on' } else { FailCheck 'four-host-compat-and-zero-always-on' ($g6Errs -join '; ') }
}
finally {
    if ($null -eq $prevSkipModel) { Remove-Item Env:B3_SKIP_MODEL_INIT -ErrorAction SilentlyContinue } else { $env:B3_SKIP_MODEL_INIT = $prevSkipModel }
    if ($null -eq $prevModelsPersonal) { Remove-Item Env:B3_MODELS_PERSONAL -ErrorAction SilentlyContinue } else { $env:B3_MODELS_PERSONAL = $prevModelsPersonal }
    Remove-ReparseLinksUnder $sandbox
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Complete-ValidationSuite
