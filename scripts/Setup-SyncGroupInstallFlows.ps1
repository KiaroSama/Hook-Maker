# ---------------------------------------------------------------------------
# The create-or-install sub-menu's flows: installing one or more existing
# hooks (the main hook list with its management rows, event/client/target
# selection, and the per-hook install summary), installing every hook a
# profile config names, updating previously installed hooks, and the sub-menu
# that dispatches all four.
#
# Split out of Setup-SyncGroup.ps1 (which had grown past the file-size review
# signal) because this is the biggest cohesive block in the wizard: choosing
# what to install, invoking Install-Hook.ps1, and reporting what it actually
# did. That is distinct from rendering (Setup-SyncGroupPresentation.ps1), from
# hook authoring (Setup-SyncGroupCreateHook.ps1), and from listing/uninstalling
# what is already installed (Setup-SyncGroupInstalledHooks.ps1).
#
# Dot-sourced by Setup-SyncGroup.ps1 only. These functions rely on that
# script's ambient script-scope state and UI primitives ($C, $HooksDir,
# $InstallScript, $ConfigPath, $ToolRoot, $script:HookMeta, Write-PhaseHeader,
# Write-Field, Write-MenuLine, Write-MenuTitle, Write-ErrorLine,
# Write-NoteLine, Write-HookMenuLine, New-QuestionPrompt, Read-Answer,
# Read-YesNo, Read-ProjectList, Read-HookConfig, Read-HookEnv,
# Get-HookEntries, Get-HookRecommendedEvents, Get-ClientInstallArgs,
# Get-ClientInstallLabel, Get-HookTimeoutArgs, Write-Log) and on its sibling
# modules (Expand-MenuSelection, Invoke-CreateHook, Invoke-CreateGroup,
# Invoke-GetHookStatus, Invoke-UninstallInstalledHooks) - dot-sourcing splices
# these functions into the callers scope, and calls resolve at invocation
# time, so this is a normal one-directional dependency, not a layering
# violation.
# ---------------------------------------------------------------------------

