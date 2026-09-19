from pathlib import Path
import sys

mode = sys.argv[1]
root = Path(sys.argv[2]) if len(sys.argv) > 2 else Path('.')

def get(name):
    return (root / name).read_text(encoding='utf-8-sig')

def put(name, text):
    (root / name).write_text(text, encoding='utf-8', newline='\r\n')

def replace(name, old, new, count=1):
    text = get(name)
    assert text.count(old) == count, (name, old[:100], text.count(old), count)
    put(name, text.replace(old, new))

# Exercise the real producer under a saved/restored environment, not an
# interpolated shell command that can write a marker in the real user profile.
name = 'scripts/Test-GraphUpdateCheck.ps1'
old = '''    # Its OWN marker, named by CALLING the production helper rather than by
    # retyping its path format, so the fixture cannot drift from the real one.
    $markerPath = & pwsh -NoProfile -Command ". '$HookLib'; $env:LOCALAPPDATA = '$FakeLocalAppData'; Get-StopBlockMarkerPath -HookName 'Graph-Update-Check' -ProjectRoot '$guard'"
    New-Item -ItemType Directory -Path (Split-Path -Parent $markerPath) -Force | Out-Null
    [System.IO.File]::WriteAllText($markerPath, 't')
    $r4 = Fire -Cwd $guard -StopHookActive
    Check 'stop_hook_active PLUS its own marker for this session -> silent (own re-entry)' ($r4.Exit -eq 0 -and $r4.Out -eq '') $r4.Out'''
new = '''    # A separate project has no cooldown stamp: only the real ledger claim
    # below can suppress it. The environment assignment is code, never text
    # expanded on the left-hand side of a nested PowerShell command.
    $ownedGuard = New-GitRepo 'OwnedGuard'
    New-StaleGraph $ownedGuard | Out-Null
    Write-Utf8 (Join-Path $ownedGuard 'src.ps1') 'function Owned {}'
    Add-Commit $ownedGuard 'add Owned'
    $savedMarkerLocal = $env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA = $FakeLocalAppData
        . $HookLib
        $claim = Set-StopBlockMarker -HookInput ([pscustomobject]@{
            session_id = 't'; cwd = $ownedGuard; hook_event_name = 'Stop'
        }) -HookName 'Graph-Update-Check'
        Check 'the production helper actually admitted the isolated graph claim' $claim.Admitted $claim.Reason
        $ledgerPath = Get-StopLedgerPath -ProjectRoot $ownedGuard
        Check 'the graph claim is persisted inside the owned test state directory' (
            (Test-PathInside -Candidate $ledgerPath -Parent $FakeLocalAppData) -and
            [IO.File]::Exists($ledgerPath)) $ledgerPath
    }
    finally { $env:LOCALAPPDATA = $savedMarkerLocal }
    $r4 = Fire -Cwd $ownedGuard -StopHookActive
    Check 'own re-entry is silent without a cooldown stamp and without stderr' (
        $r4.Exit -eq 0 -and $r4.Out -eq '' -and $r4.Err -eq '') ($r4.Out + $r4.Err)'''
replace(name, old, new)

