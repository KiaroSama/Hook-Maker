# Test-Generation section: affirmative gate receipts (spec 007 RD-4, FR-013..FR-016).
#
# Dot-sourced from Test-Generation.ps1 INSIDE its try block, so it runs in that
# scope with its harness: $Work, Check, Start-GenTask, the fake LOCALAPPDATA and
# the loaded _hooklib/_generation (which load _gatereceipts through
# _evidencelib). The underscore keeps it out of the runner's Test-*.ps1 glob.
#
# What is load-bearing here: readiness is claimed ONLY on a pass receipt from
# every registered gate written in this round. Each negative case (block,
# missing, stale, crashed, unreadable registration) has a positive twin in the
# same file, so a check that is simply always-false cannot pass them all.

    $script:GateReceiptGlobalRoot = Join-Path $Work 'home'
    $script:GateReceiptWaitMs = 300
    $receiptSettingsDir = Join-Path $Work '.claude'
    [void][IO.Directory]::CreateDirectory($receiptSettingsDir)
    function Write-ReceiptRegistration {
        param([string[]]$Gates, [switch]$Corrupt)
        $path = Join-Path $receiptSettingsDir 'settings.local.json'
        if ($Corrupt) { [IO.File]::WriteAllText($path, '{ "hooks": ', (New-Object Text.UTF8Encoding($false))); return }
        $handlers = @($Gates | ForEach-Object { @{ type = 'command'; command = ('powershell.exe -File "C:\p\.claude\hooks\Hook-Maker\' + $_ + '\' + $_ + '.ps1"'); timeout = 60 } })
        $handlers += @{ type = 'command'; command = 'powershell.exe -File "C:\p\.claude\hooks\Hook-Maker\Session-Summary-Check\Session-Summary-Check.ps1"' }
        $handlers += @{ type = 'command'; command = 'node C:\elsewhere\my-own-hook.js' }
        $doc = @{ hooks = @{ Stop = @(@{ hooks = $handlers }) } }
        [IO.File]::WriteAllText($path, ($doc | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    }
    function New-StopInput {
        param($Boundary, [string]$Answer = "DONE: shipped and verified`nREMAINING: none")
        $stop = $Boundary.PSObject.Copy()
        $stop.hook_event_name = 'Stop'
        Set-ObjectProperty -Object $stop -Name 'last_assistant_message' -Value $Answer
        return $stop
    }
    function Set-Receipt {
        param($HookInput, [string]$Gate, [string]$Verdict, [switch]$Crash)
        $receipt = Start-StopGateReceipt -HookInput $HookInput -HookName $Gate
        if ($Verdict -eq 'block') { $script:StopGateVerdict = 'block' }
        if ($Crash) { $receipt.Crashed = $true }
        if ($Verdict -ne 'running') { Complete-StopGateReceipt $receipt }
        return $receipt
    }
    function Get-ReceiptVerdict { param($HookInput, [string]$Gate) (Read-StopGateReceipt -Path (Get-StopGateReceiptPath -HookInput $HookInput -Gate $Gate)).Verdict }

    # --- FR-013: the receipt lifecycle -------------------------------------------
    $rb = Start-GenTask -Session 's-rcpt-life'
    $rs = New-StopInput $rb
    Check 'R01 a gate outside a Stop round writes no receipt' ($null -eq (Start-StopGateReceipt -HookInput $rb -HookName 'Git-Sync-Check'))
    $null = Set-Receipt $rs 'Git-Sync-Check' 'running'
    Check 'R02 a gate that has only started reads as running, never pass' ((Get-ReceiptVerdict $rs 'Git-Sync-Check') -ceq 'running')
    $null = Set-Receipt $rs 'Git-Sync-Check' 'pass'
    Check 'R03 a gate that finished without a block writes pass' ((Get-ReceiptVerdict $rs 'Git-Sync-Check') -ceq 'pass')
    $null = Set-Receipt $rs 'Large-File-Check' 'block'
    Check 'R04 a gate that blocked writes block' ((Get-ReceiptVerdict $rs 'Large-File-Check') -ceq 'block')
    $null = Set-Receipt $rs 'Secrets-Check' 'pass' -Crash
    Check 'R05 a gate that threw writes error' ((Get-ReceiptVerdict $rs 'Secrets-Check') -ceq 'error')
    $script:StopGateVerdict = ''
    $rulesReceipt = Set-Receipt $rs 'Rules-Check' 'running'
    $blockProbe = Write-StopBlockResult -HookInput $rs -HookName 'Rules-Check' -EventName 'Stop' -Reason 'RULES CHECK: receipt probe finding'
    Check 'R06 Write-StopBlockResult marks the round as a block for the receipt' ($script:StopGateVerdict -ceq 'block') ([string]$script:StopGateVerdict)
    Complete-StopGateReceipt $rulesReceipt
    $reentry = $rs.PSObject.Copy()
    Set-ObjectProperty -Object $reentry -Name 'stop_hook_active' -Value $true
    # A task-scoped runtime does not stand a gate down on re-entry: it
    # re-evaluates, and an unchanged finding is deduplicated by admission rather
    # than shown again. The round must still end `block`, never `pass`.
    $rulesAgain = Start-StopGateReceipt -HookInput $reentry -HookName 'Rules-Check'
    $null = Write-StopBlockResult -HookInput $reentry -HookName 'Rules-Check' -EventName 'Stop' -Reason 'RULES CHECK: receipt probe finding'
    if ($null -ne $rulesAgain) { Complete-StopGateReceipt $rulesAgain }
    Check 'R06b an unresolved finding re-evaluated on re-entry stays block even when its repeat is suppressed' (
        (Get-ReceiptVerdict $rs 'Rules-Check') -ceq 'block') ([string](Get-ReceiptVerdict $rs 'Rules-Check'))

    # --- FR-014: the required set comes from the client's own registration -------
    Write-ReceiptRegistration -Gates @('Git-Sync-Check', 'Large-File-Check')
    $req = Get-RequiredStopGates -HookInput $rs
    Check 'R07 required gates are the registered receipt gates only (observer and foreign hooks excluded)' (
        $req.Known -and (@($req.Gates) -join ',') -ceq 'Git-Sync-Check,Large-File-Check') ((@($req.Gates) -join ','))
    Write-ReceiptRegistration -Corrupt
    Check 'R08 an unreadable registration makes the set unknown, never empty-and-ready' (-not (Get-RequiredStopGates -HookInput $rs).Known)

    # --- FR-015/FR-016: the observer publishes READY only on every pass -----------
    Write-ReceiptRegistration -Gates @('Git-Sync-Check', 'Large-File-Check')
    $since = [DateTime]::UtcNow.AddSeconds(-1)
    $okBoundary = Start-GenTask -Session 's-rcpt-ready'
    $ok = New-StopInput $okBoundary
    $null = Set-Receipt $ok 'Git-Sync-Check' 'pass'
    $null = Set-Receipt $ok 'Large-File-Check' 'pass'
    Observe-GenerationSummary -HookInput $ok -Since $since
    $entry = Get-GenerationRecord -HookInput $ok
    Check 'R09 every registered gate passed -> published READY and finalized (SC-005)' (
        $null -ne $entry -and $entry.state -ceq 'finalized' -and $entry.publication.ready) ($entry | ConvertTo-Json -Depth 6 -Compress)

    $blkBoundary = Start-GenTask -Session 's-rcpt-block'
    $blk = New-StopInput $blkBoundary
    $null = Set-Receipt $blk 'Git-Sync-Check' 'pass'
    $null = Set-Receipt $blk 'Large-File-Check' 'block'
    Observe-GenerationSummary -HookInput $blk -Since $since
    $entry = Get-GenerationRecord -HookInput $blk
    Check 'R10 one blocking gate -> not ready, and the failure names that gate (SC-006)' (
        $null -ne $entry -and -not $entry.publication.ready -and $entry.publication.failure -match 'Large-File-Check:block' -and
        $entry.publication.failure -notmatch 'Git-Sync-Check:') ($entry | ConvertTo-Json -Depth 6 -Compress)

    $misBoundary = Start-GenTask -Session 's-rcpt-missing'
    $mis = New-StopInput $misBoundary
    $null = Set-Receipt $mis 'Git-Sync-Check' 'pass'
    $null = Set-Receipt $mis 'Large-File-Check' 'running'
    Observe-GenerationSummary -HookInput $mis -Since $since
    $entry = Get-GenerationRecord -HookInput $mis
    Check 'R11 a gate still running (e.g. killed by its timeout) -> no-receipt, not ready' (
        $null -ne $entry -and -not $entry.publication.ready -and $entry.publication.failure -match 'Large-File-Check:no-receipt') ($entry | ConvertTo-Json -Depth 6 -Compress)

    $oldBoundary = Start-GenTask -Session 's-rcpt-stale'
    $old = New-StopInput $oldBoundary
    $null = Set-Receipt $old 'Git-Sync-Check' 'pass'
    $null = Set-Receipt $old 'Large-File-Check' 'pass'
    Observe-GenerationSummary -HookInput $old -Since ([DateTime]::UtcNow.AddSeconds(5))
    $entry = Get-GenerationRecord -HookInput $old
    Check 'R12 a pass from an EARLIER round is not evidence for this one' (
        $null -ne $entry -and -not $entry.publication.ready -and $entry.publication.failure -match 'no-receipt') ($entry | ConvertTo-Json -Depth 6 -Compress)

    Write-ReceiptRegistration -Corrupt
    $unkBoundary = Start-GenTask -Session 's-rcpt-unknown'
    $unk = New-StopInput $unkBoundary
    Observe-GenerationSummary -HookInput $unk -Since $since
    $entry = Get-GenerationRecord -HookInput $unk
    Check 'R13 an unreadable registration -> not ready (never assumed)' (
        $null -ne $entry -and -not $entry.publication.ready -and $entry.publication.failure -match 'gate-registration-unreadable') ($entry | ConvertTo-Json -Depth 6 -Compress)
    Write-ReceiptRegistration -Gates @('Git-Sync-Check', 'Large-File-Check')

    # --- FR-016: a READY generation is collectable (T046) -------------------------
    $collected = Invoke-GenerationCollection -HookInput $ok
    Check 'R14 a READY, finalized generation is collected instead of filling the store' (
        -not $collected.Refused -and $collected.Collected -ge 1) ($collected | ConvertTo-Json -Compress)
