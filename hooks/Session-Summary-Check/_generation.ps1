# GENERATION STATE - what a unit of user work is, and when its record may go.
#
# ROLE: a plain STORE. Not a gate and not an executor over project state. It
# records transitions, aggregates what the gates already said, remembers that a
# summary was published, and collects what is finished. It blocks nothing and it
# writes nothing outside its own state file.
#
# WHY A SEPARATE FILE FROM THE TASK RECORD. The task record in _taskidentity.ps1
# is validated strictly and installed in 29 projects; a field added on one side
# of that fleet and read by a runtime that predates it makes every project's
# record read as corrupt at once, recoverable only by a full re-install. So the
# task record's schema is untouched and this state lives beside it, keyed the
# same way. docs/adr/0002-generation-state-in-its-own-file.md holds the two
# rejected alternatives and why each was worse.
#
# WHAT THIS CANNOT DO, STATED HERE SO NOBODY BUILDS ON THE WRONG BELIEF.
#
# 1. It detects and attributes a premature summary; it does not prevent one.
#    Claude Code runs Stop AFTER the response is displayed, and Codex answers a
#    rejected Stop by synthesising a continuation rather than un-sending a turn
#    that already finished. This observer cannot withhold a displayed response.
#    This passive observer does not own the client's output transport. A
#    display-level guarantee needs an output-owning integration, not this store.
#
# 2. A Stop event is not evidence that a summary exists, nor that every gate
#    passed. The observer requires eligible CURRENT assistant text, and
#    readiness requires a `pass` receipt (_gatereceipts.ps1) from every gate the
#    client registered, written in this Stop round. A missing, running, blocked
#    or crashed gate keeps the publication not-ready and is named once.
#    This store never authorizes skipping a gate or claims control of a UI.
#
# THE ALLOWANCE IS WHY A CONTINUATION IS NOT A NEW GENERATION. A hook-generated
# correction carries the same task id and therefore lands on the same
# generation. If it started a new one, every block would refund the correction
# allowance it was supposed to spend - the exact loop the task record exists to
# bound. Nothing here may key a generation to a turn, a timestamp, or a
# transcript statistic.

Set-StrictMode -Version 2.0

$script:GenerationSchema = 1
$script:GenerationMaxEntries = 32
$script:GenerationMaxTombstones = 64
$script:GenerationLiveStates = @('working', 'validating', 'ready')
$script:GenerationTerminalStates = @('finalized', 'unverified')

function Get-GenerationPath {
    param([AllowEmptyString()][string]$ProjectRoot = '', [string]$SessionId = '', [string]$Client = '')
    # Same directory and the same two key functions as the task record, so a
    # generation and its task record are always found from the same inputs and
    # there is no second resolution path to drift.
    $stem = 'Generation-' + (Get-StopProjectKey -ProjectRoot $ProjectRoot)
    if ($SessionId -ne '' -and $Client -ne '') { $stem += '-' + (Get-ShortHash ($Client + '|' + $SessionId)) }
    return (Join-Path (Join-Path $env:LOCALAPPDATA 'HookMaker\state') ($stem + '.json'))
}

function Get-GenerationScope {
    param($HookInput)
    $session = [string](Get-Field $HookInput 'session_id')
    $client = Get-HookClientId
    $root = [string](Get-Field $HookInput 'cwd')
    if ([string]::IsNullOrWhiteSpace($session) -or $client -eq 'unknown' -or [string]::IsNullOrWhiteSpace($root)) { return $null }
    $actor = ''
    if ($null -ne (Get-Command Get-StopAgentKey -ErrorAction SilentlyContinue)) {
        try { $actor = [string](Get-StopAgentKey -HookInput $HookInput) } catch { $actor = '' }
    }
    return [pscustomobject]@{
        Session = $session; Client = $client; Root = $root; Actor = $actor
        Path    = (Get-GenerationPath -ProjectRoot $root -SessionId $session -Client $client)
    }
}

function Get-GenerationIdentity {
    param($HookInput)
    $scope = Get-GenerationScope $HookInput
    if ($null -eq $scope) { return $null }
    if ($null -eq (Get-Command Get-CurrentUserTaskIdentity -ErrorAction SilentlyContinue)) { return $null }
    $identity = Get-CurrentUserTaskIdentity -HookInput $HookInput
    # Degraded identity is reported, never invented. A generation keyed to a
    # guessed task id would merge two tasks or split one, and both are worse
    # than recording nothing.
    if ($null -eq $identity -or $identity.Degraded -or [string]::IsNullOrWhiteSpace([string]$identity.TaskId)) { return $null }
    return [pscustomobject]@{ Scope = $scope; TaskId = [string]$identity.TaskId; Actor = $scope.Actor }
}

