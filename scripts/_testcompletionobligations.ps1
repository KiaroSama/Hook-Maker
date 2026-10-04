# Optimized obligation seam: no subprocess, clock waits or external service.
function Invoke-NoteObligationRegression {
    param([string]$RepoRoot)
    & {
        param($root)
        . (Join-Path $root 'hooks/_hooklib.ps1')
        function ConvertTo-UtcTime { param($Value) if ($null -ne $Value) { return ([DateTime]$Value).ToUniversalTime() }; return $null }
        $statePath = Join-Path $Work 'absent-ledger.json'
        $script:cwd = $Work
        . (Join-Path $root 'hooks/Test-Completion-Check/_notes.ps1')
        . (Join-Path $root 'hooks/Test-Completion-Check/_ledger.ps1')
        . (Join-Path $root 'hooks/Test-Completion-Check/_evidence.ps1')
        . (Join-Path $root 'hooks/Test-Completion-Check/_noteobligations.ps1')
        $ordinary = [pscustomobject]@{ overall='failed'; terminated=$false; terminateReason=''; terminateDetail=''; leakedProcessIds=@(); commandFingerprint='ordinary'; endedUtc='2026-10-05T00:00:00Z' }
        $key = Get-ResultIncidentKey $ordinary ''
        Check 'note eligibility: ordinary failures retain recovery identity' ($key -ne '')
        Register-PendingNote -Key $key -Reason (Get-IncidentReasonFromDoc $ordinary)
        Check 'note eligibility: ordinary failure does not register an empty obligation' ($script:pendingNotes.Count -eq 0)
        Register-PendingNote -Key 'blank' -Reason '   '
        Check 'note eligibility: whitespace cause is rejected at the shared boundary' ($script:pendingNotes.Count -eq 0)
        $term = [pscustomobject]@{ overall='error'; terminated=$true; terminateReason='wallTimeout'; terminateDetail='cleanup failed'; leakedProcessIds=@(); commandFingerprint='terminated' }
        Check 'note eligibility: cleanup error retains its proven termination cause' ((Get-IncidentReasonFromDoc $term) -match 'TERMINATED.*wallTimeout')
        $leak = [pscustomobject]@{ overall='ok'; terminated=$false; terminateReason=''; leakedProcessIds=@(900001); commandFingerprint='leak' }
        Check 'note eligibility: leaks remain eligible even with overall ok' ((Get-IncidentReasonFromDoc $leak) -match 'LEAKED')
        $script:stateDir = $Work; $script:projectKey = Get-ShortHash (Normalize-Path $Work).ToLowerInvariant()
        $origin = [pscustomobject]@{kind='result';projectKey=$script:projectKey;workingDirectory=$Work;receiptPath=(Join-Path $Work ('TestRunGuard-result-'+$script:projectKey+'-fixture.json'));receiptSha256=('a'*64);runId='fixture';commandFingerprint='fixture';overall='terminated'}
        Check 'origin: valid pruned snapshot remains traceable' (Test-NoteOrigin $origin)
        $foreign = $origin | Select-Object *; $foreign.receiptPath = Join-Path (Split-Path -Parent $Work) 'foreign.json'
        Check 'origin: a foreign or kind-mismatched receipt path is not actionable' (-not (Test-NoteOrigin $foreign))
        $script:pendingNotes['merge'] = [pscustomobject]@{reason='';baseline=1}
        $script:statePath = Join-Path $Work 'merge-ledger.json'
        try {
            Write-JsonFileAtomic -Path $script:statePath -Value ([pscustomobject]@{pendingNotes=@([pscustomobject]@{key='merge';reason='the run was terminated';baseline=2;origin=$origin;extraField='retained'})})
            Merge-DiskLedger
            Check 'merge: stale writer keeps the strongest disk origin and earliest baseline' ((Test-NoteObligationActionable $script:pendingNotes['merge']) -and $script:pendingNotes['merge'].baseline -eq 1 -and $script:pendingNotes['merge'].extraField -eq 'retained')
            $script:pendingNotes['unknown'] = [pscustomobject]@{reason='';baseline=0}
            function Get-NoteBytes { param($Root) return 1000 }
            function Test-NoteTagPresent { param($Root,$Key) return $true }
            Check 'unknown: a tag and unrelated note growth cannot falsely resolve it' (-not (Test-PendingNoteSatisfied 'unknown'))
        }
        finally { if (Test-Path -LiteralPath $script:statePath) { Remove-Item -LiteralPath $script:statePath -Force } }
    } $RepoRoot
}

