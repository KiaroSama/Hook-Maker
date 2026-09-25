# ---------------------------------------------------------------------------
# Installed-runtime diagnostics and the versioned migration of RETIRED DEFAULT
# event bindings (36.md F11).
#
# THE DEFECT THIS EXISTS FOR. "Update previously installed hooks" reuses each
# record's per-client `events` verbatim, by design - a union across clients
# would force one client's semantics onto another (LESSON_INSTALL.md). The
# consequence is that a hook whose RECOMMENDED events later changed keeps
# receiving new code under its OLD registration for ever. There is no error and
# no output: the new script is installed and then never triggered, because the
# only event it is bound to is one it no longer answers on.
#
# The worked example is Session-Summary-Check, whose shipped default has had
# three spellings: @('Stop','SubagentStop') (v1 below), then
# @('SessionStart','UserPromptSubmit') (v2), and now all four events. A v1
# binding never receives the pre-task instruction; a v2 binding never runs the
# silent Stop/SubagentStop summary observer. Both fail with no error and no
# output. (This says nothing about any particular machine's INSTALLED copy,
# which is not inspectable from here.)
#
# TWO CAPABILITIES, DELIBERATELY SEPARATE:
#
#   1. Get-EffectiveRegistrationDiagnostic - READ-ONLY. Reports, for one
#      record: recorded vs current SOURCE hashes, recorded vs on-disk INSTALLED
#      hashes, the registered command, the events actually ACTIVE in each
#      client's settings file, and other records naming the same hook in
#      another scope. It mutates nothing, executes nothing, and dot-sources
#      nothing it finds. Anything it could not read is reported as PARTIAL
#      coverage - never as an all-clear.
#
#   2. Get-InstalledEventMigrationPlan / Invoke-InstalledEventMigration - the
#      versioned migration. It moves ONLY a binding that is demonstrably a
#      managed historical default (exact set equality against the table below,
#      plus the proof in Test-EventMigrationPrecondition). A custom binding, a
#      hand-edited one and a foreign handler are REPORTED, never rewritten, and
#      no settings key is ever deleted here: the reinstall the migration drives
#      removes only handlers whose ownership Install-Hook.ps1 has proved.
#
# Load-order contract: this file is dot-sourced from the END of
# _installvalidate.ps1, which _installlib.ps1 loads - so every consumer keeps
# dot-sourcing only _installlib.ps1. Everything it calls resolves at CALL time
# in that one shared script scope:
#   Get-ClientSubrecord, Get-InstalledClientNames, Test-IsManagedRecord
#                                          (_installregistry.ps1)
#   Test-InstallRecordValid                (_installvalidate.ps1)
#   Get-InstalledManifest, Compare-Manifest, Get-ManagedSourceManifest
#                                          (_installlibmanifest.ps1)
#   Get-HookRegistrations                  (_installlibregistration.ps1)
#   Test-PathContainedIn                   (_installplan.ps1)
#   Resolve-HookMakerEventPlan             (_clientcapability.ps1)
#   Read-JsonFile                          (hooks\_hooklib.ps1)
#
# Two functions are resolved OPTIONALLY, because they exist only in the wizard
# (Setup-SyncGroup.ps1) and not in Install-Hook.ps1 or Get-HookStatus.ps1:
#   Get-HookRecommendedEvents - the CANONICAL current default event set. This
#       file deliberately holds no second copy of it; the project's most
#       repeated defect is two sites deriving one value differently. Where it
#       is absent the destination is UNKNOWN and every migration is refused,
#       which is the safe direction.
#   Invoke-HookInstaller - the one structured-result install path
#       (_installinvoke.ps1). Absent means the migration cannot be applied and
#       says so, rather than shelling out by some second route.
# ---------------------------------------------------------------------------

