# ---------------------------------------------------------------------------
# Discovery half of the hook-status scan engine. Dot-sourced by
# Get-HookStatus.ps1 ONLY - it runs in that script's scope, so every
# $script: state variable (Warnings, Inaccessible, SkippedReparse,
# RegistrationFindings, NativeFindings, counters, ...) and every helper it
# calls (Add-ScanWarning, Show-ScanProgress, and the record builders in
# _hookstatusrecords.ps1) resolve at CALL time, once the whole engine and its
# libraries are loaded and only "main" is executing. Do not dot-source this
# file directly.
#
# ONE dot-source, deliberately: scripts\_installkiro.ps1. Kiro registrations
# are per-hook FILES, and their ownership proof lives in that module - the same
# one the installer and uninstaller use. Reimplementing "is this document ours"
# here would be a second, drifting copy of an ownership rule, which is exactly
# how a scanner ends up claiming somebody else's file.
#
# _installlib.ps1 also loads that module, so this line is redundant TODAY and
# is kept anyway: it states the dependency where it is actually used instead of
# inheriting it from a file that has no reason to guarantee it. Dot-sourcing is
# idempotent, the module is pure (it defines functions, writes nothing, and
# touches disk only inside Test-KiroManagedFile), and it pulls in only
# _clientcapability.ps1, which the entry script has already loaded - so this
# cannot reorder anything.
#
# Responsibility: turn a filesystem location into raw findings - Claude/Codex
# settings registrations, Kiro per-hook-file registrations and native Git hooks
# - via settings parsing, git/native discovery, and the directory walk itself.
# See _hookstatusrecords.ps1 for turning those findings into verified logical
# records.
# ---------------------------------------------------------------------------

. (Join-Path $PSScriptRoot '_installkiro.ps1')

# ---- shared path helpers ---------------------------------------------------

$script:SeenDirectoryKeys = New-Object System.Collections.Generic.HashSet[string]
$script:SeenSettingsKeys = New-Object System.Collections.Generic.HashSet[string]
$script:SeenGitKeys = New-Object System.Collections.Generic.HashSet[string]

function Test-PathUnderAny {
    param([string]$Path, [string[]]$Parents)
    foreach ($parent in @($Parents)) {
        if ([string]::IsNullOrWhiteSpace($parent)) { continue }
        try { if (Test-PathContainedIn -ChildPath $Path -ParentPath $parent) { return $true } }
        catch { }
    }
    return $false
}

# ---- client registration shapes (derived, never re-declared) ---------------

# Every client fact below comes from _clientcapability.ps1, because that table
# is where the installer decides the same things. A second copy here is exactly
# the drift that made Kiro invisible to this scanner in the first place.

function Test-PerHookFileClient {
    param([string]$ClientId)
    try { return ((Get-HookMakerClientCapability -ClientId $ClientId).registrationKind -eq 'perHookFile') }
    catch { return $false }
}

