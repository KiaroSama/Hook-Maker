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

    $goodRecord = [pscustomobject]@{
        id = 'schema-ok'; schema = 2; friendlyName = 'F'; hookType = 'CustomHook'
        sourceScript = 'C:\src\hook.ps1'; sourceDir = 'C:\src'; scope = 'global'
        clients = [pscustomobject]@{ claude = [pscustomobject]@{ runtimeScript = 'C:\runtime\hook.ps1'; settingsPath = 'C:\s.json'; runtimeRoot = 'C:\runtime'; events = @('Stop') } }
    }

    function Copy-Record { param($R) return ($R | ConvertTo-Json -Depth 20 | ConvertFrom-Json) }

    Check 'a well-formed record validates' ((Test-InstallRecordValid -Record $goodRecord).Ok)

    Check 'a null record is rejected' (-not (Test-InstallRecordValid -Record $null).Ok)

    foreach ($requiredField in @('id', 'friendlyName', 'hookType', 'sourceScript', 'sourceDir', 'scope')) {

        $missingField = Copy-Record $goodRecord

        $missingField.PSObject.Properties.Remove($requiredField)

        Check ("a record missing '" + $requiredField + "' is rejected") (-not (Test-InstallRecordValid -Record $missingField).Ok)

    }

    $missingRuntimeRoot = Copy-Record $goodRecord
    $missingRuntimeRoot.clients.claude.PSObject.Properties.Remove('runtimeRoot')
    Check "a client subrecord missing 'runtimeRoot' is rejected" (-not (Test-InstallRecordValid -Record $missingRuntimeRoot).Ok)

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
    $completeManagedNative | Add-Member -MemberType NoteProperty -Name nativeGit -Value ([pscustomobject]@{ managed = $true; wrapperPath = 'C:\p\pre-push'; runtimeRoot = 'C:\runtime'; companions = @('Secrets-Check') })
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



    # End-to-end: a broken record placed BEFORE a healthy one must not stop the

    # healthy one from being evaluated.

    $isoProj = New-Proj 'IsolationProj'

    & $InstallScript -CustomHook (Join-Path $RealHooksDir 'Ai-Memory-Check\Ai-Memory-Check.ps1') -Events @('Stop') -TargetProject $isoProj -ClaudeOnly *> $null

    $isoRegPath = Join-Path $env:HOOKMAKER_STATE_DIR 'install-registry.json'

    $isoReg = Get-Content -LiteralPath $isoRegPath -Raw | ConvertFrom-Json

    $isoOriginal = [System.IO.File]::ReadAllText($isoRegPath)

    $isoBroken = [pscustomobject]@{ id = 'broken-isolation'; schema = 2; friendlyName = 'Broken-Hook' }

    # A second, independently healthy record (a straight clone of the real one
    # under a different id/friendlyName) alongside THREE differently-malformed
    # records covering the newly-validated Defect 4 field categories, so the
    # mixed batch proves both directions at once: every kind of malformed
    # record is isolated, and BOTH healthy records still evaluate.
    $isoHealthy2 = $isoReg.installs[0] | ConvertTo-Json -Depth 50 | ConvertFrom-Json
    $isoHealthy2.id = 'iso-healthy-clone'
    $isoHealthy2.friendlyName = 'Ai-Memory-Check-Clone'

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



}
finally {
    $env:HOOKMAKER_STATE_DIR = $SavedHookMakerStateDir
    if (-not $KeepArtifacts) {
        try {
            Get-ChildItem -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue |
                ForEach-Object { $_.Attributes = [System.IO.FileAttributes]::Normal }
            Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
        }
        catch { }
    }
}

Write-Host ''
Write-Host ("Passed: $script:Pass  Failed: $script:Fail") -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