# ---- the versioned migration table ----------------------------------------
#
# One entry per RETIRED DEFAULT binding. `From` is matched as an exact set
# (case-insensitive, order-insensitive) against a client's recorded events; a
# record that matches nothing here is left alone. There is no `To`: the
# destination is always whatever Get-HookRecommendedEvents reports right now,
# so this table can never disagree with the shipped default.
#
# Version is the migration id and is unique. It is reported and logged so a run
# can be named ("event-binding migration v1"), and so a future retirement of a
# different set for the same hook is a NEW entry rather than an edit to this
# one - an edited entry would silently reclassify installs it already moved.
#
# Adding an entry requires evidence that the `From` set really was a SHIPPED
# DEFAULT, not merely a plausible one: a set a user chose by hand is a custom
# binding and must stay in the "report, do not rewrite" path.
$script:InstalledEventMigrations = @(
    [pscustomobject]@{
        Version = 1
        Hook    = 'Session-Summary-Check'
        From    = @('Stop', 'SubagentStop')
        Reason  = 'the retired closing-only default; it never delivers the pre-task summary requirement'
    }
    [pscustomobject]@{
        Version = 2
        Hook    = 'Session-Summary-Check'
        From    = @('SessionStart', 'UserPromptSubmit')
        Reason  = 'the prior shipped default delivered policy but never invoked the silent publication observer'
    }
)

# Case-insensitive, order-insensitive set equality over event names. Duplicates
# collapse, so @('Stop','Stop') equals @('Stop') - a duplicated entry is a
# malformed record, not a different binding.
function Test-EventSetEqual {
    param($Left, $Right)
    $leftSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in @($Left)) {
        if ($null -eq $item) { continue }
        $text = ([string]$item).Trim()
        if ($text -ne '') { [void]$leftSet.Add($text) }
    }
    $rightSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in @($Right)) {
        if ($null -eq $item) { continue }
        $text = ([string]$item).Trim()
        if ($text -ne '') { [void]$rightSet.Add($text) }
    }
    if ($leftSet.Count -ne $rightSet.Count) { return $false }
    foreach ($item in $leftSet) { if (-not $rightSet.Contains($item)) { return $false } }
    return $true
}

# The hook's own name (the source folder / menu name), which is what the
# migration table and Get-HookRecommendedEvents are keyed by. `internalName` is
# the recorded value; the two fallbacks cover records written before it existed.
function Get-RecordHookName {
    param($Record)
    if ($null -eq $Record) { return '' }
    foreach ($field in @('internalName', 'friendlyName')) {
        if ($null -ne $Record.PSObject.Properties[$field]) {
            $value = [string]$Record.$field
            if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
        }
    }
    if ($null -ne $Record.PSObject.Properties['sourceDir']) {
        $dir = [string]$Record.sourceDir
        if (-not [string]::IsNullOrWhiteSpace($dir)) { return (Split-Path -Leaf $dir) }
    }
    return ''
}

# The CURRENT shipped default events for a record's hook, from the wizard's own
# canonical resolver. Returns Known=$false where that resolver is not loaded -
# the caller must then refuse to migrate rather than guess a destination.
#
# The synthesized hook object mirrors exactly what Get-HookEntries yields for
# this hook: Name drives the $script:HookMeta lookup, EnvPath drives the
# .env.example fallback beside it. Neither is read from here.
function Get-CurrentDefaultEvents {
    param($Record)
    $resolver = Get-Command -Name 'Get-HookRecommendedEvents' -ErrorAction SilentlyContinue
    if ($null -eq $resolver) {
        return [pscustomobject]@{ Known = $false; Events = @(); Detail = 'the current default event set is not resolvable in this host (Get-HookRecommendedEvents is not loaded)' }
    }
    $hookName = Get-RecordHookName -Record $Record
    if ([string]::IsNullOrWhiteSpace($hookName)) {
        return [pscustomobject]@{ Known = $false; Events = @(); Detail = 'the record does not name a hook' }
    }
    $envPath = ''
    if ($null -ne $Record.PSObject.Properties['sourceDir']) {
        $sourceDir = [string]$Record.sourceDir
        if (-not [string]::IsNullOrWhiteSpace($sourceDir)) { $envPath = (Join-Path $sourceDir '.env') }
    }
    try {
        $events = @(& $resolver ([pscustomobject]@{ Name = $hookName; EnvPath = $envPath }))
    }
    catch {
        return [pscustomobject]@{ Known = $false; Events = @(); Detail = ('the current default event set could not be resolved: ' + $_.Exception.Message) }
    }
    if (@($events).Count -eq 0) {
        return [pscustomobject]@{ Known = $false; Events = @(); Detail = 'the current default event set resolved to nothing' }
    }
    return [pscustomobject]@{ Known = $true; Events = @($events); Detail = '' }
}

