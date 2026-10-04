# Note eligibility and audited legacy reconciliation are independent of run recovery.
# Called under the ledger mutex for migration; never invent a lesson for unknown evidence.
function New-NoteOrigin {
    param([string]$Kind, [string]$Path)
    if ($Kind -notin @('result', 'ownerless', 'always')) { return $null }
    try {
        $receipt = Read-RecoveryReceipt $Path
        $doc = $receipt.Doc
        $wd = [string](Get-Field $doc 'workingDirectory')
        $run = [string](Get-Field $doc 'runId')
        $cmd = [string](Get-Field $doc 'commandFingerprint')
        $expectedKind = if ($Kind -eq 'ownerless') { 'active' } else { 'result' }
        $prefix = 'TestRunGuard-' + $expectedKind + '-' + $script:projectKey
        if (-not [string]::Equals((Normalize-Path (Split-Path -Parent $receipt.Path)), (Normalize-Path $script:stateDir), [StringComparison]::OrdinalIgnoreCase) -or
            (Split-Path -Leaf $receipt.Path) -notlike ($prefix + '*.json')) { return $null }
        if ($wd -ne '' -and -not [string]::Equals((Normalize-Path $wd), (Normalize-Path $script:cwd), [StringComparison]::OrdinalIgnoreCase)) { return $null }
        # Legacy receipts have no optional run/command/root fields. The exact
        # project-keyed state path and byte hash still prove their origin;
        # missing fields remain unknown, never invented or used for retirement.
        if ($Kind -eq 'always' -and ([string]::IsNullOrWhiteSpace($run) -or [string]::IsNullOrWhiteSpace($cmd))) { return $null }
        return [pscustomobject]@{
            kind=$Kind; projectKey=$script:projectKey; workingDirectory=(Normalize-Path $script:cwd)
            receiptPath=$receipt.Path; receiptSha256=$receipt.Sha256; runId=$run; commandFingerprint=$cmd
            overall=$(if ($Kind -eq 'ownerless') { 'ownerless' } else { [string](Get-Field $doc 'overall') })
            endedUtc=[string](Get-Field $doc 'endedUtc'); recordedUtc=[DateTime]::UtcNow.ToString('o')
        }
    }
    catch { return $null }
}

