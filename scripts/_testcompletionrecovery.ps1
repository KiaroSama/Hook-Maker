# Explicit historical-incident recovery: real hook processes, isolated receipts
# and ledgers, with no application tests or live user state involved.

function Invoke-ExplicitRecovery {
    param($Fixture, [string]$Exe = 'pwsh', [string]$RunId = '', [string]$Reason = '')
    if ($RunId -eq '') { $RunId = $Fixture.RecoveryRunId }
    if ($Reason -eq '') { $Reason = 'The same six fixture tests were rerun with bounded process ownership and cleanup in finally; the newer guarded receipt proves their completion without leaked descendants.' }
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = if ($Exe -eq 'pwsh') { (Get-Process -Id $PID).Path } else { 'powershell.exe' }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.EnvironmentVariables['LOCALAPPDATA'] = $Fixture.Copy.LocalAppData
    $psi.EnvironmentVariables['CLAUDE_PROJECT_DIR'] = ''
    foreach ($arg in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Fixture.Copy.Script, '-ResolveIncident', $Fixture.Key, '-RecoveryRunId', $RunId, '-ProjectRoot', $Fixture.Root, '-Reason', $Reason)) { [void]$psi.ArgumentList.Add($arg) }
    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
        $proc.StandardInput.Close()
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $stderr = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit(15000)) { throw 'Explicit recovery exceeded its 15-second wall/idle bound.' }
        if (-not [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($stdout, $stderr), 5000)) { throw 'Explicit recovery output did not close within five seconds.' }
        return [pscustomobject]@{ Exit = $proc.ExitCode; Out = $stdout.Result.Trim(); Err = $stderr.Result.Trim() }
    }
    finally {
        if ($proc.Id -gt 0 -and -not $proc.HasExited) { $proc.Kill($true); [void]$proc.WaitForExit(5000) }
        $proc.Dispose()
    }
}

function New-RecoveryFixture {
    param([string]$Name, [string]$Variant = 'valid')
    $copy = New-IsolatedHookCopy
    $root = New-GitRepoAi ('Recovery-' + $Name)
    $negativeRun = 'legacy-' + (Get-ProjectKey $root)
    $recoveryRun = 'recovery-' + (Get-ProjectKey $root)
    $leakedPid = if ($Variant -in @('liveLeak', 'reusedPid')) { $PID } else { 2147483000 }
    Write-GuardedResult -Copy $copy -Root $root -Overall 'failed' -Leaked @($leakedPid) -AgeMinutes 30 -RunId $negativeRun -CommandFingerprint ('d' * 32)
    $negativePath = Get-RunStateFile -Copy $copy -Root $root -Kind 'result' -RunId $negativeRun
    $negative = Read-JsonFile $negativePath
    $negative.projectFingerprint = ''
    if ($Variant -eq 'expiredRecovery') { $negative.startedUtc = [DateTime]::UtcNow.AddHours(-6).ToString('o'); $negative.endedUtc = [DateTime]::UtcNow.AddHours(-5).ToString('o') }
    if ($Variant -eq 'liveLeak') {
        $negative.startedUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().AddSeconds(-1).ToString('o')
        $negative.endedUtc = [DateTime]::UtcNow.AddSeconds(-5).ToString('o')
    }
    Write-Utf8 $negativePath ($negative | ConvertTo-Json -Depth 6)
    $blocked = Fire -Copy $copy -Cwd $root -SessionId ('seed-' + $Name)
    if ($blocked.Out -notmatch '"decision":"block"') { throw ('Recovery fixture did not reproduce the original incident gate: ' + $blocked.Out + $blocked.Err) }
    $tag = Get-IncidentTagLine (Get-BlockReason $blocked.Out)
    $key = $tag.Substring('Test incident: '.Length)
    $body = 'Cause: an owned helper survived the original test process. Recovery reruns the same six fixture tests with a bounded wrapper and finally cleanup. The clean receipt and empty owned tree were verified.'
    if ($Variant -ne 'missingNote') {
        if ($Variant -eq 'wrongTag') { Add-AiNote -Root $root -Text ($tag + '-different' + "`n" + $body) }
        elseif ($Variant -eq 'bareTag') { Add-AiNote -Root $root -Text $tag }
        else { Add-AiNote -Root $root -Text ($tag + "`n" + $body) }
    }
    Write-GuardedResult -Copy $copy -Root $root -RunId $recoveryRun -CommandFingerprint ('e' * 32) -AgeMinutes 1
    $recoveryPath = Get-RunStateFile -Copy $copy -Root $root -Kind 'result' -RunId $recoveryRun
    $recovery = Read-JsonFile $recoveryPath
    if ($Variant -eq 'liveLeak') { $recovery.startedUtc = [DateTime]::UtcNow.AddSeconds(-3).ToString('o'); $recovery.endedUtc = [DateTime]::UtcNow.AddSeconds(-1).ToString('o') }
    if ($Variant -eq 'failedRecovery') { $recovery.overall = 'failed'; $recovery.exitCode = 1 }
    if ($Variant -eq 'wrongProject') { $recovery.workingDirectory = New-Proj ('Other-' + $Name) }
    if ($Variant -eq 'missingIdentity') { $recovery.commandFingerprint = '' }
    if ($Variant -eq 'badTime') { $recovery.startedUtc = [DateTime]::UtcNow.AddHours(1).ToString('o'); $recovery.endedUtc = [DateTime]::UtcNow.AddHours(2).ToString('o') }
    if ($Variant -eq 'staleRecovery') { $recovery.startedUtc = [DateTime]::UtcNow.AddHours(-2).ToString('o'); $recovery.endedUtc = [DateTime]::UtcNow.AddHours(-1).ToString('o') }
    if ($Variant -eq 'expiredRecovery') { $recovery.startedUtc = [DateTime]::UtcNow.AddHours(-4).ToString('o'); $recovery.endedUtc = [DateTime]::UtcNow.AddHours(-4).AddMinutes(1).ToString('o') }
    Write-Utf8 $recoveryPath ($recovery | ConvertTo-Json -Depth 6)
    if ($Variant -eq 'missingRecovery') { Remove-Item -LiteralPath $recoveryPath -Force }
    if ($Variant -eq 'active') { Write-ActiveMarker -Copy $copy -Root $root -ProcessId $PID -RunId 'still-active' }
    return [pscustomobject]@{ Copy = $copy; Root = $root; Key = $key; NegativePath = $negativePath; RecoveryPath = $recoveryPath; RecoveryRunId = $recoveryRun }
}

