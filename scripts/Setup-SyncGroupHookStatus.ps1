# Hook-status discovery screens for the wizard: the scan prompts behind
# hook-list item 22 ("Get hook status") and the grouped result screen.
#
# Split out of Setup-SyncGroup.ps1 as its own responsibility, exactly like
# Setup-SyncGroupInstalledHooks.ps1: everything here is about DISCOVERING hooks
# that exist on disk but are not necessarily tracked by Hook Maker, which is a
# different concern from the wizard's create/install flows and from managing
# records that are already in the registry.
#
# This file is UI ONLY. It performs no scanning, no classification and no
# registry mutation of its own. All of that lives in scripts\Get-HookStatus.ps1,
# which is invoked as a separate script process (the same pattern
# Invoke-UninstallInstalledHooks uses for Uninstall-Hook.ps1) and communicates
# back through a JSON result document. It is deliberately NOT dot-sourced: the
# scanner must not be able to splice anything into the wizard's scope, and the
# wizard must not be able to reach into the scanner's internals.
#
# Dot-sourced by Setup-SyncGroup.ps1, which supplies the UI primitives
# ($C, $ToolRoot, $StatusScript, Write-PhaseHeader, Write-MenuTitle, Write-Field,
# Read-Answer, Read-YesNo, New-QuestionPrompt, Write-NoteLine, Write-Log, ...).
# The dependency is one-directional: this file never reaches back into a wizard
# menu flow.

# ---- safe result-document field access ------------------------------------
# The result document comes from another process, so under StrictMode every
# field read has to tolerate the property being absent entirely. A malformed or
# partial document must degrade into a visible "(unknown)" rather than an
# unhandled exception that hides the whole scan result.
function Get-StatusValue {
    param($Object, [string]$Name, $Fallback = $null)
    if ($null -eq $Object) { return $Fallback }
    if ($null -eq $Object.PSObject.Properties[$Name]) { return $Fallback }
    $value = $Object.$Name
    if ($null -eq $value) { return $Fallback }
    return $value
}

function Get-StatusText {
    param($Object, [string]$Name, [string]$Fallback = '(unknown)')
    $value = [string](Get-StatusValue $Object $Name '')
    if ([string]::IsNullOrWhiteSpace($value)) { return $Fallback }
    return $value
}

function Get-StatusList {
    param($Object, [string]$Name)
    return @(Get-StatusValue $Object $Name @())
}

# A list rendered inline, with an explicit marker when it is empty - an empty
# line would read as "not collected" rather than "genuinely none".
function Get-StatusListText {
    param([object[]]$Items, [string]$EmptyText = '(none)')
    $values = @(@($Items) | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($values.Count -eq 0) { return $EmptyText }
    return ($values -join ', ')
}

# ---- scan root canonicalization -------------------------------------------
# Accepts anything that names a real directory: a project root, a parent of many
# projects, a .claude/.codex/.git/hooks/Hook-Maker directory, any ancestor of
# those, a drive root, a quoted path, a path with spaces, or a path containing
# environment variables. It deliberately does NOT require the exact project root
# - the scanner walks downwards from wherever it is pointed.
#
# Canonicalization is both lexical (environment expansion + GetFullPath, which
# resolves . and .. and relative input against the current directory) and
# physical (Get-Item, which yields the directory's real on-disk name). A drive
# root keeps its trailing separator: "G:" alone is a drive-relative path, not
# the root of the drive, so trimming it would silently change the meaning.
function Resolve-ScanRoot {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return [pscustomobject]@{ Ok = $false; Path = ''; Reason = 'Enter a folder path.' }
    }
    $lexical = ''
    try {
        $lexical = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Value))
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Path = ''; Reason = ('Not a usable path: ' + $Value) }
    }
    if (-not (Test-Path -LiteralPath $lexical -PathType Container)) {
        return [pscustomobject]@{ Ok = $false; Path = ''; Reason = ('Folder not found: ' + $lexical) }
    }
    $physical = $lexical
    try {
        # -Force so a hidden folder (.claude, .codex, .git) resolves like any
        # other; those are among the most likely things to be pointed at here.
        $item = Get-Item -LiteralPath $lexical -Force -ErrorAction Stop
        if ($null -ne $item -and -not [string]::IsNullOrWhiteSpace([string]$item.FullName)) {
            $physical = [string]$item.FullName
        }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Path = ''; Reason = ('Folder could not be read: ' + $lexical) }
    }
    return [pscustomobject]@{ Ok = $true; Path = $physical; Reason = '' }
}

