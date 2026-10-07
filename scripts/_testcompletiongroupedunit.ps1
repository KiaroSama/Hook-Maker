function Invoke-GroupedRecoveryUnitRegression {
    param([string]$RepoRoot)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repo = $RepoRoot
. (Join-Path $repo 'hooks\_hooklib.ps1')
. (Join-Path $repo 'hooks\Test-Completion-Check\_identity.ps1')
. (Join-Path $repo 'hooks\Test-Completion-Check\_evidence.ps1')
. (Join-Path $repo 'hooks\Test-Completion-Check\_recovery.ps1')
$script:cwd = Join-Path $repo 'fixture'
$work = Join-Path $repo ('.ci-work\duplicate-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($work)
$script:recoveryAssociations = New-Object System.Collections.Specialized.OrderedDictionary
$script:pendingNotes = New-Object System.Collections.Specialized.OrderedDictionary
$script:MaxResolvedIncidents = 50
$script:activeMarkerMaxHours = 24
$script:resolved = ''
$script:entries = @()
$script:resultReads = 0
$script:injectMember = $false
$script:injectedEntry = $null
$script:MalformedEvidence = New-Object 'System.Collections.Generic.List[string]'
$script:badRead = 0
$script:activeState = ''
function Get-RepositoryStateEvidence { param($ProjectRoot) return [pscustomobject]@{ State = 'available' } }
function Get-CompletionStateEntries {
    param($Kind)
    if ($Kind -eq 'result') {
        $script:resultReads++
        if ($script:badRead -eq $script:resultReads) { [void]$script:MalformedEvidence.Add('corrupt-result.json') }
        if ($script:injectMember -and $script:resultReads -eq 2) { $script:entries += $script:injectedEntry }
        return $script:entries
    }
    if ($script:activeState -ne '') { return [pscustomobject]@{ Doc = [pscustomobject]@{}; Path = 'uncertain-active.json' } }
    return @()
}
function Get-ActiveMarkerState { param($Doc, $Path, $MaxAgeHours, $ResultEntries) return [pscustomobject]@{ State = $script:activeState } }
function Test-NoteObligationActionable { param($Entry) return $false }
function Add-ResolvedIncident { param($Key) $script:resolved = $Key }
function Test-IncidentResolved { param($Key) return $script:resolved -ceq $Key }
function Write-FixtureReceipt {
    param([string]$RunId, [int]$Age, [bool]$Clean = $false)
    $doc = [pscustomobject][ordered]@{
        schema = 2; workingDirectory = $script:cwd; runId = $RunId
        commandFingerprint = ('a' * 32); projectFingerprint = $(if ($Clean) { 'verified-tree' } else { '' })
        overall = $(if ($Clean) { 'ok' } else { 'failed' }); exitCode = $(if ($Clean) { 0 } else { 1 })
        terminated = $false; terminateReason = ''; leakedProcessIds = @()
        startedUtc = [DateTime]::UtcNow.AddMinutes(-$Age).ToString('o')
        endedUtc = [DateTime]::UtcNow.AddMinutes(-$Age).AddSeconds(1).ToString('o')
    }
    $path = Join-Path $work ($RunId + '.json')
    [System.IO.File]::WriteAllText($path, ($doc | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
    $script:entries += [pscustomobject]@{ Doc = $doc; Path = $path }
    return $script:entries[-1]
}
function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
try {
    $one = Write-FixtureReceipt 'negative-one' 30
    $two = Write-FixtureReceipt 'negative-two' 20
    $green = Write-FixtureReceipt 'clean-recovery' 10 $true
    $key = Get-ResultIncidentKey $one.Doc $one.Path
    $hashes = @($script:entries | ForEach-Object { (Read-RecoveryReceipt $_.Path).Sha256 })
    $reason = 'The exact complete command ran clean after both historical failures; every original receipt is retained and process ownership and empty survivors were verified.'
    Set-VerifiedIncidentRecovery $key 'clean-recovery' $reason
    Assert-True ($script:resolved -ceq $key) 'The grouped incident was not resolved.'
    $association = $script:recoveryAssociations[$key]
    $pins = @(Get-Field $association 'negativeReceipts')
    Assert-True ($pins.Count -eq 2) 'Every grouped negative must have its own pinned receipt.'
    foreach ($entry in @($one, $two)) {
        $pin = @($pins | Where-Object { $_.runId -ceq $entry.Doc.runId })
        Assert-True ($pin.Count -eq 1 -and $pin[0].receiptSha256 -ceq (Read-RecoveryReceipt $entry.Path).Sha256) 'A negative receipt identity/hash was lost.'
        Assert-True (Test-RecoveryReceiptRetained $entry.Doc.runId) 'A grouped receipt is not retained.'
    }
    foreach ($entry in @($one, $two)) { Assert-True (Test-ResultIncidentResolved $entry.Doc $entry.Path) 'A pinned grouped result is not resolved.' }
    Set-VerifiedIncidentRecovery $key 'clean-recovery' $reason
    Assert-True ($script:recoveryAssociations.Count -eq 1) 'Repeated recovery is not idempotent.'
    $after = @($script:entries | ForEach-Object { (Read-RecoveryReceipt $_.Path).Sha256 })
    Assert-True (($hashes -join '|') -ceq ($after -join '|')) 'Recovery modified an original receipt.'
    # A later failure with the same group key must not inherit the old repair.
    $later = Write-FixtureReceipt 'later-negative' 5
    Assert-True (-not (Test-ResultIncidentResolved $later.Doc $later.Path)) 'A later same-key failure inherited historical recovery.'
    $priorAssociation = $association | ConvertTo-Json -Depth 10 -Compress
    $refused = $false
    try { Set-VerifiedIncidentRecovery $key 'clean-recovery' $reason } catch { $refused = $true }
    Assert-True $refused 'Recovery was accepted before the newest group member ended.'
    Assert-True (($script:recoveryAssociations[$key] | ConvertTo-Json -Depth 10 -Compress) -ceq $priorAssociation) 'Rejected extension changed the association.'
    $script:entries = @($one, $two, $green)
    $oldText = [System.IO.File]::ReadAllText($two.Path, [System.Text.Encoding]::UTF8)
    $oneText = [System.IO.File]::ReadAllText($one.Path, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($two.Path, ($oldText + "`n"), [System.Text.UTF8Encoding]::new($false))
    Assert-True (-not (Test-ResultIncidentResolved $two.Doc $two.Path)) 'Modified original bytes inherited historical recovery.'
    [System.IO.File]::WriteAllText($two.Path, $oldText, [System.Text.UTF8Encoding]::new($false))
    # Foreign root and duplicate identities stay refused even when their key matches.
    foreach ($variant in @('foreignRoot', 'duplicateId', 'missingId', 'futureNegative', 'failedRecovery', 'missingRecoveryIdentity', 'ambiguousRecovery', 'liveOriginalLeak')) {
        $script:entries = @($one, $two, $green)
        $greenText = [System.IO.File]::ReadAllText($green.Path, [System.Text.Encoding]::UTF8)
        $original = Read-RecoveryReceipt $two.Path
        switch ($variant) {
            'foreignRoot' { $original.Doc.workingDirectory = Join-Path $repo 'foreign' }
            'duplicateId' { $original.Doc.runId = $one.Doc.runId }
            'missingId' { $original.Doc.runId = '' }
            'futureNegative' { $original.Doc.endedUtc = [DateTime]::UtcNow.AddMinutes(1).ToString('o') }
            'failedRecovery' { $green.Doc.overall = 'failed'; $green.Doc.exitCode = 1 }
            'missingRecoveryIdentity' { $green.Doc.projectFingerprint = '' }
            'ambiguousRecovery' { $script:entries += $green }
            'liveOriginalLeak' {
                $one.Doc.leakedProcessIds = @($PID); $original.Doc.leakedProcessIds = @($PID)
                $now = [DateTime]::UtcNow
                $one.Doc.endedUtc = $now.ToString('o'); $original.Doc.endedUtc = $one.Doc.endedUtc
                $green.Doc.startedUtc = $now.AddMilliseconds(100).ToString('o'); $green.Doc.endedUtc = $now.AddMilliseconds(200).ToString('o')
                $key = Get-ResultIncidentKey $original.Doc $original.Path
                [System.IO.File]::WriteAllText($one.Path, ($one.Doc | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
            }

        }
        [System.IO.File]::WriteAllText($two.Path, ($original.Doc | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
        $two.Doc = $original.Doc
        [System.IO.File]::WriteAllText($green.Path, ($green.Doc | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
        $refused = $false
        try { Set-VerifiedIncidentRecovery $key 'clean-recovery' $reason } catch { $refused = $true; $refusal = $_.Exception.Message }
        if ($variant -eq 'liveOriginalLeak') { Assert-True ($refusal -match 'recorded leaked process is still present') ('The live-descendant refusal was not exercised: ' + $refusal) }
        Assert-True $refused ($variant + ': unsafe grouped recovery was accepted.')
        Assert-True (($script:recoveryAssociations[(Get-ResultIncidentKey ($oldText | ConvertFrom-Json) $two.Path)] | ConvertTo-Json -Depth 10 -Compress) -ceq $priorAssociation) ($variant + ': refusal changed historical association.')
        [System.IO.File]::WriteAllText($two.Path, $oldText, [System.Text.UTF8Encoding]::new($false))
        $two.Doc = ($oldText | ConvertFrom-Json)
        [System.IO.File]::WriteAllText($green.Path, $greenText, [System.Text.UTF8Encoding]::new($false))
        $green.Doc = ($greenText | ConvertFrom-Json)
        if ($variant -eq 'liveOriginalLeak') { [System.IO.File]::WriteAllText($one.Path, $oneText, [System.Text.UTF8Encoding]::new($false)); $one.Doc = ($oneText | ConvertFrom-Json); $key = Get-ResultIncidentKey $one.Doc $one.Path }
    }
    $legacy = $association | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $legacy.PSObject.Properties.Remove('negativeReceipts')
    $script:recoveryAssociations[$key] = $legacy
    $script:entries = @($one, $green)
    Set-VerifiedIncidentRecovery $key 'clean-recovery' $reason
    $singularResolved = $false
    try { $singularResolved = Test-ResultIncidentResolved $one.Doc $one.Path } catch { }
    Assert-True $singularResolved 'Legacy singular association compatibility was lost.'
    Assert-True (-not (Test-ResultIncidentResolved $two.Doc $two.Path)) 'Legacy singular association cleared an unpinned same-key original.'
    $script:entries = @($one, $two, $green)
    $refused = $false
    try { Set-VerifiedIncidentRecovery $key 'clean-recovery' $reason } catch { $refused = $true }
    Assert-True $refused 'Legacy singular association was silently expanded.'
    $script:recoveryAssociations.Clear()
    $script:injectedEntry = Write-FixtureReceipt 'concurrent-negative' 15
    $script:entries = @($one, $two, $green)
    $script:resultReads = 0; $script:injectMember = $true
    $refused = $false
    try { Set-VerifiedIncidentRecovery $key 'clean-recovery' $reason } catch { $refused = $_.Exception.Message -match 'receipt set changed' }
    Assert-True ($refused -and $script:recoveryAssociations.Count -eq 0) 'Concurrent new member was silently omitted at publication.'
    $script:injectMember = $false
    $script:entries = @($one, $two, $green)
    foreach ($variant in @('malformedInitial', 'malformedFinal', 'uncertainOwner', 'repeatUnknownNote', 'repeatMemberChange')) {
        $script:recoveryAssociations.Clear()
        if ($variant -like 'repeat*') { $script:recoveryAssociations[$key] = $association }
        $script:pendingNotes.Clear()
        if ($variant -eq 'repeatUnknownNote') { $script:pendingNotes[$key] = [pscustomobject]@{ baseline = 0; origin = $null } }
        $script:MalformedEvidence.Clear(); $script:resultReads = 0
        $script:badRead = if ($variant -eq 'malformedInitial') { 1 } elseif ($variant -eq 'malformedFinal') { 2 } else { 0 }
        $script:activeState = if ($variant -eq 'uncertainOwner') { 'died' } else { '' }
        $script:injectMember = $variant -eq 'repeatMemberChange'
        $beforeState = @($script:recoveryAssociations, $script:pendingNotes) | ConvertTo-Json -Depth 12 -Compress
        $refused = $false
        try { Set-VerifiedIncidentRecovery $key 'clean-recovery' $reason } catch { $refused = $true }
        Assert-True $refused ($variant + ': recovery admission was not refused.')
        $afterState = @($script:recoveryAssociations, $script:pendingNotes) | ConvertTo-Json -Depth 12 -Compress
        Assert-True ($beforeState -ceq $afterState) ($variant + ': refusal changed ledger state.')
        $script:entries = @($one, $two, $green)
    }
    Write-Output 'PASS: grouped recovery, all hash pins, idempotence, later/modified negatives, invalid members and legacy compatibility.'
}
finally { if ([System.IO.Directory]::Exists($work)) { [System.IO.Directory]::Delete($work, $true) } }

}
