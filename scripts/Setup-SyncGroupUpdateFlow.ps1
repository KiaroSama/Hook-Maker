# ---------------------------------------------------------------------------
# The UPDATE flow: refreshing installations that already exist, rather than
# creating one. It reuses each registry record's saved parameters, so it asks
# no configuration question at all - which is exactly what makes it a different
# job from the install flows beside it, and why it is its own file.
#
# Split out of Setup-SyncGroupInstallFlows.ps1 at the 800-line ceiling. The
# display-field reader below travels with it: it exists so a malformed record
# can still be SHOWN in the update plan without StrictMode throwing, and
# nothing else reads a record that way.
#
# Dot-sourced by Setup-SyncGroupInstallFlows.ps1 in the position the block
# occupied. Like that file, these functions rely on the wizard's ambient
# script-scope state and UI primitives, resolved at call time.
# ---------------------------------------------------------------------------


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

# What a `partial` install result actually means for the user.
#
# 'partial' covers three different outcomes: tracking failed, one component
# failed while another landed, or a component installed with REDUCED CAPABILITY
# (a client drops events it has no documented trigger for, or cannot gate Stop).
#
# Only the first two are failures. `degraded` is a client stating what it does
# not support: permanent, documented, and identical on every future run.
# Counting it as a failure made a clean update impossible to reach - a real
# 572-record run reported failed=21 in which every single one was a component
# reporting "partial - (degraded)" for that reason. A failure count that
# can never be zero hides the failures that matter, which is the opposite of
# what it is for.
#
# A component that is BOTH a real problem and degraded is a real problem: the
# reduced capability is reported alongside, never instead.
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
    # PER-RECORD ISOLATION lives in Get-RecordUpdateState: every record is
    # validated before any of its fields are read, and its whole evaluation runs
    # inside try/catch. Under StrictMode a single malformed record (e.g. one
    # missing sourceScript) previously threw and aborted the entire run, so
    # every healthy record after it was never evaluated. A bad record is an
    # isolated, precisely-reported entry and nothing about it is guessed at.
    #
    # The evaluation is read-only, so it is spread across a bounded runspace
    # pool. A 627-record registry took ~2 minutes to evaluate in one thread.
    $evaluationTimer = [System.Diagnostics.Stopwatch]::StartNew()
    Write-NoteLine ('  Evaluating ' + $allRecords.Count + ' tracked installation(s)...')
    $plan = Get-UpdateEvaluationPlan -Records $allRecords -ToolRoot $ToolRoot
    $evaluationTimer.Stop()
    Write-Log 'INFO' 'UPDATE' ('Evaluated ' + $allRecords.Count + ' record(s) in ' +
        $evaluationTimer.Elapsed.TotalSeconds.ToString('N1') + 's using ' +
        (Get-UpdateEvaluationWorkerCount) + ' worker(s).')

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
            # F11. The recorded binding is reused UNCHANGED - the historical
            # behaviour - unless it is provably a RETIRED SHIPPED DEFAULT, in
            # which case the update also moves it to the current one. A custom
            # or hand-edited binding is reported here and never rewritten; the
            # whole judgement lives in scripts\_installeventmigration.ps1.
            $eventPlan = Resolve-UpdateEventsForClient -Record $record -Client $client
            if ($eventPlan.Note -ne '') { [void]$clientResults.Add($client + ': ' + $eventPlan.Note); Write-NoteLine ('    ' + $displayName + ' / ' + $client + ': ' + $eventPlan.Note); Write-Log 'INFO' 'UPDATE' ($displayName + ' / ' + $client + ': ' + $eventPlan.Note) }
            if (@($eventPlan.Events).Count -eq 0) { $anyFailed = $true; continue }
            $installArgs = @{ Events = @($eventPlan.Events) }
            if ($record.scope -eq 'project') { $installArgs['TargetProject'] = $record.targetProjectRoot }
            if ($record.hookType -eq 'Engine') {
                $installArgs['Profile'] = $record.profile
                $installArgs['ConfigPath'] = $record.configPath
            }
            else {
                $installArgs['CustomHook'] = $record.sourceScript
            }
            # The POSITIVE client set, never the -*Only shims. Those are
            # consumed as double negations, so "anything that is not claude"
            # meant CodexOnly - a repair of any future subrecord
            # would have reinstalled CODEX, i.e. installed a client this record
            # may never have had, and left the damaged one untouched. -Clients
            # names exactly the one client being repaired and fails closed on
            # anything it does not recognise.
            $clientArgs = @{ Clients = @($client) }
            try {
                # STRUCTURED OUTCOME, through the one shared contract: success is
                # read from the installer's result document, never inferred from
                # console text or from "no exception was thrown". This flow always
                # had that protection; Invoke-HookInstaller is where it now lives, so
                # the fresh and config-driven flows cannot end up lacking it again.
                $mergedArgs = @{}
                foreach ($key in @($installArgs.Keys)) { $mergedArgs[$key] = $installArgs[$key] }
                foreach ($key in @($clientArgs.Keys)) { $mergedArgs[$key] = $clientArgs[$key] }
                $verdict = Invoke-HookInstaller -InstallScript $InstallScript -InstallArgs $mergedArgs
                foreach ($line in @($verdict.Output)) { Write-Log 'INFO' 'INSTALL' ([string]$line) }
                if (-not $verdict.Ok) { $anyFailed = $true }
                [void]$clientResults.Add($client + ': ' + [string]$verdict.Summary)
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
        # (which distinguishes a failed, degraded or untracked install from a
        # clean one), this is what stops a nominal success from being reported
        # as a real one.
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