# ---- result grouping -------------------------------------------------------
# Which section of the result screen a finding belongs in. Ambiguity wins over
# everything else: a finding whose command could not be parsed, or whose command
# fields disagree, must never be quietly filed under a confident heading.
function Get-StatusGroupKey {
    param($Finding)

    $status = [string](Get-StatusText $Finding 'status' '')
    if ($status -eq 'ambiguous') { return 'ambiguous' }
    foreach ($client in @(Get-StatusList $Finding 'clients')) {
        $registration = [string](Get-StatusText $client 'registrationStatus' '')
        if ($registration -eq 'unparsedCommand' -or $registration -eq 'fieldsDisagree') { return 'ambiguous' }
    }
    $native = Get-StatusValue $Finding 'nativeGit' $null
    if ($null -ne $native -and (Get-StatusText $native 'classification' '') -eq 'ambiguous') { return 'ambiguous' }

    if ((Get-StatusText $Finding 'managedBy' '') -eq 'hookMaker') { return 'managed' }
    switch (Get-StatusText $Finding 'hookType' '') {
        'NativeGitHook' { return 'nativeGit' }
        'CodexRegistration' { return 'externalCodex' }
        default { return 'externalClaude' }
    }
}

# How much of a finding this tool can actually remove on its own. Stated in the
# result screen for EVERY hook, because "detected" and "removable" are different
# questions and conflating them is how a user ends up believing an external
# hook will disappear when it will not.
function Get-RemovalPolicyText {
    param($Finding)
    switch (Get-StatusText $Finding 'removalPolicy' '') {
        'full' { return 'full' }
        'registrationOnly' { return 'registration-only' }
        'nativeFileOnly' { return 'native-file-only' }
        default { return 'unavailable' }
    }
}

function Get-RemovalPolicyColor {
    param([string]$PolicyText)
    switch ($PolicyText) {
        'full' { return $C.Green }
        'unavailable' { return $C.Red }
        default { return $C.Amber }
    }
}

