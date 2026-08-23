# Dot-sourced scenario block of Test-InstallRegistrySchema.ps1: DISCOVERED
# records - shape/enum/fingerprint/timestamp validation (table-driven),
# over-rejection guards, native discovered evidence; the managed and
# discovered validation paths never accept each other; discovered ids are
# stable, path-derived and non-secret; a raw command string is never
# persisted; Merge-DiscoveredRecord add/update/coveredByManaged/notSeen
# coverage rules; migration leaves discovered records untouched.
# NOT a standalone suite: this file is dot-sourced into the entry suite's
# scope and relies on its harness (Check, $script:Pass/$script:Fail), shared
# fixtures and helper functions - later blocks also read fixtures defined by
# earlier blocks. Run scripts\Test-InstallRegistrySchema.ps1 instead.

    # =====================================================================
    # DISCOVERED records: a completely different shape, validated by its own
    # rules. Nothing here may be accepted by the managed path, and nothing
    # managed may be accepted here.
    Write-Host '--- discovered records: shape, enums, fingerprints, timestamps ---' -ForegroundColor Cyan

    $discProjectRoot = Join-Path $Work 'DiscoveredProj'
    $discSettingsPath = Join-Path $discProjectRoot '.claude\settings.local.json'
    $discTarget = Join-Path $discProjectRoot 'tools\external-hook.ps1'
    $discHandlerFp = ('a' * 64)
    $discMatcherFp = ('b' * 64)
    $discArtifactHash = ('c' * 64)

    function New-DiscoveredRecordFixture {
        return [pscustomobject][ordered]@{
            id                = (Get-DiscoveredRecordId -Kind 'registration' -Scope 'project' -TargetProjectRoot $discProjectRoot `
                                    -Client 'claude' -SettingsPath $discSettingsPath -HandlerFingerprints @($discHandlerFp))
            schema            = 3
            recordType        = 'discovered'
            origin            = 'statusScan'
            friendlyName      = 'external-hook.ps1 (claude)'
            hookType          = 'ClaudeRegistration'
            scope             = 'project'
            targetProjectRoot = $discProjectRoot
            firstSeenUtc      = '2026-07-01T10:00:00.0000000Z'
            lastSeenUtc       = '2026-07-20T09:30:00.0000000Z'
            lastScanId        = 'scan-0001'
            scanRoots         = @($discProjectRoot)
            status            = 'active'
            statusReason      = 'registration resolves to an existing script'
            managedBy         = 'external'
            clients           = @([pscustomobject][ordered]@{
                client              = 'claude'
                settingsPath        = $discSettingsPath
                events              = @('Stop')
                handlerFingerprints = @($discHandlerFp)
                matcherFingerprints = @($discMatcherFp)
                handlerTypes        = @('command')
                commandFieldNames   = @('command')
                parsedTargets       = @($discTarget)
                registrationStatus  = 'parsed'
            })
            nativeGit         = $null
            runtimeArtifacts  = @([pscustomobject][ordered]@{
                path              = $discTarget
                kind              = 'script'
                hash              = $discArtifactHash
                size              = 2048
                classification    = 'registeredRuntime'
                referencedBy      = @('disc-0000000000000000000000000000000')
                deleteEligibility = 'preserve'
                deleteReason      = 'not installed by Hook Maker'
            })
            removalPolicy     = 'registrationOnly'
            needsManualRepair = $false
        }
    }

    $goodDiscovered = New-DiscoveredRecordFixture
    $goodDiscoveredResult = Test-DiscoveredRecordValid -Record $goodDiscovered
    Check 'a fully valid discovered record validates' $goodDiscoveredResult.Ok $goodDiscoveredResult.Reason

    $goodDiscoveredRoundTrip = Test-DiscoveredRecordValid -Record (Copy-Record $goodDiscovered)
    Check 'a valid discovered record still validates after a JSON round-trip' $goodDiscoveredRoundTrip.Ok $goodDiscoveredRoundTrip.Reason

    # A NATIVE discovered record: the other required shape, with real native
    # evidence instead of $null.
    $discRepoRoot = Join-Path $Work 'DiscoveredRepo'
    $discHookPath = Join-Path $discRepoRoot '.git\hooks\pre-push'
    $goodDiscoveredNative = New-DiscoveredRecordFixture
    $goodDiscoveredNative.hookType = 'NativeGitHook'
    $goodDiscoveredNative.clients = @()
    $goodDiscoveredNative.removalPolicy = 'nativeFileOnly'
    $goodDiscoveredNative.id = Get-DiscoveredRecordId -Kind 'native' -RepositoryRoot $discRepoRoot -HookPath $discHookPath -HookName 'pre-push'
    $goodDiscoveredNative.nativeGit = [pscustomobject][ordered]@{
        repositoryRoot  = $discRepoRoot
        hooksPath       = (Join-Path $discRepoRoot '.git\hooks')
        hookName        = 'pre-push'
        hookPath        = $discHookPath
        hookHash        = ('d' * 64)
        hookSize        = 512
        hookModifiedUtc = '2026-07-19T08:00:00.0000000Z'
        classification  = 'externalNativeHook'
        managedStages   = @()
    }
    $goodDiscoveredNativeResult = Test-DiscoveredRecordValid -Record $goodDiscoveredNative
    Check 'a fully valid NATIVE discovered record validates' $goodDiscoveredNativeResult.Ok $goodDiscoveredNativeResult.Reason

    # One negative fixture per required field, wrong type, bad enum, non-hex
    # fingerprint and unparseable timestamp. Every assertion is on the OUTCOME
    # plus a reason substring that identifies the field - never on which
    # internal gate happened to fire first.
    $discoveredCases = @(
        # ---- required fields ------------------------------------------------
        @{ Name = 'id missing'; Reason = 'missing the required field "id"'; Mutate = { param($r) $r.PSObject.Properties.Remove('id') } }
        @{ Name = 'schema missing'; Reason = 'has no schema version'; Mutate = { param($r) $r.PSObject.Properties.Remove('schema') } }
        @{ Name = 'recordType missing'; Reason = 'not a discovered record'; Mutate = { param($r) $r.PSObject.Properties.Remove('recordType') } }
        @{ Name = 'origin missing'; Reason = 'missing the required field "origin"'; Mutate = { param($r) $r.PSObject.Properties.Remove('origin') } }
        @{ Name = 'friendlyName missing'; Reason = 'missing the required field "friendlyName"'; Mutate = { param($r) $r.PSObject.Properties.Remove('friendlyName') } }
        @{ Name = 'hookType missing'; Reason = 'missing the required field "hookType"'; Mutate = { param($r) $r.PSObject.Properties.Remove('hookType') } }
        @{ Name = 'scope missing'; Reason = 'missing the required field "scope"'; Mutate = { param($r) $r.PSObject.Properties.Remove('scope') } }
        @{ Name = 'targetProjectRoot missing'; Reason = 'missing the required field "targetProjectRoot"'; Mutate = { param($r) $r.PSObject.Properties.Remove('targetProjectRoot') } }
        @{ Name = 'firstSeenUtc missing'; Reason = 'missing the required field "firstSeenUtc"'; Mutate = { param($r) $r.PSObject.Properties.Remove('firstSeenUtc') } }
        @{ Name = 'lastSeenUtc missing'; Reason = 'missing the required field "lastSeenUtc"'; Mutate = { param($r) $r.PSObject.Properties.Remove('lastSeenUtc') } }
        @{ Name = 'lastScanId missing'; Reason = 'missing the required field "lastScanId"'; Mutate = { param($r) $r.PSObject.Properties.Remove('lastScanId') } }
        @{ Name = 'scanRoots missing'; Reason = 'missing the required field "scanRoots"'; Mutate = { param($r) $r.PSObject.Properties.Remove('scanRoots') } }
        @{ Name = 'status missing'; Reason = 'missing the required field "status"'; Mutate = { param($r) $r.PSObject.Properties.Remove('status') } }
        @{ Name = 'statusReason missing'; Reason = 'missing the required field "statusReason"'; Mutate = { param($r) $r.PSObject.Properties.Remove('statusReason') } }
        @{ Name = 'managedBy missing'; Reason = 'missing the required field "managedBy"'; Mutate = { param($r) $r.PSObject.Properties.Remove('managedBy') } }
        @{ Name = 'clients missing'; Reason = 'missing the required field "clients"'; Mutate = { param($r) $r.PSObject.Properties.Remove('clients') } }
        @{ Name = 'nativeGit missing'; Reason = 'missing the required field "nativeGit"'; Mutate = { param($r) $r.PSObject.Properties.Remove('nativeGit') } }
        @{ Name = 'runtimeArtifacts missing'; Reason = 'missing the required field "runtimeArtifacts"'; Mutate = { param($r) $r.PSObject.Properties.Remove('runtimeArtifacts') } }
        @{ Name = 'removalPolicy missing'; Reason = 'missing the required field "removalPolicy"'; Mutate = { param($r) $r.PSObject.Properties.Remove('removalPolicy') } }
        @{ Name = 'needsManualRepair missing'; Reason = 'missing the required field "needsManualRepair"'; Mutate = { param($r) $r.PSObject.Properties.Remove('needsManualRepair') } }
        # ---- wrong TYPE (castable is not enough) -----------------------------
        @{ Name = 'id is numeric'; Reason = 'field "id" is not a string'; Mutate = { param($r) $r | Add-Member -MemberType NoteProperty -Name id -Value 12345 -Force } }
        @{ Name = 'friendlyName is an object'; Reason = 'field "friendlyName" is not a string'; Mutate = { param($r) $r | Add-Member -MemberType NoteProperty -Name friendlyName -Value ([pscustomobject]@{ n = 1 }) -Force } }
        @{ Name = 'lastScanId is empty'; Reason = 'field "lastScanId" is empty'; Mutate = { param($r) $r | Add-Member -MemberType NoteProperty -Name lastScanId -Value '   ' -Force } }
        @{ Name = 'scanRoots is a scalar'; Reason = 'field "scanRoots" is not an array'; Mutate = { param($r) $r | Add-Member -MemberType NoteProperty -Name scanRoots -Value 'C:\one' -Force } }
        @{ Name = 'scanRoots contains a non-string'; Reason = 'field "scanRoots" contains a non-string entry'; Mutate = { param($r) $r | Add-Member -MemberType NoteProperty -Name scanRoots -Value @(123) -Force } }
        @{ Name = 'clients is a scalar'; Reason = 'field "clients" is not an array'; Mutate = { param($r) $r | Add-Member -MemberType NoteProperty -Name clients -Value 'claude' -Force } }
        @{ Name = 'runtimeArtifacts is a scalar'; Reason = 'field "runtimeArtifacts" is not an array'; Mutate = { param($r) $r | Add-Member -MemberType NoteProperty -Name runtimeArtifacts -Value 'x' -Force } }
        @{ Name = 'needsManualRepair is a string'; Reason = 'field "needsManualRepair" is not a boolean'; Mutate = { param($r) $r | Add-Member -MemberType NoteProperty -Name needsManualRepair -Value 'yes' -Force } }
        @{ Name = 'schema is not numeric'; Reason = 'non-numeric schema version'; Mutate = { param($r) $r | Add-Member -MemberType NoteProperty -Name schema -Value 'three' -Force } }
        @{ Name = 'schema is newer than supported'; Reason = 'unsupported schema version'; Mutate = { param($r) $r | Add-Member -MemberType NoteProperty -Name schema -Value 4 -Force } }
        @{ Name = 'schema is older than supported'; Reason = 'needs migration'; Mutate = { param($r) $r | Add-Member -MemberType NoteProperty -Name schema -Value 2 -Force } }
        # ---- enum values outside their allowed set ---------------------------
        @{ Name = 'recordType is a foreign value'; Reason = 'not a discovered record'; Mutate = { param($r) $r | Add-Member -MemberType NoteProperty -Name recordType -Value 'managed' -Force } }
        @{ Name = 'origin is a foreign value'; Reason = 'field "origin" has the unsupported value'; Mutate = { param($r) $r | Add-Member -MemberType NoteProperty -Name origin -Value 'hookMaker' -Force } }
        @{ Name = 'hookType is outside the allowed set'; Reason = 'field "hookType" has the unsupported value'; Mutate = { param($r) $r | Add-Member -MemberType NoteProperty -Name hookType -Value 'SomethingElse' -Force } }
        @{ Name = 'scope is outside the allowed set'; Reason = 'field "scope" has the unsupported value'; Mutate = { param($r) $r | Add-Member -MemberType NoteProperty -Name scope -Value 'sideways' -Force } }
        @{ Name = 'status is outside the allowed set'; Reason = 'field "status" has the unsupported value'; Mutate = { param($r) $r | Add-Member -MemberType NoteProperty -Name status -Value 'probably-fine' -Force } }
        @{ Name = 'managedBy is outside the allowed set'; Reason = 'field "managedBy" has the unsupported value'; Mutate = { param($r) $r | Add-Member -MemberType NoteProperty -Name managedBy -Value 'somebody' -Force } }
        @{ Name = 'removalPolicy is outside the allowed set'; Reason = 'field "removalPolicy" has the unsupported value'; Mutate = { param($r) $r | Add-Member -MemberType NoteProperty -Name removalPolicy -Value 'maybe' -Force } }
        @{ Name = 'client evidence client is outside the allowed set'; Reason = 'field "client" has the unsupported value'; Mutate = { param($r) $r.clients[0] | Add-Member -MemberType NoteProperty -Name client -Value 'emacs' -Force } }
        @{ Name = 'client evidence registrationStatus is outside the allowed set'; Reason = 'field "registrationStatus" has the unsupported value'; Mutate = { param($r) $r.clients[0] | Add-Member -MemberType NoteProperty -Name registrationStatus -Value 'guessed' -Force } }
        @{ Name = 'runtime artifact classification is outside the allowed set'; Reason = 'field "classification" has the unsupported value'; Mutate = { param($r) $r.runtimeArtifacts[0] | Add-Member -MemberType NoteProperty -Name classification -Value 'unknownish' -Force } }
        @{ Name = 'runtime artifact deleteEligibility is outside the allowed set'; Reason = 'field "deleteEligibility" has the unsupported value'; Mutate = { param($r) $r.runtimeArtifacts[0] | Add-Member -MemberType NoteProperty -Name deleteEligibility -Value 'perhaps' -Force } }
        # ---- fingerprints must be genuine 64-hex -----------------------------
        @{ Name = 'handlerFingerprints contains a non-hex value'; Reason = 'is not a 64-character SHA-256 hex fingerprint'; Mutate = { param($r) $r.clients[0] | Add-Member -MemberType NoteProperty -Name handlerFingerprints -Value @('not-hex-zzz!') -Force } }
        @{ Name = 'handlerFingerprints contains a 63-char value'; Reason = 'is not a 64-character SHA-256 hex fingerprint'; Mutate = { param($r) $r.clients[0] | Add-Member -MemberType NoteProperty -Name handlerFingerprints -Value @(('a' * 63)) -Force } }
        @{ Name = 'matcherFingerprints contains a non-hex value'; Reason = 'is not a 64-character SHA-256 hex fingerprint'; Mutate = { param($r) $r.clients[0] | Add-Member -MemberType NoteProperty -Name matcherFingerprints -Value @(('z' * 64)) -Force } }
        @{ Name = 'handlerFingerprints contains a non-string'; Reason = 'field "handlerFingerprints" contains a non-string entry'; Mutate = { param($r) $r.clients[0] | Add-Member -MemberType NoteProperty -Name handlerFingerprints -Value @(123) -Force } }
        @{ Name = 'runtime artifact hash is not 64-hex'; Reason = 'field "hash" is not a 64-character SHA-256 hex value'; Mutate = { param($r) $r.runtimeArtifacts[0] | Add-Member -MemberType NoteProperty -Name hash -Value 'abc' -Force } }
        # ---- timestamps must parse as UTC ------------------------------------
        @{ Name = 'firstSeenUtc is unparseable'; Reason = 'field "firstSeenUtc" is not'; Mutate = { param($r) $r | Add-Member -MemberType NoteProperty -Name firstSeenUtc -Value 'not-a-timestamp' -Force } }
        @{ Name = 'lastSeenUtc has no zone'; Reason = 'field "lastSeenUtc" is not an ISO 8601 UTC timestamp'; Mutate = { param($r) $r | Add-Member -MemberType NoteProperty -Name lastSeenUtc -Value '2026-07-20 09:30:00' -Force } }
        @{ Name = 'lastSeenUtc is numeric'; Reason = 'field "lastSeenUtc" is not a string'; Mutate = { param($r) $r | Add-Member -MemberType NoteProperty -Name lastSeenUtc -Value 20260720 -Force } }
        @{ Name = 'firstSeenUtc claims a zone but is nonsense'; Reason = 'field "firstSeenUtc" is not a parseable timestamp'; Mutate = { param($r) $r | Add-Member -MemberType NoteProperty -Name firstSeenUtc -Value '2026-13-45T99:99:99Z' -Force } }
        # ---- paths must canonicalize -----------------------------------------
        @{ Name = 'client settingsPath cannot be canonicalized'; Reason = 'field "settingsPath" cannot be canonicalized'; Mutate = { param($r) $r.clients[0] | Add-Member -MemberType NoteProperty -Name settingsPath -Value ('C:\Bad' + [string][char]0 + 'Path') -Force } }
        @{ Name = 'a parsedTarget cannot be canonicalized'; Reason = 'contains a path that cannot be canonicalized'; Mutate = { param($r) $r.clients[0] | Add-Member -MemberType NoteProperty -Name parsedTargets -Value @('C:\Bad' + [string][char]0 + 'Path') -Force } }
        # ---- a raw command may NEVER be persisted ----------------------------
        @{ Name = 'a raw command on the record'; Reason = 'persists a raw command'; Mutate = { param($r) $r | Add-Member -MemberType NoteProperty -Name command -Value 'pwsh -File "C:\secret\hook.ps1" -Token abc123' -Force } }
        @{ Name = 'a raw command on client evidence'; Reason = 'persists a raw command'; Mutate = { param($r) $r.clients[0] | Add-Member -MemberType NoteProperty -Name command -Value 'pwsh -File x.ps1' -Force } }
        @{ Name = 'a raw commandWindows on client evidence'; Reason = 'persists a raw command'; Mutate = { param($r) $r.clients[0] | Add-Member -MemberType NoteProperty -Name commandWindows -Value 'powershell.exe -File x.ps1' -Force } }
        # ---- scope consistency -----------------------------------------------
        @{ Name = 'a project-scoped record with an empty targetProjectRoot'; Reason = 'has no targetProjectRoot'; Mutate = { param($r) $r | Add-Member -MemberType NoteProperty -Name targetProjectRoot -Value '' -Force } }
    )

    foreach ($case in $discoveredCases) {
        $variant = New-DiscoveredRecordFixture
        & $case.Mutate $variant
        $result = Test-DiscoveredRecordValid -Record $variant
        Check ('discovered record: ' + $case.Name + ' is rejected') ((-not $result.Ok) -and ($result.Reason -match [regex]::Escape($case.Reason))) $result.Reason
    }

    # Over-rejection guards: legitimate states that must NOT be refused.
    $globalDiscovered = New-DiscoveredRecordFixture
    $globalDiscovered.scope = 'global'
    $globalDiscovered.targetProjectRoot = ''
    $globalDiscoveredResult = Test-DiscoveredRecordValid -Record $globalDiscovered
    Check 'a GLOBAL discovered record with an empty targetProjectRoot validates' $globalDiscoveredResult.Ok $globalDiscoveredResult.Reason

    $unparsedDiscovered = New-DiscoveredRecordFixture
    $unparsedDiscovered.clients[0].registrationStatus = 'unparsedCommand'
    $unparsedDiscovered.clients[0].parsedTargets = @()
    $unparsedDiscoveredResult = Test-DiscoveredRecordValid -Record $unparsedDiscovered
    Check 'an unparsable-command discovered record with no parsedTargets validates' $unparsedDiscoveredResult.Ok $unparsedDiscoveredResult.Reason

    $emptyHashArtifact = New-DiscoveredRecordFixture
    $emptyHashArtifact.runtimeArtifacts[0].hash = ''
    $emptyHashArtifactResult = Test-DiscoveredRecordValid -Record $emptyHashArtifact
    Check 'a runtime artifact whose file could not be hashed (empty hash) validates' $emptyHashArtifactResult.Ok $emptyHashArtifactResult.Reason

    $noArtifacts = New-DiscoveredRecordFixture
    $noArtifacts.runtimeArtifacts = @()
    $noArtifactsResult = Test-DiscoveredRecordValid -Record $noArtifacts
    Check 'a discovered record with no runtime artifacts validates' $noArtifactsResult.Ok $noArtifactsResult.Reason

    # Native evidence has its own rules.
    $badNativeClassification = Copy-Record $goodDiscoveredNative
    $badNativeClassification.nativeGit | Add-Member -MemberType NoteProperty -Name classification -Value 'probably-ours' -Force
    $badNativeClassificationResult = Test-DiscoveredRecordValid -Record $badNativeClassification
    Check 'discovered nativeGit: an unsupported classification is rejected' ((-not $badNativeClassificationResult.Ok) -and ($badNativeClassificationResult.Reason -match 'field "classification" has the unsupported value')) $badNativeClassificationResult.Reason

    $badNativeHash = Copy-Record $goodDiscoveredNative
    $badNativeHash.nativeGit | Add-Member -MemberType NoteProperty -Name hookHash -Value 'nope' -Force
    $badNativeHashResult = Test-DiscoveredRecordValid -Record $badNativeHash
    Check 'discovered nativeGit: a non-64-hex hookHash is rejected' ((-not $badNativeHashResult.Ok) -and ($badNativeHashResult.Reason -match 'field "hookHash" is not a 64-character SHA-256 hex value')) $badNativeHashResult.Reason

    $badNativeSize = Copy-Record $goodDiscoveredNative
    $badNativeSize.nativeGit | Add-Member -MemberType NoteProperty -Name hookSize -Value 'big' -Force
    $badNativeSizeResult = Test-DiscoveredRecordValid -Record $badNativeSize
    Check 'discovered nativeGit: a non-numeric hookSize is rejected' ((-not $badNativeSizeResult.Ok) -and ($badNativeSizeResult.Reason -match 'field "hookSize" is not numeric')) $badNativeSizeResult.Reason

    $missingNativeRepo = Copy-Record $goodDiscoveredNative
    $missingNativeRepo.nativeGit.PSObject.Properties.Remove('repositoryRoot')
    $missingNativeRepoResult = Test-DiscoveredRecordValid -Record $missingNativeRepo
    Check 'discovered nativeGit: a missing repositoryRoot is rejected' ((-not $missingNativeRepoResult.Ok) -and ($missingNativeRepoResult.Reason -match 'missing the required field "repositoryRoot"')) $missingNativeRepoResult.Reason

    $emptyNativeHash = Copy-Record $goodDiscoveredNative
    $emptyNativeHash.nativeGit | Add-Member -MemberType NoteProperty -Name hookHash -Value '' -Force
    Check 'discovered nativeGit: an unreadable hook file (empty hookHash) still validates' ((Test-DiscoveredRecordValid -Record $emptyNativeHash).Ok)

    # =====================================================================
    # The two validation paths are mutually exclusive. Accepting a record under
    # the wrong contract would let fields nothing validated reach a consumer.
    Write-Host '--- managed and discovered validation paths never accept each other ---' -ForegroundColor Cyan

    $managedThroughDiscovered = Test-DiscoveredRecordValid -Record $goodRecord
    Check 'a managed record is rejected by the DISCOVERED validator' ((-not $managedThroughDiscovered.Ok) -and ($managedThroughDiscovered.Reason -match 'not a discovered record')) $managedThroughDiscovered.Reason

    $projectManagedThroughDiscovered = Test-DiscoveredRecordValid -Record $goodProjectRecord
    Check 'a managed PROJECT record is rejected by the DISCOVERED validator' (-not $projectManagedThroughDiscovered.Ok)

    $genuineManagedThroughDiscovered = Test-DiscoveredRecordValid -Record $nmiHealthyNormal
    Check 'a genuine installer-written record is rejected by the DISCOVERED validator' (-not $genuineManagedThroughDiscovered.Ok)

    # A discovered record has none of sourceScript/sourceDir/clients-object that
    # the managed rules demand, so if Test-InstallRecordValid ever ran the
    # managed rules over it the outcome would be a managed rejection. It passes,
    # which proves it was routed to the discovered validator instead.
    $discoveredThroughShared = Test-InstallRecordValid -Record $goodDiscovered
    Check 'Test-InstallRecordValid routes a discovered record to the discovered rules' $discoveredThroughShared.Ok $discoveredThroughShared.Reason

    $brokenDiscoveredThroughShared = New-DiscoveredRecordFixture
    $brokenDiscoveredThroughShared | Add-Member -MemberType NoteProperty -Name status -Value 'nonsense' -Force
    $brokenDiscoveredSharedResult = Test-InstallRecordValid -Record $brokenDiscoveredThroughShared
    Check 'Test-InstallRecordValid reports a discovered failure in discovered terms' ((-not $brokenDiscoveredSharedResult.Ok) -and ($brokenDiscoveredSharedResult.Reason -match 'field "status" has the unsupported value')) $brokenDiscoveredSharedResult.Reason

    # A record that merely CLAIMS to be discovered while carrying the managed
    # shape is refused - the claim does not create the shape.
    $managedWearingDiscoveredLabel = Copy-Record $goodRecord
    $managedWearingDiscoveredLabel | Add-Member -MemberType NoteProperty -Name recordType -Value 'discovered' -Force
    $managedWearingResult = Test-InstallRecordValid -Record $managedWearingDiscoveredLabel
    Check 'a managed-shaped record labelled discovered is rejected' (-not $managedWearingResult.Ok) $managedWearingResult.Reason

    # =====================================================================
    Write-Host '--- discovered record ids are stable, path-derived and non-secret ---' -ForegroundColor Cyan

    $idFirst = Get-DiscoveredRecordId -Kind 'registration' -Scope 'project' -TargetProjectRoot $discProjectRoot `
        -Client 'claude' -SettingsPath $discSettingsPath -HandlerFingerprints @($discHandlerFp)
    $idSecond = Get-DiscoveredRecordId -Kind 'registration' -Scope 'project' -TargetProjectRoot $discProjectRoot `
        -Client 'claude' -SettingsPath $discSettingsPath -HandlerFingerprints @($discHandlerFp)
    Check 'the same discovered input yields the same id on every call' ($idFirst -eq $idSecond)
    Check 'a discovered id is the documented disc- + 32 hex form' ($idFirst -match '^disc-[0-9a-f]{32}$')

    # A rescan can hand the fingerprints back in a different order; that is the
    # same hook, not a new one.
    $idReordered = Get-DiscoveredRecordId -Kind 'registration' -Scope 'project' -TargetProjectRoot $discProjectRoot `
        -Client 'claude' -SettingsPath $discSettingsPath -HandlerFingerprints @($discMatcherFp, $discHandlerFp)
    $idOriginalOrder = Get-DiscoveredRecordId -Kind 'registration' -Scope 'project' -TargetProjectRoot $discProjectRoot `
        -Client 'claude' -SettingsPath $discSettingsPath -HandlerFingerprints @($discHandlerFp, $discMatcherFp)
    Check 'reordered handler fingerprints yield the SAME id' ($idReordered -eq $idOriginalOrder)

    # Windows paths are case-insensitive: the same file typed two ways is one hook.
    $idDifferentCase = Get-DiscoveredRecordId -Kind 'registration' -Scope 'project' -TargetProjectRoot $discProjectRoot.ToUpperInvariant() `
        -Client 'claude' -SettingsPath $discSettingsPath.ToUpperInvariant() -HandlerFingerprints @($discHandlerFp)
    Check 'a differently-cased path yields the SAME id' ($idDifferentCase -eq $idFirst)

    # THE identity requirement: two same-named hooks at different paths are
    # different hooks. An id is never derived from a name or a basename.
    $otherProjectRoot = Join-Path $Work 'DiscoveredProjOther'
    $otherSettingsPath = Join-Path $otherProjectRoot '.claude\settings.local.json'
    $idOtherPath = Get-DiscoveredRecordId -Kind 'registration' -Scope 'project' -TargetProjectRoot $otherProjectRoot `
        -Client 'claude' -SettingsPath $otherSettingsPath -HandlerFingerprints @($discHandlerFp)
    Check 'two same-named hooks at DIFFERENT paths yield different ids' ($idOtherPath -ne $idFirst)

    $idOtherClient = Get-DiscoveredRecordId -Kind 'registration' -Scope 'project' -TargetProjectRoot $discProjectRoot `
        -Client 'codex' -SettingsPath $discSettingsPath -HandlerFingerprints @($discHandlerFp)
    Check 'the same registration under a different client yields a different id' ($idOtherClient -ne $idFirst)

    $idOtherFingerprint = Get-DiscoveredRecordId -Kind 'registration' -Scope 'project' -TargetProjectRoot $discProjectRoot `
        -Client 'claude' -SettingsPath $discSettingsPath -HandlerFingerprints @(('e' * 64))
    Check 'a different handler fingerprint yields a different id' ($idOtherFingerprint -ne $idFirst)

    $nativeIdFirst = Get-DiscoveredRecordId -Kind 'native' -RepositoryRoot $discRepoRoot -HookPath $discHookPath -HookName 'pre-push'
    $nativeIdSecond = Get-DiscoveredRecordId -Kind 'native' -RepositoryRoot $discRepoRoot -HookPath $discHookPath -HookName 'pre-push'
    Check 'the same native input yields the same id on every call' ($nativeIdFirst -eq $nativeIdSecond)
    Check 'a native id never collides with a registration id' ($nativeIdFirst -ne $idFirst)

    $otherRepoRoot = Join-Path $Work 'DiscoveredRepoOther'
    $nativeIdOtherRepo = Get-DiscoveredRecordId -Kind 'native' -RepositoryRoot $otherRepoRoot `
        -HookPath (Join-Path $otherRepoRoot '.git\hooks\pre-push') -HookName 'pre-push'
    Check 'the same-named native hook in a different repository yields a different id' ($nativeIdOtherRepo -ne $nativeIdFirst)

    # =====================================================================
    # SECRET SAFETY: a command line can embed a token or an expanded secret, so
    # a discovered record persists the FINGERPRINT and never the text. Asserted
    # on the SERIALIZED form, which is what actually reaches disk.
    Write-Host '--- a discovered record never persists a raw command string ---' -ForegroundColor Cyan

    $secretBearingCommand = 'pwsh -NoProfile -File "C:\tools\hook.ps1" -ApiToken sk-live-SECRET-VALUE-12345'
    $serializedDiscovered = $goodDiscovered | ConvertTo-Json -Depth 60
    Check 'the serialized discovered record contains no raw command text' (-not ($serializedDiscovered -match 'sk-live-SECRET-VALUE-12345'))
    Check 'the serialized discovered record has no "command" field' (-not ($serializedDiscovered -match '"command"\s*:'))
    Check 'the serialized discovered record has no "commandWindows" field' (-not ($serializedDiscovered -match '"commandWindows"\s*:'))
    Check 'the serialized discovered record records command FIELD NAMES only' ($serializedDiscovered -match '"commandFieldNames"')
    Check 'the serialized discovered record carries fingerprints instead' ($serializedDiscovered -match [regex]::Escape($discHandlerFp))

    # The same proof after a real registry round-trip: written, read back, and
    # re-serialized is where a leak would actually surface.
    $secretRoot = Join-Path $Work 'secret-check-root'
    New-Item -ItemType Directory -Path (Join-Path $secretRoot 'state') -Force | Out-Null
    $savedSecretStateDir = $env:HOOKMAKER_STATE_DIR
    $env:HOOKMAKER_STATE_DIR = ''
    try {
        $secretRegistry = New-EmptyInstallRegistry
        $secretMerge = Merge-DiscoveredRecord -Registry $secretRegistry -Record (New-DiscoveredRecordFixture)
        Check 'setup: the discovered record merged into a fresh registry' ($secretMerge.Action -eq 'added')
        Save-InstallRegistry -ToolRoot $secretRoot -Registry $secretRegistry
        $secretOnDisk = Get-InstallRegistryRawText -ToolRoot $secretRoot
        Check 'the persisted registry file contains no raw command text' (-not ($secretOnDisk -match [regex]::Escape($secretBearingCommand)))
        Check 'the persisted registry file has no "command" field' (-not ($secretOnDisk -match '"command"\s*:'))
        Check 'the persisted discovered record survives the round-trip and still validates' ((Test-DiscoveredRecordValid -Record @((Read-InstallRegistryState -ToolRoot $secretRoot).Registry.installs)[0]).Ok)
    }
    finally { $env:HOOKMAKER_STATE_DIR = $savedSecretStateDir }

    # =====================================================================
    Write-Host '--- discovered merge: add, update, managed coverage, incomplete coverage ---' -ForegroundColor Cyan

    $mergeRegistry = New-EmptyInstallRegistry
    $firstMerge = Merge-DiscoveredRecord -Registry $mergeRegistry -Record (New-DiscoveredRecordFixture)
    Check 'a never-seen discovered record is ADDED' ($firstMerge.Action -eq 'added') $firstMerge.Reason
    Check 'the added record is in the registry' (@($mergeRegistry.installs).Count -eq 1)

    # The SAME unchanged installation rescanned: same id, so update - never a
    # duplicate - and firstSeenUtc is the one fact a later scan cannot re-derive.
    $rescanned = New-DiscoveredRecordFixture
    $rescanned.firstSeenUtc = '2026-07-20T11:00:00.0000000Z'
    $rescanned.lastSeenUtc = '2026-07-20T11:00:00.0000000Z'
    $rescanned.lastScanId = 'scan-0002'
    $rescanned.status = 'missingTarget'
    $rescanned.statusReason = 'the registered script no longer exists'
    $rescanned.runtimeArtifacts[0].hash = ('f' * 64)
    $secondMerge = Merge-DiscoveredRecord -Registry $mergeRegistry -Record $rescanned
    Check 'the same installation rescanned is UPDATED, never duplicated' ($secondMerge.Action -eq 'updated') $secondMerge.Reason
    Check 'the rescan did not add a second record' (@($mergeRegistry.installs).Count -eq 1)
    $mergedRecord = @($mergeRegistry.installs)[0]
    Check 'firstSeenUtc is preserved from the ORIGINAL sighting' ([string]$mergedRecord.firstSeenUtc -eq '2026-07-01T10:00:00.0000000Z')
    Check 'lastSeenUtc is refreshed by the rescan' ([string]$mergedRecord.lastSeenUtc -eq '2026-07-20T11:00:00.0000000Z')
    Check 'lastScanId is refreshed by the rescan' ([string]$mergedRecord.lastScanId -eq 'scan-0002')
    Check 'status is refreshed by the rescan' ([string]$mergedRecord.status -eq 'missingTarget')
    Check 'hashes are refreshed by the rescan' ([string]$mergedRecord.runtimeArtifacts[0].hash -eq ('f' * 64))
    Check 'the updated record still validates' ((Test-DiscoveredRecordValid -Record $mergedRecord).Ok)

    # A hook at a DIFFERENT path is a different record, not an update.
    $otherDiscovered = New-DiscoveredRecordFixture
    $otherDiscovered.targetProjectRoot = $otherProjectRoot
    $otherDiscovered.scanRoots = @($otherProjectRoot)
    $otherDiscovered.clients[0].settingsPath = $otherSettingsPath
    $otherDiscovered.clients[0].parsedTargets = @((Join-Path $otherProjectRoot 'tools\external-hook.ps1'))
    $otherDiscovered.id = Get-DiscoveredRecordId -Kind 'registration' -Scope 'project' -TargetProjectRoot $otherProjectRoot `
        -Client 'claude' -SettingsPath $otherSettingsPath -HandlerFingerprints @($discHandlerFp)
    $otherMerge = Merge-DiscoveredRecord -Registry $mergeRegistry -Record $otherDiscovered
    Check 'a same-named hook at another path is ADDED as its own record' ($otherMerge.Action -eq 'added') $otherMerge.Reason
    Check 'the registry now holds both discovered records' (@($mergeRegistry.installs).Count -eq 2)

    # A hook Hook Maker installed itself must never be re-listed as a foreign
    # discovery. Coverage is decided on evidence: the same settings file plus
    # the managed runtime script the registration actually resolves to.
    $coverageRegistry = New-EmptyInstallRegistry
    $coverageRegistry.installs = @(Copy-Record $goodProjectRecord)
    $coveredDiscovered = New-DiscoveredRecordFixture
    $coveredDiscovered.targetProjectRoot = $fixtureProjectRoot
    $coveredDiscovered.scanRoots = @($fixtureProjectRoot)
    $coveredDiscovered.clients[0].settingsPath = $fixtureProjectClaudeSettingsPath
    $coveredDiscovered.clients[0].parsedTargets = @($fixtureProjectClaudeRuntimeScript)
    $coveredMerge = Merge-DiscoveredRecord -Registry $coverageRegistry -Record $coveredDiscovered
    Check 'a hook already tracked as a managed install is NOT duplicated' ($coveredMerge.Action -eq 'coveredByManaged') $coveredMerge.Reason
    Check 'nothing was written for the managed-covered hook' (@($coverageRegistry.installs).Count -eq 1)

    # A per-hook-file client (Kiro) registers the hook's LAUNCHER shim, so the
    # managed record's runtimeScript and the path it actually registered are
    # different files. Matching runtimeScript alone missed every one of them, and
    # each Kiro install was then kept as a second, unremovable discovered record.
    $launcherScript = Join-Path $fixtureProjectClaudeRuntimeRoot 'F\kiro-launch.ps1'
    $launcherRegistry = New-EmptyInstallRegistry
    $launcherManaged = Copy-Record $goodProjectRecord
    $launcherManaged.clients.claude.command = 'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $launcherScript + '"'
    $launcherRegistry.installs = @($launcherManaged)
    $launcherDiscovered = New-DiscoveredRecordFixture
    $launcherDiscovered.targetProjectRoot = $fixtureProjectRoot
    $launcherDiscovered.scanRoots = @($fixtureProjectRoot)
    $launcherDiscovered.clients[0].settingsPath = $fixtureProjectClaudeSettingsPath
    $launcherDiscovered.clients[0].parsedTargets = @($launcherScript)
    $launcherMerge = Merge-DiscoveredRecord -Registry $launcherRegistry -Record $launcherDiscovered
    Check 'a registration pointing at the launcher the managed record REGISTERED is covered' ($launcherMerge.Action -eq 'coveredByManaged') $launcherMerge.Reason
    Check 'nothing was written for the launcher-registered hook' (@($launcherRegistry.installs).Count -eq 1)

    # The registered command is still not a free pass: a path the managed record
    # never registered, in the same settings file, remains a separate hook.
    $foreignLauncherRegistry = New-EmptyInstallRegistry
    $foreignLauncherRegistry.installs = @((Copy-Record $launcherManaged))
    $foreignDiscovered = New-DiscoveredRecordFixture
    $foreignDiscovered.targetProjectRoot = $fixtureProjectRoot
    $foreignDiscovered.scanRoots = @($fixtureProjectRoot)
    $foreignDiscovered.clients[0].settingsPath = $fixtureProjectClaudeSettingsPath
    $foreignDiscovered.clients[0].parsedTargets = @((Join-Path $fixtureProjectClaudeRuntimeRoot 'F\not-ours.ps1'))
    $foreignMerge = Merge-DiscoveredRecord -Registry $foreignLauncherRegistry -Record $foreignDiscovered
    Check 'a path the managed record never registered is still its own record' ($foreignMerge.Action -eq 'added') $foreignMerge.Reason

    # A discovered record for the same artifact can predate the managed install
    # (hooks reinstalled over paths an earlier scan had discovered). Left in the
    # registry it can never be cleaned up: this branch returns before the update
    # below, the demotion pass then calls it notSeen although the file is right
    # there, and the uninstall screen offers a row whose removal can never be
    # proven. It must be retired where the duplicate is proven.
    $ghostRegistry = New-EmptyInstallRegistry
    $ghostStale = Copy-Record $coveredDiscovered
    $ghostStale.status = 'manualRepair'
    $ghostStale.needsManualRepair = $true
    $ghostStale.statusReason = 'left over from an earlier removal attempt'
    $ghostRegistry.installs = @((Copy-Record $goodProjectRecord), $ghostStale)
    $ghostMerge = Merge-DiscoveredRecord -Registry $ghostRegistry -Record (Copy-Record $coveredDiscovered)
    Check 'a hook now covered by a managed install still reports coveredByManaged' ($ghostMerge.Action -eq 'coveredByManaged') $ghostMerge.Reason
    Check 'the stale discovered duplicate is RETIRED, not left unremovable' (@(@($ghostRegistry.installs) | Where-Object { [string]$_.id -eq [string]$ghostStale.id }).Count -eq 0)
    Check 'retiring the duplicate leaves the managed record untouched' (@(@($ghostRegistry.installs) | Where-Object { [string]$_.id -eq 'schema-ok-project' }).Count -eq 1)

    # Same settings file but a DIFFERENT script is a genuinely different hook -
    # coverage must not be claimed on the settings path alone.
    $notCoveredDiscovered = New-DiscoveredRecordFixture
    $notCoveredDiscovered.targetProjectRoot = $fixtureProjectRoot
    $notCoveredDiscovered.scanRoots = @($fixtureProjectRoot)
    $notCoveredDiscovered.clients[0].settingsPath = $fixtureProjectClaudeSettingsPath
    $notCoveredDiscovered.clients[0].parsedTargets = @((Join-Path $fixtureProjectRoot 'tools\someone-elses.ps1'))
    $notCoveredDiscovered.id = Get-DiscoveredRecordId -Kind 'registration' -Scope 'project' -TargetProjectRoot $fixtureProjectRoot `
        -Client 'claude' -SettingsPath $fixtureProjectClaudeSettingsPath -HandlerFingerprints @($discMatcherFp)
    $notCoveredMerge = Merge-DiscoveredRecord -Registry $coverageRegistry -Record $notCoveredDiscovered
    Check 'a DIFFERENT script in the same settings file is still discovered' ($notCoveredMerge.Action -eq 'added') $notCoveredMerge.Reason

    # notSeen is a claim about ABSENCE. A scan that did not reach everywhere has
    # not proven a hook is gone, and must never be able to write that verdict.
    $notSeenRecord = New-DiscoveredRecordFixture
    $notSeenRecord.status = 'notSeen'
    $notSeenRecord.statusReason = 'not found by this scan'
    $incompleteMerge = Merge-DiscoveredRecord -Registry $mergeRegistry -Record $notSeenRecord
    Check 'notSeen from a scan with incomplete coverage is REJECTED' ($incompleteMerge.Action -eq 'rejected') $incompleteMerge.Reason
    Check 'the incomplete-coverage rejection says why' ($incompleteMerge.Reason -match 'coverage was incomplete') $incompleteMerge.Reason
    Check 'nothing was written for the rejected notSeen record' (@($mergeRegistry.installs).Count -eq 2)

    $completeMerge = Merge-DiscoveredRecord -Registry $mergeRegistry -Record $notSeenRecord -CoverageComplete
    Check 'notSeen from a COMPLETE scan is accepted' ($completeMerge.Action -eq 'updated') $completeMerge.Reason
    Check 'the notSeen update still did not duplicate the record' (@($mergeRegistry.installs).Count -eq 2)

    # An invalid record never reaches the registry.
    $invalidMergeRecord = New-DiscoveredRecordFixture
    $invalidMergeRecord | Add-Member -MemberType NoteProperty -Name status -Value 'invented' -Force
    $invalidMerge = Merge-DiscoveredRecord -Registry $mergeRegistry -Record $invalidMergeRecord
    Check 'an invalid discovered record is rejected by the merge' ($invalidMerge.Action -eq 'rejected') $invalidMerge.Reason
    Check 'the rejected record was not written' (@($mergeRegistry.installs).Count -eq 2)

    # Migration must leave discovered records completely alone - pushing one
    # through the managed v1->v2 rebuild would corrupt it.
    $mixedRegistry = New-EmptyInstallRegistry
    $mixedManaged = Copy-Record $goodRecord
    $mixedManaged.PSObject.Properties.Remove('recordType')
    $mixedRegistry.installs = @($mixedManaged, (New-DiscoveredRecordFixture))
    $mixedDiscoveredBefore = @($mixedRegistry.installs)[1] | ConvertTo-Json -Depth 60
    $mixedMigrated = ConvertTo-InstallRegistryCurrent -Registry $mixedRegistry
    $mixedDiscoveredAfter = @($mixedMigrated.installs)[1] | ConvertTo-Json -Depth 60
    Check 'migration leaves a discovered record completely untouched' ($mixedDiscoveredBefore -eq $mixedDiscoveredAfter)
    Check 'migration still stamps the managed record beside it' ([string]@($mixedMigrated.installs)[0].recordType -eq 'managed')
    Check 'a mixed registry keeps both records' (@($mixedMigrated.installs).Count -eq 2)