# Install one or more existing hooks. A list/range (e.g. 2-5,8) selects several
# at once; for a batch you use each hook's recommended events with shared
# client/targets, or configure every hook independently. A precise summary then
# lists every hook's events/client/projects.
function Invoke-InstallExistingHook {
    Write-Log 'INFO' 'CUSTOM' 'Custom hook install started.'
    Write-PhaseHeader 'Install an Existing Hook' $C.Input '-'

    $hookFiles = @(Get-HookEntries)
    if ($hookFiles.Count -eq 0) {
        Write-ErrorLine ('No hooks found in: ' + $HooksDir)
        Write-NoteLine 'Create one first ("Create a new hook").'
        return 'back'
    }

    while ($true) {
        # ---- selection: a single number, comma list, or range ----
        # FIXED menu layout (the numbers are part of the documented UI):
        #   1                      Select all hooks (aggregate action)
        #   2                      the sync group (its own multi-project flow)
        #   3 .. 2+S               the S SHIPPED hooks, in $script:HookMeta.Order
        #   3+S                    Update installed hooks    (management action)
        #   4+S                    Get hook status           (management action)
        #   5+S                    Uninstall installed hooks (management action)
        #   6+S ..                 user-created/custom hooks, deterministic order
        # The THREE management rows are placed AFTER the shipped block and
        # BEFORE the custom block deliberately: discovering a new custom hook
        # under hooks\ must never shift the management rows, because those
        # numbers are documented UI. Every index below is derived from
        # $shippedHooks.Count - adding a shipped hook renumbers the management
        # rows, it never needs a hand-edited constant.
        #
        # Deliberately NOT restating a concrete rendering here. A worked example
        # ("with all N shipped hooks this renders as 3..M") is a snapshot of S,
        # and it silently rots every time a hook is added - it had already gone
        # stale by two hooks. The formula above is the specification; read S off
        # $shippedHooks.Count when you need the live numbers.
        $shippedHooks = @($hookFiles | Where-Object { $script:HookMeta.ContainsKey($_.Name) })
        $customHooks = @($hookFiles | Where-Object { -not $script:HookMeta.ContainsKey($_.Name) })
        $updateIndex = $shippedHooks.Count + 3
        $statusIndex = $shippedHooks.Count + 4
        $uninstallIndex = $shippedHooks.Count + 5
        $customStartIndex = $shippedHooks.Count + 6
        $maxIndex = $customStartIndex + $customHooks.Count - 1

        Write-MenuTitle 'Available hooks (hooks\):'
        Write-Host ('  ' + (Get-Painted '1.' $C.LightBlue) + ' ' + (Get-Painted 'Select all hooks' $C.Bold) + $script:MenuSep + (Get-Painted '[all]' $C.Orchid) + $script:MenuSep + (Get-Painted ('run the sync group (2) and install every hook below (3-' + ($shippedHooks.Count + $customHooks.Count + 2) + ')') $C.HintYellow))
        Write-Host ('  ' + (Get-Painted '2.' $C.LightBlue) + ' ' + (Get-Painted 'Create or update a sync group' $C.Bold) + $script:MenuSep + (Get-Painted '[pre-task]' $C.Mint) + $script:MenuSep + (Get-Painted 'cross-project .ai knowledge sync' $C.HintYellow))
        for ($i = 0; $i -lt $shippedHooks.Count; $i++) {
            Write-HookMenuLine ($i + 3) $shippedHooks[$i].Name
        }
        Write-Host ('  ' + (Get-Painted ([string]$updateIndex + '.') $C.LightBlue) + ' ' + (Get-Painted 'Update installed hooks' $C.Bold) + $script:MenuSep + (Get-Painted '[manage]' $C.Teal) + $script:MenuSep + (Get-Painted 'refresh installed copies from their current source' $C.HintYellow))
        Write-Host ('  ' + (Get-Painted ([string]$statusIndex + '.') $C.LightBlue) + ' ' + (Get-Painted 'Get hook status' $C.Bold) + $script:MenuSep + (Get-Painted '[manage]' $C.Teal) + $script:MenuSep + (Get-Painted 'scan a path, detect installed hooks, and track verified results' $C.HintYellow))
        Write-Host ('  ' + (Get-Painted ([string]$uninstallIndex + '.') $C.LightBlue) + ' ' + (Get-Painted 'Uninstall installed hooks' $C.Bold) + $script:MenuSep + (Get-Painted '[manage]' $C.Teal) + $script:MenuSep + (Get-Painted 'list and remove installed hooks; never deletes hook sources' $C.HintYellow))
        for ($i = 0; $i -lt $customHooks.Count; $i++) {
            Write-HookMenuLine ($customStartIndex + $i) $customHooks[$i].Name
        }
        Write-NoteLine ('  Tip: use lists and ranges, e.g. 3-8 (1 alone runs everything: the sync group AND every hook). ' + $updateIndex + '/' + $statusIndex + '/' + $uninstallIndex + ' are management actions - pick one on its own.')
        $value = Read-Answer (New-QuestionPrompt 'Select a hook (number, list, or range)' $null '2') 'select custom hook'
        if ($value -eq '0') { return 'back' }
        if ($value -eq '') { $value = '2' }

        # ONE canonical numeric-selection parser, shared with the installed-hook
        # screens (Setup-SyncGroupInstalledHooks.ps1) so list/range semantics can
        # never drift between the install and uninstall flows.
        $parsed = Expand-MenuSelection -Value $value -MaxIndex $maxIndex
        if (-not $parsed.Ok) {
            Write-ErrorLine $parsed.Reason
            continue
        }
        $indices = New-Object System.Collections.Generic.List[int]
        foreach ($idx in @($parsed.Indices)) { [void]$indices.Add($idx) }

        # The management rows are actions, not hook selections: mixing them with
        # hooks (or with each other) has no coherent meaning, so it is rejected
        # explicitly rather than silently doing half of what was typed.
        $managementPicked = @($indices | Where-Object { $_ -eq $updateIndex -or $_ -eq $statusIndex -or $_ -eq $uninstallIndex })
        if ($managementPicked.Count -gt 0) {
            if ($indices.Count -ne 1) {
                Write-ErrorLine ('Select ' + $updateIndex + ' (update), ' + $statusIndex + ' (status) or ' + $uninstallIndex + ' (uninstall) on its own - it cannot be combined with hook selections or with each other.')
                continue
            }
            if ($indices[0] -eq $updateIndex) {
                if ((Invoke-UpdateInstalledHooks) -eq 'done') { return 'done' }
                continue
            }
            if ($indices[0] -eq $statusIndex) {
                if ((Invoke-GetHookStatus) -eq 'done') { return 'done' }
                continue
            }
            if ((Invoke-UninstallInstalledHooks) -eq 'done') { return 'done' }
            continue
        }
        # "Select all hooks" (item 1) is an aggregate action, not a hook: it
        # means the COMPLETE former full-list flow - the sync group AND every
        # individual hook index (3..N+2), dynamically derived from
        # $hookFiles (never a hard-coded count) - unconditionally, without
        # needing "2" also typed explicitly. It rebuilds the selection in
        # canonical order so combining it with explicit picks (e.g. "1,5" or
        # "1,2") can never run the sync group twice or install a hook twice.
        # It never re-includes itself as a hook.
        # It never re-includes itself as a hook, and it never triggers any of the
        # three management rows (update/status/uninstall) - "install everything"
        # must not be able to scan or uninstall anything. The rebuilt list is
        # literally 2 + the shipped range + the custom range, so the management
        # indices between them are structurally unreachable from item 1.
        if ($indices.Contains(1)) {
            $indices = New-Object System.Collections.Generic.List[int]
            [void]$indices.Add(2)
            for ($i = 0; $i -lt $shippedHooks.Count; $i++) { [void]$indices.Add($i + 3) }
            for ($i = 0; $i -lt $customHooks.Count; $i++) { [void]$indices.Add($customStartIndex + $i) }
        }
        # The sync group (item 2) is its own multi-project flow, not a plain
        # hook install - it can't be gathered into the same events/client/
        # projects batch below. When it's selected alongside other hooks, run
        # its wizard first, then fall through and install the rest right after
        # (no need to re-enter this menu a second time).
        $ranSyncGroup = $false
        # Project paths collected by the sync group, reused as the install targets
        # for any other hooks picked in the same batch (entered once, not per hook).
        # Empty unless item 2 ran and published its projects.
        $sharedGroupProjects = @()
        if ($indices.Contains(2)) {
            [void]$indices.Remove(2)
            if ($indices.Count -gt 0) {
                Write-NoteLine ('  Running the sync group first, then installing ' + $indices.Count + ' more hook(s)...')
            }
            $groupResult = Invoke-CreateGroup
            if ($groupResult -eq 'back') { continue }
            if ($groupResult -eq 'canceled') { return 'done' }
            $ranSyncGroup = $true
            if ($indices.Count -eq 0) { return 'done' }
            $sharedGroupProjects = @($script:LastGroupProjects)
            if ($sharedGroupProjects.Count -gt 0) {
                Write-NoteLine ('  Reusing the same ' + $sharedGroupProjects.Count + ' project path(s) from the sync group for the remaining hook(s) - edit them at the summary if needed.')
            }
            Write-PhaseHeader 'Install an Existing Hook' $C.Input '-'
        }
        # Resolve each remaining index back to its hook. Shipped and custom hooks
        # live in two separate ranges either side of the fixed management rows,
        # so the index maths differs per range - a single flat offset would map
        # custom picks onto the wrong hook.
        $selected = @($indices | ForEach-Object {
            if ($_ -ge $customStartIndex) { $customHooks[$_ - $customStartIndex] } else { $shippedHooks[$_ - 3] }
        })
        Write-Log 'INFO' 'CUSTOM' ('Selected ' + $selected.Count + ' hook(s): ' + (($selected | ForEach-Object { $_.Name }) -join ', '))

        # ---- gather config (same for all, or per hook) ----
        $plans = $null
        $sharedTargets = $false
        if ($selected.Count -eq 1) {
            $cfg = Read-HookConfig -RecommendedEvents @(Get-HookRecommendedEvents $selected[0]) -InitialTargets $sharedGroupProjects
            if ($null -eq $cfg) { continue }
            $plans = @([pscustomobject]@{ Hook = $selected[0]; Config = $cfg })
        }
        else {
            $selectedNames = ($selected | ForEach-Object { Get-HookFriendlyName $_.Name }) -join ', '
            Write-Host ((Get-Painted ('Configuring ' + $selected.Count + ' hooks:') $C.Input) + ' ' + (Get-Painted $selectedNames $C.White))
            Write-Host ''
            Write-MenuLine 1 'Recommended events per hook / same client / projects' '(one set of target answers)'
            Write-MenuLine 2 'Configure each hook separately' '(ask per hook)'
            $mode = Read-Answer (New-QuestionPrompt 'How should they be configured?' $null '1') 'multi-hook config mode'
            if ($mode -eq '0') { continue }
            if ($mode -eq '') { $mode = '1' }
            if ($mode -eq '1') {
                $cfg = Read-HookConfig ' (all selected hooks)' -SkipEvents -InitialTargets $sharedGroupProjects
                if ($null -eq $cfg) { continue }
                $sharedTargets = $true
                $plans = @($selected | ForEach-Object {
                    $hookConfig = [pscustomobject]@{ Events = @(Get-HookRecommendedEvents $_); Clients = $cfg.Clients; Targets = @($cfg.Targets) }
                    [pscustomobject]@{ Hook = $_; Config = $hookConfig }
                })
            }
            elseif ($mode -eq '2') {
                $collected = New-Object System.Collections.Generic.List[object]
                $aborted = $false
                foreach ($h in $selected) {
                    $cfg = Read-HookConfig (' for ' + (Get-HookFriendlyName $h.Name)) -RecommendedEvents @(Get-HookRecommendedEvents $h) -InitialTargets $sharedGroupProjects
                    if ($null -eq $cfg) { $aborted = $true; break }
                    [void]$collected.Add([pscustomobject]@{ Hook = $h; Config = $cfg })
                }
                if ($aborted) { continue }
                $plans = $collected.ToArray()
            }
            else {
                Write-ErrorLine 'Enter 1, 2 or 0.'
                continue
            }
        }

        # ---- summary ----
        while ($true) {
            Write-PhaseHeader 'Summary' $C.Summary '-'
            for ($i = 0; $i -lt $plans.Count; $i++) {
                $plan = $plans[$i]
                Write-MenuLine ($i + 1) (Get-HookFriendlyName $plan.Hook.Name)
                Write-Field '     events' ($plan.Config.Events -join ', ')
                Write-Field '     client' $plan.Config.Clients
                Write-Field '     projects' (@($plan.Config.Targets | ForEach-Object { $_.Name }) -join ', ')
            }
            Write-Host ''
            Write-Field 'install' 'self-contained copy per project (.claude/.codex hooks\Hook-Maker\<name>\)'
            Write-PhaseHeader 'Confirm' $C.Confirm '-'
            $confirm = Read-YesNo (New-QuestionPrompt 'Start now?' 'y/n' 'y') $true 'start multi hook install'
            if ($null -eq $confirm) {
                $lastPlan = $plans[$plans.Count - 1]
                $editedTargets = Read-ProjectList -MinimumCount 1 -InitialProjects @($lastPlan.Config.Targets)
                if ($null -eq $editedTargets) { continue }
                if ($sharedTargets) {
                    foreach ($plan in $plans) { $plan.Config.Targets = @($editedTargets) }
                }
                else {
                    $lastPlan.Config.Targets = @($editedTargets)
                }
                continue
            }
            if ($confirm -ne $true) {
                if ($ranSyncGroup) {
                    Write-NoteLine 'Canceled. The sync group was applied; the remaining hook(s) were not installed.'
                }
                else {
                    Write-NoteLine 'Canceled. Nothing was installed.'
                }
                Write-Log 'INFO' 'CUSTOM' 'User declined at confirmation; no install.'
                return 'done'
            }
            break
        }

        # ---- install ----
        Write-PhaseHeader 'Applying Changes' $C.Process '-'
        foreach ($plan in $plans) {
            $clientArgs = Get-ClientInstallArgs $plan.Config.Clients
            $timeoutArgs = Get-HookTimeoutArgs $plan.Hook.Name
            foreach ($target in $plan.Config.Targets) {
                $installOutput = & $InstallScript -CustomHook $plan.Hook.ScriptPath -Events @($plan.Config.Events) -TargetProject $target.Root @clientArgs @timeoutArgs *>&1
                foreach ($line in @($installOutput)) { Write-Log 'INFO' 'INSTALL' ([string]$line) }
                Write-Host ('  ' + (Get-Painted '+ installed' $C.Green) + ' ' + (Get-Painted (Get-HookFriendlyName $plan.Hook.Name) $C.Bold) + ' -> ' + (Get-Painted $target.Name $C.Bold) + '  ' + (Get-Painted ('(' + $plan.Config.Clients + ', ' + ($plan.Config.Events -join '+') + ')') $C.Gray))
            }
            Write-Log 'INFO' 'INSTALL' ('Installed ' + $plan.Hook.Name + ' | client=' + $plan.Config.Clients + ' | events=' + ($plan.Config.Events -join ',') + ' | projects=' + $plan.Config.Targets.Count)
        }
        Write-PhaseHeader 'Completed' $C.Done '='
        $doneMsg = if ($ranSyncGroup) { '  Sync group + ' + $plans.Count + ' hook(s) installed.' } else { '  Installed ' + $plans.Count + ' hook(s).' }
        Write-Host (Get-Painted ($doneMsg + ' Restart the Claude/Codex clients and review /hooks inside each project.') $C.White)
        Write-NoteLine '  Codex: run /hooks in each project and trust the new command before it runs.'
        Write-Log 'INFO' 'DONE' ('Multi-hook install complete: ' + $plans.Count + ' hook(s)' + $(if ($ranSyncGroup) { ' + sync group' } else { '' }) + '.')
        return 'done'
    }
}

