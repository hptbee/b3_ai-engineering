# Behavioral validation suite for global Antigravity plugin lifecycle and unified adapters/install-global dispatcher.
# Exercises install, verify (independent capability surfaces), update, dry-run, uninstall, drift/broken links, spaces, coexistence, and dispatcher parity across PowerShell and Git Bash.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate-antigravity-global.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$agPs = Join-Path $root 'adapters\antigravity\install-plugin.ps1'
$agShPosix = ($root -replace '\\', '/') + '/adapters/antigravity/install-plugin.sh'
$uniPs = Join-Path $root 'adapters\install-global.ps1'
$uniShPosix = ($root -replace '\\', '/') + '/adapters/install-global.sh'
$gitBash = 'C:\Program Files\Git\bin\bash.exe'
if (-not (Test-Path -LiteralPath $gitBash -PathType Leaf)) {
    $bashCmd = Get-Command bash -ErrorAction SilentlyContinue
    if ($bashCmd -and ($bashCmd.Source -notmatch '[\\/]Windows[\\/]System32[\\/]bash\.exe$')) {
        $gitBash = $bashCmd.Source
    }
}
$hasBash = Test-Path -LiteralPath $gitBash -PathType Leaf
if (-not $hasBash) {
    Write-Output "WARNING: bash not found; cross-shell .sh checks skipped (INCOMPLETE)"
}
$failed = 0

function Pass([string]$Name) { Write-Output "PASS $Name" }
function FailCheck([string]$Name, [string]$Detail) {
    Write-Output "FAIL $Name :: $Detail"
    $script:failed++
}

function Invoke-PsScript([string]$ScriptPath, [string[]]$ScriptArgs) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @ScriptArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    $lines = @($raw | ForEach-Object { ([string]$_).TrimEnd("`r") })
    return @{ Code = $code; Lines = $lines; Text = ($lines -join "`n") }
}

function Invoke-ShScript([string]$ScriptPosix, [string]$ArgsLine) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & $gitBash -c "'$ScriptPosix' $ArgsLine" 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    $lines = @($raw | ForEach-Object { ([string]$_).TrimEnd("`r") })
    return @{ Code = $code; Lines = $lines; Text = ($lines -join "`n") }
}

