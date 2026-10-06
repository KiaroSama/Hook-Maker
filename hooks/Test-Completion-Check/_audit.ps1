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
    $results = @(); $observations = @(); $active = @(); $snapshots = @(); $rows = @()
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
        $snapshots += [pscustomobject]@{ path = $file.FullName; sha256 = $hash; verdict = 'UNKNOWN'; parseState = $(if ($valid) { 'parsed' } else { 'malformed' }) }
        if (-not $valid) {
            $rows += [pscustomobject]@{ runId = $file.BaseName; commandFingerprint = ''; observedUtc = ''; verdict = 'UNKNOWN'; failedField = 'evidenceDocument:malformed'; candidateOverall = ''; gateWaived = $false }
            continue
        }
        $entry = [pscustomobject]@{ Path = $file.FullName; Doc = $doc }
        if ($file.Name.StartsWith('TestRunGuard-result-')) { $results += $entry }
        if ($file.Name.StartsWith('TestRunGuard-observed-')) { $observations += $entry }
        if ($file.Name.StartsWith('TestRunGuard-active-')) { $active += $entry }
    }
    # Historical matching uses recorded identity only. It never certifies current
    # Git state, waives the gate, changes a receipt, or resolves a ledger incident.
    $assignment = Get-ObservedResultAssignment -CurrentObserved $observations -ResultEntries $results -StateFp ''
    $pairs = @(); $pairedObservationPaths = New-Object 'System.Collections.Generic.HashSet[string]'
    for ($i = 0; $i -lt $assignment.SortedObserved.Count; $i++) {
        $result = if ($assignment.Map.ContainsKey($i)) { $assignment.Map[$i] } else { $null }
        if ($null -ne $result) { [void]$pairedObservationPaths.Add($assignment.SortedObserved[$i].Path) }
        $pairs += [pscustomobject]@{ Observed = $assignment.SortedObserved[$i].Doc; ResEntry = $result }
    }
    foreach ($entry in $observations) {
        $candidate = @($results | Where-Object { [string](Get-Field $_.Doc 'runId') -eq [string](Get-Field $entry.Doc 'runId') })
        $doc = if ($candidate.Count -gt 0) { $candidate[0].Doc } else { $null }
        $hasActive = @($active | Where-Object { [string](Get-Field $_.Doc 'runId') -eq [string](Get-Field $entry.Doc 'runId') }).Count -gt 0
        # A live or unproven active marker is an independent obligation. Audit
        # conservatively retains UNKNOWN rather than claiming its cleanup.
        $superseded = (-not $hasActive -and -not $pairedObservationPaths.Contains($entry.Path) -and (Test-ObservationSuperseded -Observed $entry.Doc -Pairs $pairs -StateFp (Get-ObservedFingerprint $entry.Doc)))
        $at = ConvertTo-UtcTime (Get-Field $entry.Doc 'observedUtc')
        $rows += [pscustomobject][ordered]@{
            runId = [string](Get-Field $entry.Doc 'runId'); commandFingerprint = [string](Get-Field $entry.Doc 'commandFingerprint')
            observedUtc = $(if ($null -ne $at) { $at.ToString('o') } else { '' })
            verdict = $(if ($superseded) { 'SUPERSEDED' } else { 'UNKNOWN' })
            failedField = (Get-ObservationMatchingField $entry.Doc $doc (Get-ObservedFingerprint $entry.Doc))
            candidateOverall = [string](Get-Field $doc 'overall'); gateWaived = $false
        }
    }
    foreach ($snapshot in $snapshots) {
        if ((Get-AuditBytesHash ([IO.File]::ReadAllBytes($snapshot.path))) -cne $snapshot.sha256) { throw 'Evidence changed concurrently; audit aborted without modifying originals. Retry after the producer finishes.' }
    }
    if ((@(Get-AuditEvidenceFiles | ForEach-Object { $_.FullName }) -join '|') -cne (@($files | ForEach-Object { $_.FullName }) -join '|')) { throw 'Evidence file set changed concurrently; audit aborted. Retry after the producer finishes.' }
    $report = [pscustomobject][ordered]@{ schema = 1; auditedUtc = [DateTime]::UtcNow.ToString('o'); projectKey = $State.ProjectKey; repositoryState = $State.State; repositoryStateFingerprint = $State.RepositoryStateFingerprint; gateWaived = $false; originals = @($snapshots); observations = @($rows) }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($report | ConvertTo-Json -Depth 8))
    $stream = [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() } finally { $stream.Dispose() }
    [Console]::Out.WriteLine('Read-only evidence audit exported. Original hashes retained; UNKNOWN keeps the gate. No SUCCESS or incident resolution was recorded.')
}