# Install an existing hook using its .env (EVENTS + TARGET_PROJECTS): no
# questions besides the hook selection and one confirm.
function Invoke-InstallHookFromConfig {
    Write-Log 'INFO' 'CUSTOM' 'Config-based hook install started.'
    Write-PhaseHeader 'Install From Config (.env)' $C.Input '-'

    $hookFiles = @(Get-HookEntries | Where-Object { $_.EnvPath -ne '' })
    if ($hookFiles.Count -eq 0) {
        Write-ErrorLine ('No hooks found in: ' + $HooksDir)
        return 'back'
    }

    while ($true) {
        Write-MenuTitle 'Available hooks (hooks\):'
        for ($i = 0; $i -lt $hookFiles.Count; $i++) {
            $envState = '(no .env yet)'
            if (Test-Path -LiteralPath $hookFiles[$i].EnvPath -PathType Leaf) {
                $envState = '(.env found)'
            }
            Write-HookMenuLine ($i + 1) $hookFiles[$i].Name $envState
        }
        $value = Read-Answer (New-QuestionPrompt 'Select a hook' $null '1') 'select hook for config install'
        if ($value -eq '0') {
            return 'back'
        }
        if ($value -eq '') {
            $value = '1'
        }
        $index = 0
        if (-not ([int]::TryParse($value, [ref]$index) -and $index -ge 1 -and $index -le $hookFiles.Count)) {
            Write-ErrorLine ('Enter a number between 1 and ' + $hookFiles.Count + '.')
            continue
        }
        $hook = $hookFiles[$index - 1]

        if (-not (Test-Path -LiteralPath $hook.EnvPath -PathType Leaf)) {
            Write-ErrorLine ('No .env found for ' + $hook.Name + '.')
            Write-NoteLine ('Copy ' + (Join-Path (Split-Path -Parent $hook.EnvPath) '.env.example') + ' to .env and fill TARGET_PROJECTS.')
            continue
        }
        $envValues = Read-HookEnv $hook.EnvPath

        $events = @('SessionStart', 'UserPromptSubmit')
        if ($envValues.ContainsKey('EVENTS') -and $envValues['EVENTS'] -ne '') {
            $events = @($envValues['EVENTS'].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        }
        # FAILS CLOSED. This used to print a note and fall through with
        # $clients still 'Both', so a typo such as CLIENTS=Cluade installed for
        # MORE clients than the config asked for - the one outcome a
        # client-restricting setting must never produce. Validity now comes from
        # the canonical capability table, and anything it does not recognise
        # skips this hook with nothing written.
        $clients = 'Both'
        if ($envValues.ContainsKey('CLIENTS') -and $envValues['CLIENTS'] -ne '') {
            $clientSet = $null
            try { $clientSet = @(Resolve-HookMakerClientSet $envValues['CLIENTS']) }
            catch {
                Write-ErrorLine ('Unknown CLIENTS value "' + $envValues['CLIENTS'] + '" in ' + $hook.EnvPath + '.')
                Write-NoteLine ('Accepted: Claude, Codex, Both (= Claude + Codex). Nothing was installed for ' + $hook.Name + '.')
                Write-Log 'WARNING' 'CONFIG' ('Rejected unknown CLIENTS value for ' + $hook.Name + ' - nothing installed')
                continue
            }
            # Resolvable but not yet installable through this flow: the
            # -ClaudeOnly/-CodexOnly switches are consumed as double negations,
            # so a third client cannot be expressed here until the positive
            # -Clients set replaces them. Rejecting is correct - accepting would
            # silently install nothing for the client that was asked for.
            $notWired = @($clientSet | Where-Object { $_ -ne 'claude' -and $_ -ne 'codex' })
            if ($notWired.Count -gt 0) {
                Write-ErrorLine ('CLIENTS value "' + $envValues['CLIENTS'] + '" names a client this config flow cannot install yet: ' + ($notWired -join ', ') + '.')
                Write-NoteLine ('Nothing was installed for ' + $hook.Name + '. Use the interactive install flow for that client.')
                continue
            }
            if ($clientSet.Count -eq 1 -and $clientSet[0] -eq 'claude') { $clients = 'Claude' }
            elseif ($clientSet.Count -eq 1 -and $clientSet[0] -eq 'codex') { $clients = 'Codex' }
            else { $clients = 'Both' }
        }
        $targetsRaw = ''
        if ($envValues.ContainsKey('TARGET_PROJECTS')) {
            $targetsRaw = $envValues['TARGET_PROJECTS']
        }
        $targetPaths = @($targetsRaw.Split(';') | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ -ne '' })
        if ($targetPaths.Count -eq 0) {
            Write-ErrorLine ('TARGET_PROJECTS is empty in ' + $hook.EnvPath + '.')
            Write-NoteLine 'Fill it with semicolon-separated project roots and retry.'
            continue
        }
        $targets = New-Object System.Collections.Generic.List[object]
        $invalid = $false
        foreach ($path in $targetPaths) {
            try {
                $root = Normalize-Path $path
            }
            catch {
                Write-ErrorLine ('Invalid path in TARGET_PROJECTS: ' + $path)
                $invalid = $true
                break
            }
            if (-not (Test-Path -LiteralPath $root -PathType Container)) {
                Write-ErrorLine ('Directory not found (from TARGET_PROJECTS): ' + $root)
                $invalid = $true
                break
            }
            [void]$targets.Add([pscustomobject]@{ Name = (Split-Path -Leaf $root); Root = $root })
        }
        if ($invalid) {
            continue
        }

        # ---- summary + confirm ----
        Write-PhaseHeader 'Summary' $C.Summary '-'
        Write-Field 'hook script' $hook.ScriptPath $C.LightBlue
        Write-Field 'config' $hook.EnvPath $C.LightBlue
        Write-Field 'events' ($events -join ', ')
        Write-Field 'client' $clients
        Write-Field 'install' (Get-ClientInstallLabel $clients)
        Write-MenuTitle 'Target projects (from .env):'
        for ($i = 0; $i -lt $targets.Count; $i++) {
            Write-MenuLine ($i + 1) $targets[$i].Name $targets[$i].Root
        }
        Write-PhaseHeader 'Confirm' $C.Confirm '-'
        $confirm = Read-YesNo (New-QuestionPrompt 'Start now?' 'y/n' 'y') $true 'start config install'
        if ($null -eq $confirm) {
            continue
        }
        if ($confirm -ne $true) {
            Write-NoteLine 'Canceled. Nothing was installed.'
            return 'done'
        }

        Write-PhaseHeader 'Applying Changes' $C.Process '-'
        $clientArgs = Get-ClientInstallArgs $clients
        $timeoutArgs = Get-HookTimeoutArgs $hook.Name
        foreach ($target in $targets) {
            $installOutput = & $InstallScript -CustomHook $hook.ScriptPath -Events @($events) -TargetProject $target.Root @clientArgs @timeoutArgs *>&1
            foreach ($line in @($installOutput)) {
                Write-Log 'INFO' 'INSTALL' ([string]$line)
            }
            Write-Host ('  ' + (Get-Painted '+ hook installed in' $C.Green) + ' ' + (Get-Painted $target.Name $C.Bold) + '  ' + (Get-Painted $target.Root $C.Gray))
        }
        Write-PhaseHeader 'Completed' $C.Done '='
        Write-Host (Get-Painted ('  ' + $hook.Name + ' installed for: ' + ($events -join ', ') + ' (' + $clients + ')') $C.White)
        Write-Host (Get-Painted '  Restart the Claude/Codex clients and review /hooks inside each project.' $C.White)
        Write-NoteLine '  Codex: run /hooks in each project and trust the new command before it runs.'
        Write-Log 'INFO' 'DONE' ('Config install: ' + $hook.ScriptPath + ' | events=' + ($events -join ',') + ' | clients=' + $clients + ' | projects=' + $targets.Count)
        return 'done'
    }
}


