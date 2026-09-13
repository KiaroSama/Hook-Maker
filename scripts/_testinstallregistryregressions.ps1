# Dot-sourced scenario block of Test-InstallRegistry.ps1: defect regressions -
# a structured result document lands for every terminal outcome, not only
# success (D1); legacy runtime/config cleanup happens only after the
# replacement runtime commits (D2); an engine config/profile is fully
# validated before any mutation, including the routes-array and zero-route
# rules (D3); per-hook registration timeouts (default, explicit, bounds,
# drift repair, legacy records without the field); and handler preservation
# for foreign/ambiguous entries - hooks-less groups, cross-client timeout
# inheritance, disagreeing command fields, plain user commands (D4).
# NOT a standalone suite: this file is dot-sourced into the entry suite's
# scope and relies on its harness (Check, $script:Pass/$script:Fail), shared
# fixtures and helper functions. Run scripts\Test-InstallRegistry.ps1 instead.

    # =====================================================================
    # DEFECT 1: a structured result document is guaranteed for every terminal
    # outcome, not only the happy path. Validation, runtime-phase and
    # native-git-phase failures all THROW (preserving prior behavior for
    # callers that don't pass -ResultPath) but must still land a valid,
    # correctly-attributed result document when -ResultPath is given, via
    # Install-Hook.ps1's top-level trap.
    Write-Host '--- a structured result is written for every terminal outcome, not only success ---' -ForegroundColor Cyan
    $d1Hook = Join-Path $RealHooksDir 'Ai-Memory-Check\Ai-Memory-Check.ps1'

    # 1a. validation failure (pre-mutation, phase=validation)
    $d1ValProj = New-Proj 'D1ValidationFail'
    $d1ValResult = Join-Path $Work 'd1-validation.json'
    $d1ValThrew = $false
    try { & $InstallScript -CustomHook $d1Hook -TargetProject $d1ValProj -Events @('Stop') -ClaudeOnly -CodexOnly -ResultPath $d1ValResult *> $null } catch { $d1ValThrew = $true }
    Check 'validation failure still throws (original behavior preserved)' $d1ValThrew
    Check 'validation failure still writes a result document' (Test-Path -LiteralPath $d1ValResult)
    $d1ValDoc = Get-Content -LiteralPath $d1ValResult -Raw | ConvertFrom-Json
    Check 'validation failure result document is valid JSON with overall=failed' ([string]$d1ValDoc.overall -eq 'failed')
    $d1ValComp = @($d1ValDoc.components | Where-Object { $_.component -eq 'validation' })[0]
    Check 'validation failure is attributed to the validation component' ($null -ne $d1ValComp -and [string]$d1ValComp.status -eq 'failed')
    Check 'validation failure mutated nothing' (-not (Test-Path -LiteralPath (Join-Path $d1ValProj '.claude')))

    # 1b. runtime-phase failure (mid-pipeline, phase=claude): the source
    # script is exclusively locked so plan-building/staging cannot read it,
    # forcing a genuine throw AFTER validation has already passed.
    $d1RtDir = Join-Path $RealHooksDir 'ZZZ-Regtest-Runtimefail'
    New-Item -ItemType Directory -Path $d1RtDir -Force | Out-Null
    $d1RtHook = Join-Path $d1RtDir 'ZZZ-Regtest-Runtimefail.ps1'
    Write-Utf8 $d1RtHook "exit 0`n"
    try {
        $d1RtProj = New-Proj 'D1RuntimeFail'
        $d1RtResult = Join-Path $Work 'd1-runtime.json'
        $d1RtHeld = [System.IO.File]::Open($d1RtHook, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $d1RtThrew = $false
        try {
            try { & $InstallScript -CustomHook $d1RtHook -TargetProject $d1RtProj -Events @('Stop') -ResultPath $d1RtResult *> $null } catch { $d1RtThrew = $true }
        }
        finally { $d1RtHeld.Dispose() }
        Check 'a mid-pipeline runtime failure throws' $d1RtThrew
        Check 'a mid-pipeline runtime failure still writes a result document' (Test-Path -LiteralPath $d1RtResult)
        $d1RtDoc = Get-Content -LiteralPath $d1RtResult -Raw | ConvertFrom-Json
        Check 'a runtime failure result document reports overall=failed' ([string]$d1RtDoc.overall -eq 'failed')
        $d1RtComp = @($d1RtDoc.components | Where-Object { $_.component -eq 'claude' })[0]
        Check 'a runtime failure is attributed to the claude component' ($null -ne $d1RtComp -and [string]$d1RtComp.status -eq 'failed')
    }
    finally { Remove-Item -LiteralPath $d1RtDir -Recurse -Force -ErrorAction SilentlyContinue }

    # 1c. native-git-phase failure (phase=nativeGit): a stale
    # pre-push.hookmaker-existing collides with a real (non-marker) pre-push
    # hook, which Install-IgnorePrePush already refuses to silently overwrite.
    $d1NatProj = New-Proj 'D1NativeFail'
    & git -C $d1NatProj init -q -b main 2>$null
    & git -C $d1NatProj config user.email 't@t' 2>$null
    & git -C $d1NatProj config user.name 't' 2>$null
    $d1NatGitHooks = Join-Path $d1NatProj '.git\hooks'
    New-Item -ItemType Directory -Path $d1NatGitHooks -Force | Out-Null
    Write-Utf8 (Join-Path $d1NatGitHooks 'pre-push') "#!/bin/sh`necho user-hook`n"
    Write-Utf8 (Join-Path $d1NatGitHooks 'pre-push.hookmaker-existing') "#!/bin/sh`necho stale-leftover`n"
    $d1NatResult = Join-Path $Work 'd1-native.json'
    $d1NatThrew = $false
    try { & $InstallScript -CustomHook (Join-Path $RealHooksDir 'Ignore-Rules-Check\Ignore-Rules-Check.ps1') -TargetProject $d1NatProj -Events @('Stop') -ResultPath $d1NatResult *> $null } catch { $d1NatThrew = $true }
    Check 'a native pre-push conflict throws' $d1NatThrew
    Check 'a native pre-push conflict still writes a result document' (Test-Path -LiteralPath $d1NatResult)
    $d1NatDoc = Get-Content -LiteralPath $d1NatResult -Raw | ConvertFrom-Json
    Check 'a native failure result document reports overall=failed' ([string]$d1NatDoc.overall -eq 'failed')
    $d1NatComp = @($d1NatDoc.components | Where-Object { $_.component -eq 'nativeGit' })[0]
    Check 'a native failure is attributed to the nativeGit component' ($null -ne $d1NatComp -and [string]$d1NatComp.status -eq 'failed')
    Check 'the claude component still reports ok (it committed before native failed)' (@($d1NatDoc.components | Where-Object { $_.component -eq 'claude' -and $_.status -eq 'ok' }).Count -eq 1)

    # 1d. real spawned process: exit code and stderr are preserved, and the
    # in-process test above cannot prove genuine end-user/CI process behavior.
    $d1SpProj = New-Proj 'D1SpawnedFail'
    $d1SpResult = Join-Path $Work 'd1-spawned.json'
    $d1SpArgLine = '-NoLogo -NoProfile -File "' + $InstallScript + '" -CustomHook "' + $d1Hook + '" -TargetProject "' + $d1SpProj + '" -Events Stop -ClaudeOnly -CodexOnly -ResultPath "' + $d1SpResult + '"'
    $d1SpOut = Join-Path $Work 'd1-spawned.out'; $d1SpErr = Join-Path $Work 'd1-spawned.err'
    $d1SpStart = @{
        FilePath = (Get-Process -Id $PID).Path; ArgumentList = $d1SpArgLine
        RedirectStandardOutput = $d1SpOut; RedirectStandardError = $d1SpErr
        NoNewWindow = $true; PassThru = $true; Wait = $true
    }
    if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) { $d1SpStart.Environment = @{ HOOKMAKER_STATE_DIR = $IsolatedStateDir } }
    $d1SpProc = Start-BoundedProcess @d1SpStart
    Check 'a spawned failing install exits non-zero' ($d1SpProc.ExitCode -ne 0)
    Check 'a spawned failing install still writes a result document' (Test-Path -LiteralPath $d1SpResult)
    Check 'a spawned failing install does not swallow the original error text' ((Get-Content -LiteralPath $d1SpErr -Raw) -match 'ClaudeOnly.*CodexOnly|mutually exclusive|both.*Claude.*Codex')

    # 1e. success still reports overall=ok (the baseline this all must not break)
    $d1OkProj = New-Proj 'D1Success'
    $d1OkResult = Join-Path $Work 'd1-ok.json'
    & $InstallScript -CustomHook $d1Hook -TargetProject $d1OkProj -Events @('Stop') -ResultPath $d1OkResult *> $null
    $d1OkDoc = Get-Content -LiteralPath $d1OkResult -Raw | ConvertFrom-Json
    Check 'a fully successful install still reports overall=ok' ([string]$d1OkDoc.overall -eq 'ok')

    # =====================================================================
    # DEFECT 2: legacy runtime/config cleanup must happen only AFTER the
    # replacement runtime has staged, hash-verified and swapped - never
    # before. A failed replacement must never destroy a working legacy
    # artifact, and a successful replacement must still clean up afterward.
    Write-Host '--- legacy cleanup happens only after the replacement runtime commits ---' -ForegroundColor Cyan
    $d2Fixture = New-FixtureHook 'ZZZ-Regtest-Legacycleanup' "exit 0 # good`n"
    try {
        $d2Proj = New-Proj 'D2LegacyCleanup'
        & $InstallScript -CustomHook $d2Fixture -Events @('Stop') -TargetProject $d2Proj -ClaudeOnly *> $null
        $d2RuntimeRoot = Join-Path $d2Proj '.claude\hooks\Hook-Maker'
        $d2Script = Join-Path $d2RuntimeRoot 'ZZZ-Regtest-Legacycleanup\ZZZ-Regtest-Legacycleanup.ps1'
        Check 'baseline D2 install succeeded' (Test-Path -LiteralPath $d2Script)

        # Plant a fake legacy root-level sync-hooks.json - one of the three
        # artifacts Copy-HookRuntime cleans up post-commit.
        $d2LegacyConfig = Join-Path $d2RuntimeRoot 'sync-hooks.json'
        Write-Utf8 $d2LegacyConfig '{"legacy":true}'
        $d2LegacyBytesBefore = [System.IO.File]::ReadAllBytes($d2LegacyConfig)
        $d2GoodHash = (Get-FileHash -LiteralPath $d2Script -Algorithm SHA256).Hash

        # Force a staging failure (source locked exclusively) on a REINSTALL of
        # the SAME hook, so Copy-HookRuntime runs but Install-PlannedRuntime
        # throws before the swap - legacy cleanup must never be reached.
        $d2Held = [System.IO.File]::Open($d2Fixture, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $d2Threw = $false
        try {
            try { & $InstallScript -CustomHook $d2Fixture -Events @('Stop') -TargetProject $d2Proj -ClaudeOnly *> $null } catch { $d2Threw = $true }
        }
        finally { $d2Held.Dispose() }
        Check 'a forced staging failure on reinstall throws' $d2Threw
        Check 'the previous runtime survives a failed staging' (Test-Path -LiteralPath $d2Script)
        Check 'the previous runtime is byte-identical after a failed staging' ((Get-FileHash -LiteralPath $d2Script -Algorithm SHA256).Hash -eq $d2GoodHash)
        Check 'the legacy artifact still exists after a failed staging (cleanup never reached)' (Test-Path -LiteralPath $d2LegacyConfig)
        $d2LegacyBytesAfterFail = [System.IO.File]::ReadAllBytes($d2LegacyConfig)
        Check 'the legacy artifact is byte-identical after a failed staging' (
            ($d2LegacyBytesAfterFail.Length -eq $d2LegacyBytesBefore.Length) -and
            ((Compare-Object $d2LegacyBytesAfterFail $d2LegacyBytesBefore -SyncWindow 0 | Measure-Object).Count -eq 0))

        # Now a normal (unlocked) reinstall: staging/swap succeeds, and ONLY
        # after that does the legacy artifact get cleaned up.
        & $InstallScript -CustomHook $d2Fixture -Events @('Stop') -TargetProject $d2Proj -ClaudeOnly *> $null
        Check 'a successful reinstall keeps the runtime present' (Test-Path -LiteralPath $d2Script)
        Check 'a successful reinstall cleans up the legacy artifact afterward' (-not (Test-Path -LiteralPath $d2LegacyConfig))
    }
    finally { Remove-FixtureHook 'ZZZ-Regtest-Legacycleanup' }

    # =====================================================================
    # DEFECT 3: a direct engine install fully validates its config/profile
    # BEFORE any mutation - missing file, malformed JSON, missing profiles,
    # unknown profile, duplicate profile id, malformed route, missing
    # endpoint root/name are all rejected with nothing touched.
    Write-Host '--- engine config/profile is fully validated before any mutation ---' -ForegroundColor Cyan
    function New-D3Proj { param([string]$Name) return (New-Proj ('D3' + $Name)) }
    function Assert-D3Rejected {
        param([string]$Label, [string]$ConfigPath, [string]$ProfileId = 'p', [string]$ProjSuffix)
        $proj = New-D3Proj $ProjSuffix
        $threw = $false
        try { & $InstallScript -Profile $ProfileId -ConfigPath $ConfigPath -TargetProject $proj -Events @('Stop') *> $null } catch { $threw = $true }
        Check ($Label + ' throws') $threw
        Check ($Label + ': nothing mutated') (-not (Test-Path -LiteralPath (Join-Path $proj '.claude')))
    }
    $d3MissingCfg = Join-Path $Work 'd3-missing.json'
    Assert-D3Rejected 'missing config file' $d3MissingCfg -ProjSuffix 'MissingCfg'

    $d3BadJson = Join-Path $Work 'd3-badjson.json'
    Write-Utf8 $d3BadJson '{ not json'
    Assert-D3Rejected 'malformed JSON config' $d3BadJson -ProjSuffix 'BadJson'

    $d3NoProfiles = Join-Path $Work 'd3-noprofiles.json'
    Write-Utf8 $d3NoProfiles '{"version":1}'
    Assert-D3Rejected 'config missing profiles array' $d3NoProfiles -ProjSuffix 'NoProfiles'

    $d3Real = Join-Path $Work 'd3-real.json'
    Write-Utf8 $d3Real '{"version":1,"profiles":[{"id":"p","name":"P","routes":[{"id":"r1","source":{"name":"A","root":"C:\\x"},"destination":{"name":"B","root":"C:\\y"}}]}]}'
    Assert-D3Rejected 'unknown profile id' $d3Real -ProfileId 'no-such-profile' -ProjSuffix 'UnknownProfile'

    $d3Dup = Join-Path $Work 'd3-dup.json'
    Write-Utf8 $d3Dup '{"version":1,"profiles":[{"id":"p","name":"P1","routes":[]},{"id":"p","name":"P2","routes":[]}]}'
    Assert-D3Rejected 'duplicate profile id' $d3Dup -ProjSuffix 'DupProfile'

    $d3NoRouteId = Join-Path $Work 'd3-norouteid.json'
    Write-Utf8 $d3NoRouteId '{"version":1,"profiles":[{"id":"p","name":"P","routes":[{"source":{"name":"A","root":"C:\\x"},"destination":{"name":"B","root":"C:\\y"}}]}]}'
    Assert-D3Rejected 'malformed route (missing id)' $d3NoRouteId -ProjSuffix 'NoRouteId'

    $d3NoRoot = Join-Path $Work 'd3-noroot.json'
    Write-Utf8 $d3NoRoot '{"version":1,"profiles":[{"id":"p","name":"P","routes":[{"id":"r1","source":{"name":"A"},"destination":{"name":"B","root":"C:\\y"}}]}]}'
    Assert-D3Rejected 'missing endpoint root' $d3NoRoot -ProjSuffix 'NoRoot'

    $d3NoName = Join-Path $Work 'd3-noname.json'
    Write-Utf8 $d3NoName '{"version":1,"profiles":[{"id":"p","routes":[{"id":"r1","source":{"name":"A","root":"C:\\x"},"destination":{"name":"B","root":"C:\\y"}}]}]}'
    Assert-D3Rejected 'profile missing name (SYNC-PROJECTS.txt needs it)' $d3NoName -ProjSuffix 'NoName'

    # A structurally valid config still installs successfully end-to-end.
    $d3GoodProj = New-D3Proj 'Good'
    & $InstallScript -Profile 'p' -ConfigPath $d3Real -TargetProject $d3GoodProj -Events @('SessionStart') -ClaudeOnly *> $null
    Check 'a valid engine config/profile still installs successfully' (Test-Path -LiteralPath (Join-Path $d3GoodProj '.claude\settings.local.json'))

    # =====================================================================
    # REGRESSION: Test-SyncConfigStructure used to default a MISSING 'routes'
    # property to @(), silently treating "no routes property at all" as a
    # valid profile with an empty route list. It now REQUIRES 'routes' to be
    # present and a genuine array. An EMPTY array ("routes":[]) is deliberately
    # still STRUCTURALLY valid (Validate-Config.ps1 validates every profile in
    # a whole file, including ones not being installed, and an emptied-out
    # placeholder group is a legitimate file state) - the stricter "the
    # profile being installed needs at least one route" rule is enforced only
    # in Install-Hook.ps1's pre-mutation engine block, tested separately below.
    Write-Host '--- Test-SyncConfigStructure requires a genuine routes array (both directions) ---' -ForegroundColor Cyan
    function New-RoutesTestConfig { param($ProfileObj) return [pscustomobject]@{ profiles = @($ProfileObj) } }

    $profMissingRoutes = [pscustomobject]@{ id = 'p'; name = 'P' }
    $rtMissing = Test-SyncConfigStructure -Config (New-RoutesTestConfig $profMissingRoutes)
    Check 'a profile missing routes entirely is rejected' (-not $rtMissing.Ok)
    Check 'the rejection reason names the profile and the missing routes array' ($rtMissing.Reason -match "profile 'p' requires a routes array") $rtMissing.Reason

    $profNullRoutes = [pscustomobject]@{ id = 'p'; name = 'P'; routes = $null }
    $rtNull = Test-SyncConfigStructure -Config (New-RoutesTestConfig $profNullRoutes)
    Check 'routes: null is rejected' (-not $rtNull.Ok) $rtNull.Reason

    $profStringRoutes = [pscustomobject]@{ id = 'p'; name = 'P'; routes = 'not-an-array' }
    $rtString = Test-SyncConfigStructure -Config (New-RoutesTestConfig $profStringRoutes)
    Check 'routes as a string is rejected' (-not $rtString.Ok) $rtString.Reason

    $profObjectRoutes = [pscustomobject]@{ id = 'p'; name = 'P'; routes = [pscustomobject]@{ note = 'not an array' } }
    $rtObject = Test-SyncConfigStructure -Config (New-RoutesTestConfig $profObjectRoutes)
    Check 'routes as an object (not an array) is rejected' (-not $rtObject.Ok) $rtObject.Reason

    $profNumberRoutes = [pscustomobject]@{ id = 'p'; name = 'P'; routes = 5 }
    $rtNumber = Test-SyncConfigStructure -Config (New-RoutesTestConfig $profNumberRoutes)
    Check 'routes as a number is rejected' (-not $rtNumber.Ok) $rtNumber.Reason

    $profEmptyRoutes = [pscustomobject]@{ id = 'p'; name = 'P'; routes = @() }
    $rtEmpty = Test-SyncConfigStructure -Config (New-RoutesTestConfig $profEmptyRoutes)
    Check 'routes: [] (empty array) is still accepted - a legitimate emptied/placeholder profile' ($rtEmpty.Ok -eq $true) $rtEmpty.Reason

    $profOneRoute = [pscustomobject]@{
        id     = 'p'; name = 'P'
        routes = @([pscustomobject]@{
                id          = 'r1'
                source      = [pscustomobject]@{ name = 'A'; root = 'C:\x' }
                destination = [pscustomobject]@{ name = 'B'; root = 'C:\y' }
            })
    }
    $rtOneRoute = Test-SyncConfigStructure -Config (New-RoutesTestConfig $profOneRoute)
    Check 'a valid one-route profile is still accepted' ($rtOneRoute.Ok -eq $true) $rtOneRoute.Reason

    # REGRESSION: the real shipped sync-hooks.example.json still validates.
    $exampleSyncConfigPath = Join-Path $ToolRoot 'sync-hooks.example.json'
    $exampleSyncConfig = Get-Content -LiteralPath $exampleSyncConfigPath -Raw | ConvertFrom-Json
    $rtExample = Test-SyncConfigStructure -Config $exampleSyncConfig
    Check 'the shipped sync-hooks.example.json still validates' ($rtExample.Ok -eq $true) $rtExample.Reason

    # =====================================================================
    # REGRESSION: at ENGINE INSTALL time the specific profile being installed
    # must have at least one route - a zero-route install would produce a
    # hook that provably cannot sync anything plus an empty generated
    # SYNC-PROJECTS.txt. Extends Assert-D3Rejected (which only checks
    # throw + ".claude never created") with the full structured-result,
    # validation-attribution, registry and leftover-artifact assertions this
    # defect specifically requires.
    Write-Host '--- a zero-route (or routeless) profile is rejected before any engine install mutation ---' -ForegroundColor Cyan
    function Assert-EngineValidationRejected {
        param([string]$Label, [string]$ConfigPath, [string]$ProfileId, [string]$ProjSuffix)
        $proj = New-D3Proj $ProjSuffix
        $resultFile = Join-Path $Work ('routes-reject-' + $ProjSuffix + '.json')
        $threw = $false
        try { & $InstallScript -Profile $ProfileId -ConfigPath $ConfigPath -TargetProject $proj -Events @('Stop') -ResultPath $resultFile *> $null } catch { $threw = $true }
        Check ($Label + ': invocation throws') $threw

        Check ($Label + ': a structured result document is written') (Test-Path -LiteralPath $resultFile)
        $docOk = $false; $doc = $null
        try { $doc = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json; $docOk = $true } catch { }
        Check ($Label + ': the result document is valid JSON') $docOk
        Check ($Label + ': the result document reports overall=failed') ($docOk -and [string]$doc.overall -eq 'failed')

        $validationComp = $null
        if ($docOk) { $validationComp = @($doc.components | Where-Object { $_.component -eq 'validation' })[0] }
        Check ($Label + ': the failure is attributed to the validation component') ($null -ne $validationComp -and [string]$validationComp.status -eq 'failed')

        Check ($Label + ': no .claude directory was created') (-not (Test-Path -LiteralPath (Join-Path $proj '.claude')))
        Check ($Label + ': no .codex directory was created') (-not (Test-Path -LiteralPath (Join-Path $proj '.codex')))

        $recs = @((Get-Registry).installs | Where-Object { [string]$_.targetProjectRoot -eq $proj })
        Check ($Label + ': no registry record was created for this target') ($recs.Count -eq 0)

        $leftovers = @(Get-ChildItem -LiteralPath $proj -Recurse -Force -ErrorAction SilentlyContinue)
        Check ($Label + ': no backup/temp/staging/result-lock artifact was left in the target project') ($leftovers.Count -eq 0)
    }

    $d4ZeroRoutesCfg = Join-Path $Work 'd4-zeroroutes.json'
    Write-Utf8 $d4ZeroRoutesCfg '{"version":1,"profiles":[{"id":"p","name":"P","routes":[]}]}'
    Assert-EngineValidationRejected 'zero-route profile being installed' $d4ZeroRoutesCfg -ProfileId 'p' -ProjSuffix 'ZeroRoutes'

    $d4NoRoutesCfg = Join-Path $Work 'd4-noroutes.json'
    Write-Utf8 $d4NoRoutesCfg '{"version":1,"profiles":[{"id":"p","name":"P"}]}'
    Assert-EngineValidationRejected 'profile missing routes entirely' $d4NoRoutesCfg -ProfileId 'p' -ProjSuffix 'NoRoutesEntirely'

    # (C) The new checks must not break the happy path: a valid one-route
    # engine install still succeeds end-to-end.
    $d4GoodRoutesCfg = Join-Path $Work 'd4-goodroutes.json'
    Write-Utf8 $d4GoodRoutesCfg '{"version":1,"profiles":[{"id":"p","name":"P","routes":[{"id":"r1","source":{"name":"A","root":"C:\\x"},"destination":{"name":"B","root":"C:\\y"}}]}]}'
    $d4GoodProj = New-D3Proj 'RoutesGood'
    & $InstallScript -Profile 'p' -ConfigPath $d4GoodRoutesCfg -TargetProject $d4GoodProj -Events @('SessionStart') -ClaudeOnly *> $null
    Check 'a valid one-route engine install still succeeds end-to-end (routes checks do not break the happy path)' (Test-Path -LiteralPath (Join-Path $d4GoodProj '.claude\settings.local.json'))

    # =====================================================================
    # PER-HOOK REGISTRATION TIMEOUT.
    # Both clients document `timeout` on the INDIVIDUAL hook entry, so a
    # per-hook value is registrable; the universal 60 stays the default for
    # every hook that does not ask for its own. These blocks pin the
    # compatibility guard, the bounds, per-client persistence, drift detection
    # and repair-without-collateral-damage.
    Write-Host '--- an install with no explicit timeout still writes 60 for both clients ---' -ForegroundColor Cyan
    $fixtureT1 = New-FixtureHook 'ZZZ-Regtest-Timeoutdefault'
    try {
        $projT1 = New-Proj 'TimeoutDefault'
        & $InstallScript -CustomHook $fixtureT1 -Events @('Stop') -TargetProject $projT1 *> $null
        $t1Claude = Get-Content -LiteralPath (Join-Path $projT1 '.claude\settings.local.json') -Raw | ConvertFrom-Json
        $t1Codex = Get-Content -LiteralPath (Join-Path $projT1 '.codex\hooks.json') -Raw | ConvertFrom-Json
        Check 'claude handler timeout is 60 when -Timeout is omitted' ([int]$t1Claude.hooks.Stop[0].hooks[0].timeout -eq 60)
        Check 'codex handler timeout is 60 when -Timeout is omitted' ([int]$t1Codex.hooks.Stop[0].hooks[0].timeout -eq 60)
        $recT1 = (Get-RecordsFor 'ZZZ-Regtest-Timeoutdefault')[0]
        Check 'claude subrecord persists timeout 60 when -Timeout is omitted' ([int]$recT1.clients.claude.timeout -eq 60)
        Check 'codex subrecord persists timeout 60 when -Timeout is omitted' ([int]$recT1.clients.codex.timeout -eq 60)
        Check 'a default-timeout install is reported as current (no false drift)' ((Get-InstallIntegrity -Record $recT1 -ToolRoot $ToolRoot).Status -eq 'current')
    }
    finally { Remove-FixtureHook 'ZZZ-Regtest-Timeoutdefault' }

    # =====================================================================
    Write-Host '--- an explicit in-range timeout is written and persisted per client ---' -ForegroundColor Cyan
    $fixtureT2 = New-FixtureHook 'ZZZ-Regtest-Timeoutexplicit'
    try {
        $projT2 = New-Proj 'TimeoutExplicit'
        & $InstallScript -CustomHook $fixtureT2 -Events @('Stop', 'SessionStart') -TargetProject $projT2 -Timeout 180 *> $null
        $t2Claude = Get-Content -LiteralPath (Join-Path $projT2 '.claude\settings.local.json') -Raw | ConvertFrom-Json
        $t2Codex = Get-Content -LiteralPath (Join-Path $projT2 '.codex\hooks.json') -Raw | ConvertFrom-Json
        Check 'claude handler carries the explicit timeout' ([int]$t2Claude.hooks.Stop[0].hooks[0].timeout -eq 180)
        Check 'codex handler carries the explicit timeout' ([int]$t2Codex.hooks.Stop[0].hooks[0].timeout -eq 180)
        Check 'the explicit timeout is written on EVERY registered event, not just the first' (
            [int]$t2Claude.hooks.SessionStart[0].hooks[0].timeout -eq 180 -and [int]$t2Codex.hooks.SessionStart[0].hooks[0].timeout -eq 180)
        $recT2 = (Get-RecordsFor 'ZZZ-Regtest-Timeoutexplicit')[0]
        Check 'claude subrecord persists the explicit timeout' ([int]$recT2.clients.claude.timeout -eq 180)
        Check 'codex subrecord persists the explicit timeout' ([int]$recT2.clients.codex.timeout -eq 180)
        Check 'a record with a non-default timeout still validates' ((Test-InstallRecordValid -Record $recT2).Ok)
        Check 'an explicit-timeout install is reported as current (asserted against 180, not 60)' ((Get-InstallIntegrity -Record $recT2 -ToolRoot $ToolRoot).Status -eq 'current')

        # A repair invocation (what the updater issues) carries no -Timeout, so
        # the hook's OWN value must survive rather than silently reset to 60.
        & $InstallScript -CustomHook $fixtureT2 -Events @('Stop', 'SessionStart') -TargetProject $projT2 *> $null
        $t2Again = Get-Content -LiteralPath (Join-Path $projT2 '.claude\settings.local.json') -Raw | ConvertFrom-Json
        Check 'reinstalling without -Timeout keeps the recorded per-hook value' ([int]$t2Again.hooks.Stop[0].hooks[0].timeout -eq 180)
        Check 'the persisted per-hook value is unchanged by a no-Timeout reinstall' ([int]((Get-RecordsFor 'ZZZ-Regtest-Timeoutexplicit')[0]).clients.claude.timeout -eq 180)
        # ...and it is still explicitly overridable in both directions.
        & $InstallScript -CustomHook $fixtureT2 -Events @('Stop', 'SessionStart') -TargetProject $projT2 -Timeout 60 *> $null
        $t2Back = Get-Content -LiteralPath (Join-Path $projT2 '.claude\settings.local.json') -Raw | ConvertFrom-Json
        Check 'an explicit -Timeout 60 returns the hook to the default' ([int]$t2Back.hooks.Stop[0].hooks[0].timeout -eq 60)
    }
    finally { Remove-FixtureHook 'ZZZ-Regtest-Timeoutexplicit' }

    # =====================================================================
    Write-Host '--- an out-of-range timeout is refused with a precise reason and nothing is written ---' -ForegroundColor Cyan
    $fixtureT3 = New-FixtureHook 'ZZZ-Regtest-Timeoutbounds'
    try {
        function Assert-TimeoutRejected {
            param([string]$Label, [int]$Value, [string]$ProjSuffix)
            $projReject = New-Proj ('TimeoutReject' + $ProjSuffix)
            $resultFile = Join-Path $Work ('timeout-reject-' + $ProjSuffix + '.json')
            $rejectMessage = ''
            $threw = $false
            try { & $InstallScript -CustomHook $fixtureT3 -Events @('Stop') -TargetProject $projReject -Timeout $Value -ResultPath $resultFile *> $null }
            catch { $threw = $true; $rejectMessage = [string]$_.Exception.Message }
            Check ($Label + ': the invocation is refused') $threw
            Check ($Label + ': the reason names the timeout and the allowed range') (
                $rejectMessage -match 'timeout' -and $rejectMessage -match [regex]::Escape([string]$Value) -and $rejectMessage -match '5' -and $rejectMessage -match '600') $rejectMessage
            # Refused, never clamped: a clamped value would have installed
            # something the caller never asked for.
            Check ($Label + ': no .claude registration was written') (-not (Test-Path -LiteralPath (Join-Path $projReject '.claude')))
            Check ($Label + ': no .codex registration was written') (-not (Test-Path -LiteralPath (Join-Path $projReject '.codex')))
            Check ($Label + ': nothing at all was left in the target project') (@(Get-ChildItem -LiteralPath $projReject -Recurse -Force -ErrorAction SilentlyContinue).Count -eq 0)
            Check ($Label + ': no registry record was created') (@((Get-Registry).installs | Where-Object { [string]$_.targetProjectRoot -eq $projReject }).Count -eq 0)
            $docOk = $false; $doc = $null
            if (Test-Path -LiteralPath $resultFile) { try { $doc = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json; $docOk = $true } catch { } }
            Check ($Label + ': the failure is attributed to the validation component') (
                $docOk -and [string]$doc.overall -eq 'failed' -and @($doc.components | Where-Object { $_.component -eq 'validation' -and $_.status -eq 'failed' }).Count -eq 1)
        }
        Assert-TimeoutRejected 'above the maximum' 5000 'High'
        Assert-TimeoutRejected 'below the minimum' 1 'Low'
        Assert-TimeoutRejected 'zero' 0 'Zero'
        Assert-TimeoutRejected 'negative' -30 'Negative'

        # The boundary values themselves are IN range - an off-by-one in the
        # bounds check would make the documented range a lie.
        $projEdgeLow = New-Proj 'TimeoutEdgeLow'
        & $InstallScript -CustomHook $fixtureT3 -Events @('Stop') -TargetProject $projEdgeLow -Timeout 5 -ClaudeOnly *> $null
        $projEdgeHigh = New-Proj 'TimeoutEdgeHigh'
        & $InstallScript -CustomHook $fixtureT3 -Events @('Stop') -TargetProject $projEdgeHigh -Timeout 600 -ClaudeOnly *> $null
        Check 'the minimum bound (5) is accepted' (
            [int]((Get-Content -LiteralPath (Join-Path $projEdgeLow '.claude\settings.local.json') -Raw | ConvertFrom-Json).hooks.Stop[0].hooks[0].timeout) -eq 5)
        Check 'the maximum bound (600) is accepted' (
            [int]((Get-Content -LiteralPath (Join-Path $projEdgeHigh '.claude\settings.local.json') -Raw | ConvertFrom-Json).hooks.Stop[0].hooks[0].timeout) -eq 600)
    }
    finally { Remove-FixtureHook 'ZZZ-Regtest-Timeoutbounds' }

    # =====================================================================
    Write-Host '--- an edited live registration timeout is drift, and update repairs ONLY it ---' -ForegroundColor Cyan
    $fixtureT4 = New-FixtureHook 'ZZZ-Regtest-Timeoutdrift'
    try {
        $projT4 = New-Proj 'TimeoutDrift'
        & $InstallScript -CustomHook $fixtureT4 -Events @('Stop') -TargetProject $projT4 -Timeout 240 -ClaudeOnly *> $null
        $t4Settings = Join-Path $projT4 '.claude\settings.local.json'
        $recT4 = (Get-RecordsFor 'ZZZ-Regtest-Timeoutdrift')[0]
        Check 'the drift fixture starts out current' ((Get-InstallIntegrity -Record $recT4 -ToolRoot $ToolRoot).Status -eq 'current')

        # A FOREIGN handler in the SAME settings file, on its own event. It is
        # not Hook Maker's, so repairing the timeout must not touch one byte of
        # it. The installed source is left alone so the ONLY thing needing
        # repair is the timeout.
        $t4Json = Get-Content -LiteralPath $t4Settings -Raw | ConvertFrom-Json
        $t4Json.hooks | Add-Member -MemberType NoteProperty -Name 'PreCompact' -Value @(
            [pscustomobject]@{ matcher = 'manual'; hooks = @([pscustomobject]@{ type = 'command'; command = 'pwsh -File "D:\Foreign\Watcher.ps1"'; timeout = 17; statusMessage = 'foreign watcher' }) }) -Force
        # Live drift: someone edited the registered timeout by hand.
        $t4Json.hooks.Stop[0].hooks[0].timeout = 9
        [System.IO.File]::WriteAllText($t4Settings, ($t4Json | ConvertTo-Json -Depth 50), (New-Object System.Text.UTF8Encoding $false))

        # BYTE baseline of the foreign subtree, captured after it is on disk.
        $t4ForeignBefore = ((Get-Content -LiteralPath $t4Settings -Raw | ConvertFrom-Json).hooks.PreCompact | ConvertTo-Json -Depth 50)
        $t4ForeignBeforeBytes = [System.Text.Encoding]::UTF8.GetBytes($t4ForeignBefore)

        $recT4Drifted = (Get-RecordsFor 'ZZZ-Regtest-Timeoutdrift')[0]
        $integrityT4 = Get-InstallIntegrity -Record $recT4Drifted -ToolRoot $ToolRoot
        Check 'an edited registration timeout is detected as needing an update' ($integrityT4.Status -eq 'update')
        Check 'the drift detail names the timeout, not some other field' ([string]$integrityT4.Detail -match 'timeout') ([string]$integrityT4.Detail)

        $cfgT4 = Join-Path $Work 'cfg-timeout-drift.json'; New-Config $cfgT4
        $rT4 = Invoke-Wizard -Config $cfgT4 -Answers @('1', '4', '', '0')
        Check 'the update run exits 0' ($rT4.Exit -eq 0) $rT4.Err
        $t4After = Get-Content -LiteralPath $t4Settings -Raw | ConvertFrom-Json
        Check 'update restored the recorded per-hook timeout (240, not the default 60)' ([int]$t4After.hooks.Stop[0].hooks[0].timeout -eq 240)
        Check 'the record still carries the per-hook timeout after the repair' ([int]((Get-RecordsFor 'ZZZ-Regtest-Timeoutdrift')[0]).clients.claude.timeout -eq 240)
        Check 'the repaired installation is reported as current again' ((Get-InstallIntegrity -Record ((Get-RecordsFor 'ZZZ-Regtest-Timeoutdrift')[0]) -ToolRoot $ToolRoot).Status -eq 'current')

        $t4ForeignAfterBytes = [System.Text.Encoding]::UTF8.GetBytes(($t4After.hooks.PreCompact | ConvertTo-Json -Depth 50))
        Check 'the foreign handler in the same settings file is byte-identical after the repair' (
            [System.Linq.Enumerable]::SequenceEqual([byte[]]$t4ForeignBeforeBytes, [byte[]]$t4ForeignAfterBytes)) ($t4After.hooks.PreCompact | ConvertTo-Json -Depth 50)
        Check 'the foreign handler still appears exactly once' (
            @([regex]::Matches((Get-Content -LiteralPath $t4Settings -Raw), [regex]::Escape('D:\\Foreign\\Watcher.ps1'))).Count -eq 1)
    }
    finally { Remove-FixtureHook 'ZZZ-Regtest-Timeoutdrift' }

    # =====================================================================
    # Records written before timeouts were per-hook carry no `timeout` field at
    # all. They must keep validating, keep evaluating against the historical
    # 60, and keep updating - never be reported as drifted for lacking one.
    Write-Host '--- a pre-per-hook-timeout record still validates and still updates cleanly ---' -ForegroundColor Cyan
    $fixtureT5 = New-FixtureHook 'ZZZ-Regtest-Timeoutlegacy' "exit 0 # legacy v1`n"
    try {
        $projT5 = New-Proj 'TimeoutLegacy'
        & $InstallScript -CustomHook $fixtureT5 -Events @('Stop') -TargetProject $projT5 *> $null
        $legacyId = [string]((Get-RecordsFor 'ZZZ-Regtest-Timeoutlegacy')[0]).id

        # Strip the field the old writer never wrote.
        $registryT5 = Get-Registry
        foreach ($candidate in @($registryT5.installs | Where-Object { [string]$_.id -eq $legacyId })) {
            foreach ($clientName in @('claude', 'codex')) {
                $sub = Get-ClientSubrecord -Record $candidate -Client $clientName
                if ($null -ne $sub -and $null -ne $sub.PSObject.Properties['timeout']) { $sub.PSObject.Properties.Remove('timeout') }
            }
        }
        Save-InstallRegistry -ToolRoot $ToolRoot -Registry $registryT5
        $recT5 = @((Get-Registry).installs | Where-Object { [string]$_.id -eq $legacyId })[0]
        Check 'the legacy-shaped record really has no timeout field' (
            $null -eq (Get-ClientSubrecord -Record $recT5 -Client 'claude').PSObject.Properties['timeout'])
        Check 'a record with no timeout field still validates' ((Test-InstallRecordValid -Record $recT5).Ok) ([string](Test-InstallRecordValid -Record $recT5).Reason)
        Check 'a record with no timeout field is still schema 2 (id/shape compatible)' ([int]$recT5.schema -eq 2 -and [string]$recT5.id -eq $legacyId)
        Check 'a record with no timeout field is reported as current, not drifted' (
            (Get-InstallIntegrity -Record $recT5 -ToolRoot $ToolRoot).Status -eq 'current')

        # ...and it updates cleanly, gaining the historical 60 rather than
        # anything new, with its id preserved.
        Write-Utf8 $fixtureT5 "exit 0 # legacy v2 changed`n"
        $cfgT5 = Join-Path $Work 'cfg-timeout-legacy.json'; New-Config $cfgT5
        $rT5 = Invoke-Wizard -Config $cfgT5 -Answers @('1', '4', '', '0')
        Check 'the legacy-record update run exits 0' ($rT5.Exit -eq 0) $rT5.Err
        $recT5After = @((Get-Registry).installs | Where-Object { [string]$_.id -eq $legacyId })[0]
        Check 'the legacy record survives the update under the same id' ($null -ne $recT5After)
        Check 'the updated legacy record now carries the historical 60' ([int]$recT5After.clients.claude.timeout -eq 60)
        Check 'the updated legacy registration is still 60 on disk' (
            [int]((Get-Content -LiteralPath (Join-Path $projT5 '.claude\settings.local.json') -Raw | ConvertFrom-Json).hooks.Stop[0].hooks[0].timeout) -eq 60)
        Check 'the legacy record is current after the update' ((Get-InstallIntegrity -Record $recT5After -ToolRoot $ToolRoot).Status -eq 'current')
    }
    finally { Remove-FixtureHook 'ZZZ-Regtest-Timeoutlegacy' }

    # =====================================================================
    # D2 (StrictMode crash): a group object with NO `hooks` key at all (a
    # foreign/hand-edited entry - not a legitimate "hooks": [] group) must
    # never crash install/update under StrictMode, and must pass through
    # untouched since there is nothing on it to prove ownership over.
    Write-Host '--- a foreign event-group missing `hooks` never crashes install/update and is preserved ---' -ForegroundColor Cyan
    $fixtureForeignGroup = New-FixtureHook 'ZZZ-Regtest-Foreignnohooks'
    try {
        $projForeignGroup = New-Proj 'ForeignNoHooksProj'
        & $InstallScript -CustomHook $fixtureForeignGroup -Events @('Stop') -TargetProject $projForeignGroup -ClaudeOnly *> $null
        $foreignGroupSettings = Join-Path $projForeignGroup '.claude\settings.local.json'
        $foreignGroupJson = Get-Content -LiteralPath $foreignGroupSettings -Raw | ConvertFrom-Json
        # Hand-edit in a group with no `hooks` property at all, alongside the
        # real Hook Maker group, under the SAME event this install manages.
        $foreignGroupJson.hooks.Stop = @($foreignGroupJson.hooks.Stop) + @([pscustomobject]@{ matcher = 'foreign-no-hooks-key' })
        [System.IO.File]::WriteAllText($foreignGroupSettings, ($foreignGroupJson | ConvertTo-Json -Depth 50), (New-Object System.Text.UTF8Encoding $false))

        $foreignGroupThrew = $false
        try { & $InstallScript -CustomHook $fixtureForeignGroup -Events @('Stop') -TargetProject $projForeignGroup -ClaudeOnly *> $null }
        catch { $foreignGroupThrew = $true }
        Check 'a settings file with a hooks-less foreign group does not crash reinstall (StrictMode)' (-not $foreignGroupThrew)

        $foreignGroupAfter = Get-Content -LiteralPath $foreignGroupSettings -Raw | ConvertFrom-Json
        $foreignGroupStopGroups = @($foreignGroupAfter.hooks.Stop)
        Check 'the foreign hooks-less group is preserved (not dropped) across the reinstall' (
            @($foreignGroupStopGroups | Where-Object { $null -eq $_.PSObject.Properties['hooks'] -and [string]$_.matcher -eq 'foreign-no-hooks-key' }).Count -eq 1)
        $foreignGroupHandlers = @($foreignGroupStopGroups | Where-Object { $null -ne $_.PSObject.Properties['hooks'] } | ForEach-Object { $_.hooks })
        Check 'the real Hook Maker registration is still present exactly once' (
            @($foreignGroupHandlers | Where-Object { (Get-HandlerFieldValue $_ 'command') -like '*Hook-Maker*' }).Count -eq 1)
    }
    finally { Remove-FixtureHook 'ZZZ-Regtest-Foreignnohooks' }

    # =====================================================================
    # D1 (cross-client contamination): the prior-timeout lookup must consider
    # ONLY the client(s) THIS invocation is installing - a first-ever
    # -CodexOnly install must never inherit an existing -ClaudeOnly install's
    # custom timeout.
    Write-Host '--- a first-ever -CodexOnly install never inherits a prior -ClaudeOnly timeout ---' -ForegroundColor Cyan
    $fixtureCrossClient = New-FixtureHook 'ZZZ-Regtest-Crossclienttimeout'
    try {
        $projCrossClient = New-Proj 'CrossClientTimeoutProj'
        & $InstallScript -CustomHook $fixtureCrossClient -Events @('Stop') -TargetProject $projCrossClient -ClaudeOnly -Timeout 240 *> $null
        $recCrossClientClaude = (Get-RecordsFor 'ZZZ-Regtest-Crossclienttimeout')[0]
        Check 'the claude-only baseline install recorded the custom timeout' ([int]$recCrossClientClaude.clients.claude.timeout -eq 240)
        Check 'the claude-only baseline install has no codex subrecord yet' ($null -eq (Get-ClientSubrecord -Record $recCrossClientClaude -Client 'codex'))

        # First-ever CODEX install of the SAME logical hook (same friendly
        # name/scope/profile => same record id), with NO -Timeout given.
        & $InstallScript -CustomHook $fixtureCrossClient -Events @('Stop') -TargetProject $projCrossClient -CodexOnly *> $null
        Check 'still exactly one logical record after adding codex' ((Get-RecordsFor 'ZZZ-Regtest-Crossclienttimeout').Count -eq 1)
        $recCrossClientBoth = (Get-RecordsFor 'ZZZ-Regtest-Crossclienttimeout')[0]
        Check 'the first-ever codex subrecord gets the DEFAULT timeout, never the claude value' ([int]$recCrossClientBoth.clients.codex.timeout -eq 60)
        Check 'the existing claude subrecord timeout is unaffected' ([int]$recCrossClientBoth.clients.claude.timeout -eq 240)
        $crossClientCodexSettings = Get-Content -LiteralPath (Join-Path $projCrossClient '.codex\hooks.json') -Raw | ConvertFrom-Json
        Check 'the codex handler on disk carries the default timeout, not 240' ([int]$crossClientCodexSettings.hooks.Stop[0].hooks[0].timeout -eq 60)
    }
    finally { Remove-FixtureHook 'ZZZ-Regtest-Crossclienttimeout' }

    # =====================================================================
    # D4 (wrong-handler deletion): a handler whose command fields DISAGREE
    # (one matches THIS install, the other resolves to a DIFFERENT Hook Maker
    # hook) is not fully owned - deleting it would silence whatever the other
    # field pointed at, so a reinstall must leave it in place rather than
    # pruning it as stale.
    Write-Host '--- a handler with disagreeing command fields is preserved, never treated as stale ---' -ForegroundColor Cyan
    $fixtureDisagree = New-FixtureHook 'ZZZ-Regtest-Disagreefields'
    try {
        $projDisagree = New-Proj 'DisagreeFieldsProj'
        & $InstallScript -CustomHook $fixtureDisagree -Events @('Stop') -TargetProject $projDisagree -ClaudeOnly *> $null
        $disagreeSettings = Join-Path $projDisagree '.claude\settings.local.json'
        $disagreeJson = Get-Content -LiteralPath $disagreeSettings -Raw | ConvertFrom-Json
        $disagreeHandler = @(@($disagreeJson.hooks.Stop) | ForEach-Object { $_.hooks })[0]
        $disagreeRealCommand = [string]$disagreeHandler.command
        Check 'the baseline handler carries the real Hook Maker command' ($disagreeRealCommand -like '*Hook-Maker*ZZZ-Regtest-Disagreefields*')

        # Hand-edit in a SECOND command field that resolves to a DIFFERENT
        # hook - the same handler now disagrees with itself.
        $disagreeForeignTarget = 'powershell.exe -NoLogo -NoProfile -File "C:\Somewhere\.claude\hooks\Hook-Maker\ZZZ-Regtest-Otherhook\ZZZ-Regtest-Otherhook.ps1"'
        $disagreeHandler | Add-Member -MemberType NoteProperty -Name commandWindows -Value $disagreeForeignTarget -Force
        [System.IO.File]::WriteAllText($disagreeSettings, ($disagreeJson | ConvertTo-Json -Depth 50), (New-Object System.Text.UTF8Encoding $false))

        # A reinstall (repair) of the SAME hook must not delete this
        # now-ambiguous handler.
        & $InstallScript -CustomHook $fixtureDisagree -Events @('Stop') -TargetProject $projDisagree -ClaudeOnly *> $null
        $disagreeAfter = Get-Content -LiteralPath $disagreeSettings -Raw | ConvertFrom-Json
        $disagreeHandlersAfter = @(@($disagreeAfter.hooks.Stop) | ForEach-Object { $_.hooks })
        Check 'the disagreeing handler is still present after reinstall (not removed)' (
            @($disagreeHandlersAfter | Where-Object { (Get-HandlerFieldValue $_ 'commandWindows') -eq $disagreeForeignTarget }).Count -eq 1)
        Check 'the disagreeing handler still carries its original real command' (
            @($disagreeHandlersAfter | Where-Object { (Get-HandlerFieldValue $_ 'commandWindows') -eq $disagreeForeignTarget -and (Get-HandlerFieldValue $_ 'command') -eq $disagreeRealCommand }).Count -eq 1)
    }
    finally { Remove-FixtureHook 'ZZZ-Regtest-Disagreefields' }

    # =====================================================================
    # D4 (plain user command variant): Get-HandlerCommandValues only returns
    # fields that are actually PRESENT, so a second field that is a plain,
    # non-Hook-Maker-shaped user command is still real content, not "nothing
    # to disagree with" - it must block removal exactly like a different-hook
    # field does, or the user's own script gets silently deleted.
    Write-Host '--- a handler with a plain user command in the other field is preserved ---' -ForegroundColor Cyan
    $fixtureDisagreePlain = New-FixtureHook 'ZZZ-Regtest-Disagreeplaincmd'
    try {
        $projDisagreePlain = New-Proj 'DisagreePlainCmdProj'
        & $InstallScript -CustomHook $fixtureDisagreePlain -Events @('Stop') -TargetProject $projDisagreePlain -ClaudeOnly *> $null
        $disagreePlainSettings = Join-Path $projDisagreePlain '.claude\settings.local.json'
        $disagreePlainJson = Get-Content -LiteralPath $disagreePlainSettings -Raw | ConvertFrom-Json
        $disagreePlainHandler = @(@($disagreePlainJson.hooks.Stop) | ForEach-Object { $_.hooks })[0]
        $disagreePlainRealCommand = [string]$disagreePlainHandler.command

        # Hand-add a SECOND field carrying a plain, real, non-Hook-Maker user
        # command - not a different hook, just the user's own unrelated script.
        $disagreePlainUserCommand = 'powershell.exe -File "C:\Users\me\MyOwnTools\whatever.ps1"'
        $disagreePlainHandler | Add-Member -MemberType NoteProperty -Name commandWindows -Value $disagreePlainUserCommand -Force
        [System.IO.File]::WriteAllText($disagreePlainSettings, ($disagreePlainJson | ConvertTo-Json -Depth 50), (New-Object System.Text.UTF8Encoding $false))

        # A reinstall (repair) of the SAME hook must not delete this handler.
        & $InstallScript -CustomHook $fixtureDisagreePlain -Events @('Stop') -TargetProject $projDisagreePlain -ClaudeOnly *> $null
        $disagreePlainAfter = Get-Content -LiteralPath $disagreePlainSettings -Raw | ConvertFrom-Json
        $disagreePlainHandlersAfter = @(@($disagreePlainAfter.hooks.Stop) | ForEach-Object { $_.hooks })
        Check 'a handler with a plain user command in the other field is still present after reinstall (not removed)' (
            @($disagreePlainHandlersAfter | Where-Object { (Get-HandlerFieldValue $_ 'commandWindows') -eq $disagreePlainUserCommand }).Count -eq 1)
        Check 'that preserved handler still carries its original real command' (
            @($disagreePlainHandlersAfter | Where-Object { (Get-HandlerFieldValue $_ 'commandWindows') -eq $disagreePlainUserCommand -and (Get-HandlerFieldValue $_ 'command') -eq $disagreePlainRealCommand }).Count -eq 1)
    }
    finally { Remove-FixtureHook 'ZZZ-Regtest-Disagreeplaincmd' }

    # =====================================================================
    # DEFECT 5: ONE settings backup per install run, not one per hook.
    # Installing 20 hooks is 20 Install-Hook.ps1 invocations, and each used to
    # drop its own timestamped copy of the same settings.local.json - so the
    # one copy worth keeping, the state BEFORE the batch, sat buried among 19
    # mid-batch snapshots. The wizard marks its run in HOOKMAKER_BACKUP_RUN;
    # the first install of that run backs up and the rest must leave it alone.
    $fixtureBackupA = New-FixtureHook 'ZZZ-Regtest-Backupruna'
    $fixtureBackupB = New-FixtureHook 'ZZZ-Regtest-Backuprunb'
    $previousBackupRun = $env:HOOKMAKER_BACKUP_RUN
    try {
        # Marked run: one backup for the whole batch, and it is the PRE-batch file.
        $projBackupRun = New-Proj 'BackupRunMarkedProj'
        $backupRunDir = Join-Path $projBackupRun '.claude'
        $env:HOOKMAKER_BACKUP_RUN = ''
        & $InstallScript -CustomHook $fixtureBackupA -Events @('Stop') -TargetProject $projBackupRun -ClaudeOnly *> $null
        Get-ChildItem -LiteralPath $backupRunDir -Filter 'settings.local.json.backup-*' -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
        $env:HOOKMAKER_BACKUP_RUN = '20260728-010203'
        & $InstallScript -CustomHook $fixtureBackupB -Events @('Stop') -TargetProject $projBackupRun -ClaudeOnly *> $null
        & $InstallScript -CustomHook $fixtureBackupB -Events @('SessionStart') -TargetProject $projBackupRun -ClaudeOnly *> $null
        & $InstallScript -CustomHook $fixtureBackupA -Events @('SessionStart') -TargetProject $projBackupRun -ClaudeOnly *> $null
        $runBackups = @(Get-ChildItem -LiteralPath $backupRunDir -Filter 'settings.local.json.backup-*' -File -ErrorAction SilentlyContinue)
        Check 'three installs in one marked run leave exactly ONE settings backup' ($runBackups.Count -eq 1) ('backups=' + (@($runBackups.Name) -join ', '))
        Check 'the surviving backup is named for the run, not for one invocation' (
            $runBackups.Count -eq 1 -and $runBackups[0].Name -eq 'settings.local.json.backup-install-20260728-010203') ('name=' + (@($runBackups.Name) -join ', '))
        $runBackupText = ''
        if ($runBackups.Count -eq 1) { $runBackupText = [System.IO.File]::ReadAllText($runBackups[0].FullName) }
        Check 'it holds the state from BEFORE the batch, not a mid-batch snapshot' (
            $runBackupText -match 'ZZZ-Regtest-Backupruna' -and $runBackupText -notmatch 'ZZZ-Regtest-Backuprunb') $runBackupText

        # ONE backup per file AT A TIME. The per-run rule above stops copies
        # piling up WITHIN a run; nothing used to stop them piling up ACROSS
        # runs, so a machine accumulated 464 backup files (6.5 MB). A later run
        # must now leave exactly its own copy.
        $env:HOOKMAKER_BACKUP_RUN = '20260728-020304'
        & $InstallScript -CustomHook $fixtureBackupA -Events @('Stop') -TargetProject $projBackupRun -ClaudeOnly *> $null
        $afterSecondRun = @(Get-ChildItem -LiteralPath $backupRunDir -Filter 'settings.local.json.backup-*' -File -ErrorAction SilentlyContinue)
        Check 'a SECOND run leaves exactly one backup - the previous run''s copy is gone' (
            $afterSecondRun.Count -eq 1) ('backups=' + (@($afterSecondRun.Name) -join ', '))
        Check 'and the survivor is the CURRENT run''s copy, not the stale one' (
            $afterSecondRun.Count -eq 1 -and $afterSecondRun[0].Name -eq 'settings.local.json.backup-install-20260728-020304') (
            'name=' + (@($afterSecondRun.Name) -join ', '))
        # Pruning is scoped to the exact file it backs up. A neighbour whose name
        # merely STARTS with the same text, and an unrelated file of the user's
        # that happens to use the same suffix convention, must both survive.
        $neighbourBackup = Join-Path $backupRunDir 'settings.local.json.extra.backup-install-19990101-000000'
        $foreignBackup = Join-Path $backupRunDir 'my-database.sqlite3.backup-19990101-000000'
        Write-Utf8 $neighbourBackup 'not ours'
        Write-Utf8 $foreignBackup 'user file'
        $env:HOOKMAKER_BACKUP_RUN = '20260728-030405'
        & $InstallScript -CustomHook $fixtureBackupA -Events @('SessionStart') -TargetProject $projBackupRun -ClaudeOnly *> $null
        Check 'pruning never touches a DIFFERENT file whose name shares the prefix' (Test-Path -LiteralPath $neighbourBackup)
        Check 'pruning never touches an unrelated file using the same backup suffix' (Test-Path -LiteralPath $foreignBackup)
        Check 'and it still left exactly one backup of the file it owns' (
            @(Get-ChildItem -LiteralPath $backupRunDir -Filter 'settings.local.json.backup-*' -File -ErrorAction SilentlyContinue).Count -eq 1)

        # A run marker that sanitizes to nothing must not produce a nameless
        # backup file - it falls back to the per-invocation timestamp, which is
        # also the shape an unmarked single install keeps.
        $projBackupJunk = New-Proj 'BackupRunJunkProj'
        $backupJunkDir = Join-Path $projBackupJunk '.claude'
        $env:HOOKMAKER_BACKUP_RUN = ''
        & $InstallScript -CustomHook $fixtureBackupA -Events @('Stop') -TargetProject $projBackupJunk -ClaudeOnly *> $null
        Get-ChildItem -LiteralPath $backupJunkDir -Filter 'settings.local.json.backup-*' -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
        $env:HOOKMAKER_BACKUP_RUN = '///'
        & $InstallScript -CustomHook $fixtureBackupB -Events @('Stop') -TargetProject $projBackupJunk -ClaudeOnly *> $null
        $junkBackups = @(Get-ChildItem -LiteralPath $backupJunkDir -Filter 'settings.local.json.backup-*' -File -ErrorAction SilentlyContinue)
        Check 'an unusable run marker falls back to a real per-invocation name' (
            $junkBackups.Count -eq 1 -and $junkBackups[0].Name -match '^settings\.local\.json\.backup-\d{8}-\d{6}$') ('name=' + (@($junkBackups.Name) -join ', '))
    }
    finally {
        $env:HOOKMAKER_BACKUP_RUN = $previousBackupRun
        Remove-FixtureHook 'ZZZ-Regtest-Backupruna'
        Remove-FixtureHook 'ZZZ-Regtest-Backuprunb'
    }