# The directory names a client registration lives under, split into the leaf
# and the directory that must contain it: '.kiro\hooks' -> Leaf 'hooks',
# Parent '.kiro'. The walk uses this to recognise a per-hook-file registration
# directory by POSITION, exactly as it already recognises .claude\settings.json
# - never by filename alone, which any directory could carry.
$script:PerHookFileDirectoryShapes = New-Object System.Collections.Generic.List[object]
# The client-root directory names ('.claude', '.codex', '.kiro'), used to find
# the project root of a registration path.
$script:ClientRootMarkers = New-Object System.Collections.Generic.List[string]
foreach ($clientId in @(Get-HookMakerClientIds)) {
    $capability = $null
    try { $capability = Get-HookMakerClientCapability -ClientId $clientId } catch { continue }
    $segments = @(([string]$capability.projectRegistration).Split([char[]]@('\', '/')) | Where-Object { $_ -ne '' })
    if ($segments.Count -lt 1) { continue }
    if (-not $script:ClientRootMarkers.Contains([string]$segments[0])) {
        [void]$script:ClientRootMarkers.Add([string]$segments[0])
    }
    if ([string]$capability.registrationKind -ne 'perHookFile' -or $segments.Count -lt 2) { continue }
    [void]$script:PerHookFileDirectoryShapes.Add([pscustomobject]@{
        Client = [string]$capability.id
        Leaf   = [string]$segments[$segments.Count - 1]
        Parent = [string]$segments[$segments.Count - 2]
    })
}

# The project root of a registration path, from the DEEPEST client-root
# component in it.
#
# The old form was "the settings file's grandparent", which is correct only
# while every registration sits exactly one level under its client directory.
# It is wrong for any nested registration directory: for
# <root>\.kiro\hooks\x.json it answered <root>\.kiro, i.e. it named the client
# directory as the project. Deriving the answer from the client-root component
# fixes that shape generally rather than special-casing one client, and gives a
# byte-identical result for .claude\settings.json and .codex\hooks.json, whose
# client root IS the immediate parent.
function Get-ProjectRootForRegistrationPath {
    param([string]$Path)
    $current = Split-Path -Parent $Path
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        $leaf = ''
        try { $leaf = Split-Path -Leaf $current } catch { break }
        if ($script:ClientRootMarkers -contains [string]$leaf) { return (Split-Path -Parent $current) }
        $parent = ''
        try { $parent = Split-Path -Parent $current } catch { break }
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) { break }
        $current = $parent
    }
    return ''
}

# ---- client settings parsing -----------------------------------------------

# The canonical global registration locations, as the installer itself writes
# them. A sharedSettingsFile client contributes its settings FILE; a
# perHookFile client contributes its registration DIRECTORY, because it has no
# single settings document to name (asking Get-CanonicalClientSettingsPath for
# one is a refusal by design, not an oversight).
function Get-GlobalSettingsCandidates {
    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($client in @(Get-HookMakerClientIds)) {
        $capability = $null
        try { $capability = Get-HookMakerClientCapability -ClientId $client } catch { continue }
        $perHookFile = ([string]$capability.registrationKind -eq 'perHookFile')
        $path = ''
        if ($perHookFile) {
            try { $path = Join-Path $HOME ([string]$capability.globalRegistration) } catch { continue }
        }
        else {
            try { $path = Get-CanonicalClientSettingsPath -ClientName $client -Scope 'global' } catch { continue }
        }
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        [void]$candidates.Add([pscustomobject]@{ Client = $client; Path = $path; PerHookFile = $perHookFile })
    }
    return $candidates.ToArray()
}

# Two sets, because the two kinds of location are compared against different
# things: a settings FILE key is matched against the file being opened, a
# per-hook registration DIRECTORY key against the parent of the file being
# opened.
$script:GlobalSettingsKeys = New-Object System.Collections.Generic.HashSet[string]
$script:GlobalPerHookDirectoryKeys = New-Object System.Collections.Generic.HashSet[string]
foreach ($candidate in @(Get-GlobalSettingsCandidates)) {
    if ($candidate.PerHookFile) { [void]$script:GlobalPerHookDirectoryKeys.Add((Get-CanonicalPathKey $candidate.Path)) }
    else { [void]$script:GlobalSettingsKeys.Add((Get-CanonicalPathKey $candidate.Path)) }
}

# Is this registration file one of the current user's canonical GLOBAL ones?
# Answered for both client shapes at the single point each is opened, so
# declining -IncludeGlobal means the same thing on every code path.
function Test-GlobalRegistrationPath {
    param([string]$RegistrationPath)
    if ($script:GlobalSettingsKeys.Contains((Get-CanonicalPathKey $RegistrationPath))) { return $true }
    $parent = ''
    try { $parent = Split-Path -Parent $RegistrationPath } catch { return $false }
    if ([string]::IsNullOrWhiteSpace($parent)) { return $false }
    return $script:GlobalPerHookDirectoryKeys.Contains((Get-CanonicalPathKey $parent))
}

# Scope is decided by the FILE'S OWN location, not by how the scan reached it: a
# global settings file found because it happened to sit inside the scanned root
# is still global.
function Get-SettingsScopeInfo {
    param([string]$SettingsPath)
    if (Test-GlobalRegistrationPath -RegistrationPath $SettingsPath) {
        return [pscustomobject]@{ Scope = 'global'; ProjectRoot = '' }
    }
    # <root>\.claude\settings.local.json -> <root>
    # <root>\.kiro\hooks\hookmaker-x.json -> <root>
    $projectRoot = Get-ProjectRootForRegistrationPath -Path $SettingsPath
    if ([string]::IsNullOrWhiteSpace($projectRoot)) {
        # No client-root component at all. Kept as the original grandparent rule
        # so a caller that ever hands this function a path outside a client
        # directory gets exactly the answer it used to get.
        $projectRoot = Split-Path -Parent (Split-Path -Parent $SettingsPath)
    }
    if ([string]::IsNullOrWhiteSpace($projectRoot)) {
        return [pscustomobject]@{ Scope = 'global'; ProjectRoot = '' }
    }
    return [pscustomobject]@{ Scope = 'project'; ProjectRoot = (Get-CanonicalPathOrEmpty $projectRoot) }
}

# Turns ONE settings file into per-handler findings.
#
# Every event and every handler is reported - there is deliberately NO filter on
# Hook Maker's name, path, marker, profile or command. A third-party hook is
# exactly as much an "installed hook" as ours, and hiding it would defeat the
# purpose of the scan.
#
# Malformed JSON is a FINDING (a warning plus a coverage note), never a crash.
function Read-SettingsRegistrations {
    param([Parameter(Mandatory = $true)][string]$SettingsPath, [Parameter(Mandatory = $true)][string]$Client)

    # A perHookFile client has no shared settings document: the path IS its
    # registration directory, and every managed *.json inside it is one
    # registration. Dispatched here so the global-candidate loop in
    # Get-HookStatus.ps1 needs no client-specific branch of its own.
    if (Test-PerHookFileClient -ClientId $Client) {
        Read-PerHookFileDirectory -Path $SettingsPath -Client $Client
        return
    }

    $key = Get-CanonicalPathKey $SettingsPath
    if ($key -eq '') { return }
    # THE global gate, enforced at the single point where any settings file is
    # opened rather than at each caller. -IncludeGlobal is a direct answer to a
    # direct question, so "declined" has to mean the current user's global
    # settings files are never read - no matter which path would reach them.
    # Both the downward walk (a scan root that happens to sit at or above the
    # user's profile) and the direct-subtree lookup (a scan root inside
    # $HOME\.claude\...) can otherwise land on exactly those files.
    if (-not $IncludeGlobal -and $script:GlobalSettingsKeys.Contains($key)) { return }
    if (-not $script:SeenSettingsKeys.Add($key)) { return }
    if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) { return }
    $script:SettingsFilesSeen++
    $script:CandidateRootsSeen++

    $raw = ''
    try { $raw = [System.IO.File]::ReadAllText($SettingsPath, [System.Text.Encoding]::UTF8) }
    catch {
        Add-ScanWarning ('settings file could not be read: ' + $SettingsPath + ' (' + $_.Exception.Message + ')')
        [void]$script:Inaccessible.Add($SettingsPath)
        return
    }
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    $document = $null
    try { $document = $raw | ConvertFrom-Json }
    catch {
        Add-ScanWarning ('settings file is not valid JSON and was skipped: ' + $SettingsPath)
        return
    }
    if ($null -eq $document -or $document -isnot [psobject]) { return }
    # An unrelated but perfectly valid JSON file at a candidate name simply has
    # no hooks object - that is a clean no-op, not a warning.
    $hooksProperty = $document.PSObject.Properties['hooks']
    if ($null -eq $hooksProperty -or $null -eq $hooksProperty.Value) { return }
    $hooksObject = $hooksProperty.Value
    if ($hooksObject -isnot [psobject] -or $hooksObject -is [System.Collections.IEnumerable]) { return }

    $scopeInfo = Get-SettingsScopeInfo -SettingsPath $SettingsPath
    $canonicalSettings = Get-CanonicalPathOrEmpty $SettingsPath

    foreach ($eventProperty in @($hooksObject.PSObject.Properties)) {
        $eventName = [string]$eventProperty.Name
        $groups = $eventProperty.Value
        if ($null -eq $groups) { continue }
        foreach ($group in @($groups)) {
            if ($null -eq $group -or $group -isnot [psobject]) { continue }
            $handlersProperty = $group.PSObject.Properties['hooks']
            if ($null -eq $handlersProperty -or $null -eq $handlersProperty.Value) { continue }
            $matcherFingerprint = ''
            try { $matcherFingerprint = Get-MatcherFingerprint -Group $group } catch { }
            foreach ($handler in @($handlersProperty.Value)) {
                if ($null -eq $handler -or $handler -isnot [psobject]) { continue }
                $finding = New-RegistrationFinding -Client $Client -SettingsPath $canonicalSettings `
                    -Scope $scopeInfo.Scope -ProjectRoot $scopeInfo.ProjectRoot `
                    -EventName $eventName -Group $group -MatcherFingerprint $matcherFingerprint -Handler $handler
                if ($null -ne $finding) { [void]$script:RegistrationFindings.Add($finding) }
            }
        }
    }
}

