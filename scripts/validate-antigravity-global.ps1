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
$hasBash = Test-Path -LiteralPath $gitBash -PathType Leaf
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
    $revText2 = Get-Content -LiteralPath (Join-Path $pr2 'agents\b3-reviewer.md') -Raw
    $rulesText2 = Get-Content -LiteralPath (Join-Path $pr2 'rules\AGENTS.md') -Raw
    $hasAllCmds = $true
    foreach ($cmd in @('b3-plan', 'b3-implement', 'b3-debug', 'b3-review', 'b3-verify', 'b3-review-loop', 'b3-ship')) {
        if (-not (Test-Path -LiteralPath (Join-Path $pr2 "skills\$cmd\SKILL.md") -PathType Leaf)) { $hasAllCmds = $false }
    }
    $noHardcodedModel = ($revText2 -notmatch '(?m)^model:') -and ($revText2 -notmatch 'claude-|gpt-|gemini-[0-9]')
    $rulesPrecOk = ($rulesText2 -match 'Project-level AGENTS\.md') -and ($rulesText2 -match 'install-product is optional')
    if ($in2.Code -eq 0 -and $ver2Ps.Code -eq 0 -and $ver2ShOk -and
        ($ver2Ps.Text -match 'check\.plugin=OK') -and ($ver2Ps.Text -match 'check\.commands=OK') -and
        ($ver2Ps.Text -match 'UNKNOWN / INCOMPLETE') -and
        $skillDirs2.Count -eq $expectedTotalSkills -and $hasAllCmds -and $agFiles2.Count -eq 5 -and
        $noHardcodedModel -and $rulesPrecOk) {
        Pass 'ag-global-fresh-install'
    } else {
        FailCheck 'ag-global-fresh-install' "in=$($in2.Code) ver=$($ver2Ps.Code) sh=$ver2ShOk skills=$($skillDirs2.Count)/$expectedTotalSkills cmds=$hasAllCmds ags=$($agFiles2.Count) model=$noHardcodedModel"
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
    $refNonB3 = Invoke-PsScript $agPs @('install', '-PluginRoot', $pr5NonB3, '-UserHome', $uh5)
    $refShOk = $true
    if ($hasBash) {
        $pr5p = $pr5NonB3 -replace '\\', '/'
        $uh5p = $uh5 -replace '\\', '/'
        $refSh = Invoke-ShScript $agShPosix "install --plugin-root '$pr5p' --user-home '$uh5p'"
        $refShOk = ($refSh.Code -eq 1)
    }
    $forceNonB3 = Invoke-PsScript $agPs @('install', '-PluginRoot', $pr5NonB3, '-UserHome', $uh5, '-Force')
    # Inject non-link dir under skills/ and check refusal without -Force
    & cmd.exe /c rmdir "`"$(Join-Path $pr5NonB3 'skills\verification')`"" | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $pr5NonB3 'skills\verification') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $pr5NonB3 'skills\verification\SKILL.md') "---`nname: verification`ndescription: local`n---`n"
    $refNonLink = Invoke-PsScript $agPs @('install', '-PluginRoot', $pr5NonB3, '-UserHome', $uh5)
    $forceNonLink = Invoke-PsScript $agPs @('install', '-PluginRoot', $pr5NonB3, '-UserHome', $uh5, '-Force')
    $ver5 = Invoke-PsScript $agPs @('verify', '-PluginRoot', $pr5NonB3, '-UserHome', $uh5)
    if ($refFile.Code -eq 1 -and $refNonB3.Code -eq 1 -and $refShOk -and (Test-Path -LiteralPath (Join-Path $pr5NonB3 'keep.txt')) -and
        $forceNonB3.Code -eq 0 -and $refNonLink.Code -eq 1 -and $forceNonLink.Code -eq 0 -and $ver5.Code -eq 0) {
        Pass 'ag-global-conflict-protection'
    } else {
        FailCheck 'ag-global-conflict-protection' "file=$($refFile.Code) nonB3=$($refNonB3.Code) sh=$refShOk f1=$($forceNonB3.Code) nl=$($refNonLink.Code) f2=$($forceNonLink.Code) v=$($ver5.Code)"
    }

    # --- 6. ag-global-stale-broken-and-drift (per-surface failure diagnostics + heal) ---
    $b3Drift = Join-Path $sandbox 'b3-drift'
    Copy-B3Snapshot $b3Drift
    $uh6 = Join-Path $sandbox 'u6'
    $pr6 = Join-Path $uh6 '.gemini\config\plugins\b3-ai-engineering'
    $drPsPath = Join-Path $b3Drift 'adapters\antigravity\install-plugin.ps1'
    $drShPosix = ($b3Drift -replace '\\', '/') + '/adapters/antigravity/install-plugin.sh'
    $in6 = Invoke-PsScript $drPsPath @('install', '-B3Home', $b3Drift, '-PluginRoot', $pr6, '-UserHome', $uh6)

    Add-Content -LiteralPath (Join-Path $pr6 'rules\AGENTS.md') "`n<!-- drifted -->"
    $vRulesBad = Invoke-PsScript $drPsPath @('verify', '-B3Home', $b3Drift, '-PluginRoot', $pr6, '-UserHome', $uh6)
    $rulesFailReported = ($vRulesBad.Code -eq 1) -and ($vRulesBad.Text -match 'check\.rules=FAIL') -and ($vRulesBad.Text -match 'check\.skills=OK')

    $healRules = Invoke-PsScript $drPsPath @('update', '-B3Home', $b3Drift, '-PluginRoot', $pr6, '-UserHome', $uh6)
    Add-Content -LiteralPath (Join-Path $pr6 'agents\b3-reviewer.md') "`n<!-- drifted -->"
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
    if ($in6.Code -eq 0 -and $rulesFailReported -and $healRules.Code -eq 0 -and $multiFailReported -and $shBadOk -and $healAll.Code -eq 0 -and $verHealed.Code -eq 0) {
        Pass 'ag-global-stale-broken-and-drift'
    } else {
        FailCheck 'ag-global-stale-broken-and-drift' "rules=$rulesFailReported multi=$multiFailReported sh=$shBadOk healed=$($verHealed.Code)"
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

    # --- 10. ag-global-coexistence-and-uninstall (preserves config.json & user notes) ---
    New-Item -ItemType Directory -Path (Join-Path $uh8 '.gemini\config\skills\verification') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $uh8 '.gemini\config\skills\verification\SKILL.md') "---`nname: verification`ndescription: loose`n---`n"
    New-Item -ItemType Directory -Path (Join-Path $uh8 '.gemini\config\plugins\b3-dup') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $uh8 '.gemini\config\plugins\b3-dup\plugin.json') '{"name":"b3-ai-engineering"}'
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
    if ($coexVer.Code -eq 0 -and $warnMatches -eq 3 -and $unDr.Code -eq 0 -and $stillThereAfterDr -and
        $un8.Code -eq 0 -and ($cfgSha0 -eq $cfgSha1) -and $userKept10 -and $managedGone10) {
        Pass 'ag-global-coexistence-and-uninstall'
    } else {
        FailCheck 'ag-global-coexistence-and-uninstall' "warns=$warnMatches dr=$($unDr.Code)/$stillThereAfterDr un=$($un8.Code) cfg=$($cfgSha0 -eq $cfgSha1) user=$userKept10 gone=$managedGone10"
    }

    # --- 11. unified-install-global-dispatcher (cursor, antigravity, all across PS & Bash) ---
    $uhUniC = Join-Path $sandbox 'u-uni-cursor'
    $uC1 = Invoke-PsScript $uniPs @('-HostName', 'cursor', '-UserHome', $uhUniC)
    $uCOnly = (Test-Path -LiteralPath (Join-Path $uhUniC '.cursor\skills\verification\SKILL.md')) -and (-not (Test-Path -LiteralPath (Join-Path $uhUniC '.gemini\config\plugins\b3-ai-engineering')))

    $uhUniA = Join-Path $sandbox 'u-uni-ag'
    $uA1 = Invoke-PsScript $uniPs @('-HostName', 'antigravity', '-UserHome', $uhUniA)
    $uAOnly = (Test-Path -LiteralPath (Join-Path $uhUniA '.gemini\config\plugins\b3-ai-engineering\plugin.json')) -and (-not (Test-Path -LiteralPath (Join-Path $uhUniA '.cursor')))

    $uhAll = Join-Path $sandbox 'u-uni-all'
    $allDr = Invoke-PsScript $uniPs @('-HostName', 'all', '-UserHome', $uhAll, '-DryRun')
    $allDrClean = (-not (Test-Path -LiteralPath (Join-Path $uhAll '.cursor'))) -and (-not (Test-Path -LiteralPath (Join-Path $uhAll '.gemini')))
    $allIn = Invoke-PsScript $uniPs @('-HostName', 'all', '-UserHome', $uhAll)
    $allVer = Invoke-PsScript $uniPs @('verify', '-HostName', 'all', '-UserHome', $uhAll)
    $noCoexConflict = -not ($allVer.Text -match 'COEXISTENCE_WARNING:')

    $shAllOk = $true
    if ($hasBash) {
        $uhAllP = $uhAll -replace '\\', '/'
        $shAllVer = Invoke-ShScript $uniShPosix "verify --host all --user-home '$uhAllP'"
        $shAllUp = Invoke-ShScript $uniShPosix "update --host all --user-home '$uhAllP'"
        $shAllUn = Invoke-ShScript $uniShPosix "uninstall --host all --user-home '$uhAllP'"
        $shAllOk = ($shAllVer.Code -eq 0) -and ($shAllVer.Text -match 'GLOBAL_OK:') -and
                   ($shAllUp.Code -eq 0) -and ($shAllUp.Text -match 'GLOBAL_OK:') -and
                   ($shAllUn.Code -eq 0) -and ($shAllUn.Text -match 'GLOBAL_OK:')
    } else {
        $psAllUn = Invoke-PsScript $uniPs @('uninstall', '-HostName', 'all', '-UserHome', $uhAll)
        $shAllOk = ($psAllUn.Code -eq 0)
    }
    $allGone = (-not (Test-Path -LiteralPath (Join-Path $uhAll '.cursor\skills\verification'))) -and
               (-not (Test-Path -LiteralPath (Join-Path $uhAll '.gemini\config\plugins\b3-ai-engineering')))
    if ($uC1.Code -eq 0 -and $uCOnly -and $uA1.Code -eq 0 -and $uAOnly -and
        $allDr.Code -eq 0 -and $allDrClean -and $allIn.Code -eq 0 -and $allVer.Code -eq 0 -and
        ($allVer.Text -match 'GLOBAL_OK:') -and $noCoexConflict -and $shAllOk -and $allGone) {
        Pass 'unified-install-global-dispatcher'
    } else {
        FailCheck 'unified-install-global-dispatcher' "c=$($uC1.Code)/$uCOnly a=$($uA1.Code)/$uAOnly dr=$allDrClean all=$($allIn.Code)/$($allVer.Code) noWarn=$noCoexConflict sh=$shAllOk gone=$allGone"
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
