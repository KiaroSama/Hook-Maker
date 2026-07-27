$script:ScanKnownToolRoots = $null
# ---------------------------------------------------------------------------
# Registration parsing for the hook-status scan engine. Dot-sourced by
# _hookstatusscan.ps1 ONLY (which Get-HookStatus.ps1 dot-sources), so exactly
# like the rest of the engine it runs in the entry script's scope: $script:
# state and helpers resolve at CALL time. Do not dot-source this file
# directly.
#
# Responsibility: turn ONE known candidate location into raw registration
# findings - a Claude/Codex shared settings file, or a Kiro per-hook-file
# registration directory/document. Deciding WHICH locations are opened is the
# walk's job (_hookstatusscan.ps1); native Git discovery is
# _hookstatusscangit.ps1's.
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
# ---------------------------------------------------------------------------

. (Join-Path $PSScriptRoot '_installkiro.ps1')

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
    # Repaint here too, not only once per directory: the per-candidate
    # work below (settings parsing, one finding per registered hook)
    # grew long once projects held 22 hooks each, and with the only
    # call sitting in the directory walk the elapsed counter froze for
    # the whole of it and the scan read as hung. Show-ScanProgress is
    # throttled to 750 ms, so extra calls cost nothing.
    Show-ScanProgress

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
                if ($null -ne $finding) { [void]$script:RegistrationFindings.Add($finding); Show-ScanProgress }
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
            # Get-KnownToolRoots parses the ENTIRE install registry (~1 s
            # against a 5 MB / 563-record file) and was called here for EVERY
            # command field of EVERY finding - 66 of the scan's 116 seconds on
            # one project, and the reason a full-tree scan (591 registrations)
            # never finished. The roots cannot change mid-scan, so resolve them
            # once per scan. Same disease as the install-path double-parse fixed
            # in f72ebe8: an unindexed re-read of the same growing registry.
            if ($null -eq $script:ScanKnownToolRoots) {
                $script:ScanKnownToolRoots = @(Get-KnownToolRoots -ToolRoot $ToolRoot)
            }
            try { $info = Get-HookMakerCommandInfo -Command $field.Value -KnownToolRoots $script:ScanKnownToolRoots }
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
            # Same scan-lifetime cache as the settings path above: this is the
            # second call site of the full-registry re-parse, and the full-tree
            # scan hits it once per per-hook registration file.
            if ($null -eq $script:ScanKnownToolRoots) {
                $script:ScanKnownToolRoots = @(Get-KnownToolRoots -ToolRoot $ToolRoot)
            }
            try { $info = Get-HookMakerCommandInfo -Command $command -KnownToolRoots $script:ScanKnownToolRoots }
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
    Show-ScanProgress

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
        if ($null -ne $finding) { [void]$script:RegistrationFindings.Add($finding); Show-ScanProgress }
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
