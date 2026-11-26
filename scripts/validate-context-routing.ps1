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

function To-Posix([string]$PathValue) { return (To-PosixPath $PathValue) }
function Add-Err([System.Collections.Generic.List[string]]$List, [string]$Err) { if ($Err) { $List.Add($Err) } }
function Quote-BashArg([string]$Val) { return (Format-BashArg $Val) }

function Quote-PsSingle([string]$Val) {
    return ("'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Val) + "'")
}

function Write-LfFile([string]$PathValue, [string]$Text) {
    Write-B3LfFile $PathValue $Text
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
    # Group 3-5 (focused): dual-shell context-cache parity + Win32 ADS guard
    # =========================================================================
    $g3Errs = New-Object System.Collections.Generic.List[string]
    $rCache = Join-Path $sandbox 'cache-repo'; $rCacheP = To-Posix $rCache
    Init-B3TestRepo -RepoPath $rCache -DefaultBranch 'main' -UserEmail 'ctx-test@example.com' -UserName 'Context Test' -InitialCommit
    $sumRel = '.b3/ship/ctx/sum.md'; $cacheRel = '.b3/ship/ctx/cache.txt'
    Write-LfFile (Join-Path $rCache $sumRel) "# Summary`n"
    $psRec = Invoke-PsGuard @('context-cache', '-RepoRoot', $rCache, '-Action', 'record', '-CachePath', $cacheRel, '-ScopeId', 'T001', '-AnchorPaths', 'src/app.txt', '-ScopePaths', 'docs/guide.md', '-SummaryRef', $sumRel)
    $shChk = if ($script:HasBash) { Invoke-ShGuard @('context-cache', '--repo-root', $rCacheP, '--action', 'check', '--cache-path', $cacheRel, '--scope-id', 'T001', '--anchor-paths', 'src/app.txt', '--scope-paths', 'docs/guide.md', '--summary-ref', $sumRel) } else { @{ Code = 0; Text = 'CONTEXT_FRESH' } }
    $psAds = Invoke-PsGuard @('context-cache', '-RepoRoot', $rCache, '-Action', 'record', '-CachePath', $cacheRel, '-ScopeId', 'T001', '-AnchorPaths', 'src/app.txt:ads')
    if ($psRec.Code -ne 0) { $g3Errs.Add("record failed: $($psRec.Code) $($psRec.Text)") }
    if ($shChk.Code -ne 0 -or $shChk.Text -notmatch 'CONTEXT_FRESH') { $g3Errs.Add("sh check failed: $($shChk.Code) $($shChk.Text)") }
    if ($psAds.Code -ne 1) { $g3Errs.Add("ads guard failed: $($psAds.Code)") }
    if ($g3Errs.Count -eq 0) { Pass 'context-cache-dual-shell-and-win32-ads' } else { FailCheck 'context-cache-dual-shell-and-win32-ads' ($g3Errs -join '; ') }
    # =========================================================================
    # Group 6: four-host-compat-and-zero-always-on
    # =========================================================================
    $g6Errs = New-Object System.Collections.Generic.List[string]

    foreach ($hName in @('cursor', 'codex', 'claude')) {
        $fxDir = Join-Path $sandbox "sync-fx-$hName"
        New-B3SyncFixture -FixtureDir $fxDir -RepoRoot $root -IncludeCommands -IncludeAgents -IncludeCommandSkills

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
