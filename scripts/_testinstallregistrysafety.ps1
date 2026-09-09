# Dot-sourced scenario block of Test-InstallRegistry.ps1: installer safety
# boundaries - a standalone hook source never drags its parent directory
# (.env/.git/node_modules/secrets stay behind); direct installer inputs are
# validated before any mutation; ownership is proven by the managed runtime
# path, never a basename; runtime replacement is transactional (failed
# staging keeps the old runtime); the install plan ships per-hook artifacts
# (guarded runner) and the managed manifest covers every copied file
# (.env, helpers, added/removed/tampered files, unexpected runtime files);
# every managed runtime carries planned ownership metadata whose projectKey
# recomputes from the project root, whose bounded manifest covers the runtime
# script it names, that drifts when deleted or edited, is repaired by the update
# path, and never holds a command, an absolute path, a secret or source content.
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
    # The EXACT shipped artifact set. Every entry is deliberate: the private
    # library copy, the hook script itself, and the ownership metadata that says
    # which install owns this directory. Anything else appearing here is either a
    # new planned artifact (update this list in the same change) or a file the
    # installer is writing that no plan accounts for - the defect that made the
    # updater reinstall a client for ever.
    # ORDINAL sort, not Sort-Object: Sort-Object compares culture-sensitively and
    # orders '_hooklib.ps1' BEFORE '.hookmaker-runtime.json' on an en-US host, so a
    # culture-dependent expected string here would be a latent flake.
    $standaloneSorted = @($standaloneNames)
    [System.Array]::Sort($standaloneSorted, [System.StringComparer]::Ordinal)
    Check 'a standalone hook installs its own script, the shared library and its ownership metadata' (
        (($standaloneSorted) -join ',') -ceq '.hookmaker-runtime.json,_hooklib.ps1,zzz-standalone-hook.ps1') (($standaloneSorted) -join ',')
    Check 'the neighbouring project .env is never copied' (@($standaloneNames | Where-Object { $_ -eq '.env' }).Count -eq 0)
    Check 'the neighbouring project secrets.md is never copied' (@($standaloneNames | Where-Object { $_ -eq 'secrets.md' }).Count -eq 0)
    Check 'git metadata is never copied' (@($standaloneFiles | Where-Object { $_.FullName -like '*.git*' -and $_.Name -eq 'config' }).Count -eq 0)
    Check 'node_modules is never copied' (@($standaloneFiles | Where-Object { $_.FullName -like '*node_modules*' }).Count -eq 0)
    Check 'unrelated source files are never copied' (@($standaloneNames | Where-Object { $_ -eq 'proprietary.cs' }).Count -eq 0)
    $standaloneBytes = ''
    foreach ($standaloneFile in $standaloneFiles) { $standaloneBytes += [System.IO.File]::ReadAllText($standaloneFile.FullName) }
    Check 'the neighbouring project .env is not even NAMED by the ownership metadata' ($standaloneBytes -notmatch 'AWS_SECRET_ACCESS_KEY')
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
    # A virtualenv inside a package is excluded by its PEP 405 MARKER, not by
    # its name. '.venv'/'venv' in $script:PlanForbiddenDirectoryNames are only
    # the conventional spellings, so an oddly named one was copied wholesale
    # into every managed runtime - large, and broken on arrival, because a venv
    # stores absolute paths to the interpreter that created it.
    Write-Host '--- an oddly named virtualenv inside a package is never planned ---' -ForegroundColor Cyan
    $venvFixture = New-FixtureHook 'ZZZ-Regtest-VenvPkg' "exit 0`n"
    try {
        $venvPkgRoot = Split-Path -Parent $venvFixture
        $oddVenvDir = Join-Path $venvPkgRoot 'spotdl-env'
        New-Item -ItemType Directory -Path (Join-Path $oddVenvDir 'Lib') -Force | Out-Null
        Write-Utf8 (Join-Path $oddVenvDir 'pyvenv.cfg') "home = C:\Python312`n"
        Write-Utf8 (Join-Path $oddVenvDir 'Lib\site.py') "# third-party content`n"
        New-Item -ItemType Directory -Path (Join-Path $venvPkgRoot 'data') -Force | Out-Null
        Write-Utf8 (Join-Path $venvPkgRoot 'data\keep.txt') "real package content`n"
        $venvPlanPaths = @(@(Get-InstallPlanFor -HookScript $venvFixture -ToolRoot $ToolRoot) | ForEach-Object { [string]$_.relativePath })
        Check 'the virtualenv marker file itself is not planned' (
            @($venvPlanPaths | Where-Object { $_ -like '*pyvenv.cfg' }).Count -eq 0) ($venvPlanPaths -join ',')
        Check 'a file inside the oddly named virtualenv is not planned' (
            @($venvPlanPaths | Where-Object { $_ -like '*spotdl-env*' }).Count -eq 0) ($venvPlanPaths -join ',')
        # The guard must EXCLUDE the venv without going blind to the package.
        Check 'ordinary package content beside it is still planned' (
            @($venvPlanPaths | Where-Object { $_ -like '*keep.txt' }).Count -eq 1) ($venvPlanPaths -join ',')
    }
    finally { Remove-FixtureHook 'ZZZ-Regtest-VenvPkg' }

    # =====================================================================
    # The runtime metadata must state BOTH halves of what an update does.
    # runtimeManifest is what gets replaced; preservedUserConfig is what gets
    # carried across. A reader inspecting .hookmaker-runtime.json to ask "is my
    # .env safe?" finds only the manifest otherwise, reads its absence as "not
    # protected", and reports the bug again - which happened three times.
    Write-Host '--- runtime metadata names the preserved user config, not just the managed files ---' -ForegroundColor Cyan
    $metaFixture = New-FixtureHook 'ZZZ-Regtest-Metadoc' "exit 0`n"
    try {
        $projMeta = New-Proj 'MetaConfigProj'
        & $InstallScript -CustomHook $metaFixture -Events @('Stop') -TargetProject $projMeta -ClaudeOnly *> $null
        # No internal CamelCase in the fixture name on purpose: the installer
        # derives the friendly name by splitting CamelCase, so a 'MetaConfig'
        # fixture installs as 'Meta-Config' and a hand-built path misses it.
        $metaPath = Join-Path $projMeta '.claude\hooks\Hook-Maker\ZZZ-Regtest-Metadoc\.hookmaker-runtime.json'
        Check 'the runtime metadata document exists' (Test-Path -LiteralPath $metaPath -PathType Leaf) $metaPath
        $metaDoc = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
        Check 'it declares the schema version that carries the field' ([int]$metaDoc.schemaVersion -ge 2) ([string]$metaDoc.schemaVersion)
        Check 'it names .env as preserved user config' (
            @($metaDoc.preservedUserConfig) -contains '.env') (@($metaDoc.preservedUserConfig) -join ',')
        # The two halves must stay DISJOINT: a path in both would be replaced and
        # preserved at once, and a .env inside runtimeManifest is exactly the
        # drift-on-every-configured-hook bug this pair exists to prevent.
        $managedPaths = @(@($metaDoc.runtimeManifest) | ForEach-Object { [string]$_.path })
        Check 'no preserved path is also a managed manifest entry' (
            @($managedPaths | Where-Object { $_ -like '*.env' }).Count -eq 0) ($managedPaths -join ',')
    }
    finally { Remove-FixtureHook 'ZZZ-Regtest-Metadoc' }

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
    # Install-generated ownership metadata: <runtime>/<hook>/.hookmaker-runtime.json.
    #
    # A managed runtime is self-contained, so a hook executing from it cannot read
    # the tool root's install registry. This file is the only ownership evidence
    # available at runtime, and projectKey is the load-bearing field: it must be
    # RECOMPUTABLE from the project root with the same helpers the hooks use, or a
    # runtime directory copied in from another project reads as belonging here.
    Write-Host '--- install-generated runtime ownership metadata ---' -ForegroundColor Cyan
    $ownFixtureName = 'ZZZ-Regtest-Ownership'
    $ownFixture = New-FixtureHook $ownFixtureName "exit 0 # ownership v1`n"
    try {
        $ownSourceDir = Split-Path -Parent $ownFixture
        $ownEnvValue = 'REGTEST-ENVVALUE-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        Write-Utf8 (Join-Path $ownSourceDir '.env') ('TOKEN=' + $ownEnvValue + "`n")
        $ownProject = New-Proj 'OwnershipMetaProj'
        & $InstallScript -CustomHook $ownFixture -Events @('SessionStart') -TargetProject $ownProject -Clients @('claude', 'codex') *> $null
        $ownRecord = @(Get-RecordsFor $ownFixtureName | Where-Object { [string]$_.targetProjectRoot -eq $ownProject })[0]

        # ---- planned, not side-written ------------------------------------
        # The launcher was originally written beside the runtime AFTER the plan had
        # committed, so no artifact accounted for it and every later evaluation
        # reported "unexpected managed file". These assertions are what stop this
        # file repeating that: it is a Generated/Immutable PLAN artifact, so it is
        # staged, hash-verified before the swap, rolled back with everything else,
        # and drift-detectable.
        $ownIdentity = New-RuntimeIdentity -Client 'claude' -Scope 'project' -RecordId ([string]$ownRecord.id) -ProjectRoot $ownProject
        $ownPlan = @(Get-InstallPlanFor -HookScript $ownFixture -ToolRoot $ToolRoot -RuntimeIdentity $ownIdentity)
        $ownPlanned = @($ownPlan | Where-Object { $_.relativePath -eq ($ownFixtureName + '/.hookmaker-runtime.json') })
        Check 'the ownership metadata is a PLANNED artifact, not a file written beside the runtime' ($ownPlanned.Count -eq 1) ((@($ownPlan | ForEach-Object { $_.relativePath })) -join ', ')
        Check 'it is Generated + Immutable, so it is hash-verified and drift-repairable' (
            $ownPlanned.Count -eq 1 -and $ownPlanned[0].kind -eq 'Generated' -and $ownPlanned[0].ownership -eq 'Immutable') (
            [string]$ownPlanned[0].kind + '/' + [string]$ownPlanned[0].ownership)
        Check 'no metadata artifact is planned when no install identity is supplied (the SOURCE manifest stays client-agnostic)' (
            @(@(Get-InstallPlanFor -HookScript $ownFixture -ToolRoot $ToolRoot) | Where-Object { $_.relativePath -like '*hookmaker-runtime.json' }).Count -eq 0)
        $ownSourceManifest = @(Get-ManagedSourceManifest -ToolRoot $ToolRoot -HookScript $ownFixture -SourceDir $ownSourceDir -FriendlyName $ownFixtureName)
        Check 'the client-agnostic source manifest does NOT carry the metadata (identity is not source)' (
            @($ownSourceManifest | Where-Object { $_.path -like '*hookmaker-runtime.json' }).Count -eq 0)

        # ---- present for every client, with that client's own identity ----
        # Same source, two runtimes: the ONLY difference between them is what
        # this file says, which is exactly why the expected manifest has to be
        # per-client rather than shared.
        $ownDocuments = @{}
        foreach ($ownClient in @('claude', 'codex')) {
            $ownRuntimeRoot = [string]$ownRecord.clients.$ownClient.runtimeRoot
            $ownPath = Join-Path (Join-Path $ownRuntimeRoot $ownFixtureName) '.hookmaker-runtime.json'
            Check ('the ' + $ownClient + ' runtime carries ownership metadata') (Test-Path -LiteralPath $ownPath -PathType Leaf) $ownPath
            $ownRaw = [System.IO.File]::ReadAllText($ownPath, [System.Text.Encoding]::UTF8)
            $ownDocuments[$ownClient] = [pscustomobject]@{ Path = $ownPath; Raw = $ownRaw; Json = (($ownRaw | ConvertFrom-Json)) }
        }

        # ---- the contract: EXACTLY these fields, nothing more -------------
        # schemaVersion 2 added 'preservedUserConfig' as the LAST field. The order
        # is part of the contract, so a new field goes at the end and the version
        # moves with it - a consumer pinned to 1 must not silently read a 2.
        $ownExpectedFields = @('schemaVersion', 'recordId', 'friendlyName', 'client', 'scope', 'projectKey',
            'registrationName', 'runtimeScriptRelativePath', 'runtimeManifest', 'preservedUserConfig')
        foreach ($ownClient in @('claude', 'codex')) {
            $ownJson = $ownDocuments[$ownClient].Json
            $ownFields = @($ownJson.PSObject.Properties | ForEach-Object { $_.Name })
            Check ('the ' + $ownClient + ' metadata carries exactly the contract fields, in order') (
                (($ownFields) -join ',') -ceq (($ownExpectedFields) -join ',')) (($ownFields) -join ',')
            Check ('the ' + $ownClient + ' metadata states schemaVersion 2, this record id, this hook and this client') (
                $ownJson.schemaVersion -eq 2 -and
                ([string]$ownJson.recordId) -ceq ([string]$ownRecord.id) -and
                ([string]$ownJson.friendlyName) -ceq $ownFixtureName -and
                ([string]$ownJson.client) -ceq $ownClient -and
                ([string]$ownJson.scope) -ceq 'project') (
                [string]$ownJson.recordId + ' / ' + [string]$ownJson.friendlyName + ' / ' + [string]$ownJson.client + ' / ' + [string]$ownJson.scope)
        }

        # ---- projectKey: recomputed the way a HOOK would ------------------
        # Derived from the REAL producers (Normalize-Path then Get-ShortHash out of
        # hooks\_hooklib.ps1), never re-implemented here: a shared-state test that
        # rebuilds the derivation agrees with itself and can disagree with
        # production, which is exactly how this project shipped three sites keying
        # one state file three different ways.
        $ownRecomputed = Get-ShortHash ((Normalize-Path $ownProject).ToLowerInvariant())
        foreach ($ownClient in @('claude', 'codex')) {
            Check ('the ' + $ownClient + ' projectKey recomputes from the project root') (
                ([string]$ownDocuments[$ownClient].Json.projectKey) -ceq $ownRecomputed) (
                [string]$ownDocuments[$ownClient].Json.projectKey + ' vs ' + $ownRecomputed)
        }
        # Adversarial spellings of the same root must key identically, or a hook
        # resolving its own cwd slightly differently reads as a foreign copy.
        $ownSpellingKeys = @(@($ownProject, ($ownProject + '\'), (Join-Path $ownProject '.\'), $ownProject.ToUpperInvariant()) |
            ForEach-Object { Get-RuntimeMetadataProjectKey -Scope 'project' -ProjectRoot $_ })
        Check 'a trailing separator, a dot segment and a case change all yield the same projectKey' (
            (@($ownSpellingKeys | Sort-Object -Unique).Count -eq 1) -and $ownSpellingKeys[0] -ceq $ownRecomputed) (($ownSpellingKeys) -join ' ')
        # A DIFFERENT project must not produce this key - the whole point.
        Check 'a different project root yields a different projectKey (a copied-in runtime is detectable)' (
            (Get-RuntimeMetadataProjectKey -Scope 'project' -ProjectRoot (New-Proj 'OwnershipOtherProj')) -cne $ownRecomputed)

        # ---- registrationName / runtimeScriptRelativePath -----------------
        Check 'claude and codex record the managed runtime ownership segment as their registration identity' (
            ([string]$ownDocuments['claude'].Json.registrationName) -ceq ('Hook-Maker/' + $ownFixtureName) -and
            ([string]$ownDocuments['codex'].Json.registrationName) -ceq ('Hook-Maker/' + $ownFixtureName)) (
            [string]$ownDocuments['claude'].Json.registrationName)
        Check 'claude/codex name <hook>.ps1 as the runtime script their registration invokes' (
            ([string]$ownDocuments['claude'].Json.runtimeScriptRelativePath) -ceq ($ownFixtureName + '/' + $ownFixtureName + '.ps1') -and
            ([string]$ownDocuments['codex'].Json.runtimeScriptRelativePath) -ceq ($ownFixtureName + '/' + $ownFixtureName + '.ps1')) (
            [string]$ownDocuments['claude'].Json.runtimeScriptRelativePath)

        # ---- runtimeManifest: bounded, covers the runtime script, excludes itself
        foreach ($ownClient in @('claude', 'codex')) {
            $ownJson = $ownDocuments[$ownClient].Json
            $ownEntries = @($ownJson.runtimeManifest)
            $ownHookDir = Split-Path -Parent $ownDocuments[$ownClient].Path
            $ownRuntimeRelative = [string]$ownJson.runtimeScriptRelativePath
            $ownScriptEntries = @($ownEntries | Where-Object { ([string]$_.path) -ceq $ownRuntimeRelative })
            Check ('the ' + $ownClient + ' manifest covers the runtime script it names, exactly once') ($ownScriptEntries.Count -eq 1) (
                (@($ownEntries | ForEach-Object { [string]$_.path })) -join ', ')
            $ownScriptOnDisk = Join-Path (Split-Path -Parent $ownHookDir) ($ownRuntimeRelative.Replace('/', '\'))
            Check ('the ' + $ownClient + ' manifest hash matches the installed runtime script byte-for-byte') (
                $ownScriptEntries.Count -eq 1 -and
                ([string]$ownScriptEntries[0].sha256) -ceq ((Get-FileHash -LiteralPath $ownScriptOnDisk -Algorithm SHA256).Hash.ToLowerInvariant())) (
                [string]$ownScriptEntries[0].sha256)
            Check ('the ' + $ownClient + ' manifest hashes are 64 lowercase hex characters') (
                @($ownEntries | Where-Object { ([string]$_.sha256) -cmatch '^[0-9a-f]{64}$' }).Count -eq $ownEntries.Count) (
                (@($ownEntries | ForEach-Object { [string]$_.sha256 })) -join ', ')
            Check ('the ' + $ownClient + ' metadata excludes ITSELF from its own manifest (a file cannot hash its own bytes)') (
                @($ownEntries | Where-Object { ([string]$_.path) -like '*hookmaker-runtime.json' }).Count -eq 0)
            Check ('the ' + $ownClient + ' manifest is bounded by the documented cap') (
                $ownEntries.Count -le $script:RuntimeMetadataManifestCap) (
                [string]$ownEntries.Count + ' of ' + [string]$script:RuntimeMetadataManifestCap)
            # Every entry must be a runtime-RELATIVE path. An absolute one would put
            # a user directory name inside an installed runtime.
            Check ('the ' + $ownClient + ' manifest paths are runtime-relative, never absolute') (
                @($ownEntries | Where-Object { ([string]$_.path).Contains(':') -or ([string]$_.path).StartsWith('/') -or ([string]$_.path).StartsWith('\') }).Count -eq 0)
        }

        # ---- FORBIDDEN content -------------------------------------------
        # Never: a command line, an absolute path, a .env value, prompt or tool
        # input, secrets, source content, log text. The file is identity ONLY.
        foreach ($ownClient in @('claude', 'codex')) {
            $ownRaw = $ownDocuments[$ownClient].Raw
            Check ('the ' + $ownClient + ' metadata contains no absolute path') ($ownRaw -notmatch '[A-Za-z]:\\|[A-Za-z]:/|^\\\\') $ownRaw
            Check ('the ' + $ownClient + ' metadata contains no command line') (
                $ownRaw -notmatch 'powershell|pwsh\b|-NoProfile|-ExecutionPolicy|-File ') $ownRaw
            Check ('the ' + $ownClient + ' metadata contains no .env value') ($ownRaw -notmatch [regex]::Escape($ownEnvValue))
            Check ('the ' + $ownClient + ' metadata contains no hook source content') ($ownRaw -notmatch 'exit 0')
            Check ('the ' + $ownClient + ' metadata never leaks the project root, only its hash') (
                $ownRaw -notmatch [regex]::Escape((Split-Path -Leaf $ownProject))) $ownRaw
        }

        # ---- drift: deleted, edited, and repaired -------------------------
        Check 'a freshly installed runtime with metadata evaluates as current for every client' (
            (Get-InstallIntegrity -Record $ownRecord -ToolRoot $ToolRoot).Status -eq 'current') (
            (Get-InstallIntegrity -Record $ownRecord -ToolRoot $ToolRoot).Detail)
        $ownClaudeMetaPath = $ownDocuments['claude'].Path
        $ownClaudeMetaBytes = [System.IO.File]::ReadAllText($ownClaudeMetaPath)
        Remove-Item -LiteralPath $ownClaudeMetaPath -Force
        $ownDeleted = Get-InstallIntegrity -Record $ownRecord -ToolRoot $ToolRoot
        Check 'deleting the ownership metadata is detected as drift, and named as such' (
            $ownDeleted.Status -eq 'update' -and $ownDeleted.Detail -match 'ownership metadata is missing') $ownDeleted.Detail
        Write-Utf8 $ownClaudeMetaPath $ownClaudeMetaBytes
        Check 'restoring it returns the install to current' ((Get-InstallIntegrity -Record $ownRecord -ToolRoot $ToolRoot).Status -eq 'current')
        # An EDITED file is the interesting case: it still parses, so only the hash
        # catches it. Forging another project's key is the attack this detects.
        $ownForged = $ownClaudeMetaBytes.Replace(('"projectKey": "' + $ownRecomputed + '"'), '"projectKey": "0000000000"')
        Check 'the forged document really differs from the installed one' ($ownForged -cne $ownClaudeMetaBytes)
        Write-Utf8 $ownClaudeMetaPath $ownForged
        $ownEdited = Get-InstallIntegrity -Record $ownRecord -ToolRoot $ToolRoot
        Check 'editing the ownership metadata to claim a different project is detected as drift' (
            $ownEdited.Status -eq 'update' -and $ownEdited.Detail -match 'ownership metadata does not describe this installation') $ownEdited.Detail

        # The updater must REPAIR it, not merely notice it.
        $ownCfg = Join-Path $Work 'cfg-ownership.json'; New-Config $ownCfg
        $ownUpdate = Invoke-Wizard -Config $ownCfg -Answers @('1', '4', '', '0')
        Check 'the update run that repairs the metadata exits 0' ($ownUpdate.Exit -eq 0) $ownUpdate.Err
        Check 'the update restored the exact planned bytes' (
            ([System.IO.File]::ReadAllText($ownClaudeMetaPath)) -ceq $ownClaudeMetaBytes) (
            [System.IO.File]::ReadAllText($ownClaudeMetaPath))
        $ownAfter = @(Get-RecordsFor $ownFixtureName | Where-Object { [string]$_.targetProjectRoot -eq $ownProject })[0]
        Check 'the repaired install evaluates as current' ((Get-InstallIntegrity -Record $ownAfter -ToolRoot $ToolRoot).Status -eq 'current') (
            (Get-InstallIntegrity -Record $ownAfter -ToolRoot $ToolRoot).Detail)
        Check 'the installed manifest recorded for a client now covers the metadata' (
            @(@(Get-InstalledManifest -RuntimeRoot ([string]$ownAfter.clients.claude.runtimeRoot) -FriendlyName $ownFixtureName) |
                Where-Object { $_.path -like '*hookmaker-runtime.json' }).Count -eq 1)

        # ---- SHARED runtime: a sibling registration is not drift -----------
        # One project in N sync groups gets N engine records - same hook, same
        # client, same project, differing only by profile - and every one of them
        # registers a handler pointing at the SAME runtime directory. Only one
        # record id can be named in the metadata, so the others each read
        # "ownership metadata does not describe this installation", were replanned
        # as `update`, reinstalled, and came back to the same verdict on the next
        # run: an update loop that could never reach `current`. A real registry hit
        # this on 21 of 572 records.
        $ownSiblingBytes = [System.IO.File]::ReadAllText($ownClaudeMetaPath)
        $ownSiblingId = 'a1b2c3d4e5'
        $ownSiblingDoc = $ownSiblingBytes.Replace(('"recordId": "' + [string]$ownAfter.id + '"'), ('"recordId": "' + $ownSiblingId + '"'))
        Check 'the sibling document really differs from the installed one' (
            $ownSiblingDoc -cne $ownSiblingBytes -and $ownSiblingId -cne ([string]$ownAfter.id))
        Write-Utf8 $ownClaudeMetaPath $ownSiblingDoc
        $ownSibling = Get-InstallIntegrity -Record $ownAfter -ToolRoot $ToolRoot
        Check 'a runtime whose metadata names a SIBLING record of the same hook/client/project is current, not drift' (
            $ownSibling.Status -eq 'current') $ownSibling.Detail

        # ...but ONLY the record id may differ. Each of these keeps a foreign
        # record id and breaks one other claim, and every one must still drift -
        # otherwise the sibling allowance became a way to launder any document.
        foreach ($ownTamper in @(
                @{ Name = 'a foreign projectKey'; From = ('"projectKey": "' + $ownRecomputed + '"'); To = '"projectKey": "0000000000"' },
                @{ Name = 'a foreign client'; From = '"client": "claude"'; To = '"client": "codex"' },
                @{ Name = 'a foreign scope'; From = '"scope": "project"'; To = '"scope": "global"' },
                @{ Name = 'a foreign hook name'; From = ('"friendlyName": "' + $ownFixtureName + '"'); To = '"friendlyName": "Some-Other-Hook"' },
                @{ Name = 'an unknown schema version'; From = '"schemaVersion": 2'; To = '"schemaVersion": 99' },
                @{ Name = 'a registrationName no record id would produce'; From = ('"registrationName": "Hook-Maker/' + $ownFixtureName + '"'); To = '"registrationName": "Hook-Maker/Some-Other-Hook"' },
                @{ Name = 'a manifest hash that does not match the installed file'; From = '"sha256": "'; To = '"sha256": "0000' })) {
            $ownTampered = $ownSiblingDoc.Replace([string]$ownTamper.From, [string]$ownTamper.To)
            Check ('the tampered document (' + [string]$ownTamper.Name + ') really differs') ($ownTampered -cne $ownSiblingDoc) ([string]$ownTamper.From)
            Write-Utf8 $ownClaudeMetaPath $ownTampered
            $ownTamperResult = Get-InstallIntegrity -Record $ownAfter -ToolRoot $ToolRoot
            Check ('a sibling record id does NOT excuse ' + [string]$ownTamper.Name) (
                $ownTamperResult.Status -eq 'update' -and $ownTamperResult.Detail -match 'ownership metadata does not describe this installation') (
                $ownTamperResult.Status + ': ' + $ownTamperResult.Detail)
        }
        # Unparseable is not "close enough to a sibling" either.
        Write-Utf8 $ownClaudeMetaPath '{ not json'
        $ownGarbage = Get-InstallIntegrity -Record $ownAfter -ToolRoot $ToolRoot
        Check 'an unparseable ownership document is still drift' ($ownGarbage.Status -eq 'update') ($ownGarbage.Status + ': ' + $ownGarbage.Detail)
        Write-Utf8 $ownClaudeMetaPath $ownSiblingBytes
        Check 'restoring this record own metadata returns the install to current' (
            (Get-InstallIntegrity -Record $ownAfter -ToolRoot $ToolRoot).Status -eq 'current')

        # ---- global scope: no project, so no project key ------------------
        # GATED on Start-Process -Environment, which only PowerShell 7 has. Without
        # it Invoke-InstallProcess cannot redirect USERPROFILE/HOME, and a global
        # install would write into the REAL user profile - a test must never do
        # that. Skipped rather than made dangerous; the same block runs on the host
        # CI actually uses (pwsh).
        if ((Get-Command Start-Process).Parameters.ContainsKey('Environment')) {
            $ownFakeHome = Join-Path $Work 'OwnershipGlobalHome'
            New-Item -ItemType Directory -Path $ownFakeHome -Force | Out-Null
            $ownGlobal = Invoke-InstallProcess -ScriptArgs @('-CustomHook', $ownFixture, '-Events', 'SessionStart', '-ClaudeOnly') -FakeHome $ownFakeHome
            Check 'a global install succeeds' ($ownGlobal.Exit -eq 0) $ownGlobal.Err
            $ownGlobalMeta = Join-Path $ownFakeHome ('.claude\hooks\Hook-Maker\' + $ownFixtureName + '\.hookmaker-runtime.json')
            Check 'a global install writes ownership metadata too' (Test-Path -LiteralPath $ownGlobalMeta -PathType Leaf) $ownGlobalMeta
            if (Test-Path -LiteralPath $ownGlobalMeta -PathType Leaf) {
                $ownGlobalJson = ((([System.IO.File]::ReadAllText($ownGlobalMeta, [System.Text.Encoding]::UTF8)) | ConvertFrom-Json))
                Check 'a global install records scope=global and an EMPTY projectKey (there is no project to key to)' (
                    ([string]$ownGlobalJson.scope) -ceq 'global' -and ([string]$ownGlobalJson.projectKey) -ceq '') (
                    [string]$ownGlobalJson.scope + ' / [' + [string]$ownGlobalJson.projectKey + ']')
                Check 'a global install still names a runtime script and covers it in the manifest' (
                    ([string]$ownGlobalJson.runtimeScriptRelativePath) -ceq ($ownFixtureName + '/' + $ownFixtureName + '.ps1') -and
                    @(@($ownGlobalJson.runtimeManifest) | Where-Object { ([string]$_.path) -ceq ($ownFixtureName + '/' + $ownFixtureName + '.ps1') }).Count -eq 1) (
                    [string]$ownGlobalJson.runtimeScriptRelativePath)
            }
        }
    }
    finally { Remove-FixtureHook $ownFixtureName }

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
        # '.env' is the USER's local configuration - README: ".env.example
        # (tracked) + .env (your local copy, git-ignored)" - so it is never a
        # managed artifact. It used to be one, and that was a data-loss bug in
        # two halves: a user who configured a hook made the record read as
        # "unexpected managed file: <hook>/.env", and the update that drift
        # triggered rebuilt the runtime from the plan alone and deleted it.
        Check 'the manifest EXCLUDES a hook-local .env (user configuration, never managed)' (
            @($manPaths | Where-Object { $_ -like '*/.env' }).Count -eq 0) ($manPaths -join ',')
        Check 'the manifest includes a copied helper file' (@($manPaths | Where-Object { $_ -like '*/helper.ps1' }).Count -eq 1)
        Check 'the manifest excludes .env.example (never copied by the installer)' (@($manPaths | Where-Object { $_ -like '*.env.example' }).Count -eq 0)
        Check 'baseline manifest install is current' ((Get-InstallIntegrity -Record $recMan -ToolRoot $ToolRoot).Status -eq 'current')

        # 1. a .env-only SOURCE change changes nothing: it is never packaged,
        # so it cannot make an installation stale. Shipping it would also push
        # the hook author's own local configuration into every target project.
        Write-Utf8 (Join-Path $manDir '.env') "EVENTS=Stop`nEXTRA=1`n"
        $m = Get-InstallIntegrity -Record $recMan -ToolRoot $ToolRoot
        Check 'a .env-only source change does NOT trigger an update' ($m.Status -eq 'current') $m.Detail
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

        # 5. a corrupted INSTALLED managed file (source untouched) is still
        # drift. This used to be asserted with '.env', which is exactly the file
        # that must NOT be managed - so it now uses a genuinely packaged one.
        $installedHelper = Join-Path ([string]$recMan.clients.claude.runtimeRoot) 'ZZZ-Regtest-Manifest\helper.ps1'
        Add-Content -LiteralPath $installedHelper -Value '# TAMPERED'
        $m = Get-InstallIntegrity -Record $recMan -ToolRoot $ToolRoot
        Check 'a corrupted installed managed file triggers an update' ($m.Status -eq 'update' -and $m.Detail -match 'installed file modified') $m.Detail
        Write-Utf8 $installedHelper "# helper v1`n"
        Check 'restoring the installed managed file returns to current' ((Get-InstallIntegrity -Record $recMan -ToolRoot $ToolRoot).Status -eq 'current')

        # 5b. THE CONTRACT THAT WAS BROKEN: a user's own .env in the installed
        # runtime is not drift, and survives the reinstall an update performs.
        $userEnv = Join-Path ([string]$recMan.clients.claude.runtimeRoot) 'ZZZ-Regtest-Manifest\.env'
        Write-Utf8 $userEnv "MAX_SCAN_DEPTH=10`nMAX_SCAN_ENTRIES=40000`n"
        Check 'a user-written .env in an installed runtime is NOT drift' (
            (Get-InstallIntegrity -Record $recMan -ToolRoot $ToolRoot).Status -eq 'current') (
            (Get-InstallIntegrity -Record $recMan -ToolRoot $ToolRoot).Detail)
        & $InstallScript -CustomHook $fixtureMan -Events @('Stop') -TargetProject $projMan -ClaudeOnly *> $null
        Check 'the user .env survives the reinstall an update performs' (Test-Path -LiteralPath $userEnv)
        Check 'the user .env keeps its exact contents across the reinstall' (
            (Get-Content -LiteralPath $userEnv -Raw) -match 'MAX_SCAN_ENTRIES=40000') (
            $(if (Test-Path -LiteralPath $userEnv) { Get-Content -LiteralPath $userEnv -Raw } else { '(deleted)' }))
        Remove-Item -LiteralPath $userEnv -Force -ErrorAction SilentlyContinue

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