function Test-GenerationEntryShape {
    param($Entry)
    if ($Entry -isnot [System.Management.Automation.PSCustomObject]) { throw 'generation entry shape' }
    foreach ($name in @('taskId', 'actor', 'state', 'evidence', 'verdicts', 'publication', 'endedAt')) {
        if ($null -eq $Entry.PSObject.Properties[$name]) { throw 'missing generation field' }
    }
    Test-GenerationKeyShape -Value $Entry
    if ($Entry.state -isnot [string] -or $Entry.state -cnotin ($script:GenerationLiveStates + $script:GenerationTerminalStates)) { throw 'generation vocabulary' }
    if ($Entry.evidence -isnot [string] -or $Entry.evidence.Length -gt 4096) { throw 'generation evidence shape' }
    $terminal = $Entry.state -cin $script:GenerationTerminalStates
    if ($terminal) { Test-GenerationTimestamp $Entry.endedAt }
    elseif ($null -ne $Entry.endedAt -and $Entry.endedAt -cne '') { throw 'generation terminality' }
    if ($Entry.verdicts -isnot [System.Array] -or @($Entry.verdicts).Count -gt 64) { throw 'unbounded generation verdicts' }
    $seen = @{}
    foreach ($verdict in @($Entry.verdicts)) {
        if ($verdict -isnot [System.Management.Automation.PSCustomObject]) { throw 'generation verdict shape' }
        foreach ($name in @('gate', 'affirmative', 'at')) {
            if ($null -eq $verdict.PSObject.Properties[$name]) { throw 'malformed generation verdict' }
        }
        if ($verdict.gate -isnot [string] -or $verdict.gate -cnotmatch '^[A-Za-z0-9-]{1,64}$' -or $seen.ContainsKey($verdict.gate)) { throw 'generation verdict name' }
        if ($verdict.affirmative -isnot [bool]) { throw 'generation verdict boolean' }
        Test-GenerationTimestamp $verdict.at
        $seen[$verdict.gate] = $true
    }
    if ($null -ne $Entry.publication) {
        $pub = $Entry.publication
        if ($pub -isnot [System.Management.Automation.PSCustomObject]) { throw 'generation publication shape' }
        foreach ($name in @('at', 'ready', 'failure', 'reported')) {
            if ($null -eq $pub.PSObject.Properties[$name]) { throw 'missing publication field' }
        }
        Test-GenerationTimestamp $pub.at
        if ($pub.ready -isnot [bool] -or $pub.reported -isnot [bool] -or $pub.failure -isnot [string] -or $pub.failure.Length -gt 8192) { throw 'generation publication fields' }
        if (($pub.ready -and $pub.failure -ne '') -or (-not $pub.ready -and [string]::IsNullOrWhiteSpace($pub.failure))) { throw 'generation publication verdict' }
    }
}

function Test-GenerationKeyShape {
    param($Value)
    foreach ($name in @('taskId', 'actor')) {
        if ($null -eq $Value.PSObject.Properties[$name] -or $Value.$name -isnot [string]) { throw 'generation key shape' }
    }
    if ($Value.taskId -cnotmatch '^[A-Za-z0-9._-]{1,128}$' -or $Value.actor.Length -gt 256) { throw 'generation identity' }
}

