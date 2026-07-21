# Offline test suite for REGISTRY INTEGRITY: schema validation, per-record
# isolation, corruption/availability handling, and the path-safety primitives
# the installer relies on.
#
# Split out of Test-InstallRegistry.ps1 (which covers install/update FLOWS) so
# each suite has one responsibility: this file exercises the registry and path
# layer directly, without depending on install-flow fixtures beyond a single
# real install used to prove batch isolation.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-InstallRegistrySchema.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$ToolRoot = Split-Path -Parent $ScriptRoot
$RealHooksDir = Join-Path $ToolRoot 'hooks'
$InstallScript = Join-Path $ScriptRoot 'Install-Hook.ps1'
$HookLib = Join-Path $RealHooksDir '_hooklib.ps1'
foreach ($required in @($InstallScript, $HookLib)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-Host "Required script not found: $required" -ForegroundColor Red
        exit 1
    }
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 500
. (Join-Path $PSScriptRoot '_testlib.ps1')
. $HookLib
# _installplan.ps1 first: _installlib.ps1's manifest builders delegate to the
# canonical plan defined there.
. (Join-Path $ScriptRoot '_installplan.ps1')
. (Join-Path $ScriptRoot '_installlib.ps1')

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-regschema-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Work -Force | Out-Null
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

function New-Proj { param([string]$Name) $p = Join-Path $Work $Name; New-Item -ItemType Directory -Path $p -Force | Out-Null; return $p }
function Write-Utf8 { param([string]$Path, [string]$Content) [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false)) }

# Keeps every install and registry write inside this workspace, away from the
# real checkout's own state\install-registry.json.
$SavedHookMakerStateDir = $env:HOOKMAKER_STATE_DIR
$IsolatedStateDir = Join-Path $Work 'state'
$env:HOOKMAKER_STATE_DIR = $IsolatedStateDir