function Copy-B3Snapshot([string]$DestDir) {
    New-Item -ItemType Directory -Path $DestDir | Out-Null
    foreach ($sub in @('skills', 'commands', 'agents', 'rules', 'workflows')) {
        Copy-Item -LiteralPath (Join-Path $root $sub) -Destination (Join-Path $DestDir $sub) -Recurse -Force
    }
    New-Item -ItemType Directory -Path (Join-Path $DestDir 'adapters\antigravity') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $DestDir 'adapters\cursor') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'adapters\command-skills') -Destination (Join-Path $DestDir 'adapters\command-skills') -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $root 'adapters\install-global.ps1') -Destination (Join-Path $DestDir 'adapters\install-global.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $root 'adapters\install-global.sh') -Destination (Join-Path $DestDir 'adapters\install-global.sh') -Force
    Copy-Item -LiteralPath (Join-Path $root 'adapters\antigravity\install-plugin.ps1') -Destination (Join-Path $DestDir 'adapters\antigravity\install-plugin.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $root 'adapters\antigravity\install-plugin.sh') -Destination (Join-Path $DestDir 'adapters\antigravity\install-plugin.sh') -Force
    Copy-Item -LiteralPath (Join-Path $root 'adapters\cursor\install-global.ps1') -Destination (Join-Path $DestDir 'adapters\cursor\install-global.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $root 'adapters\cursor\install-global.sh') -Destination (Join-Path $DestDir 'adapters\cursor\install-global.sh') -Force
}

function Remove-ReparseLinksUnder([string]$DirPath) {
    if (-not (Test-Path -LiteralPath $DirPath)) { return }
    $all = @(Get-ChildItem -LiteralPath $DirPath -Recurse -Force -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending)
    foreach ($item in $all) {
        if (($item.LinkType -in @('Junction', 'SymbolicLink')) -or (($item.Attributes.ToString()) -match 'ReparsePoint')) {
            if ($item.PSIsContainer) {
                & cmd.exe /c rmdir "`"$($item.FullName)`"" 2>&1 | Out-Null
            } else {
                Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

$expectedCoreSkills = @(Get-ChildItem -LiteralPath (Join-Path $root 'skills') -Recurse -Filter 'SKILL.md' -File).Count
$expectedCmdSkills = @(Get-ChildItem -LiteralPath (Join-Path $root 'adapters\command-skills') -Recurse -Filter 'SKILL.md' -File).Count
$expectedTotalSkills = $expectedCoreSkills + $expectedCmdSkills
$sandbox = Join-Path $env:TEMP ('b3-ag-global-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $sandbox | Out-Null

try {
    # --- 1. ag-global-dry-run ---
    $uh1 = Join-Path $sandbox 'u1'
    $pr1 = Join-Path $uh1 '.gemini\config\plugins\b3-ai-engineering'
    $drPs = Invoke-PsScript $agPs @('install', '-PluginRoot', $pr1, '-UserHome', $uh1, '-DryRun')
    $shDrOk = $true
    if ($hasBash) {
        $pr1p = $pr1 -replace '\\', '/'
        $uh1p = $uh1 -replace '\\', '/'
        $drSh = Invoke-ShScript $agShPosix "install --plugin-root '$pr1p' --user-home '$uh1p' --dry-run"
        $shDrOk = ($drSh.Code -eq 0) -and ($drSh.Text -match 'DRY_RUN_OK:')
    }
    if ($drPs.Code -eq 0 -and ($drPs.Text -match 'DRY_RUN_OK:') -and (-not (Test-Path -LiteralPath $pr1)) -and $shDrOk) {
        Pass 'ag-global-dry-run'
    } else {
        FailCheck 'ag-global-dry-run' "psCode=$($drPs.Code) exists=$(Test-Path -LiteralPath $pr1) shOk=$shDrOk"
    }

    # --- 2. ag-global-fresh-install & independent surface checks ---
    $uh2 = Join-Path $sandbox 'u2'
    $pr2 = Join-Path $uh2 '.gemini\config\plugins\b3-ai-engineering'
    $in2 = Invoke-PsScript $agPs @('-Action', 'install', '-PluginRoot', $pr2, '-UserHome', $uh2)
    $ver2Ps = Invoke-PsScript $agPs @('verify', '-PluginRoot', $pr2, '-UserHome', $uh2)
    $ver2ShOk = $true
    if ($hasBash) {
        $pr2p = $pr2 -replace '\\', '/'
        $uh2p = $uh2 -replace '\\', '/'
        $ver2Sh = Invoke-ShScript $agShPosix "verify --plugin-root '$pr2p' --user-home '$uh2p'"
        $ver2ShOk = ($ver2Sh.Code -eq 0) -and
                    ($ver2Sh.Text -match 'check\.plugin=OK') -and
                    ($ver2Sh.Text -match 'check\.rules=OK') -and
                    ($ver2Sh.Text -match 'check\.skills=OK') -and
                    ($ver2Sh.Text -match 'check\.commands=OK') -and
                    ($ver2Sh.Text -match 'check\.agents=OK')
    }
    $skillDirs2 = @(Get-ChildItem -LiteralPath (Join-Path $pr2 'skills') -Force -ErrorAction SilentlyContinue)
    $agFiles2 = @(Get-ChildItem -LiteralPath (Join-Path $pr2 'agents') -Filter 'b3-*.md' -File -ErrorAction SilentlyContinue)
    $pjObj2 = Get-Content -LiteralPath (Join-Path $pr2 'plugin.json') -Raw | ConvertFrom-Json
    $pjExtra2 = @($pjObj2.PSObject.Properties | ForEach-Object { $_.Name } | Where-Object { @('name', 'displayName', 'version', 'description', 'suggestedPrompts') -notcontains $_ })
    $pjOk2 = ($pjObj2.name -eq 'b3-ai-engineering') -and ($pjExtra2.Count -eq 0) -and (@($pjObj2.suggestedPrompts).Count -eq 3)
    $rulesPath2 = Join-Path $pr2 'rules\AGENTS.md'
    $rulesText2 = Get-Content -LiteralPath $rulesPath2 -Raw
    $rulesBytes2 = ([IO.File]::ReadAllBytes($rulesPath2)).Length
    $rulesOk2 = ($rulesBytes2 -lt 24000) -and (-not ($rulesText2.TrimStart() -match '^---')) -and ($rulesText2 -notmatch 'review-loop/spec\.md') -and
                ($rulesText2 -match 'Project-level AGENTS\.md') -and ($rulesText2 -match 'install-product is optional')
    $allAgentsOk2 = ($agFiles2.Count -eq 5)
    $noHardcodedModel = $true
    foreach ($af2 in $agFiles2) {
        $at2 = Get-Content -LiteralPath $af2.FullName -Raw
        if (($at2 -match '(?m)^model:') -or ($at2 -match 'claude-|gpt-|gemini-[0-9]') -or
            ($at2 -notmatch '(?m)^subagent:\s*true\s*$') -or ($at2 -notmatch '(?m)^mainAgent:\s*false\s*$') -or ($at2 -notmatch '(?m)^tools:\s*\[')) {
            $allAgentsOk2 = $false
            $noHardcodedModel = $false
        }
    }
    $hasAllCmds = $true
    foreach ($cmd in @('b3-plan', 'b3-implement', 'b3-debug', 'b3-review', 'b3-verify', 'b3-review-loop', 'b3-ship')) {
        if (-not (Test-Path -LiteralPath (Join-Path $pr2 "skills\$cmd\SKILL.md") -PathType Leaf)) { $hasAllCmds = $false }
    }
    if ($in2.Code -eq 0 -and $ver2Ps.Code -eq 0 -and $ver2ShOk -and
        ($ver2Ps.Text -match 'check\.plugin=OK') -and ($ver2Ps.Text -match 'check\.commands=OK') -and
        ($ver2Ps.Text -match 'UNKNOWN / INCOMPLETE') -and
        $pjOk2 -and $rulesOk2 -and $allAgentsOk2 -and
        $skillDirs2.Count -eq $expectedTotalSkills -and $hasAllCmds -and $noHardcodedModel) {
        Pass 'ag-global-fresh-install'
    } else {
        FailCheck 'ag-global-fresh-install' "in=$($in2.Code) ver=$($ver2Ps.Code) sh=$ver2ShOk pj=$pjOk2 rules=$rulesOk2 ags=$allAgentsOk2 skills=$($skillDirs2.Count)/$expectedTotalSkills cmds=$hasAllCmds model=$noHardcodedModel"
    }

    # --- 3. ag-global-idempotent (repeated PS & Bash install preserves unrelated user notes) ---
    $manifestBefore = ([IO.File]::ReadAllText((Join-Path $pr2 '.b3-plugin-manifest'), [System.Text.Encoding]::UTF8))
    Set-Content -LiteralPath (Join-Path $pr2 'user-note.txt') "keep me`n"
    Set-Content -LiteralPath (Join-Path $pr2 'agents\custom-agent.md') "# user custom agent`n"
    $in2Again = Invoke-PsScript $agPs @('install', '-PluginRoot', $pr2, '-UserHome', $uh2)
    $shIdemOk = $true
    if ($hasBash) {
        $in2Sh = Invoke-ShScript $agShPosix "install --plugin-root '$pr2p' --user-home '$uh2p'"
        $ver2PsPost = Invoke-PsScript $agPs @('verify', '-PluginRoot', $pr2, '-UserHome', $uh2)
        $shIdemOk = ($in2Sh.Code -eq 0) -and ($ver2PsPost.Code -eq 0)
    }
    $manifestAfter = ([IO.File]::ReadAllText((Join-Path $pr2 '.b3-plugin-manifest'), [System.Text.Encoding]::UTF8))
    $keptUser = (Test-Path -LiteralPath (Join-Path $pr2 'user-note.txt')) -and (Test-Path -LiteralPath (Join-Path $pr2 'agents\custom-agent.md'))
    if ($in2Again.Code -eq 0 -and $shIdemOk -and ($manifestBefore -eq $manifestAfter) -and $keptUser) {
        Pass 'ag-global-idempotent'
    } else {
        FailCheck 'ag-global-idempotent' "in=$($in2Again.Code) sh=$shIdemOk mEq=$($manifestBefore -eq $manifestAfter) kept=$keptUser"
    }

    # --- 4. ag-global-update-and-prune ---
    $b3Copy = Join-Path $sandbox 'b3-copy'
    Copy-B3Snapshot $b3Copy
    $uh4 = Join-Path $sandbox 'u4'
    $pr4 = Join-Path $uh4 '.gemini\config\plugins\b3-ai-engineering'
    $copyPs = Join-Path $b3Copy 'adapters\antigravity\install-plugin.ps1'
    $copyShPosix = ($b3Copy -replace '\\', '/') + '/adapters/antigravity/install-plugin.sh'
    $in4 = Invoke-PsScript $copyPs @('install', '-B3Home', $b3Copy, '-PluginRoot', $pr4, '-UserHome', $uh4)
    Set-Content -LiteralPath (Join-Path $pr4 'user-note.txt') "user note`n"
    Set-Content -LiteralPath (Join-Path $pr4 'agents\my-local-agent.md') "# user agent`n"

    # Add synthetic skill & agent, then update
    New-Item -ItemType Directory -Path (Join-Path $b3Copy 'skills\engineering\ag-extra') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $b3Copy 'skills\engineering\ag-extra\SKILL.md') "---`nname: ag-extra`ndescription: extra skill`n---`n# extra`n"
    Set-Content -LiteralPath (Join-Path $b3Copy 'agents\b3-temp-agent.md') "---`nname: b3-temp-agent`ndescription: temp agent`nreadonly: true`n---`n# temp`n"
    $up4a = Invoke-PsScript $copyPs @('update', '-B3Home', $b3Copy, '-PluginRoot', $pr4, '-UserHome', $uh4)
    $addedOk = (Test-Path -LiteralPath (Join-Path $pr4 'skills\ag-extra\SKILL.md')) -and (Test-Path -LiteralPath (Join-Path $pr4 'agents\b3-temp-agent.md'))

    # Remove synthetic skill & agent + real skill, verify prune
    Remove-Item -LiteralPath (Join-Path $b3Copy 'skills\engineering\ag-extra') -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $b3Copy 'agents\b3-temp-agent.md') -Force
    Remove-Item -LiteralPath (Join-Path $b3Copy 'skills\engineering\refactoring') -Recurse -Force
    $up4b = Invoke-PsScript $copyPs @('update', '-B3Home', $b3Copy, '-PluginRoot', $pr4, '-UserHome', $uh4)
    $ver4 = Invoke-PsScript $copyPs @('verify', '-B3Home', $b3Copy, '-PluginRoot', $pr4, '-UserHome', $uh4)
    $ver4ShOk = $true
    if ($hasBash) {
        $pr4p = $pr4 -replace '\\', '/'
        $uh4p = $uh4 -replace '\\', '/'
        $b3p = $b3Copy -replace '\\', '/'
        $ver4Sh = Invoke-ShScript $copyShPosix "verify --b3-home '$b3p' --plugin-root '$pr4p' --user-home '$uh4p'"
        $ver4ShOk = ($ver4Sh.Code -eq 0) -and ($ver4Sh.Text -match 'VERIFY_OK:')
    }
    $prunedOk = (-not (Test-Path -LiteralPath (Join-Path $pr4 'skills\ag-extra'))) -and
                (-not (Test-Path -LiteralPath (Join-Path $pr4 'skills\refactoring'))) -and
                (-not (Test-Path -LiteralPath (Join-Path $pr4 'agents\b3-temp-agent.md')))
    $userKept4 = (Test-Path -LiteralPath (Join-Path $pr4 'user-note.txt')) -and (Test-Path -LiteralPath (Join-Path $pr4 'agents\my-local-agent.md'))
    if ($in4.Code -eq 0 -and $up4a.Code -eq 0 -and $addedOk -and $up4b.Code -eq 0 -and $ver4.Code -eq 0 -and $ver4ShOk -and $prunedOk -and $userKept4) {
        Pass 'ag-global-update-and-prune'
    } else {
        FailCheck 'ag-global-update-and-prune' "in=$($in4.Code) add=$addedOk upB=$($up4b.Code) ver=$($ver4.Code) sh=$ver4ShOk prune=$prunedOk user=$userKept4"
    }

    # --- 5. ag-global-conflict-protection ---
    $uh5 = Join-Path $sandbox 'u5'
    $pr5File = Join-Path $uh5 'file-block'
    New-Item -ItemType Directory -Path $uh5 -Force | Out-Null
    Set-Content -LiteralPath $pr5File 'not a dir'
    $refFile = Invoke-PsScript $agPs @('install', '-PluginRoot', $pr5File, '-UserHome', $uh5)

    $pr5NonB3 = Join-Path $uh5 '.gemini\config\plugins\b3-ai-engineering'
    New-Item -ItemType Directory -Path $pr5NonB3 -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $pr5NonB3 'keep.txt') 'keep'
    $refUnrecUninst = Invoke-PsScript $agPs @('uninstall', '-PluginRoot', $pr5NonB3, '-UserHome', $uh5)

    $pr5DanglingTarget = Join-Path $uh5 'dangling-target'
    $pr5DanglingLink = Join-Path $uh5 'dangling-link'
    New-Item -ItemType Directory -Path $pr5DanglingTarget -Force | Out-Null
    & cmd.exe /c mklink /J "`"$pr5DanglingLink`"" "`"$pr5DanglingTarget`"" | Out-Null
    Remove-Item -LiteralPath $pr5DanglingTarget -Force
    $refDanglingUninst = Invoke-PsScript $agPs @('uninstall', '-PluginRoot', $pr5DanglingLink, '-UserHome', $uh5)

    $refNonB3 = Invoke-PsScript $agPs @('install', '-PluginRoot', $pr5NonB3, '-UserHome', $uh5)
    $refShOk = $true
    if ($hasBash) {
        $pr5p = $pr5NonB3 -replace '\\', '/'
        $uh5p = $uh5 -replace '\\', '/'
        $refSh = Invoke-ShScript $agShPosix "install --plugin-root '$pr5p' --user-home '$uh5p'"
        # Also verify single-line extra-key JSON does not masquerade as a valid B3 plugin in Bash
        $pr5Single = Join-Path $uh5 'single-line-extra'
        New-Item -ItemType Directory -Path $pr5Single -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $pr5Single 'plugin.json') '{"name":"b3-ai-engineering","skills":"./x"}'
        $pr5sp = $pr5Single -replace '\\', '/'
        $refSingleSh = Invoke-ShScript $agShPosix "install --plugin-root '$pr5sp' --user-home '$uh5p'"
        $refShOk = ($refSh.Code -eq 1) -and ($refSingleSh.Code -eq 1)
    }
    $forceNonB3 = Invoke-PsScript $agPs @('install', '-PluginRoot', $pr5NonB3, '-UserHome', $uh5, '-Force')
    # Inject non-link dir under skills/ and check refusal without -Force
    & cmd.exe /c rmdir "`"$(Join-Path $pr5NonB3 'skills\verification')`"" | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $pr5NonB3 'skills\verification') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $pr5NonB3 'skills\verification\SKILL.md') "---`nname: verification`ndescription: local`n---`n"
    $refNonLink = Invoke-PsScript $agPs @('install', '-PluginRoot', $pr5NonB3, '-UserHome', $uh5)
    $forceNonLink = Invoke-PsScript $agPs @('install', '-PluginRoot', $pr5NonB3, '-UserHome', $uh5, '-Force')
    $ver5 = Invoke-PsScript $agPs @('verify', '-PluginRoot', $pr5NonB3, '-UserHome', $uh5)
    if ($refFile.Code -eq 1 -and $refUnrecUninst.Code -eq 1 -and $refDanglingUninst.Code -eq 1 -and
        $refNonB3.Code -eq 1 -and $refShOk -and (Test-Path -LiteralPath (Join-Path $pr5NonB3 'keep.txt')) -and
        $forceNonB3.Code -eq 0 -and $refNonLink.Code -eq 1 -and $forceNonLink.Code -eq 0 -and $ver5.Code -eq 0) {
        Pass 'ag-global-conflict-protection'
    } else {
        FailCheck 'ag-global-conflict-protection' "file=$($refFile.Code) unrecUn=$($refUnrecUninst.Code) dangUn=$($refDanglingUninst.Code) nonB3=$($refNonB3.Code) sh=$refShOk f1=$($forceNonB3.Code) nl=$($refNonLink.Code) f2=$($forceNonLink.Code) v=$($ver5.Code)"
    }

    # --- 6. ag-global-stale-broken-and-drift (per-surface failure diagnostics + heal) ---
    $b3Drift = Join-Path $sandbox 'b3-drift'
    Copy-B3Snapshot $b3Drift
    $uh6 = Join-Path $sandbox 'u6'
    $pr6 = Join-Path $uh6 '.gemini\config\plugins\b3-ai-engineering'
    $drPsPath = Join-Path $b3Drift 'adapters\antigravity\install-plugin.ps1'
    $drShPosix = ($b3Drift -replace '\\', '/') + '/adapters/antigravity/install-plugin.sh'
    $in6 = Invoke-PsScript $drPsPath @('install', '-B3Home', $b3Drift, '-PluginRoot', $pr6, '-UserHome', $uh6)

    Add-Content -LiteralPath (Join-Path $pr6 'plugin.json') ' '
    $vPluginBad = Invoke-PsScript $drPsPath @('verify', '-B3Home', $b3Drift, '-PluginRoot', $pr6, '-UserHome', $uh6)
    $pluginFailReported = ($vPluginBad.Code -eq 1) -and ($vPluginBad.Text -match 'check\.plugin=FAIL') -and ($vPluginBad.Text -match 'check\.rules=OK')
    $healPlugin = Invoke-PsScript $drPsPath @('update', '-B3Home', $b3Drift, '-PluginRoot', $pr6, '-UserHome', $uh6)

    Add-Content -LiteralPath (Join-Path $pr6 'rules\AGENTS.md') "`n<!-- drifted -->"
    $vRulesBad = Invoke-PsScript $drPsPath @('verify', '-B3Home', $b3Drift, '-PluginRoot', $pr6, '-UserHome', $uh6)
    $rulesFailReported = ($vRulesBad.Code -eq 1) -and ($vRulesBad.Text -match 'check\.rules=FAIL') -and ($vRulesBad.Text -match 'check\.skills=OK')

    $healRules = Invoke-PsScript $drPsPath @('update', '-B3Home', $b3Drift, '-PluginRoot', $pr6, '-UserHome', $uh6)
    Add-Content -LiteralPath (Join-Path $pr6 'agents\b3-reviewer.md') "`n<!-- drifted -->"
    Set-Content -LiteralPath (Join-Path $pr6 'agents\b3-stale-generated.md') "---`nname: b3-stale`n---`n<!-- Generated from stale/agents/b3-stale-generated.md -->`n"
    $vStaleAg = Invoke-PsScript $drPsPath @('verify', '-B3Home', $b3Drift, '-PluginRoot', $pr6, '-UserHome', $uh6)
    $staleAgCaught = ($vStaleAg.Code -eq 1) -and ($vStaleAg.Text -match 'stale generated agent file')
    Remove-Item -LiteralPath (Join-Path $b3Drift 'skills\engineering\debugging') -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $b3Drift 'adapters\command-skills\b3-plan') -Recurse -Force
    $vMultiBad = Invoke-PsScript $drPsPath @('verify', '-B3Home', $b3Drift, '-PluginRoot', $pr6, '-UserHome', $uh6)
    $shBadOk = $true
    if ($hasBash) {
        $pr6p = $pr6 -replace '\\', '/'
        $uh6p = $uh6 -replace '\\', '/'
        $b3dp = $b3Drift -replace '\\', '/'
        $vMultiSh = Invoke-ShScript $drShPosix "verify --b3-home '$b3dp' --plugin-root '$pr6p' --user-home '$uh6p'"
        $shBadOk = ($vMultiSh.Code -eq 1) -and ($vMultiSh.Text -match 'check\.skills=FAIL') -and ($vMultiSh.Text -match 'check\.commands=FAIL') -and ($vMultiSh.Text -match 'check\.agents=FAIL')
    }
    $multiFailReported = ($vMultiBad.Code -eq 1) -and ($vMultiBad.Text -match 'check\.skills=FAIL') -and ($vMultiBad.Text -match 'check\.commands=FAIL') -and ($vMultiBad.Text -match 'check\.agents=FAIL') -and ($vMultiBad.Text -match 'check\.rules=OK')

    Copy-Item -LiteralPath (Join-Path $root 'skills\engineering\debugging') -Destination (Join-Path $b3Drift 'skills\engineering\debugging') -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $root 'adapters\command-skills\b3-plan') -Destination (Join-Path $b3Drift 'adapters\command-skills\b3-plan') -Recurse -Force
    $healAll = Invoke-PsScript $drPsPath @('update', '-B3Home', $b3Drift, '-PluginRoot', $pr6, '-UserHome', $uh6)
    $verHealed = Invoke-PsScript $drPsPath @('verify', '-B3Home', $b3Drift, '-PluginRoot', $pr6, '-UserHome', $uh6)
    if ($in6.Code -eq 0 -and $pluginFailReported -and $healPlugin.Code -eq 0 -and $rulesFailReported -and $healRules.Code -eq 0 -and $staleAgCaught -and $multiFailReported -and $shBadOk -and $healAll.Code -eq 0 -and $verHealed.Code -eq 0) {
        Pass 'ag-global-stale-broken-and-drift'
    } else {
        FailCheck 'ag-global-stale-broken-and-drift' "pj=$pluginFailReported rules=$rulesFailReported staleAg=$staleAgCaught multi=$multiFailReported sh=$shBadOk healed=$($verHealed.Code)"
    }

    # --- 7. ag-global-paths-with-spaces ---
    $b3Sp = Join-Path $sandbox 'B3 Space Home'
    Copy-B3Snapshot $b3Sp
    $uhSp = Join-Path $sandbox 'User Space Home'
    $prSp = Join-Path $uhSp '.gemini\config\plugins\B3 Plugin Space'
    $spPs = Join-Path $b3Sp 'adapters\antigravity\install-plugin.ps1'
    $spShPosix = ($b3Sp -replace '\\', '/') + '/adapters/antigravity/install-plugin.sh'
    $prSpP = $prSp -replace '\\', '/'
    $uhSpP = $uhSp -replace '\\', '/'
    $b3SpP = $b3Sp -replace '\\', '/'
    $spIn = Invoke-PsScript $spPs @('install', '-B3Home', $b3Sp, '-PluginRoot', $prSp, '-UserHome', $uhSp)
    $spShOk = $true
    if ($hasBash) {
        $spShV = Invoke-ShScript $spShPosix "verify --b3-home '$b3SpP' --plugin-root '$prSpP' --user-home '$uhSpP'"
        $spShU = Invoke-ShScript $spShPosix "uninstall --plugin-root '$prSpP' --user-home '$uhSpP'"
        $spShI = Invoke-ShScript $spShPosix "install --b3-home '$b3SpP' --plugin-root '$prSpP' --user-home '$uhSpP'"
        $spShOk = ($spShV.Code -eq 0) -and ($spShU.Code -eq 0) -and ($spShI.Code -eq 0)
    }
    $spPsV = Invoke-PsScript $spPs @('verify', '-B3Home', $b3Sp, '-PluginRoot', $prSp, '-UserHome', $uhSp)
    $spPsU = Invoke-PsScript $spPs @('uninstall', '-PluginRoot', $prSp, '-UserHome', $uhSp)
    if ($spIn.Code -eq 0 -and $spShOk -and $spPsV.Code -eq 0 -and $spPsU.Code -eq 0 -and (-not (Test-Path -LiteralPath $prSp))) {
        Pass 'ag-global-paths-with-spaces'
    } else {
        FailCheck 'ag-global-paths-with-spaces' "in=$($spIn.Code) sh=$spShOk v=$($spPsV.Code) u=$($spPsU.Code)"
    }

    # --- 8. ag-global-unrelated-projects-untouched ---
    $repoA = Join-Path $sandbox 'ag-proj-alpha'
    $repoB = Join-Path $sandbox 'ag-proj-beta'
    foreach ($pr in @($repoA, $repoB)) {
        New-Item -ItemType Directory -Path (Join-Path $pr '.agents\rules') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $pr 'AGENTS.md') "# Local Project $(Split-Path -Leaf $pr)`n"
        Set-Content -LiteralPath (Join-Path $pr '.agents\rules\local.md') "# Local rule`n"
        Push-Location $pr
        & git init -q; & git config user.email 't@e.com'; & git config user.name 'T'
        & git add .; & git commit -qm 'init'
        Pop-Location
    }
    $shaA0 = (& git -C $repoA rev-parse HEAD).Trim()
    $shaB0 = (& git -C $repoB rev-parse HEAD).Trim()
    $uh8 = Join-Path $sandbox 'u8'
    $pr8 = Join-Path $uh8 '.gemini\config\plugins\b3-ai-engineering'
    $in8 = Invoke-PsScript $agPs @('install', '-PluginRoot', $pr8, '-UserHome', $uh8)
    $ver8 = Invoke-PsScript $agPs @('verify', '-PluginRoot', $pr8, '-UserHome', $uh8)
    $stA = ((& git -C $repoA status --short) -join '')
    $stB = ((& git -C $repoB status --short) -join '')
    $shaA1 = (& git -C $repoA rev-parse HEAD).Trim()
    $shaB1 = (& git -C $repoB rev-parse HEAD).Trim()
    if ($in8.Code -eq 0 -and $ver8.Code -eq 0 -and (-not $stA) -and (-not $stB) -and ($shaA0 -eq $shaA1) -and ($shaB0 -eq $shaB1)) {
        Pass 'ag-global-unrelated-projects-untouched'
    } else {
        FailCheck 'ag-global-unrelated-projects-untouched' "in=$($in8.Code) ver=$($ver8.Code) stA='$stA' stB='$stB'"
    }

    # --- 9. ag-global-install-product-compat ---
    $prodC = Join-Path $sandbox 'ag-proj-gamma'
    New-Item -ItemType Directory -Path $prodC | Out-Null
    Push-Location $prodC
    & git init -q; & git config user.email 't@e.com'; & git config user.name 'T'
    Set-Content 'README.md' "# Gamma`n"
    & git add .; & git commit -qm 'init'
    Pop-Location
    $instProd = Join-Path $root 'adapters\install-product.ps1'
    & powershell -NoProfile -ExecutionPolicy Bypass -File $instProd -ProductRoot $prodC -B3Home $root -HostName antigravity | Out-Null
    $ipExit = $LASTEXITCODE
    $ipOk = ($ipExit -eq 0) -and (Test-Path -LiteralPath (Join-Path $prodC '.b3\home')) -and (Test-Path -LiteralPath (Join-Path $prodC '.agents\skills\b3-ship\SKILL.md'))
    $ver8AfterProd = Invoke-PsScript $agPs @('verify', '-PluginRoot', $pr8, '-UserHome', $uh8)
    if ($ipOk -and $ver8AfterProd.Code -eq 0) {
        Pass 'ag-global-install-product-compat'
    } else {
        FailCheck 'ag-global-install-product-compat' "ip=$ipExit ver=$($ver8AfterProd.Code)"
    }

    # --- 10. ag-global-coexistence-and-uninstall (preserves config.json & user notes + legacy pre-manifest cleanup) ---
    New-Item -ItemType Directory -Path (Join-Path $uh8 '.gemini\config\skills\verification') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $uh8 '.gemini\config\skills\verification\SKILL.md') "---`nname: verification`ndescription: loose`n---`n"
    New-Item -ItemType Directory -Path (Join-Path $uh8 '.gemini\config\plugins\b3-dup') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $uh8 '.gemini\config\plugins\b3-dup\plugin.json') '{"name":"b3-ai-engineering","extra":true}'
    New-Item -ItemType Directory -Path (Join-Path $uh8 '.agents\skills\verification') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $uh8 '.agents\skills\verification\SKILL.md') "---`nname: verification`ndescription: ag`n---`n"
    $cfgPath = Join-Path $uh8 '.gemini\config\config.json'
    Set-Content -LiteralPath $cfgPath '{"plugins":{"b3-ai-engineering":{"enabled":true}}}'
    $cfgSha0 = (Get-FileHash -LiteralPath $cfgPath -Algorithm SHA256).Hash
    Set-Content -LiteralPath (Join-Path $pr8 'user-only.txt') "keep me`n"

    $coexVer = Invoke-PsScript $agPs @('verify', '-PluginRoot', $pr8, '-UserHome', $uh8)
    $warnMatches = ([regex]::Matches($coexVer.Text, 'COEXISTENCE_WARNING:')).Count
    $unDr = Invoke-PsScript $agPs @('uninstall', '-PluginRoot', $pr8, '-UserHome', $uh8, '-DryRun')
    $stillThereAfterDr = Test-Path -LiteralPath (Join-Path $pr8 'plugin.json')
    $un8 = Invoke-PsScript $agPs @('uninstall', '-PluginRoot', $pr8, '-UserHome', $uh8)
    $cfgSha1 = (Get-FileHash -LiteralPath $cfgPath -Algorithm SHA256).Hash
    $userKept10 = Test-Path -LiteralPath (Join-Path $pr8 'user-only.txt')
    $managedGone10 = (-not (Test-Path -LiteralPath (Join-Path $pr8 'plugin.json'))) -and
                     (-not (Test-Path -LiteralPath (Join-Path $pr8 'rules\AGENTS.md'))) -and
                     (-not (Test-Path -LiteralPath (Join-Path $pr8 'skills\verification'))) -and
                     (-not (Test-Path -LiteralPath (Join-Path $pr8 'agents\b3-reviewer.md'))) -and
                     (-not (Test-Path -LiteralPath (Join-Path $pr8 '.b3-plugin-manifest')))

    # Legacy pre-manifest uninstall fallback test
    $uhLegacy = Join-Path $sandbox 'u-legacy'
    $prLegacy = Join-Path $uhLegacy '.gemini\config\plugins\b3-ai-engineering'
    $legIn = Invoke-PsScript $agPs @('install', '-PluginRoot', $prLegacy, '-UserHome', $uhLegacy)
    Remove-Item -LiteralPath (Join-Path $prLegacy '.b3-plugin-manifest') -Force
    Set-Content -LiteralPath (Join-Path $prLegacy 'keep-legacy.txt') 'keep'
    $legUn = Invoke-PsScript $agPs @('uninstall', '-PluginRoot', $prLegacy, '-UserHome', $uhLegacy)
    $legCleaned = (Test-Path -LiteralPath (Join-Path $prLegacy 'keep-legacy.txt')) -and
                  (-not (Test-Path -LiteralPath (Join-Path $prLegacy 'plugin.json'))) -and
                  (-not (Test-Path -LiteralPath (Join-Path $prLegacy 'rules\AGENTS.md'))) -and
                  (-not (Test-Path -LiteralPath (Join-Path $prLegacy 'skills\verification')))
    if ($coexVer.Code -eq 0 -and $warnMatches -eq 3 -and $unDr.Code -eq 0 -and $stillThereAfterDr -and
        $un8.Code -eq 0 -and ($cfgSha0 -eq $cfgSha1) -and $userKept10 -and $managedGone10 -and
        $legIn.Code -eq 0 -and $legUn.Code -eq 0 -and $legCleaned) {
        Pass 'ag-global-coexistence-and-uninstall'
    } else {
        FailCheck 'ag-global-coexistence-and-uninstall' "warns=$warnMatches dr=$($unDr.Code)/$stillThereAfterDr un=$($un8.Code) cfg=$($cfgSha0 -eq $cfgSha1) user=$userKept10 gone=$managedGone10 leg=$($legUn.Code)/$legCleaned"
    }

    # --- 11. unified-install-global-dispatcher (cursor, antigravity, all, trailing slashes, failure propagation) ---
    $uhUniC = Join-Path $sandbox 'u-uni-cursor'
    $uC1 = Invoke-PsScript $uniPs @('-HostName', 'cursor', '-UserHome', $uhUniC)
    $uCOnly = (Test-Path -LiteralPath (Join-Path $uhUniC '.cursor\skills\verification\SKILL.md')) -and (-not (Test-Path -LiteralPath (Join-Path $uhUniC '.gemini\config\plugins\b3-ai-engineering'))) -and
              (Test-Path -LiteralPath (Join-Path $uhUniC '.b3\models.md') -PathType Leaf)

    $uhUniA = Join-Path $sandbox 'u-uni-ag'
    $uA1 = Invoke-PsScript $uniPs @('-HostName', 'antigravity', '-UserHome', $uhUniA)
    $uAOnly = (Test-Path -LiteralPath (Join-Path $uhUniA '.gemini\config\plugins\b3-ai-engineering\plugin.json')) -and (-not (Test-Path -LiteralPath (Join-Path $uhUniA '.cursor'))) -and
              (Test-Path -LiteralPath (Join-Path $uhUniA '.b3\models.md') -PathType Leaf)

    # Trailing-backslash path with spaces (R001 regression test via direct PowerShell invocation, as in PS tab completion)
    $uhSpSlash = (Join-Path $sandbox 'User Trail Space') + '\'
    $prSpSlash = (Join-Path $uhSpSlash '.gemini\config\plugins\Ag Trail Space') + '\'
    $chSpSlash = (Join-Path $uhSpSlash '.cursor') + '\'
    $prevTrailPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $uniPs -HostName all -UserHome $uhSpSlash -CursorHome $chSpSlash -AntigravityPluginRoot $prSpSlash | Out-Null
        $spTrailInCode = $LASTEXITCODE
        & $uniPs verify -HostName all -UserHome $uhSpSlash -CursorHome $chSpSlash -AntigravityPluginRoot $prSpSlash | Out-Null
        $spTrailVerCode = $LASTEXITCODE
        & $uniPs uninstall -HostName all -UserHome $uhSpSlash -CursorHome $chSpSlash -AntigravityPluginRoot $prSpSlash | Out-Null
        $spTrailUnCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevTrailPref
    }
    $trailOk = ($spTrailInCode -eq 0) -and ($spTrailVerCode -eq 0) -and ($spTrailUnCode -eq 0)

    # Mixed-host failure propagation test: Cursor fails (conflict), Antigravity still runs & succeeds, overall exits 1 with GLOBAL_FAIL
    $uhMix = Join-Path $sandbox 'u-uni-mix'
    New-Item -ItemType Directory -Path (Join-Path $uhMix '.cursor\commands') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $uhMix '.cursor\commands\b3-ship.md') 'unmanaged custom'
    $mixRes = Invoke-PsScript $uniPs @('-HostName', 'all', '-UserHome', $uhMix)
    $mixOk = ($mixRes.Code -eq 1) -and ($mixRes.Text -match 'host=cursor status=FAIL') -and
             ($mixRes.Text -match 'host=antigravity status=OK') -and ($mixRes.Text -match 'GLOBAL_FAIL:') -and
             (-not (Test-Path -LiteralPath (Join-Path $uhMix '.b3\models.md')))

    $uhAll = Join-Path $sandbox 'u-uni-all'
    $allDr = Invoke-PsScript $uniPs @('-HostName', 'all', '-UserHome', $uhAll, '-DryRun')
    $allPref = Join-Path $uhAll '.b3\models.md'
    $allDrClean = (-not (Test-Path -LiteralPath (Join-Path $uhAll '.cursor'))) -and (-not (Test-Path -LiteralPath (Join-Path $uhAll '.gemini'))) -and (-not (Test-Path -LiteralPath $allPref))
    $allIn = Invoke-PsScript $uniPs @('-HostName', 'all', '-UserHome', $uhAll)
    $allPrefSeeded = (Test-Path -LiteralPath $allPref -PathType Leaf) -and ((Get-Content -LiteralPath $allPref -Raw) -match 'B3 Model Preferences')
    if ($allPrefSeeded) { Set-Content -LiteralPath $allPref '# personal preference - keep after update and uninstall' }
    $allUp = Invoke-PsScript $uniPs @('update', '-HostName', 'all', '-UserHome', $uhAll)
    $allVer = Invoke-PsScript $uniPs @('verify', '-HostName', 'all', '-UserHome', $uhAll)
    $allPrefPreserved = (Test-Path -LiteralPath $allPref -PathType Leaf) -and ((Get-Content -LiteralPath $allPref -Raw) -match 'personal preference - keep')
    $noCoexConflict = -not ($allVer.Text -match 'COEXISTENCE_WARNING:')

    $shAllOk = $true
    if ($hasBash) {
        $uhAllP = $uhAll -replace '\\', '/'
        $uhAllSh = Join-Path $sandbox 'u-uni-sh'
        $uhAllShP = $uhAllSh -replace '\\', '/'
        $shAllIn = Invoke-ShScript $uniShPosix "install --host all --user-home '$uhAllShP'"
        $shModelPref = Join-Path $uhAllSh '.b3\models.md'
        $shModelSeeded = Test-Path -LiteralPath $shModelPref -PathType Leaf
        if ($shModelSeeded) { Set-Content -LiteralPath $shModelPref '# shell custom preference - keep' }
        $shAllVer = Invoke-ShScript $uniShPosix "verify --host all --user-home '$uhAllP'"
        $shAllUp = Invoke-ShScript $uniShPosix "update --host all --user-home '$uhAllP'"
        $shAllUn = Invoke-ShScript $uniShPosix "uninstall --host all --user-home '$uhAllP'"
        $shAllShUn = Invoke-ShScript $uniShPosix "uninstall --host all --user-home '$uhAllShP'"
        $shAllOk = ($shAllIn.Code -eq 0) -and ($shAllIn.Text -match 'GLOBAL_OK:') -and
                   ($shAllVer.Code -eq 0) -and ($shAllVer.Text -match 'GLOBAL_OK:') -and
                   ($shAllUp.Code -eq 0) -and ($shAllUp.Text -match 'GLOBAL_OK:') -and
                   ($shAllUn.Code -eq 0) -and ($shAllUn.Text -match 'GLOBAL_OK:') -and
                   ($shAllShUn.Code -eq 0) -and $shModelSeeded -and
                   (Test-Path -LiteralPath $shModelPref -PathType Leaf) -and
                   ((Get-Content -LiteralPath $shModelPref -Raw) -match 'shell custom preference - keep')
    } else {
        $psAllUn = Invoke-PsScript $uniPs @('uninstall', '-HostName', 'all', '-UserHome', $uhAll)
        $shAllOk = ($psAllUn.Code -eq 0)
    }
    $allGone = (-not (Test-Path -LiteralPath (Join-Path $uhAll '.cursor\skills\verification'))) -and
               (-not (Test-Path -LiteralPath (Join-Path $uhAll '.gemini\config\plugins\b3-ai-engineering'))) -and
               (Test-Path -LiteralPath $allPref -PathType Leaf)
    if ($uC1.Code -eq 0 -and $uCOnly -and $uA1.Code -eq 0 -and $uAOnly -and $trailOk -and $mixOk -and
        $allDr.Code -eq 0 -and $allDrClean -and $allPrefSeeded -and $allPrefPreserved -and $allIn.Code -eq 0 -and $allUp.Code -eq 0 -and $allVer.Code -eq 0 -and
        ($allVer.Text -match 'GLOBAL_OK:') -and $noCoexConflict -and $shAllOk -and $allGone) {
        Pass 'unified-install-global-dispatcher'
    } else {
        FailCheck 'unified-install-global-dispatcher' "c=$($uC1.Code)/$uCOnly a=$($uA1.Code)/$uAOnly trail=$trailOk mix=$mixOk dr=$allDrClean all=$($allIn.Code)/$($allUp.Code)/$($allVer.Code) noWarn=$noCoexConflict sh=$shAllOk gone=$allGone"
    }

    # --- 12. ag-global-symlink-boundaries (F1, F2) ---
    $uh12 = Join-Path $sandbox 'u12'
    $liveTarget = Join-Path $uh12 'live-target'
    $liveLink = Join-Path $uh12 'live-plugin-link'
    New-Item -ItemType Directory -Path $liveTarget -Force | Out-Null
    & cmd.exe /c mklink /J "`"$liveLink`"" "`"$liveTarget`"" | Out-Null
    $psLiveIn = Invoke-PsScript $agPs @('install', '-PluginRoot', $liveLink, '-UserHome', $uh12, '-Force')
    $psLiveVer = Invoke-PsScript $agPs @('verify', '-PluginRoot', $liveLink, '-UserHome', $uh12)
    $psLiveUn = Invoke-PsScript $agPs @('uninstall', '-PluginRoot', $liveLink, '-UserHome', $uh12)
    $shLiveOk = $true
    if ($hasBash) {
        $liveLinkP = $liveLink -replace '\\', '/'
        $uh12p = $uh12 -replace '\\', '/'
        $shLiveIn = Invoke-ShScript $agShPosix "install --plugin-root '$liveLinkP' --user-home '$uh12p' --force"
        $shLiveVer = Invoke-ShScript $agShPosix "verify --plugin-root '$liveLinkP' --user-home '$uh12p'"
        $shLiveUn = Invoke-ShScript $agShPosix "uninstall --plugin-root '$liveLinkP' --user-home '$uh12p'"
        $shLiveOk = ($shLiveIn.Code -eq 1) -and ($shLiveVer.Code -eq 1) -and ($shLiveUn.Code -eq 1)
    }
    $liveTargetUntouched = (Test-Path -LiteralPath $liveTarget) -and (@(Get-ChildItem -LiteralPath $liveTarget -Force).Count -eq 0)

    $subAllOk = $true
    foreach ($subName in @('agents', 'rules', 'skills')) {
        $prSub = Join-Path $uh12 "pr-sub-$subName"
        $extSub = Join-Path $uh12 "ext-$subName"
        New-Item -ItemType Directory -Path $prSub, $extSub | Out-Null
        & cmd.exe /c mklink /J "`"$(Join-Path $prSub $subName)`"" "`"$extSub`"" | Out-Null
        $psSub = Invoke-PsScript $agPs @('install', '-PluginRoot', $prSub, '-UserHome', $uh12, '-Force')
        $shSubOk = $true
        if ($hasBash) {
            $prSubP = $prSub -replace '\\', '/'
            $shSub = Invoke-ShScript $agShPosix "install --plugin-root '$prSubP' --user-home '$uh12p' --force"
            $shSubOk = ($shSub.Code -eq 1)
        }
        $extEmpty = (@(Get-ChildItem -LiteralPath $extSub -Force).Count -eq 0)
        if ($psSub.Code -ne 1 -or -not $shSubOk -or -not $extEmpty) {
            $subAllOk = $false
        }
    }
    if ($psLiveIn.Code -eq 1 -and $psLiveVer.Code -eq 1 -and $psLiveUn.Code -eq 1 -and $shLiveOk -and $liveTargetUntouched -and $subAllOk) {
        Pass 'ag-global-symlink-boundaries'
    } else {
        FailCheck 'ag-global-symlink-boundaries' "ps=$($psLiveIn.Code)/$($psLiveVer.Code)/$($psLiveUn.Code) sh=$shLiveOk untouched=$liveTargetUntouched sub=$subAllOk"
    }

    # --- 13. ag-global-force-preserves-non-b3-skills (F3) ---
    $uh13 = Join-Path $sandbox 'u13'
    $pr13 = Join-Path $uh13 '.gemini\config\plugins\b3-ai-engineering'
    New-Item -ItemType Directory -Path (Join-Path $pr13 'skills\verification'), (Join-Path $pr13 'skills\my-custom-skill'), (Join-Path $pr13 'skills\debugging') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $pr13 'skills\verification\SKILL.md') "---`nname: verification`ndescription: local`n---`n"
    Set-Content -LiteralPath (Join-Path $pr13 'skills\my-custom-skill\SKILL.md') "---`nname: my-custom-skill`ndescription: user`n---`n"
    Set-Content -LiteralPath (Join-Path $pr13 'skills\user-note.txt') "keep me`n"
    Set-Content -LiteralPath (Join-Path $pr13 'skills\debugging\not-a-skill.txt') "not a skill`n"
    $refNonSkill = Invoke-PsScript $agPs @('install', '-PluginRoot', $pr13, '-UserHome', $uh13, '-Force')
    $shNonSkillOk = $true
    if ($hasBash) {
        $pr13p = $pr13 -replace '\\', '/'
        $uh13p = $uh13 -replace '\\', '/'
        $shNonSkill = Invoke-ShScript $agShPosix "install --plugin-root '$pr13p' --user-home '$uh13p' --force"
        $shNonSkillOk = ($shNonSkill.Code -eq 1)
    }
    Remove-Item -LiteralPath (Join-Path $pr13 'skills\debugging') -Recurse -Force
    $force13Ps = Invoke-PsScript $agPs @('install', '-PluginRoot', $pr13, '-UserHome', $uh13, '-Force')
    $kept13Ps = (Test-Path -LiteralPath (Join-Path $pr13 'skills\my-custom-skill\SKILL.md')) -and
                (Test-Path -LiteralPath (Join-Path $pr13 'skills\user-note.txt')) -and
                (Test-Path -LiteralPath (Join-Path $pr13 'skills\verification\SKILL.md'))

    $sh13Ok = $true
    if ($hasBash) {
        & cmd.exe /c rmdir "`"$(Join-Path $pr13 'skills\verification')`"" | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $pr13 'skills\verification') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $pr13 'skills\verification\SKILL.md') "---`nname: verification`ndescription: local2`n---`n"
        $force13Sh = Invoke-ShScript $agShPosix "install --plugin-root '$pr13p' --user-home '$uh13p' --force"
        $ver13Sh = Invoke-ShScript $agShPosix "verify --plugin-root '$pr13p' --user-home '$uh13p'"
        $kept13Sh = (Test-Path -LiteralPath (Join-Path $pr13 'skills\my-custom-skill\SKILL.md')) -and
                    (Test-Path -LiteralPath (Join-Path $pr13 'skills\user-note.txt'))
        $sh13Ok = ($force13Sh.Code -eq 0) -and ($ver13Sh.Code -eq 0) -and $kept13Sh
    }
    if ($refNonSkill.Code -eq 1 -and $shNonSkillOk -and $force13Ps.Code -eq 0 -and $kept13Ps -and $sh13Ok) {
        Pass 'ag-global-force-preserves-non-b3-skills'
    } else {
        FailCheck 'ag-global-force-preserves-non-b3-skills' "refNS=$($refNonSkill.Code)/$shNonSkillOk f=$($force13Ps.Code) kept=$kept13Ps sh=$sh13Ok"
    }

    # --- 14. ag-global-uninstall-protects-modified (F4) ---
    $uh14 = Join-Path $sandbox 'u14'
    $pr14 = Join-Path $uh14 '.gemini\config\plugins\b3-ai-engineering'
    $dbgTgt14 = Join-Path $uh14 'custom-dbg-ps'
    New-Item -ItemType Directory -Path $dbgTgt14 -Force | Out-Null
    $in14 = Invoke-PsScript $agPs @('install', '-PluginRoot', $pr14, '-UserHome', $uh14)
    Add-Content -LiteralPath (Join-Path $pr14 'agents\b3-reviewer.md') "`n<!-- user edit -->"
    & cmd.exe /c rmdir "`"$(Join-Path $pr14 'skills\debugging')`"" | Out-Null
    & cmd.exe /c mklink /J "`"$(Join-Path $pr14 'skills\debugging')`"" "`"$dbgTgt14`"" | Out-Null
    $unConf14 = Invoke-PsScript $agPs @('uninstall', '-PluginRoot', $pr14, '-UserHome', $uh14)
    $kept14 = ((Get-Content -LiteralPath (Join-Path $pr14 'agents\b3-reviewer.md') -Raw) -match 'user edit') -and
              (Test-Path -LiteralPath (Join-Path $pr14 'skills\debugging')) -and
              (Test-Path -LiteralPath (Join-Path $pr14 '.b3-plugin-manifest'))
    $unForce14 = Invoke-PsScript $agPs @('uninstall', '-PluginRoot', $pr14, '-UserHome', $uh14, '-Force')
    $clean14 = (-not (Test-Path -LiteralPath $pr14)) -and (Test-Path -LiteralPath $dbgTgt14)

    $sh14Ok = $true
    if ($hasBash) {
        $uh14s = Join-Path $sandbox 'u14sh'
        $pr14s = Join-Path $uh14s '.gemini\config\plugins\b3-ai-engineering'
        $dbgTgt14s = Join-Path $uh14s 'custom-dbg-sh'
        New-Item -ItemType Directory -Path $dbgTgt14s -Force | Out-Null
        $pr14sp = $pr14s -replace '\\', '/'
        $uh14sp = $uh14s -replace '\\', '/'
        $shIn14 = Invoke-ShScript $agShPosix "install --plugin-root '$pr14sp' --user-home '$uh14sp'"
        Add-Content -LiteralPath (Join-Path $pr14s 'agents\b3-reviewer.md') "`n<!-- user edit -->"
        & cmd.exe /c rmdir "`"$(Join-Path $pr14s 'skills\debugging')`"" | Out-Null
        & cmd.exe /c mklink /J "`"$(Join-Path $pr14s 'skills\debugging')`"" "`"$dbgTgt14s`"" | Out-Null
        $shConf14 = Invoke-ShScript $agShPosix "uninstall --plugin-root '$pr14sp' --user-home '$uh14sp'"
        $shKept14 = ((Get-Content -LiteralPath (Join-Path $pr14s 'agents\b3-reviewer.md') -Raw) -match 'user edit') -and
                    (Test-Path -LiteralPath (Join-Path $pr14s 'skills\debugging')) -and
                    (Test-Path -LiteralPath (Join-Path $pr14s '.b3-plugin-manifest'))
        $shForce14 = Invoke-ShScript $agShPosix "uninstall --plugin-root '$pr14sp' --user-home '$uh14sp' --force"
        $shClean14 = (-not (Test-Path -LiteralPath $pr14s)) -and (Test-Path -LiteralPath $dbgTgt14s)
        $sh14Ok = ($shIn14.Code -eq 0) -and ($shConf14.Code -eq 1) -and ($shConf14.Text -match 'UNINSTALL_CONFLICT:') -and
                  $shKept14 -and ($shForce14.Code -eq 0) -and $shClean14
    }
    if ($in14.Code -eq 0 -and $unConf14.Code -eq 1 -and ($unConf14.Text -match 'UNINSTALL_CONFLICT:') -and
        $kept14 -and $unForce14.Code -eq 0 -and $clean14 -and $sh14Ok) {
        Pass 'ag-global-uninstall-protects-modified'
    } else {
        FailCheck 'ag-global-uninstall-protects-modified' "in=$($in14.Code) conf=$($unConf14.Code) kept=$kept14 force=$($unForce14.Code) clean=$clean14 sh=$sh14Ok"
    }

    # --- 15. P1: user-owned links/agents are not adopted or pruned ---
    $uh15 = Join-Path $sandbox 'u15'
    $pr15 = Join-Path $uh15 '.gemini\config\plugins\b3-ai-engineering'
    $ext15 = Join-Path $uh15 'external-user-skill'
    New-Item -ItemType Directory -Path $ext15 -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $ext15 'SKILL.md') -Value @('---','name: user-custom','description: user','---')
    $in15 = Invoke-PsScript $agPs @('install', '-PluginRoot', $pr15, '-UserHome', $uh15)
    $customLink15 = Join-Path $pr15 'skills\user-custom'
    New-Item -ItemType Junction -Path $customLink15 -Target $ext15 | Out-Null
    $customAgent15 = Join-Path $pr15 'agents\user-generated.md'
    Set-Content -LiteralPath $customAgent15 -Value '<!-- Generated from /other/agents/user-generated.md -->'
    $up15Ps = Invoke-PsScript $agPs @('update', '-PluginRoot', $pr15, '-UserHome', $uh15)
    $ver15Ps = Invoke-PsScript $agPs @('verify', '-PluginRoot', $pr15, '-UserHome', $uh15)
    $up15ShOk = $true
    if ($hasBash) {
        $pr15p = $pr15 -replace '\\', '/'
        $uh15p = $uh15 -replace '\\', '/'
        $up15Sh = Invoke-ShScript $agShPosix "update --plugin-root '$pr15p' --user-home '$uh15p'"
        $ver15Sh = Invoke-ShScript $agShPosix "verify --plugin-root '$pr15p' --user-home '$uh15p'"
        $up15ShOk = ($up15Sh.Code -eq 0) -and ($ver15Sh.Code -eq 0)
    }
    $preserved15 = (Test-Path -LiteralPath (Join-Path $customLink15 'SKILL.md')) -and (Test-Path -LiteralPath $customAgent15)
    $uh15b = Join-Path $sandbox 'u15b'
    $pr15b = Join-Path $uh15b '.gemini\config\plugins\b3-ai-engineering'
    $ext15b = Join-Path $uh15b 'external-same-name'
    New-Item -ItemType Directory -Path (Join-Path $pr15b 'skills'), $ext15b -Force | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $pr15b 'skills\debugging') -Target $ext15b | Out-Null
    $blocked15Ps = Invoke-PsScript $agPs @('install', '-PluginRoot', $pr15b, '-UserHome', $uh15b, '-Force')
    $blocked15ShOk = $true
    if ($hasBash) {
        $pr15bp = $pr15b -replace '\\', '/'
        $uh15bp = $uh15b -replace '\\', '/'
        $blocked15Sh = Invoke-ShScript $agShPosix "install --plugin-root '$pr15bp' --user-home '$uh15bp' --force"
        $blocked15ShOk = ($blocked15Sh.Code -eq 1) -and ($blocked15Sh.Text -match 'UPDATE_CONFLICT')
    }
    $collisionKept15 = (Test-Path -LiteralPath (Join-Path $pr15b 'skills\debugging')) -and (Test-Path -LiteralPath $ext15b)
    if ($in15.Code -eq 0 -and $up15Ps.Code -eq 0 -and $ver15Ps.Code -eq 0 -and $up15ShOk -and $preserved15 -and
        $blocked15Ps.Code -eq 1 -and $blocked15ShOk -and $collisionKept15) {
        Pass 'ag-global-untracked-links-survive-update'
    } else {
        FailCheck 'ag-global-untracked-links-survive-update' "in=$($in15.Code) up=$($up15Ps.Code) verify=$($ver15Ps.Code) bash=$up15ShOk preserved=$preserved15 collision=$($blocked15Ps.Code)/$blocked15ShOk/$collisionKept15"
    }

    # --- 16. P1: modified managed files stop update before any writes ---
    $uh16 = Join-Path $sandbox 'u16'
    $pr16 = Join-Path $uh16 '.gemini\config\plugins\b3-ai-engineering'
    $in16 = Invoke-PsScript $agPs @('install', '-PluginRoot', $pr16, '-UserHome', $uh16)
    $agent16 = Join-Path $pr16 'agents\b3-reviewer.md'
    $rules16 = Join-Path $pr16 'rules\AGENTS.md'
    $plugin16 = Join-Path $pr16 'plugin.json'
    $manifest16 = Join-Path $pr16 '.b3-plugin-manifest'
    $priorPlugin16 = (Get-FileHash -LiteralPath $plugin16 -Algorithm SHA256).Hash
    $priorManifest16 = (Get-FileHash -LiteralPath $manifest16 -Algorithm SHA256).Hash
    Add-Content -LiteralPath $agent16 -Value '<!-- personal edit -->'
    $blocked16Ps = Invoke-PsScript $agPs @('update', '-PluginRoot', $pr16, '-UserHome', $uh16)
    $blocked16ShOk = $true
    if ($hasBash) {
        $pr16p = $pr16 -replace '\\', '/'
        $uh16p = $uh16 -replace '\\', '/'
        $blocked16Sh = Invoke-ShScript $agShPosix "update --plugin-root '$pr16p' --user-home '$uh16p'"
        $blocked16ShOk = ($blocked16Sh.Code -eq 1) -and ($blocked16Sh.Text -match 'UPDATE_CONFLICT')
    }
    $protected16 = ((Get-Content -LiteralPath $agent16 -Raw) -match 'personal edit') -and
                   ((Get-FileHash -LiteralPath $plugin16 -Algorithm SHA256).Hash -eq $priorPlugin16) -and
                   ((Get-FileHash -LiteralPath $manifest16 -Algorithm SHA256).Hash -eq $priorManifest16)
    $restored16 = Invoke-PsScript $agPs @('update', '-PluginRoot', $pr16, '-UserHome', $uh16, '-Force')
    Add-Content -LiteralPath $rules16 -Value '<!-- personal rules -->'
    $rulesBlockedPs16 = Invoke-PsScript $agPs @('update', '-PluginRoot', $pr16, '-UserHome', $uh16)
    $rulesBlockedShOk16 = $true
    if ($hasBash) {
        $rulesBlockedSh16 = Invoke-ShScript $agShPosix "update --plugin-root '$pr16p' --user-home '$uh16p'"
        $rulesBlockedShOk16 = ($rulesBlockedSh16.Code -eq 1) -and ($rulesBlockedSh16.Text -match 'UPDATE_CONFLICT')
    }
    $rulesKept16 = (Get-Content -LiteralPath $rules16 -Raw) -match 'personal rules'
    $forced16 = Invoke-PsScript $agPs @('update', '-PluginRoot', $pr16, '-UserHome', $uh16, '-Force')
    $verified16 = Invoke-PsScript $agPs @('verify', '-PluginRoot', $pr16, '-UserHome', $uh16)
    if ($in16.Code -eq 0 -and $blocked16Ps.Code -eq 1 -and $blocked16ShOk -and $protected16 -and
        $restored16.Code -eq 0 -and $rulesBlockedPs16.Code -eq 1 -and $rulesBlockedShOk16 -and
        $rulesKept16 -and $forced16.Code -eq 0 -and $verified16.Code -eq 0) {
        Pass 'ag-global-update-preserves-user-edits'
    } else {
        FailCheck 'ag-global-update-preserves-user-edits' "in=$($in16.Code) agent=$($blocked16Ps.Code)/$blocked16ShOk protected=$protected16 restore=$($restored16.Code) rules=$($rulesBlockedPs16.Code)/$rulesBlockedShOk16 kept=$rulesKept16 forced=$($forced16.Code) ver=$($verified16.Code)"
    }

}
finally {
    Pop-Location -ErrorAction SilentlyContinue
    Remove-ReparseLinksUnder $sandbox
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed -gt 0) {
    Write-Output "$failed check(s) failed"
    exit 1
}
if (-not $hasBash) {
    Write-Output 'ok (PS-only; bash skipped - INCOMPLETE)'
} else {
    Write-Output 'ok'
}
exit 0
