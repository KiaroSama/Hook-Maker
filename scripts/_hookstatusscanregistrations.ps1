$script:ScanKnownToolRoots = $null
# ---------------------------------------------------------------------------
# Registration parsing for the hook-status scan engine. Dot-sourced by
# _hookstatusscan.ps1 ONLY (which Get-HookStatus.ps1 dot-sources), so exactly
# like the rest of the engine it runs in the entry script's scope: $script:
# state and helpers resolve at CALL time. Do not dot-source this file
# directly.
#
# Responsibility: turn ONE known candidate location into raw registration
# findings - a Claude/Codex shared settings file, or a per-hook-file
# registration directory/document. Deciding WHICH locations are opened is the
# walk's job (_hookstatusscan.ps1); native Git discovery is
# _hookstatusscangit.ps1's.
#
# ONE dot-source, deliberately. Per-hook-file registrations
# are per-hook FILES, and their ownership proof lives in that module - the same
# one the installer and uninstaller use. Reimplementing "is this document ours"
# here would be a second, drifting copy of an ownership rule, which is exactly
# how a scanner ends up claiming somebody else's file.
#
# _installlib.ps1 also loads that module, so this line is redundant TODAY and
# is kept anyway: it states the dependency where it is actually used instead of
# inheriting it from a file that has no reason to guarantee it. Dot-sourcing is
# idempotent, the module is pure (it defines functions, writes nothing, and
# touches disk only inside the managed-file test), and it pulls in only
# _clientcapability.ps1, which the entry script has already loaded - so this
# cannot reorder anything.
# ---------------------------------------------------------------------------

# ---- client registration shapes (derived, never re-declared) ---------------

# Every client fact below comes from _clientcapability.ps1, because that table
# is where the installer decides the same things. A second copy here is exactly
# the drift that made a whole client invisible to this scanner in the first place.

# The client-root directory names ('.claude', '.codex'), used to find
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

}

# The project root of a registration path, from the DEEPEST client-root
# component in it.
#
# The old form was "the settings file's grandparent", which is correct only
# while every registration sits exactly one level under its client directory.
# It is wrong for any nested registration directory: for
# <root>\.client\hooks\x.json it answered <root>\.client, i.e. it named the client
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
    # <root>\.client\hooks\hookmaker-x.json -> <root>
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