# What is ACTUALLY registered for one installation right now, read from the
# client's live settings file. Distinguishes "no registrations" from "could not
# look" - Get-HookRegistrations returns an empty array for both, and reporting
# an unreadable settings file as "not registered" is the false all-clear this
# whole file exists to avoid.
#
# Strictly read-only: a JSON parse, nothing executed, nothing dot-sourced.
function Get-ActiveRegistrationSnapshot {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$SettingsPath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RuntimeScript,
        [string]$ProfileId = ''
    )
    $empty = @()
    if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
        return [pscustomobject]@{ Readable = $false; Reason = 'the record carries no settings path'; Registrations = $empty; Events = $empty }
    }
    if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
        return [pscustomobject]@{ Readable = $false; Reason = ('the settings file does not exist: ' + $SettingsPath); Registrations = $empty; Events = $empty }
    }
    try {
        $registrations = @(Get-HookRegistrations -SettingsPath $SettingsPath -RuntimeScript $RuntimeScript -ProfileId $ProfileId)
    }
    catch {
        return [pscustomobject]@{ Readable = $false; Reason = ('the settings file could not be read: ' + $_.Exception.Message); Registrations = $empty; Events = $empty }
    }
    $events = New-Object System.Collections.Generic.List[string]
    foreach ($registration in $registrations) {
        $name = [string]$registration.EventName
        if ($name -ne '' -and -not $events.Contains($name)) { [void]$events.Add($name) }
    }
    return [pscustomobject]@{ Readable = $true; Reason = ''; Registrations = $registrations; Events = $events.ToArray() }
}

# Everything that must be PROVED before one client's binding may be rewritten.
# Shared by the planner and by the updater's Resolve-UpdateEventsForClient so
# the two can never apply different standards to the same record.
#
# Deliberately NOT part of it: "the source still matches what was recorded". An
# update exists precisely because source changed, so requiring a match would
# refuse the migration exactly when it is due. What must hold is that the
# INSTALLED runtime is still the one this record describes, which is
# source-change independent and is what the installed-hash check below proves.
function Test-EventMigrationPrecondition {
    param(
        [Parameter(Mandatory = $true)]$Record,
        [Parameter(Mandatory = $true)][string]$Client
    )
    $validity = Test-InstallRecordValid -Record $Record
    if (-not $validity.Ok) {
        return [pscustomobject]@{ Ok = $false; Reason = ('the record cannot be interpreted safely: ' + $validity.Reason) }
    }
    if (-not (Test-IsManagedRecord -Record $Record)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'the record is not a managed Hook Maker install' }
    }
    $subrecord = Get-ClientSubrecord -Record $Record -Client $Client
    if ($null -eq $subrecord) {
        return [pscustomobject]@{ Ok = $false; Reason = ('no installed ' + $Client + ' subrecord') }
    }
    $runtimeScript = [string]$subrecord.runtimeScript
    $runtimeRoot = [string]$subrecord.runtimeRoot
    if (-not (Test-Path -LiteralPath $runtimeScript -PathType Leaf)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'the installed hook script is missing' }
    }
    # Ownership by PATH SHAPE, the rule identity is proved with everywhere else
    # in this codebase: the registered target must live inside the managed
    # runtime root this record recorded, with no `..` or reparse escape.
    if (-not (Test-PathContainedIn -ChildPath $runtimeScript -ParentPath $runtimeRoot)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'the installed hook script is not inside the recorded managed runtime root' }
    }
    # INSTALLED-HASH VERIFICATION. Every file the record says it installed must
    # still hash to the recorded value, and nothing managed may have appeared
    # beside them. A tampered or half-written runtime is reported, never
    # rebound.
    $recordedInstalled = @()
    if ($null -ne $subrecord.PSObject.Properties['installedManifest'] -and $null -ne $subrecord.installedManifest) {
        $recordedInstalled = @($subrecord.installedManifest)
    }
    if (@($recordedInstalled).Count -eq 0) {
        return [pscustomobject]@{ Ok = $false; Reason = 'the record carries no installed-file manifest to verify against' }
    }
    $onDisk = @(Get-InstalledManifest -RuntimeRoot $runtimeRoot -FriendlyName ([string]$Record.friendlyName))
    $difference = Compare-Manifest -Expected $recordedInstalled -Actual $onDisk
    if (-not $difference.IsMatch) {
        $detail = 'the installed runtime no longer matches its recorded hashes'
        if (@($difference.Missing).Count -gt 0) { $detail = 'installed file missing: ' + $difference.Missing[0] }
        elseif (@($difference.Modified).Count -gt 0) { $detail = 'installed file modified: ' + $difference.Modified[0] }
        elseif (@($difference.Unexpected).Count -gt 0) { $detail = 'unexpected managed file: ' + $difference.Unexpected[0] }
        return [pscustomobject]@{ Ok = $false; Reason = $detail }
    }
    # The LIVE registration must still be exactly what the record says. If it is
    # not, something outside Hook Maker has moved this binding and the events in
    # the record are no longer a statement about what is installed.
    $profileId = ''
    if ($null -ne $Record.PSObject.Properties['profile']) { $profileId = [string]$Record.profile }
    $active = Get-ActiveRegistrationSnapshot -SettingsPath ([string]$subrecord.settingsPath) -RuntimeScript $runtimeScript -ProfileId $profileId
    if (-not $active.Readable) {
        return [pscustomobject]@{ Ok = $false; Reason = $active.Reason }
    }
    if (-not (Test-EventSetEqual $active.Events @($subrecord.events))) {
        return [pscustomobject]@{ Ok = $false; Reason = ('the live registration (' + (@($active.Events) -join '+') + ') does not match the recorded binding (' + (@($subrecord.events) -join '+') + ')') }
    }
    return [pscustomobject]@{ Ok = $true; Reason = '' }
}