function Test-NoteOrigin {
    param($Origin)
    if ($null -eq $Origin) { return $false }
    $kind = [string](Get-Field $Origin 'kind')
    if ($kind -notin @('result', 'ownerless', 'always')) { return $false }
    $wd = [string](Get-Field $Origin 'workingDirectory')
    if ([string]::IsNullOrWhiteSpace($wd) -or [string](Get-Field $Origin 'projectKey') -ne $script:projectKey -or
        -not [string]::Equals((Normalize-Path $wd), (Normalize-Path $script:cwd), [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $path = [string](Get-Field $Origin 'receiptPath')
    if ([string](Get-Field $Origin 'receiptSha256') -notmatch '^[a-f0-9]{64}$' -or [string]::IsNullOrWhiteSpace($path)) { return $false }
    $expectedKind = if ($kind -eq 'ownerless') { 'active' } else { 'result' }
    $prefix = 'TestRunGuard-' + $expectedKind + '-' + $script:projectKey
    try {
        if (-not [string]::Equals((Normalize-Path (Split-Path -Parent $path)), (Normalize-Path $script:stateDir), [StringComparison]::OrdinalIgnoreCase) -or
            (Split-Path -Leaf $path) -notmatch ('^' + [regex]::Escape($prefix) + '(?:-[a-z0-9]+)?\.json$')) { return $false }
    }
    catch { return $false }
    if ($kind -eq 'always' -and ([string]::IsNullOrWhiteSpace([string](Get-Field $Origin 'runId')) -or [string]::IsNullOrWhiteSpace([string](Get-Field $Origin 'commandFingerprint')))) { return $false }
    return $true
}

function Test-NoteObligationActionable {
    param($Entry)
    return (-not [string]::IsNullOrWhiteSpace([string](Get-Field $Entry 'reason')) -and (Test-NoteOrigin (Get-Field $Entry 'origin')))
}

function Backup-CompletionLedger {
    # Byte copy with create-new semantics: no overwrite, reparse escape or falsely reported backup.
    if ($script:LedgerLegacyBackup -ne '') { return $script:LedgerLegacyBackup }
    $original = Read-RecoveryReceipt $script:statePath
    $dir = Join-Path $script:stateDir 'completion-backups'
    if (-not (Test-Path -LiteralPath $dir)) { [void][IO.Directory]::CreateDirectory($dir) }
    if (((Get-Item -LiteralPath $dir).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Completion backup directory must not be a reparse point.' }
    $path = Join-Path $dir ((Split-Path -Leaf $script:statePath) + '.' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N') + '.bak')
    $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $bytes=[IO.File]::ReadAllBytes($script:statePath); $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
    if ((Read-RecoveryReceipt $path).Sha256 -ne $original.Sha256) { throw 'Completion ledger changed while its backup was being verified.' }
    $script:LedgerLegacyBackup = $path
    return $path
}

function Repair-LegacyNoteObligations {
    $backup = ''
    $results = @(Get-CompletionStateEntries 'result')
    foreach ($key in @($script:pendingNotes.Keys)) {
        $entry = $script:pendingNotes[$key]
        if (Test-NoteOrigin (Get-Field $entry 'origin')) { continue }
        $matchesFound = @($results | Where-Object { (Get-ResultIncidentKey $_.Doc $_.Path) -eq $key -or (Get-ResultIncidentKeyLegacy $_.Doc $_.Path) -eq $key })
        if ($matchesFound.Count -ne 1) {
            $markers = @(@(Get-CompletionStateEntries 'active') | Where-Object { (Get-AbandonedIncidentKey $_.Doc) -eq $key })
            if ($markers.Count -ne 1) { continue }
            $markerState = Get-ActiveMarkerState -Doc $markers[0].Doc -Path $markers[0].Path -MaxAgeHours $script:activeMarkerMaxHours -ResultEntries $results
            if ($markerState.State -ne 'died') { continue }
            $markerOrigin = New-NoteOrigin -Kind ownerless -Path $markers[0].Path
            if ($null -eq $markerOrigin) { continue }
            if ((Get-AbandonedIncidentKey (Read-RecoveryReceipt $markers[0].Path).Doc) -ne $key) { continue }
            if ($backup -eq '') { $backup = Backup-CompletionLedger }
            $script:pendingNotes[$key] = [pscustomobject]@{ reason='a guarded run died without recording its outcome: ' + $markerState.Detail; baseline=[int64]$entry.baseline; origin=$markerOrigin }
            continue
        }
        $origin = New-NoteOrigin -Kind result -Path $matchesFound[0].Path
        if ($null -eq $origin) { continue }
        $receipt = Read-RecoveryReceipt $matchesFound[0].Path
        if ($receipt.Sha256 -ne $origin.receiptSha256 -or
            ((Get-ResultIncidentKey $receipt.Doc $receipt.Path) -ne $key -and (Get-ResultIncidentKeyLegacy $receipt.Doc $receipt.Path) -ne $key)) { continue }
        $cause = Get-IncidentReasonFromDoc $receipt.Doc
        $ordinary = (-not [string]::IsNullOrWhiteSpace([string](Get-Field $receipt.Doc 'workingDirectory')) -and
            -not [string]::IsNullOrWhiteSpace([string](Get-Field $receipt.Doc 'runId')) -and
            -not [string]::IsNullOrWhiteSpace([string](Get-Field $receipt.Doc 'commandFingerprint')) -and
            [string](Get-Field $receipt.Doc 'overall') -eq 'failed' -and
            (Get-Field $receipt.Doc 'terminated') -eq $false -and
            [string]::IsNullOrWhiteSpace([string](Get-Field $receipt.Doc 'terminateReason')) -and
            [string]::IsNullOrWhiteSpace($cause))
        # A nonempty legacy cause might describe explicit always mode or another
        # policy. Only the proven empty-cause assertion-failure bug is retired.
        if ($cause -eq '' -and -not ($ordinary -and [string]::IsNullOrWhiteSpace([string]$entry.reason))) { continue }
        if ($backup -eq '') { $backup = Backup-CompletionLedger }
        if ($ordinary) {
            $script:retiredNotes[$key] = [pscustomobject]@{ key=[string]$key; reason='ordinary assertion failure is not note-eligible'; origin=$origin; backupPath=$backup; retiredUtc=[DateTime]::UtcNow.ToString('o') }
            $script:pendingNotes.Remove($key)
        }
        else {
            $script:pendingNotes[$key] = [pscustomobject]@{ reason=$cause; baseline=[int64]$entry.baseline; origin=$origin }
        }
    }
    while ($script:retiredNotes.Count -gt $script:MaxPendingNotes) { $script:retiredNotes.Remove([string]@($script:retiredNotes.Keys)[0]) }
}

function Get-UnknownNoteDiagnostic {
    $unknown = @($script:pendingNotes.Keys | Where-Object { -not (Test-NoteObligationActionable $script:pendingNotes[$_]) })
    if ($unknown.Count -eq 0) { return @() }
    $fingerprint = Get-ShortHash (($unknown | ForEach-Object { [string]$_ + '|' + [string]$script:pendingNotes[$_].reason }) -join ';')
    if ($fingerprint -eq $script:noteDiagnosticFingerprint) { return @() }
    $script:noteDiagnosticFingerprint = $fingerprint
    $shown = @($unknown | Select-Object -First 5)
    return @('TEST COMPLETION CHECK (diagnostic): ' + $unknown.Count + ' legacy note record(s) have UNKNOWN origin or cause: ' + ($shown -join ', ') +
        $(if ($unknown.Count -gt 5) { ' (first five shown)' } else { '' }) + '. Preserved, not resolved. No invented lesson or acknowledgement is required. Correlate the original project/command/outcome/receipt before selective repair.')
}

function Write-UnknownNoteDiagnostic {
    $lines = @(Get-UnknownNoteDiagnostic)
    if ($lines.Count -eq 0) { return }
    Save-CompletionState
    # Stop additionalContext continues the conversation. Unknown legacy state
    # is status, not a fabricated task; use the non-continuing common field.
    [Console]::Out.WriteLine(([ordered]@{ systemMessage=($lines -join "`n") } | ConvertTo-Json -Compress))
}