if mode == 'task':
    replace('hooks/_taskidentity.ps1',
        "($turn -eq '' -or @($record.turnIds) -ccontains $turn)",
        "($turn -eq '' -or $record.dispatchId -ceq $turn)")
    replace('hooks/_taskidentity.ps1',
        "if ($turn -ne '' -and $record.dispatchId -ceq $turn) { return $record }",
        "if ($turn -ne '' -and @($record.turnIds) -ccontains $turn) { return $record }")
    replace('hooks/_stoplib.ps1',
        "    if (-not $IsContinuation) { return $false }\n    $path = Get-StopLedgerPath",
        """    if (-not $IsContinuation) { return $false }
    # A known task must be reevaluated: a shared continuation flag says nothing
    # about its current evidence. Atomic admission below, not this early hint,
    # deduplicates unchanged findings and enforces the finite task allowance.
    if ((Get-StopEventId -HookInput $HookInput) -like 't:*') { return $false }
    $path = Get-StopLedgerPath""")
    replace('scripts/Test-DocsFreshnessCheck.ps1',
        "[switch]$StopHookActive, [string]$Exe = 'pwsh')",
        "[switch]$StopHookActive, [string]$Exe = 'pwsh', [string]$Prompt = '')")
    replace('scripts/Test-DocsFreshnessCheck.ps1',
        "    $obj = @{ session_id = $SessionId; cwd = $Cwd; hook_event_name = $EventName }",
        "    $obj = @{ session_id = $SessionId; cwd = $Cwd; hook_event_name = $EventName }\n    if ($Prompt -ne '') { $obj['prompt'] = $Prompt }")
    replace('scripts/Test-DocsFreshnessCheck.ps1',
        '''    Check 'a rejected acknowledgement never clears the block' ($rStillBlocked.Out -match '"decision":"block"') $rStillBlocked.Out''',
        '''    Check 'an unchanged rejected review does not create repeated correction turns' (
        $rStillBlocked.Exit -eq 0 -and $rStillBlocked.Out -eq '' -and $rStillBlocked.Err -eq '') $rStillBlocked.Out
    Check 'a rejected acknowledgement writes no approval record' (
        @(Get-ChildItem -LiteralPath (Join-Path $hc12.LocalAppData 'HookMaker\\state') -Filter 'DocsFreshnessCheck-ack-*.json').Count -eq 0)
    $null = Fire -HookPath $hc12.Script -Cwd $proj12 -EventName 'UserPromptSubmit' -Prompt 'Recheck the rejected review' -LocalAppData $hc12.LocalAppData
    $rRecheck = Fire -HookPath $hc12.Script -Cwd $proj12 -EventName 'Stop' -LocalAppData $hc12.LocalAppData -StopHookActive
    Check 'a genuine new task still blocks the identical unacknowledged documentation evidence' (
        $rRecheck.Out -match '"decision":"block"' -and (Get-Fingerprint $rRecheck.Out) -eq $fp12) $rRecheck.Out''')
    replace('scripts/Test-DocsFreshnessCheck.ps1',
        '''    Check 'a mismatched/stale fingerprint acknowledgement never clears the block' ($rAfterWrongFp.Out -match '"decision":"block"') $rAfterWrongFp.Out''',
        '''    Check 'an unchanged mismatched review is deduplicated, not repeatedly emitted' (
        $rAfterWrongFp.Exit -eq 0 -and $rAfterWrongFp.Out -eq '' -and $rAfterWrongFp.Err -eq '') $rAfterWrongFp.Out
    $null = Fire -HookPath $hc14.Script -Cwd $proj14 -EventName 'UserPromptSubmit' -Prompt 'Recheck the stale review' -LocalAppData $hc14.LocalAppData
    $rRecheck = Fire -HookPath $hc14.Script -Cwd $proj14 -EventName 'Stop' -LocalAppData $hc14.LocalAppData -StopHookActive
    Check 'a mismatched approval still cannot clear the gate when the task is reevaluated' (
        $rRecheck.Out -match '"decision":"block"' -and (Get-Fingerprint $rRecheck.Out) -ne $wrongFp) $rRecheck.Out''')
    replace('scripts/Test-CiStatusCheck.ps1',
        "(Claude: non-blocking additionalContext, CI not green)' ($r.Exit -eq 0 -and $r.Out -notmatch '\"decision\":\"block\"' -and $r.Out -match 'additionalContext'",
        "(Claude: non-continuing systemMessage, CI not green)' ($r.Exit -eq 0 -and $r.Out -notmatch '\"decision\":\"block\"' -and $r.Out -match 'systemMessage' -and $r.Out -notmatch 'hookSpecificOutput'")
    replace('scripts/Test-GitSyncCheck.ps1',
        '''Check 'the Claude client gets additionalContext for the non-blocking advisory, not systemMessage' ($rClaude.Out -match '"additionalContext"' -and $rClaude.Out -notmatch '"systemMessage"')''',
        '''Check 'the Claude Stop advisory is user-visible without injecting a model turn' ($rClaude.Out -match '"systemMessage"' -and $rClaude.Out -notmatch '"hookSpecificOutput"')''')
    replace('scripts/_testcontextlargefile.ps1',
        "$null -eq $lfCodexDoc.PSObject.Properties['systemMessage']",
        "$null -eq $lfCodexDoc.PSObject.Properties['hookSpecificOutput']")
    replace('scripts/_testcompletiongate.ps1',
        "$rSub.Out -match 'additionalContext' -and $rSub.Out -match 'TEST COMPLETION CHECK'",
        "$rSub.Out -match 'systemMessage' -and $rSub.Out -notmatch 'hookSpecificOutput' -and $rSub.Out -match 'TEST COMPLETION CHECK'")
    replace('scripts/_testcompletiongate.ps1',
        "    Set-MarkerAge -Copy $c -Root $p -AgeHours 240\n    $r = Fire -Copy $c -Cwd $p",
        "    Set-MarkerAge -Copy $c -Root $p -AgeHours 240\n    $r = Fire -Copy $c -Cwd $p -SessionId 'recheck-live-owner'")
    replace('scripts/_testcompletiongate.ps1',
        '''    # The same finding blocks again on the next Stop: nothing has changed.
    $r2 = Fire -Copy $c -Cwd $p
    Check 'it does not evaporate on the next Stop' ($r2.Out -match '"decision":"block"') $r2.Out''',
        '''    # Deduplication concerns emission, not whether the incident is resolved.
    $r2 = Fire -Copy $c -Cwd $p
    Check 'ownerless evidence remains pending while repeated output is suppressed' (
        $r2.Exit -eq 0 -and $r2.Out -eq '' -and
        [IO.File]::Exists((Get-RunStateFile -Copy $c -Root $p -Kind 'active')) -and
        (Get-PendingCount (Get-CompletionStateDoc -Copy $c -Root $p)) -eq 1) $r2.Out
    $rRecheck = Fire -Copy $c -Cwd $p -SessionId 'recheck-ownerless'
    Check 'an independent session still sees the unresolved ownerless incident' (
        $rRecheck.Out -match '"decision":"block"' -and (Get-BlockReason $rRecheck.Out) -match 'OWNERLESS') $rRecheck.Out''')
    replace('scripts/_testcompletionnotes.ps1',
        '''    Check 'the word "done" does NOT satisfy the durable-note requirement' ($r.Out -match '"decision":"block"') $r.Out
    Check 'the block says a bare acknowledgement will not clear it' ((Get-BlockReason $r.Out) -match 'bare acknowledgement') $r.Out''',
        '''    Check 'the word "done" leaves the durable-note obligation pending without repeating output' (
        $r.Exit -eq 0 -and $r.Out -eq '' -and (Get-PendingCount (Get-CompletionStateDoc -Copy $c -Root $p)) -eq 1) $r.Out
    Check 'the original block says a bare acknowledgement will not clear it' ($reason -match 'bare acknowledgement') $reason''')
    replace('scripts/_testcompletionnotes.ps1',
        '''    Check 'a long but UNTAGGED note does not satisfy the requirement - the incident tag is required' ($r.Out -match '"decision":"block"') $r.Out
    # Now write the SAME note tagged with the incident key the block names.
    Add-TaggedNote -Root $p -Reason (Get-BlockReason $r.Out)''',
        '''    Check 'an untagged note cannot resolve the pending incident even when output is deduplicated' (
        $r.Exit -eq 0 -and $r.Out -eq '' -and (Get-PendingCount (Get-CompletionStateDoc -Copy $c -Root $p)) -eq 1 -and
        (Get-ResolvedCount (Get-CompletionStateDoc -Copy $c -Root $p)) -eq 0) $r.Out
    # Retain the originally delivered incident key; silence is not a new receipt.
    Add-TaggedNote -Root $p -Reason $reason''')
    for name in ['scripts/_testcompletionoutput.ps1', 'scripts/_testcompletiondeepdebug.ps1']:
        text = get(name)
        text = text.replace('$doc.hookSpecificOutput.additionalContext', '$doc.systemMessage')
        text = text.replace('$doc.hookSpecificOutput.hookEventName -eq \'Stop\'', "$null -eq $doc.PSObject.Properties['hookSpecificOutput']")
        text = text.replace('reported through additionalContext', 'reported through non-continuing systemMessage')
        text = text.replace('the advisory carries the correct hookEventName', 'the advisory does not inject hookSpecificOutput')
        put(name, text)
    addition = r'''
    # A delayed handler must not roll back the active dispatch or refill its task.
    $p = New-TaskInput 'late-dispatch' 'first user turn' 'late-1'
    Register-UserTaskBoundary $p
    $taskBefore = (Get-CurrentUserTaskIdentity $p).TaskId
    $receipt = Register-TaskContinuation -HookInput $p -Reason 'repair the original finding'
    $next = New-TaskInput 'late-dispatch' $receipt.Text 'late-2'
    Register-UserTaskBoundary $next
    $null = Set-StopBlockMarker -HookInput $next -HookName 'Late-Gate' -FindingFingerprint 'same'
    Register-UserTaskBoundary $p
    Assert-Case 'a delayed original dispatch cannot mint a replacement task' {
        (Get-CurrentUserTaskIdentity $next).TaskId -ceq $taskBefore
    }
    $p.hook_event_name = 'Stop'
    Register-UserTaskBoundary $p
    $state = Read-TaskIdentityRecord -Path (Get-TaskScope $next).Path
    Assert-Case 'a delayed Stop cannot seal a newer active dispatch' { $state.phase -ceq 'working' -and $state.dispatchId -ceq 'late-2' }
    Set-ObjectProperty -Object $next -Name 'stop_hook_active' -Value $true
    Assert-Case 'a known-task continuation evaluates current evidence before admission' { -not (Test-StopStandDown -HookInput $next -HookName 'Late-Gate') }
    $duplicate = Set-StopBlockMarker -HookInput $next -HookName 'Late-Gate' -FindingFingerprint 'same'
    Assert-Case 'a delayed dispatch does not refund an already-claimed finding' { -not $duplicate.Admitted -and $duplicate.Reason -ceq 'already-claimed' }
    $changed = Set-StopBlockMarker -HookInput $next -HookName 'Late-Gate' -FindingFingerprint 'changed'
    Assert-Case 'changed continuation evidence is evaluated within the same task allowance' { $changed.Admitted }
    $fresh = New-TaskInput 'late-dispatch' 'a genuinely new task' 'late-3'
    Register-UserTaskBoundary $fresh
    Set-ObjectProperty -Object $fresh -Name 'stop_hook_active' -Value $true
    Assert-Case 'a new task is not suppressed by an earlier tasks continuation hint' { -not (Test-StopStandDown -HookInput $fresh -HookName 'Late-Gate') }
    $scope = Get-TaskScope $fresh
    $held = [IO.File]::Open(($scope.Path + '.lock'), 'Open', 'ReadWrite', 'None')
    try {
        $beforeBytes = [IO.File]::ReadAllText($scope.Path)
        $blocked = Register-TaskContinuation -HookInput $fresh -Reason 'must be persisted'
        Assert-Case 'a held task lock refuses a correction receipt without altering task state' { -not $blocked.Ok -and [IO.File]::ReadAllText($scope.Path) -ceq $beforeBytes }
    }
    finally { $held.Dispose() }
'''
    replace('scripts/regression/Test-TaskIdentityIsolation.ps1',
        '    # Exercise the actual write transaction, not a translated model.',
        addition + '\n    # Exercise the actual write transaction, not a translated model.')
