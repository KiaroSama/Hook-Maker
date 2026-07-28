# ---------------------------------------------------------------------------
# Kiro uninstall scenarios, dot-sourced by Test-UninstallHook.ps1 into ITS
# scope: Check, $script:Pass/$script:Fail, $Work, $ToolRoot, New-Proj,
# Get-BytesOrEmpty/Test-BytesEqual, Invoke-UninstallProcess, Get-Registry /
# Get-RecordsFor and Get-ComponentStatus/Reason all resolve in the caller.
#
# Kiro is the 'perHookFile' client: this installation owns its own JSON file
# under <project>\.kiro\hooks rather than a handler entry inside a shared
# settings document. The scenarios below pin the two failure modes that shape
# has and the shared clients do not:
#   1. a file Hook Maker names can still be somebody else's, so ownership is
#      proven from identities INSIDE the entries and never from the filename;
#   2. a file Hook Maker owns can hold hand-added entries, so removal is
#      entry-level and a user's own hook survives the uninstall.
#
# The record is built here rather than by running Install-Hook.ps1, on purpose:
# this suite proves the UNINSTALLER's ownership contract against the persisted
# record shape, independently of whichever install path produced it. Every
# fixture value mirrors what Install-Hook.ps1 writes for a Kiro install (the
# per-entry ' -Trigger <physical>' launcher command included).
# ---------------------------------------------------------------------------

$KiroUtf8NoBom = New-Object System.Text.UTF8Encoding $false

# Builds a complete, realistic Kiro installation on disk plus its registry
# record. Returns everything a scenario needs to assert against.
function New-KiroInstallFixture {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectName,
        [string]$Name = '',
        [string[]]$Events = @('SessionStart', 'PreToolUse'),
        [int]$Timeout = 60
    )
    # One friendly name per fixture: Get-RecordsFor looks records up BY name, so
    # a shared name would have every scenario asserting against whichever
    # fixture happened to be first in the registry.
    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = 'ZZZ-Kiro-' + $ProjectName }
    $project = New-Proj $ProjectName
    $recordId = Get-InstallRecordId -FriendlyName $Name -ScopeKey $project

    $runtimeRoot = Join-Path $project '.kiro\hook-runtime\Hook-Maker'
    $hookDir = Join-Path $runtimeRoot $Name
    New-Item -ItemType Directory -Path $hookDir -Force | Out-Null
    $runtimeScript = Join-Path $hookDir ($Name + '.ps1')
    Write-Utf8 $runtimeScript "exit 0`n"
    Write-Utf8 (Join-Path $hookDir '_hooklib.ps1') "# private copy`n"
    $launcher = Join-Path $hookDir 'kiro-launch.ps1'
    Write-Utf8 $launcher "param([string]`$Trigger = '')`nexit 0`n"

    # The source only has to be a real path the record can name; no scenario
    # here compares source manifests.
    $sourceDir = Join-Path $Work ($ProjectName + '-source')
    New-Item -ItemType Directory -Path $sourceDir -Force | Out-Null
    $sourceScript = Join-Path $sourceDir ($Name + '.ps1')
    Write-Utf8 $sourceScript "exit 0`n"

    $registrationPath = Get-KiroRegistrationPath -Scope 'project' -FriendlyName $Name -StableId $recordId -TargetProjectRoot $project
    New-Item -ItemType Directory -Path (Split-Path -Parent $registrationPath) -Force | Out-Null

    # One entry per trigger, each with its OWN command - exactly how
    # Install-Hook.ps1 builds them, because Kiro cannot tell a hook which event
    # fired unless the trigger is on the command line.
    $baseCommand = '"pwsh" -NoProfile -File "' + $launcher + '"'
    $builtEntries = @()
    $physicalTriggers = @()
    foreach ($logicalEvent in $Events) {
        $document = New-KiroHookDocument -FriendlyName $Name -Command ($baseCommand + ' -Trigger ' + $logicalEvent) `
            -Triggers @($logicalEvent) -TimeoutSeconds $Timeout -ManagedId $recordId
        $builtEntries += @($document.hooks)
        $physicalTriggers += @([pscustomobject]@{ logical = $logicalEvent; physical = $logicalEvent })
    }
    $merged = Merge-KiroManagedEntries -ExistingDocument $null -ManagedEntries @($builtEntries) -ManagedId $recordId
    [System.IO.File]::WriteAllText($registrationPath, (ConvertTo-KiroHookJson $merged.Document), $KiroUtf8NoBom)
    $entryNames = @(@($merged.ManagedEntries) | ForEach-Object { [string]$_.name })

    $subrecords = [pscustomobject][ordered]@{}
    Set-ObjectProperty -Object $subrecords -Name 'kiro' -Value (New-ClientSubrecord `
            -SettingsPath $registrationPath `
            -RuntimeRoot $runtimeRoot `
            -RuntimeScript $runtimeScript `
            -Events @($Events) `
            -Command $baseCommand `
            -HandlerType 'command' `
            -Timeout $Timeout `
            -RegistrationKind 'perHookFile' `
            -RegistrationPath $registrationPath `
            -PhysicalTriggers @($physicalTriggers) `
            -ManagedEntryNames @($entryNames))

    $record = [pscustomobject][ordered]@{
        id                = $recordId
        schema            = 2
        internalName      = $Name
        friendlyName      = $Name
        hookType          = 'CustomHook'
        sourceScript      = $sourceScript
        sourceDir         = $sourceDir
        toolRoot          = $ToolRoot
        scope             = 'project'
        targetProjectRoot = $project
        profile           = ''
        configPath        = ''
        sourceManifest    = @()
        clients           = $subrecords
        nativeGit         = $null
        lastUpdatedUtc    = [DateTime]::UtcNow.ToString('o')
        lastResult        = 'ok'
        lastReason        = 'installed'
        lastError         = ''
        lastComponents    = @()
        needsManualRepair = $false
    }
    $registry = Get-Registry
    Set-InstallRecord -Registry $registry -Record $record
    Save-InstallRegistry -ToolRoot $ToolRoot -Registry $registry

    return [pscustomobject]@{
        Name = $Name; Project = $project; RecordId = $recordId
        RegistrationPath = $registrationPath
        RegistrationDir = (Split-Path -Parent $registrationPath)
        RuntimeRoot = $runtimeRoot; HookDir = $hookDir; RuntimeScript = $runtimeScript
        EntryNames = @($entryNames); Command = $baseCommand
    }
}

