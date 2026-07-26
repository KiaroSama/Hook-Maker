# ---------------------------------------------------------------------------
# "Update previously installed hooks" for the Kiro (perHookFile) client.
# Dot-sourced by Test-InstallRegistry.ps1 into ITS scope: Check, the $script:
# counters, $Work, $ToolRoot, New-Proj, Write-Utf8, New-FixtureHook,
# Get-Registry/Get-RecordsFor and the isolated state dir all resolve there.
#
# Two things have to hold before an update run can be trusted for Kiro:
#   1. the client must be ENUMERATED at all - a client missing from
#      Get-InstalledClientNames is a client the updater can never repair;
#   2. drift must be judged by a check that understands a Kiro document.
#      Pointing the shared-settings check at one would report "registration
#      missing" every single time (its hooks are an ARRAY, not an object keyed
#      by event), so the hook would be reinstalled on every run for ever -
#      drift detection that always says "drifted" is the same as none.
# ---------------------------------------------------------------------------

$KiroRegUtf8 = New-Object System.Text.UTF8Encoding $false
$KiroRegName = 'ZZZ-Regtest-Kiro'

Write-Host ''
Write-Host '--- Kiro: client enumeration, registration drift, update wiring ---' -ForegroundColor Cyan

# Writes one managed Kiro document exactly as Install-Hook.ps1 builds it: one
# entry per trigger, each carrying its OWN ' -Trigger <physical>' command,
# because Kiro cannot tell a hook which event fired unless it is on the
# command line.
function New-KiroDocumentOnDisk {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ManagedId,
        [Parameter(Mandatory = $true)][string]$BaseCommand,
        [Parameter(Mandatory = $true)][string[]]$Triggers,
        [int]$Timeout = 60
    )
    $built = @()
    foreach ($logicalEvent in $Triggers) {
        $document = New-KiroHookDocument -FriendlyName $Name -Command ($BaseCommand + ' -Trigger ' + $logicalEvent) `
            -Triggers @($logicalEvent) -TimeoutSeconds $Timeout -ManagedId $ManagedId
        $built += @($document.hooks)
    }
    $merged = Merge-KiroManagedEntries -ExistingDocument $null -ManagedEntries @($built) -ManagedId $ManagedId
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [System.IO.File]::WriteAllText($Path, (ConvertTo-KiroHookJson $merged.Document), $KiroRegUtf8)
    return @(@($merged.ManagedEntries) | ForEach-Object { [string]$_.name })
}
function Read-KiroDocument {
    param([string]$Path)
    return ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
}
function Write-KiroDocument {
    param([string]$Path, $Document)
    [System.IO.File]::WriteAllText($Path, ($Document | ConvertTo-Json -Depth 12), $KiroRegUtf8)
}

# ---- registration drift matrix (unit level) --------------------------------
$kdProject = New-Proj 'KiroDrift'
$kdDir = Join-Path $kdProject '.kiro\hooks'
$kdManagedId = 'abc123def456'
$kdCommand = '"pwsh" -NoProfile -File "' + (Join-Path $kdProject '.kiro\hook-runtime\Hook-Maker\' + $KiroRegName + '\kiro-launch.ps1') + '"'
$kdPath = Join-Path $kdDir ('hookmaker-' + (ConvertTo-KiroSlug -Text $KiroRegName) + '-' + $kdManagedId + '.json')
$kdEvents = @('SessionStart', 'PreToolUse')
$kdNames = @(New-KiroDocumentOnDisk -Path $kdPath -Name $KiroRegName -ManagedId $kdManagedId -BaseCommand $kdCommand -Triggers $kdEvents)
$kdTriggers = @(@($kdEvents) | ForEach-Object { [pscustomobject]@{ logical = $_; physical = $_ } })
$kdPristine = [System.IO.File]::ReadAllText($kdPath, [System.Text.Encoding]::UTF8)

function Test-KiroDrift {
    param([string[]]$EntryNames = $null, $Triggers = $null, [string]$Command = '', [int]$Timeout = 60, [bool]$Enabled = $true)
    if ($null -eq $EntryNames) { $EntryNames = $kdNames }
    if ($null -eq $Triggers) { $Triggers = $kdTriggers }
    if ($Command -eq '') { $Command = $kdCommand }
    return (Test-KiroRegistrationState -RegistrationDirectory $kdDir -ManagedId $kdManagedId `
            -ExpectedEntryNames @($EntryNames) -ExpectedEvents @($kdEvents) -PhysicalTriggers $Triggers `
            -ExpectedCommand $Command -ExpectedTimeout $Timeout -ExpectedEnabled $Enabled)
}
function Reset-KiroDrift { [System.IO.File]::WriteAllText($kdPath, $kdPristine, $KiroRegUtf8) }

Check 'kiro drift: setup wrote two managed entries' ($kdNames.Count -eq 2) (($kdNames -join ','))
Check 'kiro drift: an untouched installation is current' ((Test-KiroDrift).Reason -eq 'current') ((Test-KiroDrift).Reason + '/' + (Test-KiroDrift).Detail)

# The fallback path: a record written without physicalTriggers derives them
# from the canonical capability table instead of reporting false drift.
Check 'kiro drift: no persisted physicalTriggers still resolves to current' ((Test-KiroDrift -Triggers @()).Reason -eq 'current') ((Test-KiroDrift -Triggers @()).Detail)

# A file whose entries belong to somebody else is not this installation's.
$kdForeignId = Test-KiroRegistrationState -RegistrationDirectory $kdDir -ManagedId 'some-other-record' `
    -ExpectedEntryNames $kdNames -ExpectedEvents $kdEvents -PhysicalTriggers $kdTriggers -ExpectedCommand $kdCommand
Check 'kiro drift: another record''s managed id finds no registration of its own' ($kdForeignId.Reason -eq 'registration missing') ($kdForeignId.Detail)

# A hand-added user entry in OUR file is ignored, not reported as stale.
$kdMixed = Read-KiroDocument $kdPath
$kdMixed.hooks = @(@($kdMixed.hooks) + @([pscustomobject][ordered]@{
    name = 'my-own-hook'; trigger = 'Stop'
    action = [pscustomobject][ordered]@{ type = 'command'; command = 'echo hi' }; timeout = 30; enabled = $true }))
Write-KiroDocument -Path $kdPath -Document $kdMixed
Check 'kiro drift: a foreign entry inside our own file is ignored' ((Test-KiroDrift).Reason -eq 'current') ((Test-KiroDrift).Detail)
Reset-KiroDrift

# ---- each owned field, one at a time --------------------------------------
$kdMissing = Test-KiroDrift -EntryNames @($kdNames + @('hookmaker-' + $kdManagedId + '-never-written'))
Check 'kiro drift: an expected entry that is not registered is "registration missing"' ($kdMissing.Reason -eq 'registration missing') ($kdMissing.Detail)

$kdStale = Test-KiroDrift -EntryNames @($kdNames[0])
Check 'kiro drift: an entry we own but no longer expect is "stale registration"' ($kdStale.Reason -eq 'stale registration') ($kdStale.Detail)

$kdDoc = Read-KiroDocument $kdPath
@($kdDoc.hooks)[0].timeout = 999
Write-KiroDocument -Path $kdPath -Document $kdDoc
$kdTimeout = Test-KiroDrift
Check 'kiro drift: a changed timeout is drift' ($kdTimeout.Reason -eq 'registration drifted' -and $kdTimeout.Detail -like 'timeout changed*') ($kdTimeout.Detail)
Reset-KiroDrift

$kdDoc = Read-KiroDocument $kdPath
@($kdDoc.hooks)[0].enabled = $false
Write-KiroDocument -Path $kdPath -Document $kdDoc
$kdDisabled = Test-KiroDrift
Check 'kiro drift: a disabled entry is drift' ($kdDisabled.Reason -eq 'registration drifted' -and $kdDisabled.Detail -like 'enabled changed*') ($kdDisabled.Detail)
Reset-KiroDrift

$kdDoc = Read-KiroDocument $kdPath
@($kdDoc.hooks)[0].action.command = 'pwsh -File "C:\somewhere\else.ps1" -Trigger SessionStart'
Write-KiroDocument -Path $kdPath -Document $kdDoc
$kdCommandDrift = Test-KiroDrift
Check 'kiro drift: a command pointing somewhere else is drift' ($kdCommandDrift.Reason -eq 'registration drifted' -and $kdCommandDrift.Detail -like 'command changed*') ($kdCommandDrift.Detail)
Reset-KiroDrift

# The launcher argument is what tells the hook which event fired, so an entry
# whose trigger and -Trigger argument disagree is a live registration that
# looks healthy and behaves wrongly.
$kdDoc = Read-KiroDocument $kdPath
$kdSessionEntry = @(@($kdDoc.hooks) | Where-Object { [string]$_.trigger -eq 'SessionStart' })[0]
$kdSessionEntry.action.command = $kdCommand + ' -Trigger PreToolUse'
Write-KiroDocument -Path $kdPath -Document $kdDoc
$kdTriggerArg = Test-KiroDrift
Check 'kiro drift: a -Trigger argument that no longer matches the entry is drift' (
    $kdTriggerArg.Reason -eq 'registration drifted' -and $kdTriggerArg.Detail -like 'trigger argument changed*') ($kdTriggerArg.Detail)
Reset-KiroDrift

$kdDoc = Read-KiroDocument $kdPath
@($kdDoc.hooks)[0].trigger = 'PostToolUse'
Write-KiroDocument -Path $kdPath -Document $kdDoc
$kdTriggerDrift = Test-KiroDrift
Check 'kiro drift: a changed trigger is drift' ($kdTriggerDrift.Reason -eq 'registration drifted' -and $kdTriggerDrift.Detail -like 'trigger changed*') ($kdTriggerDrift.Detail)
Reset-KiroDrift

$kdDoc = Read-KiroDocument $kdPath
@($kdDoc.hooks)[0].action.type = 'agent'
Write-KiroDocument -Path $kdPath -Document $kdDoc
$kdActionDrift = Test-KiroDrift
Check 'kiro drift: an agent action (which spawns no process) is drift' (
    $kdActionDrift.Reason -eq 'registration drifted' -and $kdActionDrift.Detail -like 'action type changed*') ($kdActionDrift.Detail)
Reset-KiroDrift

# A matcher Kiro never evaluates on this trigger must not appear on our entry.
$kdDoc = Read-KiroDocument $kdPath
$kdSessionEntry = @(@($kdDoc.hooks) | Where-Object { [string]$_.trigger -eq 'SessionStart' })[0]
Add-Member -InputObject $kdSessionEntry -MemberType NoteProperty -Name 'matcher' -Value 'startup|resume' -Force
Write-KiroDocument -Path $kdPath -Document $kdDoc
$kdMatcherDrift = Test-KiroDrift
Check 'kiro drift: a matcher added to an entry is drift' ($kdMatcherDrift.Reason -eq 'registration drifted' -and $kdMatcherDrift.Detail -like 'matcher changed*') ($kdMatcherDrift.Detail)
Reset-KiroDrift

# Two files claiming the same identity fire the hook twice.
$kdSecond = Join-Path $kdDir ('hookmaker-' + (ConvertTo-KiroSlug -Text $KiroRegName) + '-copy.json')
[System.IO.File]::WriteAllText($kdSecond, $kdPristine, $KiroRegUtf8)
$kdDuplicateFile = Test-KiroDrift
Check 'kiro drift: two files carrying our identity are a duplicate registration' ($kdDuplicateFile.Reason -eq 'duplicate registration') ($kdDuplicateFile.Detail)
Remove-Item -LiteralPath $kdSecond -Force

# Two entries with the same name inside one file, likewise.
$kdDoc = Read-KiroDocument $kdPath
$kdDoc.hooks = @(@($kdDoc.hooks) + @(@($kdDoc.hooks)[0]))
Write-KiroDocument -Path $kdPath -Document $kdDoc
$kdDuplicateEntry = Test-KiroDrift
Check 'kiro drift: the same entry registered twice is a duplicate registration' ($kdDuplicateEntry.Reason -eq 'duplicate registration') ($kdDuplicateEntry.Detail)
Reset-KiroDrift

Remove-Item -LiteralPath $kdPath -Force
$kdGone = Test-KiroDrift
Check 'kiro drift: a deleted registration file is "registration missing"' ($kdGone.Reason -eq 'registration missing') ($kdGone.Detail)
$kdNoDir = Test-KiroRegistrationState -RegistrationDirectory (Join-Path $kdProject 'no-such-dir') -ManagedId $kdManagedId `
    -ExpectedEntryNames $kdNames -ExpectedEvents $kdEvents -PhysicalTriggers $kdTriggers -ExpectedCommand $kdCommand
Check 'kiro drift: a missing .kiro hooks directory is "registration missing"' ($kdNoDir.Reason -eq 'registration missing') ($kdNoDir.Detail)

# ---- integrity wiring: the updater's own decision --------------------------
# The runtime is materialised from the REAL install plan so the source and
# installed manifests match; only then does evaluation reach the registration
# check at all. NOTE: a real Kiro install also writes a generated
# kiro-launch.ps1 into this directory, which the plan does not yet describe -
# see the report accompanying this change.
$kiHook = New-FixtureHook $KiroRegName "exit 0`n"
try {
    $kiProject = New-Proj 'KiroIntegrity'
    $kiRuntimeRoot = Join-Path $kiProject '.kiro\hook-runtime\Hook-Maker'
    $kiPlan = Get-InstallPlanFor -HookScript $kiHook -ToolRoot $ToolRoot -FriendlyNameOverride $KiroRegName
    Install-PlannedRuntime -Plan $kiPlan -RuntimeRoot $kiRuntimeRoot -FriendlyName $KiroRegName | Out-Null
    $kiRuntimeScript = Join-Path (Join-Path $kiRuntimeRoot $KiroRegName) ($KiroRegName + '.ps1')
    $kiRecordId = Get-InstallRecordId -FriendlyName $KiroRegName -ScopeKey $kiProject
    $kiCommand = '"pwsh" -NoProfile -File "' + (Join-Path (Join-Path $kiRuntimeRoot $KiroRegName) 'kiro-launch.ps1') + '"'
    $kiPath = Get-KiroRegistrationPath -Scope 'project' -FriendlyName $KiroRegName -StableId $kiRecordId -TargetProjectRoot $kiProject
    $kiNames = @(New-KiroDocumentOnDisk -Path $kiPath -Name $KiroRegName -ManagedId $kiRecordId -BaseCommand $kiCommand -Triggers @('SessionStart'))

    $kiClients = [pscustomobject][ordered]@{}
    Set-ObjectProperty -Object $kiClients -Name 'kiro' -Value (New-ClientSubrecord `
            -SettingsPath $kiPath -RuntimeRoot $kiRuntimeRoot -RuntimeScript $kiRuntimeScript `
            -Events @('SessionStart') -Command $kiCommand -Timeout 60 `
            -RegistrationKind 'perHookFile' -RegistrationPath $kiPath `
            -PhysicalTriggers @([pscustomobject]@{ logical = 'SessionStart'; physical = 'SessionStart' }) `
            -ManagedEntryNames @($kiNames) `
            -InstalledManifest @(Get-InstalledManifest -RuntimeRoot $kiRuntimeRoot -FriendlyName $KiroRegName))
    $kiRecord = [pscustomobject][ordered]@{
        id = $kiRecordId; schema = 2; internalName = $KiroRegName; friendlyName = $KiroRegName
        hookType = 'CustomHook'; sourceScript = $kiHook; sourceDir = (Split-Path -Parent $kiHook)
        toolRoot = $ToolRoot; scope = 'project'; targetProjectRoot = $kiProject; profile = ''; configPath = ''
        sourceManifest = @(Get-ManagedSourceManifest -ToolRoot $ToolRoot -HookScript $kiHook `
                -SourceDir (Split-Path -Parent $kiHook) -FriendlyName $KiroRegName)
        clients = $kiClients; nativeGit = $null
        lastUpdatedUtc = [DateTime]::UtcNow.ToString('o'); lastResult = 'ok'; lastReason = 'installed'; lastError = ''
        lastComponents = @(); needsManualRepair = $false
    }
    $kiRegistry = Get-Registry
    Set-InstallRecord -Registry $kiRegistry -Record $kiRecord
    Save-InstallRegistry -ToolRoot $ToolRoot -Registry $kiRegistry
    $kiStored = @(Get-RecordsFor $KiroRegName)[0]

    Check 'kiro update: the record is valid for the shared validator' ((Test-InstallRecordValid -Record $kiStored).Ok) (
        (Test-InstallRecordValid -Record $kiStored).Reason)
    Check 'kiro update: Get-InstalledClientNames enumerates kiro' ((@(Get-InstalledClientNames -Record $kiStored) -join ',') -eq 'kiro') (
        (@(Get-InstalledClientNames -Record $kiStored) -join ','))
    Check 'kiro update: the registration directory is derived from the record''s own scope' (
        [string]::Equals((Get-KiroRecordRegistrationDirectory -Record $kiStored), (Join-Path $kiProject '.kiro\hooks'), [System.StringComparison]::OrdinalIgnoreCase)) (
        (Get-KiroRecordRegistrationDirectory -Record $kiStored))

    $kiIntegrity = Get-InstallIntegrity -Record $kiStored -ToolRoot $ToolRoot
    Check 'kiro update: an intact Kiro install evaluates as current (no permanent update loop)' (
        $kiIntegrity.Status -eq 'current') ($kiIntegrity.Status + ': ' + $kiIntegrity.Detail)
    Check 'kiro update: the kiro component itself is current' (
        (@(@($kiIntegrity.Components) | Where-Object { $_.Name -eq 'kiro' })).Count -eq 1 -and
        [string](@(@($kiIntegrity.Components) | Where-Object { $_.Name -eq 'kiro' })[0].Status) -eq 'current') (
        (@($kiIntegrity.Components) | ForEach-Object { $_.Name + '=' + $_.Status }) -join ',')

    # A second evaluation with the registration damaged must ask for a repair
    # of KIRO specifically - not of the whole record, and not of another client.
    $kiDoc = Read-KiroDocument $kiPath
    @($kiDoc.hooks)[0].timeout = 5
    Write-KiroDocument -Path $kiPath -Document $kiDoc
    $kiDamaged = Get-InstallIntegrity -Record $kiStored -ToolRoot $ToolRoot
    Check 'kiro update: a drifted Kiro registration is reported as update' ($kiDamaged.Status -eq 'update') ($kiDamaged.Status + ': ' + $kiDamaged.Detail)
    Check 'kiro update: the damaged component is named kiro' ($kiDamaged.Detail -like 'kiro:*') ($kiDamaged.Detail)

    # Repairing it must reinstall kiro and nothing else: the updater's own
    # apply loop names the client positively.
    $kiFlows = [System.IO.File]::ReadAllText((Join-Path $ScriptRoot 'Setup-SyncGroupInstallFlows.ps1'), [System.Text.Encoding]::UTF8)
    Check 'kiro update: the repair loop passes the POSITIVE -Clients set' ($kiFlows -match '\$clientArgs\s*=\s*@\{\s*Clients\s*=\s*@\(\$client\)\s*\}') $kiFlows
    Check 'kiro update: the repair loop no longer falls back to CodexOnly' (
        $kiFlows -notmatch '\$clientArgs\s*=\s*if\s*\(') $kiFlows
}
finally {
    Remove-FixtureHook $KiroRegName
}

# ---- the shared clients are unchanged --------------------------------------
$kcProject = New-Proj 'KiroClientNames'
$kcHook = New-FixtureHook 'ZZZ-Regtest-Kirocn' "exit 0`n"
try {
    & $InstallScript -CustomHook $kcHook -Events @('SessionStart') -TargetProject $kcProject *> $null
    $kcRecord = @(Get-RecordsFor 'ZZZ-Regtest-Kirocn')[0]
    Check 'kiro update: a Claude+Codex record still enumerates exactly claude,codex' (
        $null -ne $kcRecord -and ((@(Get-InstalledClientNames -Record $kcRecord) | Sort-Object) -join ',') -eq 'claude,codex') (
        (@(Get-InstalledClientNames -Record $kcRecord) -join ','))
    Check 'kiro update: a Claude+Codex record is still evaluated as current' (
        $null -ne $kcRecord -and (Get-InstallIntegrity -Record $kcRecord -ToolRoot $ToolRoot).Status -eq 'current') (
        (Get-InstallIntegrity -Record $kcRecord -ToolRoot $ToolRoot).Detail)
}
finally {
    Remove-FixtureHook 'ZZZ-Regtest-Kirocn'
}

# ---- an untouched client's subrecord survives a reinstall ------------------
# The record id is hash(friendlyName|scope|profile) - it does NOT depend on the
# client set - so installing the same hook again for claude alone lands on the
# SAME record. Set-InstallRecord carries forward the subrecords that invocation
# did not touch; a client missing from that carry-forward loop loses its
# registrationPath and managedEntryNames, which are the only ownership proof
# uninstall has, leaving the .kiro\hooks entry and its runtime as orphans
# nothing can ever remove.
$kkName = 'ZZZ-Regtest-Kirokeep'
$kkHook = New-FixtureHook $kkName "exit 0`n"
try {
    $kkProject = New-Proj 'KiroKeep'
    & $InstallScript -CustomHook $kkHook -Events @('SessionStart') -TargetProject $kkProject -Clients kiro *> $null
    $kkBefore = @(Get-RecordsFor $kkName)[0]
    $kkKiroBefore = if ($null -ne $kkBefore) { Get-ClientSubrecord -Record $kkBefore -Client 'kiro' } else { $null }
    $kkBeforeDetail = if ($null -eq $kkBefore) { '<no record>' } else { (@(Get-InstalledClientNames -Record $kkBefore) -join ',') }
    Check 'kiro carry-forward: the kiro-only install recorded a kiro subrecord' ($null -ne $kkKiroBefore) ($kkBeforeDetail)

    if ($null -ne $kkKiroBefore) {
        $kkPathBefore = [string]$kkKiroBefore.registrationPath
        $kkNamesBefore = @($kkKiroBefore.managedEntryNames)
        # Same friendly name, same project, same (empty) profile => same record id.
        & $InstallScript -CustomHook $kkHook -Events @('SessionStart') -TargetProject $kkProject -Clients claude *> $null
        $kkAfter = @(Get-RecordsFor $kkName)[0]
        Check 'kiro carry-forward: the claude reinstall reused the one record' (
            @(Get-RecordsFor $kkName).Count -eq 1 -and [string]$kkAfter.id -eq [string]$kkBefore.id) (
            @(Get-RecordsFor $kkName).Count.ToString() + ' record(s)')
        Check 'kiro carry-forward: claude was actually installed by the second run' (
            $null -ne (Get-ClientSubrecord -Record $kkAfter -Client 'claude')) (
            (@(Get-InstalledClientNames -Record $kkAfter) -join ','))

        $kkKiroAfter = Get-ClientSubrecord -Record $kkAfter -Client 'kiro'
        Check 'kiro carry-forward: a claude-only reinstall does NOT drop the kiro subrecord' (
            $null -ne $kkKiroAfter) ((@(Get-InstalledClientNames -Record $kkAfter) -join ','))
        if ($null -ne $kkKiroAfter) {
            # The two fields uninstall needs to find and prune the .kiro\hooks
            # entry. A surviving-but-hollow subrecord is the same orphan.
            Check 'kiro carry-forward: the surviving subrecord keeps its registrationPath' (
                [string]$kkKiroAfter.registrationPath -eq $kkPathBefore -and $kkPathBefore -ne '') (
                '"' + [string]$kkKiroAfter.registrationPath + '" vs "' + $kkPathBefore + '"')
            Check 'kiro carry-forward: the surviving subrecord keeps its managedEntryNames' (
                @($kkNamesBefore).Count -gt 0 -and
                ((@($kkKiroAfter.managedEntryNames) -join ',') -eq (@($kkNamesBefore) -join ','))) (
                '"' + (@($kkKiroAfter.managedEntryNames) -join ',') + '" vs "' + (@($kkNamesBefore) -join ',') + '"')
            # The registration it names must still be on disk and still ours.
            Check 'kiro carry-forward: the registration the record names still exists' (
                $kkPathBefore -ne '' -and (Test-Path -LiteralPath $kkPathBefore -PathType Leaf)) ($kkPathBefore)
        }
    }
}
finally {
    Remove-FixtureHook $kkName
}
