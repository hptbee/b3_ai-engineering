# Behavioral validation suite for global Cursor installation (install-global.ps1 & install-global.sh).
# Exercises filesystem links, generated artifacts, conflicts, updates, paths with spaces, unrelated repos, manifest corruption, and uninstall in isolated sandboxes.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate-cursor-global.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\global-test-helpers.ps1')

$root = Split-Path -Parent $PSScriptRoot
$instPs = Join-Path $root 'adapters\cursor\install-global.ps1'
$instShPosix = ($root -replace '\\', '/') + '/adapters/cursor/install-global.sh'
$hasBash = $script:HasBash

function Invoke-PsGlobal([string[]]$ScriptArgs) { return Invoke-PsScript $instPs $ScriptArgs }
function Invoke-ShGlobal([string]$ScriptPosix, [string]$ArgsLine) { return Invoke-ShScript $ScriptPosix $ArgsLine }

function Add-CustomUserArtifacts([string]$CursorHome) {
    $mySkill = Join-Path $CursorHome 'skills\my-custom-skill'
    New-Item -ItemType Directory -Path $mySkill -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $mySkill 'SKILL.md') "---`nname: my-custom-skill`ndescription: user custom`n---`n# user`n"
    $cmdDir = Join-Path $CursorHome 'commands'
    New-Item -ItemType Directory -Path $cmdDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $cmdDir 'my-cmd.md') "# user cmd`n"
    $agDir = Join-Path $CursorHome 'agents'
    New-Item -ItemType Directory -Path $agDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $agDir 'my-agent.md') "# user agent`n"
}

