# ---------------------------------------------------------------------------
# Uninstall ownership proofs - split out of Uninstall-Hook.ps1.
#
# ONE responsibility: decide what a persisted install record can PROVE it owns.
# Nothing here mutates anything; every function is a read-only judgement that
# returns a verdict for Uninstall-Hook.ps1 to act on. Keeping the proofs apart
# from the removal machinery is what makes them reviewable in isolation - the
# whole safety contract of the uninstaller lives in this file.
#
# DOT-SOURCED, not imported: Uninstall-Hook.ps1 dot-sources this AFTER it has
# assigned the record identity variables, so these functions read them from the
# including scope exactly as they did when they lived inline. They are part of
# the contract - this file is not standalone and must not be dot-sourced before
# they exist:
#   $FriendlyName             - record.friendlyName
#   $InternalName             - record.internalName (may be empty)
#   $ProfileId                - record.profile (empty for a custom hook)
#   $RecordScope              - global | project
#   $RecordTargetProjectRoot  - project root for a project-scoped record
#   $script:KnownToolRoots    - roots that make the legacy layout provable
#
# It also uses Test-PathContainedIn / Get-HandlerCommandValues /
# Get-HookMakerCommandInfo from _installplan.ps1, which Uninstall-Hook.ps1
# dot-sources first.
# ---------------------------------------------------------------------------

# ---- strict per-client identity validation ---------------------------------
# The persisted registry record is the source of truth: nothing below is ever
# reconstructed from FriendlyName. A record is only acted on once every
# consumed identity invariant is PROVEN; any failure retains the record as
# manualRepair with a precise reason and mutates nothing.

# GetFullPath throws on genuinely malformed input (illegal characters, a path
# exceeding OS limits, etc.) - such a value can never be a real previously-
# installed path, so it is treated as unresolvable rather than crashing the
# whole uninstall attempt.
function Get-CanonicalPathOrNull {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try { return [System.IO.Path]::GetFullPath($Path) } catch { return $null }
}

# Stricter than [string]::IsNullOrWhiteSpace([string]$Value): a value that is
# merely CASTABLE to a non-blank string (a number, an array, a nested object)
# must never be accepted as a real path/command/event name - only a genuine
# [string] instance whose content is non-blank does.
function Test-RequiredStringField {
    param($Value)
    return ($Value -is [string]) -and (-not [string]::IsNullOrWhiteSpace($Value))
}

# The EXACT canonical settings path Install-Hook.ps1 itself writes for this
# scope/client - never invented, never "anything reachable". $null means the
# record's own scope cannot be resolved at all.
function Get-ExpectedSettingsPath {
    param([Parameter(Mandatory = $true)][string]$ClientName)
    if ($RecordScope -eq 'project') {
        $canonicalProjectRoot = Get-CanonicalPathOrNull $RecordTargetProjectRoot
        if ($null -eq $canonicalProjectRoot) { return $null }
        if ($ClientName -eq 'claude') { return (Get-CanonicalPathOrNull (Join-Path $canonicalProjectRoot '.claude\settings.local.json')) }
        return (Get-CanonicalPathOrNull (Join-Path $canonicalProjectRoot '.codex\hooks.json'))
    }
    if ($RecordScope -eq 'global') {
        if ($ClientName -eq 'claude') { return (Get-CanonicalPathOrNull (Join-Path $HOME '.claude\settings.json')) }
        return (Get-CanonicalPathOrNull (Join-Path $HOME '.codex\hooks.json'))
    }
    return $null
}