function Test-GenerationTimestamp {
    param($Value)
    # Older Core JSON decoders materialize ISO dates; Windows PowerShell keeps
    # strings. Both representations denote the same timestamp, not a boolean.
    if ($Value -is [DateTime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) { throw 'generation timestamp timezone' }
        return
    }
    $parsed = [DateTime]::MinValue
    if ($Value -isnot [string] -or -not [DateTime]::TryParseExact($Value, 'o', [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed) -or $parsed.Kind -eq [DateTimeKind]::Unspecified) { throw 'generation timestamp' }
}

function Get-GenerationDocumentState {
    param([string]$Path)
    try {
        if ([IO.Directory]::Exists($Path)) { return [pscustomobject]@{ State = 'corrupt'; Doc = $null } }
        if (-not [IO.File]::Exists($Path)) { return [pscustomobject]@{ State = 'absent'; Doc = $null } }
        if ((Get-Item -LiteralPath $Path -ErrorAction Stop).Length -gt 262144) { throw 'oversized generation document' }
        $raw = [IO.File]::ReadAllText($Path, (New-Object Text.UTF8Encoding($false, $true)))
        if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $doc = $raw | ConvertFrom-Json -DateKind String }
        else { $doc = $raw | ConvertFrom-Json }
        if ($null -eq $doc -or $doc -isnot [System.Management.Automation.PSCustomObject]) { throw 'generation shape' }
        $version = 0
        if (-not [int]::TryParse([string](Get-Field $doc 'schema'), [ref]$version)) { throw 'generation version' }
        if ($version -ne $script:GenerationSchema) { return [pscustomobject]@{ State = 'unsupported'; Doc = $null } }
        foreach ($name in @('sessionId', 'client', 'generations', 'tombstones')) {
            if ($null -eq $doc.PSObject.Properties[$name]) { throw ('missing generation document field: ' + $name) }
        }
        if ($doc.client -isnot [string] -or $doc.client -cnotin @('claude', 'codex') -or $doc.sessionId -isnot [string] -or [string]::IsNullOrWhiteSpace($doc.sessionId)) { throw 'generation client or session' }
        if ($doc.generations -isnot [System.Array] -or @($doc.generations).Count -gt $script:GenerationMaxEntries) { throw 'unbounded generations' }
        if ($doc.tombstones -isnot [System.Array] -or @($doc.tombstones).Count -gt $script:GenerationMaxTombstones) { throw 'unbounded tombstones' }
        $identities = @{}
        foreach ($entry in @($doc.generations)) {
            Test-GenerationEntryShape -Entry $entry
            $key = @($entry.taskId, $entry.actor) | ConvertTo-Json -Compress
            if ($identities.ContainsKey($key)) { throw 'duplicate generation identity' }
            $identities[$key] = $true
        }
        foreach ($stone in @($doc.tombstones)) {
            if ($stone -isnot [System.Management.Automation.PSCustomObject]) { throw 'tombstone shape' }
            Test-GenerationKeyShape $stone
            Test-GenerationTimestamp (Get-Field $stone 'endedAt')
            $key = @($stone.taskId, $stone.actor) | ConvertTo-Json -Compress
            if ($identities.ContainsKey($key)) { throw 'duplicate or resurrected tombstone' }
            $identities[$key] = $true
        }
        return [pscustomobject]@{ State = 'valid'; Doc = $doc }
    }
    catch { return [pscustomobject]@{ State = 'corrupt'; Doc = $null } }
}

function New-GenerationDocument {
    param($Scope)
    return [pscustomobject][ordered]@{
        schema = $script:GenerationSchema; sessionId = $Scope.Session; client = $Scope.Client
        generations = @(); tombstones = @()
    }
}

