# Dual-shell behavioral checks for MCP-aware context routing and b3-guard context-cache.
# Verifies routing contract, 6 workflow hooks + hint-only subagents, Iter 2+ cache reuse/invalidation,
# stale graph-index vs live-LSP semantics, security containment/tamper fail-closed, 4-host compat, and 0 always-on bloat.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate-context-routing.ps1
param(
    [switch]$AllowIncompleteBash
)
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'lib\global-test-helpers.ps1')

$guardPs = Join-Path $root 'scripts\b3-guard.ps1'
$guardShPosix = ($root -replace '\\', '/') + '/scripts/b3-guard.sh'
$measurePs = Join-Path $root 'scripts\measure-context.ps1'
$measureShPosix = ($root -replace '\\', '/') + '/scripts/measure-context.sh'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$isoEnc = [System.Text.Encoding]::GetEncoding(28591)

$script:GuardFlags = [ordered]@{
    ScopeId          = '--scope-id'
    AnchorPaths      = '--anchor-paths'
    ScopePaths       = '--scope-paths'
    GraphIndexSha    = '--graph-index-sha'
    SummaryRef       = '--summary-ref'
    IgnoreDirtyPaths = '--ignore-dirty-paths'
}

function To-Posix([string]$PathValue) { return ($PathValue -replace '\\', '/') }
function Add-Err([System.Collections.Generic.List[string]]$List, [string]$Err) { if ($Err) { $List.Add($Err) } }

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
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::WriteAllText($PathValue, ($Text -replace "`r`n", "`n"), $utf8NoBom)
}

function Get-LfByteLength([string]$FullPath) {
    if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) { return -1 }
    return ($isoEnc.GetString([System.IO.File]::ReadAllBytes($FullPath)).Replace("`r", '')).Length
}

function Test-LfNoBom([byte[]]$Bytes, [string]$Label) {
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return @{ Err = "[$Label] cache has UTF-8 BOM"; Raw = '' }
    }
    $raw = $isoEnc.GetString($Bytes)
    if ($raw.Contains("`r")) { return @{ Err = "[$Label] cache contains CR"; Raw = '' } }
    return @{ Err = ''; Raw = $raw }
}

function Invoke-GitQuiet([string]$RepoDir, [string[]]$GitArgs) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $out = & git -C $RepoDir @GitArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed in ${RepoDir}: $($out -join ' ')" }
        return (($out | ForEach-Object { ([string]$_).TrimEnd("`r") }) -join "`n").Trim()
    } finally { $ErrorActionPreference = $prev }
}

function Init-GitRepo([string]$RepoDir) {
    Init-B3TestRepo -RepoPath $RepoDir -DefaultBranch 'main' -UserEmail 'ctx-test@example.com' -UserName 'Context Test'
}

function Invoke-PsGuard([string[]]$GuardArgs) { return (Invoke-PsScript -ScriptPath $guardPs -ScriptArgs $GuardArgs) }

function Invoke-ShScriptArgs([string]$ScriptPosix, [string[]]$ScriptArgs) {
    if (-not $script:HasBash) { return @{ Code = 127; Lines = @('bash not found'); Text = 'bash not found' } }
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add((Quote-BashArg $ScriptPosix))
    foreach ($a in @($ScriptArgs)) { $parts.Add((Quote-BashArg ([string]$a))) }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $raw = & $script:GitBash -c ($parts -join ' ') 2>&1; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
    $lines = @($raw | ForEach-Object { ([string]$_).TrimEnd("`r") })
    return @{ Code = $code; Lines = $lines; Text = ($lines -join "`n") }
}

function Invoke-ShGuard([string[]]$GuardArgs) { return (Invoke-ShScriptArgs -ScriptPosix $guardShPosix -ScriptArgs $GuardArgs) }

function ConvertTo-GuardArgPair([hashtable]$Opts) {
    $ps = New-Object System.Collections.Generic.List[string]
    $sh = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Opts -or $Opts.Count -eq 0) { return @{ Ps = [string[]]@(); Sh = [string[]]@() } }
    foreach ($k in $script:GuardFlags.Keys) {
        if ($Opts.ContainsKey($k)) {
            $v = [string]$Opts[$k]
            $ps.Add("-$k"); $ps.Add($v)
            $sh.Add($script:GuardFlags[$k]); $sh.Add($v)
        }
    }
    foreach ($k in $Opts.Keys) {
        if (-not $script:GuardFlags.Contains($k)) { throw "ConvertTo-GuardArgPair: unknown option '$k'" }
    }
    return @{ Ps = [string[]]$ps.ToArray(); Sh = [string[]]$sh.ToArray() }
}

function Assert-Parity([hashtable]$PsRes, [hashtable]$ShRes, [int]$ExpectedCode, [string]$MatchPattern = '', [string]$Label = '') {
    if ($PsRes.Code -ne $ExpectedCode) { return "[$Label] PS exit=$($PsRes.Code) expected=$ExpectedCode out=$($PsRes.Text)" }
    if ($MatchPattern -and ($PsRes.Text -notmatch $MatchPattern)) { return "[$Label] PS output did not match /$MatchPattern/ :: $($PsRes.Text)" }
    if ($script:HasBash) {
        if ($PsRes.Code -ne $ShRes.Code) { return "[$Label] code parity mismatch PS=$($PsRes.Code) SH=$($ShRes.Code) PS_OUT=$($PsRes.Text) SH_OUT=$($ShRes.Text)" }
        if ($PsRes.Text -cne $ShRes.Text) { return "[$Label] text parity mismatch PS=[$($PsRes.Text)] SH=[$($ShRes.Text)]" }
    }
    return ''
}

function Test-ParityCommand {
    param([string[]]$PsArgs, [string[]]$ShArgs, [int]$ExpectedCode, [string]$MatchPattern = '', [string]$Label = '', [switch]$NoGlob, [switch]$NoPathConv)
    $ps = Invoke-PsGuard $PsArgs
    $prevMsys = $env:MSYS; $prevConv = $env:MSYS_NO_PATHCONV
    try {
        if ($NoGlob) { $env:MSYS = 'noglob' }
        if ($NoPathConv) { $env:MSYS_NO_PATHCONV = '1' }
        $sh = Invoke-ShGuard $ShArgs
    } finally {
        if ($NoGlob) { if ($null -eq $prevMsys) { Remove-Item Env:MSYS -ErrorAction SilentlyContinue } else { $env:MSYS = $prevMsys } }
        if ($NoPathConv) { if ($null -eq $prevConv) { Remove-Item Env:MSYS_NO_PATHCONV -ErrorAction SilentlyContinue } else { $env:MSYS_NO_PATHCONV = $prevConv } }
    }
    return @{ Err = (Assert-Parity $ps $sh $ExpectedCode $MatchPattern $Label); Ps = $ps; Sh = $sh }
}