# Everything that must hold about ONE client's persisted subrecord BEFORE any
# mutation is attempted for it:
#   - every consumed field is an ACTUAL non-empty [string] (never merely
#     castable to one), and events is a genuine array of non-empty strings;
#   - settingsPath equals the exact canonical path Install-Hook.ps1 itself
#     writes for this record's scope/client;
#   - the directory to remove is Split-Path -Parent of the persisted
#     runtimeScript - NEVER Join-Path runtimeRoot FriendlyName - and that
#     directory is a proper, contained child of runtimeRoot;
#   - the runtimeScript's own directory/file names still agree with what the
#     record claims this installation is named, so an internally
#     inconsistent record (name says X, runtimeScript points at Y) is refused
#     rather than trusted to compute a delete target.
function Test-ClientRecordIdentity {
    param(
        [Parameter(Mandatory = $true)]$Subrecord,
        [Parameter(Mandatory = $true)][string]$ClientName
    )
    function New-IdentityFailure {
        param([string]$Reason)
        return [pscustomobject]@{
            Ok = $false; Reason = $Reason; HookDir = ''
            CanonicalRuntimeScript = ''; CanonicalRuntimeRoot = ''; CanonicalSettingsPath = ''
        }
    }

    foreach ($field in @('settingsPath', 'runtimeRoot', 'runtimeScript', 'command')) {
        $prop = $Subrecord.PSObject.Properties[$field]
        # NOTE: never write this as `$value = if (...) { $prop.Value } else { $null }` -
        # an if/else USED AS AN EXPRESSION streams its branch's output through
        # the pipeline, which silently unwraps a one-element array into a bare
        # scalar (a real, reproduced PowerShell trap). A plain statement form
        # assigns the value as-is, array-ness and all.
        $value = $null
        if ($null -ne $prop) { $value = $prop.Value }
        if (-not (Test-RequiredStringField $value)) {
            return (New-IdentityFailure ($ClientName + '.' + $field + ' is missing or is not a genuine non-empty string'))
        }
    }
    $eventsProp = $Subrecord.PSObject.Properties['events']
    $eventsValue = $null
    if ($null -ne $eventsProp) { $eventsValue = $eventsProp.Value }
    if ($null -eq $eventsValue -or $eventsValue -is [string] -or $eventsValue -is [System.Collections.IDictionary] -or
        -not ($eventsValue -is [System.Collections.IEnumerable])) {
        return (New-IdentityFailure ($ClientName + '.events is not an array'))
    }
    $eventsArray = @($eventsValue)
    if ($eventsArray.Count -eq 0) { return (New-IdentityFailure ($ClientName + '.events is empty')) }
    foreach ($eventEntry in $eventsArray) {
        if (-not (Test-RequiredStringField $eventEntry)) {
            return (New-IdentityFailure ($ClientName + '.events contains a non-string or empty entry'))
        }
    }
    $commandWindowsProp = $Subrecord.PSObject.Properties['commandWindows']
    if ($null -ne $commandWindowsProp -and $null -ne $commandWindowsProp.Value -and $commandWindowsProp.Value -isnot [string]) {
        return (New-IdentityFailure ($ClientName + '.commandWindows is present but is not a string'))
    }

    $canonicalSettingsPath = Get-CanonicalPathOrNull ([string]$Subrecord.settingsPath)
    $canonicalRuntimeRoot = Get-CanonicalPathOrNull ([string]$Subrecord.runtimeRoot)
    $canonicalRuntimeScript = Get-CanonicalPathOrNull ([string]$Subrecord.runtimeScript)
    if ($null -eq $canonicalSettingsPath -or $null -eq $canonicalRuntimeRoot -or $null -eq $canonicalRuntimeScript) {
        return (New-IdentityFailure ($ClientName + ' has a path that cannot be canonicalized'))
    }

    $expectedSettingsPath = Get-ExpectedSettingsPath -ClientName $ClientName
    if ($null -eq $expectedSettingsPath) {
        return (New-IdentityFailure 'record has an unresolvable scope for settings-path validation')
    }
    if (-not [string]::Equals($canonicalSettingsPath, $expectedSettingsPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return (New-IdentityFailure ($ClientName + '.settingsPath does not match the expected ' + $RecordScope + '-scope path for this client'))
    }

    if (-not (Test-PathContainedIn -ChildPath $canonicalRuntimeScript -ParentPath $canonicalRuntimeRoot)) {
        return (New-IdentityFailure ($ClientName + '.runtimeScript is outside runtimeRoot'))
    }
    $hookDir = Split-Path -Parent $canonicalRuntimeScript
    if ([string]::Equals($hookDir, $canonicalRuntimeRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return (New-IdentityFailure ($ClientName + '.runtimeScript parent equals runtimeRoot - refusing to treat the shared runtime root as one hook''s own directory'))
    }
    if (-not (Test-PathContainedIn -ChildPath $hookDir -ParentPath $canonicalRuntimeRoot)) {
        return (New-IdentityFailure ($ClientName + '.runtimeScript parent is outside runtimeRoot'))
    }
    $hookDirLeaf = Split-Path -Leaf $hookDir
    $scriptLeaf = Split-Path -Leaf $canonicalRuntimeScript
    $expectedScriptLeaf = $FriendlyName + '.ps1'
    if (-not [string]::Equals($hookDirLeaf, $FriendlyName, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals($scriptLeaf, $expectedScriptLeaf, [System.StringComparison]::OrdinalIgnoreCase)) {
        return (New-IdentityFailure ($ClientName + '.runtimeScript parent does not match the managed hook directory for friendlyName ''' + $FriendlyName + ''''))
    }

    return [pscustomobject]@{
        Ok = $true; Reason = ''; HookDir = $hookDir
        CanonicalRuntimeScript = $canonicalRuntimeScript
        CanonicalRuntimeRoot   = $canonicalRuntimeRoot
        CanonicalSettingsPath  = $canonicalSettingsPath
    }
}

# ---- registration ownership: exact identity mandatory ----------------------
# A handler is removable ONLY when ALL of: its parsed runtime script path
# equals this client's canonical runtimeScript; its profile (when this record
# has one) equals the persisted profile; its event is one of the exact
# persisted events for this client; and handler type/timeout/statusMessage
# are consistent wherever the record carries them. Friendly name, internal
# name, basename, profile alone, known tool root and path SHAPE are
# supporting evidence only inside the parser - never sufficient by
# themselves. A same-name handler pointing anywhere else is FOREIGN (or, if it
# merely looks like it might be ours, AMBIGUOUS) and survives byte-identical.
function Test-HandlerFieldsConsistent {
    param($Handler, $Subrecord)
    if ($null -ne $Subrecord.PSObject.Properties['handlerType'] -and -not [string]::IsNullOrWhiteSpace([string]$Subrecord.handlerType)) {
        $actualType = ''
        if ($null -ne $Handler.PSObject.Properties['type']) { $actualType = [string]$Handler.type }
        if ($actualType -ne [string]$Subrecord.handlerType) { return $false }
    }
    if ($null -ne $Subrecord.PSObject.Properties['timeout']) {
        $expectedTimeout = 0
        if ([int]::TryParse([string]$Subrecord.timeout, [ref]$expectedTimeout) -and $expectedTimeout -gt 0) {
            $actualTimeout = -1
            if ($null -ne $Handler.PSObject.Properties['timeout']) { [void][int]::TryParse([string]$Handler.timeout, [ref]$actualTimeout) }
            if ($actualTimeout -ne $expectedTimeout) { return $false }
        }
    }
    if ($null -ne $Subrecord.PSObject.Properties['statusMessage'] -and -not [string]::IsNullOrWhiteSpace([string]$Subrecord.statusMessage)) {
        $actualStatusMessage = ''
        if ($null -ne $Handler.PSObject.Properties['statusMessage']) { $actualStatusMessage = [string]$Handler.statusMessage }
        if ($actualStatusMessage -ne [string]$Subrecord.statusMessage) { return $false }
    }
    return $true
}

# Does ONE handler carry the exact identity this client subrecord owns?
#
# Returns 'owned' | 'ambiguous' | 'foreign'. ONLY 'owned' is removable.
#
# EVERY command-bearing field on the handler must agree - one matching field is
# NOT enough. A handler carries up to three (command / commandWindows /
# command_windows) and a real install writes the SAME runtime script into all of
# the ones it uses (Install-Hook.ps1's Windows and Portable forms are built from
# one $Runtime.Script). So a handler whose `command` is ours while its
# `commandWindows` points somewhere else is NOT ours to delete: removing it
# would silently destroy whatever that other field invokes. That case is
# 'ambiguous' - the whole client stops with manualRepair - not a quiet removal
# and not a quiet skip.
function Test-HandlerExactlyOwned {
    param(
        [Parameter(Mandatory = $true)]$Handler,
        [Parameter(Mandatory = $true)][string]$EventName,
        [Parameter(Mandatory = $true)]$Subrecord,
        [Parameter(Mandatory = $true)][string]$CanonicalRuntimeScript,
        [Parameter(Mandatory = $true)][System.Collections.Generic.HashSet[string]]$PersistedEvents
    )
    if (-not $PersistedEvents.Contains($EventName)) { return 'foreign' }

    $matching = 0
    $conflicting = 0
    foreach ($commandValue in @(Get-HandlerCommandValues -Handler $Handler)) {
        $info = Get-HookMakerCommandInfo -Command $commandValue -KnownToolRoots $script:KnownToolRoots
        $parsedCanonical = $null
        if ($info.IsHookMaker) { $parsedCanonical = Get-CanonicalPathOrNull $info.RuntimeScript }
        if ($null -ne $parsedCanonical -and
            [string]::Equals($parsedCanonical, $CanonicalRuntimeScript, [System.StringComparison]::OrdinalIgnoreCase) -and
            ([string]::IsNullOrWhiteSpace($ProfileId) -or [string]$info.Profile -eq $ProfileId)) {
            $matching++
        }
        else {
            # Anything else present on this handler - a different Hook Maker
            # runtime, a different profile, an ambiguous legacy shape, or a
            # command that is not Hook Maker's at all - is a field this record
            # cannot claim.
            $conflicting++
        }
    }

    if ($matching -eq 0) { return 'foreign' }
    if ($conflicting -gt 0) { return 'ambiguous' }
    # Reached only when every command field is provably ours, so a mismatch in
    # the persisted handler metadata means OUR registration was edited after
    # install - report it rather than removing a handler we no longer recognise.
    if (-not (Test-HandlerFieldsConsistent -Handler $Handler -Subrecord $Subrecord)) { return 'ambiguous' }
    return 'owned'
}

# Broader than Test-HandlerExactlyOwned: does this parsed candidate merely
# NAME this installation (friendly/internal name, and profile when this
# record has one) without necessarily proving every exact-match criterion?
# Used only to detect a suspicious near-match - never to prove removability.
function Test-HandlerNamesThisInstall {
    param($Info, [string[]]$OwnNames)
    $named = @($OwnNames | Where-Object { [string]::Equals($_, $Info.HookName, [System.StringComparison]::OrdinalIgnoreCase) })
    if ($named.Count -eq 0) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($ProfileId) -and [string]$Info.Profile -ne $ProfileId) { return $false }
    return $true
}

function Get-PersistedEventSet {
    param($Subrecord)
    $set = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($eventEntry in @($Subrecord.events)) { [void]$set.Add([string]$eventEntry) }
    return $set
}

# Read-only pre-flight over a settings file's LIVE handlers: proves exactly
# which ones are this install's own (safe to remove) and whether anything
# merely LOOKS like it belongs to this install without being provable. A near
# match blocks the ENTIRE client (nothing staged, nothing written) rather than
# being silently skipped or silently removed - "no registration" is only ever
# claimed once nothing Hook-Maker-shaped names this install anywhere in the
# file.
function Get-ClientHandlerScan {
    param(
        [Parameter(Mandatory = $true)][string]$SettingsPath,
        [Parameter(Mandatory = $true)]$Subrecord,
        [Parameter(Mandatory = $true)][string]$CanonicalRuntimeScript
    )
    $result = [pscustomobject]@{ NearMatch = $false; NearMatchDetail = ''; OwnedCount = 0 }
    if ([string]::IsNullOrWhiteSpace($SettingsPath) -or -not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) { return $result }
    $json = Read-OrCreateJsonObject $SettingsPath
    if ($null -eq $json.PSObject.Properties['hooks'] -or $null -eq $json.hooks) { return $result }

    $persistedEvents = Get-PersistedEventSet -Subrecord $Subrecord
    $ownNames = @(@($FriendlyName, $InternalName) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    foreach ($eventProperty in $json.hooks.PSObject.Properties) {
        $eventName = $eventProperty.Name
        foreach ($group in @($eventProperty.Value)) {
            foreach ($handler in @($group.hooks)) {
                $ownership = Test-HandlerExactlyOwned -Handler $handler -EventName $eventName -Subrecord $Subrecord `
                    -CanonicalRuntimeScript $CanonicalRuntimeScript -PersistedEvents $persistedEvents
                if ($ownership -eq 'owned') {
                    $result.OwnedCount++
                    continue
                }
                if ($ownership -eq 'ambiguous') {
                    # Proven-partial ownership: at least one command field is
                    # ours and at least one is not. This blocks the whole client
                    # on its own, without needing the name-based near-match scan
                    # below to notice it.
                    $result.NearMatch = $true
                    if ([string]::IsNullOrEmpty($result.NearMatchDetail)) {
                        $result.NearMatchDetail = 'a registration under ' + $eventName + ' matches this install on some command fields but not on all of them, so it cannot be proven to be ours alone'
                    }
                    continue
                }
                foreach ($commandValue in @(Get-HandlerCommandValues -Handler $handler)) {
                    $info = Get-HookMakerCommandInfo -Command $commandValue -KnownToolRoots $script:KnownToolRoots
                    if (-not $info.IsHookMaker -and -not $info.IsAmbiguous) { continue }
                    if (-not (Test-HandlerNamesThisInstall -Info $info -OwnNames $ownNames)) { continue }
                    $result.NearMatch = $true
                    if ([string]::IsNullOrEmpty($result.NearMatchDetail)) {
                        $result.NearMatchDetail = 'a registration under ' + $eventName + ' names this install (' + $FriendlyName + ') but does not exactly match its recorded runtime script, profile, event, or handler fields'
                    }
                    break
                }
            }
        }
    }
    return $result
}

# Mutates $HooksObject in place, dropping only handlers PROVEN (via
# Test-HandlerExactlyOwned) to belong to this client subrecord.
function Remove-ExactlyOwnedHandlers {
    param(
        [Parameter(Mandatory = $true)]$HooksObject,
        [Parameter(Mandatory = $true)][string]$EventName,
        [Parameter(Mandatory = $true)]$Subrecord,
        [Parameter(Mandatory = $true)][string]$CanonicalRuntimeScript,
        [Parameter(Mandatory = $true)][System.Collections.Generic.HashSet[string]]$PersistedEvents
    )
    if ($null -eq $HooksObject.PSObject.Properties[$EventName]) { return $false }
    $removedAny = $false
    $keptGroups = @()
    foreach ($group in @($HooksObject.$EventName)) {
        $keptHandlers = @()
        foreach ($handler in @($group.hooks)) {
            # Only 'owned' is removable; 'ambiguous' and 'foreign' both survive
            # byte-identical. (An ambiguous handler cannot actually reach this
            # point - Get-ClientHandlerScan blocks the entire client first - but
            # the equality test keeps that a belt-and-braces invariant rather
            # than a truthiness accident.)
            $owned = (Test-HandlerExactlyOwned -Handler $handler -EventName $EventName -Subrecord $Subrecord `
                    -CanonicalRuntimeScript $CanonicalRuntimeScript -PersistedEvents $PersistedEvents) -eq 'owned'
            if ($owned) { $removedAny = $true } else { $keptHandlers += $handler }
        }
        if ($keptHandlers.Count -gt 0) {
            $group.hooks = $keptHandlers
            $keptGroups += $group
        }
    }
    $HooksObject.$EventName = $keptGroups
    return $removedAny
}

# Which on-disk stages does this record actually own?
#
# The name is ONLY a lookup key into the record's own persisted expectedStages -
# it is never the authority for what gets deleted. Every returned path is a
# string that was literally persisted at install time (Install-Hook.ps1 writes
# expectedStages = @($runtime.Script, $secretsScript), i.e. the exact installed
# stage paths), canonicalized and proven to sit in a proper subdirectory of the
# record's own runtimeRoot.
#
# So a record whose friendlyName/companions do not line up with its persisted
# stages resolves to a REFUSAL, not to a name-derived directory that happens to
# exist. Records predating expectedStages cannot prove ownership at all and are
# likewise refused: they already fail the byte-exact wrapper comparison further
# down, and "we cannot tell what is ours" must never be reported as a clean
# removal.
function Resolve-OwnNativeStages {
    param(
        [Parameter(Mandatory = $true)]$Native,
        [string]$OwnRuntimeRoot
    )
    function New-OwnershipFailure {
        param([string]$Reason)
        return [pscustomobject]@{ Ok = $false; Reason = $Reason; Stages = @(); Dirs = @() }
    }

    if ([string]::IsNullOrWhiteSpace($OwnRuntimeRoot)) {
        return (New-OwnershipFailure 'managed nativeGit record has no runtimeRoot to resolve its own stages against')
    }
    $canonicalRoot = Get-CanonicalPathOrNull $OwnRuntimeRoot
    if ($null -eq $canonicalRoot) {
        return (New-OwnershipFailure 'managed nativeGit runtimeRoot cannot be canonicalized')
    }

    $persisted = @()
    if ($null -ne $Native.PSObject.Properties['expectedStages'] -and $null -ne $Native.expectedStages) {
        $persisted = @($Native.expectedStages | ForEach-Object { [string]$_ })
    }
    if ($persisted.Count -eq 0) {
        return (New-OwnershipFailure 'managed nativeGit record persists no expectedStages, so none of its on-disk stages can be proven to belong to it')
    }
    # Default [hashtable] key comparison is already case-insensitive for
    # strings, which is what path comparison needs on Windows.
    $persistedByCanonical = @{}
    foreach ($stage in $persisted) {
        $canonicalStage = Get-CanonicalPathOrNull $stage
        if ($null -eq $canonicalStage) {
            return (New-OwnershipFailure 'managed nativeGit expectedStages contains a path that cannot be canonicalized')
        }
        $persistedByCanonical[$canonicalStage] = $true
    }

    $ownNames = @($FriendlyName)
    if ($null -ne $Native.PSObject.Properties['companions'] -and $null -ne $Native.companions) {
        $ownNames += @(@($Native.companions) | ForEach-Object { [string]$_ })
    }

    $stages = New-Object System.Collections.Generic.List[string]
    $dirs = New-Object System.Collections.Generic.List[string]
    foreach ($name in $ownNames) {
        if ([string]::IsNullOrWhiteSpace($name)) {
            return (New-OwnershipFailure 'managed nativeGit record names an empty stage')
        }
        $candidate = Get-CanonicalPathOrNull (Join-Path $canonicalRoot ($name + '\' + $name + '.ps1'))
        if ($null -eq $candidate -or -not $persistedByCanonical.ContainsKey($candidate)) {
            return (New-OwnershipFailure ('the managed stage for ''' + $name + ''' is absent from this record''s own persisted expectedStages, so it cannot be proven to belong to this installation'))
        }
        $dir = Split-Path -Parent $candidate
        if ([string]::Equals($dir, $canonicalRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-PathContainedIn -ChildPath $dir -ParentPath $canonicalRoot)) {
            return (New-OwnershipFailure ('the persisted stage for ''' + $name + ''' does not sit in a managed subdirectory of the record''s own runtimeRoot'))
        }
        [void]$stages.Add($candidate)
        [void]$dirs.Add($dir)
    }
    return [pscustomobject]@{ Ok = $true; Reason = ''; Stages = @($stages.ToArray()); Dirs = @($dirs.ToArray()) }
}