function Invoke-GenerationUpdate {
    # ARGUMENTS ARE PASSED, NEVER CLOSED OVER. An unbound scriptblock resolves a
    # free variable against the live call stack, and PowerShell names are
    # case-insensitive - so a mutation referring to $State picked up THIS
    # function's own $state local instead of its caller's parameter, wrote an
    # object where a state name belonged, and every such write was rejected as
    # invalid. The entry then reappeared with its default state and three
    # assertions failed while a fourth passed for the wrong reason. Nothing here
    # may go back to relying on a mutation's enclosing scope.
    param($HookInput, [scriptblock]$Mutate, [hashtable]$Arguments = @{})
    $identity = Get-GenerationIdentity $HookInput
    if ($null -eq $identity) { return [pscustomobject]@{ Ok = $false; State = 'identity-unavailable'; Result = $null } }
    $scope = $identity.Scope
    $handle = $null; $temp = ''
    try {
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $scope.Path))
        $deadline = [DateTime]::UtcNow.AddSeconds(2)
        do {
            try { $handle = [IO.File]::Open(($scope.Path + '.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
            catch {
                if ([DateTime]::UtcNow -ge $deadline) { return [pscustomobject]@{ Ok = $false; State = 'busy'; Result = $null } }
                Start-Sleep -Milliseconds 20
            }
        } while ($null -eq $handle)
        $docState = Get-GenerationDocumentState -Path $scope.Path
        if ($docState.State -notin @('absent', 'valid')) { return [pscustomobject]@{ Ok = $false; State = ('document-' + $docState.State); Result = $null } }
        $doc = if ($null -eq $docState.Doc) { New-GenerationDocument -Scope $scope } else { $docState.Doc }
        if ($doc.sessionId -cne $scope.Session -or $doc.client -cne $scope.Client) { return [pscustomobject]@{ Ok = $false; State = 'scope-mismatch'; Result = $null } }
        # Recheck identity after the wait: do not attribute a delayed mutation to
        # a task that was replaced while another handler owned this store lock.
        $current = Get-GenerationIdentity $HookInput
        if ($null -eq $current -or $current.TaskId -cne $identity.TaskId -or $current.Actor -cne $identity.Actor) {
            return [pscustomobject]@{ Ok = $false; State = 'identity-changed'; Result = $null }
        }
        $before = $doc | ConvertTo-Json -Depth 10 -Compress
        $mutateResult = & $Mutate $doc $identity $Arguments
        $after = $doc | ConvertTo-Json -Depth 10 -Compress
        if ($before -ceq $after) { return [pscustomobject]@{ Ok = $true; State = 'ok'; Result = $mutateResult } }
        $temp = $scope.Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        [IO.File]::WriteAllText($temp, ($doc | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
        # Re-read what was actually written. Committing a document this very
        # reader would reject is how a store starts lying about its own state,
        # and returning here leaves the previous valid bytes in place.
        if ((Get-GenerationDocumentState -Path $temp).State -ne 'valid') {
            return [pscustomobject]@{ Ok = $false; State = 'mutation-invalid-or-capacity'; Result = $null }
        }
        if ([IO.File]::Exists($scope.Path)) { [IO.File]::Replace($temp, $scope.Path, [NullString]::Value) }
        else { [IO.File]::Move($temp, $scope.Path) }
        $temp = ''
        return [pscustomobject]@{ Ok = $true; State = 'ok'; Result = $mutateResult }
    }
    catch {
        $message = [string]$_.Exception.Message
        $failure = switch -Wildcard ($message) {
            'generation-*-capacity' { 'capacity'; break }
            'generation retired' { 'retired'; break }
            'generation terminal' { 'terminal'; break }
            'generation invalid transition' { 'invalid-transition'; break }
            default { 'persistence-failed' }
        }
        return [pscustomobject]@{ Ok = $false; State = $failure; Result = $null }
    }
    finally {
        if ($temp -ne '' -and [IO.File]::Exists($temp)) { try { [IO.File]::Delete($temp) } catch { } }
        if ($null -ne $handle) { $handle.Dispose() }
        # Never unlink the lock file: another writer may already own that inode.
    }
}

function Find-GenerationEntry {
    param($Doc, [string]$TaskId, [AllowEmptyString()][string]$Actor)
    foreach ($entry in @($Doc.generations)) {
        if ([string]$entry.taskId -ceq $TaskId -and [string]$entry.actor -ceq $Actor) { return $entry }
    }
    return $null
}

function Test-GenerationRetired {
    param($Doc, [string]$TaskId, [AllowEmptyString()][string]$Actor)
    foreach ($stone in @($Doc.tombstones)) {
        if ([string]$stone.taskId -ceq $TaskId -and [string]$stone.actor -ceq $Actor) { return $true }
    }
    return $false
}

function Add-GenerationEntry {
    param($Doc, $Identity, [string]$Evidence)
    if (Test-GenerationRetired -Doc $Doc -TaskId $Identity.TaskId -Actor $Identity.Actor) { throw 'generation retired' }
    # Collection runs HERE and nowhere else: at the moment of pressure, paid for
    # by the write that needs the room. A hook process lives for milliseconds
    # and has no owner for a background prune.
    if (@($Doc.generations).Count -ge $script:GenerationMaxEntries) {
        $null = Remove-TerminalGenerations -Doc $Doc
        if (@($Doc.generations).Count -ge $script:GenerationMaxEntries) { throw 'generation-entry-capacity' }
    }
    $entry = [pscustomobject][ordered]@{
        taskId = $Identity.TaskId; actor = [string]$Identity.Actor; state = 'working'
        evidence = $Evidence; verdicts = @(); publication = $null; endedAt = $null
    }
    $Doc.generations = @(@($Doc.generations) + $entry)
    return $entry
}

function Remove-TerminalGenerations {
    param($Doc)
    $kept = New-Object System.Collections.ArrayList
    $stones = New-Object System.Collections.ArrayList
    foreach ($stone in @($Doc.tombstones)) { [void]$stones.Add($stone) }
    $collected = 0
    foreach ($entry in @($Doc.generations)) {
        # Terminality alone is not disposal authority. An unresolved verdict or
        # an unreported/unknown publication must remain available for review.
        $eligible = $entry.state -ceq 'finalized' -and $null -ne $entry.publication -and
            $entry.publication.ready -is [bool] -and $entry.publication.ready -and
            @($entry.verdicts | Where-Object { -not $_.affirmative }).Count -eq 0
        if ($eligible -and $stones.Count -lt $script:GenerationMaxTombstones) {
            [void]$stones.Add([pscustomobject][ordered]@{ taskId = $entry.taskId; actor = $entry.actor; endedAt = $entry.endedAt })
            $collected++
        }
        else { [void]$kept.Add($entry) }
    }
    # Never rotate away replay protection to make room. With no trustworthy
    # client replay horizon, capacity is an explicit refusal, not eviction.
    $Doc.generations = @($kept.ToArray())
    $Doc.tombstones = @($stones.ToArray())
    return $collected
}

function Get-GenerationRecord {
    param([Parameter(Mandatory = $true)]$HookInput)
    $identity = Get-GenerationIdentity $HookInput
    if ($null -eq $identity) { return $null }
    $state = Get-GenerationDocumentState -Path $identity.Scope.Path
    if ($state.State -ne 'valid' -or $state.Doc.sessionId -cne $identity.Scope.Session -or $state.Doc.client -cne $identity.Scope.Client) { return $null }
    return (Find-GenerationEntry -Doc $state.Doc -TaskId $identity.TaskId -Actor $identity.Actor)
}

function Set-GenerationState {
    param([Parameter(Mandatory = $true)]$HookInput, [Parameter(Mandatory = $true)][string]$State, [AllowEmptyString()][string]$Evidence = '')
    if ($State -notin ($script:GenerationLiveStates + $script:GenerationTerminalStates)) {
        return [pscustomobject]@{ Ok = $false; State = 'invalid-transition' }
    }
    $result = Invoke-GenerationUpdate -HookInput $HookInput -Arguments @{ Target = $State; Evidence = $Evidence } -Mutate {
        param($doc, $identity, $opt)
        if (Test-GenerationRetired -Doc $doc -TaskId $identity.TaskId -Actor $identity.Actor) { throw 'generation retired' }
        $entry = Find-GenerationEntry -Doc $doc -TaskId $identity.TaskId -Actor $identity.Actor
        if ($null -eq $entry) { $entry = Add-GenerationEntry -Doc $doc -Identity $identity -Evidence $opt.Evidence }
        if ($entry.state -cin $script:GenerationTerminalStates) {
            if ($entry.state -cne $opt.Target -or ($opt.Evidence -ne '' -and $entry.evidence -cne $opt.Evidence)) { throw 'generation terminal' }
            return $entry.state
        }
        if ($opt.Target -ceq 'finalized' -and ($null -eq $entry.publication -or -not $entry.publication.ready -or
            @($entry.verdicts | Where-Object { -not $_.affirmative }).Count -gt 0)) { throw 'generation invalid transition' }
        $entry.state = $opt.Target
        # Terminality and its timestamp are written together so the two can
        # never disagree; the validator rejects a document where they do.
        if ($opt.Target -in $script:GenerationTerminalStates) {
            if ([string]::IsNullOrWhiteSpace([string]$entry.endedAt)) { $entry.endedAt = [DateTime]::UtcNow.ToString('o') }
        }
        else { $entry.endedAt = $null }
        if ($opt.Evidence -ne '') { $entry.evidence = $opt.Evidence }
        return $entry.state
    }
    return [pscustomobject]@{ Ok = $result.Ok; State = $(if ($result.Ok) { 'ok' } else { $result.State }) }
}

function Register-GenerationVerdict {
    param([Parameter(Mandatory = $true)]$HookInput, [Parameter(Mandatory = $true)][string]$Gate, [bool]$Affirmative)
    $safe = $Gate
    if ($safe -cnotmatch '^[A-Za-z0-9-]{1,64}$') { return [pscustomobject]@{ Ok = $false; State = 'invalid-gate' } }
    $result = Invoke-GenerationUpdate -HookInput $HookInput -Arguments @{ Gate = $safe; Affirmative = $Affirmative } -Mutate {
        param($doc, $identity, $opt)
        $entry = Find-GenerationEntry -Doc $doc -TaskId $identity.TaskId -Actor $identity.Actor
        if ($null -eq $entry) { $entry = Add-GenerationEntry -Doc $doc -Identity $identity -Evidence '' }
        if ($entry.state -cin $script:GenerationTerminalStates) { throw 'generation terminal' }
        $kept = @(@($entry.verdicts) | Where-Object { [string]$_.gate -cne $opt.Gate })
        if ($kept.Count -ge 64) { throw 'generation-verdict-capacity' }
        $entry.verdicts = @($kept + [pscustomobject][ordered]@{ gate = $opt.Gate; affirmative = $opt.Affirmative; at = [DateTime]::UtcNow.ToString('o') })
        return $opt.Gate
    }
    return [pscustomobject]@{ Ok = $result.Ok; State = $(if ($result.Ok) { 'ok' } else { $result.State }) }
}

function Get-GenerationReadiness {
    param($Entry, [string[]]$Objections = @(), [string]$Evidence = '')
    $missing = New-Object System.Collections.ArrayList
    if ($null -eq $Entry) { return [pscustomobject]@{ Ready = $false; Missing = @('generation-unknown'); Evidence = '' } }
    if ($Entry.state -cnotin @('ready', 'finalized') -or [string]::IsNullOrWhiteSpace($Entry.evidence)) {
        [void]$missing.Add('validation-not-recorded')
    }
    # Old records may carry a terminal label without verified publication.
    # Preserve those bytes for review, but never turn the label into proof.
    if ($Entry.state -ceq 'finalized' -and ($null -eq $Entry.publication -or -not $Entry.publication.ready)) {
        [void]$missing.Add('publication-unverified')
    }
    foreach ($name in @($Objections)) {
        if ($name -cmatch '^[A-Za-z0-9._:-]{1,128}$') { [void]$missing.Add($name) }
        else { [void]$missing.Add('unverified-objection') }
    }
    foreach ($verdict in @($Entry.verdicts)) {
        if (-not $verdict.affirmative) { [void]$missing.Add($verdict.gate) }
    }
    if ($Evidence -ne '' -and $Entry.evidence -cne $Evidence) { [void]$missing.Add('evidence-moved') }
    $unique = @($missing | Sort-Object -Unique)
    return [pscustomobject]@{ Ready = ($unique.Count -eq 0); Missing = $unique; Evidence = $Entry.evidence }
}

function Test-GenerationReady {
    param([Parameter(Mandatory = $true)]$HookInput, [string[]]$Objections = @(), [AllowEmptyString()][string]$Evidence = '')
    return (Get-GenerationReadiness -Entry (Get-GenerationRecord $HookInput) -Objections $Objections -Evidence $Evidence)
}

function Publish-GenerationSummary {
    param([Parameter(Mandatory = $true)]$HookInput, [bool]$Ready, [string[]]$Missing = @())
    $result = Invoke-GenerationUpdate -HookInput $HookInput -Arguments @{ Ready = $Ready; Missing = $Missing } -Mutate {
        param($doc, $identity, $opt)
        if (Test-GenerationRetired -Doc $doc -TaskId $identity.TaskId -Actor $identity.Actor) { throw 'generation retired' }
        $entry = Find-GenerationEntry -Doc $doc -TaskId $identity.TaskId -Actor $identity.Actor
        if ($null -eq $entry) { $entry = Add-GenerationEntry -Doc $doc -Identity $identity -Evidence '' }
        # At most one OBSERVATION record per generation. Repeated callback
        # delivery resolves to the first record; this does not prevent an agent
        # from displaying a second summary outside this observer's control.
        if ($null -ne $entry.publication) {
            return [pscustomobject]@{ Published = $false; AlreadyPublished = $true; Failure = '' }
        }
        if ($entry.state -cin $script:GenerationTerminalStates) { throw 'generation terminal' }
        # The caller's earlier read is advisory. A verdict can arrive before
        # this lock is acquired; derive the committed decision under this lock.
        $check = Get-GenerationReadiness -Entry $entry -Objections $opt.Missing
        $confirmedReady = $opt.Ready -and $check.Ready
        $named = @($check.Missing)
        if (@($opt.Missing).Count -gt 0) { $named = @($named | Where-Object { $_ -ne 'validation-not-recorded' }) }
        if (-not $opt.Ready -and $named.Count -eq 0) { $named = @('readiness-unverified') }
        $failureText = if ($named.Count -eq 0) { 'unknown-verdict' } else { ($named -join ', ') }
        $entry.publication = [pscustomobject][ordered]@{ at = [DateTime]::UtcNow.ToString('o'); ready = $confirmedReady; failure = $(if ($confirmedReady) { '' } else { $failureText }); reported = $false }
        if ($confirmedReady) {
            $entry.state = 'finalized'
            $entry.endedAt = [DateTime]::UtcNow.ToString('o')
            return [pscustomobject]@{ Published = $true; AlreadyPublished = $false; Failure = '' }
        }
        # Published without readiness. Recorded, named ONCE, and never turned
        # into a demand for a correction line: the client displays the summary
        # before this code runs, so such a demand necessarily arrives after the
        # summary and breaks the very rule it is enforcing. That is the mistake
        # the previous attempt at this feature made.
        return [pscustomobject]@{ Published = $true; AlreadyPublished = $false; Failure = $failureText }
    }
    if (-not $result.Ok) { return [pscustomobject]@{ Published = $false; AlreadyPublished = $false; Failure = $result.State } }
    return $result.Result
}

function Read-GenerationFailureOnce {
    # WHY THIS EXISTS AND WHY IT IS ATOMIC. The summary is published at Stop,
    # and this hook is deliberately SILENT there: speaking at Stop costs one
    # extra assistant turn after the turn that finished the work, which is the
    # defect this hook's header records at length. So a premature publication is
    # recorded at Stop and NAMED at the next delivery - and it must be named
    # exactly once, however many handlers reach this point, or the report
    # becomes the nagging it was supposed to replace.
    param([Parameter(Mandatory = $true)]$HookInput)
    $result = Invoke-GenerationUpdate -HookInput $HookInput -Mutate {
        param($doc, $identity, $opt)
        $pending = ''
        foreach ($entry in @($doc.generations)) {
            if ($entry.actor -cne $identity.Actor) { continue }
            if ($null -eq $entry.publication) { continue }
            if ([bool]$entry.publication.ready) { continue }
            if ($null -ne $entry.publication.PSObject.Properties['reported'] -and [bool]$entry.publication.reported) { continue }
            $pending = [string]$entry.publication.failure
            # Claiming it inside the same locked write is what makes this once.
            Set-ObjectProperty -Object $entry.publication -Name 'reported' -Value $true
            break
        }
        return $pending
    }
    if (-not $result.Ok) { return '' }
    return [string]$result.Result
}

function Invoke-GenerationCollection {
    param([Parameter(Mandatory = $true)]$HookInput)
    $result = Invoke-GenerationUpdate -HookInput $HookInput -Mutate {
        param($doc, $identity, $opt)
        $collected = Remove-TerminalGenerations -Doc $doc
        if ($collected -eq 0) {
            # Explicit, and no budget is refilled by the failure. "Delete the
            # oldest" is what this refusal exists to prevent: the oldest entry
            # is as likely to be an active correction chain as anything else.
            return [pscustomobject]@{ Collected = 0; Refused = $true; Reason = 'no safely collectable record or tombstone capacity exhausted' }
        }
        return [pscustomobject]@{ Collected = $collected; Refused = $false; Reason = '' }
    }
    if (-not $result.Ok) { return [pscustomobject]@{ Collected = 0; Refused = $true; Reason = $result.State } }
    return $result.Result
}


function Test-GenerationSummaryText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text) -or $Text.Length -gt 1048576) { return $false }
    $done = '(?:DONE|\u0686\u06cc\s+\u0634\u062f|\u0627\u0646\u062c\u0627\u0645[\s\u200c-]*\u0634\u062f\u0647)'
    $remaining = '(?:REMAINING|\u0686\u06cc\s+\u0645\u0648\u0646\u062f|\u0628\u0627\u0642\u06cc[\s\u200c-]*\u0645\u0627\u0646\u062f\u0647)'
    $prefix = '^ {0,3}(?:[-*#]+[ \t]*)?'
    $suffix = '(?:[ \t]*\*{1,2})?[ \t]*(?::|[-\u2013\u2014]|$)[ \t]*(.*)$'
    $section = ''; $doneBody = $false; $remainingBody = $false
    $fence = ''; $fenceLength = 0
    foreach ($raw in @($Text -split '\r?\n')) {
        $line = $raw -replace '[\u200e\u200f\u202a-\u202e\u2066-\u2069\ufeff]', ''
        if ($line -match '^[ \t]*>' -or $line -match '^(?: {4}|\t)') { continue }
        if ($line -match '^ {0,3}(`{3,}|~{3,})(.*)$') {
            $marker = $Matches[1]; $rest = $Matches[2]
            if ($fence -eq '') { $fence = $marker.Substring(0, 1); $fenceLength = $marker.Length }
            elseif ($marker.StartsWith($fence) -and $marker.Length -ge $fenceLength -and $rest.Trim() -eq '') { $fence = ''; $fenceLength = 0 }
            continue
        }
        if ($fence -ne '') { continue }
        if ($line -match ($prefix + $done + $suffix)) { $section = 'done'; $line = $Matches[1] }
        elseif ($line -match ($prefix + $remaining + $suffix)) {
            if ($section -eq '' -or -not $doneBody) { return $false }
            $section = 'remaining'; $line = $Matches[1]
        }
        $body = $line.Trim().Trim('*', '-', '#', ' ').Trim()
        if ($body -eq '' -or $body -match '^(?:<[^>]*>|TBD|TODO|\.\.\.)$') { continue }
        if ($section -eq 'done') { $doneBody = $true }
        elseif ($section -eq 'remaining') { $remainingBody = $true }
    }
    return ($doneBody -and $remainingBody)
}