# One logical hook, as a multi-line block. Never truncated to a single line:
# the exact settings path and the exact parsed target are the two facts a user
# needs to act on, and both are routinely longer than a terminal row.
function Write-StatusFinding {
    param([int]$Number, $Finding)

    $name = Get-StatusText $Finding 'friendlyName' '(unnamed hook)'
    $hookType = Get-StatusText $Finding 'hookType' '(unknown type)'
    $scope = Get-StatusText $Finding 'scope' 'unknown'
    $managedBy = Get-StatusText $Finding 'managedBy' 'unknown'
    $managedText = if ($managedBy -eq 'hookMaker') { 'Hook Maker managed' } elseif ($managedBy -eq 'external') { 'external' } else { 'unknown ownership' }
    $managedColor = if ($managedBy -eq 'hookMaker') { $C.Mint } elseif ($managedBy -eq 'external') { $C.Amber } else { $C.Red }

    Write-Host ('  ' + (Get-Painted (([string]$Number) + '.') $C.LightBlue) + ' ' + (Get-Painted $name $C.Bold) + $script:MenuSep + (Get-Painted $hookType $C.Aqua) + $script:MenuSep + (Get-Painted $managedText $managedColor) + $script:MenuSep + (Get-Painted $scope $C.Gray))

    $targetRoot = Get-StatusText $Finding 'targetProjectRoot' ''
    if ($scope -eq 'global') { Write-Field '     target' 'global' }
    elseif (-not [string]::IsNullOrWhiteSpace($targetRoot)) { Write-Field '     target' $targetRoot }

    $clients = @(Get-StatusList $Finding 'clients')
    if ($clients.Count -eq 0) {
        Write-Field '     clients' '(none)'
    }
    foreach ($client in $clients) {
        $clientName = Get-ClientDisplayName (Get-StatusText $client 'client' 'unknown')
        $events = Get-StatusListText (Get-StatusList $client 'events')
        Write-Field ('     ' + $clientName + ' events') $events
        Write-Field ('     ' + $clientName + ' settings') (Get-StatusText $client 'settingsPath' '(unknown settings path)')
        # An unparsable command is reported as exactly that. The raw command
        # string itself is never displayed or persisted - it can embed secrets.
        $registration = Get-StatusText $client 'registrationStatus' ''
        $targets = @(Get-StatusList $client 'parsedTargets')
        if ($targets.Count -gt 0) {
            Write-Field ('     ' + $clientName + ' target') (Get-StatusListText $targets)
        }
        elseif ($registration -eq 'fieldsDisagree') {
            Write-Field ('     ' + $clientName + ' target') 'unparsed command (command fields disagree)' $C.Amber
        }
        else {
            Write-Field ('     ' + $clientName + ' target') 'unparsed command' $C.Amber
        }
        if ($registration -eq 'targetMissing') {
            Write-Field ('     ' + $clientName + ' note') 'registered target file is missing' $C.Amber
        }
    }

    $native = Get-StatusValue $Finding 'nativeGit' $null
    if ($null -ne $native) {
        Write-Field '     native hook' (Get-StatusText $native 'hookPath' '(unknown hook path)')
        Write-Field '     native repo' (Get-StatusText $native 'repositoryRoot' '(unknown repository)')
        Write-Field '     native kind' (Get-StatusText $native 'classification' '(unclassified)')
        $stages = @(Get-StatusList $native 'managedStages')
        if ($stages.Count -gt 0) { Write-Field '     native stages' (Get-StatusListText $stages) }
    }

    $status = Get-StatusText $Finding 'status' 'unknown'
    $statusReason = Get-StatusText $Finding 'statusReason' ''
    $statusColor = if ($status -eq 'active') { $C.Green } elseif ($status -eq 'manualRepair' -or $status -eq 'ambiguous') { $C.Red } else { $C.Amber }
    $statusText = if ([string]::IsNullOrWhiteSpace($statusReason)) { $status } else { $status + ' - ' + $statusReason }
    Write-Field '     status' $statusText $statusColor

    $policy = Get-RemovalPolicyText $Finding
    Write-Field '     automatic uninstall' $policy (Get-RemovalPolicyColor $policy)
    if ((Get-StatusValue $Finding 'needsManualRepair' $false) -eq $true) {
        Write-Field '     manual repair' 'yes - this finding cannot be handled automatically' $C.Red
    }
}

