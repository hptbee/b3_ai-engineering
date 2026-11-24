# Behavioral validation suite for global Antigravity plugin lifecycle and unified adapters/install-global dispatcher.
# Exercises install, verify (independent capability surfaces), update, dry-run, uninstall, drift/broken links, spaces, coexistence, manifest corruption, and dispatcher parity across PowerShell and Git Bash.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate-antigravity-global.ps1
param([switch]$AllowIncompleteBash)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\global-test-helpers.ps1')

$root = Split-Path -Parent $PSScriptRoot
$agPs = Join-Path $root 'adapters\antigravity\install-plugin.ps1'
$agShPosix = ($root -replace '\\', '/') + '/adapters/antigravity/install-plugin.sh'
$uniPs = Join-Path $root 'adapters\install-global.ps1'
$uniShPosix = ($root -replace '\\', '/') + '/adapters/install-global.sh'
$hasBash = $script:HasBash

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
                    ($ver2Sh.Text -match 'check\.agents=OK') -and
                    ($ver2Sh.Text -match 'check\.skills_json=OK')
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
    foreach ($cmd in @('b3-plan', 'b3-implement', 'b3-debug', 'b3-review', 'b3-verify', 'b3-review-loop', 'b3-ship', 'b3-research-ship')) {
        if (-not (Test-Path -LiteralPath (Join-Path $pr2 "skills\$cmd\SKILL.md") -PathType Leaf)) { $hasAllCmds = $false }
    }
    if ($in2.Code -eq 0 -and $ver2Ps.Code -eq 0 -and $ver2ShOk -and
        ($ver2Ps.Text -match 'check\.plugin=OK') -and ($ver2Ps.Text -match 'check\.commands=OK') -and
        ($ver2Ps.Text -match 'check\.skills_json=OK') -and
        (Test-Path -LiteralPath (Join-Path $uh2 '.gemini\config\skills.json') -PathType Leaf) -and
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
    Copy-B3Snapshot -DestDir $b3Copy -IncludeCommandSkills
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
    New-Item -ItemType Junction -Path $pr5DanglingLink -Target $pr5DanglingTarget | Out-Null
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
    [System.IO.Directory]::Delete((Join-Path $pr5NonB3 'skills\verification'), $false)
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
    Copy-B3Snapshot -DestDir $b3Drift -IncludeCommandSkills
    $staleSrcAg = Join-Path $b3Drift 'agents\b3-stale-generated.md'
    [System.IO.File]::WriteAllText($staleSrcAg, "---`nname: b3-stale`ndescription: Temporary test agent for stale-agent verification`nreadonly: true`n---`nTemporary agent.`n", (New-Object System.Text.UTF8Encoding($false)))
    $uh6 = Join-Path $sandbox 'u6'
    $pr6 = Join-Path $uh6 '.gemini\config\plugins\b3-ai-engineering'
    $drPsPath = Join-Path $b3Drift 'adapters\antigravity\install-plugin.ps1'
    $drShPosix = ($b3Drift -replace '\\', '/') + '/adapters/antigravity/install-plugin.sh'
    $in6 = Invoke-PsScript $drPsPath @('install', '-B3Home', $b3Drift, '-PluginRoot', $pr6, '-UserHome', $uh6)

    Add-Content -LiteralPath (Join-Path $pr6 'plugin.json') ' '
    $vPluginBad = Invoke-PsScript $drPsPath @('verify', '-B3Home', $b3Drift, '-PluginRoot', $pr6, '-UserHome', $uh6)
    $pluginFailReported = ($vPluginBad.Code -eq 1) -and ($vPluginBad.Text -match 'check\.plugin=FAIL') -and ($vPluginBad.Text -match 'check\.rules=OK')
    $healPlugin = Invoke-PsScript $drPsPath @('update', '-B3Home', $b3Drift, '-PluginRoot', $pr6, '-UserHome', $uh6, '-Force')

    Add-Content -LiteralPath (Join-Path $pr6 'rules\AGENTS.md') "`n<!-- drifted -->"
    $vRulesBad = Invoke-PsScript $drPsPath @('verify', '-B3Home', $b3Drift, '-PluginRoot', $pr6, '-UserHome', $uh6)
    $rulesFailReported = ($vRulesBad.Code -eq 1) -and ($vRulesBad.Text -match 'check\.rules=FAIL') -and ($vRulesBad.Text -match 'check\.skills=OK')

    $healRules = Invoke-PsScript $drPsPath @('update', '-B3Home', $b3Drift, '-PluginRoot', $pr6, '-UserHome', $uh6, '-Force')
    Add-Content -LiteralPath (Join-Path $pr6 'agents\b3-reviewer.md') "`n<!-- drifted -->"
    Remove-Item -LiteralPath $staleSrcAg -Force
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
    $healAll = Invoke-PsScript $drPsPath @('update', '-B3Home', $b3Drift, '-PluginRoot', $pr6, '-UserHome', $uh6, '-Force')
    $verHealed = Invoke-PsScript $drPsPath @('verify', '-B3Home', $b3Drift, '-PluginRoot', $pr6, '-UserHome', $uh6)
    $staleAgPruned = -not (Test-Path -LiteralPath (Join-Path $pr6 'agents\b3-stale-generated.md'))
    if ($in6.Code -eq 0 -and $pluginFailReported -and $healPlugin.Code -eq 0 -and $rulesFailReported -and $healRules.Code -eq 0 -and $staleAgCaught -and $multiFailReported -and $shBadOk -and $healAll.Code -eq 0 -and $verHealed.Code -eq 0 -and $staleAgPruned) {
        Pass 'ag-global-stale-broken-and-drift'
    } else {
        FailCheck 'ag-global-stale-broken-and-drift' "pj=$pluginFailReported rules=$rulesFailReported staleAg=$staleAgCaught multi=$multiFailReported sh=$shBadOk healed=$($verHealed.Code) pruned=$staleAgPruned"
    }

    # --- 7. ag-global-paths-with-spaces ---
    $b3Sp = Join-Path $sandbox 'B3 Space Home'
    Copy-B3Snapshot -DestDir $b3Sp -IncludeCommandSkills
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
        New-TempGitRepo -RepoPath $pr -SubDir '.agents\rules' -SubFileName 'local.md' -SubFileContent '# Local rule' `
            -RootFileName 'AGENTS.md' -RootFileContent "# Local Project $(Split-Path -Leaf $pr)"
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
    New-TempGitRepo -RepoPath $prodC -RootFileName 'README.md' -RootFileContent '# Gamma'
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
    New-Item -ItemType Junction -Path $liveLink -Target $liveTarget | Out-Null
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
        New-Item -ItemType Junction -Path (Join-Path $prSub $subName) -Target $extSub | Out-Null
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
        [System.IO.Directory]::Delete((Join-Path $pr13 'skills\verification'), $false)
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
    [System.IO.Directory]::Delete((Join-Path $pr14 'skills\debugging'), $false)
    New-Item -ItemType Junction -Path (Join-Path $pr14 'skills\debugging') -Target $dbgTgt14 | Out-Null
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
        [System.IO.Directory]::Delete((Join-Path $pr14s 'skills\debugging'), $false)
        New-Item -ItemType Junction -Path (Join-Path $pr14s 'skills\debugging') -Target $dbgTgt14s | Out-Null
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

    # --- 17. ag-global-manifest-corruption (blocks install/update/verify/uninstall) ---
    $uh17 = Join-Path $sandbox 'u17'
    $pr17 = Join-Path $uh17 '.gemini\config\plugins\b3-ai-engineering'
    $in17 = Invoke-PsScript $agPs @('install', '-PluginRoot', $pr17, '-UserHome', $uh17)
    $manifest17 = Join-Path $pr17 '.b3-plugin-manifest'
    [System.IO.File]::WriteAllText($manifest17, "schema=corrupt`nbad_line_without_equals`n", (New-Object System.Text.UTF8Encoding($false)))
    $inBad17 = Invoke-PsScript $agPs @('install', '-PluginRoot', $pr17, '-UserHome', $uh17)
    $upBad17 = Invoke-PsScript $agPs @('update', '-PluginRoot', $pr17, '-UserHome', $uh17)
    $verBad17 = Invoke-PsScript $agPs @('verify', '-PluginRoot', $pr17, '-UserHome', $uh17)
    $unBad17 = Invoke-PsScript $agPs @('uninstall', '-PluginRoot', $pr17, '-UserHome', $uh17)
    $kept17 = (Test-Path -LiteralPath (Join-Path $pr17 'plugin.json')) -and
              (Test-Path -LiteralPath (Join-Path $pr17 'agents\b3-reviewer.md')) -and
              (Test-Path -LiteralPath $manifest17)

    $sh17Ok = $true
    if ($hasBash) {
        $uh17s = Join-Path $sandbox 'u17sh'
        $pr17s = Join-Path $uh17s '.gemini\config\plugins\b3-ai-engineering'
        $pr17sp = $pr17s -replace '\\', '/'
        $uh17sp = $uh17s -replace '\\', '/'
        $shIn17 = Invoke-ShScript $agShPosix "install --plugin-root '$pr17sp' --user-home '$uh17sp'"
        $manifest17s = Join-Path $pr17s '.b3-plugin-manifest'
        [System.IO.File]::WriteAllText($manifest17s, "schema=corrupt`nbad_line_without_equals`n", (New-Object System.Text.UTF8Encoding($false)))
        $shInBad17 = Invoke-ShScript $agShPosix "install --plugin-root '$pr17sp' --user-home '$uh17sp'"
        $shUpBad17 = Invoke-ShScript $agShPosix "update --plugin-root '$pr17sp' --user-home '$uh17sp'"
        $shVerBad17 = Invoke-ShScript $agShPosix "verify --plugin-root '$pr17sp' --user-home '$uh17sp'"
        $shUnBad17 = Invoke-ShScript $agShPosix "uninstall --plugin-root '$pr17sp' --user-home '$uh17sp'"
        $shKept17 = (Test-Path -LiteralPath (Join-Path $pr17s 'plugin.json')) -and
                    (Test-Path -LiteralPath (Join-Path $pr17s 'agents\b3-reviewer.md')) -and
                    (Test-Path -LiteralPath $manifest17s)
        $sh17Ok = ($shIn17.Code -eq 0) -and ($shInBad17.Code -ne 0) -and ($shUpBad17.Code -ne 0) -and
                  ($shVerBad17.Code -ne 0) -and ($shUnBad17.Code -ne 0) -and $shKept17
    }
    if ($in17.Code -eq 0 -and $inBad17.Code -ne 0 -and $upBad17.Code -ne 0 -and
        $verBad17.Code -ne 0 -and $unBad17.Code -ne 0 -and $kept17 -and $sh17Ok) {
        Pass 'ag-global-manifest-corruption'
    } else {
        FailCheck 'ag-global-manifest-corruption' "in=$($in17.Code) i2=$($inBad17.Code) u2=$($upBad17.Code) v2=$($verBad17.Code) un2=$($unBad17.Code) kept=$kept17 sh=$sh17Ok"
    }

    # --- 18. ag-global-manifest-path-traversal ---
    $uh18 = Join-Path $sandbox 'u18'
    $pr18 = Join-Path $uh18 '.gemini\config\plugins\b3-ai-engineering'
    $in18 = Invoke-PsScript $agPs @('install', '-PluginRoot', $pr18, '-UserHome', $uh18)
    $decoy18 = Join-Path $uh18 'outside-ag-decoy.txt'
    $decoyDir18 = Join-Path $uh18 'outside-ag-dir'
    [System.IO.File]::WriteAllText($decoy18, "keep outside ag decoy`n", (New-Object System.Text.UTF8Encoding($false)))
    New-Item -ItemType Directory -Path $decoyDir18 -Force | Out-Null
    $decoySha18 = (Get-FileHash -LiteralPath $decoy18 -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifest18 = Join-Path $pr18 '.b3-plugin-manifest'
    $origManifest18 = [System.IO.File]::ReadAllText($manifest18, (New-Object System.Text.UTF8Encoding($false)))
    $evilLines18 = @(
        "file|../../../../outside-ag-decoy.txt|$decoySha18",
        "file|agents\..\..\..\..\..\outside-ag-decoy.txt|$decoySha18",
        "file|/tmp/outside.txt|$decoySha18",
        "file|C:/outside.txt|$decoySha18",
        "link|skills/../../outside-ag-dir|$($decoyDir18 -replace '\\', '/')"
    ) -join "`n"
    [System.IO.File]::WriteAllText($manifest18, ($origManifest18.TrimEnd("`r", "`n") + "`n" + $evilLines18 + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    $unTrav18 = Invoke-PsScript $agPs @('uninstall', '-PluginRoot', $pr18, '-UserHome', $uh18)
    $unForceTrav18 = Invoke-PsScript $agPs @('uninstall', '-PluginRoot', $pr18, '-UserHome', $uh18, '-Force')
    $verTrav18 = Invoke-PsScript $agPs @('verify', '-PluginRoot', $pr18, '-UserHome', $uh18)
    $upTrav18 = Invoke-PsScript $agPs @('update', '-PluginRoot', $pr18, '-UserHome', $uh18)
    $kept18 = (Test-Path -LiteralPath $decoy18 -PathType Leaf) -and (Test-Path -LiteralPath $decoyDir18 -PathType Container) -and
              (Test-Path -LiteralPath (Join-Path $pr18 'plugin.json') -PathType Leaf) -and
              (Test-Path -LiteralPath (Join-Path $pr18 'agents\b3-reviewer.md') -PathType Leaf)

    $sh18Ok = $true
    if ($hasBash) {
        $uh18s = Join-Path $sandbox 'u18sh'
        $pr18s = Join-Path $uh18s '.gemini\config\plugins\b3-ai-engineering'
        $pr18sp = $pr18s -replace '\\', '/'
        $uh18sp = $uh18s -replace '\\', '/'
        $shIn18 = Invoke-ShScript $agShPosix "install --plugin-root '$pr18sp' --user-home '$uh18sp'"
        $decoy18s = Join-Path $uh18s 'outside-ag-decoy.txt'
        $decoyDir18s = Join-Path $uh18s 'outside-ag-dir'
        [System.IO.File]::WriteAllText($decoy18s, "keep outside ag decoy`n", (New-Object System.Text.UTF8Encoding($false)))
        New-Item -ItemType Directory -Path $decoyDir18s -Force | Out-Null
        $decoySha18s = (Get-FileHash -LiteralPath $decoy18s -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifest18s = Join-Path $pr18s '.b3-plugin-manifest'
        $origManifest18s = [System.IO.File]::ReadAllText($manifest18s, (New-Object System.Text.UTF8Encoding($false)))
        $evilLines18s = @(
            "file|../../../../outside-ag-decoy.txt|$decoySha18s",
            "file|agents\..\..\..\..\..\outside-ag-decoy.txt|$decoySha18s",
            "file|/tmp/outside.txt|$decoySha18s",
            "file|C:/outside.txt|$decoySha18s",
            "link|skills/../../outside-ag-dir|$($decoyDir18s -replace '\\', '/')"
        ) -join "`n"
        [System.IO.File]::WriteAllText($manifest18s, ($origManifest18s.TrimEnd("`r", "`n") + "`n" + $evilLines18s + "`n"), (New-Object System.Text.UTF8Encoding($false)))
        $shUn18 = Invoke-ShScript $agShPosix "uninstall --plugin-root '$pr18sp' --user-home '$uh18sp'"
        $shUnForce18 = Invoke-ShScript $agShPosix "uninstall --plugin-root '$pr18sp' --user-home '$uh18sp' --force"
        $shVer18 = Invoke-ShScript $agShPosix "verify --plugin-root '$pr18sp' --user-home '$uh18sp'"
        $shUp18 = Invoke-ShScript $agShPosix "update --plugin-root '$pr18sp' --user-home '$uh18sp'"
        $shKept18 = (Test-Path -LiteralPath $decoy18s -PathType Leaf) -and (Test-Path -LiteralPath $decoyDir18s -PathType Container) -and
                    (Test-Path -LiteralPath (Join-Path $pr18s 'plugin.json') -PathType Leaf) -and
                    (Test-Path -LiteralPath (Join-Path $pr18s 'agents\b3-reviewer.md') -PathType Leaf)
        $sh18Ok = ($shIn18.Code -eq 0) -and ($shUn18.Code -ne 0) -and ($shUnForce18.Code -ne 0) -and
                  ($shVer18.Code -ne 0) -and ($shUp18.Code -ne 0) -and $shKept18
    }
    if ($in18.Code -eq 0 -and $unTrav18.Code -ne 0 -and $unForceTrav18.Code -ne 0 -and
        $verTrav18.Code -ne 0 -and $upTrav18.Code -ne 0 -and $kept18 -and $sh18Ok) {
        Pass 'ag-global-manifest-path-traversal'
    } else {
        FailCheck 'ag-global-manifest-path-traversal' "in=$($in18.Code) un=$($unTrav18.Code) uf=$($unForceTrav18.Code) ver=$($verTrav18.Code) up=$($upTrav18.Code) kept=$kept18 sh=$sh18Ok"
    }

    # --- 19. ag-global-special-chars-no-cmd-injection (R002) ---
    $uh19 = Join-Path $sandbox 'u19 amp & %TEMP% dir'
    $pr19 = Join-Path $uh19 '.gemini\config\plugins\b3-ai-engineering'
    $in19 = Invoke-PsScript $agPs @('install', '-PluginRoot', $pr19, '-UserHome', $uh19)
    $ver19 = Invoke-PsScript $agPs @('verify', '-PluginRoot', $pr19, '-UserHome', $uh19)
    $un19 = Invoke-PsScript $agPs @('uninstall', '-PluginRoot', $pr19, '-UserHome', $uh19)
    $sh19Ok = $true
    if ($hasBash) {
        $uh19s = Join-Path $sandbox 'u19sh amp & %TEMP% dir'
        $pr19s = Join-Path $uh19s '.gemini\config\plugins\b3-ai-engineering'
        $pr19sp = $pr19s -replace '\\', '/'
        $uh19sp = $uh19s -replace '\\', '/'
        $shIn19 = Invoke-ShScript $agShPosix "install --plugin-root '$pr19sp' --user-home '$uh19sp'"
        $shVer19 = Invoke-ShScript $agShPosix "verify --plugin-root '$pr19sp' --user-home '$uh19sp'"
        $shUn19 = Invoke-ShScript $agShPosix "uninstall --plugin-root '$pr19sp' --user-home '$uh19sp'"
        $sh19Ok = ($shIn19.Code -eq 0) -and ($shVer19.Code -eq 0) -and ($shUn19.Code -eq 0) -and (-not (Test-Path -LiteralPath $pr19s))
    }
    if ($in19.Code -eq 0 -and $ver19.Code -eq 0 -and $un19.Code -eq 0 -and (-not (Test-Path -LiteralPath $pr19)) -and $sh19Ok) {
        Pass 'ag-global-special-chars-no-cmd-injection'
    } else {
        FailCheck 'ag-global-special-chars-no-cmd-injection' "in=$($in19.Code) ver=$($ver19.Code) un=$($un19.Code) sh=$sh19Ok"
    }

    # --- 20. ag-global-force-nested-junction-safe (R003) ---
    $uh20 = Join-Path $sandbox 'u20'
    $pr20 = Join-Path $uh20 '.gemini\config\plugins\b3-ai-engineering'
    $decoy20 = Join-Path $uh20 'external-decoy'
    New-Item -ItemType Directory -Path $decoy20, (Join-Path $pr20 'skills\debugging') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $decoy20 'keep.txt') "keep decoy`n"
    Set-Content -LiteralPath (Join-Path $pr20 'skills\debugging\SKILL.md') "---`nname: debugging`ndescription: local`n---`n"
    Set-Content -LiteralPath (Join-Path $pr20 'skills\debugging\.hidden-note') "dotfile`n"
    New-Item -ItemType Junction -Path (Join-Path $pr20 'skills\debugging\nested-link') -Target $decoy20 | Out-Null
    $f20 = Invoke-PsScript $agPs @('install', '-PluginRoot', $pr20, '-UserHome', $uh20, '-Force')
    $v20 = Invoke-PsScript $agPs @('verify', '-PluginRoot', $pr20, '-UserHome', $uh20)
    $decoyKept20 = Test-Path -LiteralPath (Join-Path $decoy20 'keep.txt') -PathType Leaf
    $sh20Ok = $true
    if ($hasBash) {
        $uh20s = Join-Path $sandbox 'u20sh'
        $pr20s = Join-Path $uh20s '.gemini\config\plugins\b3-ai-engineering'
        $decoy20s = Join-Path $uh20s 'external-decoy-sh'
        New-Item -ItemType Directory -Path $decoy20s, (Join-Path $pr20s 'skills\debugging') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $decoy20s 'keep.txt') "keep decoy sh`n"
        Set-Content -LiteralPath (Join-Path $pr20s 'skills\debugging\SKILL.md') "---`nname: debugging`ndescription: local`n---`n"
        Set-Content -LiteralPath (Join-Path $pr20s 'skills\debugging\.hidden-note') "dotfile`n"
        New-Item -ItemType Junction -Path (Join-Path $pr20s 'skills\debugging\nested-link') -Target $decoy20s | Out-Null
        $pr20sp = $pr20s -replace '\\', '/'
        $uh20sp = $uh20s -replace '\\', '/'
        $shF20 = Invoke-ShScript $agShPosix "install --plugin-root '$pr20sp' --user-home '$uh20sp' --force"
        $shV20 = Invoke-ShScript $agShPosix "verify --plugin-root '$pr20sp' --user-home '$uh20sp'"
        $sh20Ok = ($shF20.Code -eq 0) -and ($shV20.Code -eq 0) -and (Test-Path -LiteralPath (Join-Path $decoy20s 'keep.txt') -PathType Leaf)
    }
    if ($f20.Code -eq 0 -and $v20.Code -eq 0 -and $decoyKept20 -and $sh20Ok) {
        Pass 'ag-global-force-nested-junction-safe'
    } else {
        FailCheck 'ag-global-force-nested-junction-safe' "f=$($f20.Code) v=$($v20.Code) decoy=$decoyKept20 sh=$sh20Ok"
    }

    # --- 21. ag-global-manifest-hardening (R025) ---
    $uh21 = Join-Path $sandbox 'u21'
    $pr21 = Join-Path $uh21 '.gemini\config\plugins\b3-ai-engineering'
    $in21 = Invoke-PsScript $agPs @('install', '-PluginRoot', $pr21, '-UserHome', $uh21)
    $m21Path = Join-Path $pr21 '.b3-plugin-manifest'
    $m21Clean = [System.IO.File]::ReadAllText($m21Path, (New-Object System.Text.UTF8Encoding($false)))
    $validSha21 = ('b' * 64)
    $badVariants21 = @(
        @{ Name = 'empty-hash'; Body = ($m21Clean -replace '(?m)^(file\|plugin\.json\|).*$', '$1') },
        @{ Name = 'non-hex-hash'; Body = ($m21Clean -replace '(?m)^(file\|plugin\.json\|).*$', '${1}not-a-sha256') },
        @{ Name = 'empty-target'; Body = ($m21Clean -replace '(?m)^(link\|skills/debugging\|).*$', '$1') },
        @{ Name = 'rel-target'; Body = ($m21Clean -replace '(?m)^(link\|skills/debugging\|).*$', '${1}relative/path') },
        @{ Name = 'trav-target'; Body = ($m21Clean -replace '(?m)^(link\|skills/debugging\|).*$', '${1}C:/ok/../escape') },
        @{ Name = 'pipe-target'; Body = ($m21Clean -replace '(?m)^(link\|skills/debugging\|).*$', '${1}C:/ok|extra') },
        @{ Name = 'dup-entry'; Body = ($m21Clean.TrimEnd("`n") + "`nfile|plugin.json|$validSha21`n") },
        @{ Name = 'empty-schema'; Body = ($m21Clean -replace '(?m)^schema=.*$', 'schema=') },
        @{ Name = 'dup-header'; Body = ($m21Clean.TrimEnd("`n") + "`nb3_home=C:/other`n") }
    )
    $psHard21Ok = ($in21.Code -eq 0)
    $hard21FailDetail = ''
    foreach ($bv in $badVariants21) {
        [System.IO.File]::WriteAllText($m21Path, $bv.Body, (New-Object System.Text.UTF8Encoding($false)))
        $vBad = Invoke-PsScript $agPs @('verify', '-PluginRoot', $pr21, '-UserHome', $uh21)
        $uBad = Invoke-PsScript $agPs @('update', '-PluginRoot', $pr21, '-UserHome', $uh21)
        $xBad = Invoke-PsScript $agPs @('uninstall', '-PluginRoot', $pr21, '-UserHome', $uh21)
        if ($vBad.Code -eq 0 -or $uBad.Code -eq 0 -or $xBad.Code -eq 0 -or -not (Test-Path -LiteralPath (Join-Path $pr21 'plugin.json'))) {
            $psHard21Ok = $false
            $hard21FailDetail = "ps:$($bv.Name)=v:$($vBad.Code)/u:$($uBad.Code)/x:$($xBad.Code)"
            break
        }
    }
    $shHard21Ok = $true
    if ($hasBash) {
        $uh21s = Join-Path $sandbox 'u21sh'
        $pr21s = Join-Path $uh21s '.gemini\config\plugins\b3-ai-engineering'
        $pr21sp = $pr21s -replace '\\', '/'
        $uh21sp = $uh21s -replace '\\', '/'
        $shIn21 = Invoke-ShScript $agShPosix "install --plugin-root '$pr21sp' --user-home '$uh21sp'"
        $m21sPath = Join-Path $pr21s '.b3-plugin-manifest'
        $m21sClean = [System.IO.File]::ReadAllText($m21sPath, (New-Object System.Text.UTF8Encoding($false)))
        if ($shIn21.Code -ne 0) { $shHard21Ok = $false; $hard21FailDetail += " shIn=$($shIn21.Code)" }
        else {
            $shBadVariants21 = @(
                @{ Name = 'empty-hash'; Body = ($m21sClean -replace '(?m)^(file\|plugin\.json\|).*$', '$1') },
                @{ Name = 'non-hex-hash'; Body = ($m21sClean -replace '(?m)^(file\|plugin\.json\|).*$', '${1}not-a-sha256') },
                @{ Name = 'empty-target'; Body = ($m21sClean -replace '(?m)^(link\|skills/debugging\|).*$', '$1') },
                @{ Name = 'rel-target'; Body = ($m21sClean -replace '(?m)^(link\|skills/debugging\|).*$', '${1}relative/path') },
                @{ Name = 'trav-target'; Body = ($m21sClean -replace '(?m)^(link\|skills/debugging\|).*$', '${1}C:/ok/../escape') },
                @{ Name = 'pipe-target'; Body = ($m21sClean -replace '(?m)^(link\|skills/debugging\|).*$', '${1}C:/ok|extra') },
                @{ Name = 'dup-entry'; Body = ($m21sClean.TrimEnd("`n") + "`nfile|plugin.json|$validSha21`n") },
                @{ Name = 'empty-schema'; Body = ($m21sClean -replace '(?m)^schema=.*$', 'schema=') },
                @{ Name = 'dup-header'; Body = ($m21sClean.TrimEnd("`n") + "`nb3_home=C:/other`n") }
            )
            foreach ($bv in $shBadVariants21) {
                [System.IO.File]::WriteAllText($m21sPath, $bv.Body, (New-Object System.Text.UTF8Encoding($false)))
                $sv = Invoke-ShScript $agShPosix "verify --plugin-root '$pr21sp' --user-home '$uh21sp'"
                $su = Invoke-ShScript $agShPosix "update --plugin-root '$pr21sp' --user-home '$uh21sp'"
                $sx = Invoke-ShScript $agShPosix "uninstall --plugin-root '$pr21sp' --user-home '$uh21sp'"
                if ($sv.Code -eq 0 -or $su.Code -eq 0 -or $sx.Code -eq 0 -or -not (Test-Path -LiteralPath (Join-Path $pr21s 'plugin.json'))) {
                    $shHard21Ok = $false
                    $hard21FailDetail += " sh:$($bv.Name)=v:$($sv.Code)/u:$($su.Code)/x:$($sx.Code)"
                    break
                }
            }
        }
    }
    if ($psHard21Ok -and $shHard21Ok) {
        Pass 'ag-global-manifest-hardening'
    } else {
        FailCheck 'ag-global-manifest-hardening' $hard21FailDetail
    }

    # --- 22. ag-global-skills-json-lifecycle (merge, verify, uninstall preserve custom vs remove empty, conflict & symlink) ---
    $uh22 = Join-Path $sandbox 'u22'
    $pr22 = Join-Path $uh22 '.gemini\config\plugins\b3-ai-engineering'
    $sj22 = Join-Path $uh22 '.gemini\config\skills.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $sj22) -Force | Out-Null
    $b3Fwd = ($root -replace '\\', '/')
    $seedSj22 = @"
{
  "inherits": ["./shared.json"],
  "note": "keep-top",
  "entries": [
    { "path": "D:/my-custom-skills", "include_only": ["foo"] },
    { "path": "$b3Fwd/skills/removed-cat" },
    { "path": "$b3Fwd/adapters/command-skills" }
  ]
}
"@.Replace("`r`n", "`n")
    [System.IO.File]::WriteAllText($sj22, $seedSj22, (New-Object System.Text.UTF8Encoding($false)))

    $in22 = Invoke-PsScript $agPs @('install', '-PluginRoot', $pr22, '-UserHome', $uh22)
    $ver22 = Invoke-PsScript $agPs @('verify', '-PluginRoot', $pr22, '-UserHome', $uh22)
    $sj22Obj = Get-Content -LiteralPath $sj22 -Raw | ConvertFrom-Json
    $sj22Paths = @($sj22Obj.entries | ForEach-Object { [string]$_.path })
    $merge22Ok = ($in22.Code -eq 0) -and ($ver22.Code -eq 0) -and ($ver22.Text -match 'check\.skills_json=OK') -and
                 ($sj22Obj.note -eq 'keep-top') -and (@($sj22Obj.inherits).Count -eq 1) -and ($sj22Obj.inherits[0] -eq './shared.json') -and
                 ($sj22Paths -contains 'D:/my-custom-skills') -and ($sj22Obj.entries[0].include_only[0] -eq 'foo') -and
                 ($sj22Paths -notcontains "$b3Fwd/skills/removed-cat") -and
                 (@($sj22Paths | Where-Object { $_ -eq "$b3Fwd/adapters/command-skills" }).Count -eq 1) -and
                 ($sj22Paths -contains "$b3Fwd/skills/architecture") -and ($sj22Paths -contains "$b3Fwd/skills/engineering")

    # Verify catches missing/stale entries & missing file independently
    $sj22MissingEntry = @{ inherits = $sj22Obj.inherits; note = 'keep-top'; entries = @($sj22Obj.entries | Where-Object { $_.path -ne "$b3Fwd/adapters/command-skills" }) + @(@{ path = "$b3Fwd/skills/bogus-stale" }) }
    [System.IO.File]::WriteAllText($sj22, ((ConvertTo-Json $sj22MissingEntry -Depth 10) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    $ver22Bad = Invoke-PsScript $agPs @('verify', '-PluginRoot', $pr22, '-UserHome', $uh22)
    $ver22BadOk = ($ver22Bad.Code -eq 1) -and ($ver22Bad.Text -match 'check\.skills_json=FAIL') -and ($ver22Bad.Text -match 'check\.plugin=OK')
    $up22Heal = Invoke-PsScript $agPs @('update', '-PluginRoot', $pr22, '-UserHome', $uh22)
    $ver22Healed = Invoke-PsScript $agPs @('verify', '-PluginRoot', $pr22, '-UserHome', $uh22)

    # Corrupt skills.json refuses without -Force before modifying PluginRoot; -Force heals
    Remove-Item -LiteralPath $sj22 -Force
    $ver22Missing = Invoke-PsScript $agPs @('verify', '-PluginRoot', $pr22, '-UserHome', $uh22)
    [System.IO.File]::WriteAllText($sj22, "{bad json`n", (New-Object System.Text.UTF8Encoding($false)))
    $up22Corrupt = Invoke-PsScript $agPs @('update', '-PluginRoot', $pr22, '-UserHome', $uh22)
    $up22Force = Invoke-PsScript $agPs @('update', '-PluginRoot', $pr22, '-UserHome', $uh22, '-Force')
    [System.IO.File]::WriteAllText($sj22, $seedSj22, (New-Object System.Text.UTF8Encoding($false)))
    $up22ReSeed = Invoke-PsScript $agPs @('update', '-PluginRoot', $pr22, '-UserHome', $uh22)

    # Uninstall removes only B3 entries and preserves custom entries/properties
    $un22 = Invoke-PsScript $agPs @('uninstall', '-PluginRoot', $pr22, '-UserHome', $uh22)
    $sj22PostUn = Get-Content -LiteralPath $sj22 -Raw | ConvertFrom-Json
    $un22PreserveOk = ($un22.Code -eq 0) -and ($sj22PostUn.note -eq 'keep-top') -and
                      (@($sj22PostUn.entries).Count -eq 1) -and ($sj22PostUn.entries[0].path -eq 'D:/my-custom-skills')

    # Clean B3-only install then uninstall deletes skills.json cleanly
    $uh22Pure = Join-Path $sandbox 'u22pure'
    $pr22Pure = Join-Path $uh22Pure '.gemini\config\plugins\b3-ai-engineering'
    $sj22Pure = Join-Path $uh22Pure '.gemini\config\skills.json'
    $in22Pure = Invoke-PsScript $agPs @('install', '-PluginRoot', $pr22Pure, '-UserHome', $uh22Pure)
    $un22Pure = Invoke-PsScript $agPs @('uninstall', '-PluginRoot', $pr22Pure, '-UserHome', $uh22Pure)
    $pureDeletedOk = ($in22Pure.Code -eq 0) -and ($un22Pure.Code -eq 0) -and (-not (Test-Path -LiteralPath $sj22Pure))

    # Symlinked skills.json refused even with -Force
    $uh22Sym = Join-Path $sandbox 'u22sym'
    $pr22Sym = Join-Path $uh22Sym '.gemini\config\plugins\b3-ai-engineering'
    $sj22SymDir = Join-Path $uh22Sym '.gemini\config\skills.json'
    $sj22SymTgt = Join-Path $uh22Sym 'sym-target'
    New-Item -ItemType Directory -Path (Split-Path -Parent $sj22SymDir) -Force | Out-Null
    New-Item -ItemType Directory -Path $sj22SymTgt -Force | Out-Null
    New-Item -ItemType Junction -Path $sj22SymDir -Target $sj22SymTgt | Out-Null
    $in22Sym = Invoke-PsScript $agPs @('install', '-PluginRoot', $pr22Sym, '-UserHome', $uh22Sym, '-Force')

    $sh22Ok = $true
    if ($hasBash) {
        $uh22s = Join-Path $sandbox 'u22sh'
        $pr22s = Join-Path $uh22s '.gemini\config\plugins\b3-ai-engineering'
        $sj22s = Join-Path $uh22s '.gemini\config\skills.json'
        $pr22sp = $pr22s -replace '\\', '/'
        $uh22sp = $uh22s -replace '\\', '/'
        New-Item -ItemType Directory -Path (Split-Path -Parent $sj22s) -Force | Out-Null
        [System.IO.File]::WriteAllText($sj22s, $seedSj22, (New-Object System.Text.UTF8Encoding($false)))
        $shIn22 = Invoke-ShScript $agShPosix "install --plugin-root '$pr22sp' --user-home '$uh22sp'"
        $shVer22 = Invoke-ShScript $agShPosix "verify --plugin-root '$pr22sp' --user-home '$uh22sp'"
        $sj22sObj = Get-Content -LiteralPath $sj22s -Raw | ConvertFrom-Json
        $sj22sPaths = @($sj22sObj.entries | ForEach-Object { [string]$_.path })
        [System.IO.File]::WriteAllText($sj22s, "{bad`n", (New-Object System.Text.UTF8Encoding($false)))
        $shUp22Bad = Invoke-ShScript $agShPosix "update --plugin-root '$pr22sp' --user-home '$uh22sp'"
        $shUp22Force = Invoke-ShScript $agShPosix "update --plugin-root '$pr22sp' --user-home '$uh22sp' --force"
        [System.IO.File]::WriteAllText($sj22s, $seedSj22, (New-Object System.Text.UTF8Encoding($false)))
        $shUp22Reseed = Invoke-ShScript $agShPosix "update --plugin-root '$pr22sp' --user-home '$uh22sp'"
        $shUn22 = Invoke-ShScript $agShPosix "uninstall --plugin-root '$pr22sp' --user-home '$uh22sp'"
        $sj22sPostUn = Get-Content -LiteralPath $sj22s -Raw | ConvertFrom-Json

        $uh22spure = Join-Path $sandbox 'u22shpure'
        $pr22spure = Join-Path $uh22spure '.gemini\config\plugins\b3-ai-engineering'
        $sj22spure = Join-Path $uh22spure '.gemini\config\skills.json'
        $shInPure = Invoke-ShScript $agShPosix "install --plugin-root '$($pr22spure -replace '\\', '/')' --user-home '$($uh22spure -replace '\\', '/')'"
        $shUnPure = Invoke-ShScript $agShPosix "uninstall --plugin-root '$($pr22spure -replace '\\', '/')' --user-home '$($uh22spure -replace '\\', '/')'"

        # Bash legacy pre-manifest uninstall removes B3 entries from skills.json
        $uh22sleg = Join-Path $sandbox 'u22shleg'
        $pr22sleg = Join-Path $uh22sleg '.gemini\config\plugins\b3-ai-engineering'
        $sj22sleg = Join-Path $uh22sleg '.gemini\config\skills.json'
        $shInLeg = Invoke-ShScript $agShPosix "install --plugin-root '$($pr22sleg -replace '\\', '/')' --user-home '$($uh22sleg -replace '\\', '/')'"
        Remove-Item -LiteralPath (Join-Path $pr22sleg '.b3-plugin-manifest') -Force
        $shUnLeg = Invoke-ShScript $agShPosix "uninstall --plugin-root '$($pr22sleg -replace '\\', '/')' --user-home '$($uh22sleg -replace '\\', '/')'"

        $sh22Ok = ($shIn22.Code -eq 0) -and ($shVer22.Code -eq 0) -and ($shVer22.Text -match 'check\.skills_json=OK') -and
                  ($sj22sObj.note -eq 'keep-top') -and ($sj22sPaths -contains 'D:/my-custom-skills') -and
                  ($sj22sPaths -notcontains "$b3Fwd/skills/removed-cat") -and ($sj22sPaths -contains "$b3Fwd/skills/engineering") -and
                  ($shUp22Bad.Code -eq 1) -and ($shUp22Force.Code -eq 0) -and ($shUp22Reseed.Code -eq 0) -and
                  ($shUn22.Code -eq 0) -and (@($sj22sPostUn.entries).Count -eq 1) -and ($sj22sPostUn.entries[0].path -eq 'D:/my-custom-skills') -and
                  ($shInPure.Code -eq 0) -and ($shUnPure.Code -eq 0) -and (-not (Test-Path -LiteralPath $sj22spure)) -and
                  ($shInLeg.Code -eq 0) -and ($shUnLeg.Code -eq 0) -and (-not (Test-Path -LiteralPath $sj22sleg))
    }

    if ($merge22Ok -and $ver22BadOk -and ($up22Heal.Code -eq 0) -and ($ver22Healed.Code -eq 0) -and
        ($ver22Missing.Code -eq 1) -and ($up22Corrupt.Code -eq 1) -and ($up22Force.Code -eq 0) -and ($up22ReSeed.Code -eq 0) -and
        $un22PreserveOk -and $pureDeletedOk -and ($in22Sym.Code -eq 1) -and $sh22Ok) {
        Pass 'ag-global-skills-json-lifecycle'
    } else {
        FailCheck 'ag-global-skills-json-lifecycle' "merge=$merge22Ok vBad=$ver22BadOk vMiss=$($ver22Missing.Code) corr=$($up22Corrupt.Code)/$($up22Force.Code) unPres=$un22PreserveOk pureDel=$pureDeletedOk sym=$($in22Sym.Code) sh=$sh22Ok"
    }

}
finally {
    Pop-Location -ErrorAction SilentlyContinue
    Remove-ReparseLinksUnder $sandbox
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Complete-ValidationSuite -AllowIncompleteBash:$AllowIncompleteBash