Write-Host '--- explicit recovery: legacy fingerprint and a changed ownership wrapper ---' -ForegroundColor Cyan
foreach ($hostName in @('pwsh', 'powershell.exe')) {
    $fixture = New-RecoveryFixture -Name $hostName
    $before = Fire -Copy $fixture.Copy -Cwd $fixture.Root -Exe $hostName -SessionId ('before-' + $hostName)
    Check ($hostName + ': note and unrelated command green do not automatically resolve legacy incident') ($before.Out -match '"decision":"block"') $before.Out
    $negativeBytes = [System.IO.File]::ReadAllText($fixture.NegativePath, [System.Text.Encoding]::UTF8)
    $recoveryBytes = [System.IO.File]::ReadAllText($fixture.RecoveryPath, [System.Text.Encoding]::UTF8)
    $resolved = Invoke-ExplicitRecovery -Fixture $fixture -Exe $hostName
    $state = Get-CompletionStateDoc -Copy $fixture.Copy -Root $fixture.Root
    Check ($hostName + ': validated association resolves the exact incident') ($resolved.Exit -eq 0 -and @($state.resolvedIncidents) -contains $fixture.Key) ($resolved.Out + $resolved.Err)
    $associations = @(Get-Field $state 'recoveryAssociations') | Where-Object { $null -ne $_ }
    Check ($hostName + ': association records the exact recovery and receipt hashes') (@($associations).Count -eq 1 -and $associations[0].recoveryRunId -eq $fixture.RecoveryRunId -and $associations[0].negativeReceiptSha256 -ceq (Get-FileHash -LiteralPath $fixture.NegativePath -Algorithm SHA256).Hash.ToLowerInvariant() -and $associations[0].recoveryReceiptSha256 -ceq (Get-FileHash -LiteralPath $fixture.RecoveryPath -Algorithm SHA256).Hash.ToLowerInvariant()) ($state | ConvertTo-Json -Depth 6)
    foreach ($event in @('Stop', 'SubagentStop')) {
        $after = Fire -Copy $fixture.Copy -Cwd $fixture.Root -EventName $event -Exe $hostName -SessionId ('after-' + $event + $hostName)
        Check ($hostName + ': ' + $event + ' does not revive the recovered incident') ($after.Exit -eq 0 -and [string]::IsNullOrWhiteSpace($after.Out)) ($after.Out + $after.Err)
    }
    $repeated = Invoke-ExplicitRecovery -Fixture $fixture -Exe $hostName
    $repeatedState = Get-CompletionStateDoc -Copy $fixture.Copy -Root $fixture.Root
    $repeatedAssociations = @(@(Get-Field $repeatedState 'recoveryAssociations') | Where-Object { $null -ne $_ })
    Check ($hostName + ': repeated association is idempotent') ($repeated.Exit -eq 0 -and $repeatedAssociations.Count -eq 1 -and (Get-ResolvedCount $repeatedState) -eq 1) ($repeated.Out + $repeated.Err)
    Check ($hostName + ': historical receipts are preserved byte-for-byte') ([System.IO.File]::ReadAllText($fixture.NegativePath, [System.Text.Encoding]::UTF8) -ceq $negativeBytes -and [System.IO.File]::ReadAllText($fixture.RecoveryPath, [System.Text.Encoding]::UTF8) -ceq $recoveryBytes)
}