# ---- menu 22: scan a path and report what is installed ---------------------
# Prompt flow (each step can go back one; nothing is scanned or written until
# the user has passed BOTH prompts):
#   1. root folder to scan
#   2. also inspect the current user's global Claude/Codex locations? (default No)
#   3. show the canonical roots, then start immediately
#
# Returns 'back' when the user leaves before scanning, 'done' otherwise.
function Invoke-GetHookStatus {
    Write-Log 'INFO' 'STATUS' 'Get hook status started.'
    Write-PhaseHeader 'Get Hook Status' $C.Input '-'

    Write-NoteLine '  Point this at any folder: a project root, a folder holding many projects, a'
    Write-NoteLine '  .claude / .codex / .git / hooks folder, or any parent of those. The scan reads'
    Write-NoteLine '  only - it never runs a hook, and never writes into the folder you choose.'

    $scanRoot = ''
    $includeGlobal = $false
    $stage = 0
    while ($true) {
        if ($stage -eq 0) {
            $value = Read-Answer (New-QuestionPrompt 'Root folder to scan' ('example: ' + (Get-ExampleText 'G:\Projects')) $null) 'hook status scan root'
            if ($value -eq '0') {
                Write-Log 'INFO' 'STATUS' 'User backed out of the scan-root prompt; nothing scanned.'
                return 'back'
            }
            $resolved = Resolve-ScanRoot $value
            if (-not $resolved.Ok) {
                Write-ErrorLine $resolved.Reason
                Write-Log 'WARNING' 'STATUS' ('Rejected scan root: ' + $resolved.Reason)
                continue
            }
            $scanRoot = $resolved.Path
            $stage = 1
            continue
        }

        # Default No: the global locations belong to the user's whole machine,
        # not to the folder they just named, so including them is an explicit
        # opt-in rather than something Enter does by accident.
        $answer = Read-YesNo (New-QuestionPrompt "Also inspect the current user's global Claude and Codex hook locations?" 'y/n' 'n') $false 'hook status include global'
        if ($null -eq $answer) {
            $stage = 0
            continue
        }
        $includeGlobal = $answer
        break
    }

    # ---- roots screen: exactly what will be read, then start ----------------
    Write-PhaseHeader 'Scanning' $C.Process '-'
    Write-MenuTitle 'Roots to scan:'
    Write-Host ('  ' + (Get-Painted $scanRoot $C.White))
    if ($includeGlobal) {
        foreach ($client in @('claude', 'codex')) {
            $globalPath = Get-CanonicalClientSettingsPath -ClientName $client -Scope 'global'
            Write-Host ('  ' + (Get-Painted $globalPath $C.White) + $script:MenuSep + (Get-Painted ((Get-ClientDisplayName $client) + ' global') $C.Gray))
        }
    }
    else {
        Write-NoteLine '  Global Claude/Codex locations are NOT included in this scan.'
    }
    Write-NoteLine '  Reparse points (symlinks, junctions, mount points) are not followed; they are'
    Write-NoteLine '  reported as skipped instead, so the scan cannot wander outside these roots.'
    Write-Log 'INFO' 'STATUS' ('Scan starting: root=' + $scanRoot + '; includeGlobal=' + $includeGlobal)

    # Availability is checked HERE, at the point of use, rather than on entry:
    # every step above is read-only and cancellable, so a missing scanner must
    # not stop the user from seeing what the flow would have done - and the
    # prompts stay exercisable when the scanner is absent.
    if (-not (Test-Path -LiteralPath $StatusScript -PathType Leaf)) {
        Write-ErrorLine ('The scanner is not available: ' + $StatusScript)
        Write-NoteLine '  Nothing was scanned, and nothing was written to the install registry.'
        Write-Log 'ERROR' 'STATUS' ('Scanner script missing: ' + $StatusScript)
        return 'done'
    }

    $resultPath = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-status-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
    $arguments = @{ ScanRoot = $scanRoot; ToolRoot = $ToolRoot; ResultPath = $resultPath }
    if ($includeGlobal) { $arguments.IncludeGlobal = $true }

    # Elapsed time is measured HERE rather than taken from the result document:
    # it is a property of this run, and it must still be reportable when the
    # scanner fails before it can write a document at all.
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $threw = ''
    try { & $StatusScript @arguments *> $null }
    catch { $threw = $_.Exception.Message }
    $stopwatch.Stop()

    $document = $null
    if (Test-Path -LiteralPath $resultPath) {
        try { $document = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json }
        catch { $document = $null }
        Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
    }
    if ($null -eq $document) {
        Write-ErrorLine 'The scan did not produce a readable result, so nothing can be reported.'
        if ($threw -ne '') { Write-NoteLine ('  Reason: ' + $threw) }
        Write-NoteLine '  Nothing was written to the install registry.'
        Write-Log 'ERROR' 'STATUS' ('Scan produced no readable result. ' + $threw)
        return 'done'
    }

    Show-HookStatusResult -Document $document -Elapsed $stopwatch.Elapsed
    return 'done'
}

