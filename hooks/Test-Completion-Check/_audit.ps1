# Explicit audit writes one new report, never the evidence or incident ledger.
# SUPERSEDED is historical same-command recovery, not SUCCESS or CURRENT proof.
function Get-AuditBytesHash {
    param([byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
}

function Get-AuditEvidenceFiles {
    $files = @()
    if (-not [IO.Directory]::Exists($script:stateDir)) { return $files }
    foreach ($kind in @('result','observed','active')) {
        $files += @(Get-ChildItem -LiteralPath $script:stateDir -Filter ('TestRunGuard-' + $kind + '-' + $script:projectKey + '-*.json') -File -ErrorAction Stop)
        $legacy = Join-Path $script:stateDir ('TestRunGuard-' + $kind + '-' + $script:projectKey + '.json')
        if ([IO.File]::Exists($legacy)) { $files += Get-Item -LiteralPath $legacy -ErrorAction Stop }
    }
    return @($files | Sort-Object FullName)
}

function Export-CompletionEvidenceAudit {
    param([string]$Path, $State)
    $destination = [IO.Path]::GetFullPath($Path)
    if ([IO.File]::Exists($destination)) { throw 'Audit destination already exists; choose a new local path. No existing file was overwritten.' }
    if (-not [IO.Directory]::Exists((Split-Path -Parent $destination))) { throw 'Audit destination directory must already exist.' }
    $results = New-Object 'Collections.Generic.List[object]'
    $observations = New-Object 'Collections.Generic.List[object]'
    $snapshots = New-Object 'Collections.Generic.List[object]'
    $rows = New-Object 'Collections.Generic.List[object]'
    $resultsByRun = New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::InvariantCultureIgnoreCase)
    $activeRunIds = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::InvariantCultureIgnoreCase)
    $snapshotsByPath = New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    $malformedActive = $false
    $files = @(Get-AuditEvidenceFiles)
    foreach ($file in $files) {
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $file.Length -gt 1048576) { throw 'Audit requires regular evidence files no larger than 1 MiB; incomplete coverage cannot be exported as complete.' }
        # Parse and digest the SAME bytes. Hashing after parsing could certify a
        # replacement receipt while the classification still described old bytes.
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        $hash = Get-AuditBytesHash $bytes
        $doc = $null
        try { $doc = ([Text.UTF8Encoding]::new($false,$true).GetString($bytes).TrimStart([char]0xFEFF) | ConvertFrom-Json) } catch { }
        $valid = ($null -ne $doc -and $doc -is [pscustomobject])
        $snapshot = [pscustomobject]@{ path = $file.FullName; sha256 = $hash; verdict = 'UNKNOWN'; parseState = $(if ($valid) { 'parsed' } else { 'malformed' }) }
        [void]$snapshots.Add($snapshot)
        $snapshotsByPath[$file.FullName] = $snapshot
        if (-not $valid) {
            if ($file.Name.StartsWith('TestRunGuard-active-')) { $malformedActive = $true }
            [void]$rows.Add([pscustomobject]@{ runId = $file.BaseName; commandFingerprint = ''; observedUtc = ''; verdict = 'UNKNOWN'; failedField = 'evidenceDocument:malformed'; candidateOverall = ''; gateWaived = $false })
            continue
        }
        $entry = [pscustomobject]@{ Path = $file.FullName; Doc = $doc }
        $runId = [string](Get-Field $doc 'runId')
        if ($file.Name.StartsWith('TestRunGuard-result-')) {
            [void]$results.Add($entry)
            # The sorted inventory's first matching run was the diagnostic candidate.
            if (-not $resultsByRun.ContainsKey($runId)) { $resultsByRun[$runId] = $entry }
        }
        if ($file.Name.StartsWith('TestRunGuard-observed-')) { [void]$observations.Add($entry) }
        if ($file.Name.StartsWith('TestRunGuard-active-')) { [void]$activeRunIds.Add($runId) }
    }
    # Historical matching uses recorded identity only. It never certifies current
    # Git state, waives the gate, changes a receipt, or resolves a ledger incident.
    $assignment = Get-ObservedResultAssignment -CurrentObserved $observations.ToArray() -ResultEntries $results.ToArray() -StateFp ''
    $pairsByCommand = New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::InvariantCultureIgnoreCase)
    $assignedResults = @{}
    for ($i = 0; $i -lt $assignment.SortedObserved.Count; $i++) {
        $result = if ($assignment.Map.ContainsKey($i)) { $assignment.Map[$i] } else { $null }
        if ($null -ne $result) {
            $observation = $assignment.SortedObserved[$i]
            $assignedResults[$observation.Path] = $result
            $command = [string](Get-Field $result.Doc 'commandFingerprint')
            if (-not $pairsByCommand.ContainsKey($command)) { $pairsByCommand[$command] = New-Object 'Collections.Generic.List[object]' }
            [void]$pairsByCommand[$command].Add([pscustomobject]@{ Observed = $observation.Doc; ResEntry = $result })
        }
    }
    foreach ($entry in $observations) {
        $runId = [string](Get-Field $entry.Doc 'runId')
        $command = [string](Get-Field $entry.Doc 'commandFingerprint')
        $paired = $assignedResults.ContainsKey($entry.Path)
        $doc = if ($paired) { $assignedResults[$entry.Path].Doc } elseif ($resultsByRun.ContainsKey($runId)) { $resultsByRun[$runId].Doc } else { $null }
        # A live or unproven active marker is an independent obligation. Audit
        # conservatively retains UNKNOWN rather than claiming its cleanup.
        $superseded = $false
        if (-not $malformedActive -and -not $activeRunIds.Contains($runId) -and -not $paired -and $pairsByCommand.ContainsKey($command)) {
            $superseded = Test-ObservationSuperseded -Observed $entry.Doc -Pairs $pairsByCommand[$command].ToArray() -StateFp (Get-ObservedFingerprint $entry.Doc)
        }
        $at = ConvertTo-UtcTime (Get-Field $entry.Doc 'observedUtc')
        [void]$rows.Add([pscustomobject][ordered]@{
            runId = $runId; commandFingerprint = $command
            observedUtc = $(if ($null -ne $at) { $at.ToString('o') } else { '' })
            verdict = $(if ($superseded) { 'SUPERSEDED' } else { 'UNKNOWN' })
            pairStatus = $(if ($paired) { 'PAIRED' } else { 'UNPAIRED' })
            pairedResultPath = $(if ($paired) { $assignedResults[$entry.Path].Path } else { '' })
            pairedResultHash = $(if ($paired) { [string]$snapshotsByPath[$assignedResults[$entry.Path].Path].sha256 } else { '' })
            failedField = $(if ($paired) { '' } else { Get-ObservationMatchingField $entry.Doc $doc (Get-ObservedFingerprint $entry.Doc) })
            candidateOverall = [string](Get-Field $doc 'overall'); gateWaived = $false
        })
    }
    foreach ($snapshot in $snapshots) {
        if ((Get-AuditBytesHash ([IO.File]::ReadAllBytes($snapshot.path))) -cne $snapshot.sha256) { throw 'Evidence changed concurrently; audit aborted without modifying originals. Retry after the producer finishes.' }
    }
    if ((@(Get-AuditEvidenceFiles | ForEach-Object { $_.FullName }) -join '|') -cne (@($files | ForEach-Object { $_.FullName }) -join '|')) { throw 'Evidence file set changed concurrently; audit aborted. Retry after the producer finishes.' }
    $report = [pscustomobject][ordered]@{ schema = 1; auditedUtc = [DateTime]::UtcNow.ToString('o'); projectKey = $State.ProjectKey; repositoryState = $State.State; repositoryStateFingerprint = $State.RepositoryStateFingerprint; gateWaived = $false; originals = $snapshots.ToArray(); observations = $rows.ToArray() }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($report | ConvertTo-Json -Depth 8))
    $stream = [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() } finally { $stream.Dispose() }
    [Console]::Out.WriteLine('Read-only evidence audit exported. Original hashes retained; UNKNOWN keeps the gate. No SUCCESS or incident resolution was recorded.')
}