try {
    # =====================================================================

    Write-Host '--- registry availability: zero-byte file and orphan lock ---' -ForegroundColor Cyan

    $availRoot = Join-Path $Work 'availability-root'

    New-Item -ItemType Directory -Path (Join-Path $availRoot 'state') -Force | Out-Null

    $availRegistry = Join-Path $availRoot 'state\install-registry.json'

    $savedAvailStateDir = $env:HOOKMAKER_STATE_DIR

    $env:HOOKMAKER_STATE_DIR = ''

    try {

        Write-Utf8 $availRegistry '{"version":2,"installs":[{"id":"real-record","schema":2,"friendlyName":"Real"}]}'

        Check 'a healthy registry reads as ok' ((Read-InstallRegistryState -ToolRoot $availRoot).State -eq 'ok')

        [System.IO.File]::WriteAllText($availRegistry, '')

        Check 'a zero-byte registry is corrupt, not missing' ((Read-InstallRegistryState -ToolRoot $availRoot).State -eq 'corrupt')

        [System.IO.File]::WriteAllText($availRegistry, '    ')

        Check 'a whitespace-only registry is corrupt, not missing' ((Read-InstallRegistryState -ToolRoot $availRoot).State -eq 'corrupt')

        Remove-Item -LiteralPath $availRegistry -Force

        Check 'a genuinely absent registry is still reported missing' ((Read-InstallRegistryState -ToolRoot $availRoot).State -eq 'missing')

        $availLock = Join-Path $availRoot 'state\install-registry.lock'

        Write-Utf8 $availLock '{"pid":999999,"host":"machine-that-died"}'

        $reclaimed = $false

        $probeRecord = [pscustomobject][ordered]@{

            id = 'orphan-lock-probe'; schema = 2; friendlyName = 'OrphanProbe'; hookType = 'CustomHook'

            sourceScript = ''; sourceDir = ''; scope = 'project'; targetProjectRoot = ''

            profile = ''; configPath = ''; sourceManifest = @(); clients = [pscustomobject]@{}; nativeGit = $null

            lastResult = 'ok'; lastReason = 'probe'; lastError = ''

        }

        try { Update-InstallRegistry -ToolRoot $availRoot -Record $probeRecord | Out-Null; $reclaimed = $true } catch { }

        Check 'an orphan lock from a killed writer is reclaimed, not fatal forever' $reclaimed

        Check 'the lock file is released after the write' (-not (Test-Path -LiteralPath $availLock))

    }

    finally { $env:HOOKMAKER_STATE_DIR = $savedAvailStateDir }



    # =====================================================================

    # Filesystem roots and physical boundaries. Lexical containment must never

    # turn a root into a non-root ('C:\' -> 'C:'), and a sibling whose name

    # merely starts with the parent's name is not inside it.

    Write-Host '--- path roots, sibling-prefix attacks and traversal ---' -ForegroundColor Cyan

    Check 'a drive root contains its children' (Test-PathContainedIn -ChildPath 'C:\Windows\System32' -ParentPath 'C:\')

    Check 'a drive root is contained in itself' (Test-PathContainedIn -ChildPath 'C:\' -ParentPath 'C:\')

    Check 'a UNC share root contains its children' (Test-PathContainedIn -ChildPath '\\server\share\dir\file.txt' -ParentPath '\\server\share')

    Check 'a sibling-prefix directory is NOT contained' (-not (Test-PathContainedIn -ChildPath 'C:\Hook-Maker-Evil\x.ps1' -ParentPath 'C:\Hook-Maker'))

    Check 'an exact-name directory IS contained' (Test-PathContainedIn -ChildPath 'C:\Hook-Maker\x.ps1' -ParentPath 'C:\Hook-Maker')

    Check 'a parent-relative traversal escapes containment' (-not (Test-PathContainedIn -ChildPath 'C:\Hook-Maker\..\Other\x.ps1' -ParentPath 'C:\Hook-Maker'))

    Check 'a nested traversal that stays inside is contained' (Test-PathContainedIn -ChildPath 'C:\Hook-Maker\sub\..\x.ps1' -ParentPath 'C:\Hook-Maker')

    Check 'alternate separators are normalized' (Test-PathContainedIn -ChildPath 'C:/Hook-Maker/sub/x.ps1' -ParentPath 'C:\Hook-Maker')

    Check 'Windows path comparison is case-insensitive' (Test-PathContainedIn -ChildPath 'C:\HOOK-MAKER\x.ps1' -ParentPath 'C:\hook-maker')

    Check 'an unrelated drive is never contained' (-not (Test-PathContainedIn -ChildPath 'D:\Hook-Maker\x.ps1' -ParentPath 'C:\Hook-Maker'))

    Check 'empty paths are never contained' ((-not (Test-PathContainedIn -ChildPath '' -ParentPath 'C:\X')) -and (-not (Test-PathContainedIn -ChildPath 'C:\X' -ParentPath '')))

    # A planned artifact must never be able to escape its staging directory.

    $escapePlan = @(New-PlanArtifact -RelativePath '../escaped.ps1' -Kind 'Generated' -GeneratedContent 'x')

    $escapeRoot = Join-Path $Work 'escape-root'

    New-Item -ItemType Directory -Path $escapeRoot -Force | Out-Null

    $escapeThrew = $false

    try { Install-PlannedRuntime -Plan $escapePlan -RuntimeRoot $escapeRoot -FriendlyName 'Escape-Test' | Out-Null } catch { $escapeThrew = $true }

    Check 'a planned artifact that escapes staging is rejected' $escapeThrew

    Check 'the escape attempt wrote nothing outside the runtime root' (-not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $escapeRoot) 'escaped.ps1')))



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

    # =====================================================================
    # GENUINE-RECORD PROOF: the stricter validation above must never reject a
    # record Install-Hook.ps1 actually writes. Every genuine record is checked
    # both directly and after a real JSON round-trip (ConvertTo-Json |
    # ConvertFrom-Json), since that is exactly how a record persists and is
    # read back by every real caller.
    Write-Host '--- genuine installer-written records still validate ---' -ForegroundColor Cyan

    function Assert-GenuineRecordValidates {
        param([string]$Label, $Record)
        Check ("setup: " + $Label + " record was found") ($null -ne $Record)
        if ($null -eq $Record) { return }
        $direct = Test-InstallRecordValid -Record $Record
        Check ($Label + ' validates directly') $direct.Ok $direct.Reason
        $roundTripped = $Record | ConvertTo-Json -Depth 50 | ConvertFrom-Json
        $afterRoundTrip = Test-InstallRecordValid -Record $roundTripped
        Check ($Label + ' still validates after a JSON round-trip') $afterRoundTrip.Ok $afterRoundTrip.Reason
    }

    # Reuse the two real records already installed above rather than
    # reinstalling: a plain CustomHook install and a managed native-git
    # (Ignore-Rules-Check) install, both genuinely written by Install-Hook.ps1.
    Assert-GenuineRecordValidates 'a real CustomHook install' $nmiHealthyNormal
    Assert-GenuineRecordValidates 'a real NATIVE-git managed install' $nmiHealthyNative

    # A fresh install for BOTH clients (no -ClaudeOnly/-CodexOnly): the only
    # way to prove a genuine CODEX subrecord (real commandWindows) validates,
    # since every fixture above used -ClaudeOnly.
    $bothClientsProj = New-Proj 'GenuineBothClientsProj'
    & $InstallScript -CustomHook (Join-Path $RealHooksDir 'Ai-Memory-Check\Ai-Memory-Check.ps1') -Events @('Stop') -TargetProject $bothClientsProj *> $null
    $bothClientsRecord = @((Read-InstallRegistry -ToolRoot $ToolRoot).installs | Where-Object { $_.friendlyName -eq 'Ai-Memory-Check' -and $_.targetProjectRoot -eq $bothClientsProj })[0]
    Check 'setup: the both-clients record has a codex subrecord' ($null -ne $bothClientsRecord -and $null -ne $bothClientsRecord.clients.codex)
    Assert-GenuineRecordValidates 'a real install for both Claude and Codex' $bothClientsRecord

    # A fresh ENGINE/profile install (sync-hooks.json + -Profile), the third
    # required-to-prove genuine shape.
    $engineProj = New-Proj 'GenuineEngineProj'
    $engineCfgPath = Join-Path $Work 'genuine-engine-cfg.json'
    $engineConfigJson = @{
        version  = 2
        defaults = @{ events = @('SessionStart', 'UserPromptSubmit') }
        profiles = @(@{
            id     = 'genuine-profile'
            name   = 'Genuine Profile'
            routes = @(@{
                id          = 'genuine-route'
                source      = @{ root = (Join-Path $Work 'GenuineSyncSrc'); name = 'Src' }
                destination = @{ root = (Join-Path $Work 'GenuineSyncDst'); name = 'Dst' }
            })
        })
    }
    ($engineConfigJson | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $engineCfgPath -Encoding utf8
    & $InstallScript -Profile 'genuine-profile' -ConfigPath $engineCfgPath -TargetProject $engineProj -Events @('SessionStart') *> $null
    $engineRecord = @((Read-InstallRegistry -ToolRoot $ToolRoot).installs | Where-Object { $_.hookType -eq 'Engine' -and $_.targetProjectRoot -eq $engineProj })[0]
    Assert-GenuineRecordValidates 'a real ENGINE/profile install' $engineRecord

    # Get-InstallIntegrity must still accept every one of these without
    # throwing under StrictMode - a record that validates must never then
    # crash the updater it feeds into.
    $integrityThrew = $false
    foreach ($genuineRecord in @($nmiHealthyNormal, $nmiHealthyNative, $bothClientsRecord, $engineRecord)) {
        try { $null = Get-InstallIntegrity -Record $genuineRecord -ToolRoot $ToolRoot } catch { $integrityThrew = $true }
    }
    Check 'Get-InstallIntegrity accepts every genuine record without throwing' (-not $integrityThrew)

    # =====================================================================
    # SCHEMA 3: v2 -> v3 migration must be additive only. It stamps recordType
    # and origin and touches nothing else - not a value, not an id, not one
    # history entry. Anything more would silently rewrite install history the
    # uninstaller and updater both act on.
    Write-Host '--- v2 -> v3 migration is deterministic, lossless and idempotent ---' -ForegroundColor Cyan

    # Every property of a record, serialized, so a comparison covers VALUES and
    # not merely which names are present.
    function Get-RecordPropertyMap {
        param($Record)
        $map = @{}
        foreach ($property in $Record.PSObject.Properties) {
            $map[$property.Name] = ($property.Value | ConvertTo-Json -Depth 40 -Compress)
        }
        return $map
    }

    # A genuine multi-record v2 registry: real installer-written records (one
    # plain, one managed-native, one engine, one both-clients) with their real
    # history, put back into pre-v3 shape by removing the two fields migration
    # is supposed to add.
    function New-V2RegistryFixture {
        $records = New-Object System.Collections.Generic.List[object]
        foreach ($source in @($nmiHealthyNormal, $nmiHealthyNative, $bothClientsRecord, $engineRecord)) {
            $copy = Copy-Record $source
            $copy.PSObject.Properties.Remove('recordType')
            $copy.PSObject.Properties.Remove('origin')
            [void]$records.Add($copy)
        }
        return [pscustomobject][ordered]@{ version = 2; installs = @($records.ToArray()) }
    }

    $v2Registry = New-V2RegistryFixture
    Check 'setup: the v2 fixture holds several records' (@($v2Registry.installs).Count -eq 4)
    Check 'setup: no v2 fixture record carries recordType yet' (@(@($v2Registry.installs) | Where-Object { $null -ne $_.PSObject.Properties['recordType'] }).Count -eq 0)

    $beforeMaps = @(@($v2Registry.installs) | ForEach-Object { Get-RecordPropertyMap $_ })
    $beforeIds = @(@($v2Registry.installs) | ForEach-Object { [string]$_.id })

    $v3Registry = ConvertTo-InstallRegistryCurrent -Registry $v2Registry

    Check 'migration raises the REGISTRY version to 3' ([int]$v3Registry.version -eq 3)
    Check 'migration keeps every record (none dropped, none invented)' (@($v3Registry.installs).Count -eq 4)

    $migratedRecords = @($v3Registry.installs)
    $allStampedManaged = $true
    $allOriginHookMaker = $true
    $allIdsSurvived = $true
    $allValuesSurvived = $true
    $onlyTwoFieldsAdded = $true
    $allSchemaStillTwo = $true
    for ($m = 0; $m -lt $migratedRecords.Count; $m++) {
        $after = $migratedRecords[$m]
        if ([string]$after.recordType -ne 'managed') { $allStampedManaged = $false }
        if ([string]$after.origin -ne 'hookMaker') { $allOriginHookMaker = $false }
        if ([string]$after.id -ne $beforeIds[$m]) { $allIdsSurvived = $false }
        # A managed record's own shape did not change in v3, so its schema must
        # still read 2 - bumping it would declare every installed record stale.
        if ([int]$after.schema -ne 2) { $allSchemaStillTwo = $false }

        $afterMap = Get-RecordPropertyMap $after
        foreach ($name in @($beforeMaps[$m].Keys)) {
            if (-not $afterMap.ContainsKey($name)) { $allValuesSurvived = $false; continue }
            if ($afterMap[$name] -ne $beforeMaps[$m][$name]) { $allValuesSurvived = $false }
        }
        $added = @(@($afterMap.Keys) | Where-Object { -not $beforeMaps[$m].ContainsKey($_) } | Sort-Object)
        if (($added -join ',') -ne 'origin,recordType') { $onlyTwoFieldsAdded = $false }
    }
    Check 'every migrated record is stamped recordType=managed' $allStampedManaged
    Check 'every migrated record is stamped origin=hookMaker' $allOriginHookMaker
    Check 'migration preserves every record id exactly' $allIdsSurvived
    Check 'migration preserves every other field and value byte-for-byte (history included)' $allValuesSurvived
    Check 'migration adds ONLY recordType and origin' $onlyTwoFieldsAdded
    Check 'a managed record stays schema 2 across migration' $allSchemaStillTwo

    # Deterministic: two independent runs over identical input agree exactly.
    $determinismA = (ConvertTo-InstallRegistryCurrent -Registry (New-V2RegistryFixture)) | ConvertTo-Json -Depth 60
    $determinismB = (ConvertTo-InstallRegistryCurrent -Registry (New-V2RegistryFixture)) | ConvertTo-Json -Depth 60
    Check 'migrating the same v2 registry twice produces identical output' ($determinismA -eq $determinismB)

    # Idempotent: migrating an ALREADY-v3 registry changes nothing at all.
    $idempotentBefore = $v3Registry | ConvertTo-Json -Depth 60
    $idempotentAfter = (ConvertTo-InstallRegistryCurrent -Registry $v3Registry) | ConvertTo-Json -Depth 60
    Check 'migrating an already-v3 registry is a no-op' ($idempotentBefore -eq $idempotentAfter)

    # A migrated record must still satisfy the UNCHANGED managed rules - the
    # regression guard for "do not weaken a single existing managed rule".
    $migratedStillValid = $true
    $migratedReason = ''
    foreach ($migratedRecord in $migratedRecords) {
        $migratedValidation = Test-InstallRecordValid -Record $migratedRecord
        if (-not $migratedValidation.Ok) { $migratedStillValid = $false; $migratedReason = $migratedValidation.Reason }
    }
    Check 'every migrated record still validates under the managed rules' $migratedStillValid $migratedReason

    # A record with NO recordType at all (a registry written before v3, read
    # without going through migration) is still treated as managed.
    $unstampedManaged = Copy-Record $goodRecord
    Check 'a record with no recordType is treated as managed' (Test-IsManagedRecord -Record $unstampedManaged)
    Check 'a record with no recordType is not treated as discovered' (-not (Test-IsDiscoveredRecord -Record $unstampedManaged))
    $unstampedResult = Test-InstallRecordValid -Record $unstampedManaged
    Check 'a record with no recordType still validates exactly as before' $unstampedResult.Ok $unstampedResult.Reason

    $explicitManaged = Copy-Record $goodRecord
    $explicitManaged | Add-Member -MemberType NoteProperty -Name recordType -Value 'managed' -Force
    $explicitManaged | Add-Member -MemberType NoteProperty -Name origin -Value 'hookMaker' -Force
    $explicitManagedResult = Test-InstallRecordValid -Record $explicitManaged
    Check 'an explicitly managed record validates identically' $explicitManagedResult.Ok $explicitManagedResult.Reason

    # A newer-than-supported REGISTRY is still refused rather than partially
    # understood - v3 did not relax that.
    $futureRoot = Join-Path $Work 'future-registry-root'
    New-Item -ItemType Directory -Path (Join-Path $futureRoot 'state') -Force | Out-Null
    $futureRegistryPath = Join-Path $futureRoot 'state\install-registry.json'
    $savedFutureStateDir = $env:HOOKMAKER_STATE_DIR
    $env:HOOKMAKER_STATE_DIR = ''
    try {
        Write-Utf8 $futureRegistryPath '{"version":4,"installs":[{"id":"future","schema":4,"friendlyName":"Future"}]}'
        $futureState = Read-InstallRegistryState -ToolRoot $futureRoot
        Check 'a v4 registry is still rejected as newer than supported' (($futureState.State -eq 'corrupt') -and ($futureState.Reason -match 'newer than this Hook Maker supports')) $futureState.Reason

        Write-Utf8 $futureRegistryPath '{"version":3,"installs":[]}'
        Check 'a v3 registry reads as ok' ((Read-InstallRegistryState -ToolRoot $futureRoot).State -eq 'ok')
    }
    finally { $env:HOOKMAKER_STATE_DIR = $savedFutureStateDir }

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
        $secretOnDisk = [System.IO.File]::ReadAllText((Get-InstallRegistryPath -ToolRoot $secretRoot))
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

}
finally {
    $env:HOOKMAKER_STATE_DIR = $SavedHookMakerStateDir
    if (-not $KeepArtifacts) {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
}

Write-Host ''
Write-Host ("Passed: $script:Pass  Failed: $script:Fail") -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