# ---- result screen ---------------------------------------------------------
# Groups every finding, then prints the totals block. Kept separate from the
# prompt flow above so the rendering can be reasoned about (and changed) without
# touching the input stage machine.
function Show-HookStatusResult {
    param(
        [Parameter(Mandatory = $true)]$Document,
        [Parameter(Mandatory = $true)][TimeSpan]$Elapsed
    )

    $overall = Get-StatusText $Document 'overall' 'failed'
    Write-PhaseHeader 'Hook Status' $C.Summary '-'

    if ($overall -eq 'failed' -or $overall -eq 'canceled') {
        $word = if ($overall -eq 'canceled') { 'canceled' } else { 'failed' }
        Write-ErrorLine ('The scan ' + $word + '. Nothing was written to the install registry.')
        foreach ($problem in @(Get-StatusList $Document 'errors')) { Write-NoteLine ('    ' + [string]$problem) }
        Write-Log 'ERROR' 'STATUS' ('Scan ' + $word + '.')
        return
    }

    $findings = @(Get-StatusList $Document 'findings')
    $groups = @(
        [pscustomobject]@{ Key = 'managed'; Title = 'Hook Maker managed:' }
        [pscustomobject]@{ Key = 'externalClaude'; Title = 'External Claude registrations:' }
        [pscustomobject]@{ Key = 'externalCodex'; Title = 'External Codex registrations:' }
        [pscustomobject]@{ Key = 'nativeGit'; Title = 'Native Git hooks:' }
        [pscustomobject]@{ Key = 'ambiguous'; Title = 'Ambiguous / unparsed:' }
    )
    $anyShown = $false
    foreach ($group in $groups) {
        $members = @($findings | Where-Object { (Get-StatusGroupKey $_) -eq $group.Key })
        if ($members.Count -eq 0) { continue }
        $anyShown = $true
        Write-Host ''
        Write-MenuTitle $group.Title
        for ($i = 0; $i -lt $members.Count; $i++) {
            Write-StatusFinding ($i + 1) $members[$i]
        }
    }

    # Orphan runtime candidates are per-ARTIFACT, not per-hook: an installed
    # runtime copy nobody registers any more. They are only ever reported here -
    # this screen never deletes one.
    $orphans = New-Object System.Collections.Generic.List[object]
    foreach ($finding in $findings) {
        foreach ($artifact in @(Get-StatusList $finding 'runtimeArtifacts')) {
            if ((Get-StatusText $artifact 'classification' '') -eq 'orphanRuntimeCandidate') { [void]$orphans.Add($artifact) }
        }
    }
    if ($orphans.Count -gt 0) {
        $anyShown = $true
        Write-Host ''
        Write-MenuTitle 'Orphan runtime candidates:'
        for ($i = 0; $i -lt $orphans.Count; $i++) {
            $artifact = $orphans[$i]
            Write-Host ('  ' + (Get-Painted (([string]($i + 1)) + '.') $C.LightBlue) + ' ' + (Get-Painted (Get-StatusText $artifact 'path' '(unknown path)') $C.Bold))
            Write-Field '     kind' (Get-StatusText $artifact 'kind' '(unknown)')
            $eligibility = Get-StatusText $artifact 'deleteEligibility' 'preserve'
            $reason = Get-StatusText $artifact 'deleteReason' ''
            $eligibilityText = if ([string]::IsNullOrWhiteSpace($reason)) { $eligibility } else { $eligibility + ' - ' + $reason }
            $eligibilityColor = if ($eligibility -eq 'eligible') { $C.Amber } else { $C.Gray }
            Write-Field '     removal' $eligibilityText $eligibilityColor
        }
        Write-NoteLine '  Candidates are REPORTED only. Nothing here was deleted.'
    }

    # ---- coverage: inaccessible and skipped --------------------------------
    $coverage = Get-StatusValue $Document 'coverage' $null
    $inaccessible = @(Get-StatusList $coverage 'inaccessible')
    $skippedReparse = @(Get-StatusList $coverage 'skippedReparse')
    if ($inaccessible.Count -gt 0 -or $skippedReparse.Count -gt 0) {
        $anyShown = $true
        Write-Host ''
        Write-MenuTitle 'Inaccessible / skipped:'
        foreach ($path in $inaccessible) { Write-Host ('  ' + (Get-Painted 'not readable' $C.Red) + ' ' + [string]$path) }
        foreach ($path in $skippedReparse) { Write-Host ('  ' + (Get-Painted 'reparse point' $C.Amber) + ' ' + [string]$path) }
    }

    if (-not $anyShown) {
        Write-Host ''
        Write-NoteLine '  No hooks were detected under the scanned roots.'
    }

    # ---- totals -------------------------------------------------------------
    $counts = Get-StatusValue $Document 'counts' $null
    Write-Host ''
    Write-MenuTitle 'Totals:'
    Write-Field '  directories inspected' ([string](Get-StatusValue $counts 'directories' 0))
    Write-Field '  candidate settings files' ([string](Get-StatusValue $counts 'settingsFiles' 0))
    Write-Field '  candidate Git repositories' ([string](Get-StatusValue $counts 'gitRepositories' 0))
    Write-Field '  verified logical hooks' ([string](Get-StatusValue $counts 'logicalHooks' 0))
    Write-Field '  records added' ([string](Get-StatusValue $Document 'recordsAdded' 0))
    Write-Field '  records updated' ([string](Get-StatusValue $Document 'recordsUpdated' 0))
    Write-Field '  records matched' ([string](Get-StatusValue $Document 'recordsMatched' 0))
    Write-Field '  ambiguous findings' ([string](Get-StatusValue $counts 'ambiguous' 0))
    Write-Field '  inaccessible directories' ([string]$inaccessible.Count)
    Write-Field '  elapsed' ($Elapsed.ToString('hh\:mm\:ss\.fff'))
    Write-Field '  registry' (Get-StatusText $Document 'registryPath' '(not written)')

    # Partial coverage is stated plainly. Implying that every unreadable, system
    # or reparse-point directory was scanned would make an incomplete result
    # look like proof that nothing else is installed.
    $complete = (Get-StatusValue $coverage 'complete' $false) -eq $true
    if ($overall -eq 'partial' -or -not $complete) {
        Write-Host ''
        Write-NoteLine '  COVERAGE IS PARTIAL. This result does NOT prove that no other hooks exist.'
        # Only name a CAUSE that the result document actually evidences. When
        # both lists are empty the scan still reported incomplete coverage for a
        # reason it did not enumerate, and inventing one ("some directories
        # could not be read") would be a claim this screen cannot support.
        if ($inaccessible.Count -gt 0 -or $skippedReparse.Count -gt 0) {
            Write-NoteLine '  The paths listed above were unreadable or were reparse points that were not followed.'
        }
        else {
            Write-NoteLine '  The scan did not enumerate which parts were skipped.'
        }
    }
    foreach ($warning in @(Get-StatusList $Document 'warnings')) { Write-NoteLine ('  ' + [string]$warning) }

    Write-Log 'INFO' 'STATUS' ('Scan finished: overall=' + $overall + '; hooks=' + [string](Get-StatusValue $counts 'logicalHooks' 0) + '; added=' + [string](Get-StatusValue $Document 'recordsAdded' 0) + '; updated=' + [string](Get-StatusValue $Document 'recordsUpdated' 0) + '; complete=' + $complete)
}