function Invoke-CtxParity {
    param([string]$RepoDir, [string]$Action, [string]$CachePath, [hashtable]$Opts = @{}, [int]$ExpectedCode, [string]$MatchPattern = '', [string]$Label = '', [switch]$NoGlob, [switch]$NoPathConv)
    $pair = ConvertTo-GuardArgPair $Opts
    return (Test-ParityCommand -Label $Label -ExpectedCode $ExpectedCode -MatchPattern $MatchPattern -NoGlob:$NoGlob -NoPathConv:$NoPathConv `
        -PsArgs (@('context-cache', '-RepoRoot', $RepoDir, '-Action', $Action, '-CachePath', $CachePath) + $pair.Ps) `
        -ShArgs (@('context-cache', '--repo-root', (To-Posix $RepoDir), '--action', $Action, '--cache-path', $CachePath) + $pair.Sh))
}

function Test-RecordParity {
    param([string]$RepoDir, [string]$BaseCacheRel, [hashtable]$Opts = @{}, [string]$MatchPattern = '^CONTEXT_RECORDED: ', [string]$Label = '')
    $psRel = "$BaseCacheRel-ps.ctx"; $shRel = "$BaseCacheRel-sh.ctx"
    $fail = { param($m) @{ Ok = $false; Err = $m; RepoDir = $RepoDir; PsRel = $psRel; ShRel = $shRel; PsFull = '' } }
    $pair = ConvertTo-GuardArgPair $Opts

    $ps = Invoke-PsGuard (@('context-cache', '-RepoRoot', $RepoDir, '-Action', 'record', '-CachePath', $psRel) + $pair.Ps)
    if ($ps.Code -ne 0) { return (& $fail "[$Label] PS record exit=$($ps.Code) out=$($ps.Text)") }
    if ($MatchPattern -and ($ps.Text -notmatch $MatchPattern)) { return (& $fail "[$Label] PS record did not match /$MatchPattern/ :: $($ps.Text)") }
    $psFull = Join-Path $RepoDir ($psRel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $psFull -PathType Leaf)) { return (& $fail "[$Label] PS cache missing: $psFull") }
    $psFmt = Test-LfNoBom ([System.IO.File]::ReadAllBytes($psFull)) "$Label PS"
    if ($psFmt.Err) { return (& $fail $psFmt.Err) }

    if ($script:HasBash) {
        $sh = Invoke-ShGuard (@('context-cache', '--repo-root', (To-Posix $RepoDir), '--action', 'record', '--cache-path', $shRel) + $pair.Sh)
        if ($sh.Code -ne 0) { return (& $fail "[$Label] SH record exit=$($sh.Code) out=$($sh.Text)") }
        if ($ps.Text.Replace($psRel, '<CACHE>') -cne $sh.Text.Replace($shRel, '<CACHE>')) {
            return (& $fail "[$Label] record stdout parity mismatch PS=[$($ps.Text)] SH=[$($sh.Text)]")
        }
        $shFull = Join-Path $RepoDir ($shRel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $shFull -PathType Leaf)) { return (& $fail "[$Label] SH cache missing: $shFull") }
        $shFmt = Test-LfNoBom ([System.IO.File]::ReadAllBytes($shFull)) "$Label SH"
        if ($shFmt.Err) { return (& $fail $shFmt.Err) }
        $tsPat = '(?m)^timestamp_utc=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
        $psNorm = [regex]::Replace($psFmt.Raw, $tsPat, 'timestamp_utc=<TS>')
        $shNorm = [regex]::Replace($shFmt.Raw, $tsPat, 'timestamp_utc=<TS>')
        if ($psNorm -cne $shNorm) { return (& $fail "[$Label] written file parity mismatch PS=[$psNorm] SH=[$shNorm]") }
    }
    return @{ Ok = $true; Err = ''; RepoDir = $RepoDir; PsRel = $psRel; ShRel = $shRel; PsFull = $psFull }
}