function New-RegistrationFinding {
    param(
        [string]$Client, [string]$SettingsPath, [string]$Scope, [string]$ProjectRoot,
        [string]$EventName, $Group, [string]$MatcherFingerprint, $Handler
    )
    $handlerFingerprint = ''
    try { $handlerFingerprint = Get-HandlerFingerprint -Handler $Handler }
    catch {
        Add-ScanWarning ('a handler in ' + $SettingsPath + ' could not be fingerprinted and was skipped')
        return $null
    }
    $handlerType = ''
    if ($null -ne $Handler.PSObject.Properties['type'] -and $null -ne $Handler.type) { $handlerType = [string]$Handler.type }

    $agreement = Get-HandlerTargetAgreement -Handler $Handler
    $fieldNames = @($agreement.FieldNames)
    $parsedTargets = @($agreement.ParsedTargets)

    # Which of the four contract statuses this handler is in. "Cannot be proven"
    # is a first-class outcome, not an error: such a registration is still an
    # installed hook, it just cannot be removed automatically.
    $registrationStatus = 'parsed'
    $targetExists = $false
    if ($fieldNames.Count -eq 0 -or -not $agreement.AnyParsed) {
        $registrationStatus = 'unparsedCommand'
    }
    elseif (-not $agreement.AllAgree) {
        # Covers both "the fields name different targets" and "one field parsed,
        # another did not" - in either case the fields do not agree, so removing
        # the registration could silence something the other field pointed at.
        $registrationStatus = 'fieldsDisagree'
    }
    else {
        $targetExists = (Test-Path -LiteralPath $parsedTargets[0] -PathType Leaf)
        if (-not $targetExists) { $registrationStatus = 'targetMissing' }
    }

    # Ownership: proven Hook Maker path shape, provably something else, or -
    # when nothing could be parsed - honestly unknown.
    $managedBy = 'unknown'
    $hookMakerName = ''
    if ($agreement.AnyParsed) {
        $managedBy = 'external'
        foreach ($field in @(Get-DiscoveryCommandFields -Handler $Handler)) {
            $info = $null
            try { $info = Get-HookMakerCommandInfo -Command $field.Value -KnownToolRoots @(Get-KnownToolRoots -ToolRoot $ToolRoot) }
            catch { continue }
            if ($null -ne $info -and $info.IsHookMaker) { $managedBy = 'hookMaker'; $hookMakerName = [string]$info.HookName; break }
        }
    }

    return [pscustomobject]@{
        Client             = $Client
        SettingsPath       = $SettingsPath
        Scope              = $Scope
        ProjectRoot        = $ProjectRoot
        EventName          = $EventName
        HandlerFingerprint = $handlerFingerprint
        MatcherFingerprint = $MatcherFingerprint
        HandlerType        = $handlerType
        CommandFieldNames  = $fieldNames
        ParsedTargets      = $parsedTargets
        RegistrationStatus = $registrationStatus
        TargetExists       = $targetExists
        ManagedBy          = $managedBy
        HookMakerName      = $hookMakerName
    }
}

# ---- per-hook-file (Kiro) registration parsing ------------------------------
#
# Kiro is a perHookFile client: .kiro\hooks holds ONE JSON document per logical
# installation instead of a shared settings file every hook lives in. Two
# consequences drive everything below.
#
#   1. A file Hook Maker NAMES can still be somebody else's. Kiro users write
#      hooks by hand into the same directory, so ownership is proven from an
#      identity inside the ENTRIES, never from the filename.
#   2. Ownership is not this file's to decide. _installkiro.ps1 already owns
#      that judgement for the installer and the uninstaller, so the proof is
#      delegated to it: Test-KiroManagedFile for the document,
#      Test-KiroManagedEntry for each entry, Split-KiroDocumentEntries for the
#      v1 schema. Nothing here re-derives any of them.
#
# As everywhere else in this scanner, a document is parsed as DATA. No command
# is run, resolved, dot-sourced or interpreted.