# A file that matches the managed FILENAME pattern but whose entries belong to
# a different Hook Maker installation. Nothing about it may ever be touched -
# the filename is a hint, never evidence.
function New-ForeignKiroFile {
    param([Parameter(Mandatory = $true)][string]$Directory, [string]$Leaf = 'hookmaker-someone-elses-hook.json')
    $path = Join-Path $Directory $Leaf
    $document = New-KiroHookDocument -FriendlyName 'Someone Elses Hook' -Command 'pwsh -File "C:\other\hook.ps1"' `
        -Triggers @('SessionStart') -TimeoutSeconds 30 -ManagedId 'a-completely-different-record-id'
    [System.IO.File]::WriteAllText($path, (ConvertTo-KiroHookJson $document), $KiroUtf8NoBom)
    return $path
}

Write-Host ''
Write-Host '--- Kiro (perHookFile) uninstall ---' -ForegroundColor Cyan

# ---- 1. a managed Kiro install comes off cleanly ---------------------------
$k1 = New-KiroInstallFixture -ProjectName 'KiroClean'
$k1Foreign = New-ForeignKiroFile -Directory $k1.RegistrationDir
$k1ForeignBefore = Get-BytesOrEmpty $k1Foreign
# Not the managed filename pattern at all: a hand-written Kiro hook file.
$k1Plain = Join-Path $k1.RegistrationDir 'my-own-hook.json'
Write-Utf8 $k1Plain '{"version":"v1","hooks":[{"name":"mine","trigger":"Stop","action":{"type":"command","command":"echo hi"}}]}'
$k1PlainBefore = Get-BytesOrEmpty $k1Plain

Check 'setup: the managed Kiro file and both bystanders exist' (
    (Test-Path -LiteralPath $k1.RegistrationPath -PathType Leaf) -and
    (Test-Path -LiteralPath $k1Foreign -PathType Leaf) -and
    (Test-Path -LiteralPath $k1Plain -PathType Leaf))

$k1Result = Invoke-UninstallProcess -RecordId $k1.RecordId
Check 'kiro: uninstall reports overall ok' ([string]$k1Result.Result.overall -eq 'ok') ([string]$k1Result.Result.overall)
Check 'kiro: the kiro component reports ok' ((Get-ComponentStatus $k1Result.Result 'kiro') -eq 'ok') ($k1Result.Out + $k1Result.Err)
Check 'kiro: the managed registration file is gone' (-not (Test-Path -LiteralPath $k1.RegistrationPath))
Check 'kiro: the managed runtime directory is gone' (-not (Test-Path -LiteralPath $k1.HookDir))
Check 'kiro: the emptied Hook-Maker runtime root is gone' (-not (Test-Path -LiteralPath $k1.RuntimeRoot))
Check 'kiro: the registry record is removed' ((@(Get-RecordsFor $k1.Name)).Count -eq 0)
Check 'kiro: a FOREIGN hookmaker-*.json beside ours survives byte-identical' (
    (Test-Path -LiteralPath $k1Foreign -PathType Leaf) -and (Test-BytesEqual $k1ForeignBefore (Get-BytesOrEmpty $k1Foreign)))
Check 'kiro: a non-managed .kiro\hooks file survives byte-identical' (
    (Test-Path -LiteralPath $k1Plain -PathType Leaf) -and (Test-BytesEqual $k1PlainBefore (Get-BytesOrEmpty $k1Plain)))
Check 'kiro: the .kiro\hooks directory itself is preserved' (Test-Path -LiteralPath $k1.RegistrationDir -PathType Container)

# A document that was entirely ours is DELETED, so a backup of it is a copy of a
# file this tool wrote and just removed - it restores nothing that reinstalling
# does not. And .kiro\hooks is the directory Kiro SCANS as its configuration: a
# real 24-hook uninstall left 24 dead copies sitting in it, which is what a
# "clean uninstall" must not do. The bystander files are matched by exact name,
# so this counts only backup copies.
Check 'kiro: deleting the document leaves no backup copy behind in .kiro\hooks' (
    @(Get-ChildItem -LiteralPath $k1.RegistrationDir -Filter '*.backup-*' -File -ErrorAction SilentlyContinue).Count -eq 0) (
    (@(Get-ChildItem -LiteralPath $k1.RegistrationDir -Filter '*.backup-*' -File -ErrorAction SilentlyContinue) |
        ForEach-Object { $_.Name }) -join ',')

# ---- 2. a hand-added entry inside OUR file survives ------------------------
# The install side merges around foreign entries (Merge-KiroManagedEntries);
# the uninstall side must be its mirror image or a user's own hook is silently
# deleted with ours.
$k2 = New-KiroInstallFixture -ProjectName 'KiroMixed'
$k2Document = ([System.IO.File]::ReadAllText($k2.RegistrationPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
$k2UserEntry = [pscustomobject][ordered]@{
    name = 'my-own-lint-hook'; description = 'hand added'; trigger = 'PostToolUse'
    action = [pscustomobject][ordered]@{ type = 'command'; command = 'pwsh -File "C:\mine\lint.ps1"' }
    timeout = 45; enabled = $true
}
$k2Document.hooks = @(@($k2Document.hooks) + @($k2UserEntry))
[System.IO.File]::WriteAllText($k2.RegistrationPath, ($k2Document | ConvertTo-Json -Depth 12), $KiroUtf8NoBom)

$k2Result = Invoke-UninstallProcess -RecordId $k2.RecordId
Check 'kiro/mixed: uninstall reports overall ok' ([string]$k2Result.Result.overall -eq 'ok') ([string]$k2Result.Result.overall)
Check 'kiro/mixed: the file is KEPT because a foreign entry remains' (Test-Path -LiteralPath $k2.RegistrationPath -PathType Leaf)
$k2After = $null
if (Test-Path -LiteralPath $k2.RegistrationPath -PathType Leaf) {
    $k2After = ([System.IO.File]::ReadAllText($k2.RegistrationPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
}
Check 'kiro/mixed: only the hand-added entry is left' (
    $null -ne $k2After -and (@($k2After.hooks)).Count -eq 1 -and [string]@($k2After.hooks)[0].name -eq 'my-own-lint-hook') (
    ($k2After | ConvertTo-Json -Depth 12))
Check 'kiro/mixed: the surviving entry keeps its own command and timeout' (
    $null -ne $k2After -and [string]@($k2After.hooks)[0].action.command -eq 'pwsh -File "C:\mine\lint.ps1"' -and
    [int]@($k2After.hooks)[0].timeout -eq 45)
Check 'kiro/mixed: the document is still a v1 document' ($null -ne $k2After -and [string]$k2After.version -eq 'v1')
Check 'kiro/mixed: the runtime still came off' (-not (Test-Path -LiteralPath $k2.HookDir))
Check 'kiro/mixed: the record is removed' ((@(Get-RecordsFor $k2.Name)).Count -eq 0)
# The mirror of the clean case: here the file SURVIVES and now holds the user's
# own entry, which is exactly when a backup is worth keeping.
Check 'kiro/mixed: a document that survives KEEPS its backup' (
    @(Get-ChildItem -LiteralPath $k2.RegistrationDir -Filter ((Split-Path -Leaf $k2.RegistrationPath) + '.backup-*') -File -ErrorAction SilentlyContinue).Count -ge 1) (
    (@(Get-ChildItem -LiteralPath $k2.RegistrationDir -File -ErrorAction SilentlyContinue) | ForEach-Object { $_.Name }) -join ',')

# ---- 3. an entry that appeared since install is NOT removed ----------------
# Same managed identity, but a name this record never recorded: two
# installations wrote the file, or it was hand-edited. Either way ownership of
# the file's entries is no longer provable, so nothing is touched.
$k3 = New-KiroInstallFixture -ProjectName 'KiroDrifted'
$k3Before = Get-BytesOrEmpty $k3.RegistrationPath
$k3Document = ([System.IO.File]::ReadAllText($k3.RegistrationPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
# Carries this record's managed identity (so Test-KiroManagedFile calls it
# ours) but is absent from the record's own managedEntryNames.
$k3Extra = [pscustomobject][ordered]@{
    name = 'hookmaker-' + (ConvertTo-KiroSlug -Text $k3.RecordId) + '-zzz-kiro-hook-unrecorded'
    description = 'appeared after install'; trigger = 'Stop'
    action = [pscustomobject][ordered]@{ type = 'command'; command = 'pwsh -File "C:\mine\other.ps1"' }
    timeout = 60; enabled = $true
}
$k3Document.hooks = @(@($k3Document.hooks) + @($k3Extra))
[System.IO.File]::WriteAllText($k3.RegistrationPath, ($k3Document | ConvertTo-Json -Depth 12), $KiroUtf8NoBom)
$k3AfterEdit = Get-BytesOrEmpty $k3.RegistrationPath

$k3Result = Invoke-UninstallProcess -RecordId $k3.RecordId
Check 'kiro/unrecorded entry: the outcome is manualRepair' ([string]$k3Result.Result.overall -eq 'manualRepair') ([string]$k3Result.Result.overall)
Check 'kiro/unrecorded entry: the kiro component says ambiguousRegistration' (
    (Get-ComponentStatus $k3Result.Result 'kiro') -eq 'manualRepair' -and
    (Get-ComponentReason $k3Result.Result 'kiro') -eq 'ambiguousRegistration') (
    (Get-ComponentStatus $k3Result.Result 'kiro') + '/' + (Get-ComponentReason $k3Result.Result 'kiro'))
Check 'kiro/unrecorded entry: the registration file is byte-identical' (
    (Test-Path -LiteralPath $k3.RegistrationPath -PathType Leaf) -and (Test-BytesEqual $k3AfterEdit (Get-BytesOrEmpty $k3.RegistrationPath)))
Check 'kiro/unrecorded entry: the runtime is untouched' (Test-Path -LiteralPath $k3.RuntimeScript -PathType Leaf)
Check 'kiro/unrecorded entry: the record is RETAINED' ((@(Get-RecordsFor $k3.Name)).Count -eq 1)
Check 'kiro/unrecorded entry: nothing else in the file changed either' (
    (@(([System.IO.File]::ReadAllText($k3.RegistrationPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json).hooks)).Count -eq 3)
Check 'setup control: the drifted file really did differ from the installed one' (-not (Test-BytesEqual $k3Before $k3AfterEdit))

# ---- 4. a registrationPath outside this record's own scope is refused ------
$k4 = New-KiroInstallFixture -ProjectName 'KiroBadPath'
$k4Elsewhere = New-Proj 'KiroBadPathElsewhere'
New-Item -ItemType Directory -Path (Join-Path $k4Elsewhere '.kiro\hooks') -Force | Out-Null
$k4Record = @(Get-RecordsFor $k4.Name)[0]
$k4Record.clients.kiro.registrationPath = (Join-Path $k4Elsewhere '.kiro\hooks\hookmaker-elsewhere-1234.json')
Save-MutatedRecord -Record $k4Record
$k4Before = Get-BytesOrEmpty $k4.RegistrationPath

$k4Result = Invoke-UninstallProcess -RecordId $k4.RecordId
Check 'kiro/foreign path: the outcome is manualRepair' ([string]$k4Result.Result.overall -eq 'manualRepair') ([string]$k4Result.Result.overall)
Check 'kiro/foreign path: the kiro component says identityInvalid' (
    (Get-ComponentReason $k4Result.Result 'kiro') -eq 'identityInvalid') ((Get-ComponentReason $k4Result.Result 'kiro'))
Check 'kiro/foreign path: the real registration file is untouched' (
    (Test-Path -LiteralPath $k4.RegistrationPath -PathType Leaf) -and (Test-BytesEqual $k4Before (Get-BytesOrEmpty $k4.RegistrationPath)))
Check 'kiro/foreign path: the runtime is untouched' (Test-Path -LiteralPath $k4.RuntimeScript -PathType Leaf)
Check 'kiro/foreign path: the record is RETAINED' ((@(Get-RecordsFor $k4.Name)).Count -eq 1)

# ---- 5. -WhatIf changes nothing -------------------------------------------
$k5 = New-KiroInstallFixture -ProjectName 'KiroWhatIf'
$k5Before = Get-BytesOrEmpty $k5.RegistrationPath
$k5Result = Invoke-UninstallProcess -RecordId $k5.RecordId -WhatIf
Check 'kiro/whatif: reports ok without changing anything' ([string]$k5Result.Result.overall -eq 'ok') ([string]$k5Result.Result.overall)
Check 'kiro/whatif: the kiro component reports wouldRemove' ((Get-ComponentReason $k5Result.Result 'kiro') -eq 'wouldRemove') ((Get-ComponentReason $k5Result.Result 'kiro'))
Check 'kiro/whatif: the registration file is byte-identical' (
    (Test-Path -LiteralPath $k5.RegistrationPath -PathType Leaf) -and (Test-BytesEqual $k5Before (Get-BytesOrEmpty $k5.RegistrationPath)))
Check 'kiro/whatif: the runtime survives' (Test-Path -LiteralPath $k5.RuntimeScript -PathType Leaf)
Check 'kiro/whatif: the record survives' ((@(Get-RecordsFor $k5.Name)).Count -eq 1)

# ---- 6. an already-removed registration is idempotent success -------------
$k6 = New-KiroInstallFixture -ProjectName 'KiroAlreadyGone'
Remove-Item -LiteralPath $k6.RegistrationPath -Force
$k6Result = Invoke-UninstallProcess -RecordId $k6.RecordId
Check 'kiro/idempotent: a missing registration file is still a clean uninstall' ([string]$k6Result.Result.overall -eq 'ok') ([string]$k6Result.Result.overall)
Check 'kiro/idempotent: the runtime is removed' (-not (Test-Path -LiteralPath $k6.HookDir))
Check 'kiro/idempotent: the record is removed' ((@(Get-RecordsFor $k6.Name)).Count -eq 0)

# ---- 7. a record with no kiro subrecord is unaffected ----------------------
# The regression guard for the two shared clients: adding the Kiro component
# must report 'skipped/notInstalled' for every pre-existing record rather than
# inventing work or failing.
$k7Project = New-Proj 'KiroAbsent'
$k7Hook = Join-Path $Work 'KiroAbsent-source\ZZZ-Kiro-Absent.ps1'
New-Item -ItemType Directory -Path (Split-Path -Parent $k7Hook) -Force | Out-Null
Write-Utf8 $k7Hook "exit 0`n"
& $InstallScript -CustomHook $k7Hook -Events @('SessionStart') -TargetProject $k7Project -ClaudeOnly *> $null
$k7Record = @(Get-RecordsFor 'ZZZ-Kiro-Absent')[0]
Check 'setup: a Claude-only install was tracked' ($null -ne $k7Record)
if ($null -ne $k7Record) {
    $k7Result = Invoke-UninstallProcess -RecordId ([string]$k7Record.id)
    Check 'kiro/absent: a Claude-only record still uninstalls cleanly' ([string]$k7Result.Result.overall -eq 'ok') ([string]$k7Result.Result.overall)
    Check 'kiro/absent: the kiro component is skipped as notInstalled' (
        (Get-ComponentStatus $k7Result.Result 'kiro') -eq 'skipped' -and
        (Get-ComponentReason $k7Result.Result 'kiro') -eq 'notInstalled') (
        (Get-ComponentStatus $k7Result.Result 'kiro') + '/' + (Get-ComponentReason $k7Result.Result 'kiro'))
    Check 'kiro/absent: the claude component still came off' ((Get-ComponentStatus $k7Result.Result 'claude') -eq 'ok')
    Check 'kiro/absent: the record is removed' ((@(Get-RecordsFor 'ZZZ-Kiro-Absent')).Count -eq 0)
}