Write-Host '--- explicit recovery: missing proof, unrelated proof and unfinished ownership still reject ---' -ForegroundColor Cyan
foreach ($variant in @('missingNote', 'wrongTag', 'bareTag', 'missingRecovery', 'failedRecovery', 'wrongProject', 'wrongRunId', 'missingIdentity', 'badTime', 'staleRecovery', 'shortReason', 'active', 'liveLeak')) {
    $fixture = New-RecoveryFixture -Name $variant -Variant $variant
    $ledgerPath = Join-Path (Get-StateDir $fixture.Copy) ('TestCompletionCheck-' + (Get-ProjectKey $fixture.Root) + '.json')
    $ledgerBefore = [System.IO.File]::ReadAllText($ledgerPath, [System.Text.Encoding]::UTF8)
    $reason = if ($variant -eq 'shortReason') { 'done' } else { '' }
    $requestedRunId = if ($variant -eq 'wrongRunId') { 'unrelated-run-id' } else { '' }
    $rejected = Invoke-ExplicitRecovery -Fixture $fixture -Reason $reason -RunId $requestedRunId
    Check ($variant + ': explicit recovery is rejected') ($rejected.Exit -ne 0) ($rejected.Out + $rejected.Err)
    Check ($variant + ': rejected recovery does not change the ledger') ([System.IO.File]::ReadAllText($ledgerPath, [System.Text.Encoding]::UTF8) -ceq $ledgerBefore)
    $stillBlocked = Fire -Copy $fixture.Copy -Cwd $fixture.Root -SessionId ('still-' + $variant)
    Check ($variant + ': completion remains blocked') ($stillBlocked.Out -match '"decision":"block"') $stillBlocked.Out
}

$fixture = New-RecoveryFixture -Name 'reusedPid' -Variant 'reusedPid'
$reused = Invoke-ExplicitRecovery -Fixture $fixture
Check 'PID reuse: a process started after the old incident does not prevent recovery' ($reused.Exit -eq 0 -and (Get-ResolvedCount (Get-CompletionStateDoc -Copy $fixture.Copy -Root $fixture.Root)) -eq 1) ($reused.Out + $reused.Err)
Check 'PID reuse: the unrelated current process remains alive' ($null -ne (Get-Process -Id $PID -ErrorAction SilentlyContinue))

$fixture = New-RecoveryFixture -Name 'historicalReceiptAge' -Variant 'expiredRecovery'
$historicalAge = Invoke-ExplicitRecovery -Fixture $fixture
Check 'historical recovery: a strictly newer genuine repair does not expire with the current-evidence window' ($historicalAge.Exit -eq 0 -and (Get-ResolvedCount (Get-CompletionStateDoc -Copy $fixture.Copy -Root $fixture.Root)) -eq 1) ($historicalAge.Out + $historicalAge.Err)

