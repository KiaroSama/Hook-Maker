# Grouped explicit recovery at the actual hook entry. Two real JSON negatives,
# one independent clean receipt, and a later same-key failure; no application
# execution, live state, polling or sleeps. Existing fixture ownership is reused.
# Load only the existing bounded executor helper, not its unrelated test cases.
$recoveryAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '_testcompletionrecovery.ps1'), [ref]$null, [ref]$null)
$executor = $recoveryAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-ExplicitRecovery' }, $true)
. ([scriptblock]::Create($executor.Extent.Text))
foreach ($hostName in @('pwsh', 'powershell.exe')) {
    $copy = New-IsolatedHookCopy
    $root = New-GitRepoAi ('GroupedRecovery-' + $hostName)
    $negativeIds = @('negative-one', 'negative-two')
    foreach ($id in $negativeIds) {
        Write-GuardedResult -Copy $copy -Root $root -Overall 'failed' -RunId $id -CommandFingerprint ('d' * 32) -AgeMinutes 30
        $path = Get-RunStateFile -Copy $copy -Root $root -Kind 'result' -RunId $id
        $doc = Read-JsonFile $path
        $doc.projectFingerprint = ''
        Write-Utf8 $path ($doc | ConvertTo-Json -Depth 8)
    }
    $blocked = Fire -Copy $copy -Cwd $root -Exe $hostName -SessionId ('group-before-' + $hostName)
    $match = [regex]::Match((Get-BlockReason $blocked.Out), 'runId=([^;]+)')
    Check ($hostName + ': legacy grouped failures remain blocked before explicit proof') ($blocked.Out -match '"decision":"block"' -and $match.Success) ($blocked.Out + $blocked.Err)
    $firstPath = Get-RunStateFile -Copy $copy -Root $root -Kind 'result' -RunId $negativeIds[0]
    # Use the production key helper without copying its grouping algorithm.
    . (Join-Path (Split-Path -Parent $copy.Script) '_identity.ps1')
    . (Join-Path (Split-Path -Parent $copy.Script) '_evidence.ps1')
    $key = Get-ResultIncidentKey (Read-JsonFile $firstPath) $firstPath
    $recoveryId = 'group-clean-recovery'
    Write-GuardedResult -Copy $copy -Root $root -RunId $recoveryId -CommandFingerprint ('e' * 32) -AgeMinutes 1
    $fixture = [pscustomobject]@{ Copy = $copy; Root = $root; Key = $key; RecoveryRunId = $recoveryId }
    $paths = @($negativeIds | ForEach-Object { Get-RunStateFile -Copy $copy -Root $root -Kind 'result' -RunId $_ })
    $paths += Get-RunStateFile -Copy $copy -Root $root -Kind 'result' -RunId $recoveryId
    $beforeHashes = @($paths | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash })
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = if ($hostName -eq 'pwsh') { (Get-Process -Id $PID).Path } else { 'powershell.exe' }
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.EnvironmentVariables['LOCALAPPDATA'] = $copy.LocalAppData
    $psi.EnvironmentVariables['CLAUDE_PROJECT_DIR'] = ''
    $reason = 'Both historical failed receipts describe the same reviewed test scope; the separate newer clean receipt proves equivalent recovery with process cleanup, preserving every original.'
    $psi.Arguments = '-NoLogo -NoProfile -File "' + $copy.Script + '" -ResolveIncident ' + $key + ' -RecoveryRunId ' + $recoveryId + ' -ProjectRoot "' + $root + '" -Reason "' + $reason + '"'
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start(); $proc.StandardInput.Close()
        $stdout = $proc.StandardOutput.ReadToEndAsync(); $stderr = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit(15000)) { throw 'Grouped recovery exceeded its 15-second process bound.' }
        if (-not [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($stdout, $stderr), 5000)) { throw 'Grouped recovery streams did not close.' }
        $state = Get-CompletionStateDoc -Copy $copy -Root $root
        $pins = @(Get-Field (@(Get-Field $state 'recoveryAssociations')[0]) 'negativeReceipts')
        Check ($hostName + ': actual executor associates the full group') ($proc.ExitCode -eq 0 -and @($state.resolvedIncidents) -contains $key -and $pins.Count -eq 2) ($stdout.Result + $stderr.Result)
    }
    finally {
        if ($proc.Id -gt 0 -and -not $proc.HasExited) { $proc.Kill(); [void]$proc.WaitForExit(5000) }
        $proc.Dispose()
    }
    $after = Fire -Copy $copy -Cwd $root -Exe $hostName -SessionId ('group-after-' + $hostName)
    Check ($hostName + ': pinned originals do not re-block') ($after.Exit -eq 0 -and [string]::IsNullOrWhiteSpace($after.Out)) ($after.Out + $after.Err)
    $afterHashes = @($paths | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash })
    Check ($hostName + ': all original receipt bytes remain unchanged') (($beforeHashes -join '|') -ceq ($afterHashes -join '|'))
    Write-GuardedResult -Copy $copy -Root $root -Overall 'failed' -RunId 'later-same-key' -CommandFingerprint ('d' * 32)
    $laterPath = Get-RunStateFile -Copy $copy -Root $root -Kind 'result' -RunId 'later-same-key'
    $laterDoc = Read-JsonFile $laterPath; $laterDoc.projectFingerprint = ''
    Write-Utf8 $laterPath ($laterDoc | ConvertTo-Json -Depth 8)
    $later = Fire -Copy $copy -Cwd $root -Exe $hostName -SessionId ('group-later-' + $hostName)
    Check ($hostName + ': later same-key failure stays blocked at the real entry') ($later.Out -match '"decision":"block"' -and (Get-BlockReason $later.Out) -match 'later-same-key') ($later.Out + $later.Err)

    $single = New-IsolatedHookCopy
    $singleRoot = New-GitRepoAi ('SingularRecovery-' + $hostName)
    Write-GuardedResult -Copy $single -Root $singleRoot -Overall 'failed' -RunId 'singular-negative' -CommandFingerprint ('d' * 32) -AgeMinutes 30
    $singlePath = Get-RunStateFile -Copy $single -Root $singleRoot -Kind 'result' -RunId 'singular-negative'
    $singleDoc = Read-JsonFile $singlePath; $singleDoc.projectFingerprint = ''
    Write-Utf8 $singlePath ($singleDoc | ConvertTo-Json -Depth 8)
    Write-GuardedResult -Copy $single -Root $singleRoot -RunId 'singular-green' -CommandFingerprint ('e' * 32) -AgeMinutes 1
    $singleFixture = [pscustomobject]@{ Copy = $single; Root = $singleRoot; Key = (Get-ResultIncidentKey $singleDoc $singlePath); RecoveryRunId = 'singular-green' }
    $admitted = Invoke-ExplicitRecovery -Fixture $singleFixture -Exe $hostName
    $singleStop = Fire -Copy $single -Cwd $singleRoot -Exe $hostName -SessionId ('single-after-' + $hostName)
    Check ($hostName + ': singular explicit association evaluates without scalar Count failure') ($admitted.Exit -eq 0 -and $singleStop.Exit -eq 0 -and [string]::IsNullOrWhiteSpace($singleStop.Out)) ($admitted.Err + $singleStop.Err + $singleStop.Out)

    foreach ($variant in @('malformedResult', 'malformedActive', 'uncertainOwner', 'repeatUnknownNote')) {
        $badPath = ''
        $ledgerPath = Join-Path (Get-StateDir $single) ('TestCompletionCheck-' + (Get-ProjectKey $singleRoot) + '.json')
        if ($variant -eq 'repeatUnknownNote') {
            $ledger = Read-JsonFile $ledgerPath
            $ledger.pendingNotes = @([pscustomobject]@{ key = $singleFixture.Key; reason = 'Unknown legacy cause'; baseline = 0; origin = $null })
            Write-Utf8 $ledgerPath ($ledger | ConvertTo-Json -Depth 12)
        }
        else {
            $kind = if ($variant -eq 'malformedResult') { 'result' } else { 'active' }
            $badPath = Get-RunStateFile -Copy $single -Root $singleRoot -Kind $kind -RunId 'corrupt-or-uncertain'
            if ($variant -eq 'uncertainOwner') {
                Write-Utf8 $badPath (([pscustomobject]@{ runId = 'corrupt-or-uncertain'; ownerPid = $PID; markerCreatedUtc = [DateTime]::UtcNow.ToString('o') }) | ConvertTo-Json)
            } else { Write-Utf8 $badPath '{truncated' }
        }
        $ledgerBytes = [IO.File]::ReadAllBytes($ledgerPath)
        $receiptHash = (Get-FileHash -LiteralPath $singlePath -Algorithm SHA256).Hash
        $refusal = Invoke-ExplicitRecovery -Fixture $singleFixture -Exe $hostName
        Check ($hostName + ': ' + $variant + ' refuses recovery without ledger/original mutation') ($refusal.Exit -ne 0 -and [Convert]::ToBase64String($ledgerBytes) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($ledgerPath)) -and $receiptHash -ceq (Get-FileHash -LiteralPath $singlePath -Algorithm SHA256).Hash) ($refusal.Out + $refusal.Err)
        if ($badPath -ne '') { Remove-Item -LiteralPath $badPath -Force }
    }
}