function Test-CrossShellCheck {
    param([hashtable]$Rec, [hashtable]$Opts = @{}, [int]$ExpectedCode, [string]$MatchPattern = '', [string]$Label = '')
    $rPs = Invoke-CtxParity -RepoDir $Rec.RepoDir -Action 'check' -CachePath $Rec.PsRel -Opts $Opts -Label "$Label-on-ps-file" -ExpectedCode $ExpectedCode -MatchPattern $MatchPattern
    if ($rPs.Err) { return $rPs.Err }
    if ($script:HasBash) {
        $rSh = Invoke-CtxParity -RepoDir $Rec.RepoDir -Action 'check' -CachePath $Rec.ShRel -Opts $Opts -Label "$Label-on-sh-file" -ExpectedCode $ExpectedCode -MatchPattern $MatchPattern
        if ($rSh.Err) { return $rSh.Err }
        if ($rPs.Ps.Text -cne $rSh.Ps.Text) { return "[$Label] cross-file output mismatch PS_FILE=[$($rPs.Ps.Text)] SH_FILE=[$($rSh.Ps.Text)]" }
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
    if ($crBytes -lt 1 -or $crBytes -gt 3000) {
        $g1Errs.Add("context-routing.md size=$crBytes B (must be 1..3000 B LF)")
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
            @{ Name = 'conditional-load'; Pat = 'only when triggered.*skip on native-only' },
            @{ Name = 'graph-index-mismatch'; Pat = 'graph_index_mismatch' },
            @{ Name = 'staleness-graph-vs-lsp'; Pat = 'commit-indexed.*graph_index_sha.*Live LSP `serena`.*working tree' },
            @{ Name = 'review-loop-iter1-diff-first'; Pat = 'Review Loop Iter 1 \(diff-first\)' },
            @{ Name = 'review-loop-iter2-delta-first'; Pat = 'Review Loop Iter 2\+ \(delta-first\)' },
            @{ Name = 'research-ship-repo-evidence'; Pat = 'Research Ship:.*`repo-evidence`.*`evidence-check`' },
            @{ Name = 'graceful-fallback-no-false-pass'; Pat = 'Graceful failure:.*native fallback.*never false `PASS`' }
        )
        foreach ($req in $requiredPatterns) { if ($crText -notmatch $req.Pat) { $g1Errs.Add("missing $($req.Name)") } }
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
        @{ Rel = 'review-loop\strategy.md'; Pats = @('context-routing\.md', 'context_hint:', 'only when triggered.*skip.*native-only') },
        @{ Rel = 'review-loop\hierarchical.md'; Pats = @('context-routing\.md', 'context_hint:', 'skipping it on native direct-known', 'Level 1 invariants via `summary_ref`') },
        @{ Rel = 'skills\engineering\debugging\SKILL.md'; Pats = @('context-routing\.md', 'on demand') },
        @{ Rel = 'skills\engineering\problem-solving\SKILL.md'; Pats = @('context-routing\.md', 'on demand') },
        @{ Rel = 'workflows\feature-implementation.md'; Pats = @('context-routing\.md', 'on demand') }
    )
    foreach ($hf in $hookFiles) {
        $fp = Join-Path $root $hf.Rel
        if (-not (Test-Path -LiteralPath $fp -PathType Leaf)) { $g2Errs.Add("missing $($hf.Rel)"); continue }
        $txt = Get-Content -LiteralPath $fp -Raw
        foreach ($pat in $hf.Pats) { if ($txt -notmatch $pat) { $g2Errs.Add("$($hf.Rel) missing /$pat/") } }
    }
    foreach ($agRel in @('agents\b3-reviewer.md', 'agents\b3-fixer.md')) {
        $afp = Join-Path $root $agRel
        if (-not (Test-Path -LiteralPath $afp -PathType Leaf)) { $g2Errs.Add("missing $agRel"); continue }
        $atxt = Get-Content -LiteralPath $afp -Raw
        foreach ($req in @('context_hint:', 'hint-only', 'never load `context-routing\.md`')) {
            if ($atxt -notmatch $req) { $g2Errs.Add("$agRel missing /$req/") }
        }
    }
    if ($g2Errs.Count -eq 0) { Pass 'six-workflow-hooks-and-hint-only' } else { FailCheck 'six-workflow-hooks-and-hint-only' ($g2Errs -join '; ') }

    # =========================================================================
    # Group 3: context-cache-iter2-reuse-and-invalidation
    # =========================================================================
    $g3Errs = New-Object System.Collections.Generic.List[string]
    $rCache = Join-Path $sandbox 'cache-repo'; $rCacheP = To-Posix $rCache
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
    $c3Fresh = '^CONTEXT_FRESH: scope=rl-iter1 head=[0-9a-f]{40} anchor_status=FRESH graph_index=NOT_RECORDED live_lsp_eligible=true$'
    $c3AncStale = '^CONTEXT_STALE: scope=rl-iter1 reasons=anchor_changed anchor_status=STALE graph_index=NOT_RECORDED live_lsp_eligible=true$'

    # Iter 1 record to distinct -ps.ctx and -sh.ctx files (verify stdout + LF/no-BOM/field parity)
    $r1 = Test-RecordParity -RepoDir $rCache -BaseCacheRel '.b3/ship/ctx/iter1' -Label 'iter1-record' `
        -MatchPattern '^CONTEXT_RECORDED: \.b3/ship/ctx/iter1-ps\.ctx scope=rl-iter1 ' `
        -Opts @{ ScopeId = 'rl-iter1'; AnchorPaths = $anchorsCsv; SummaryRef = $sumRel; GraphIndexSha = 'none' }
    Add-Err $g3Errs $r1.Err

    # Snapshot prev_sha before Fixer edits mutable file
    $snap = Test-ParityCommand -Label 'iter1-snapshot' -ExpectedCode 0 -MatchPattern '^[0-9a-f]{40}$' `
        -PsArgs @('snapshot', '-RepoRoot', $rCache) -ShArgs @('snapshot', '--repo-root', $rCacheP)
    Add-Err $g3Errs $snap.Err
    $prevSha = $snap.Ps.Text.Trim()

    # Fixer edits mutable src/orders/handler.ts (uncommitted) -- cross-shell check BOTH -ps.ctx and -sh.ctx
    Write-LfFile (Join-Path $rCache 'src\orders\handler.ts') "export function handleOrder(id: string): string { return id.trim(); }`n"
    Add-Err $g3Errs (Test-CrossShellCheck -Rec $r1 -Label 'iter2-uncommitted-fresh' -ExpectedCode 0 -MatchPattern $c3Fresh `
        -Opts @{ ScopeId = 'rl-iter1'; AnchorPaths = $anchorsCsv; SummaryRef = $sumRel })
    Add-Err $g3Errs (Test-ParityCommand -Label 'iter2-uncommitted-delta' -ExpectedCode 0 -MatchPattern '(?m)^delta_files=src/orders/handler\.ts$' `
        -PsArgs @('diff-scope', '-RepoRoot', $rCache, '-BaseSha', $c1Sha, '-PrevSha', $prevSha) `
        -ShArgs @('diff-scope', '--repo-root', $rCacheP, '--base-sha', $c1Sha, '--prev-sha', $prevSha)).Err

    # Fixer forward-commits src/orders/handler.ts -- cross-shell check BOTH -ps.ctx and -sh.ctx
    [void](Invoke-GitQuiet $rCache @('add', 'src/orders/handler.ts'))
    [void](Invoke-GitQuiet $rCache @('commit', '-qm', 'fix handler'))
    Add-Err $g3Errs (Test-CrossShellCheck -Rec $r1 -Label 'iter2-forward-commit-fresh' -ExpectedCode 0 -MatchPattern $c3Fresh `
        -Opts @{ ScopeId = 'rl-iter1'; AnchorPaths = $anchorsCsv; SummaryRef = $sumRel })
    Add-Err $g3Errs (Test-ParityCommand -Label 'iter2-forward-commit-delta' -ExpectedCode 0 -MatchPattern '(?m)^delta_files=src/orders/handler\.ts$' `
        -PsArgs @('diff-scope', '-RepoRoot', $rCache, '-BaseSha', $c1Sha, '-PrevSha', $prevSha) `
        -ShArgs @('diff-scope', '--repo-root', $rCacheP, '--base-sha', $c1Sha, '--prev-sha', $prevSha)).Err

    # Invalidation 1 & 2: changed dependency (src/deps/auth.ts) and changed shared contract (src/contracts/order.ts)
    Write-LfFile (Join-Path $rCache 'src\deps\auth.ts') "export function verifyToken(t: string): boolean { return t.startsWith('v2:'); }`n"
    Add-Err $g3Errs (Test-CrossShellCheck -Rec $r1 -Label 'inv-dep-changed' -ExpectedCode 2 -MatchPattern $c3AncStale -Opts @{ ScopeId = 'rl-iter1' })
    [void](Invoke-GitQuiet $rCache @('checkout', '--', 'src/deps/auth.ts'))

    Write-LfFile (Join-Path $rCache 'src\contracts\order.ts') "export interface Order { id: string; total: number; currency: string; }`n"
    Add-Err $g3Errs (Test-CrossShellCheck -Rec $r1 -Label 'inv-contract-changed' -ExpectedCode 2 -MatchPattern $c3AncStale -Opts @{ ScopeId = 'rl-iter1' })
    [void](Invoke-GitQuiet $rCache @('checkout', '--', 'src/contracts/order.ts'))

    # Invalidation 2b (H-03): staged broken content in anchor while WT matches HEAD -> anchor_changed (exit 2)
    $authOrig = [System.IO.File]::ReadAllText((Join-Path $rCache 'src\deps\auth.ts'), $utf8NoBom)
    Write-LfFile (Join-Path $rCache 'src\deps\auth.ts') "BROKEN_STAGED_CONTENT`n"
    [void](Invoke-GitQuiet $rCache @('add', 'src/deps/auth.ts'))
    Write-LfFile (Join-Path $rCache 'src\deps\auth.ts') $authOrig
    $prevEapH03 = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $wtDiffAuth = (& git -C $rCache diff HEAD -- src/deps/auth.ts 2>$null | Out-String).Trim() } finally { $ErrorActionPreference = $prevEapH03 }
    if ($wtDiffAuth) { $g3Errs.Add("H-03 setup expected WT==HEAD on src/deps/auth.ts, got: $wtDiffAuth") }
    Add-Err $g3Errs (Test-CrossShellCheck -Rec $r1 -Label 'inv-anchor-staged-divergence' -ExpectedCode 2 -MatchPattern $c3AncStale -Opts @{ ScopeId = 'rl-iter1' })
    [void](Invoke-GitQuiet $rCache @('reset', '-q', 'HEAD', '--', 'src/deps/auth.ts'))

    # Invalidation 3: changed summary_ref digest
    Write-LfFile $sumFull "# Iter 1 Summary`nMutated digest`n"
    Add-Err $g3Errs (Test-CrossShellCheck -Rec $r1 -Label 'inv-summary-changed' -ExpectedCode 2 `
        -MatchPattern '^CONTEXT_STALE: scope=rl-iter1 reasons=summary_changed anchor_status=FRESH graph_index=NOT_RECORDED live_lsp_eligible=true$' -Opts @{ ScopeId = 'rl-iter1' })
    Write-LfFile $sumFull $sumInit

    # Invalidation 4: diverged HEAD (record at c2 to distinct -ps.ctx/-sh.ctx, then git reset --hard HEAD~1)
    $recC2 = Test-RecordParity -RepoDir $rCache -BaseCacheRel '.b3/ship/ctx/iter2' -Label 'record-at-c2' `
        -Opts @{ ScopeId = 'rl-iter1'; AnchorPaths = $anchorsCsv; SummaryRef = $sumRel; GraphIndexSha = 'none' }
    Add-Err $g3Errs $recC2.Err
    [void](Invoke-GitQuiet $rCache @('reset', '--hard', '-q', 'HEAD~1'))
    Add-Err $g3Errs (Test-CrossShellCheck -Rec $recC2 -Label 'inv-head-diverged' -ExpectedCode 2 `
        -MatchPattern '^CONTEXT_STALE: scope=rl-iter1 reasons=head_diverged anchor_status=STALE graph_index=NOT_RECORDED live_lsp_eligible=true$' -Opts @{ ScopeId = 'rl-iter1' })

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

    $gSumRel = '.b3/ship/ctx/graph-sum.md'
    $gSumFull = Join-Path $rGraph '.b3\ship\ctx\graph-sum.md'
    Write-LfFile $gSumFull "# Graph Summary A`n"
    $gFresh = "^CONTEXT_FRESH: scope=graph-scope head=$gHead anchor_status=FRESH graph_index=FRESH live_lsp_eligible=true$"
    $gStale = '^CONTEXT_STALE: scope=graph-scope reasons=graph_index_stale anchor_status=FRESH graph_index=STALE live_lsp_eligible=true$'
    $gMis   = '^CONTEXT_STALE: scope=graph-scope reasons=graph_index_mismatch anchor_status=FRESH graph_index=STALE live_lsp_eligible=true$'

    $gRec = Test-RecordParity -RepoDir $rGraph -BaseCacheRel '.b3/ship/ctx/graph' -Label 'graph-record' `
        -MatchPattern "^CONTEXT_RECORDED: \.b3/ship/ctx/graph-ps\.ctx scope=graph-scope head=$gHead anchor_hash=[0-9a-f]{40} graph_index_sha=$gHead$" `
        -Opts @{ ScopeId = 'graph-scope'; AnchorPaths = 'src/anchor.ts'; SummaryRef = $gSumRel; GraphIndexSha = $gHead }
    Add-Err $g4Errs $gRec.Err
    $gPsRel = $gRec.PsRel

    # 4a / 4a2. Clean HEAD=A -> FRESH; mismatched -GraphIndexSha none at clean A -> graph_index_mismatch
    Add-Err $g4Errs (Test-CrossShellCheck -Rec $gRec -Label 'graph-clean' -ExpectedCode 0 -MatchPattern $gFresh -Opts @{ ScopeId = 'graph-scope' })
    Add-Err $g4Errs (Test-CrossShellCheck -Rec $gRec -Label 'graph-mismatch-none-at-a' -ExpectedCode 2 -MatchPattern $gMis -Opts @{ ScopeId = 'graph-scope'; GraphIndexSha = 'none' })

    # 4b. Dirty WT outside anchors with omitted -ScopePaths -> CONTEXT_STALE across both -ps.ctx and -sh.ctx
    Write-LfFile (Join-Path $rGraph 'src\other.ts') "export const O = 2;`n"
    Add-Err $g4Errs (Test-CrossShellCheck -Rec $gRec -Label 'graph-dirty-wt-no-scope' -ExpectedCode 2 -MatchPattern $gStale -Opts @{ ScopeId = 'graph-scope' })
    [void](Invoke-GitQuiet $rGraph @('checkout', '--', 'src/other.ts'))

    # 4c. Dirty WT inside explicit -ScopePaths -> CONTEXT_STALE
    Write-LfFile (Join-Path $rGraph 'src\scope\mod.ts') "export const M = 2;`n"
    Add-Err $g4Errs (Invoke-CtxParity -RepoDir $rGraph -Action 'check' -CachePath $gPsRel -Label 'graph-dirty-in-scope' -ExpectedCode 2 -MatchPattern $gStale `
        -Opts @{ ScopeId = 'graph-scope'; ScopePaths = 'src/scope/mod.ts' }).Err
    [void](Invoke-GitQuiet $rGraph @('checkout', '--', 'src/scope/mod.ts'))

    # 4d. Staged rename (R): src-only ign (STALE), dest-only ign (STALE), both ign (FRESH), and literal ' -> ' filename (--porcelain -z)
    [void](Invoke-GitQuiet $rGraph @('mv', 'src/other.ts', 'src/other-renamed.ts'))
    foreach ($rc in @(
        @{ Label = 'graph-staged-rename-src-only-ign';  Ign = 'src/other.ts';                   Code = 2; Pat = $gStale },
        @{ Label = 'graph-staged-rename-dest-only-ign'; Ign = 'src/other-renamed.ts';           Code = 2; Pat = $gStale },
        @{ Label = 'graph-staged-rename-both-ign';      Ign = 'src/other.ts,src/other-renamed.ts'; Code = 0; Pat = $gFresh }
    )) {
        Add-Err $g4Errs (Invoke-CtxParity -RepoDir $rGraph -Action 'check' -CachePath $gPsRel -Label $rc.Label -ExpectedCode $rc.Code -MatchPattern $rc.Pat `
            -Opts @{ ScopeId = 'graph-scope'; IgnoreDirtyPaths = $rc.Ign }).Err
    }
    [void](Invoke-GitQuiet $rGraph @('reset', '--hard', '-q', 'HEAD'))

    [void](Invoke-GitQuiet $rGraph @('rm', '-q', 'src/other.ts'))
    [void](Invoke-GitQuiet $rGraph @('-c', 'core.protectNTFS=false', 'update-index', '--add', '--cacheinfo', "100644,$otherBlob,src/a -> b.ts"))
    Add-Err $g4Errs (Invoke-CtxParity -RepoDir $rGraph -Action 'check' -CachePath $gPsRel -Label 'graph-staged-rename-arrow' -ExpectedCode 2 -MatchPattern $gStale `
        -Opts @{ ScopeId = 'graph-scope'; IgnoreDirtyPaths = 'src/other.ts' }).Err
    [void](Invoke-GitQuiet $rGraph @('reset', '--hard', '-q', 'HEAD'))

    # 4e. Changed -AnchorPaths + -ScopePaths with dirty newly added anchor (callerAnchorArr) -> anchor_scope_changed,graph_index_stale
    Write-LfFile (Join-Path $rGraph 'src\new_anchor.ts') "export const N = 2;`n"
    Add-Err $g4Errs (Invoke-CtxParity -RepoDir $rGraph -Action 'check' -CachePath $gPsRel -Label 'graph-caller-new-anchor-dirty' -ExpectedCode 2 `
        -MatchPattern '^CONTEXT_STALE: scope=graph-scope reasons=anchor_scope_changed,graph_index_stale anchor_status=STALE graph_index=STALE live_lsp_eligible=true$' `
        -Opts @{ ScopeId = 'graph-scope'; AnchorPaths = 'src/anchor.ts,src/new_anchor.ts'; ScopePaths = 'src/scope/mod.ts' }).Err
    [void](Invoke-GitQuiet $rGraph @('checkout', '--', 'src/new_anchor.ts'))

    # 4f. Dirty submodule even with diff.ignoreSubmodules=all -> CONTEXT_STALE
    [void](Invoke-GitQuiet $rGraph @('config', 'diff.ignoreSubmodules', 'all'))
    Write-LfFile (Join-Path $rGraph 'libs\sub\sub.ts') "export const subVer = 2;`n"
    Add-Err $g4Errs (Invoke-CtxParity -RepoDir $rGraph -Action 'check' -CachePath $gPsRel -Label 'graph-dirty-submodule' -ExpectedCode 2 -MatchPattern $gStale -Opts @{ ScopeId = 'graph-scope' }).Err
    Add-Err $g4Errs (Invoke-CtxParity -RepoDir $rGraph -Action 'check' -CachePath $gPsRel -Label 'graph-dirty-submodule-scoped' -ExpectedCode 2 -MatchPattern $gStale -Opts @{ ScopeId = 'graph-scope'; ScopePaths = 'libs/sub' }).Err
    [void](Invoke-GitQuiet (Join-Path $rGraph 'libs\sub') @('checkout', '--', 'sub.ts'))
    [void](Invoke-GitQuiet $rGraph @('config', '--unset', 'diff.ignoreSubmodules'))

    # 4g. Advance HEAD from A to B modifying non-anchor src/other.ts (anchors unchanged)
    Write-LfFile (Join-Path $rGraph 'src\other.ts') "export const O = 3;`n"
    [void](Invoke-GitQuiet $rGraph @('add', 'src/other.ts'))
    [void](Invoke-GitQuiet $rGraph @('commit', '-qm', 'advance head'))
    $gHeadB = Invoke-GitQuiet $rGraph @('rev-parse', 'HEAD')

    Add-Err $g4Errs (Test-CrossShellCheck -Rec $gRec -Label 'graph-head-moved' -ExpectedCode 2 -MatchPattern $gStale -Opts @{ ScopeId = 'graph-scope' })

    # 4g2. P1 regression: caller passes new commit B against cache recorded from graph A -> graph_index_mismatch,graph_index_stale
    Add-Err $g4Errs (Test-CrossShellCheck -Rec $gRec -Label 'graph-head-moved-mismatch-b' -ExpectedCode 2 `
        -MatchPattern '^CONTEXT_STALE: scope=graph-scope reasons=graph_index_mismatch,graph_index_stale anchor_status=FRESH graph_index=STALE live_lsp_eligible=true$' `
        -Opts @{ ScopeId = 'graph-scope'; GraphIndexSha = $gHeadB })

    # 4g3. Stale summary + mismatched graph SHA at B -> summary_changed,graph_index_mismatch,graph_index_stale
    Write-LfFile $gSumFull "# Graph Summary B`nUpdated for commit B`n"
    Add-Err $g4Errs (Test-CrossShellCheck -Rec $gRec -Label 'graph-summary-and-sha-mismatch' -ExpectedCode 2 `
        -MatchPattern '^CONTEXT_STALE: scope=graph-scope reasons=summary_changed,graph_index_mismatch,graph_index_stale anchor_status=FRESH graph_index=STALE live_lsp_eligible=true$' `
        -Opts @{ ScopeId = 'graph-scope'; GraphIndexSha = $gHeadB })

    # 4g4. Valid re-recording at B with updated summary + GraphIndexSha B -> CONTEXT_FRESH
    $gRecB = Test-RecordParity -RepoDir $rGraph -BaseCacheRel '.b3/ship/ctx/graph' -Label 'graph-rerecord-at-b' `
        -MatchPattern "^CONTEXT_RECORDED: \.b3/ship/ctx/graph-ps\.ctx scope=graph-scope head=$gHeadB anchor_hash=[0-9a-f]{40} graph_index_sha=$gHeadB$" `
        -Opts @{ ScopeId = 'graph-scope'; AnchorPaths = 'src/anchor.ts'; SummaryRef = $gSumRel; GraphIndexSha = $gHeadB }
    Add-Err $g4Errs $gRecB.Err
    Add-Err $g4Errs (Test-CrossShellCheck -Rec $gRecB -Label 'graph-rerecord-at-b-fresh' -ExpectedCode 0 `
        -MatchPattern "^CONTEXT_FRESH: scope=graph-scope head=$gHeadB anchor_status=FRESH graph_index=FRESH live_lsp_eligible=true$" `
        -Opts @{ ScopeId = 'graph-scope'; SummaryRef = $gSumRel; GraphIndexSha = $gHeadB })

    # 4g5. Mismatched older SHA A against re-recorded B cache at clean HEAD=B -> graph_index_mismatch
    Add-Err $g4Errs (Test-CrossShellCheck -Rec $gRecB -Label 'graph-mismatch-old-a-against-b' -ExpectedCode 2 -MatchPattern $gMis `
        -Opts @{ ScopeId = 'graph-scope'; GraphIndexSha = $gHead })

    # 4h. Symmetric P1 regression: recorded graph_index_sha=none checked with live HEAD=B or older A -> graph_index_mismatch (never FRESH)
    $gRecNone = Test-RecordParity -RepoDir $rGraph -BaseCacheRel '.b3/ship/ctx/graph-none' -Label 'graph-record-none-at-b' `
        -Opts @{ ScopeId = 'graph-scope'; AnchorPaths = 'src/anchor.ts'; GraphIndexSha = 'none' }
    Add-Err $g4Errs $gRecNone.Err
    Add-Err $g4Errs (Test-CrossShellCheck -Rec $gRecNone -Label 'graph-none-vs-caller-head-b' -ExpectedCode 2 -MatchPattern $gMis `
        -Opts @{ ScopeId = 'graph-scope'; GraphIndexSha = $gHeadB })
    Add-Err $g4Errs (Test-CrossShellCheck -Rec $gRecNone -Label 'graph-none-vs-caller-old-a' -ExpectedCode 2 `
        -MatchPattern '^CONTEXT_STALE: scope=graph-scope reasons=graph_index_mismatch,graph_index_stale anchor_status=FRESH graph_index=STALE live_lsp_eligible=true$' `
        -Opts @{ ScopeId = 'graph-scope'; GraphIndexSha = $gHead })

    if ($g4Errs.Count -eq 0) { Pass 'stale-graph-index-vs-live-lsp' } else { FailCheck 'stale-graph-index-vs-live-lsp' ($g4Errs -join '; ') }

    # =========================================================================
    # Group 5: security-containment-and-tamper-fail-closed
    # =========================================================================
    $g5Errs = New-Object System.Collections.Generic.List[string]
    $rSec = Join-Path $sandbox 'sec-repo'; $rSecP = To-Posix $rSec
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
        -Opts @{ ScopeId = 'sec-scope'; AnchorPaths = 'src/a.ts'; SummaryRef = $secSumRel }
    $secCacheRel = $secRec.PsRel
    $validCacheRaw = ''
    if ($secRec.Ok) { $validCacheRaw = [System.IO.File]::ReadAllText($secRec.PsFull, $utf8NoBom) } else { $g5Errs.Add($secRec.Err) }

    # 5a. Forbidden anchor paths (git, nested .git, ADS :, trailing dot/space, absolute, .., junction, secret, glob, pathspec magic, leading -)
    $badAnchorCases = @(
        @{ Label = 'dotdot-git'; Val = '././.git/config' },
        @{ Label = 'nested-git'; Val = 'src/.git/config' },
        @{ Label = 'ads-colon'; Val = 'src/a.ts:stream' },
        @{ Label = 'trailing-dot-git'; Val = '.git.' },
        @{ Label = 'trailing-dot-b3'; Val = '.b3.' },
        @{ Label = 'trailing-dot-cred'; Val = 'credentials.json.' },
        @{ Label = 'trailing-space'; Val = 'src/a.ts ' },
        @{ Label = 'abs-path'; Val = '/etc/passwd'; NoConv = $true },
        @{ Label = 'parent-traversal'; Val = '../outside-sec/secret.txt' },
        @{ Label = 'junction-anchor'; Val = 'linked-out/secret.txt' },
        @{ Label = 'secret-env'; Val = '.env' },
        @{ Label = 'secret-cred'; Val = 'credentials.json' },
        @{ Label = 'glob-star'; Val = 'src/*'; NoGlob = $true },
        @{ Label = 'pathspec-magic'; Val = ':(top)src/a.ts' },
        @{ Label = 'leading-dash'; Val = '--cached' }
    )
    foreach ($bc in $badAnchorCases) {
        Add-Err $g5Errs (Invoke-CtxParity -RepoDir $rSec -Action 'record' -CachePath '.b3/ship/ctx/tmp.cache' -Label "bad-anchor-$($bc.Label)" `
            -ExpectedCode 1 -MatchPattern '^CONTEXT_ERROR: invalid path ' -NoGlob:([bool]$bc.NoGlob) -NoPathConv:([bool]$bc.NoConv) `
            -Opts @{ ScopeId = 'sec-bad'; AnchorPaths = $bc.Val }).Err
    }

    # 5b. Forbidden cache_path (generic .b3/models.md, .b3/home, .b3/autodev/x, absolute, .., junction, ADS, trailing dot/space, secret)
    $badCacheCases = @(
        @{ Label = 'b3-models'; Val = '.b3/models.md' },
        @{ Label = 'b3-home'; Val = '.b3/home' },
        @{ Label = 'b3-autodev'; Val = '.b3/autodev/x' },
        @{ Label = 'abs-cache'; Val = '/tmp/x.cache'; NoConv = $true },
        @{ Label = 'trav-cache'; Val = '.b3/ship/../../escape.cache' },
        @{ Label = 'junc-cache'; Val = '.b3/ship/linked-ctx/esc.cache' },
        @{ Label = 'ads-cache'; Val = '.b3/ship/ctx/a.cache:stream' },
        @{ Label = 'dot-cache'; Val = '.b3/ship/ctx/a.cache.' },
        @{ Label = 'space-cache'; Val = '.b3/ship/ctx/a.cache ' },
        @{ Label = 'secret-cache'; Val = '.b3/ship/.env' }
    )
    foreach ($cc in $badCacheCases) {
        Add-Err $g5Errs (Invoke-CtxParity -RepoDir $rSec -Action 'record' -CachePath $cc.Val -Label "bad-cache-$($cc.Label)" `
            -ExpectedCode 1 -MatchPattern '^CONTEXT_ERROR: invalid cache_path$' -NoPathConv:([bool]$cc.NoConv) `
            -Opts @{ ScopeId = 'sec-bad'; AnchorPaths = 'src/a.ts' }).Err
    }

    # 5c. Raw control char in CLI arg ("foo`nbar") -- use UTF-16LE -EncodedCommand for PS and ANSI-C quoting for Bash
    $psCtrlCmd = "& $(Quote-PsSingle $guardPs) context-cache -RepoRoot $(Quote-PsSingle $rSec) -Action record -CachePath '.b3/ship/ctx/ctrl.cache' -ScopeId `"foo``nbar`" -AnchorPaths 'src/a.ts'"
    $psCtrlEnc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($psCtrlCmd))
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $rawPsCtrl = & powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $psCtrlEnc 2>&1; $psCtrlCode = $LASTEXITCODE } finally { $ErrorActionPreference = $prevEap }
    $psCtrlLines = @($rawPsCtrl | ForEach-Object { ([string]$_).TrimEnd("`r") })
    $psCtrl = @{ Code = $psCtrlCode; Lines = $psCtrlLines; Text = ($psCtrlLines -join "`n") }
    $shCtrl = Invoke-ShGuard @('context-cache', '--repo-root', $rSecP, '--action', 'record', '--cache-path', '.b3/ship/ctx/ctrl.cache', '--scope-id', "foo`nbar", '--anchor-paths', 'src/a.ts')
    Add-Err $g5Errs (Assert-Parity $psCtrl $shCtrl 1 '^CONTEXT_ERROR: control characters not allowed$' 'cli-ctrl-char')

    # 5d. Bidirectional IgnoreDirtyPaths overlap (parent/child anchor + scope + mixed-case ordinal parity)
    $ignFailCases = @(
        @{ Label = 'ign-parent-of-anchor'; Opts = @{ AnchorPaths = 'src/dir/b.ts'; IgnoreDirtyPaths = 'src/dir' } },
        @{ Label = 'ign-child-of-anchor';  Opts = @{ AnchorPaths = 'src/dir'; IgnoreDirtyPaths = 'src/dir/b.ts' } },
        @{ Label = 'ign-parent-of-scope';  Opts = @{ AnchorPaths = 'src/a.ts'; ScopePaths = 'src/dir/b.ts'; IgnoreDirtyPaths = 'src/dir' } },
        @{ Label = 'ign-child-of-scope';   Opts = @{ AnchorPaths = 'src/a.ts'; ScopePaths = 'src/dir'; IgnoreDirtyPaths = 'src/dir/b.ts' } },
        @{ Label = 'ign-exact-mixedcase';  Opts = @{ AnchorPaths = 'src/MixedCase/File.ts'; IgnoreDirtyPaths = 'src/MixedCase/File.ts' } }
    )
    foreach ($ic in $ignFailCases) {
        $opts = @{ ScopeId = 'sec-ign' } + $ic.Opts
        Add-Err $g5Errs (Invoke-CtxParity -RepoDir $rSec -Action 'record' -CachePath '.b3/ship/ctx/ign.cache' -Label $ic.Label `
            -ExpectedCode 1 -MatchPattern '^CONTEXT_ERROR: invalid ignore path$' -Opts $opts).Err
    }
    Add-Err $g5Errs (Test-RecordParity -RepoDir $rSec -BaseCacheRel '.b3/ship/ctx/ign-ord' -Label 'ign-mixedcase-ordinal-nonoverlap' `
        -Opts @{ ScopeId = 'sec-ign-ord'; AnchorPaths = 'src/MixedCase/File.ts'; IgnoreDirtyPaths = 'src/mixedcase/file.ts' }).Err

    # 5e. Cross-scope & -SummaryRef CONTEXT_MISMATCH
    Add-Err $g5Errs (Invoke-CtxParity -RepoDir $rSec -Action 'check' -CachePath $secCacheRel -Label 'mismatch-scope' -ExpectedCode 1 `
        -MatchPattern '^CONTEXT_MISMATCH: scope_id expected=other-scope got=sec-scope$' -Opts @{ ScopeId = 'other-scope' }).Err
    Add-Err $g5Errs (Invoke-CtxParity -RepoDir $rSec -Action 'check' -CachePath $secCacheRel -Label 'mismatch-summary-ref' -ExpectedCode 1 `
        -MatchPattern '^CONTEXT_MISMATCH: summary_ref expected=\.b3/ship/ctx/other\.md got=\.b3/ship/ctx/sum\.md$' `
        -Opts @{ ScopeId = 'sec-scope'; SummaryRef = '.b3/ship/ctx/other.md' }).Err

    # 5f. Tampered cache files: CRLF, invalid UTF-8, duplicate/unknown/missing keys
    $tamperRel = '.b3/ship/ctx/tamper.cache'
    $tamperFull = Join-Path $rSec '.b3\ship\ctx\tamper.cache'
    $missingKeyBody = (($validCacheRaw -split "`n") | Where-Object { $_ -and ($_ -notmatch '^timestamp_utc=') }) -join "`n"
    $tamperCases = @(
        @{ Label = 'tamper-crlf';         Bytes = $utf8NoBom.GetBytes(($validCacheRaw -replace "`n", "`r`n")); Pat = '^CONTEXT_CORRUPT: control character or CRLF in cache$' },
        @{ Label = 'tamper-invalid-utf8'; Bytes = [byte[]]@(0xFF, 0xFE, 0x0A);                                 Pat = '^CONTEXT_CORRUPT: invalid utf8 encoding$' },
        @{ Label = 'tamper-dup-key';      Text  = ($validCacheRaw + "scope_id=dup`n");                         Pat = "^CONTEXT_CORRUPT: duplicate field 'scope_id'$" },
        @{ Label = 'tamper-unknown-key';  Text  = ($validCacheRaw + "evil_key=1`n");                           Pat = "^CONTEXT_CORRUPT: unknown field 'evil_key'$" },
        @{ Label = 'tamper-missing-key';  Text  = ($missingKeyBody + "`n");                                    Pat = "^CONTEXT_CORRUPT: missing field 'timestamp_utc'$" }
    )
    foreach ($tc in $tamperCases) {
        if ($tc.ContainsKey('Bytes')) { [System.IO.File]::WriteAllBytes($tamperFull, $tc.Bytes) } else { Write-LfFile $tamperFull $tc.Text }
        Add-Err $g5Errs (Invoke-CtxParity -RepoDir $rSec -Action 'check' -CachePath $tamperRel -Label $tc.Label -ExpectedCode 1 -MatchPattern $tc.Pat).Err
    }

    # 5g. Deleted summary_ref -> CONTEXT_CORRUPT
    Remove-Item -LiteralPath $secSumFull -Force
    Add-Err $g5Errs (Invoke-CtxParity -RepoDir $rSec -Action 'check' -CachePath $secCacheRel -Label 'deleted-summary-ref' -ExpectedCode 1 `
        -MatchPattern '^CONTEXT_CORRUPT: missing or invalid summary_ref$' -Opts @{ ScopeId = 'sec-scope' }).Err
    Write-LfFile $secSumFull $secSumBody

    # 5h. Mid-merge git state (.git/MERGE_HEAD) -> CONTEXT_ERROR: mid-operation git state
    $mergeHead = Join-Path $rSec '.git\MERGE_HEAD'
    Write-LfFile $mergeHead "$secHead`n"
    Add-Err $g5Errs (Invoke-CtxParity -RepoDir $rSec -Action 'check' -CachePath $secCacheRel -Label 'mid-merge-state' -ExpectedCode 1 `
        -MatchPattern '^CONTEXT_ERROR: mid-operation git state$' -Opts @{ ScopeId = 'sec-scope' }).Err
    Remove-Item -LiteralPath $mergeHead -Force

    # 5i. Empty context-cache fail-closed (record & tampered check) + graph-only anchor_status=NOT_RECORDED
    $emptyRecPat = '^CONTEXT_ERROR: empty cache \(anchor_paths or graph_index_sha required\)$'
    Add-Err $g5Errs (Invoke-CtxParity -RepoDir $rSec -Action 'record' -CachePath '.b3/ship/ctx/empty-no-sum.cache' -Label 'empty-cache-record-no-summary' `
        -ExpectedCode 1 -MatchPattern $emptyRecPat -Opts @{ ScopeId = 'sec-empty'; AnchorPaths = 'none'; GraphIndexSha = 'none' }).Err
    Add-Err $g5Errs (Invoke-CtxParity -RepoDir $rSec -Action 'record' -CachePath '.b3/ship/ctx/empty-with-sum.cache' -Label 'empty-cache-record-with-summary' `
        -ExpectedCode 1 -MatchPattern $emptyRecPat -Opts @{ ScopeId = 'sec-empty'; AnchorPaths = 'none'; GraphIndexSha = 'none'; SummaryRef = $secSumRel }).Err

    $secSumSha = (Get-FileHash -LiteralPath $secSumFull -Algorithm SHA256).Hash.ToLowerInvariant()
    $emptyCorruptPat = '^CONTEXT_CORRUPT: empty cache \(anchor_paths or graph_index_sha required\)$'
    $tamperEmptyNoSum = "schema=b3-context-v1`nscope_id=sec-empty`nhead_sha=$secHead`nanchor_paths=none`nanchor_hash=none`ngraph_index_sha=none`nsummary_ref=none`nsummary_sha256=none`ntimestamp_utc=2026-11-24T00:00:00Z`n"
    Write-LfFile $tamperFull $tamperEmptyNoSum
    Add-Err $g5Errs (Invoke-CtxParity -RepoDir $rSec -Action 'check' -CachePath $tamperRel -Label 'tamper-empty-cache-no-summary' `
        -ExpectedCode 1 -MatchPattern $emptyCorruptPat).Err
    $tamperEmptyWithSum = "schema=b3-context-v1`nscope_id=sec-empty`nhead_sha=$secHead`nanchor_paths=none`nanchor_hash=none`ngraph_index_sha=none`nsummary_ref=$secSumRel`nsummary_sha256=$secSumSha`ntimestamp_utc=2026-11-24T00:00:00Z`n"
    Write-LfFile $tamperFull $tamperEmptyWithSum
    Add-Err $g5Errs (Invoke-CtxParity -RepoDir $rSec -Action 'check' -CachePath $tamperRel -Label 'tamper-empty-cache-with-summary' `
        -ExpectedCode 1 -MatchPattern $emptyCorruptPat).Err

    # Remove untracked linked-out junction from 5a so repo WT is clean for graph-only freshness check
    [System.IO.Directory]::Delete((Join-Path $rSec 'linked-out'), $false)
    $graphOnlyRec = Test-RecordParity -RepoDir $rSec -BaseCacheRel '.b3/ship/ctx/graph-only' -Label 'graph-only-record' `
        -MatchPattern "^CONTEXT_RECORDED: \.b3/ship/ctx/graph-only-ps\.ctx scope=sec-graph-only head=$secHead anchor_hash=none graph_index_sha=$secHead$" `
        -Opts @{ ScopeId = 'sec-graph-only'; AnchorPaths = 'none'; GraphIndexSha = $secHead }
    Add-Err $g5Errs $graphOnlyRec.Err
    if ($graphOnlyRec.Ok) {
        Add-Err $g5Errs (Test-CrossShellCheck -Rec $graphOnlyRec -Label 'graph-only-anchor-not-recorded' -ExpectedCode 0 `
            -MatchPattern "^CONTEXT_FRESH: scope=sec-graph-only head=$secHead anchor_status=NOT_RECORDED graph_index=FRESH live_lsp_eligible=true$" `
            -Opts @{ ScopeId = 'sec-graph-only'; GraphIndexSha = $secHead })
    }

    if ($g5Errs.Count -eq 0) { Pass 'security-containment-and-tamper-fail-closed' } else { FailCheck 'security-containment-and-tamper-fail-closed' ($g5Errs -join '; ') }

    # =========================================================================
    # Group 6: four-host-compat-and-zero-always-on
    # =========================================================================
    $g6Errs = New-Object System.Collections.Generic.List[string]

    foreach ($hName in @('cursor', 'codex', 'claude')) {
        $fxDir = Join-Path $sandbox "sync-fx-$hName"
        New-Item -ItemType Directory -Path (Join-Path $fxDir 'adapters\command-skills\b3-ship'), (Join-Path $fxDir 'adapters\lib'), (Join-Path $fxDir 'skills\engineering\demo'), (Join-Path $fxDir 'commands'), (Join-Path $fxDir 'agents') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $root 'adapters\sync-skills.ps1') -Destination (Join-Path $fxDir 'adapters\sync-skills.ps1') -Force
        Copy-Item -LiteralPath (Join-Path $root 'adapters\lib\global-common.ps1') -Destination (Join-Path $fxDir 'adapters\lib\global-common.ps1') -Force
        Write-LfFile (Join-Path $fxDir 'skills\engineering\demo\SKILL.md') "---`nname: demo`ndescription: demo skill`n---`n# Demo`n"
        Write-LfFile (Join-Path $fxDir 'adapters\command-skills\b3-ship\SKILL.md') "---`nname: b3-ship`ndescription: ship cmd`n---`n# Ship`n"
        Write-LfFile (Join-Path $fxDir 'commands\b3-ship.md') "# Ship`n"
        Write-LfFile (Join-Path $fxDir 'agents\b3-reviewer.md') "# Reviewer`n"

        $syncRes = Invoke-PsScript -ScriptPath (Join-Path $fxDir 'adapters\sync-skills.ps1') -ScriptArgs @('-HostName', $hName)
        $verRes = Invoke-PsScript -ScriptPath (Join-Path $fxDir 'adapters\sync-skills.ps1') -ScriptArgs @('-HostName', $hName, '-VerifyOnly')
        if ($syncRes.Code -ne 0 -or $verRes.Code -ne 0) { $g6Errs.Add("sync-skills $hName failed sync=$($syncRes.Code) ver=$($verRes.Code)") }
    }

    $agVer = Invoke-PsScript -ScriptPath (Join-Path $root 'adapters\sync-skills.ps1') -ScriptArgs @('-HostName', 'antigravity', '-VerifyOnly')
    if ($agVer.Code -ne 0) { $g6Errs.Add("antigravity verify failed exit=$($agVer.Code) out=$($agVer.Text)") }

    $mcPs = Invoke-PsScript -ScriptPath $measurePs -ScriptArgs @('-RepoRoot', $root, '-Strict')
    $mcSh = Invoke-ShScriptArgs -ScriptPosix $measureShPosix -ScriptArgs @('--repo-root', (To-Posix $root), '--strict')
    Add-Err $g6Errs (Assert-Parity $mcPs $mcSh 0 '' 'measure-context-strict')
    if ($mcPs.Text -notmatch '(?m)^warnings\s*:\s*0$') { $g6Errs.Add('measure-context warnings != 0') }
    if ($mcPs.Text -match '(?m)^context_routing\s*:\s*(\d+)\s+B\b') {
        $crMeasured = [int]$Matches[1]
        if ($crMeasured -lt 1 -or $crMeasured -gt 3000) { $g6Errs.Add("context_routing measured=$crMeasured B (> 3000 B)") }
    } else {
        $g6Errs.Add('measure-context missing context_routing line')
    }
    if ($mcPs.Text -match '(?m)^dispatch_naming\s*:\s*(\d+)\s+B\b') {
        $dnMeasured = [int]$Matches[1]
        if ($dnMeasured -lt 1 -or $dnMeasured -gt 9200) { $g6Errs.Add("dispatch_naming measured=$dnMeasured B (> 9200 B)") }
    } else {
        $g6Errs.Add('measure-context missing dispatch_naming line')
    }

    # M-13 headroom caps (LF bytes)
    foreach ($hb in @(
        @{ Rel = 'review-loop\strategy.md'; Max = 5200 },
        @{ Rel = 'workflows\references\context-routing.md'; Max = 3000 },
        @{ Rel = 'skills\engineering\problem-solving\SKILL.md'; Max = 3850 }
    )) {
        $hBytes = Get-LfByteLength (Join-Path $root $hb.Rel)
        if ($hBytes -lt 1 -or $hBytes -gt $hb.Max) {
            $g6Errs.Add("M-13 headroom exceeded: $($hb.Rel)=$hBytes B (> $($hb.Max) B)")
        }
    }

    $aoPattern = 'context-routing\.md|context-cache|codebase[\s-]*memory|serena'
    if ((Get-Content -LiteralPath (Join-Path $root 'AGENTS.md') -Raw) -match $aoPattern) {
        $g6Errs.Add('AGENTS.md contains forbidden context-routing/MCP keyword')
    }
    foreach ($rf in @(Get-ChildItem -LiteralPath (Join-Path $root 'rules') -Filter '*.md' -File)) {
        if ((Get-Content -LiteralPath $rf.FullName -Raw) -match $aoPattern) { $g6Errs.Add("rules/$($rf.Name) contains forbidden context-routing/MCP keyword") }
    }
    foreach ($skillRoot in @('skills', 'adapters\command-skills')) {
        $srFull = Join-Path $root $skillRoot
        if (-not (Test-Path -LiteralPath $srFull -PathType Container)) { continue }
        foreach ($sf in @(Get-ChildItem -LiteralPath $srFull -Recurse -Filter 'SKILL.md' -File)) {
            $lf = $isoEnc.GetString([System.IO.File]::ReadAllBytes($sf.FullName)).Replace("`r", '')
            if ($lf -match '(?s)\A---\n(.*?)\n---(?:\n|\z)' -and $Matches[1] -match $aoPattern) {
                $relSf = $sf.FullName.Substring($root.Length + 1) -replace '\\', '/'
                $g6Errs.Add("$relSf frontmatter contains forbidden context-routing/MCP keyword")
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

Complete-ValidationSuite -AllowIncompleteBash:$AllowIncompleteBash