# The table entry that retires ONE client's recorded binding, or $null.
function Get-InstalledEventMigrationEntry {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$HookName, $RecordedEvents)
    foreach ($entry in $script:InstalledEventMigrations) {
        if ($entry.Hook -ne $HookName) { continue }
        if (Test-EventSetEqual $entry.From $RecordedEvents) { return $entry }
    }
    return $null
}

# One client's migration verdict. Statuses, and what each means:
#   migrate - a retired default, fully verified; Events is the destination
#   current - already on the current default; nothing to do
#   custom  - NOT a shipped default. Preserved untouched and reported, with
#             Inert/Unsupported set when the binding looks like it delivers
#             nothing (see below)
#   blocked - it looks migratable but a precondition is unproven; reported,
#             never acted on
#
# "Inert" is reported as a SUSPICION with its evidence named, never as proof:
# nothing here executes the hook, so the honest statement is that the binding
# names events outside the hook's current declared set. "Unsupported" is
# stronger - the client capability table says that client has no such trigger.
function Get-ClientEventMigrationVerdict {
    param(
        [Parameter(Mandatory = $true)]$Record,
        [Parameter(Mandatory = $true)][string]$Client
    )
    $hookName = Get-RecordHookName -Record $Record
    $subrecord = Get-ClientSubrecord -Record $Record -Client $Client
    $recorded = @()
    if ($null -ne $subrecord -and $null -ne $subrecord.PSObject.Properties['events']) { $recorded = @($subrecord.events) }
    elseif ($null -ne $Record.PSObject.Properties['events']) { $recorded = @($Record.events) }

    # Unsupported is the CAPABILITY TABLE's answer, not a guess: the client
    # documents no trigger for this event at all, so the binding cannot fire
    # however healthy the runtime is.
    $unsupported = @()
    if (@($recorded).Count -gt 0) {
        try {
            $eventPlan = Resolve-HookMakerEventPlan -Events @(@($recorded) | ForEach-Object { [string]$_ }) -ClientIds @($Client)
            foreach ($row in @($eventPlan.perClient)) { $unsupported = @($row.unsupported) }
        }
        catch { $unsupported = @() }
    }
    $result = [pscustomobject]@{
        RecordId       = ''
        HookName       = $hookName
        Client         = $Client
        Status         = 'current'
        Version        = 0
        RecordedEvents = @($recorded)
        Events         = @($recorded)
        Inert          = @()
        Unsupported    = @($unsupported)
        Detail         = ''
    }
    if ($null -ne $Record.PSObject.Properties['id']) { $result.RecordId = [string]$Record.id }
    if (@($recorded).Count -eq 0) {
        $result.Status = 'blocked'
        $result.Events = @()
        $result.Detail = 'no recorded events'
        return $result
    }

    $default = Get-CurrentDefaultEvents -Record $Record
    if (-not $default.Known) {
        # Unknown destination: reuse the recorded binding unchanged. This is the
        # ordinary state inside Install-Hook.ps1 and is not a fault.
        $result.Status = 'custom'
        $result.Detail = $default.Detail
        return $result
    }
    if (Test-EventSetEqual $recorded $default.Events) {
        $result.Status = 'current'
        return $result
    }

    $result.Inert = @(@($recorded) | Where-Object { @($default.Events) -notcontains [string]$_ })
    $entry = Get-InstalledEventMigrationEntry -HookName $hookName -RecordedEvents $recorded
    if ($null -eq $entry) {
        $result.Status = 'custom'
        $result.Detail = 'a custom binding (' + (@($recorded) -join '+') + '), preserved; it is not a retired shipped default'
        if (@($result.Inert).Count -gt 0) {
            $result.Detail += '. It names ' + (@($result.Inert) -join '+') + ', outside this hook''s current declared events (' + (@($default.Events) -join '+') + '), so it may deliver nothing'
        }
        if (@($result.Unsupported).Count -gt 0) {
            $result.Detail += '. ' + $Client + ' has no trigger for ' + (@($result.Unsupported) -join '+')
        }
        return $result
    }

    $precondition = Test-EventMigrationPrecondition -Record $Record -Client $Client
    if (-not $precondition.Ok) {
        $result.Status = 'blocked'
        $result.Version = $entry.Version
        $result.Detail = 'the retired default ' + (@($entry.From) -join '+') + ' was found but not migrated: ' + $precondition.Reason
        return $result
    }
    $result.Status = 'migrate'
    $result.Version = $entry.Version
    $result.Events = @($default.Events)
    $result.Detail = 'event-binding migration v' + $entry.Version + ': ' + (@($recorded) -join '+') + ' -> ' + (@($default.Events) -join '+') + ' (' + $entry.Reason + ')'
    return $result
}

