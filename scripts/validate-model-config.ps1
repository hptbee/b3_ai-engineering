# Focused dual-shell behavioral validation suite for User-Customizable Model Configuration.
# Tests resolve-models precedence, "auto" fallback, partial/unknown/invalid JSON, missing files, installer seeding & preservation, and .gitignore rules across PowerShell and Git Bash.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate-model-config.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$guardPs = Join-Path $root 'scripts\b3-guard.ps1'
$guardShPosix = ($root -replace '\\', '/') + '/scripts/b3-guard.sh'
$gitBash = 'C:\Program Files\Git\bin\bash.exe'
$hasBash = Test-Path -LiteralPath $gitBash -PathType Leaf
if (-not $hasBash) {
    Write-Output "WARNING: Git Bash not found at $gitBash; Bash checks skipped"
}
$failed = 0

function Pass([string]$Name) { Write-Output "PASS $Name" }
function FailCheck([string]$Name, [string]$Detail) {
    Write-Output "FAIL $Name :: $Detail"
    $script:failed++
}

function Invoke-GuardPs([string[]]$ScriptArgs) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & powershell -NoProfile -ExecutionPolicy Bypass -File $guardPs @ScriptArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    $lines = @($raw | ForEach-Object { ([string]$_).TrimEnd("`r") })
    return @{ Code = $code; Lines = $lines; Text = ($lines -join "`n") }
}

function Invoke-GuardSh([string]$ArgsLine) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & $gitBash -c "'$guardShPosix' $ArgsLine" 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    $lines = @($raw | ForEach-Object { ([string]$_).TrimEnd("`r") })
    return @{ Code = $code; Lines = $lines; Text = ($lines -join "`n") }
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

$expectedRoles = @(
    'main', 'planning', 'implementation', 'debugging',
    'b3-reviewer', 'b3-fixer', 'b3-security-reviewer',
    'b3-architecture-reviewer', 'b3-performance-reviewer'
)