$fixture = New-RecoveryFixture -Name 'independentCurrentRun'
Write-Utf8 (Join-Path $fixture.Root 'readme.txt') 'The current product state changed after the historical recovery.'
Write-ObservedRecord -Copy $fixture.Copy -Root $fixture.Root -RunId 'current-unfinished-run' -CommandFingerprint ('a' * 32)
$historical = Invoke-ExplicitRecovery -Fixture $fixture
Check 'historical recovery: later product edits do not invalidate the historical association' ($historical.Exit -eq 0 -and (Get-ResolvedCount (Get-CompletionStateDoc -Copy $fixture.Copy -Root $fixture.Root)) -eq 1) ($historical.Out + $historical.Err)
$currentBlocked = Fire -Copy $fixture.Copy -Cwd $fixture.Root -SessionId 'independent-current'
Check 'historical recovery: unfinished current-state work still blocks independently' ($currentBlocked.Out -match '"decision":"block"' -and (Get-BlockReason $currentBlocked.Out) -match 'CURRENT project state') $currentBlocked.Out

# A real concurrent writer loads the old ledger and waits on an event. Recovery
# finishes first; that stale writer must merge the association before persisting.
$fixture = New-RecoveryFixture -Name 'concurrentLedger'
$writerPath = Join-Path $Work 'recovery-ledger-writer.ps1'
Write-Utf8 $writerPath @'
param([string]$Library, [string]$Ledger, [string]$StatePath, [string]$ProjectKey, [string]$Ready, [string]$Continue)
. $Library
$script:statePath = $StatePath
$script:projectKey = $ProjectKey
. $Ledger
$script:pendingNotes['concurrent-other'] = [pscustomobject]@{ reason = 'Independent concurrent incident'; baseline = 1000000L }
$readyEvent = [System.Threading.EventWaitHandle]::OpenExisting($Ready)
$continueEvent = [System.Threading.EventWaitHandle]::OpenExisting($Continue)
try {
    [void]$readyEvent.Set()
    if (-not $continueEvent.WaitOne(15000)) { throw 'Concurrent writer exceeded its synchronization bound.' }
    Save-CompletionState
}
finally { $readyEvent.Dispose(); $continueEvent.Dispose() }
'@
$eventToken = [guid]::NewGuid().ToString('N')
$readyName = 'Local\HookMakerRecoveryReady-' + $eventToken
$continueName = 'Local\HookMakerRecoveryContinue-' + $eventToken
$readyEvent = [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::ManualReset, $readyName)
$continueEvent = [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::ManualReset, $continueName)
$ledgerPath = Join-Path (Get-StateDir $fixture.Copy) ('TestCompletionCheck-' + (Get-ProjectKey $fixture.Root) + '.json')
$writer = $null
try {
    $writer = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList ('-NoProfile -File "' + $writerPath + '" -Library "' + $HookLib + '" -Ledger "' + (Join-Path (Split-Path -Parent $fixture.Copy.Script) '_ledger.ps1') + '" -StatePath "' + $ledgerPath + '" -ProjectKey ' + (Get-ProjectKey $fixture.Root) + ' -Ready "' + $readyName + '" -Continue "' + $continueName + '"') -WindowStyle Hidden -PassThru
    $null = $writer.Handle
    if (-not $readyEvent.WaitOne(10000)) { throw 'Concurrent writer did not load its initial ledger within ten seconds.' }
    $associated = Invoke-ExplicitRecovery -Fixture $fixture
    Check 'concurrent ledger: explicit recovery succeeds while another writer holds an older snapshot' ($associated.Exit -eq 0) ($associated.Out + $associated.Err)
    [void]$continueEvent.Set()
    if (-not $writer.WaitForExit(10000)) { throw 'Concurrent writer did not finish within ten seconds.' }
    $merged = Get-CompletionStateDoc -Copy $fixture.Copy -Root $fixture.Root
    Check 'concurrent ledger: resolved association and independent note both survive' ($writer.ExitCode -eq 0 -and @($merged.resolvedIncidents) -contains $fixture.Key -and @($merged.pendingNotes).Count -eq 1 -and $merged.pendingNotes[0].key -eq 'concurrent-other' -and @($merged.recoveryAssociations).Count -eq 1) ($merged | ConvertTo-Json -Depth 6)
}
finally {
    [void]$continueEvent.Set()
    if ($null -ne $writer) { if (-not $writer.HasExited) { $writer.Kill($true); [void]$writer.WaitForExit(5000) }; $writer.Dispose() }
    $readyEvent.Dispose(); $continueEvent.Dispose()
}