# THE UPDATER'S ENTRY POINT. Returns the events "Update previously installed
# hooks" must reinstall this client with, plus one optional note for its
# per-client result line.
#
# Recorded events are returned UNCHANGED for every status except 'migrate', so
# the updater's documented behaviour (each client repaired with its own saved
# parameters) is untouched in every case this file does not positively prove.
function Resolve-UpdateEventsForClient {
    param(
        [Parameter(Mandatory = $true)]$Record,
        [Parameter(Mandatory = $true)][string]$Client
    )
    $verdict = $null
    try { $verdict = Get-ClientEventMigrationVerdict -Record $Record -Client $Client }
    catch {
        # A migration must never be able to fail an update that would otherwise
        # have succeeded: fall back to the recorded binding and say why.
        $fallback = @()
        $subrecord = Get-ClientSubrecord -Record $Record -Client $Client
        if ($null -ne $subrecord -and $null -ne $subrecord.PSObject.Properties['events']) { $fallback = @($subrecord.events) }
        elseif ($null -ne $Record.PSObject.Properties['events']) { $fallback = @($Record.events) }
        return [pscustomobject]@{ Events = @($fallback); Note = ('event-binding check skipped: ' + $_.Exception.Message) }
    }
    $note = ''
    if ($verdict.Status -eq 'migrate' -or $verdict.Status -eq 'blocked') { $note = $verdict.Detail }
    elseif ($verdict.Status -eq 'custom' -and (@($verdict.Inert).Count -gt 0 -or @($verdict.Unsupported).Count -gt 0)) { $note = $verdict.Detail }
    return [pscustomobject]@{ Events = @($verdict.Events); Note = $note }
}

# The migration plan over MANY records - every managed copy of a hook, in every
# scope, so a global and a project install of the same hook are both accounted
# for rather than whichever one was looked at first.
function Get-InstalledEventMigrationPlan {
    param(
        [Parameter(Mandatory = $true)]$Records,
        [switch]$IncludeUnchanged
    )
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($record in @($Records)) {
        if ($null -eq $record) { continue }
        $clients = @()
        try { $clients = @(Get-InstalledClientNames -Record $record) } catch { $clients = @() }
        foreach ($client in $clients) {
            $verdict = $null
            try { $verdict = Get-ClientEventMigrationVerdict -Record $record -Client $client }
            catch {
                $verdict = [pscustomobject]@{
                    RecordId = ''; HookName = (Get-RecordHookName -Record $record); Client = $client
                    Status = 'blocked'; Version = 0; RecordedEvents = @(); Events = @()
                    Inert = @(); Unsupported = @(); Detail = ('this record could not be evaluated: ' + $_.Exception.Message)
                }
            }
            if ((-not $IncludeUnchanged) -and $verdict.Status -eq 'current') { continue }
            [void]$items.Add([pscustomobject]@{
                Record  = $record
                Client  = $client
                Verdict = $verdict
            })
        }
    }
    return $items.ToArray()
}

