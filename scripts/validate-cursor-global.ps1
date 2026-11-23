# Behavioral validation suite for global Cursor installation (install-global.ps1 & install-global.sh).
# Exercises filesystem links, generated artifacts, conflicts, updates, paths with spaces, unrelated repos, and uninstall in isolated sandboxes.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate-cursor-global.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$instPs = Join-Path $root 'adapters\cursor\install-global.ps1'
$instShPosix = ($root -replace '\\', '/') + '/adapters/cursor/install-global.sh'
$gitBash = 'C:\Program Files\Git\bin\bash.exe'
$hasBash = Test-Path -LiteralPath $gitBash -PathType Leaf
$failed = 0

function Pass([string]$Name) { Write-Output "PASS $Name" }
function FailCheck([string]$Name, [string]$Detail) {
    Write-Output "FAIL $Name :: $Detail"
    $script:failed++
}

function Invoke-PsGlobal([string[]]$ScriptArgs) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & powershell -NoProfile -ExecutionPolicy Bypass -File $instPs @ScriptArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    $lines = @($raw | ForEach-Object { ([string]$_).TrimEnd("`r") })
    return @{ Code = $code; Lines = $lines; Text = ($lines -join "`n") }
}

function Invoke-ShGlobal([string]$ScriptPosix, [string]$ArgsLine) {
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
    New-Item -ItemType Directory -Path (Join-Path $DestDir 'adapters\cursor') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'adapters\cursor\install-global.ps1') -Destination (Join-Path $DestDir 'adapters\cursor\install-global.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $root 'adapters\cursor\install-global.sh') -Destination (Join-Path $DestDir 'adapters\cursor\install-global.sh') -Force
}

function Remove-ReparseLinksUnder([string]$DirPath) {
    if (-not (Test-Path -LiteralPath $DirPath)) { return }
    # Remove junction/symlink directories before recursive delete so target trees are never traversed
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
        New-Item -ItemType Directory -Path (Join-Path $pr '.cursor\rules') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $pr 'AGENTS.md') "# Project Specific Rules for $(Split-Path -Leaf $pr)`n"
        Set-Content -LiteralPath (Join-Path $pr '.cursor\rules\project.mdc') "---`ndescription: proj rule`nalwaysApply: true`n---`nUse local project rules.`n"
        Push-Location $pr
        & git init -q; & git config user.email 't@e.com'; & git config user.name 'T'
        & git add .; & git commit -qm 'init'
        Pop-Location
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
Write-Output 'ok'
exit 0