$expectedSkillsCount = @(Get-ChildItem -LiteralPath (Join-Path $root 'skills') -Recurse -Filter 'SKILL.md' -File).Count
$sandbox = Join-Path $env:TEMP ('b3-cursor-global-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $sandbox | Out-Null

try {
    # --- 1. cursor-global-dry-run ---
    $uh1 = Join-Path $sandbox 'u1'
    $ch1 = Join-Path $uh1 '.cursor'
    $drPs = Invoke-PsGlobal @('install', '-CursorHome', $ch1, '-UserHome', $uh1, '-DryRun')
    $shDrOk = $true
    if ($hasBash) {
        $ch1p = $ch1 -replace '\\', '/'
        $uh1p = $uh1 -replace '\\', '/'
        $drSh = Invoke-ShGlobal $instShPosix "install --cursor-home '$ch1p' --user-home '$uh1p' --dry-run"
        $shDrOk = ($drSh.Code -eq 0) -and ($drSh.Text -match 'DRY_RUN_OK:')
    }
    if ($drPs.Code -eq 0 -and ($drPs.Text -match 'DRY_RUN_OK:') -and (-not (Test-Path -LiteralPath $ch1)) -and $shDrOk) {
        Pass 'cursor-global-dry-run'
    } else {
        FailCheck 'cursor-global-dry-run' "psCode=$($drPs.Code) exists=$(Test-Path -LiteralPath $ch1) shOk=$shDrOk"
    }

    # --- 2. cursor-global-fresh-install ---
    $uh2 = Join-Path $sandbox 'u2'
    $ch2 = Join-Path $uh2 '.cursor'
    $in2 = Invoke-PsGlobal @('install', '-CursorHome', $ch2, '-UserHome', $uh2)
    $ver2Ps = Invoke-PsGlobal @('verify', '-CursorHome', $ch2, '-UserHome', $uh2)
    $ver2ShOk = $true
    if ($hasBash) {
        $ch2p = $ch2 -replace '\\', '/'
        $uh2p = $uh2 -replace '\\', '/'
        $ver2Sh = Invoke-ShGlobal $instShPosix "verify --cursor-home '$ch2p' --user-home '$uh2p'"
        $ver2ShOk = ($ver2Sh.Code -eq 0) -and ($ver2Sh.Text -match 'VERIFY_OK:')
    }
    $skillDirs2 = @(Get-ChildItem -LiteralPath (Join-Path $ch2 'skills') -Force -ErrorAction SilentlyContinue)
    $cmdFiles2 = @(Get-ChildItem -LiteralPath (Join-Path $ch2 'commands') -Filter 'b3-*.md' -File -ErrorAction SilentlyContinue)
    $agFiles2 = @(Get-ChildItem -LiteralPath (Join-Path $ch2 'agents') -Filter 'b3-*.md' -File -ErrorAction SilentlyContinue)
    $noCmdSkillInSkills = -not (Test-Path -LiteralPath (Join-Path $ch2 'skills\b3-ship')) -and -not (Test-Path -LiteralPath (Join-Path $ch2 'skills\b3-plan'))
    $revText2 = Get-Content -LiteralPath (Join-Path $ch2 'agents\b3-reviewer.md') -Raw
    $rulesLen2 = ([IO.File]::ReadAllBytes((Join-Path $ch2 'b3-user-rules.txt'))).Length
    if ($in2.Code -eq 0 -and $ver2Ps.Code -eq 0 -and $ver2ShOk -and
        $skillDirs2.Count -eq $expectedSkillsCount -and $noCmdSkillInSkills -and
        $cmdFiles2.Count -eq 7 -and $agFiles2.Count -eq 5 -and
        ($revText2 -match '(?m)^model:\s*inherit\s*$') -and ($revText2 -notmatch 'claude-|gpt-|gemini-') -and
        $rulesLen2 -le 1200 -and ($ver2Ps.Text -match 'UNKNOWN / INCOMPLETE')) {
        Pass 'cursor-global-fresh-install'
    } else {
        FailCheck 'cursor-global-fresh-install' "in=$($in2.Code) ver=$($ver2Ps.Code) sh=$ver2ShOk skills=$($skillDirs2.Count)/$expectedSkillsCount cmds=$($cmdFiles2.Count) ags=$($agFiles2.Count) rulesB=$rulesLen2"
    }

    # --- 3. cursor-global-idempotent (repeated install + unrelated user config untouched) ---
    Add-CustomUserArtifacts $ch2
    $in2Again = Invoke-PsGlobal @('install', '-CursorHome', $ch2, '-UserHome', $uh2)
    $ver2Again = Invoke-PsGlobal @('verify', '-CursorHome', $ch2, '-UserHome', $uh2)
    $customKept = (Get-Content -LiteralPath (Join-Path $ch2 'commands\my-cmd.md') -Raw) -match 'user cmd' -and
                  (Test-Path -LiteralPath (Join-Path $ch2 'skills\my-custom-skill\SKILL.md')) -and
                  (Test-Path -LiteralPath (Join-Path $ch2 'agents\my-agent.md'))
    if ($in2Again.Code -eq 0 -and $ver2Again.Code -eq 0 -and $customKept) {
        Pass 'cursor-global-idempotent'
    } else {
        FailCheck 'cursor-global-idempotent' "in=$($in2Again.Code) ver=$($ver2Again.Code) customKept=$customKept"
    }

    # --- 4. cursor-global-update-and-prune ---
    $b3Copy = Join-Path $sandbox 'b3-copy'
    Copy-B3Snapshot $b3Copy
    $uh4 = Join-Path $sandbox 'u4'
    $ch4 = Join-Path $uh4 '.cursor'
    $copyPs = Join-Path $b3Copy 'adapters\cursor\install-global.ps1'
    $copyShPosix = ($b3Copy -replace '\\', '/') + '/adapters/cursor/install-global.sh'
    $in4 = & powershell -NoProfile -ExecutionPolicy Bypass -File $copyPs -Action install -B3Home $b3Copy -CursorHome $ch4 -UserHome $uh4 2>&1
    $in4Exit = $LASTEXITCODE
    Add-CustomUserArtifacts $ch4
    # Mutate b3-copy: add skill, edit command, remove skill
    New-Item -ItemType Directory -Path (Join-Path $b3Copy 'skills\engineering\demo-extra') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $b3Copy 'skills\engineering\demo-extra\SKILL.md') "---`nname: demo-extra`ndescription: extra skill`n---`n# demo`n"
    Add-Content -LiteralPath (Join-Path $b3Copy 'commands\b3-plan.md') "`n<!-- updated line -->"
    Remove-Item -LiteralPath (Join-Path $b3Copy 'skills\engineering\refactoring') -Recurse -Force
    $up4 = & powershell -NoProfile -ExecutionPolicy Bypass -File $copyPs -Action update -B3Home $b3Copy -CursorHome $ch4 -UserHome $uh4 2>&1
    $up4Exit = $LASTEXITCODE
    $ver4 = & powershell -NoProfile -ExecutionPolicy Bypass -File $copyPs -Action verify -B3Home $b3Copy -CursorHome $ch4 -UserHome $uh4 2>&1
    $ver4Exit = $LASTEXITCODE
    $ver4ShOk = $true
    if ($hasBash) {
        $ch4p = $ch4 -replace '\\', '/'
        $uh4p = $uh4 -replace '\\', '/'
        $b3p = $b3Copy -replace '\\', '/'
        $ver4Sh = Invoke-ShGlobal $copyShPosix "verify --b3-home '$b3p' --cursor-home '$ch4p' --user-home '$uh4p'"
        $ver4ShOk = ($ver4Sh.Code -eq 0) -and ($ver4Sh.Text -match 'VERIFY_OK:')
    }
    $extraExists = Test-Path -LiteralPath (Join-Path $ch4 'skills\demo-extra\SKILL.md')
    $prunedGone = -not (Test-Path -LiteralPath (Join-Path $ch4 'skills\refactoring'))
    $planUpdated = (Get-Content -LiteralPath (Join-Path $ch4 'commands\b3-plan.md') -Raw) -match 'updated line'
    $custom4Kept = Test-Path -LiteralPath (Join-Path $ch4 'skills\my-custom-skill\SKILL.md')
    if ($in4Exit -eq 0 -and $up4Exit -eq 0 -and $ver4Exit -eq 0 -and $ver4ShOk -and $extraExists -and $prunedGone -and $planUpdated -and $custom4Kept) {
        Pass 'cursor-global-update-and-prune'
    } else {
        FailCheck 'cursor-global-update-and-prune' "in=$in4Exit up=$up4Exit ver=$ver4Exit sh=$ver4ShOk extra=$extraExists pruned=$prunedGone upd=$planUpdated custom=$custom4Kept"
    }

    # --- 5. cursor-global-conflict-protection (unmanaged files/dirs + legacy b3-ai-engineering migration) ---
    $uh5 = Join-Path $sandbox 'u5'
    $ch5 = Join-Path $uh5 '.cursor'
    New-Item -ItemType Directory -Path (Join-Path $ch5 'skills\code-review'), (Join-Path $ch5 'commands'), (Join-Path $ch5 'agents') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $ch5 'commands\b3-ship.md') "# user custom ship override`n"
    Set-Content -LiteralPath (Join-Path $ch5 'commands\keep-me.md') "# keep`n"
    Set-Content -LiteralPath (Join-Path $ch5 'agents\b3-reviewer.md') "# user custom reviewer`n"
    Set-Content -LiteralPath (Join-Path $ch5 'skills\code-review\SKILL.md') "---`nname: code-review`ndescription: local copy`n---`n"
    & cmd.exe /c mklink /J "`"$(Join-Path $ch5 'skills\b3-ai-engineering')`"" "`"$(Join-Path $root 'skills')`"" | Out-Null
    $j5Exit = $LASTEXITCODE
    $refusePs = Invoke-PsGlobal @('install', '-CursorHome', $ch5, '-UserHome', $uh5)
    $refuseShOk = $true
    if ($hasBash) {
        $ch5p = $ch5 -replace '\\', '/'
        $uh5p = $uh5 -replace '\\', '/'
        $refuseSh = Invoke-ShGlobal $instShPosix "install --cursor-home '$ch5p' --user-home '$uh5p'"
        $refuseShOk = ($refuseSh.Code -eq 1)
    }
    $untouchedAfterRefuse = (Get-Content -LiteralPath (Join-Path $ch5 'commands\b3-ship.md') -Raw) -match 'user custom ship override'
    $forceIn = Invoke-PsGlobal @('install', '-CursorHome', $ch5, '-UserHome', $uh5, '-Force')
    $ver5 = Invoke-PsGlobal @('verify', '-CursorHome', $ch5, '-UserHome', $uh5)
    $migratedGone = -not (Test-Path -LiteralPath (Join-Path $ch5 'skills\b3-ai-engineering'))
    $keepKept5 = Test-Path -LiteralPath (Join-Path $ch5 'commands\keep-me.md')
    if ($j5Exit -eq 0 -and $refusePs.Code -eq 1 -and $refuseShOk -and $untouchedAfterRefuse -and
        $forceIn.Code -eq 0 -and $ver5.Code -eq 0 -and $migratedGone -and $keepKept5) {
        Pass 'cursor-global-conflict-protection'
    } else {
        FailCheck 'cursor-global-conflict-protection' "j=$j5Exit ref=$($refusePs.Code) sh=$refuseShOk unt=$untouchedAfterRefuse f=$($forceIn.Code) ver=$($ver5.Code) mig=$migratedGone"
    }

    # --- 6. cursor-global-stale-and-broken-links ---
    $wrongTarget = Join-Path $sandbox 'wrong-skill-dir'
    New-Item -ItemType Directory -Path $wrongTarget | Out-Null
    & cmd.exe /c rmdir "`"$(Join-Path $ch2 'skills\debugging')`"" | Out-Null
    & cmd.exe /c mklink /J "`"$(Join-Path $ch2 'skills\debugging')`"" "`"$wrongTarget`"" | Out-Null
    Add-Content -LiteralPath (Join-Path $ch2 'commands\b3-debug.md') "`n<!-- tampered -->"
    $verBadPs = Invoke-PsGlobal @('verify', '-CursorHome', $ch2, '-UserHome', $uh2)
    $verBadShOk = $true
    if ($hasBash) {
        $verBadSh = Invoke-ShGlobal $instShPosix "verify --cursor-home '$ch2p' --user-home '$uh2p'"
        $verBadShOk = ($verBadSh.Code -eq 1) -and ($verBadSh.Text -match 'VERIFY_FAIL:')
    }
    $repUp = Invoke-PsGlobal @('update', '-CursorHome', $ch2, '-UserHome', $uh2)
    $verRep = Invoke-PsGlobal @('verify', '-CursorHome', $ch2, '-UserHome', $uh2)
    if ($verBadPs.Code -eq 1 -and ($verBadPs.Text -match 'VERIFY_FAIL:') -and $verBadShOk -and $repUp.Code -eq 0 -and $verRep.Code -eq 0) {
        Pass 'cursor-global-stale-and-broken-links'
    } else {
        FailCheck 'cursor-global-stale-and-broken-links' "bad=$($verBadPs.Code) shBad=$verBadShOk rep=$($repUp.Code) ver=$($verRep.Code)"
    }

    # --- 7. cursor-global-paths-with-spaces (.ps1 + .sh full cycle) ---
    $b3Sp = Join-Path $sandbox 'B3 Home With Spaces'
    Copy-B3Snapshot $b3Sp
    $uhSp = Join-Path $sandbox 'User Home With Spaces'
    $chSp = Join-Path $uhSp '.cursor'
    $spPs = Join-Path $b3Sp 'adapters\cursor\install-global.ps1'
    $spShPosix = ($b3Sp -replace '\\', '/') + '/adapters/cursor/install-global.sh'
    $chSpP = $chSp -replace '\\', '/'
    $uhSpP = $uhSp -replace '\\', '/'
    $b3SpP = $b3Sp -replace '\\', '/'

    & powershell -NoProfile -ExecutionPolicy Bypass -File $spPs -Action install -B3Home $b3Sp -CursorHome $chSp -UserHome $uhSp | Out-Null
    $spPsIn = $LASTEXITCODE
    $spShOk = $true
    if ($hasBash) {
        $spShVer = Invoke-ShGlobal $spShPosix "verify --b3-home '$b3SpP' --cursor-home '$chSpP' --user-home '$uhSpP'"
        $spShUn = Invoke-ShGlobal $spShPosix "uninstall --cursor-home '$chSpP' --user-home '$uhSpP'"
        $spShIn2 = Invoke-ShGlobal $spShPosix "install --b3-home '$b3SpP' --cursor-home '$chSpP' --user-home '$uhSpP'"
        $spShVer2 = Invoke-ShGlobal $spShPosix "verify --b3-home '$b3SpP' --cursor-home '$chSpP' --user-home '$uhSpP'"
        $spShOk = ($spShVer.Code -eq 0) -and ($spShUn.Code -eq 0) -and ($spShIn2.Code -eq 0) -and ($spShVer2.Code -eq 0)
    }
    & powershell -NoProfile -ExecutionPolicy Bypass -File $spPs -Action verify -B3Home $b3Sp -CursorHome $chSp -UserHome $uhSp | Out-Null
    $spPsVerFinal = $LASTEXITCODE
    & powershell -NoProfile -ExecutionPolicy Bypass -File $spPs -Action uninstall -CursorHome $chSp -UserHome $uhSp | Out-Null
    $spPsUnFinal = $LASTEXITCODE
    if ($spPsIn -eq 0 -and $spShOk -and $spPsVerFinal -eq 0 -and $spPsUnFinal -eq 0) {
        Pass 'cursor-global-paths-with-spaces'
    } else {
        FailCheck 'cursor-global-paths-with-spaces' "in=$spPsIn shOk=$spShOk ver=$spPsVerFinal un=$spPsUnFinal"
    }

    # --- 8. cursor-global-unrelated-projects-untouched ---
    $projA = Join-Path $sandbox 'proj-alpha'
    $projB = Join-Path $sandbox 'proj-beta'
    foreach ($pr in @($projA, $projB)) {
        New-TempGitRepo -RepoPath $pr -SubDir '.cursor\rules' -SubFileName 'project.mdc' `
            -SubFileContent "---`ndescription: proj rule`nalwaysApply: true`n---`nUse local project rules." `
            -RootFileName 'AGENTS.md' -RootFileContent "# Project Specific Rules for $(Split-Path -Leaf $pr)"
    }
    $uh8 = Join-Path $sandbox 'u8'
    $ch8 = Join-Path $uh8 '.cursor'
    $in8 = Invoke-PsGlobal @('install', '-CursorHome', $ch8, '-UserHome', $uh8)
    $ver8 = Invoke-PsGlobal @('verify', '-CursorHome', $ch8, '-UserHome', $uh8)
    $stA = ((& git -C $projA status --short) -join '')
    $stB = ((& git -C $projB status --short) -join '')
    $alphaUntouched = ((Get-Content -LiteralPath (Join-Path $projA 'AGENTS.md') -Raw) -match 'proj-alpha') -and (-not (Test-Path -LiteralPath (Join-Path $projA '.b3')))
    $betaUntouched = ((Get-Content -LiteralPath (Join-Path $projB 'AGENTS.md') -Raw) -match 'proj-beta') -and (-not (Test-Path -LiteralPath (Join-Path $projB '.b3')))
    if ($in8.Code -eq 0 -and $ver8.Code -eq 0 -and (-not $stA) -and (-not $stB) -and $alphaUntouched -and $betaUntouched) {
        Pass 'cursor-global-unrelated-projects-untouched'
    } else {
        FailCheck 'cursor-global-unrelated-projects-untouched' "in=$($in8.Code) ver=$($ver8.Code) stA='$stA' stB='$stB'"
    }

    # --- 9. cursor-global-install-product-compat ---
    $projC = Join-Path $sandbox 'proj-gamma'
    New-Item -ItemType Directory -Path $projC | Out-Null
    Push-Location $projC
    & git init -q; & git config user.email 't@e.com'; & git config user.name 'T'
    Set-Content 'README.md' "# Gamma`n"
    & git add .; & git commit -qm 'init'
    Pop-Location
    $instProd = Join-Path $root 'adapters\install-product.ps1'
    & powershell -NoProfile -ExecutionPolicy Bypass -File $instProd -ProductRoot $projC -B3Home $root -HostName cursor | Out-Null
    $ipExit = $LASTEXITCODE
    $ipOk = ($ipExit -eq 0) -and (Test-Path -LiteralPath (Join-Path $projC '.b3\home')) -and (Test-Path -LiteralPath (Join-Path $projC '.cursor\commands\b3-ship.md'))
    if ($ipOk) {
        Pass 'cursor-global-install-product-compat'
    } else {
        FailCheck 'cursor-global-install-product-compat' "exit=$ipExit"
    }

    # --- 10. cursor-global-coexistence-and-uninstall ---
    New-Item -ItemType Directory -Path (Join-Path $uh8 '.agents\skills\code-review') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $uh8 '.agents\skills\code-review\SKILL.md') "---`nname: code-review`ndescription: codex copy`n---`n"
    $coexVer = Invoke-PsGlobal @('verify', '-CursorHome', $ch8, '-UserHome', $uh8)
    $coexWarn = ($coexVer.Text -match 'COEXISTENCE_WARNING:') -and ($coexVer.Code -eq 0)
    Add-CustomUserArtifacts $ch8
    $un8 = Invoke-PsGlobal @('uninstall', '-CursorHome', $ch8, '-UserHome', $uh8)
    $verAfterUn = Invoke-PsGlobal @('verify', '-CursorHome', $ch8, '-UserHome', $uh8)
    $b3Gone = (-not (Test-Path -LiteralPath (Join-Path $ch8 'b3-home'))) -and
              (-not (Test-Path -LiteralPath (Join-Path $ch8 '.b3-global-manifest'))) -and
              (-not (Test-Path -LiteralPath (Join-Path $ch8 'commands\b3-ship.md'))) -and
              (-not (Test-Path -LiteralPath (Join-Path $ch8 'skills\code-review'))) -and
              (-not (Test-Path -LiteralPath (Join-Path $ch8 'agents\b3-reviewer.md')))
    $userArtifactsSafe = (Test-Path -LiteralPath (Join-Path $ch8 'skills\my-custom-skill\SKILL.md')) -and
                         (Test-Path -LiteralPath (Join-Path $ch8 'commands\my-cmd.md')) -and
                         (Test-Path -LiteralPath (Join-Path $ch8 'agents\my-agent.md')) -and
                         (Test-Path -LiteralPath (Join-Path $uh8 '.agents\skills\code-review\SKILL.md'))
    if ($coexWarn -and $un8.Code -eq 0 -and $verAfterUn.Code -eq 1 -and $b3Gone -and $userArtifactsSafe) {
        Pass 'cursor-global-coexistence-and-uninstall'
    } else {
        FailCheck 'cursor-global-coexistence-and-uninstall' "coex=$coexWarn un=$($un8.Code) verAfter=$($verAfterUn.Code) gone=$b3Gone safe=$userArtifactsSafe"
    }

    # --- 11. cursor-global-symlink-boundaries (F1, F2) ---
    $uh11 = Join-Path $sandbox 'u11'
    $liveCuTarget = Join-Path $uh11 'live-cu-target'
    $liveCuLink = Join-Path $uh11 'live-cu-link'
    New-Item -ItemType Directory -Path $liveCuTarget -Force | Out-Null
    & cmd.exe /c mklink /J "`"$liveCuLink`"" "`"$liveCuTarget`"" | Out-Null
    $psLiveIn = Invoke-PsGlobal @('install', '-CursorHome', $liveCuLink, '-UserHome', $uh11, '-Force')
    $psLiveVer = Invoke-PsGlobal @('verify', '-CursorHome', $liveCuLink, '-UserHome', $uh11)
    $psLiveUn = Invoke-PsGlobal @('uninstall', '-CursorHome', $liveCuLink, '-UserHome', $uh11)
    $shLiveOk = $true
    if ($hasBash) {
        $liveCuP = $liveCuLink -replace '\\', '/'
        $uh11p = $uh11 -replace '\\', '/'
        $shLiveIn = Invoke-ShGlobal $instShPosix "install --cursor-home '$liveCuP' --user-home '$uh11p' --force"
        $shLiveVer = Invoke-ShGlobal $instShPosix "verify --cursor-home '$liveCuP' --user-home '$uh11p'"
        $shLiveUn = Invoke-ShGlobal $instShPosix "uninstall --cursor-home '$liveCuP' --user-home '$uh11p'"
        $shLiveOk = ($shLiveIn.Code -eq 1) -and ($shLiveVer.Code -eq 1) -and ($shLiveUn.Code -eq 1)
    }
    $cuTargetEmpty = (@(Get-ChildItem -LiteralPath $liveCuTarget -Force).Count -eq 0)

    $subCu = Join-Path $uh11 'sub-cu'
    $extCmd = Join-Path $uh11 'ext-cmd'
    New-Item -ItemType Directory -Path $subCu, $extCmd | Out-Null
    & cmd.exe /c mklink /J "`"$(Join-Path $subCu 'commands')`"" "`"$extCmd`"" | Out-Null
    $psSubCmd = Invoke-PsGlobal @('install', '-CursorHome', $subCu, '-UserHome', $uh11, '-Force')
    $shSubCmdOk = $true
    if ($hasBash) {
        $subCuP = $subCu -replace '\\', '/'
        $shSubCmd = Invoke-ShGlobal $instShPosix "install --cursor-home '$subCuP' --user-home '$uh11p' --force"
        $shSubCmdOk = ($shSubCmd.Code -eq 1)
    }
    $extCmdUntouched = -not (Test-Path -LiteralPath (Join-Path $extCmd 'b3-ship.md'))
    if ($psLiveIn.Code -eq 1 -and $psLiveVer.Code -eq 1 -and $psLiveUn.Code -eq 1 -and $shLiveOk -and $cuTargetEmpty -and
        $psSubCmd.Code -eq 1 -and $shSubCmdOk -and $extCmdUntouched) {
        Pass 'cursor-global-symlink-boundaries'
    } else {
        FailCheck 'cursor-global-symlink-boundaries' "psLive=$($psLiveIn.Code)/$($psLiveVer.Code)/$($psLiveUn.Code) shLive=$shLiveOk empty=$cuTargetEmpty sub=$($psSubCmd.Code)/$shSubCmdOk ext=$extCmdUntouched"
    }

    # --- 12. cursor-global-uninstall-protects-modified (F4) ---
    $uh12 = Join-Path $sandbox 'u12'
    $ch12 = Join-Path $uh12 '.cursor'
    $dbgTgt12 = Join-Path $uh12 'custom-dbg-ps'
    New-Item -ItemType Directory -Path $dbgTgt12 -Force | Out-Null
    $in12 = Invoke-PsGlobal @('install', '-CursorHome', $ch12, '-UserHome', $uh12)
    Add-Content -LiteralPath (Join-Path $ch12 'commands\b3-plan.md') "`n<!-- user edit -->"
    & cmd.exe /c rmdir "`"$(Join-Path $ch12 'skills\debugging')`"" | Out-Null
    & cmd.exe /c mklink /J "`"$(Join-Path $ch12 'skills\debugging')`"" "`"$dbgTgt12`"" | Out-Null
    $unConf12 = Invoke-PsGlobal @('uninstall', '-CursorHome', $ch12, '-UserHome', $uh12)
    $keptMod12 = ((Get-Content -LiteralPath (Join-Path $ch12 'commands\b3-plan.md') -Raw) -match 'user edit') -and
                 (Test-Path -LiteralPath (Join-Path $ch12 'skills\debugging')) -and
                 (Test-Path -LiteralPath (Join-Path $ch12 '.b3-global-manifest'))
    $unForce12 = Invoke-PsGlobal @('uninstall', '-CursorHome', $ch12, '-UserHome', $uh12, '-Force')
    $clean12 = (-not (Test-Path -LiteralPath (Join-Path $ch12 'commands\b3-plan.md'))) -and
               (-not (Test-Path -LiteralPath (Join-Path $ch12 'skills\debugging'))) -and
               (-not (Test-Path -LiteralPath (Join-Path $ch12 '.b3-global-manifest'))) -and
               (Test-Path -LiteralPath $dbgTgt12)

    $sh12Ok = $true
    if ($hasBash) {
        $uh12s = Join-Path $sandbox 'u12sh'
        $ch12s = Join-Path $uh12s '.cursor'
        $dbgTgt12s = Join-Path $uh12s 'custom-dbg-sh'
        New-Item -ItemType Directory -Path $dbgTgt12s -Force | Out-Null
        $ch12sp = $ch12s -replace '\\', '/'
        $uh12sp = $uh12s -replace '\\', '/'
        $shIn12 = Invoke-ShGlobal $instShPosix "install --cursor-home '$ch12sp' --user-home '$uh12sp'"
        Add-Content -LiteralPath (Join-Path $ch12s 'commands\b3-plan.md') "`n<!-- user edit -->"
        & cmd.exe /c rmdir "`"$(Join-Path $ch12s 'skills\debugging')`"" | Out-Null
        & cmd.exe /c mklink /J "`"$(Join-Path $ch12s 'skills\debugging')`"" "`"$dbgTgt12s`"" | Out-Null
        $shConf12 = Invoke-ShGlobal $instShPosix "uninstall --cursor-home '$ch12sp' --user-home '$uh12sp'"
        $shKept12 = ((Get-Content -LiteralPath (Join-Path $ch12s 'commands\b3-plan.md') -Raw) -match 'user edit') -and
                    (Test-Path -LiteralPath (Join-Path $ch12s 'skills\debugging')) -and
                    (Test-Path -LiteralPath (Join-Path $ch12s '.b3-global-manifest'))
        $shForce12 = Invoke-ShGlobal $instShPosix "uninstall --cursor-home '$ch12sp' --user-home '$uh12sp' --force"
        $shClean12 = (-not (Test-Path -LiteralPath (Join-Path $ch12s 'commands\b3-plan.md'))) -and
                     (-not (Test-Path -LiteralPath (Join-Path $ch12s 'skills\debugging'))) -and
                     (-not (Test-Path -LiteralPath (Join-Path $ch12s '.b3-global-manifest'))) -and
                     (Test-Path -LiteralPath $dbgTgt12s)
        $sh12Ok = ($shIn12.Code -eq 0) -and ($shConf12.Code -eq 1) -and ($shConf12.Text -match 'UNINSTALL_CONFLICT:') -and
                  $shKept12 -and ($shForce12.Code -eq 0) -and $shClean12
    }
    if ($in12.Code -eq 0 -and $unConf12.Code -eq 1 -and ($unConf12.Text -match 'UNINSTALL_CONFLICT:') -and
        $keptMod12 -and $unForce12.Code -eq 0 -and $clean12 -and $sh12Ok) {
        Pass 'cursor-global-uninstall-protects-modified'
    } else {
        FailCheck 'cursor-global-uninstall-protects-modified' "in=$($in12.Code) conf=$($unConf12.Code) kept=$keptMod12 force=$($unForce12.Code) clean=$clean12 sh=$sh12Ok"
    }

    # --- 13. cursor-global-manifest-corruption ---
    $uh13 = Join-Path $sandbox 'u13'
    $ch13 = Join-Path $uh13 '.cursor'
    $in13 = Invoke-PsGlobal @('install', '-CursorHome', $ch13, '-UserHome', $uh13)
    $manifest13 = Join-Path $ch13 '.b3-global-manifest'
    [System.IO.File]::WriteAllText($manifest13, "schema=corrupt`nbad_line_without_equals`n", (New-Object System.Text.UTF8Encoding($false)))
    $inBad13 = Invoke-PsGlobal @('install', '-CursorHome', $ch13, '-UserHome', $uh13)
    $upBad13 = Invoke-PsGlobal @('update', '-CursorHome', $ch13, '-UserHome', $uh13)
    $verBad13 = Invoke-PsGlobal @('verify', '-CursorHome', $ch13, '-UserHome', $uh13)
    $unBad13 = Invoke-PsGlobal @('uninstall', '-CursorHome', $ch13, '-UserHome', $uh13)
    $kept13 = (Test-Path -LiteralPath (Join-Path $ch13 'commands\b3-plan.md')) -and (Test-Path -LiteralPath $manifest13)

    $sh13Ok = $true
    if ($hasBash) {
        $uh13s = Join-Path $sandbox 'u13sh'
        $ch13s = Join-Path $uh13s '.cursor'
        $ch13sp = $ch13s -replace '\\', '/'
        $uh13sp = $uh13s -replace '\\', '/'
        $shIn13 = Invoke-ShGlobal $instShPosix "install --cursor-home '$ch13sp' --user-home '$uh13sp'"
        $manifest13s = Join-Path $ch13s '.b3-global-manifest'
        [System.IO.File]::WriteAllText($manifest13s, "schema=corrupt`nbad_line_without_equals`n", (New-Object System.Text.UTF8Encoding($false)))
        $shInBad13 = Invoke-ShGlobal $instShPosix "install --cursor-home '$ch13sp' --user-home '$uh13sp'"
        $shUpBad13 = Invoke-ShGlobal $instShPosix "update --cursor-home '$ch13sp' --user-home '$uh13sp'"
        $shVerBad13 = Invoke-ShGlobal $instShPosix "verify --cursor-home '$ch13sp' --user-home '$uh13sp'"
        $shUnBad13 = Invoke-ShGlobal $instShPosix "uninstall --cursor-home '$ch13sp' --user-home '$uh13sp'"
        $shKept13 = (Test-Path -LiteralPath (Join-Path $ch13s 'commands\b3-plan.md')) -and (Test-Path -LiteralPath $manifest13s)
        $sh13Ok = ($shIn13.Code -eq 0) -and ($shInBad13.Code -ne 0) -and ($shUpBad13.Code -ne 0) -and
                  ($shVerBad13.Code -ne 0) -and ($shUnBad13.Code -ne 0) -and $shKept13
    }
    if ($in13.Code -eq 0 -and $inBad13.Code -ne 0 -and $upBad13.Code -ne 0 -and
        $verBad13.Code -ne 0 -and $unBad13.Code -ne 0 -and $kept13 -and $sh13Ok) {
        Pass 'cursor-global-manifest-corruption'
    } else {
        FailCheck 'cursor-global-manifest-corruption' "in=$($in13.Code) i2=$($inBad13.Code) u2=$($upBad13.Code) v2=$($verBad13.Code) un2=$($unBad13.Code) kept=$kept13 sh=$sh13Ok"
    }
}
finally {
    Pop-Location -ErrorAction SilentlyContinue
    Remove-ReparseLinksUnder $sandbox
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Complete-ValidationSuite