# Applies ONLY the 'migrate' items of a plan, one client at a time, through the
# same structured-result install path the wizard uses everywhere else: success
# comes from the installer's result document, never from "no exception".
#
# Nothing here edits a settings file. Install-Hook.ps1 removes the stale
# handlers it can prove it owns and writes the new binding; a foreign handler
# on the same event is not ours to touch and is left exactly as it was.
function Invoke-InstalledEventMigration {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$InstallScript
    )
    $results = New-Object System.Collections.Generic.List[object]
    $installer = Get-Command -Name 'Invoke-HookInstaller' -ErrorAction SilentlyContinue
    foreach ($item in @($Plan)) {
        if ($item.Verdict.Status -ne 'migrate') { continue }
        $record = $item.Record
        if ($null -eq $installer) {
            [void]$results.Add([pscustomobject]@{ RecordId = $item.Verdict.RecordId; Client = $item.Client; Ok = $false; Summary = 'the installer entry point (Invoke-HookInstaller) is not loaded in this host' })
            continue
        }
        $installArgs = @{ Events = @($item.Verdict.Events); Clients = @($item.Client) }
        if ([string]$record.scope -eq 'project') { $installArgs['TargetProject'] = [string]$record.targetProjectRoot }
        if ([string]$record.hookType -eq 'Engine') {
            $installArgs['Profile'] = [string]$record.profile
            $installArgs['ConfigPath'] = [string]$record.configPath
        }
        else {
            $installArgs['CustomHook'] = [string]$record.sourceScript
        }
        try {
            $verdict = & $installer -InstallScript $InstallScript -InstallArgs $installArgs
            [void]$results.Add([pscustomobject]@{ RecordId = $item.Verdict.RecordId; Client = $item.Client; Ok = [bool]$verdict.Ok; Summary = [string]$verdict.Summary })
        }
        catch {
            [void]$results.Add([pscustomobject]@{ RecordId = $item.Verdict.RecordId; Client = $item.Client; Ok = $false; Summary = $_.Exception.Message })
        }
    }
    return $results.ToArray()
}

# ---- the read-only diagnostic ---------------------------------------------

# Other managed records naming the SAME hook, so a global copy and a project
# copy of one hook are visible together. A hook legitimately installs in many
# projects, so this is a report, never a finding: the caller decides whether
# two entries are a duplicate or two intended installs.
function Get-DuplicateInstallSummary {
    param(
        [Parameter(Mandatory = $true)]$Record,
        $AllRecords = @()
    )
    $hookName = Get-RecordHookName -Record $Record
    $selfId = ''
    if ($null -ne $Record.PSObject.Properties['id']) { $selfId = [string]$Record.id }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($other in @($AllRecords)) {
        if ($null -eq $other) { continue }
        $otherId = ''
        if ($null -ne $other.PSObject.Properties['id']) { $otherId = [string]$other.id }
        if ($otherId -ne '' -and $otherId -eq $selfId) { continue }
        if ((Get-RecordHookName -Record $other) -ne $hookName) { continue }
        $scope = ''
        if ($null -ne $other.PSObject.Properties['scope']) { $scope = [string]$other.scope }
        $root = ''
        if ($null -ne $other.PSObject.Properties['targetProjectRoot']) { $root = [string]$other.targetProjectRoot }
        $clients = @()
        try { $clients = @(Get-InstalledClientNames -Record $other) } catch { $clients = @() }
        $events = New-Object System.Collections.Generic.List[string]
        foreach ($client in $clients) {
            $sub = Get-ClientSubrecord -Record $other -Client $client
            if ($null -eq $sub -or $null -eq $sub.PSObject.Properties['events']) { continue }
            [void]$events.Add($client + '=' + (@($sub.events) -join '+'))
        }
        [void]$rows.Add([pscustomobject]@{
            RecordId = $otherId; Scope = $scope; ProjectRoot = $root
            Clients = @($clients); Bindings = $events.ToArray()
        })
    }
    return $rows.ToArray()
}