$sandbox = Join-Path $env:TEMP ('b3-model-cfg-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $sandbox | Out-Null
$prevModelsPersonal = $env:B3_MODELS_PERSONAL

try {
    $missingPers = Join-Path $sandbox 'missing-personal.json'
    $missingProj = Join-Path $sandbox 'missing-project.json'
    $env:B3_MODELS_PERSONAL = $missingPers
    $missingPersP = $missingPers -replace '\\', '/'
    $missingProjP = $missingProj -replace '\\', '/'
    $rootP = $root -replace '\\', '/'

    # --- 1. model-config-defaults ---
    $r1Ps = Invoke-GuardPs @('resolve-models', '-B3Home', $root, '-PersonalConfig', $missingPers, '-ProjectConfig', $missingProj, '-Json')
    $j1 = $r1Ps.Text | ConvertFrom-Json
    $allDefAuto = $true
    foreach ($rn in $expectedRoles) {
        $entry = $j1.roles.$rn
        if (-not $entry -or $entry.model -ne 'auto' -or $entry.effective -ne 'platform_default' -or $entry.source -ne 'default') {
            $allDefAuto = $false
        }
    }
    $r1ShOk = $true
    if ($hasBash) {
        $r1Sh = Invoke-GuardSh "resolve-models --b3-home '$rootP' --personal-config '$missingPersP' --project-config '$missingProjP' --json"
        $r1ShOk = ($r1Sh.Code -eq 0) -and ((($r1Sh.Text | ConvertFrom-Json).roles.'b3-reviewer'.source) -eq 'default')
    }
    if ($r1Ps.Code -eq 0 -and $j1.sources.default_present -and (-not $j1.sources.personal_present) -and (-not $j1.sources.project_present) -and $allDefAuto -and $r1ShOk) {
        Pass 'model-config-defaults'
    } else {
        FailCheck 'model-config-defaults' "ps=$($r1Ps.Code) sh=$r1ShOk allAuto=$allDefAuto"
    }

    # --- 2. model-config-personal-override (partial override inherits defaults) ---
    $pers2 = Join-Path $sandbox 'pers2.json'
    Set-Content -LiteralPath $pers2 '{"version":1,"models":{"planning":"reason-v1","b3-reviewer":"deep-review"}}'
    $pers2P = $pers2 -replace '\\', '/'
    $r2Ps = Invoke-GuardPs @('resolve-models', '-B3Home', $root, '-PersonalConfig', $pers2, '-ProjectConfig', $missingProj, '-Json')
    $j2 = $r2Ps.Text | ConvertFrom-Json
    $r2Ok = ($r2Ps.Code -eq 0) -and
            ($j2.roles.planning.model -eq 'reason-v1') -and ($j2.roles.planning.source -eq 'personal') -and
            ($j2.roles.'b3-reviewer'.model -eq 'deep-review') -and ($j2.roles.'b3-reviewer'.source -eq 'personal') -and
            ($j2.roles.'b3-fixer'.model -eq 'auto') -and ($j2.roles.'b3-fixer'.source -eq 'default')
    $r2ShOk = $true
    if ($hasBash) {
        $r2Sh = Invoke-GuardSh "resolve-models --b3-home '$rootP' --personal-config '$pers2P' --project-config '$missingProjP' --json"
        $j2s = $r2Sh.Text | ConvertFrom-Json
        $r2ShOk = ($r2Sh.Code -eq 0) -and ($j2s.roles.planning.model -eq 'reason-v1') -and ($j2s.roles.'b3-fixer'.source -eq 'default')
    }
    if ($r2Ok -and $r2ShOk) { Pass 'model-config-personal-override' }
    else { FailCheck 'model-config-personal-override' "ps=$r2Ok sh=$r2ShOk" }

    # --- 3. model-config-project-override-and-precedence (explicit > project > personal > default) ---
    $proj3 = Join-Path $sandbox 'proj3.json'
    Set-Content -LiteralPath $proj3 '{"version":1,"models":{"planning":"proj-plan","main":"proj-main"}}'
    $proj3P = $proj3 -replace '\\', '/'
    $r3Ps = Invoke-GuardPs @('resolve-models', '-B3Home', $root, '-PersonalConfig', $pers2, '-ProjectConfig', $proj3, '-Json')
    $j3 = $r3Ps.Text | ConvertFrom-Json
    $r3ExpPs = Invoke-GuardPs @('resolve-models', '-B3Home', $root, '-PersonalConfig', $pers2, '-ProjectConfig', $proj3, '-Role', 'planning', '-ExplicitModel', 'user-picked-model')
    $r3ExpShOk = $true
    if ($hasBash) {
        $r3ExpSh = Invoke-GuardSh "resolve-models --b3-home '$rootP' --personal-config '$pers2P' --project-config '$proj3P' --role planning --explicit-model user-picked-model"
        $r3ExpShOk = ($r3ExpSh.Code -eq 0) -and ($r3ExpSh.Text -match 'effective=user-picked-model source=explicit')
    }
    $precOk = ($r3Ps.Code -eq 0) -and
              ($j3.roles.planning.model -eq 'proj-plan') -and ($j3.roles.planning.source -eq 'project') -and
              ($j3.roles.'b3-reviewer'.model -eq 'deep-review') -and ($j3.roles.'b3-reviewer'.source -eq 'personal') -and
              ($j3.roles.debugging.model -eq 'auto') -and ($j3.roles.debugging.source -eq 'default') -and
              ($r3ExpPs.Code -eq 0) -and ($r3ExpPs.Text -match 'effective=user-picked-model source=explicit') -and $r3ExpShOk
    if ($precOk) { Pass 'model-config-project-override-and-precedence' }
    else { FailCheck 'model-config-project-override-and-precedence' "prec=$precOk sh=$r3ExpShOk" }

    # --- 4. model-config-auto-fallback ("auto" overrides lower-layer concrete model back to platform_default) ---
    $proj4 = Join-Path $sandbox 'proj4.json'
    Set-Content -LiteralPath $proj4 '{"version":1,"models":{"b3-reviewer":"AUTO"}}'
    $proj4P = $proj4 -replace '\\', '/'
    $r4Ps = Invoke-GuardPs @('resolve-models', '-B3Home', $root, '-PersonalConfig', $pers2, '-ProjectConfig', $proj4, '-Role', 'b3-reviewer', '-Json')
    $j4 = $r4Ps.Text | ConvertFrom-Json
    $r4ShOk = $true
    if ($hasBash) {
        $r4Sh = Invoke-GuardSh "resolve-models --b3-home '$rootP' --personal-config '$pers2P' --project-config '$proj4P' --role b3-reviewer --json"
        $j4s = $r4Sh.Text | ConvertFrom-Json
        $r4ShOk = ($r4Sh.Code -eq 0) -and ($j4s.roles.'b3-reviewer'.model -eq 'auto') -and ($j4s.roles.'b3-reviewer'.effective -eq 'platform_default') -and ($j4s.roles.'b3-reviewer'.source -eq 'project')
    }
    if ($r4Ps.Code -eq 0 -and $j4.roles.'b3-reviewer'.model -eq 'auto' -and $j4.roles.'b3-reviewer'.effective -eq 'platform_default' -and $j4.roles.'b3-reviewer'.source -eq 'project' -and $r4ShOk) {
        Pass 'model-config-auto-fallback'
    } else {
        FailCheck 'model-config-auto-fallback' "ps=$($r4Ps.Code) eff=$($j4.roles.'b3-reviewer'.effective) sh=$r4ShOk"
    }

    # --- 5. model-config-unknown-roles (warns cleanly without failing) ---
    $pers5 = Join-Path $sandbox 'pers5-unknown.json'
    Set-Content -LiteralPath $pers5 '{"version":1,"models":{"main":"my-main","custom_role":"my-custom"}}'
    $pers5P = $pers5 -replace '\\', '/'
    $r5Ps = Invoke-GuardPs @('resolve-models', '-B3Home', $root, '-PersonalConfig', $pers5, '-ProjectConfig', $missingProj)
    $r5Query = Invoke-GuardPs @('resolve-models', '-B3Home', $root, '-PersonalConfig', $pers5, '-ProjectConfig', $missingProj, '-Role', 'unregistered_role')
    $r5ShOk = $true
    if ($hasBash) {
        $r5Sh = Invoke-GuardSh "resolve-models --b3-home '$rootP' --personal-config '$pers5P' --project-config '$missingProjP'"
        $r5ShQ = Invoke-GuardSh "resolve-models --b3-home '$rootP' --personal-config '$pers5P' --project-config '$missingProjP' --role unregistered_role"
        $r5ShOk = ($r5Sh.Code -eq 0) -and ($r5Sh.Text -match 'UNKNOWN_ROLE_WARNING: role=custom_role') -and
                  ($r5ShQ.Code -eq 0) -and ($r5ShQ.Text -match 'role=unregistered_role model=auto effective=platform_default source=platform_default')
    }
    if ($r5Ps.Code -eq 0 -and ($r5Ps.Text -match 'UNKNOWN_ROLE_WARNING: role=custom_role') -and ($r5Ps.Text -match 'RESOLVE_MODELS_OK') -and
        $r5Query.Code -eq 0 -and ($r5Query.Text -match 'role=unregistered_role model=auto effective=platform_default source=platform_default') -and $r5ShOk) {
        Pass 'model-config-unknown-roles'
    } else {
        FailCheck 'model-config-unknown-roles' "ps=$($r5Ps.Code) q=$($r5Query.Code) sh=$r5ShOk"
    }

    # --- 6. model-config-invalid-json (malformed syntax, bad version, non-object models, empty/non-string value, extra top key) ---
    $badCases = @{
        'malformed.json'    = '{ "version": 1, "models": {'
        'bad-ver-str.json'  = '{"version":"1","models":{"main":"auto"}}'
        'bad-ver-num.json'  = '{"version":2,"models":{"main":"auto"}}'
        'bad-ver-flt.json'  = '{"version":1.0,"models":{"main":"auto"}}'
        'bad-models.json'   = '{"version":1,"models":[]}'
        'empty-val.json'    = '{"version":1,"models":{"main":"   "}}'
        'num-val.json'      = '{"version":1,"models":{"main":123}}'
        'extra-top.json'    = '{"version":1,"unexpected":true,"models":{"main":"auto"}}'
    }
    $allBadRejected = $true
    foreach ($name in $badCases.Keys) {
        $bp = Join-Path $sandbox $name
        Set-Content -LiteralPath $bp $badCases[$name]
        $bpP = $bp -replace '\\', '/'
        $bPs = Invoke-GuardPs @('resolve-models', '-B3Home', $root, '-PersonalConfig', $bp, '-ProjectConfig', $missingProj)
        if ($bPs.Code -ne 1 -or ($bPs.Text -notmatch 'CONFIG_ERROR:')) { $allBadRejected = $false; break }
        if ($hasBash) {
            $bSh = Invoke-GuardSh "resolve-models --b3-home '$rootP' --personal-config '$bpP' --project-config '$missingProjP'"
            if ($bSh.Code -ne 1 -or ($bSh.Text -notmatch 'CONFIG_ERROR:')) { $allBadRejected = $false; break }
        }
    }
    if ($allBadRejected) { Pass 'model-config-invalid-json' }
    else { FailCheck 'model-config-invalid-json' 'at least one invalid config did not exit 1 with CONFIG_ERROR:' }

    # --- 7. model-config-missing-files (missing all 3 layers falls back to platform_default cleanly) ---
    $fakeB3 = Join-Path $sandbox 'empty-b3'
    New-Item -ItemType Directory -Path $fakeB3 | Out-Null
    $fakeB3P = $fakeB3 -replace '\\', '/'
    $r7Ps = Invoke-GuardPs @('resolve-models', '-B3Home', $fakeB3, '-PersonalConfig', $missingPers, '-ProjectConfig', $missingProj, '-Json')
    $j7 = $r7Ps.Text | ConvertFrom-Json
    $r7ShOk = $true
    if ($hasBash) {
        $r7Sh = Invoke-GuardSh "resolve-models --b3-home '$fakeB3P' --personal-config '$missingPersP' --project-config '$missingProjP' --json"
        $j7s = $r7Sh.Text | ConvertFrom-Json
        $r7ShOk = ($r7Sh.Code -eq 0) -and (-not $j7s.sources.default_present) -and ($j7s.roles.main.source -eq 'platform_default') -and ($j7s.roles.main.effective -eq 'platform_default')
    }
    if ($r7Ps.Code -eq 0 -and (-not $j7.sources.default_present) -and ($j7.roles.main.source -eq 'platform_default') -and ($j7.roles.main.effective -eq 'platform_default') -and $r7ShOk) {
        Pass 'model-config-missing-files'
    } else {
        FailCheck 'model-config-missing-files' "ps=$($r7Ps.Code) sh=$r7ShOk"
    }

    # --- 8. model-config-install-init-and-preserve (sync-skills & install-product seed missing, never overwrite existing) ---
    $prod8 = Join-Path $sandbox 'prod8'
    New-Item -ItemType Directory -Path $prod8 | Out-Null
    Push-Location $prod8
    & git init -q; & git config user.email 't@e.com'; & git config user.name 'T'
    Set-Content 'README.md' "# Prod8`n"
    & git add README.md; & git commit -qm 'init'
    Pop-Location

    $seedTarget = Join-Path $sandbox 'seeded-home\.b3\models.local.json'
    $env:B3_MODELS_PERSONAL = $seedTarget
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'adapters\install-product.ps1') -ProductRoot $prod8 -B3Home $root -HostName cursor -DryRun | Out-Null
    $dryNotCreated = -not (Test-Path -LiteralPath $seedTarget)
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'adapters\install-product.ps1') -ProductRoot $prod8 -B3Home $root -HostName cursor | Out-Null
    $ipExit = $LASTEXITCODE
    $seededCreated = Test-Path -LiteralPath $seedTarget -PathType Leaf
    $noCopyInProd = -not (Test-Path -LiteralPath (Join-Path $prod8 '.b3\models.local.json'))

    # Customize personal file and re-run install-product (PS & Bash) and verify-mode + normal sync-skills
    Set-Content -LiteralPath $seedTarget '{"version":1,"models":{"main":"keep-custom-model"}}'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'adapters\install-product.ps1') -ProductRoot $prod8 -B3Home $root -HostName cursor | Out-Null
    $stillCustomAfterIp = ((Get-Content -LiteralPath $seedTarget -Raw) -match 'keep-custom-model')

    $syncFx = Join-Path $sandbox 'sync-fx'
    New-Item -ItemType Directory -Path (Join-Path $syncFx 'adapters'), (Join-Path $syncFx 'config'), (Join-Path $syncFx 'skills\eng\demo'), (Join-Path $syncFx 'commands'), (Join-Path $syncFx 'agents') | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'adapters\sync-skills.ps1') -Destination (Join-Path $syncFx 'adapters\sync-skills.ps1')
    Copy-Item -LiteralPath (Join-Path $root 'config\models.default.json') -Destination (Join-Path $syncFx 'config\models.default.json')
    Set-Content -LiteralPath (Join-Path $syncFx 'skills\eng\demo\SKILL.md') "---`nname: demo`ndescription: d`n---`n# d`n"
    Set-Content -LiteralPath (Join-Path $syncFx 'commands\b3-plan.md') "# p`n"
    Set-Content -LiteralPath (Join-Path $syncFx 'agents\b3-reviewer.md') "# r`n"
    $env:B3_MODELS_PERSONAL = $seedTarget
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $syncFx 'adapters\sync-skills.ps1') -HostName cursor | Out-Null
    $syncExit = $LASTEXITCODE
    $stillCustomAfterSync = ((Get-Content -LiteralPath $seedTarget -Raw) -match 'keep-custom-model')

    $shInitOk = $true
    if ($hasBash) {
        $seedSh = Join-Path $sandbox 'seeded-sh\.b3\models.local.json'
        $prod8Sh = Join-Path $sandbox 'prod8-sh'
        New-Item -ItemType Directory -Path $prod8Sh | Out-Null
        Push-Location $prod8Sh
        & git init -q; & git config user.email 't@e.com'; & git config user.name 'T'
        Set-Content 'README.md' "# Prod8sh`n"; & git add .; & git commit -qm 'init'
        Pop-Location
        $env:B3_MODELS_PERSONAL = ($seedSh -replace '\\', '/')
        $p8ShP = $prod8Sh -replace '\\', '/'
        $ipShPosix = $rootP + '/adapters/install-product.sh'
        & $gitBash -c "'$ipShPosix' --product-root '$p8ShP' --b3-home '$rootP' --host cursor" | Out-Null
        $cSh = $LASTEXITCODE
        $shCreated = Test-Path -LiteralPath $seedSh -PathType Leaf
        Set-Content -LiteralPath $seedSh '{"version":1,"models":{"main":"sh-custom"}}'
        & $gitBash -c "'$ipShPosix' --product-root '$p8ShP' --b3-home '$rootP' --host cursor" | Out-Null
        $shPreserved = ((Get-Content -LiteralPath $seedSh -Raw) -match 'sh-custom')
        if ($cSh -eq 0 -and $shCreated -and $shPreserved) {
            # Also verify sync-skills.sh seeds if missing & preserves if present
            $seedSyncSh = Join-Path $sandbox 'seeded-sync-sh\.b3\models.local.json'
            $env:B3_MODELS_PERSONAL = ($seedSyncSh -replace '\\', '/')
            $syncFxP = $syncFx -replace '\\', '/'
            Copy-Item -LiteralPath (Join-Path $root 'adapters\sync-skills.sh') -Destination (Join-Path $syncFx 'adapters\sync-skills.sh')
            & $gitBash -c "'$syncFxP/adapters/sync-skills.sh' antigravity" | Out-Null
            $syncShCode = $LASTEXITCODE
            $syncShCreated = Test-Path -LiteralPath $seedSyncSh -PathType Leaf
            $shInitOk = ($syncShCode -eq 0) -and $syncShCreated
        } else {
            $shInitOk = $false
        }
    }
    if ($ipExit -eq 0 -and $dryNotCreated -and $seededCreated -and $noCopyInProd -and $stillCustomAfterIp -and $syncExit -eq 0 -and $stillCustomAfterSync -and $shInitOk) {
        Pass 'model-config-install-init-and-preserve'
    } else {
        FailCheck 'model-config-install-init-and-preserve' "ip=$ipExit dry=$dryNotCreated cr=$seededCreated noCp=$noCopyInProd keepIp=$stillCustomAfterIp sync=$syncExit keepSync=$stillCustomAfterSync sh=$shInitOk"
    }

    # --- 9. model-config-gitignore-behavior ---
    & git -C $root check-ignore -q '.b3/models.local.json'
    $b3RepoIgnoresLocal = ($LASTEXITCODE -eq 0)
    & git -C $root check-ignore -q 'config/models.default.json'
    $b3DefaultTracked = ($LASTEXITCODE -ne 0)
    & git -C $prod8 check-ignore -q '.b3/models.local.json'
    $prodIgnoresLocal = ($LASTEXITCODE -eq 0)
    & git -C $prod8 check-ignore -q '.b3/home'
    $prodHomeTracked = ($LASTEXITCODE -ne 0)
    if ($b3RepoIgnoresLocal -and $b3DefaultTracked -and $prodIgnoresLocal -and $prodHomeTracked) {
        Pass 'model-config-gitignore-behavior'
    } else {
        FailCheck 'model-config-gitignore-behavior' "b3Loc=$b3RepoIgnoresLocal b3Def=$b3DefaultTracked prodLoc=$prodIgnoresLocal prodHome=$prodHomeTracked"
    }

    # --- 10. model-config-dual-shell-parity (PS vs Bash JSON equivalence) ---
    if ($hasBash) {
        $parPs = Invoke-GuardPs @('resolve-models', '-B3Home', $root, '-PersonalConfig', $pers2, '-ProjectConfig', $proj4, '-Json')
        $parSh = Invoke-GuardSh "resolve-models --b3-home '$rootP' --personal-config '$pers2P' --project-config '$proj4P' --json"
        $psCompact = (($parPs.Text | ConvertFrom-Json) | ConvertTo-Json -Depth 6 -Compress)
        $shCompact = (($parSh.Text | ConvertFrom-Json) | ConvertTo-Json -Depth 6 -Compress)
        if ($parPs.Code -eq 0 -and $parSh.Code -eq 0 -and $psCompact -eq $shCompact) {
            Pass 'model-config-dual-shell-parity'
        } else {
            FailCheck 'model-config-dual-shell-parity' "psCode=$($parPs.Code) shCode=$($parSh.Code) ps=$psCompact sh=$shCompact"
        }
    } else {
        Pass 'model-config-dual-shell-parity'
    }
}
finally {
    if ($null -eq $prevModelsPersonal) { Remove-Item Env:B3_MODELS_PERSONAL -ErrorAction SilentlyContinue } else { $env:B3_MODELS_PERSONAL = $prevModelsPersonal }
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