function Observe-GenerationSummary {
    param([Parameter(Mandatory = $true)]$HookInput, [object]$Since = $null)
    # Stop timing is not content evidence. The shared reader enforces current
    # role and child provenance and never borrows a parent's last response.
    $closing = Get-ClosingAssistantText -HookInput $HookInput
    if (-not $closing.Known -or -not (Test-GenerationSummaryText $closing.Text)) { return }
    # Readiness needs an AFFIRMATIVE receipt from every gate the client
    # registered for this event, written in THIS Stop round (spec 007 RD-4).
    # Absence of objections is not proof, and old blocks are only history.
    if ($null -eq (Get-Command Get-RequiredStopGates -ErrorAction SilentlyContinue)) {
        $null = Publish-GenerationSummary -HookInput $HookInput -Ready $false -Missing @('readiness-unverified')
        return
    }
    $required = Get-RequiredStopGates -HookInput $HookInput
    if (-not $required.Known) {
        $null = Publish-GenerationSummary -HookInput $HookInput -Ready $false -Missing @('gate-registration-unreadable')
        return
    }
    # A receipt older than this process (less a small skew for gates that
    # started first) belongs to an earlier round and is not evidence for this one.
    $since = if ($Since -is [DateTime]) { $Since.ToUniversalTime() } else { (Get-Process -Id $PID).StartTime.ToUniversalTime().AddSeconds(-3) }
    $verdicts = @{}
    if (@($required.Gates).Count -gt 0) { $verdicts = Wait-StopGateReceipts -HookInput $HookInput -Gates @($required.Gates) -Since $since }
    $missing = New-Object System.Collections.ArrayList
    foreach ($gate in @($required.Gates)) {
        $verdict = [string]$verdicts[$gate]
        $null = Register-GenerationVerdict -HookInput $HookInput -Gate $gate -Affirmative ($verdict -ceq 'pass')
        if ($verdict -cne 'pass') { [void]$missing.Add($gate + ':' + $verdict) }
    }
    if ($missing.Count -gt 0) {
        $null = Publish-GenerationSummary -HookInput $HookInput -Ready $false -Missing @($missing.ToArray())
        return
    }
    $evidence = 'receipts:' + (Get-ShortHash ((@($required.Gates) -join ',') + '|' + $since.ToString('o')))
    $null = Set-GenerationState -HookInput $HookInput -State 'ready' -Evidence $evidence
    $null = Publish-GenerationSummary -HookInput $HookInput -Ready $true
}