# The effective-registration / runtime report for ONE record. READ-ONLY:
# filesystem reads and JSON parses only. No settings file is written, no
# discovered hook is executed or dot-sourced, and every area that could not be
# read lands in Coverage.Notes with Coverage.Complete = $false.
function Get-EffectiveRegistrationDiagnostic {
    param(
        [Parameter(Mandatory = $true)]$Record,
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        $AllRecords = @()
    )
    # One list, and its emptiness IS the coverage verdict - a second boolean
    # could disagree with it, which is how "complete" gets reported over an area
    # that was never read.
    $notes = New-Object System.Collections.Generic.List[string]

    $recordId = ''
    if ($null -ne $Record.PSObject.Properties['id']) { $recordId = [string]$Record.id }
    $friendlyName = ''
    if ($null -ne $Record.PSObject.Properties['friendlyName']) { $friendlyName = [string]$Record.friendlyName }
    $scope = ''
    if ($null -ne $Record.PSObject.Properties['scope']) { $scope = [string]$Record.scope }
    $projectRoot = ''
    if ($null -ne $Record.PSObject.Properties['targetProjectRoot']) { $projectRoot = [string]$Record.targetProjectRoot }
    $profileId = ''
    if ($null -ne $Record.PSObject.Properties['profile']) { $profileId = [string]$Record.profile }

    $validity = Test-InstallRecordValid -Record $Record
    if (-not $validity.Ok) { [void]$notes.Add('the record is not fully interpretable: ' + $validity.Reason) }

    # ---- source: recorded hashes vs the source tree right now --------------
    $sourceMatch = $false
    $sourceDetail = ''
    $recordedSource = @()
    if ($null -ne $Record.PSObject.Properties['sourceManifest'] -and $null -ne $Record.sourceManifest) { $recordedSource = @($Record.sourceManifest) }
    try {
        $configPath = ''
        if ($null -ne $Record.PSObject.Properties['configPath']) { $configPath = [string]$Record.configPath }
        $isEngine = ([string]$Record.hookType -eq 'Engine')
        $currentSource = @(Get-ManagedSourceManifest -ToolRoot $ToolRoot `
                -HookScript ([string]$Record.sourceScript) -SourceDir ([string]$Record.sourceDir) `
                -FriendlyName $friendlyName -ConfigPath $configPath -IncludeConfig:$isEngine `
                -ProfileId $profileId -ProjectRoot $projectRoot)
        $sourceDifference = Compare-Manifest -Expected $recordedSource -Actual $currentSource
        $sourceMatch = [bool]$sourceDifference.IsMatch
        if (-not $sourceMatch) {
            if (@($recordedSource).Count -eq 0) { $sourceDetail = 'the record predates source-hash tracking' }
            elseif (@($sourceDifference.Modified).Count -gt 0) { $sourceDetail = 'source changed: ' + $sourceDifference.Modified[0] }
            elseif (@($sourceDifference.Unexpected).Count -gt 0) { $sourceDetail = 'source file added: ' + $sourceDifference.Unexpected[0] }
            elseif (@($sourceDifference.Missing).Count -gt 0) { $sourceDetail = 'source file removed: ' + $sourceDifference.Missing[0] }
        }
    }
    catch {
        $sourceDetail = 'the source manifest could not be derived: ' + $_.Exception.Message
        [void]$notes.Add($sourceDetail)
    }

    # ---- per client: command, installed hashes, ACTIVE events --------------
    $clientRows = New-Object System.Collections.Generic.List[object]
    $clientNames = @()
    try { $clientNames = @(Get-InstalledClientNames -Record $Record) }
    catch { [void]$notes.Add('the record''s client list could not be read: ' + $_.Exception.Message) }
    if (@($clientNames).Count -eq 0) { [void]$notes.Add('the record lists no installed client') }

    foreach ($client in $clientNames) {
        $subrecord = Get-ClientSubrecord -Record $Record -Client $client
        $settingsPath = ''
        if ($null -ne $subrecord.PSObject.Properties['settingsPath']) { $settingsPath = [string]$subrecord.settingsPath }
        $runtimeScript = ''
        if ($null -ne $subrecord.PSObject.Properties['runtimeScript']) { $runtimeScript = [string]$subrecord.runtimeScript }
        $runtimeRoot = ''
        if ($null -ne $subrecord.PSObject.Properties['runtimeRoot']) { $runtimeRoot = [string]$subrecord.runtimeRoot }
        $recordedEvents = @()
        if ($null -ne $subrecord.PSObject.Properties['events']) { $recordedEvents = @($subrecord.events) }

        $installedMatch = $false
        $installedDetail = ''
        $recordedInstalled = @()
        if ($null -ne $subrecord.PSObject.Properties['installedManifest'] -and $null -ne $subrecord.installedManifest) { $recordedInstalled = @($subrecord.installedManifest) }
        if (@($recordedInstalled).Count -eq 0) {
            $installedDetail = 'the record carries no installed-file manifest'
            [void]$notes.Add($client + ': ' + $installedDetail)
        }
        elseif (-not (Test-Path -LiteralPath $runtimeRoot -PathType Container)) {
            $installedDetail = 'the managed runtime directory does not exist: ' + $runtimeRoot
            [void]$notes.Add($client + ': ' + $installedDetail)
        }
        else {
            try {
                $onDisk = @(Get-InstalledManifest -RuntimeRoot $runtimeRoot -FriendlyName $friendlyName)
                $installedDifference = Compare-Manifest -Expected $recordedInstalled -Actual $onDisk
                $installedMatch = [bool]$installedDifference.IsMatch
                if (-not $installedMatch) {
                    if (@($installedDifference.Missing).Count -gt 0) { $installedDetail = 'installed file missing: ' + $installedDifference.Missing[0] }
                    elseif (@($installedDifference.Modified).Count -gt 0) { $installedDetail = 'installed file modified: ' + $installedDifference.Modified[0] }
                    else { $installedDetail = 'unexpected managed file: ' + $installedDifference.Unexpected[0] }
                }
            }
            catch {
                $installedDetail = 'the installed runtime could not be hashed: ' + $_.Exception.Message
                [void]$notes.Add($client + ': ' + $installedDetail)
            }
        }

        $active = Get-ActiveRegistrationSnapshot -SettingsPath $settingsPath -RuntimeScript $runtimeScript -ProfileId $profileId
        if (-not $active.Readable) { [void]$notes.Add($client + ': ' + $active.Reason) }
        $verdict = $null
        try { $verdict = Get-ClientEventMigrationVerdict -Record $Record -Client $client }
        catch { [void]$notes.Add($client + ': the binding could not be classified: ' + $_.Exception.Message) }

        $command = ''
        if ($null -ne $subrecord.PSObject.Properties['command']) { $command = [string]$subrecord.command }
        $commandWindows = ''
        if ($null -ne $subrecord.PSObject.Properties['commandWindows']) { $commandWindows = [string]$subrecord.commandWindows }

        [void]$clientRows.Add([pscustomobject]@{
            Client          = $client
            SettingsPath    = $settingsPath
            RuntimeScript   = $runtimeScript
            RuntimeRoot     = $runtimeRoot
            Command         = $command
            CommandWindows  = $commandWindows
            RecordedEvents  = @($recordedEvents)
            ActiveEvents    = @($active.Events)
            ActiveReadable  = [bool]$active.Readable
            EventsAgree     = (Test-EventSetEqual $recordedEvents $active.Events)
            InstalledMatch  = $installedMatch
            InstalledDetail = $installedDetail
            Binding         = $verdict
        })
    }

    return [pscustomobject]@{
        RecordId     = $recordId
        HookName     = (Get-RecordHookName -Record $Record)
        FriendlyName = $friendlyName
        Scope        = $scope
        ProjectRoot  = $projectRoot
        Managed      = (Test-IsManagedRecord -Record $Record)
        SourceMatch  = $sourceMatch
        SourceDetail = $sourceDetail
        Clients      = $clientRows.ToArray()
        Duplicates   = @(Get-DuplicateInstallSummary -Record $Record -AllRecords $AllRecords)
        Coverage     = [pscustomobject]@{ Complete = ($notes.Count -eq 0); Notes = $notes.ToArray() }
    }
}