# The managed ids a document claims for itself.
#
# Discovery cannot know a ManagedId in advance - that is the whole point of
# discovery - so the candidates are read out of the document's own
# `[hookmaker:<id>]` markers and handed straight BACK to Test-KiroManagedFile,
# which is what actually decides. A candidate that proves nothing simply loses.
# Bounded, because the input is an arbitrary file.
#
# Returned WITHOUT a unary comma, and every caller wraps the call in @(). The
# usual `return ,$array` guard is WRONG here: it produced an array whose single
# element was the string array, so the caller's foreach bound a [string[]] to a
# [string] parameter, every proof attempt threw an argument-transformation
# error, and the file came out silently unprovable. @() already preserves a
# one-element result, so the comma buys nothing and costs correctness.
function Get-KiroCandidateManagedIds {
    param([string]$Text)
    $ids = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Text)) { return $ids.ToArray() }
    foreach ($match in [regex]::Matches($Text, '\[hookmaker:([^\]\r\n]{1,200})\]')) {
        $value = $match.Groups[1].Value.Trim()
        if ($value -eq '' -or $ids.Contains($value)) { continue }
        [void]$ids.Add($value)
        if ($ids.Count -ge 8) { break }
    }
    return $ids.ToArray()
}

# ONE entry of a Kiro document as a registration finding, in the same shape the
# shared-settings path produces so the record builder needs no client branch.
#
# $ManagedBy is decided by the CALLER from the entry-identity proof and passed
# in. Get-HookMakerCommandInfo is consulted only for a display NAME here -
# never for ownership - because a command that points at a Hook Maker runtime
# path proves where the file lives, not who owns the registration, and for a
# perHookFile client those are different questions.
function New-KiroRegistrationFinding {
    param(
        [string]$RegistrationPath, [string]$Scope, [string]$ProjectRoot,
        $Entry, [string]$ManagedBy
    )
    $eventName = [string](Get-KiroEntryField -Entry $Entry -Name 'trigger')
    if ([string]::IsNullOrWhiteSpace($eventName)) {
        # An entry with no trigger can never fire, and an empty event name would
        # make an unusable record. Reported, not silently dropped.
        Add-ScanWarning ('a Kiro entry in ' + $RegistrationPath + ' has no trigger and was skipped')
        return $null
    }
    $handlerFingerprint = ''
    try { $handlerFingerprint = Get-HandlerFingerprint -Handler $Entry }
    catch {
        Add-ScanWarning ('a Kiro entry in ' + $RegistrationPath + ' could not be fingerprinted and was skipped')
        return $null
    }

    $action = Get-KiroEntryField -Entry $Entry -Name 'action'
    $handlerType = [string](Get-KiroEntryField -Entry $action -Name 'type')
    $command = [string](Get-KiroEntryField -Entry $action -Name 'command')

    # The command sits at action.command, one level deeper than the shared
    # clients put it, so the shared target parser gets a flat shim and the REAL
    # field name travels with the finding. An 'agent' action carries no command
    # at all and spawns no process, so it can never resolve to a target.
    $fieldNames = @()
    $parsedTargets = @()
    $registrationStatus = 'unparsedCommand'
    $targetExists = $false
    $hookMakerName = ''
    if (-not [string]::IsNullOrWhiteSpace($command)) {
        $agreement = Get-HandlerTargetAgreement -Handler ([pscustomobject]@{ command = $command })
        if ($agreement.AnyParsed) {
            $fieldNames = @('action.command')
            $parsedTargets = @($agreement.ParsedTargets)
            $targetExists = (Test-Path -LiteralPath $parsedTargets[0] -PathType Leaf)
            $registrationStatus = $(if ($targetExists) { 'parsed' } else { 'targetMissing' })
            $info = $null
            try { $info = Get-HookMakerCommandInfo -Command $command -KnownToolRoots @(Get-KnownToolRoots -ToolRoot $ToolRoot) }
            catch { $info = $null }
            if ($null -ne $info -and $info.IsHookMaker) { $hookMakerName = [string]$info.HookName }
        }
    }
    # 'external' is a claim that this is somebody else's hook, and nothing was
    # proven when no target could be parsed - honestly unknown instead.
    $resolvedManagedBy = $ManagedBy
    if ($resolvedManagedBy -eq 'external' -and $parsedTargets.Count -eq 0) { $resolvedManagedBy = 'unknown' }

    return [pscustomobject]@{
        Client             = 'kiro'
        SettingsPath       = $RegistrationPath
        Scope              = $Scope
        ProjectRoot        = $ProjectRoot
        EventName          = $eventName
        HandlerFingerprint = $handlerFingerprint
        # Kiro has no matcher GROUP: its matcher is a field of the entry and is
        # therefore already inside the handler fingerprint. An invented second
        # fingerprint would be a value the remover could never recompute.
        MatcherFingerprint = ''
        HandlerType        = $handlerType
        CommandFieldNames  = $fieldNames
        ParsedTargets      = $parsedTargets
        RegistrationStatus = $registrationStatus
        TargetExists       = $targetExists
        ManagedBy          = $resolvedManagedBy
        HookMakerName      = $hookMakerName
    }
}

