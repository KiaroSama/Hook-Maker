# Dot-sourced scenario block of Test-InstallRegistry.ps1: installer safety
# boundaries - a standalone hook source never drags its parent directory
# (.env/.git/node_modules/secrets stay behind); direct installer inputs are
# validated before any mutation; ownership is proven by the managed runtime
# path, never a basename; runtime replacement is transactional (failed
# staging keeps the old runtime); the install plan ships per-hook artifacts
# (guarded runner) and the managed manifest covers every copied file
# (.env, helpers, added/removed/tampered files, unexpected runtime files).
# NOT a standalone suite: this file is dot-sourced into the entry suite's
# scope and relies on its harness (Check, $script:Pass/$script:Fail), shared
# fixtures and helper functions. Run scripts\Test-InstallRegistry.ps1 instead.

    # =====================================================================
    # =====================================================================
    # A hook source OUTSIDE a recognized hooks root is a STANDALONE script:
    # only that file is installed. Previously the installer recursively copied
    # the script's whole parent directory, so pointing -CustomHook at a script
    # inside a project copied that project's .git/.env/credentials/source into
    # a settings-registered runtime directory.
    Write-Host '--- custom-hook source boundaries: never copy an arbitrary parent directory ---' -ForegroundColor Cyan
    $victim = Join-Path $Work 'victim-project'
    New-Item -ItemType Directory -Path (Join-Path $victim '.git'), (Join-Path $victim 'node_modules\pkg'), (Join-Path $victim 'src') -Force | Out-Null
    Write-Utf8 (Join-Path $victim 'zzz-standalone-hook.ps1') "exit 0`n"
    $secretValue = 'REGTEST-SECRET-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    Write-Utf8 (Join-Path $victim '.env') ('AWS_SECRET_ACCESS_KEY=' + $secretValue)
    Write-Utf8 (Join-Path $victim 'secrets.md') 'db password: hunter2'
    Write-Utf8 (Join-Path $victim '.git\config') 'url = git@github.com:me/private.git'
    Write-Utf8 (Join-Path $victim 'node_modules\pkg\index.js') 'module.exports=1'
    Write-Utf8 (Join-Path $victim 'src\proprietary.cs') 'class Secret {}'
    $projStandalone = New-Proj 'StandaloneSourceProj'
    & $InstallScript -CustomHook (Join-Path $victim 'zzz-standalone-hook.ps1') -Events @('Stop') -TargetProject $projStandalone -ClaudeOnly *> $null
    $standaloneRoot = Join-Path $projStandalone '.claude\hooks\Hook-Maker'
    $standaloneFiles = @(Get-ChildItem -LiteralPath $standaloneRoot -Recurse -Force -File -ErrorAction SilentlyContinue)
    $standaloneNames = @($standaloneFiles | ForEach-Object { $_.Name })
    Check 'a standalone hook installs only its own script plus the shared library' ((@($standaloneNames | Sort-Object) -join ',') -eq '_hooklib.ps1,zzz-standalone-hook.ps1')
    Check 'the neighbouring project .env is never copied' (@($standaloneNames | Where-Object { $_ -eq '.env' }).Count -eq 0)
    Check 'the neighbouring project secrets.md is never copied' (@($standaloneNames | Where-Object { $_ -eq 'secrets.md' }).Count -eq 0)
    Check 'git metadata is never copied' (@($standaloneFiles | Where-Object { $_.FullName -like '*.git*' -and $_.Name -eq 'config' }).Count -eq 0)
    Check 'node_modules is never copied' (@($standaloneFiles | Where-Object { $_.FullName -like '*node_modules*' }).Count -eq 0)
    Check 'unrelated source files are never copied' (@($standaloneNames | Where-Object { $_ -eq 'proprietary.cs' }).Count -eq 0)
    $standaloneBytes = ''
    foreach ($standaloneFile in $standaloneFiles) { $standaloneBytes += [System.IO.File]::ReadAllText($standaloneFile.FullName) }
    Check 'no secret value from the neighbouring project reaches the runtime' ($standaloneBytes -notmatch [regex]::Escape($secretValue))
    Check 'a standalone hook is named after its SCRIPT, not its parent folder' (Test-Path -LiteralPath (Join-Path $standaloneRoot 'zzz-standalone-hook\zzz-standalone-hook.ps1'))
    $projPackage = New-Proj 'PackagedSourceProj'
    & $InstallScript -CustomHook (Join-Path $RealHooksDir 'Secrets-Check\Secrets-Check.ps1') -Events @('Stop') -TargetProject $projPackage -ClaudeOnly *> $null
    Check 'a packaged shipped hook still installs its package contents' (Test-Path -LiteralPath (Join-Path $projPackage '.claude\hooks\Hook-Maker\Secrets-Check\Secrets-Check.ps1'))
    Check 'a package never ships its .env.example template' (-not (Test-Path -LiteralPath (Join-Path $projPackage '.claude\hooks\Hook-Maker\Secrets-Check\.env.example')))

    # =====================================================================
    Write-Host '--- direct installer inputs are validated before anything is mutated ---' -ForegroundColor Cyan
    $HookForValidation = Join-Path $RealHooksDir 'Ai-Memory-Check\Ai-Memory-Check.ps1'
    $projValidate = New-Proj 'ValidateInputsProj'
    $bothSwitches = $false
    try { & $InstallScript -CustomHook $HookForValidation -TargetProject $projValidate -Events @('Stop') -ClaudeOnly -CodexOnly *> $null } catch { $bothSwitches = $true }
    Check 'ClaudeOnly and CodexOnly together are rejected' $bothSwitches
    Check 'the rejected invocation wrote no settings at all' (-not (Test-Path -LiteralPath (Join-Path $projValidate '.claude')))
    $emptyEvents = $false
    try { & $InstallScript -CustomHook $HookForValidation -TargetProject $projValidate -Events @() -ClaudeOnly *> $null } catch { $emptyEvents = $true }
    Check 'an empty event list is rejected' $emptyEvents
    $badEvent = $false
    try { & $InstallScript -CustomHook $HookForValidation -TargetProject $projValidate -Events @('NotARealEvent') -ClaudeOnly *> $null } catch { $badEvent = $true }
    Check 'an unsupported event name is rejected' $badEvent
    $missingTargetPath = Join-Path $Work 'target-that-does-not-exist'
    $badTarget = $false
    try { & $InstallScript -CustomHook $HookForValidation -TargetProject $missingTargetPath -Events @('Stop') -ClaudeOnly *> $null } catch { $badTarget = $true }
    Check 'a nonexistent target project is rejected' $badTarget
    Check 'the rejected target directory was not created' (-not (Test-Path -LiteralPath $missingTargetPath))
    & $InstallScript -CustomHook $HookForValidation -TargetProject $projValidate -Events @('Stop', 'Stop', 'SessionStart') -ClaudeOnly *> $null
    $validatedJson = Get-Content -LiteralPath (Join-Path $projValidate '.claude\settings.local.json') -Raw | ConvertFrom-Json
    Check 'duplicate events are normalized to one registration each' (@($validatedJson.hooks.PSObject.Properties).Count -eq 2)

    # =====================================================================
    # Ownership is proven by the managed runtime PATH, never by a basename.
    Write-Host '--- unrelated handlers with the same script basename are preserved ---' -ForegroundColor Cyan
    $projBasename = New-Proj 'BasenameIdentityProj'
    & $InstallScript -CustomHook $HookForValidation -TargetProject $projBasename -Events @('Stop') -ClaudeOnly *> $null
    $basenameSettings = Join-Path $projBasename '.claude\settings.local.json'
    $basenameJson = Get-Content -LiteralPath $basenameSettings -Raw | ConvertFrom-Json
    $userHandlerA = [pscustomobject]@{ hooks = @([pscustomobject]@{ type = 'command'; command = 'pwsh -File "C:\Users\me\MyTools\Ai-Memory-Check.ps1"'; timeout = 99 }) }
    $userHandlerB = [pscustomobject]@{ hooks = @([pscustomobject]@{ type = 'command'; commandWindows = 'powershell -File "D:\Other\Ai-Memory-Check.ps1"'; timeout = 5 }) }
    $basenameJson.hooks.Stop = @($basenameJson.hooks.Stop) + @($userHandlerA) + @($userHandlerB)
    [System.IO.File]::WriteAllText($basenameSettings, ($basenameJson | ConvertTo-Json -Depth 50), (New-Object System.Text.UTF8Encoding $false))
    & $InstallScript -CustomHook $HookForValidation -TargetProject $projBasename -Events @('Stop') -ClaudeOnly *> $null
    $basenameAfter = Get-Content -LiteralPath $basenameSettings -Raw | ConvertFrom-Json
    $basenameHandlers = @(@($basenameAfter.hooks.Stop) | ForEach-Object { $_.hooks })
    Check 'a user same-basename handler in command survives a reinstall' (@($basenameHandlers | Where-Object { (Get-HandlerFieldValue $_ 'command') -like '*MyTools*' }).Count -eq 1)
    Check 'a user same-basename handler in commandWindows survives a reinstall' (@($basenameHandlers | Where-Object { (Get-HandlerFieldValue $_ 'commandWindows') -like '*Other*' }).Count -eq 1)
    Check 'the real Hook Maker registration is still present exactly once' (@($basenameHandlers | Where-Object { (Get-HandlerFieldValue $_ 'command') -like '*Hook-Maker*' }).Count -eq 1)

    # =====================================================================
    # A failed replacement must never leave a working runtime worse off.
    Write-Host '--- runtime replacement is transactional (failed staging keeps the old runtime) ---' -ForegroundColor Cyan
    $fixtureTx = New-FixtureHook 'ZZZ-Regtest-Transaction' "exit 0 # good`n"
    try {
        $projTx = New-Proj 'TransactionProj'
        & $InstallScript -CustomHook $fixtureTx -Events @('Stop') -TargetProject $projTx -ClaudeOnly *> $null
        $txRuntimeRoot = Join-Path $projTx '.claude\hooks\Hook-Maker'
        $txScript = Join-Path $txRuntimeRoot 'ZZZ-Regtest-Transaction\ZZZ-Regtest-Transaction.ps1'
        Check 'baseline transactional install succeeded' (Test-Path -LiteralPath $txScript)
        $txGoodHash = (Get-FileHash -LiteralPath $txScript -Algorithm SHA256).Hash
        $txMissingSource = Join-Path $Work 'no-such-file.txt'
        $txPlan = @(Get-InstallPlanFor -HookScript $fixtureTx -ToolRoot $ToolRoot) + @(New-PlanArtifact -RelativePath 'ZZZ-Regtest-Transaction/missing.txt' -Kind 'File' -SourcePath $txMissingSource)
        $txThrew = $false
        try { Install-PlannedRuntime -Plan $txPlan -RuntimeRoot $txRuntimeRoot -FriendlyName 'ZZZ-Regtest-Transaction' | Out-Null } catch { $txThrew = $true }
        Check 'a staging failure is surfaced as an error' $txThrew
        Check 'the previous runtime still exists after a failed staging' (Test-Path -LiteralPath $txScript)
        Check 'the previous runtime is byte-identical after a failed staging' ((Get-FileHash -LiteralPath $txScript -Algorithm SHA256).Hash -eq $txGoodHash)
        Check 'no staging or set-aside directory is left behind' (@(Get-ChildItem -LiteralPath $txRuntimeRoot -Directory -Force | Where-Object { $_.Name -like '.hookmaker-*' }).Count -eq 0)
    }
    finally { Remove-FixtureHook 'ZZZ-Regtest-Transaction' }

    # =====================================================================
    # The managed manifest must cover EVERY file the installer copies, not
    # just the main script + _hooklib + sync config.
    # =====================================================================
    Write-Host '--- Test-Run-Guard ships its guarded runner beside the hook (Review-1) ---' -ForegroundColor Cyan
    $trgHook = Join-Path $RealHooksDir 'Test-Run-Guard\Test-Run-Guard.ps1'
    if (Test-Path -LiteralPath $trgHook -PathType Leaf) {
        $trgPlan = @(Get-InstallPlanFor -HookScript $trgHook -ToolRoot $ToolRoot)
        $trgRunner = @($trgPlan | Where-Object { $_.relativePath -eq 'Test-Run-Guard/scripts/Run-Tests-Guarded.ps1' })
        Check 'the install plan ships scripts/Run-Tests-Guarded.ps1 inside the Test-Run-Guard runtime' ($trgRunner.Count -eq 1) (($trgPlan | ForEach-Object { $_.relativePath }) -join ', ')
        Check 'the shipped runner is an Immutable managed artifact (drift-repairable)' ($trgRunner.Count -eq 1 -and $trgRunner[0].ownership -eq 'Immutable') ([string]$trgRunner[0].ownership)
        # No OTHER hook drags the runner along.
        $secHook = Join-Path $RealHooksDir 'Secrets-Check\Secrets-Check.ps1'
        if (Test-Path -LiteralPath $secHook -PathType Leaf) {
            $secPlan = @(Get-InstallPlanFor -HookScript $secHook -ToolRoot $ToolRoot)
            Check 'an unrelated hook does NOT ship the guarded runner' (@($secPlan | Where-Object { $_.relativePath -match 'Run-Tests-Guarded' }).Count -eq 0)
        }
    }

    # =====================================================================
    Write-Host '--- managed-file manifest covers .env and copied helpers ---' -ForegroundColor Cyan
    $fixtureMan = New-FixtureHook 'ZZZ-Regtest-Manifest' "exit 0 # manifest`n"
    try {
        $manDir = Split-Path -Parent $fixtureMan
        Write-Utf8 (Join-Path $manDir '.env') "EVENTS=Stop`n"
        Write-Utf8 (Join-Path $manDir '.env.example') "EVENTS=Stop`n"
        Write-Utf8 (Join-Path $manDir 'helper.ps1') "# helper v1`n"
        $projMan = New-Proj 'ManifestProj'
        & $InstallScript -CustomHook $fixtureMan -Events @('Stop') -TargetProject $projMan -ClaudeOnly *> $null
        $recMan = (Get-RecordsFor 'ZZZ-Regtest-Manifest')[0]
        $manPaths = @($recMan.sourceManifest | ForEach-Object { $_.path })
        Check 'the manifest includes the hook-local .env' (@($manPaths | Where-Object { $_ -like '*/.env' }).Count -eq 1)
        Check 'the manifest includes a copied helper file' (@($manPaths | Where-Object { $_ -like '*/helper.ps1' }).Count -eq 1)
        Check 'the manifest excludes .env.example (never copied by the installer)' (@($manPaths | Where-Object { $_ -like '*.env.example' }).Count -eq 0)
        Check 'baseline manifest install is current' ((Get-InstallIntegrity -Record $recMan -ToolRoot $ToolRoot).Status -eq 'current')

        # 1. .env-only source change must trigger update
        Write-Utf8 (Join-Path $manDir '.env') "EVENTS=Stop`nEXTRA=1`n"
        $m = Get-InstallIntegrity -Record $recMan -ToolRoot $ToolRoot
        Check 'a .env-only source change triggers an update' ($m.Status -eq 'update' -and $m.Detail -match '\.env') $m.Detail
        Write-Utf8 (Join-Path $manDir '.env') "EVENTS=Stop`n"

        # 2. helper-only source change must trigger update
        Write-Utf8 (Join-Path $manDir 'helper.ps1') "# helper v2`n"
        $m = Get-InstallIntegrity -Record $recMan -ToolRoot $ToolRoot
        Check 'a copied-helper-only source change triggers an update' ($m.Status -eq 'update' -and $m.Detail -match 'helper\.ps1') $m.Detail
        Write-Utf8 (Join-Path $manDir 'helper.ps1') "# helper v1`n"

        # 3. a managed file ADDED to source
        Write-Utf8 (Join-Path $manDir 'extra.psd1') "@{}`n"
        $m = Get-InstallIntegrity -Record $recMan -ToolRoot $ToolRoot
        Check 'a newly added managed source file triggers an update' ($m.Status -eq 'update' -and $m.Detail -match 'added') $m.Detail
        Remove-Item -LiteralPath (Join-Path $manDir 'extra.psd1') -Force

        # 4. a managed file REMOVED from source
        Remove-Item -LiteralPath (Join-Path $manDir 'helper.ps1') -Force
        $m = Get-InstallIntegrity -Record $recMan -ToolRoot $ToolRoot
        Check 'a removed managed source file triggers an update' ($m.Status -eq 'update' -and $m.Detail -match 'removed') $m.Detail
        Write-Utf8 (Join-Path $manDir 'helper.ps1') "# helper v1`n"
        Check 'restoring source returns the install to current' ((Get-InstallIntegrity -Record $recMan -ToolRoot $ToolRoot).Status -eq 'current')

        # 5. the INSTALLED .env corrupted (source untouched)
        $installedEnv = Join-Path ([string]$recMan.clients.claude.runtimeRoot) 'ZZZ-Regtest-Manifest\.env'
        Add-Content -LiteralPath $installedEnv -Value 'TAMPERED=1'
        $m = Get-InstallIntegrity -Record $recMan -ToolRoot $ToolRoot
        Check 'a corrupted installed .env triggers an update' ($m.Status -eq 'update' -and $m.Detail -match 'installed file modified') $m.Detail
        Write-Utf8 $installedEnv "EVENTS=Stop`n"

        # 6. An UNEXPECTED file inside a managed runtime directory is drift.
        # The old behaviour excluded .log/.tmp/.bak by extension - a second
        # source of truth that disagreed with the install plan (it also excluded
        # the generated SYNC-PROJECTS.txt, which made every sync-engine install
        # permanently stale). Mutable artifacts are now declared by exact path
        # via $script:ManagedRuntimeMutablePaths, intentionally empty because no
        # shipped hook writes into its own runtime directory.
        $strayFile = Join-Path (Join-Path ([string]$recMan.clients.claude.runtimeRoot) 'ZZZ-Regtest-Manifest') 'run.log'
        Write-Utf8 $strayFile 'runtime noise'
        $strayResult = Get-InstallIntegrity -Record $recMan -ToolRoot $ToolRoot
        Check 'an unexpected file in a managed runtime directory is detected as drift' ($strayResult.Status -eq 'update') $strayResult.Detail
        Remove-Item -LiteralPath $strayFile -Force
        Check 'removing the unexpected file restores current' ((Get-InstallIntegrity -Record $recMan -ToolRoot $ToolRoot).Status -eq 'current')
    }
    finally { Remove-FixtureHook 'ZZZ-Regtest-Manifest' }