function Invoke-NoteObligationEntryRegression {
    $c = New-IsolatedHookCopy
    $p = New-GitRepoAi 'OrdinaryThenClean'
    Write-GuardedResult -Copy $c -Root $p -Overall failed -ExitCode 1 -RunId 'ordinary' -AgeMinutes 5
    Write-GuardedResult -Copy $c -Root $p -RunId 'clean' -AgeMinutes 0
    $r = Fire -Copy $c -Cwd $p
    Check 'ordinary matching clean success demands no note and emits no empty cause' ($r.Exit -eq 0 -and $r.Out -eq '' -and (Get-PendingCount (Get-CompletionStateDoc $c $p)) -eq 0) $r.Out

    foreach ($mode in @('termination', 'leak', 'always')) {
        $settings = if ($mode -eq 'always') { @{TEST_COMPLETION_ALWAYS_REQUIRE_NOTE='1'} } else { @{} }
        $c = New-IsolatedHookCopy $settings
        $p = New-GitRepoAi ('Evidenced-' + $mode)
        if ($mode -eq 'always') {
            $unknownPath = Join-Path (Get-StateDir $c) ('TestCompletionCheck-' + (Get-ProjectKey $p) + '.json')
            Write-Utf8 $unknownPath ([pscustomobject]@{pendingNotes=@([pscustomobject]@{key='unknown-always';reason='';baseline=0})} | ConvertTo-Json -Depth 6)
        }
        if ($mode -eq 'termination') { Write-GuardedResult -Copy $c -Root $p -Overall terminated -ExitCode 124 -TerminateReason idleTimeout -RunId negative -AgeMinutes 5 }
        if ($mode -eq 'leak') { Write-GuardedResult -Copy $c -Root $p -Leaked @(900001) -RunId negative -AgeMinutes 5 }
        Write-GuardedResult -Copy $c -Root $p -RunId green
        $r = Fire -Copy $c -Cwd $p
        $state = Get-CompletionStateDoc $c $p
        $note = @(@(Get-Field $state 'pendingNotes') | Where-Object { $null -ne (Get-Field $_ 'origin') })
        Check ('eligible ' + $mode + ' still gates with substantive cause and traceable origin') ($r.Out -match '"decision":"block"' -and $r.Out -match 'Origin:.*command=.*receipt=.*SHA256=' -and $note.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace($note[0].reason) -and [string](Get-Field $note[0].origin 'projectKey') -eq (Get-ProjectKey $p)) $r.Out
        $r = Fire -Copy $c -Cwd $p -StopHookActive
        Check ('eligible ' + $mode + ' unchanged continuation remains bounded without losing obligation') ($r.Out -eq '' -and (Get-PendingCount (Get-CompletionStateDoc $c $p)) -eq $(if ($mode -eq 'always') { 2 } else { 1 })) $r.Out
    }

    $c = New-IsolatedHookCopy
    $p = New-GitRepoAi 'MixedLegacyNotes'
    Write-GuardedResult -Copy $c -Root $p -Overall failed -ExitCode 1 -RunId 'legacy-fail' -AgeMinutes 5
    Write-GuardedResult -Copy $c -Root $p -RunId 'legacy-clean'
    $path = Get-RunStateFile $c $p 'result' 'legacy-fail'
    $doc = Read-JsonFile $path
    $key = Get-ShortHash ((Get-TestCommandFp $p) + '|failed||')
    $ledgerPath = Join-Path (Get-StateDir $c) ('TestCompletionCheck-' + (Get-ProjectKey $p) + '.json')
    $seed = [pscustomobject]@{ resolvedIncidents=@(); pendingNotes=@([pscustomobject]@{key=$key;reason='';baseline=0},[pscustomobject]@{key='unknown';reason='';baseline=7}); recoveryAssociations=@(); retainedFixture='preserved' }
    Write-Utf8 $ledgerPath ($seed | ConvertTo-Json -Depth 8)
    $beforeHash = (Get-FileHash $ledgerPath -Algorithm SHA256).Hash
    $r = Fire -Copy $c -Cwd $p
    $state = Get-CompletionStateDoc $c $p
    Check 'legacy reconciliation never demands an invented note or blocks unknown state' ($r.Exit -eq 0 -and $r.Out -notmatch '"decision":"block"|because \.|additionalContext' -and $r.Out -match 'UNKNOWN') $r.Out
    Check 'legacy proven ordinary failure retired but not resolved' (@(Get-Field $state 'retiredNotes').Count -eq 1 -and @(Get-Field $state 'resolvedIncidents') -notcontains $key) ($state | ConvertTo-Json -Depth 8)
    $unknown = @(@(Get-Field $state 'pendingNotes') | Where-Object { [string](Get-Field $_ 'key') -eq 'unknown' })
    Check 'legacy unknown entry preserved and unrelated fields retained' ($unknown.Count -eq 1 -and [int64]$unknown[0].baseline -eq 7 -and [string](Get-Field $state 'retainedFixture') -eq 'preserved')
    $retired = @(Get-Field $state 'retiredNotes')
    $backup = if ($retired.Count -gt 0) { [string](Get-Field $retired[0] 'backupPath') } else { '' }
    Check 'legacy backup is byte-identical to original before mutation' ($backup -ne '' -and (Test-Path -LiteralPath $backup) -and (Get-FileHash $backup -Algorithm SHA256).Hash -eq $beforeHash) $backup
    $r = Fire -Copy $c -Cwd $p
    Check 'unchanged unknown diagnostic is not repeated and retirement survives disk merge' ($r.Out -eq '' -and (Get-PendingCount (Get-CompletionStateDoc $c $p)) -eq 1) $r.Out

    $c = New-IsolatedHookCopy
    $p = New-GitRepoAi 'LegacyTermination'
    $legacyReceipt = Join-Path (Get-StateDir $c) ('TestRunGuard-result-' + (Get-ProjectKey $p) + '.json')
    Write-Utf8 $legacyReceipt ([pscustomobject]@{overall='terminated';terminateReason='wallTimeout';leakedProcessIds=@();endedUtc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json)
    $r = Fire -Copy $c -Cwd $p
    Check 'legacy true termination without optional identity still records an evidenced clearable note' ($r.Out -match '"decision":"block"' -and (Get-PendingCount (Get-CompletionStateDoc $c $p)) -eq 1) $r.Out

    $c = New-IsolatedHookCopy
    $p = New-GitRepoAi 'UnknownFullLedger'
    $ledgerPath = Join-Path (Get-StateDir $c) ('TestCompletionCheck-' + (Get-ProjectKey $p) + '.json')
    $unknowns = @(0..49 | ForEach-Object { [pscustomobject]@{key=('unknown-'+$_);reason='';baseline=0} })
    Write-Utf8 $ledgerPath ([pscustomobject]@{pendingNotes=$unknowns} | ConvertTo-Json -Depth 6)
    Write-GuardedResult -Copy $c -Root $p -Overall terminated -ExitCode 124 -TerminateReason wallTimeout -RunId overflow -AgeMinutes 5
    $receiptPath = Get-RunStateFile $c $p result overflow
    (Get-Item -LiteralPath $receiptPath).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-25)
    Write-GuardedResult -Copy $c -Root $p -RunId overflow-green
    $r = Fire -Copy $c -Cwd $p
    Check 'unknown full ledger never drops the genuine incident receipt or suppresses overflow gate' ($r.Out -match '"decision":"block"' -and $r.Out -match 'ledger is FULL' -and (Test-Path -LiteralPath $receiptPath) -and (Get-PendingCount (Get-CompletionStateDoc $c $p)) -eq 50) $r.Out
}