# Refreshes every valid tracked (or newly-discovered legacy) installation
# whose managed runtime no longer matches current source, reusing each
# record's saved parameters - a correct reinstall without re-asking any
# configuration question. Missing source/target/profile are reported and
# skipped, never destructively touched. One confirmation for the whole batch.
# Safe field read for registry records shown in the update plan. A malformed
# record must be DISPLAYABLE (so the user can see what needs manual repair)
# without StrictMode throwing on its missing properties.
function Get-RecordDisplayField {
    param($Record, [string]$Name, [string]$Fallback = '(unknown)')
    if ($null -eq $Record) { return $Fallback }
    if ($null -eq $Record.PSObject.Properties[$Name]) { return $Fallback }
    $value = [string]$Record.$Name
    if ([string]::IsNullOrWhiteSpace($value)) { return $Fallback }
    return $value
}

function Invoke-UpdateInstalledHooks {
    Write-Log 'INFO' 'UPDATE' 'Update previously installed hooks started.'
    Write-PhaseHeader 'Update Previously Installed Hooks' $C.Input '-'

    # A corrupt registry must never read back as a quiet "nothing tracked" -
    # that would hide real installations and let the summary imply everything
    # is fine. Report it loudly; the file itself is left untouched here (only
    # a real install quarantines and recovers it).
    $registryState = Read-InstallRegistryState -ToolRoot $ToolRoot
    if ($registryState.State -eq 'corrupt') {
        Write-NoteLine ('  WARNING: the install registry could not be used: ' + $registryState.Reason)
        Write-NoteLine ('  File: ' + $registryState.Path)
        Write-NoteLine '  Tracked installations cannot be listed or verified until it is repaired. It has NOT been modified or deleted.'
        Write-NoteLine '  Reinstalling any hook will preserve the unreadable file under a "install-registry.corrupt-<timestamp>-<hash>.json" name and start a new registry.'
        Write-Log 'ERROR' 'UPDATE' ('Registry unusable: ' + $registryState.Reason)
        return 'done'
    }
    $registry = Read-InstallRegistry -ToolRoot $ToolRoot
    $legacyCandidates = @(Get-LegacyHookCandidates -Registry $registry -ToolRoot $ToolRoot -HooksDir $HooksDir -ConfigPath $ConfigPath)
    $allRecords = @(@($registry.installs) + @($legacyCandidates))

    if ($allRecords.Count -eq 0) {
        Write-NoteLine '  No previously installed hooks are tracked yet, and none were found in the current project, the global scope, or projects referenced by the sync config.'
        Write-NoteLine '  Install a hook once (any method) to start tracking it; a hook installed in another, unreferenced project must be reinstalled once there to enter the registry.'
        Write-Log 'INFO' 'UPDATE' 'No tracked or discoverable installs.'
        return 'back'
    }

    # ---- evaluate each record: up to date / needs update / skip reason ----
    $plan = New-Object System.Collections.Generic.List[object]
    # PER-RECORD ISOLATION. Every record is validated before any of its fields
    # are read, and its whole evaluation runs inside try/catch. Under StrictMode
    # a single malformed record (e.g. one missing sourceScript) previously threw
    # and aborted the entire run, so every healthy record after it was never
    # evaluated. A bad record is now an isolated, precisely-reported entry and
    # nothing about it is modified or guessed at.
    foreach ($record in $allRecords) {
        $status = ''
        $components = @()
        $detail = ''
        try {
            $validation = Test-InstallRecordValid -Record $record
            if (-not $validation.Ok) {
                $status = 'skip'; $detail = 'invalid registry record (manual repair): ' + $validation.Reason
            }
            elseif (-not (Test-Path -LiteralPath $record.sourceScript -PathType Leaf)) {
                $status = 'skip'; $detail = 'source script no longer found: ' + $record.sourceScript
            }
            elseif (($record.scope -ne 'global') -and -not (Test-Path -LiteralPath $record.targetProjectRoot -PathType Container)) {
                $status = 'skip'; $detail = 'target project no longer found: ' + $record.targetProjectRoot
            }
            elseif ($record.hookType -eq 'Engine' -and -not (Test-Path -LiteralPath $record.configPath -PathType Leaf)) {
                $status = 'skip'; $detail = 'sync config no longer found: ' + $record.configPath
            }
            elseif ($record.hookType -eq 'Engine') {
                $engineConfig = Read-JsonFile $record.configPath
                $profileExists = ($null -ne $engineConfig) -and ($null -ne $engineConfig.PSObject.Properties['profiles']) -and (@($engineConfig.profiles | Where-Object { [string]$_.id -eq [string]$record.profile }).Count -gt 0)
                if (-not $profileExists) { $status = 'skip'; $detail = 'profile no longer exists in the sync config: ' + $record.profile }
            }
            if ($status -eq '') {
                $evaluation = Get-InstallIntegrity -Record $record -ToolRoot $ToolRoot
                $status = $evaluation.Status
                $detail = $evaluation.Detail
                # Per-component breakdown drives targeted repair below.
                if ($null -ne $evaluation.PSObject.Properties['Components']) { $components = @($evaluation.Components) }
            }
        }
        catch {
            # Never let one record's failure end the run.
            $status = 'skip'
            $detail = 'could not evaluate this record (manual repair): ' + $_.Exception.Message
        }
        [void]$plan.Add([pscustomobject]@{ Record = $record; Status = $status; Detail = $detail; Components = $components })
    }

    Write-MenuTitle 'Plan:'
    for ($i = 0; $i -lt $plan.Count; $i++) {
        $item = $plan[$i]
        $scopeText = if ((Get-RecordDisplayField $item.Record 'scope') -eq 'global') { 'global' } else { Get-RecordDisplayField $item.Record 'targetProjectRoot' }
        $color = switch ($item.Status) { 'update' { $C.Amber }; 'skip' { $C.Red }; default { $C.Mint } }
        Write-Host ('  ' + (Get-Painted (($i + 1).ToString() + '.') $C.LightBlue) + ' ' + (Get-Painted (Get-HookFriendlyName (Get-RecordDisplayField $item.Record 'friendlyName' 'unknown-record')) $C.Bold) + $script:MenuSep + (Get-Painted $scopeText $C.Gray) + $script:MenuSep + (Get-Painted $item.Detail $color))
    }
    $toUpdate = @($plan | Where-Object { $_.Status -eq 'update' })
    $toSkip = @($plan | Where-Object { $_.Status -eq 'skip' })
    $current = @($plan | Where-Object { $_.Status -eq 'current' })
    Write-Host ''
    Write-Field 'already up to date' $current.Count.ToString()
    Write-Field 'will be updated' $toUpdate.Count.ToString()
    Write-Field 'skipped (missing source/target/profile)' $toSkip.Count.ToString()
    Write-Log 'INFO' 'UPDATE' ('Plan built: total=' + $allRecords.Count + ' current=' + $current.Count + ' update=' + $toUpdate.Count + ' skip=' + $toSkip.Count)

    if ($toUpdate.Count -eq 0) {
        Write-NoteLine '  Nothing to update - every valid tracked installation already matches the current source.'
        if ($toSkip.Count -gt 0) {
            Write-NoteLine '  Skipped (review and reinstall manually if still needed):'
            foreach ($item in $toSkip) { Write-NoteLine ('    ' + (Get-HookFriendlyName (Get-RecordDisplayField $item.Record 'friendlyName' 'unknown-record')) + ' - ' + $item.Detail) }
        }
        return 'done'
    }

    Write-PhaseHeader 'Confirm' $C.Confirm '-'
    $confirm = Read-YesNo (New-QuestionPrompt ('Update ' + $toUpdate.Count + ' installed hook(s) now?') 'y/n' 'y') $true 'confirm update installed hooks'
    if ($null -eq $confirm -or $confirm -ne $true) {
        Write-NoteLine 'Canceled. Nothing was changed.'
        Write-Log 'INFO' 'UPDATE' 'User declined at confirmation; no changes applied.'
        return 'done'
    }

    Write-PhaseHeader 'Applying Changes' $C.Process '-'
    $updated = New-Object System.Collections.Generic.List[string]
    $failed = New-Object System.Collections.Generic.List[string]
    foreach ($item in $toUpdate) {
        $record = $item.Record
        $displayName = Get-HookFriendlyName $record.friendlyName
        $scopeText = if ($record.scope -eq 'global') { 'global' } else { $record.targetProjectRoot }

        # Repair EACH client separately with that client's own saved events.
        # A single shared invocation would force one client's semantics onto
        # the other whenever they differ (Claude on SessionStart, Codex on
        # Stop is a legitimate, supported combination).
        $clientsToRepair = @(Get-InstalledClientNames -Record $record)
        if ($clientsToRepair.Count -eq 0 -and $null -ne $record.PSObject.Properties['imported'] -and $record.imported -eq $true) {
            # A legacy import records the clients it actually found live.
            $clientsToRepair = @($record.importedClients)
        }
        $clientResults = New-Object System.Collections.Generic.List[string]
        $clientResultsSkipped = New-Object System.Collections.Generic.List[string]
        # COMPONENT-LEVEL REPAIR: reinstall only the clients the integrity check
        # actually reported as damaged. Reinstalling a healthy client would
        # rewrite its settings file, add another timestamped backup and bump its
        # runtime mtimes for no reason. A changed SOURCE is a shared dependency,
        # so the integrity check already marks every client damaged in that case
        # and they are all repaired together.
        if ($null -ne $item.PSObject.Properties['Components'] -and $null -ne $item.Components) {
            $damagedClients = @(@($item.Components) |
                Where-Object { $_.Status -eq 'update' -and $_.Name -ne 'source' -and $_.Name -ne 'nativeGit' } |
                ForEach-Object { [string]$_.Name })
            if ($damagedClients.Count -gt 0) {
                $healthy = @($clientsToRepair | Where-Object { $damagedClients -notcontains $_ })
                $clientsToRepair = @($clientsToRepair | Where-Object { $damagedClients -contains $_ })
                foreach ($untouched in $healthy) {
                    [void]$clientResultsSkipped.Add($untouched + ': already current (left untouched)')
                }
            }
        }
        $anyFailed = $false
        foreach ($client in $clientsToRepair) {
            $events = @()
            $subrecord = Get-ClientSubrecord -Record $record -Client $client
            if ($null -ne $subrecord) { $events = @($subrecord.events) }
            elseif ($null -ne $record.PSObject.Properties['events']) { $events = @($record.events) }
            if (@($events).Count -eq 0) {
                $anyFailed = $true
                [void]$clientResults.Add($client + ': no recorded events')
                continue
            }
            $installArgs = @{ Events = @($events) }
            if ($record.scope -eq 'project') { $installArgs['TargetProject'] = $record.targetProjectRoot }
            if ($record.hookType -eq 'Engine') {
                $installArgs['Profile'] = $record.profile
                $installArgs['ConfigPath'] = $record.configPath
            }
            else {
                $installArgs['CustomHook'] = $record.sourceScript
            }
            $clientArgs = if ($client -eq 'claude') { @{ ClaudeOnly = $true } } else { @{ CodexOnly = $true } }
            try {
                # STRUCTURED OUTCOME: the installer writes a machine-readable
                # result document. Success is read from that, never inferred
                # from console text or from "no exception was thrown" - an
                # install whose runtime and settings landed but whose tracking
                # failed must not be reported as fully updated.
                $resultFile = Join-Path ([System.IO.Path]::GetTempPath()) ('hookmaker-install-result-' + [guid]::NewGuid().ToString('N').Substring(0, 10) + '.json')
                $installArgs['ResultPath'] = $resultFile
                $installOutput = & $InstallScript @installArgs @clientArgs *>&1
                foreach ($line in @($installOutput)) { Write-Log 'INFO' 'INSTALL' ([string]$line) }
                $installResult = $null
                if (Test-Path -LiteralPath $resultFile -PathType Leaf) {
                    try { $installResult = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json } catch { $installResult = $null }
                    Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue
                }
                if ($null -eq $installResult) {
                    $anyFailed = $true
                    [void]$clientResults.Add($client + ': no structured result from the installer')
                }
                elseif ([string]$installResult.overall -eq 'failed') {
                    $anyFailed = $true
                    $failedNames = @(@($installResult.components) | Where-Object { $_.status -eq 'failed' } | ForEach-Object { [string]$_.component })
                    [void]$clientResults.Add($client + ': failed (' + ($failedNames -join ', ') + ')')
                }
                elseif ([string]$installResult.overall -eq 'partial') {
                    # Runtime/settings applied but tracking did not - report it
                    # honestly rather than calling the hook updated.
                    $anyFailed = $true
                    [void]$clientResults.Add($client + ': installed but tracking failed - reinstall to restore tracking')
                }
                else {
                    [void]$clientResults.Add($client + ': ok')
                }
            }
            catch {
                $anyFailed = $true
                [void]$clientResults.Add($client + ': ' + $_.Exception.Message)
                Write-Log 'ERROR' 'UPDATE' ('Failed to update ' + $record.friendlyName + ' for ' + $client + ': ' + $_.Exception.Message)
            }
        }

        # INDEPENDENT RE-VERIFICATION. The installer reporting success is not
        # sufficient evidence that the installation is now intact, so the
        # record is re-read and integrity re-evaluated before anything is
        # called "updated". Combined with the installer's structured result
        # (which distinguishes "installed but tracking failed" from success),
        # this is what stops a nominal success from being reported as a real one.
        if (-not $anyFailed) {
            try {
                $verifyRecord = Get-InstallRecordById -ToolRoot $ToolRoot -Id ([string]$record.id)
                if ($null -eq $verifyRecord) {
                    $anyFailed = $true
                    [void]$clientResults.Add('post-update verification: the installation is no longer tracked')
                }
                else {
                    $verifyResult = Get-InstallIntegrity -Record $verifyRecord -ToolRoot $ToolRoot
                    if ($verifyResult.Status -ne 'current') {
                        $anyFailed = $true
                        [void]$clientResults.Add('post-update verification: ' + $verifyResult.Detail)
                    }
                }
            }
            catch {
                $anyFailed = $true
                [void]$clientResults.Add('post-update verification failed: ' + $_.Exception.Message)
            }
        }

        if ($anyFailed) {
            [void]$failed.Add($displayName + ': ' + ($clientResults -join '; '))
            Write-Host ('  ' + (Get-Painted '! failed  ' $C.Red) + ' ' + (Get-Painted $displayName $C.Bold) + '  ' + (Get-Painted ($clientResults -join '; ') $C.Gray))
        }
        else {
            [void]$updated.Add($displayName)
            # Name the components actually repaired, and say plainly which were
            # left alone - "updated" must not imply every client was rewritten.
            $repairedText = if ($clientsToRepair.Count -gt 0) { $clientsToRepair -join ', ' } else { 'no client needed repair' }
            $untouchedText = ''
            if ($clientResultsSkipped.Count -gt 0) {
                $untouchedText = $script:MenuSep + 'untouched: ' + (@($clientResultsSkipped | ForEach-Object { ($_ -split ':')[0] }) -join ', ')
            }
            Write-Host ('  ' + (Get-Painted '+ updated' $C.Green) + ' ' + (Get-Painted $displayName $C.Bold) + '  ' + (Get-Painted ($scopeText + $script:MenuSep + $repairedText + $untouchedText) $C.Gray))
        }
    }

    Write-PhaseHeader 'Completed' $C.Done '='
    Write-Host (Get-Painted ('  Updated ' + $updated.Count + ' of ' + $toUpdate.Count + ' hook(s).') $C.White)
    if ($failed.Count -gt 0) {
        Write-ErrorLine ('  ' + $failed.Count + ' failed:')
        foreach ($f in $failed) { Write-NoteLine ('    ' + $f) }
    }
    if ($toSkip.Count -gt 0) {
        Write-NoteLine ('  ' + $toSkip.Count + ' skipped (missing source/target/profile) - review and reinstall manually if still needed:')
        foreach ($item in $toSkip) { Write-NoteLine ('    ' + (Get-HookFriendlyName (Get-RecordDisplayField $item.Record 'friendlyName' 'unknown-record')) + ' - ' + $item.Detail) }
    }
    Write-NoteLine '  Restart the Claude/Codex clients and review /hooks inside each affected project.'
    Write-Log 'INFO' 'DONE' ('Update installed hooks complete: updated=' + $updated.Count + ' failed=' + $failed.Count + ' skipped=' + $toSkip.Count + ' current=' + $current.Count)
    return 'done'
}