else:
    assert mode == 'storage'
    for name, old, path, label in [
        ('scripts/_testinstallregistrydrift.ps1',
         "        Check 'no lock file is left behind after concurrent writes' (-not (Test-Path -LiteralPath (Join-Path $corruptRoot 'state\\install-registry.lock')))",
         "(Join-Path $corruptRoot 'state\\install-registry.lock')", 'concurrent writers release the lock handle and preserve its stable inode'),
        ('scripts/_testregistryschemaavailability.ps1',
         "        Check 'the lock file is released after the write' (-not (Test-Path -LiteralPath $availLock))",
         '$availLock', 'a completed registry write leaves the stable lock available for the next writer')]:
        new = """        $released = $false; $lockProbe = $null
        try {
            $lockProbe = [IO.File]::Open(PATH, 'Open', 'ReadWrite', 'None')
            $released = $true
        }
        catch { $released = $false }
        finally { if ($null -ne $lockProbe) { $lockProbe.Dispose() } }
        Check 'LABEL' $released""".replace('PATH', path).replace('LABEL',label)
        replace(name, old, new)
    # Keep the failed cold-start canary's deadlines and capture exact evidence
    # rather than retrying it into green or reusing the preceding argv capture.
    name='scripts/_testrunguardhosts.ps1'
    replace(name,
        "        $null=Invoke-QuietCommand -FilePath $program -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$wrapper) -TimeoutSeconds 35",
        "        $canaryClock = [Diagnostics.Stopwatch]::StartNew()\n        $canaryOutput=Invoke-QuietCommand -FilePath $program -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$wrapper) -TimeoutSeconds 35")
    replace(name,
        '        $doc=Read-JsonFile $receipt',
        '''        $doc=Read-JsonFile $receipt
        $canaryDiagnostic = [ordered]@{
            host = $runnerHost; case = $tag; processExit = $processExit
            elapsedSeconds = $canaryClock.Elapsed.TotalSeconds
            resultExists = [IO.File]::Exists($receipt); captureExists = [IO.File]::Exists($capture)
            result = $doc
        }
        Write-JsonFileAtomic -Path (Join-Path $caseRoot ($tag + '.diagnostics.json')) -Value $canaryDiagnostic
        $diagnosticText = $canaryDiagnostic | ConvertTo-Json -Depth 8 -Compress''')
    replace(name,"($doc|ConvertTo-Json -Compress)","$diagnosticText")
    replace(name,
        '        $receipt=Join-Path $caseRoot ($tag+\'.json\')',
        '''        # No case may reuse a capture emitted by the preceding run.
        if ([IO.File]::Exists($capture)) { [IO.File]::Delete($capture) }
        $receipt=Join-Path $caseRoot ($tag+'.json')''')
    replace('hooks/Cross-Project-.ai-Knowledge-Sync/_packageguard.ps1',
        "        if (-not [IO.Directory]::Exists($root)) { return $false }",
        "        if (-not [IO.Directory]::Exists($root) -or ([IO.File]::GetAttributes($root) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }")
    replace('hooks/Cross-Project-.ai-Knowledge-Sync/_packageguard.ps1',
        '        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop',
        '''        # Windows PowerShell providers differ on recursive link removal.
        # Refuse a redirected descendant before any deletion; never traverse it.
        $pending = New-Object 'System.Collections.Generic.Stack[string]'
        $pending.Push($target); $visited = 0
        while ($pending.Count -gt 0) {
            foreach ($child in (New-Object IO.DirectoryInfo($pending.Pop())).EnumerateFileSystemInfos()) {
                if (++$visited -gt 20000 -or ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
                if (($child.Attributes -band [IO.FileAttributes]::Directory) -ne 0) { $pending.Push($child.FullName) }
            }
        }
        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop''')
    name='scripts/regression/Test-PackagePublication.ps1'
    replace(name,
        '    # Delete only the test-owned link, not recursively through its target.',
        '''    Check-Package 'retirement refuses a tree containing an internal junction' (
        -not (Remove-OwnedPackageDirectory -Path $second.packageRoot -OwnedRoot $paths.inboxRoot -TrustedRoot $destination))
    Check-Package 'a refused retirement preserves both the package and its external target' (
        [IO.File]::Exists($second.manifestPath) -and [IO.File]::ReadAllText((Join-Path $outside 'sentinel.txt')) -ceq 'preserve')
    # Delete only the test-owned link, not recursively through its target.''')
    replace(name,
        "    Check-Package 'the external junction target is not modified by verification' ([IO.File]::ReadAllText((Join-Path $outside 'sentinel.txt')) -ceq 'preserve')",
        """    Check-Package 'the external junction target is not modified by verification' ([IO.File]::ReadAllText((Join-Path $outside 'sentinel.txt')) -ceq 'preserve')
    $emptyTarget = Join-Path $work 'empty-external-target'
    [void][IO.Directory]::CreateDirectory($emptyTarget)
    [IO.Directory]::Delete($empty.filesRoot)
    $null = New-Item -ItemType Junction -Path $empty.filesRoot -Target $emptyTarget
    try {
        Check-Package 'an empty redirected files root is not accepted as an empty reviewed set' (
            -not (Test-PendingPackageIntact $empty $context $paths))
    }
    finally { [IO.Directory]::Delete($empty.filesRoot) }""")

# New audit regressions use project-owned workspaces, not machine-wide TEMP.
for name in (['Test-TaskIdentityIsolation.ps1','Test-StopConcurrency.ps1'] if mode=='task' else ['Test-StorageIntegrity.ps1','Test-PackagePublication.ps1']):
    path='scripts/regression/'+name
    text=get(path)
    lines=text.splitlines()
    worklines=[i for i,line in enumerate(lines) if line.startswith("$work = Join-Path ([IO.Path]::GetTempPath())")]
    assert len(worklines)==1,(name,worklines)
    i=worklines[0]
    prefix={'Test-TaskIdentityIsolation.ps1':'hookmaker-task-regression', 'Test-StopConcurrency.ps1':'hookmaker-concurrency', 'Test-StorageIntegrity.ps1':'hookmaker-storage','Test-PackagePublication.ps1':'hookmaker-publication'}[name]
    lines[i:i+1]=[". (Join-Path $repo 'scripts\\_testlib.ps1')", "$work = New-TestWorkspace -Prefix '"+prefix+"'"]
    text='\n'.join(lines)+'\n'
    text=text.replace('[void](New-Item -ItemType Directory -Path $work)', '[void](New-Item -ItemType Directory -Path $work -Force)')
    put(path,text)