function Read-KiroRegistrationFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $key = Get-CanonicalPathKey $Path
    if ($key -eq '') { return }
    # The same global gate the shared-settings reader applies, at the single
    # point a Kiro document is opened.
    if (-not $IncludeGlobal -and (Test-GlobalRegistrationPath -RegistrationPath $Path)) { return }
    if (-not $script:SeenSettingsKeys.Add($key)) { return }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $script:SettingsFilesSeen++
    $script:CandidateRootsSeen++

    $raw = ''
    try { $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) }
    catch {
        Add-ScanWarning ('Kiro hook file could not be read: ' + $Path + ' (' + $_.Exception.Message + ')')
        [void]$script:Inaccessible.Add($Path)
        return
    }
    if ([string]::IsNullOrWhiteSpace($raw)) { return }
    $document = $null
    # Doubled parentheses: @($x | ConvertFrom-Json) yields one opaque Object[]
    # on Windows PowerShell, and every field read off it returns $null.
    try { $document = ($raw | ConvertFrom-Json) }
    catch {
        Add-ScanWarning ('Kiro hook file is not valid JSON and was skipped: ' + $Path)
        return
    }

    # A sentinel id no installation can hold, so the shared classifier hands
    # back EVERY entry as foreign: the enumeration this scanner needs, with none
    # of the ownership it has not proven yet.
    $classified = $null
    try { $classified = Split-KiroDocumentEntries -Document $document -ManagedId ('scan' + [guid]::NewGuid().ToString('N')) }
    catch {
        Add-ScanWarning ('Kiro hook file could not be classified and was skipped: ' + $Path)
        return
    }
    if ([string]$classified.Reason -eq 'unexpected-schema') {
        # A legacy .kiro.hook shape or a hand-written document this scanner does
        # not understand. Reported, never interpreted, never claimed.
        Add-ScanWarning ('not a Kiro v1 hook document (version "v1" plus a hooks array) and was skipped: ' + $Path)
        return
    }
    $entries = @($classified.ForeignEntries)
    if ($entries.Count -eq 0) { return }

    # Ownership, proven or not at all. The filename is only a prefilter - a
    # document that does not even carry the managed filename pattern is
    # certainly not ours, and one that does still has to prove it from inside.
    $provenId = ''
    if (Test-KiroManagedFileName -Path $Path) {
        foreach ($candidate in @(Get-KiroCandidateManagedIds -Text $raw)) {
            $proof = $null
            try { $proof = Test-KiroManagedFile -Path $Path -ManagedId $candidate }
            catch {
                # An id with no [a-z0-9] characters is a rejected CANDIDATE, not
                # a scan failure. Anything else is a real fault and is reported
                # rather than swallowed: a blanket catch here is exactly what
                # turns a provably managed file into a silently unprovable one.
                if ([string]$_.Exception.Message -notlike '*managed-id-unusable*') {
                    Add-ScanWarning ('a Kiro ownership proof failed for ' + $Path + ': ' + $_.Exception.Message)
                }
                continue
            }
            if ([string]$proof.Reason -eq 'managed') { $provenId = $candidate; break }
        }
    }
    # ponytail: only the [hookmaker:<id>] description marker yields a candidate
    # id. New-KiroHookDocument writes the name-prefix proof and the description
    # marker together, so this covers every document Hook Maker wrote; a user
    # who rewrites a description costs us the proof and the file is reported as
    # unknown ownership, which is the safe direction. Recover the id from the
    # entry name prefix if that ever proves too strict in the field.

    $scopeInfo = Get-SettingsScopeInfo -SettingsPath $Path
    $canonicalPath = Get-CanonicalPathOrEmpty $Path
    foreach ($entry in $entries) {
        $managedBy = 'unknown'
        if ($provenId -ne '') {
            $owned = $false
            try { $owned = (Test-KiroManagedEntry -Entry $entry -ManagedId $provenId) } catch { $owned = $false }
            # A foreign entry sitting inside a document we DO own is still
            # foreign - preserving it is the whole reason the writer merges.
            $managedBy = $(if ($owned) { 'hookMaker' } else { 'external' })
        }
        elseif (-not (Test-KiroManagedFileName -Path $Path)) {
            # Not even named like ours, so it is somebody else's hook - reported
            # exactly as a third-party Claude/Codex handler is.
            $managedBy = 'external'
        }
        $finding = New-KiroRegistrationFinding -RegistrationPath $canonicalPath -Scope $scopeInfo.Scope `
            -ProjectRoot $scopeInfo.ProjectRoot -Entry $entry -ManagedBy $managedBy
        if ($null -ne $finding) { [void]$script:RegistrationFindings.Add($finding) }
    }
}

# Every registration document in ONE per-hook-file registration directory. Used
# for the global candidate and the bounded upward lookup; the downward walk
# reaches the same files entry by entry and needs no directory pass.
function Read-PerHookFileDirectory {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Client)

    if ($Client -ne 'kiro') {
        # A future perHookFile client needs its own reader: its document schema
        # and its ownership proof are its own, and guessing either would be a
        # claim this scanner cannot back up.
        Add-ScanWarning ("no per-hook-file reader is implemented for client '" + $Client + "'; " + $Path + ' was not inspected')
        return
    }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    if (Test-IsReparsePoint -Path $Path) {
        [void]$script:SkippedReparse.Add((Get-CanonicalPathOrEmpty $Path))
        return
    }
    $entries = @()
    try { $entries = @((New-Object System.IO.DirectoryInfo $Path).EnumerateFiles('*.json')) }
    catch {
        [void]$script:Inaccessible.Add((Get-CanonicalPathOrEmpty $Path))
        Add-ScanWarning ('Kiro hooks directory could not be listed: ' + $Path)
        return
    }
    foreach ($entry in $entries) { Read-KiroRegistrationFile -Path $entry.FullName }
}

# ---- native Git discovery --------------------------------------------------

# `git config --get` with an argument ARRAY (never a shell string, so nothing in
# a repository path can be interpolated), a bounded timeout, and a clean
# fallback when git is absent. `git config` cannot run a hook.
$script:GitExecutable = $null
$script:GitProbed = $false
function Get-GitExecutable {
    if (-not $script:GitProbed) {
        $script:GitProbed = $true
        try {
            $command = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $command) { $script:GitExecutable = [string]$command.Source }
        }
        catch { $script:GitExecutable = $null }
    }
    return $script:GitExecutable
}

function Get-GitConfigValue {
    param([string]$RepositoryRoot, [string]$Name, [int]$TimeoutMs = 5000)
    $executable = Get-GitExecutable
    if ([string]::IsNullOrWhiteSpace($executable)) { return '' }
    $process = $null
    try {
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = $executable
        foreach ($argument in @('-C', $RepositoryRoot, 'config', '--get', $Name)) { [void]$info.ArgumentList.Add($argument) }
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $process = [System.Diagnostics.Process]::Start($info)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        [void]$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMs)) {
            try { $process.Kill($true) } catch { }
            Add-ScanWarning ('git config timed out for repository: ' + $RepositoryRoot)
            return ''
        }
        if ($process.ExitCode -ne 0) { return '' }
        return ([string]$stdout.Result).Trim()
    }
    catch {
        Add-ScanWarning ('git could not be queried for ' + $RepositoryRoot + ': ' + $_.Exception.Message)
        return ''
    }
    finally { if ($null -ne $process) { try { $process.Dispose() } catch { } } }
}

# Fallback when git is unavailable: read core.hooksPath straight out of the
# repository's own config file. Deliberately a narrow INI read of one known key,
# not a general config parser.
function Get-HooksPathFromConfigFile {
    param([string]$GitDirectory)
    $configPath = Join-Path $GitDirectory 'config'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return '' }
    $text = ''
    try { $text = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8) }
    catch { return '' }
    $inCore = $false
    foreach ($line in ($text -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith('[')) { $inCore = ($trimmed -match '^\[core(\s|\])'); continue }
        if (-not $inCore) { continue }
        $match = [regex]::Match($trimmed, '^hooksPath\s*=\s*(.+)$', 'IgnoreCase')
        if ($match.Success) { return $match.Groups[1].Value.Trim().Trim('"') }
    }
    return ''
}

# `.git` may be a directory OR a file containing `gitdir: <path>` (worktrees and
# submodules). Both are real repositories and both must be discovered.
function Resolve-GitDirectory {
    param([string]$RepositoryRoot)
    $dotGit = Join-Path $RepositoryRoot '.git'
    if (Test-Path -LiteralPath $dotGit -PathType Container) { return (Get-CanonicalPathOrEmpty $dotGit) }
    if (-not (Test-Path -LiteralPath $dotGit -PathType Leaf)) { return '' }
    $text = ''
    try {
        $item = Get-Item -LiteralPath $dotGit -Force -ErrorAction Stop
        # A `.git` pointer file is a single short line; anything larger is not
        # one and is not opened as text.
        if ($item.Length -gt 8192) { return '' }
        $text = [System.IO.File]::ReadAllText($dotGit, [System.Text.Encoding]::UTF8)
    }
    catch { return '' }
    $match = [regex]::Match($text, '(?im)^\s*gitdir\s*:\s*(.+?)\s*$')
    if (-not $match.Success) { return '' }
    $target = $match.Groups[1].Value.Trim()
    if (-not [System.IO.Path]::IsPathRooted($target)) { $target = Join-Path $RepositoryRoot $target }
    return (Get-CanonicalPathOrEmpty $target)
}

# Classify ONE native hook file.
#
# A Hook Maker wrapper is only claimed when the canonical generator REBUILDS the
# exact file from the stage list read back out of it - a marker line alone is
# not proof, because a tampered or hand-edited wrapper still carries the marker.
# That is why managedStages is populated only on an exact rebuild match.
function Get-NativeHookClassification {
    param([string]$HookPath)
    $result = [pscustomobject]@{ Classification = 'externalNativeHook'; ManagedStages = @() }
    $text = ''
    try {
        $item = Get-Item -LiteralPath $HookPath -Force -ErrorAction Stop
        if ($item.Length -gt 262144) { return $result }
        $text = [System.IO.File]::ReadAllText($HookPath, [System.Text.Encoding]::UTF8)
    }
    catch {
        $result.Classification = 'ambiguous'
        return $result
    }
    if ($text -notlike ('*' + $script:PrePushMarker + '*')) { return $result }

    $stages = @([regex]::Matches($text, '-File\s+"([^"]+)"\s+-GitPrePush') | ForEach-Object { $_.Groups[1].Value })
    if ($stages.Count -eq 0) {
        $result.Classification = 'ambiguous'
        return $result
    }
    $expected = ''
    try { $expected = New-PrePushWrapperBody -ManagedScripts $stages } catch { $expected = '' }
    if ($expected -ne '' -and (Compare-PrePushWrapperBody -Expected $expected -Actual $text)) {
        $result.Classification = 'hookMakerWrapper'
        $result.ManagedStages = @($stages | ForEach-Object { Get-CanonicalPathOrEmpty ($_.Replace('/', '\')) } | Where-Object { $_ -ne '' })
        return $result
    }
    # Marker present but the bytes are not what this generator produces: the
    # wrapper was edited or is from another writer. Reported, never claimed.
    $result.Classification = 'ambiguous'
    return $result
}

function Read-GitRepository {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $canonicalRoot = Get-CanonicalPathOrEmpty $RepositoryRoot
    if ($canonicalRoot -eq '') { return }
    $key = Get-CanonicalPathKey $canonicalRoot
    if ($key -eq '' -or -not $script:SeenGitKeys.Add($key)) { return }
    $gitDirectory = Resolve-GitDirectory -RepositoryRoot $canonicalRoot
    if ($gitDirectory -eq '') { return }
    $script:GitRepositoriesSeen++
    $script:CandidateRootsSeen++

    $hooksPath = ''
    $configured = Get-GitConfigValue -RepositoryRoot $canonicalRoot -Name 'core.hooksPath'
    if ([string]::IsNullOrWhiteSpace($configured)) { $configured = Get-HooksPathFromConfigFile -GitDirectory $gitDirectory }
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        $candidate = $configured
        if (-not [System.IO.Path]::IsPathRooted($candidate)) { $candidate = Join-Path $canonicalRoot $candidate }
        $hooksPath = Get-CanonicalPathOrEmpty $candidate
        if ($hooksPath -eq '') { Add-ScanWarning ('core.hooksPath could not be resolved for ' + $canonicalRoot) }
    }
    if ($hooksPath -eq '') { $hooksPath = Get-CanonicalPathOrEmpty (Join-Path $gitDirectory 'hooks') }
    if ($hooksPath -eq '' -or -not (Test-Path -LiteralPath $hooksPath -PathType Container)) { return }
    if (Test-IsReparsePoint -Path $hooksPath) {
        [void]$script:SkippedReparse.Add($hooksPath)
        return
    }

    $entries = @()
    try { $entries = @((New-Object System.IO.DirectoryInfo $hooksPath).EnumerateFiles()) }
    catch {
        [void]$script:Inaccessible.Add($hooksPath)
        Add-ScanWarning ('git hooks directory could not be listed: ' + $hooksPath)
        return
    }
    foreach ($entry in $entries) {
        # `*.sample` files are git's shipped examples: never installed, never
        # executed, and reporting them would bury the real hooks in noise.
        if ($entry.Name -like '*.sample') { continue }
        $classification = Get-NativeHookClassification -HookPath $entry.FullName
        [void]$script:NativeFindings.Add([pscustomobject]@{
            RepositoryRoot  = $canonicalRoot
            HooksPath       = $hooksPath
            HookName        = $entry.Name
            HookPath        = (Get-CanonicalPathOrEmpty $entry.FullName)
            HookHash        = (Get-FileSha256Hex -Path $entry.FullName)
            HookSize        = [int64]$entry.Length
            HookModifiedUtc = $entry.LastWriteTimeUtc.ToString('o')
            Classification  = $classification.Classification
            ManagedStages   = @($classification.ManagedStages)
        })
    }
}

# ---- the walk --------------------------------------------------------------

# Iterative and streaming: one directory's listing is materialized at a time
# (so an enumeration error can be caught for THAT directory), the frontier is an
# explicit stack, and nothing about the tree as a whole is ever held in memory.
function Invoke-ScanWalk {
    param([Parameter(Mandatory = $true)][string]$Root)

    $canonicalRoot = Get-CanonicalPathOrEmpty $Root
    if ($canonicalRoot -eq '' -or -not (Test-Path -LiteralPath $canonicalRoot -PathType Container)) {
        Add-ScanWarning ('scan root is not an existing directory and was skipped: ' + $Root)
        return
    }
    # A reparse-point root never reaches here: main refuses it outright, before
    # anything is scanned (see the -ScanRoot checks at the bottom of this file).

    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push([pscustomobject]@{ Path = $canonicalRoot; Depth = 0 })

    while ($stack.Count -gt 0) {
        if ($script:Canceled) { return }
        $current = $stack.Pop()
        $key = Get-CanonicalPathKey $current.Path
        if ($key -eq '' -or -not $script:SeenDirectoryKeys.Add($key)) { continue }
        $script:DirectoriesInspected++
        Show-ScanProgress

        $entries = @()
        try { $entries = @((New-Object System.IO.DirectoryInfo $current.Path).EnumerateFileSystemInfos()) }
        catch {
            # Access denied, path too long, or the directory vanished mid-scan.
            # Isolated to THIS directory - one unreadable folder must never be
            # able to abort a whole drive scan.
            [void]$script:Inaccessible.Add([string]$current.Path)
            continue
        }

        $parentName = ''
        $grandParentName = ''
        try {
            $currentInfo = New-Object System.IO.DirectoryInfo $current.Path
            $parentName = $currentInfo.Name
            if ($null -ne $currentInfo.Parent) { $grandParentName = $currentInfo.Parent.Name }
        }
        catch { }

        # Is THIS directory a per-hook-file registration directory? A
        # perHookFile client owns a whole directory of registrations rather than
        # one known filename, so it is handled once here instead of per file -
        # and recognised by POSITION (leaf name plus containing directory name),
        # so an ordinary folder called 'hooks' elsewhere is never mistaken for
        # one. Ownership is still proven per document inside the reader.
        foreach ($shape in $script:PerHookFileDirectoryShapes) {
            if ($parentName -eq $shape.Leaf -and $grandParentName -eq $shape.Parent) {
                Read-PerHookFileDirectory -Path $current.Path -Client ([string]$shape.Client)
                break
            }
        }

        foreach ($entry in $entries) {
            if ($script:Canceled) { return }
            $isDirectory = (($entry.Attributes -band [System.IO.FileAttributes]::Directory) -eq [System.IO.FileAttributes]::Directory)
            if ($isDirectory) {
                # Reparse check BEFORE the '.git' name dispatch below - a '.git'
                # entry that is itself a junction/symlink must be caught here
                # too, or Read-GitRepository would follow it via an explicit
                # path read (Resolve-GitDirectory / core.hooksPath), scanning
                # outside -ScanRoot and breaking the guarantee for the one name
                # checked first.
                # Attribute check first, then the shared helper. Both answer the
                # same question; the attribute is already in hand from the
                # enumeration, so it avoids a second stat on the common path.
                if ((($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint) -or
                    (Test-IsReparsePoint -Path $entry.FullName)) {
                    # Never followed: a junction to an ancestor is an infinite
                    # tree and one pointing outside the root would silently scan
                    # somewhere the user did not ask for.
                    [void]$script:SkippedReparse.Add([string]$entry.FullName)
                    continue
                }
                if ($entry.Name -eq '.git') {
                    # A repository, not a folder to descend into: git's object
                    # store is large, contains nothing registrable, and its
                    # hooks directory is reached by path below.
                    Read-GitRepository -RepositoryRoot $current.Path
                    continue
                }
                $childDepth = [int]$current.Depth + 1
                # $MaxDepth 0/unset = unlimited. This branch exists only so
                # tests and manual CLI use can bound a walk.
                if ($MaxDepth -gt 0 -and $childDepth -gt $MaxDepth) { continue }
                $stack.Push([pscustomobject]@{ Path = [string]$entry.FullName; Depth = $childDepth })
                continue
            }

            # Files: only KNOWN candidate names at KNOWN positions are opened.
            if ($entry.Name -eq '.git') {
                Read-GitRepository -RepositoryRoot $current.Path
                continue
            }
            if ($parentName -eq '.claude' -and ($entry.Name -eq 'settings.local.json' -or $entry.Name -eq 'settings.json')) {
                Read-SettingsRegistrations -SettingsPath $entry.FullName -Client 'claude'
                continue
            }
            if ($parentName -eq '.codex' -and $entry.Name -eq 'hooks.json') {
                Read-SettingsRegistrations -SettingsPath $entry.FullName -Client 'codex'
                continue
            }
        }
    }
}

# When -ScanRoot is already INSIDE a runtime or native tree (say
# ...\.claude\hooks\Hook-Maker), walking down from it finds the runtime files but
# not the registration that points at them. So the enclosing context is looked up
# UPWARD - but in exactly ONE bounded hop, not by climbing.
#
# The hop is derived from the root's own path components: the OUTERMOST
# `.claude` / `.codex` / `.kiro` / `.git` component in -ScanRoot marks the tree
# the user pointed inside, and its parent is that tree's project root. Only that
# one directory is inspected, and only at its known settings/git locations - no
# ancestor is ever enumerated.
#
# `.kiro` is a marker because Kiro's runtime root is `.kiro\hook-runtime\
# Hook-Maker`, so a scan aimed there was previously left with NO enclosing
# context at all. It resolves the same project root the other two do, and its
# own registrations - one JSON per install under `.kiro\hooks` - are read here
# as a bounded directory pass, the perHookFile equivalent of the two known
# settings leaves.
#
# Deriving the hop instead of walking up until something is found is what keeps
# this from silently becoming an unrestricted scan outside the user's root: a
# climb from an ordinary temp folder would eventually reach the user's home and
# read the real global settings nobody asked about.
function Find-UpwardContext {
    param([Parameter(Mandatory = $true)][string]$Root)

    $canonical = Get-CanonicalPathOrEmpty $Root
    if ($canonical -eq '') { return }
    $segments = @($canonical.Split([char[]]@('\', '/')))
    $markerIndex = -1
    for ($i = 0; $i -lt $segments.Count; $i++) {
        if ($segments[$i] -eq '.claude' -or $segments[$i] -eq '.codex' -or $segments[$i] -eq '.kiro' -or $segments[$i] -eq '.git') { $markerIndex = $i; break }
    }
    # No client/native component in the path: -ScanRoot is an ordinary directory
    # and the downward walk already covers everything reachable from it.
    if ($markerIndex -lt 1) { return }

    $contextRoot = Get-CanonicalPathOrEmpty (($segments[0..($markerIndex - 1)]) -join [string][System.IO.Path]::DirectorySeparatorChar)
    if ($contextRoot -eq '' -or -not (Test-Path -LiteralPath $contextRoot -PathType Container)) { return }

    foreach ($leaf in @('.claude\settings.local.json', '.claude\settings.json')) {
        $candidate = Join-Path $contextRoot $leaf
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { Read-SettingsRegistrations -SettingsPath $candidate -Client 'claude' }
    }
    $codexCandidate = Join-Path $contextRoot '.codex\hooks.json'
    if (Test-Path -LiteralPath $codexCandidate -PathType Leaf) { Read-SettingsRegistrations -SettingsPath $codexCandidate -Client 'codex' }
    # Each perHookFile client's registration directory under the same context
    # root, derived from the capability table rather than named again here.
    foreach ($shape in $script:PerHookFileDirectoryShapes) {
        $perHookCandidate = Join-Path (Join-Path $contextRoot ([string]$shape.Parent)) ([string]$shape.Leaf)
        if (Test-Path -LiteralPath $perHookCandidate -PathType Container) {
            Read-PerHookFileDirectory -Path $perHookCandidate -Client ([string]$shape.Client)
        }
    }
    $contextGitPath = Join-Path $contextRoot '.git'
    # Same reparse guard as the downward walk: a '.git' DIRECTORY reached by
    # this single upward hop must not be followed if it is itself a junction.
    if ((Test-Path -LiteralPath $contextGitPath -PathType Container) -and (Test-IsReparsePoint -Path $contextGitPath)) {
        [void]$script:SkippedReparse.Add($contextGitPath)
    }
    elseif (Test-Path -LiteralPath $contextGitPath) {
        Read-GitRepository -RepositoryRoot $contextRoot
    }
}