# The "Create or install a hook" sub-menu: create a new hook, install an
# existing one (item 1 of that list selects every individual hook at once,
# item 2 is the sync group), install from config, or update previously
# installed hooks (refresh existing installs from current source, no re-ask).
# Loops so that backing out of a sub-flow returns HERE (one step), not to the
# main menu. Returns 'done' after a completed sub-flow, or when the user backs
# out of this sub-menu.
function Invoke-CustomHookMenu {
    while ($true) {
        Write-PhaseHeader 'Create or Install a Hook' $C.Input '-'
        Write-MenuTitle 'Options:'
        Write-MenuLine 1 'Install an existing hook' '(sync group + hooks\ - interactive)'
        Write-MenuLine 2 'Create a new hook' '(guided templates)'
        Write-MenuLine 3 'Install from config' '(reads the hook''s .env - no questions)'
        # COMPATIBILITY ALIAS ONLY. The canonical, documented home for updating
        # installed hooks is the "Update installed hooks" management row in the
        # "Available hooks" list (followed there by hook status and uninstall).
        # That row's NUMBER moves whenever a shipped hook is added, so it is
        # derived here rather than written out - the alias may never claim a
        # stale index. This row is kept so existing muscle memory and scripted
        # answer sequences keep working - it calls exactly the same
        # Invoke-UpdateInstalledHooks implementation, never a second copy.
        $aliasUpdateIndex = @(@(Get-HookEntries) | Where-Object { $script:HookMeta.ContainsKey($_.Name) }).Count + 3
        Write-MenuLine 4 'Update installed hooks' ('(same as item ' + $aliasUpdateIndex + ' in the hook list)')
        $value = Read-Answer (New-QuestionPrompt 'Select an option' $null '1') 'custom hook menu'
        if ($value -eq '0') {
            Write-Log 'INFO' 'MENU' 'Create-or-install sub-menu -> 0. Back'
            return
        }
        if ($value -eq '') {
            $value = '1'
        }
        $subAction = @{ '1' = 'Install an existing hook'; '2' = 'Create a new hook'; '3' = 'Install from config'; '4' = 'Update previously installed hooks' }[$value]
        if ($subAction) { Write-Log 'INFO' 'MENU' ('Create-or-install sub-menu -> ' + $value + '. ' + $subAction) }
        switch ($value) {
            '1' { if ((Invoke-InstallExistingHook) -eq 'done') { return } }
            '2' { if ((Invoke-CreateHook) -eq 'done') { return } }
            '3' { if ((Invoke-InstallHookFromConfig) -eq 'done') { return } }
            '4' { if ((Invoke-UpdateInstalledHooks) -eq 'done') { return } }
            default { Write-ErrorLine 'Enter 1, 2, 3, 4 or 0.' }
        }
    }
}

