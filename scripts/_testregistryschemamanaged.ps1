# Dot-sourced scenario block of Test-InstallRegistrySchema.ps1: managed
# record schema validation and per-record isolation - required fields,
# non-string/empty client subrecord fields, event entries, canonicalized
# path/command consistency, leaf-name gates, project-scope records, timeout
# and nativeGit shape (table-driven malformed variants); a malformed record
# in a mixed batch is skipped without crashing while every healthy record
# still evaluates. Defines Copy-Record and the $goodRecord /
# $goodProjectRecord / $nmiHealthy* fixtures reused by later blocks.
# NOT a standalone suite: this file is dot-sourced into the entry suite's
# scope and relies on its harness (Check, $script:Pass/$script:Fail), shared
# fixtures and helper functions - later blocks also read fixtures defined by
# earlier blocks. Run scripts\Test-InstallRegistrySchema.ps1 instead.

    # =====================================================================

    # Registry schema validation and PER-RECORD isolation. Under StrictMode a

    # single malformed record used to throw and abort the whole update run, so

    # every healthy record after it was never evaluated.

    Write-Host '--- registry schema validation and per-record isolation ---' -ForegroundColor Cyan

    # Canonical-consistent fixture paths: Test-InstallRecordValid now proves
    # runtimeScript sits one managed-hook-directory level under runtimeRoot,
    # and that settingsPath/command actually match the record's own
    # scope/client - so a synthetic "well-formed record" fixture must use a
    # REAL structural relationship, not arbitrary strings, or every case
    # derived from it (below) would be rejected for the wrong reason.
    $fixtureRuntimeRoot = Join-Path $HOME '.claude\hooks\Hook-Maker'
    $fixtureRuntimeScript = Join-Path $fixtureRuntimeRoot 'F\F.ps1'
    $fixtureSettingsPath = Join-Path $HOME '.claude\settings.json'
    $fixtureCommand = 'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $fixtureRuntimeScript + '"'

    $goodRecord = [pscustomobject]@{
        id = 'schema-ok'; schema = 2; friendlyName = 'F'; hookType = 'CustomHook'
        sourceScript = 'C:\src\hook.ps1'; sourceDir = 'C:\src'; scope = 'global'
        clients = [pscustomobject]@{ claude = [pscustomobject]@{
            runtimeScript = $fixtureRuntimeScript; settingsPath = $fixtureSettingsPath; runtimeRoot = $fixtureRuntimeRoot
            events = @('Stop'); command = $fixtureCommand
        } }
    }

    function Copy-Record { param($R) return ($R | ConvertTo-Json -Depth 20 | ConvertFrom-Json) }

    $goodRecordResult = Test-InstallRecordValid -Record $goodRecord
    Check 'a well-formed record validates' $goodRecordResult.Ok $goodRecordResult.Reason

    Check 'a null record is rejected' (-not (Test-InstallRecordValid -Record $null).Ok)

    foreach ($requiredField in @('id', 'friendlyName', 'hookType', 'sourceScript', 'sourceDir', 'scope')) {

        $missingField = Copy-Record $goodRecord

        $missingField.PSObject.Properties.Remove($requiredField)

        Check ("a record missing '" + $requiredField + "' is rejected") (-not (Test-InstallRecordValid -Record $missingField).Ok)

    }

    $missingRuntimeRoot = Copy-Record $goodRecord
    $missingRuntimeRoot.clients.claude.PSObject.Properties.Remove('runtimeRoot')
    Check "a client subrecord missing 'runtimeRoot' is rejected" (-not (Test-InstallRecordValid -Record $missingRuntimeRoot).Ok)

    # ---- client subrecord fields must be ACTUAL non-empty strings ---------
    # missing / non-string (survives a [string] cast but never was one) /
    # whitespace-only, for every field a safe update/uninstall depends on.
    foreach ($field in @('settingsPath', 'runtimeRoot', 'runtimeScript', 'command')) {
        $missingVariant = Copy-Record $goodRecord
        $missingVariant.clients.claude.PSObject.Properties.Remove($field)
        Check ("a client subrecord missing '" + $field + "' is rejected") (-not (Test-InstallRecordValid -Record $missingVariant).Ok)

        $nonStringVariant = Copy-Record $goodRecord
        $nonStringVariant.clients.claude | Add-Member -MemberType NoteProperty -Name $field -Value 12345 -Force
        Check ("a client subrecord with a non-string '" + $field + "' is rejected") (-not (Test-InstallRecordValid -Record $nonStringVariant).Ok)

        $emptyVariant = Copy-Record $goodRecord
        $emptyVariant.clients.claude | Add-Member -MemberType NoteProperty -Name $field -Value '   ' -Force
        Check ("a client subrecord with an empty '" + $field + "' is rejected") (-not (Test-InstallRecordValid -Record $emptyVariant).Ok)
    }

    # ---- events entries must each be a non-empty string --------------------
    $nonStringEvent = Copy-Record $goodRecord
    $nonStringEvent.clients.claude.events = @(123)
    $nonStringEventResult = Test-InstallRecordValid -Record $nonStringEvent
    Check 'a non-string event entry is rejected' ((-not $nonStringEventResult.Ok) -and ($nonStringEventResult.Reason -match 'non-string entry')) $nonStringEventResult.Reason

    $emptyEvent = Copy-Record $goodRecord
    $emptyEvent.clients.claude.events = @('   ')
    $emptyEventResult = Test-InstallRecordValid -Record $emptyEvent
    Check 'an empty-string event entry is rejected' ((-not $emptyEventResult.Ok) -and ($emptyEventResult.Reason -match 'empty entry')) $emptyEventResult.Reason

    # ---- canonicalized path/command consistency ----------------------------
    $outsideRuntimeScript = Copy-Record $goodRecord
    $outsideRuntimeScript.clients.claude.runtimeScript = 'C:\SomewhereElse\F.ps1'
    $outsideResult = Test-InstallRecordValid -Record $outsideRuntimeScript
    Check 'runtimeScript outside runtimeRoot is rejected' ((-not $outsideResult.Ok) -and ($outsideResult.Reason -match 'outside runtimeRoot')) $outsideResult.Reason

    $directChildScript = Copy-Record $goodRecord
    $directChildScript.clients.claude.runtimeScript = (Join-Path $fixtureRuntimeRoot 'F.ps1')
    $directChildResult = Test-InstallRecordValid -Record $directChildScript
    Check 'runtimeScript sitting directly under runtimeRoot (no managed hook dir) is rejected' ((-not $directChildResult.Ok) -and ($directChildResult.Reason -match 'does not match managed hook directory')) $directChildResult.Reason

    # ---- runtimeScript leaf names must agree with friendlyName -------------
    # Same gate the uninstaller's Test-ClientRecordIdentity applies: menu 21
    # must not accept a record menu 22 would refuse as internally inconsistent.
    $wrongHookDirLeaf = Copy-Record $goodRecord
    $wrongHookDirLeaf.clients.claude.runtimeScript = (Join-Path $fixtureRuntimeRoot 'Wrong-Dir\F.ps1')
    $wrongHookDirLeaf.clients.claude.command = 'powershell.exe -File "' + (Join-Path $fixtureRuntimeRoot 'Wrong-Dir\F.ps1') + '"'
    $wrongHookDirLeafResult = Test-InstallRecordValid -Record $wrongHookDirLeaf
    Check 'a hook directory leaf that differs from friendlyName is rejected' ((-not $wrongHookDirLeafResult.Ok) -and ($wrongHookDirLeafResult.Reason -match 'managed hook directory')) $wrongHookDirLeafResult.Reason

    $wrongScriptLeaf = Copy-Record $goodRecord
    $wrongScriptLeaf.clients.claude.runtimeScript = (Join-Path $fixtureRuntimeRoot 'F\Other-Name.ps1')
    $wrongScriptLeaf.clients.claude.command = 'powershell.exe -File "' + (Join-Path $fixtureRuntimeRoot 'F\Other-Name.ps1') + '"'
    $wrongScriptLeafResult = Test-InstallRecordValid -Record $wrongScriptLeaf
    Check 'a script file leaf that differs from friendlyName + .ps1 is rejected' ((-not $wrongScriptLeafResult.Ok) -and ($wrongScriptLeafResult.Reason -match 'managed hook directory')) $wrongScriptLeafResult.Reason

    # Over-rejection guard: the comparison is case-INSENSITIVE on both leaves,
    # exactly as the uninstaller's is, so a differently-cased-but-genuine
    # installation must still validate.
    $casedLeaves = Copy-Record $goodRecord
    $casedLeaves.friendlyName = 'f'
    $casedLeavesResult = Test-InstallRecordValid -Record $casedLeaves
    Check 'leaf names matching friendlyName only case-insensitively still validate' $casedLeavesResult.Ok $casedLeavesResult.Reason

    $foreignGlobalSettings = Copy-Record $goodRecord
    $foreignGlobalSettings.clients.claude.settingsPath = 'C:\SomeOther\settings.json'
    $foreignGlobalResult = Test-InstallRecordValid -Record $foreignGlobalSettings
    Check 'a global record with a foreign settings path is rejected' ((-not $foreignGlobalResult.Ok) -and ($foreignGlobalResult.Reason -match 'does not match project scope/client')) $foreignGlobalResult.Reason

    $mismatchedCommand = Copy-Record $goodRecord
    $mismatchedCommand.clients.claude.command = 'powershell.exe -File "' + (Join-Path $fixtureRuntimeRoot 'Other\Other.ps1') + '"'
    $mismatchedCommandResult = Test-InstallRecordValid -Record $mismatchedCommand
    Check 'a persisted command targeting a different script than runtimeScript is rejected' ((-not $mismatchedCommandResult.Ok) -and ($mismatchedCommandResult.Reason -match 'does not target persisted runtimeScript')) $mismatchedCommandResult.Reason

    # GetFullPath throws on input it cannot interpret at all (an embedded null
    # character) - that must be a precise rejection, never an unhandled
    # exception escaping the validator.
    $uncanonicalizable = Copy-Record $goodRecord
    $uncanonicalizable.clients.claude | Add-Member -MemberType NoteProperty -Name runtimeRoot -Value ('C:\Bad' + [string][char]0 + 'Path') -Force
    $uncanonicalizableThrew = $false
    $uncanonicalizableResult = $null
    try { $uncanonicalizableResult = Test-InstallRecordValid -Record $uncanonicalizable } catch { $uncanonicalizableThrew = $true }
    Check 'a path value that cannot be canonicalized is rejected, not thrown' ((-not $uncanonicalizableThrew) -and ($null -ne $uncanonicalizableResult) -and (-not $uncanonicalizableResult.Ok) -and ($uncanonicalizableResult.Reason -match 'cannot be canonicalized')) $(if ($null -ne $uncanonicalizableResult) { $uncanonicalizableResult.Reason } else { 'threw' })

    # ---- PROJECT-scope records: both clients, canonical settingsPath -------
    $fixtureProjectRoot = Join-Path $Work 'FixtureProjectRoot'
    $fixtureProjectClaudeRuntimeRoot = Join-Path $fixtureProjectRoot '.claude\hooks\Hook-Maker'
    $fixtureProjectClaudeRuntimeScript = Join-Path $fixtureProjectClaudeRuntimeRoot 'F\F.ps1'
    $fixtureProjectClaudeSettingsPath = Join-Path $fixtureProjectRoot '.claude\settings.local.json'
    $fixtureProjectClaudeCommand = 'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $fixtureProjectClaudeRuntimeScript + '"'
    $fixtureProjectCodexRuntimeRoot = Join-Path $fixtureProjectRoot '.codex\hooks\Hook-Maker'
    $fixtureProjectCodexRuntimeScript = Join-Path $fixtureProjectCodexRuntimeRoot 'F\F.ps1'
    $fixtureProjectCodexSettingsPath = Join-Path $fixtureProjectRoot '.codex\hooks.json'
    $fixtureProjectCodexCommand = 'pwsh -NoLogo -NoProfile -NonInteractive -File "' + $fixtureProjectCodexRuntimeScript + '"'
    $fixtureProjectCodexCommandWindows = 'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $fixtureProjectCodexRuntimeScript + '"'

    $goodProjectRecord = [pscustomobject]@{
        id = 'schema-ok-project'; schema = 2; friendlyName = 'F'; hookType = 'CustomHook'
        sourceScript = 'C:\src\hook.ps1'; sourceDir = 'C:\src'; scope = 'project'; targetProjectRoot = $fixtureProjectRoot
        clients = [pscustomobject]@{
            claude = [pscustomobject]@{
                runtimeScript = $fixtureProjectClaudeRuntimeScript; settingsPath = $fixtureProjectClaudeSettingsPath; runtimeRoot = $fixtureProjectClaudeRuntimeRoot
                events = @('Stop'); command = $fixtureProjectClaudeCommand
            }
            codex = [pscustomobject]@{
                runtimeScript = $fixtureProjectCodexRuntimeScript; settingsPath = $fixtureProjectCodexSettingsPath; runtimeRoot = $fixtureProjectCodexRuntimeRoot
                events = @('Stop'); command = $fixtureProjectCodexCommand; commandWindows = $fixtureProjectCodexCommandWindows
            }
        }
    }
    $goodProjectResult = Test-InstallRecordValid -Record $goodProjectRecord
    Check 'a fully valid PROJECT-scope record (both clients) validates' $goodProjectResult.Ok $goodProjectResult.Reason

    # The leaf-name gate applies to the codex subrecord too, not just claude.
    $wrongCodexLeaf = Copy-Record $goodProjectRecord
    $codexWrongScript = Join-Path $fixtureProjectCodexRuntimeRoot 'F\Wrong.ps1'
    $wrongCodexLeaf.clients.codex.runtimeScript = $codexWrongScript
    $wrongCodexLeaf.clients.codex.command = 'pwsh -File "' + $codexWrongScript + '"'
    $wrongCodexLeaf.clients.codex.commandWindows = 'powershell.exe -File "' + $codexWrongScript + '"'
    $wrongCodexLeafResult = Test-InstallRecordValid -Record $wrongCodexLeaf
    Check 'a Codex subrecord with a mismatched script leaf is rejected too' ((-not $wrongCodexLeafResult.Ok) -and ($wrongCodexLeafResult.Reason -match 'managed hook directory')) $wrongCodexLeafResult.Reason

    $wrongCodexDirLeaf = Copy-Record $goodProjectRecord
    $codexWrongDir = Join-Path $fixtureProjectCodexRuntimeRoot 'Wrong-Dir\F.ps1'
    $wrongCodexDirLeaf.clients.codex.runtimeScript = $codexWrongDir
    $wrongCodexDirLeaf.clients.codex.command = 'pwsh -File "' + $codexWrongDir + '"'
    $wrongCodexDirLeaf.clients.codex.commandWindows = 'powershell.exe -File "' + $codexWrongDir + '"'
    $wrongCodexDirLeafResult = Test-InstallRecordValid -Record $wrongCodexDirLeaf
    Check 'a Codex subrecord with a mismatched hook directory leaf is rejected too' ((-not $wrongCodexDirLeafResult.Ok) -and ($wrongCodexDirLeafResult.Reason -match 'managed hook directory')) $wrongCodexDirLeafResult.Reason

    $wrongClaudeSettings = Copy-Record $goodProjectRecord
    $wrongClaudeSettings.clients.claude.settingsPath = $fixtureProjectCodexSettingsPath
    $wrongClaudeResult = Test-InstallRecordValid -Record $wrongClaudeSettings
    Check 'a project record with the wrong Claude settings path is rejected' ((-not $wrongClaudeResult.Ok) -and ($wrongClaudeResult.Reason -match 'does not match project scope/client')) $wrongClaudeResult.Reason

    $wrongCodexSettings = Copy-Record $goodProjectRecord
    $wrongCodexSettings.clients.codex.settingsPath = $fixtureProjectClaudeSettingsPath
    $wrongCodexResult = Test-InstallRecordValid -Record $wrongCodexSettings
    Check 'a project record with the wrong Codex settings path is rejected' ((-not $wrongCodexResult.Ok) -and ($wrongCodexResult.Reason -match 'does not match project scope/client')) $wrongCodexResult.Reason

    $missingCommandWindows = Copy-Record $goodProjectRecord
    $missingCommandWindows.clients.codex.PSObject.Properties.Remove('commandWindows')
    Check "a Codex subrecord missing 'commandWindows' is rejected" (-not (Test-InstallRecordValid -Record $missingCommandWindows).Ok)

    $emptyCommandWindows = Copy-Record $goodProjectRecord
    $emptyCommandWindows.clients.codex.commandWindows = ''
    Check 'a Codex subrecord with an empty commandWindows is rejected' (-not (Test-InstallRecordValid -Record $emptyCommandWindows).Ok)

    $claudeEmptyCommandWindowsStillOk = Copy-Record $goodProjectRecord
    $claudeEmptyCommandWindowsStillOk.clients.claude | Add-Member -MemberType NoteProperty -Name commandWindows -Value '' -Force
    Check "a Claude subrecord with an empty (not applicable) commandWindows still validates" ((Test-InstallRecordValid -Record $claudeEmptyCommandWindowsStillOk).Ok)

    $nonNumericTimeout = Copy-Record $goodRecord
    $nonNumericTimeout.clients.claude | Add-Member -MemberType NoteProperty -Name timeout -Value 'not-a-number'
    Check 'a non-numeric client timeout is rejected' (-not (Test-InstallRecordValid -Record $nonNumericTimeout).Ok)

    $numericTimeout = Copy-Record $goodRecord
    $numericTimeout.clients.claude | Add-Member -MemberType NoteProperty -Name timeout -Value 45
    Check 'a valid numeric client timeout still validates' ((Test-InstallRecordValid -Record $numericTimeout).Ok)

    $managedNativeMissingWrapper = Copy-Record $goodRecord
    $managedNativeMissingWrapper | Add-Member -MemberType NoteProperty -Name nativeGit -Value ([pscustomobject]@{ managed = $true; runtimeRoot = 'C:\runtime'; companions = @('Secrets-Check') })
    Check "a managed nativeGit record missing 'wrapperPath' is rejected" (-not (Test-InstallRecordValid -Record $managedNativeMissingWrapper).Ok)

    $managedNativeMissingCompanions = Copy-Record $goodRecord
    $managedNativeMissingCompanions | Add-Member -MemberType NoteProperty -Name nativeGit -Value ([pscustomobject]@{ managed = $true; wrapperPath = 'C:\p\pre-push'; runtimeRoot = 'C:\runtime' })
    Check "a managed nativeGit record missing 'companions' is rejected" (-not (Test-InstallRecordValid -Record $managedNativeMissingCompanions).Ok)

    $unmanagedNativeIncomplete = Copy-Record $goodRecord
    $unmanagedNativeIncomplete | Add-Member -MemberType NoteProperty -Name nativeGit -Value ([pscustomobject]@{ managed = $false })
    Check 'an UNMANAGED nativeGit record is never dereferenced for shape' ((Test-InstallRecordValid -Record $unmanagedNativeIncomplete).Ok)

    $completeManagedNative = Copy-Record $goodRecord
    $completeManagedNative | Add-Member -MemberType NoteProperty -Name nativeGit -Value ([pscustomobject]@{ managed = $true; wrapperPath = 'C:\p\pre-push'; runtimeRoot = 'C:\runtime'; companions = @('Secrets-Check'); sourceManifest = @([pscustomobject]@{ path = 'secrets-check/secrets-check.ps1'; hash = 'A1B2C3D4E5F60718293A4B5C6D7E8F901234567890ABCDEF1234567890ABCDEF' }) })
    Check 'a complete managed nativeGit record still validates' ((Test-InstallRecordValid -Record $completeManagedNative).Ok)

    $malformedLastComponents = Copy-Record $goodRecord
    $malformedLastComponents | Add-Member -MemberType NoteProperty -Name lastComponents -Value @([pscustomobject]@{ component = 'claude' })
    Check 'a lastComponents entry missing status/reason is rejected' (-not (Test-InstallRecordValid -Record $malformedLastComponents).Ok)

    $wellFormedLastComponents = Copy-Record $goodRecord
    $wellFormedLastComponents | Add-Member -MemberType NoteProperty -Name lastComponents -Value @([pscustomobject]@{ component = 'claude'; status = 'ok'; reason = '' })
    Check 'a well-formed lastComponents entry still validates' ((Test-InstallRecordValid -Record $wellFormedLastComponents).Ok)

    $newerSchema = Copy-Record $goodRecord; $newerSchema.schema = 99

    $newerResult = Test-InstallRecordValid -Record $newerSchema

    Check 'a NEWER schema version is refused explicitly, not assumed valid' ((-not $newerResult.Ok) -and ($newerResult.Reason -match 'unsupported schema')) $newerResult.Reason

    $olderSchema = Copy-Record $goodRecord; $olderSchema.schema = 1

    Check 'an OLD schema version is reported as needing migration' (-not (Test-InstallRecordValid -Record $olderSchema).Ok)

    $invalidScope = Copy-Record $goodRecord; $invalidScope.scope = 'nonsense'

    Check 'an invalid scope is rejected' (-not (Test-InstallRecordValid -Record $invalidScope).Ok)

    $invalidType = Copy-Record $goodRecord; $invalidType.hookType = 'Weird'

    Check 'an unknown hookType is rejected' (-not (Test-InstallRecordValid -Record $invalidType).Ok)

    $noEvents = Copy-Record $goodRecord; $noEvents.clients.claude.events = @()

    Check 'a client subrecord with no events is rejected' (-not (Test-InstallRecordValid -Record $noEvents).Ok)

    $badManifest = Copy-Record $goodRecord

    $badManifest | Add-Member -MemberType NoteProperty -Name sourceManifest -Value @([pscustomobject]@{ nothing = 'here' })

    Check 'a malformed sourceManifest entry is rejected' (-not (Test-InstallRecordValid -Record $badManifest).Ok)

    $engineNoProfile = Copy-Record $goodRecord; $engineNoProfile.hookType = 'Engine'

    Check 'an engine record without profile/config is rejected' (-not (Test-InstallRecordValid -Record $engineNoProfile).Ok)

    # Table-driven managed-nativeGit schema cases (Defect 4): Test-NativePrePushState
    # reads `@($NativeRecord.sourceManifest)` completely unguarded, so a managed
    # record missing it used to pass validation here and only throw later, under
    # StrictMode, during integrity evaluation. Every malformed variant below is
    # derived from one valid fixture so only the field under test differs.
    $goodManagedNative = Copy-Record $goodRecord
    $goodManagedNative | Add-Member -MemberType NoteProperty -Name nativeGit -Value ([pscustomobject]@{
        managed = $true; hooksPath = 'C:\p\.git\hooks'; runtimeRoot = 'C:\p\.git\hooks\Hook-Maker'
        wrapperPath = 'C:\p\.git\hooks\pre-push'; previousHookPath = 'C:\p\.git\hooks\pre-push.hookmaker-existing'
        previousHookPreserved = $true; previousHookMissing = $false
        expectedStages = @('Ignore-Rules-Check', 'Secrets-Check'); wrapperBodyHash = 'abc123'
        companions = @('Secrets-Check')
        sourceManifest = @([pscustomobject]@{ path = 'secrets-check/secrets-check.ps1'; hash = 'A1B2C3D4E5F60718293A4B5C6D7E8F901234567890ABCDEF1234567890ABCDEF' })
    })
    $goodManagedNative = Copy-Record $goodManagedNative

    Check 'a fully valid managed native record validates' ((Test-InstallRecordValid -Record $goodManagedNative).Ok)

    $noExpectedStages = Copy-Record $goodManagedNative
    $noExpectedStages.nativeGit.PSObject.Properties.Remove('expectedStages')
    Check 'a managed native record with expectedStages absent still validates (it is optional)' ((Test-InstallRecordValid -Record $noExpectedStages).Ok)

    # Hash comparison is case-sensitive text matching against Get-FileSha256's
    # output, but Get-FileHash itself may emit either case, so the validator's
    # hex-format check must accept both.
    $upperHashNative = Copy-Record $goodManagedNative
    $upperHashNative.nativeGit | Add-Member -MemberType NoteProperty -Name sourceManifest -Value @([pscustomobject]@{ path = 'secrets-check/secrets-check.ps1'; hash = 'A1B2C3D4E5F60718293A4B5C6D7E8F901234567890ABCDEF1234567890ABCDEF' }) -Force
    Check 'a valid UPPERCASE 64-hex hash is accepted' ((Test-InstallRecordValid -Record $upperHashNative).Ok)

    $lowerHashNative = Copy-Record $goodManagedNative
    $lowerHashNative.nativeGit | Add-Member -MemberType NoteProperty -Name sourceManifest -Value @([pscustomobject]@{ path = 'secrets-check/secrets-check.ps1'; hash = 'a1b2c3d4e5f60718293a4b5c6d7e8f901234567890abcdef1234567890abcdef' }) -Force
    Check 'a valid lowercase 64-hex hash is accepted' ((Test-InstallRecordValid -Record $lowerHashNative).Ok)

    $unmanagedMissingEverything = Copy-Record $goodRecord
    $unmanagedMissingEverything | Add-Member -MemberType NoteProperty -Name nativeGit -Value ([pscustomobject]@{ managed = $false })
    Check 'an unmanaged nativeGit record missing sourceManifest/companions is never shape-checked' ((Test-InstallRecordValid -Record $unmanagedMissingEverything).Ok)

    $managedNativeSchemaCases = @(
        @{ Name = 'sourceManifest missing'; Reason = 'is missing "sourceManifest"'; Mutate = { param($r) $r.nativeGit.PSObject.Properties.Remove('sourceManifest') } }
        @{ Name = 'sourceManifest is $null'; Reason = '"sourceManifest" is not an array'; Mutate = { param($r) $r.nativeGit | Add-Member -MemberType NoteProperty -Name sourceManifest -Value $null -Force } }
        @{ Name = 'sourceManifest is a scalar'; Reason = '"sourceManifest" is not an array'; Mutate = { param($r) $r.nativeGit | Add-Member -MemberType NoteProperty -Name sourceManifest -Value 'not-an-array' -Force } }
        @{ Name = 'sourceManifest has a null entry'; Reason = 'contains a malformed entry'; Mutate = { param($r) $r.nativeGit | Add-Member -MemberType NoteProperty -Name sourceManifest -Value @($null) -Force } }
        @{ Name = 'sourceManifest entry missing path'; Reason = 'contains a malformed entry'; Mutate = { param($r) $r.nativeGit | Add-Member -MemberType NoteProperty -Name sourceManifest -Value @([pscustomobject]@{ hash = 'ABCDEF1234567890' }) -Force } }
        @{ Name = 'sourceManifest entry missing hash'; Reason = 'contains a malformed entry'; Mutate = { param($r) $r.nativeGit | Add-Member -MemberType NoteProperty -Name sourceManifest -Value @([pscustomobject]@{ path = 'x.ps1' }) -Force } }
        @{ Name = 'sourceManifest entry has an empty path'; Reason = 'contains an entry with an empty path'; Mutate = { param($r) $r.nativeGit | Add-Member -MemberType NoteProperty -Name sourceManifest -Value @([pscustomobject]@{ path = '   '; hash = 'ABCDEF1234567890' }) -Force } }
        @{ Name = 'sourceManifest entry has a malformed hash'; Reason = 'is not a 64-character SHA-256 hex value'; Mutate = { param($r) $r.nativeGit | Add-Member -MemberType NoteProperty -Name sourceManifest -Value @([pscustomobject]@{ path = 'x.ps1'; hash = 'not-hex-zzz!' }) -Force } }
        @{ Name = 'companions is a scalar'; Reason = '"companions" is not an array'; Mutate = { param($r) $r.nativeGit | Add-Member -MemberType NoteProperty -Name companions -Value 'Secrets-Check' -Force } }
        @{ Name = 'companions has an empty entry'; Reason = '"companions" contains an empty entry'; Mutate = { param($r) $r.nativeGit | Add-Member -MemberType NoteProperty -Name companions -Value @('') -Force } }
        @{ Name = 'expectedStages is a scalar'; Reason = '"expectedStages" is not an array'; Mutate = { param($r) $r.nativeGit | Add-Member -MemberType NoteProperty -Name expectedStages -Value 'Secrets-Check' -Force } }
        @{ Name = 'expectedStages has an empty entry'; Reason = '"expectedStages" contains an empty entry'; Mutate = { param($r) $r.nativeGit | Add-Member -MemberType NoteProperty -Name expectedStages -Value @('') -Force } }
        @{ Name = 'previousHookPreserved is not a boolean'; Reason = '"previousHookPreserved" is not a boolean'; Mutate = { param($r) $r.nativeGit | Add-Member -MemberType NoteProperty -Name previousHookPreserved -Value 'yes' -Force } }
        @{ Name = 'previousHookPath is not a string'; Reason = '"previousHookPath" is not a string'; Mutate = { param($r) $r.nativeGit | Add-Member -MemberType NoteProperty -Name previousHookPath -Value 12345 -Force } }
        # Hash validity: Get-FileSha256 always returns exactly 64 lowercase-or-
        # uppercase hex characters, so anything shorter, longer, or non-hex can
        # never equal a real hash and must be rejected rather than read as drift.
        @{ Name = 'sourceManifest entry hash is empty (0 chars)'; Reason = 'is not a 64-character SHA-256 hex value'; Mutate = { param($r) $r.nativeGit | Add-Member -MemberType NoteProperty -Name sourceManifest -Value @([pscustomobject]@{ path = 'x.ps1'; hash = '' }) -Force } }
        @{ Name = 'sourceManifest entry hash is 16 hex chars'; Reason = 'is not a 64-character SHA-256 hex value'; Mutate = { param($r) $r.nativeGit | Add-Member -MemberType NoteProperty -Name sourceManifest -Value @([pscustomobject]@{ path = 'x.ps1'; hash = 'ABCDEF1234567890' }) -Force } }
        @{ Name = 'sourceManifest entry hash is 63 hex chars'; Reason = 'is not a 64-character SHA-256 hex value'; Mutate = { param($r) $r.nativeGit | Add-Member -MemberType NoteProperty -Name sourceManifest -Value @([pscustomobject]@{ path = 'x.ps1'; hash = ('A1B2C3D4E5F60718293A4B5C6D7E8F901234567890ABCDEF1234567890ABCDEF').Substring(0, 63) }) -Force } }
        @{ Name = 'sourceManifest entry hash is 65 hex chars'; Reason = 'is not a 64-character SHA-256 hex value'; Mutate = { param($r) $r.nativeGit | Add-Member -MemberType NoteProperty -Name sourceManifest -Value @([pscustomobject]@{ path = 'x.ps1'; hash = ('A1B2C3D4E5F60718293A4B5C6D7E8F901234567890ABCDEF1234567890ABCDEF' + 'A') }) -Force } }
        @{ Name = 'sourceManifest entry hash is 64 non-hex chars'; Reason = 'is not a 64-character SHA-256 hex value'; Mutate = { param($r) $r.nativeGit | Add-Member -MemberType NoteProperty -Name sourceManifest -Value @([pscustomobject]@{ path = 'x.ps1'; hash = ('z' * 64) }) -Force } }
        # Type strictness: path/companion/expectedStages entries are used as path
        # segments or rebuilt into wrapper text verbatim, so a numeric/object/$null
        # value that merely SURVIVES a [string] cast must still be rejected.
        @{ Name = 'sourceManifest entry path is numeric'; Reason = 'whose path is not a string'; Mutate = { param($r) $r.nativeGit | Add-Member -MemberType NoteProperty -Name sourceManifest -Value @([pscustomobject]@{ path = 123; hash = 'A1B2C3D4E5F60718293A4B5C6D7E8F901234567890ABCDEF1234567890ABCDEF' }) -Force } }
        @{ Name = 'sourceManifest entry path is an object'; Reason = 'whose path is not a string'; Mutate = { param($r) $r.nativeGit | Add-Member -MemberType NoteProperty -Name sourceManifest -Value @([pscustomobject]@{ path = ([pscustomobject]@{ nested = $true }); hash = 'A1B2C3D4E5F60718293A4B5C6D7E8F901234567890ABCDEF1234567890ABCDEF' }) -Force } }
        @{ Name = 'sourceManifest entry path is $null'; Reason = 'whose path is not a string'; Mutate = { param($r) $r.nativeGit | Add-Member -MemberType NoteProperty -Name sourceManifest -Value @([pscustomobject]@{ path = $null; hash = 'A1B2C3D4E5F60718293A4B5C6D7E8F901234567890ABCDEF1234567890ABCDEF' }) -Force } }
        @{ Name = 'companions entry is numeric'; Reason = '"companions" contains a non-string entry'; Mutate = { param($r) $r.nativeGit | Add-Member -MemberType NoteProperty -Name companions -Value @(123) -Force } }
        @{ Name = 'companions entry is an object'; Reason = '"companions" contains a non-string entry'; Mutate = { param($r) $r.nativeGit | Add-Member -MemberType NoteProperty -Name companions -Value @([pscustomobject]@{ nested = $true }) -Force } }
        @{ Name = 'companions entry is $null'; Reason = '"companions" contains a non-string entry'; Mutate = { param($r) $r.nativeGit | Add-Member -MemberType NoteProperty -Name companions -Value @($null) -Force } }
        @{ Name = 'expectedStages entry is numeric'; Reason = '"expectedStages" contains a non-string entry'; Mutate = { param($r) $r.nativeGit | Add-Member -MemberType NoteProperty -Name expectedStages -Value @(123) -Force } }
        @{ Name = 'expectedStages entry is an object'; Reason = '"expectedStages" contains a non-string entry'; Mutate = { param($r) $r.nativeGit | Add-Member -MemberType NoteProperty -Name expectedStages -Value @([pscustomobject]@{ nested = $true }) -Force } }
        @{ Name = 'expectedStages entry is $null'; Reason = '"expectedStages" contains a non-string entry'; Mutate = { param($r) $r.nativeGit | Add-Member -MemberType NoteProperty -Name expectedStages -Value @($null) -Force } }
    )

    foreach ($case in $managedNativeSchemaCases) {
        $variant = Copy-Record $goodManagedNative
        & $case.Mutate $variant
        $result = Test-InstallRecordValid -Record $variant
        Check ('managed nativeGit: ' + $case.Name + ' is rejected') ((-not $result.Ok) -and ($result.Reason -match $case.Reason)) $result.Reason
    }



    # End-to-end: a broken record placed BEFORE a healthy one must not stop the

    # healthy one from being evaluated.

    $isoProj = New-Proj 'IsolationProj'

    & $InstallScript -CustomHook (Join-Path $RealHooksDir 'Ai-Memory-Check\Ai-Memory-Check.ps1') -Events @('Stop') -TargetProject $isoProj -ClaudeOnly *> $null

    $isoRegPath = Join-Path $env:HOOKMAKER_STATE_DIR 'install-registry.json'

    $isoReg = Get-Content -LiteralPath $isoRegPath -Raw | ConvertFrom-Json

    $isoOriginal = [System.IO.File]::ReadAllText($isoRegPath)

    $isoBroken = [pscustomobject]@{ id = 'broken-isolation'; schema = 2; friendlyName = 'Broken-Hook' }

    # A second, independently healthy record (a straight clone of the real one
    # under a different id) alongside THREE differently-malformed records
    # covering the newly-validated Defect 4 field categories, so the mixed
    # batch proves both directions at once: every kind of malformed record is
    # isolated, and BOTH healthy records still evaluate. Only the id differs -
    # renaming friendlyName alone would leave runtimeScript pointing at the
    # original hook directory, which is now (correctly) an invalid record.
    $isoHealthy2 = $isoReg.installs[0] | ConvertTo-Json -Depth 50 | ConvertFrom-Json
    $isoHealthy2.id = 'iso-healthy-clone'

    $isoMissingRuntimeRoot = $isoReg.installs[0] | ConvertTo-Json -Depth 50 | ConvertFrom-Json
    $isoMissingRuntimeRoot.id = 'iso-missing-runtimeroot'
    $isoMissingRuntimeRoot.clients.claude.PSObject.Properties.Remove('runtimeRoot')

    $isoBadTimeout = $isoReg.installs[0] | ConvertTo-Json -Depth 50 | ConvertFrom-Json
    $isoBadTimeout.id = 'iso-bad-timeout'
    $isoBadTimeout.clients.claude | Add-Member -MemberType NoteProperty -Name timeout -Value 'not-numeric' -Force

    $isoBadNative = $isoReg.installs[0] | ConvertTo-Json -Depth 50 | ConvertFrom-Json
    $isoBadNative.id = 'iso-bad-nativegit'
    $isoBadNative | Add-Member -MemberType NoteProperty -Name nativeGit -Value ([pscustomobject]@{ managed = $true }) -Force

    $isoReg.installs = @($isoBroken, $isoMissingRuntimeRoot, $isoBadTimeout, $isoBadNative) + @($isoReg.installs) + @($isoHealthy2)

    [System.IO.File]::WriteAllText($isoRegPath, ($isoReg | ConvertTo-Json -Depth 50), (New-Object System.Text.UTF8Encoding $false))

    $isoEvaluated = 0; $isoSkipped = 0; $isoCrashed = $false

    foreach ($isoRecord in @((Read-InstallRegistry -ToolRoot $ToolRoot).installs)) {

        try {

            $isoValid = Test-InstallRecordValid -Record $isoRecord

            if (-not $isoValid.Ok) { $isoSkipped++; continue }

            $null = Get-InstallIntegrity -Record $isoRecord -ToolRoot $ToolRoot

            $isoEvaluated++

        }

        catch { $isoCrashed = $true; break }

    }

    Check 'a malformed record never crashes the batch' (-not $isoCrashed)

    Check 'every differently-malformed record is isolated as a skip (4 total)' ($isoSkipped -eq 4)

    Check 'both healthy records (original + clone) are still evaluated' ($isoEvaluated -eq 2)

    # The updater must not have modified the malformed record.

    $isoAfter = Get-Content -LiteralPath $isoRegPath -Raw | ConvertFrom-Json

    Check 'the malformed record is left untouched, never repaired by guessing' (@($isoAfter.installs | Where-Object { $_.id -eq 'broken-isolation' }).Count -eq 1)

    [System.IO.File]::WriteAllText($isoRegPath, $isoOriginal, (New-Object System.Text.UTF8Encoding $false))

    # A SEPARATE mixed-registry batch, specifically for the Defect 4 fields:
    # a real installer-written managed nativeGit record (Ignore-Rules-Check,
    # installed into a real git repo) alongside a real client-based record,
    # plus several nativeGit variants malformed ONLY in the newly validated
    # fields (missing sourceManifest, a non-hex hash, non-array companions) -
    # proving each is skipped before Get-InstallIntegrity/Test-NativePrePushState
    # ever sees it, while both healthy records still evaluate.

    $nmiProj = New-Proj 'NativeManagedIsolation'

    & git -C $nmiProj init -q -b main 2>$null

    & git -C $nmiProj config user.email 't@t' 2>$null

    & git -C $nmiProj config user.name 't' 2>$null

    & $InstallScript -CustomHook (Join-Path $RealHooksDir 'Ai-Memory-Check\Ai-Memory-Check.ps1') -Events @('Stop') -TargetProject $nmiProj -ClaudeOnly *> $null

    & $InstallScript -CustomHook (Join-Path $RealHooksDir 'Ignore-Rules-Check\Ignore-Rules-Check.ps1') -Events @('Stop') -TargetProject $nmiProj -ClaudeOnly *> $null

    $nmiReg = Read-InstallRegistry -ToolRoot $ToolRoot

    $nmiHealthyNormal = @($nmiReg.installs | Where-Object { $_.friendlyName -eq 'Ai-Memory-Check' -and $_.targetProjectRoot -eq $nmiProj })[0]

    $nmiHealthyNative = @($nmiReg.installs | Where-Object { $_.friendlyName -eq 'Ignore-Rules-Check' -and $_.targetProjectRoot -eq $nmiProj })[0]

    Check 'setup: the healthy normal record installed for the native batch' ($null -ne $nmiHealthyNormal)

    Check 'setup: the healthy managed-native record installed for the native batch' ($null -ne $nmiHealthyNative -and $nmiHealthyNative.nativeGit.managed -eq $true)

    $nmiMissingSourceManifest = Copy-Record $nmiHealthyNative

    $nmiMissingSourceManifest.id = 'nmi-missing-sourcemanifest'

    $nmiMissingSourceManifest.nativeGit.PSObject.Properties.Remove('sourceManifest')

    $nmiBadHash = Copy-Record $nmiHealthyNative

    $nmiBadHash.id = 'nmi-bad-hash'

    $nmiBadHash.nativeGit | Add-Member -MemberType NoteProperty -Name sourceManifest -Value @([pscustomobject]@{ path = 'secrets-check/secrets-check.ps1'; hash = 'not-hex-zzz!' }) -Force

    $nmiScalarCompanions = Copy-Record $nmiHealthyNative

    $nmiScalarCompanions.id = 'nmi-scalar-companions'

    $nmiScalarCompanions.nativeGit | Add-Member -MemberType NoteProperty -Name companions -Value 'Secrets-Check' -Force

    $nmiBatch = @($nmiHealthyNormal, $nmiHealthyNative, $nmiMissingSourceManifest, $nmiBadHash, $nmiScalarCompanions)

    $nmiEvaluated = 0; $nmiSkipped = 0; $nmiCrashed = $false

    foreach ($nmiRecord in $nmiBatch) {

        try {

            $nmiValid = Test-InstallRecordValid -Record $nmiRecord

            if (-not $nmiValid.Ok) { $nmiSkipped++; continue }

            $null = Get-InstallIntegrity -Record $nmiRecord -ToolRoot $ToolRoot

            $nmiEvaluated++

        }

        catch { $nmiCrashed = $true; break }

    }

    Check 'a malformed managed-native record never crashes the batch' (-not $nmiCrashed)

    Check 'every differently-malformed managed-native record is isolated as a skip (3 total)' ($nmiSkipped -eq 3)

    Check 'both the healthy normal and the healthy managed-native record still evaluate' ($nmiEvaluated -eq 2)
