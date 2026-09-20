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
#    that already finished. Neither client exposes a way to withhold a response.
#    A design whose correctness depends on holding the final section back cannot
#    be built on either supported client, and this one does not pretend to.
#
# 2. Readiness proves nothing OBJECTED, not that everything CHECKED. Verdicts
#    are read from the objections the gates already record, so a required gate
#    that never ran leaves no objection and is indistinguishable from one that
#    passed. Strengthening that needs an affirmative registration in every
#    shipped gate - one coordinated change across all of them - and is
#    deliberately not done here.
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
    foreach ($name in @('taskId', 'actor', 'state', 'evidence', 'verdicts', 'publication', 'endedAt')) {
        if ($null -eq $Entry.PSObject.Properties[$name]) { throw 'missing generation field' }
    }
    if ([string]::IsNullOrWhiteSpace([string]$Entry.taskId) -or [string]$Entry.taskId -notmatch '^[A-Za-z0-9._-]{1,128}$') { throw 'generation identity' }
    # An unknown state makes the document unreadable rather than defaulting.
    # Defaulting to live would make the entry uncollectable for ever; defaulting
    # to terminal would make it collectable while still in use.
    if ([string]$Entry.state -notin ($script:GenerationLiveStates + $script:GenerationTerminalStates)) { throw 'generation vocabulary' }
    $terminal = ([string]$Entry.state) -in $script:GenerationTerminalStates
    $ended = -not [string]::IsNullOrWhiteSpace([string]$Entry.endedAt)
    # Either half alone is a corrupt document: a terminal state with no end time
    # cannot be ordered for collection, and an end time on a live state would
    # make a working generation collectable.
    if ($terminal -ne $ended) { throw 'generation terminality' }
    if ($Entry.verdicts -isnot [System.Array] -or @($Entry.verdicts).Count -gt 64) { throw 'unbounded generation verdicts' }
    foreach ($verdict in @($Entry.verdicts)) {
        foreach ($name in @('gate', 'affirmative', 'at')) {
            if ($null -eq $verdict.PSObject.Properties[$name]) { throw 'malformed generation verdict' }
        }
        if ([string]$verdict.gate -notmatch '^[A-Za-z0-9-]{1,64}$') { throw 'generation verdict name' }
    }
}

function Get-GenerationDocumentState {
    param([string]$Path)
    try {
        if ([IO.Directory]::Exists($Path)) { return [pscustomobject]@{ State = 'corrupt'; Doc = $null } }
        if (-not [IO.File]::Exists($Path)) { return [pscustomobject]@{ State = 'absent'; Doc = $null } }
        if ((Get-Item -LiteralPath $Path -ErrorAction Stop).Length -gt 262144) { throw 'oversized generation document' }
        $doc = Read-JsonFile -Path $Path
        if ($null -eq $doc -or $doc -isnot [System.Management.Automation.PSCustomObject]) { throw 'generation shape' }
        $version = 0
        if (-not [int]::TryParse([string](Get-Field $doc 'schema'), [ref]$version)) { throw 'generation version' }
        if ($version -ne $script:GenerationSchema) { return [pscustomobject]@{ State = 'unsupported'; Doc = $null } }
        foreach ($name in @('sessionId', 'client', 'generations', 'tombstones')) {
            if ($null -eq $doc.PSObject.Properties[$name]) { throw ('missing generation document field: ' + $name) }
        }
        if ($doc.client -notin @('claude', 'codex')) { throw 'generation client' }
        if ($doc.generations -isnot [System.Array] -or @($doc.generations).Count -gt $script:GenerationMaxEntries) { throw 'unbounded generations' }
        if ($doc.tombstones -isnot [System.Array] -or @($doc.tombstones).Count -gt $script:GenerationMaxTombstones) { throw 'unbounded tombstones' }
        foreach ($entry in @($doc.generations)) { Test-GenerationEntryShape -Entry $entry }
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
        $mutateResult = & $Mutate $doc $identity $Arguments
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
        # Only a RECORDED end qualifies. Age never does: a live generation with
        # an old timestamp is still somebody's open correction chain, and
        # deleting it refunds the allowance it already spent.
        if (([string]$entry.state) -in $script:GenerationTerminalStates) {
            [void]$stones.Add([pscustomobject][ordered]@{ taskId = [string]$entry.taskId; actor = [string]$entry.actor; endedAt = [string]$entry.endedAt })
            $collected++
            continue
        }
        [void]$kept.Add($entry)
    }
    # A tombstone is already the bounded remains of something finished, so
    # dropping the oldest costs only the ability to recognise a very old late
    # event - which is why this is the one thing here that may be evicted.
    while ($stones.Count -gt $script:GenerationMaxTombstones) { $stones.RemoveAt(0) }
    $Doc.generations = @($kept.ToArray())
    $Doc.tombstones = @($stones.ToArray())
    return $collected
}

function Get-GenerationRecord {
    param([Parameter(Mandatory = $true)]$HookInput)
    $identity = Get-GenerationIdentity $HookInput
    if ($null -eq $identity) { return $null }
    $state = Get-GenerationDocumentState -Path $identity.Scope.Path
    if ($state.State -ne 'valid') { return $null }
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
    $safe = [System.Text.RegularExpressions.Regex]::Replace($Gate, '[^A-Za-z0-9-]+', '')
    if ($safe -eq '') { return [pscustomobject]@{ Ok = $false; State = 'invalid-gate' } }
    $result = Invoke-GenerationUpdate -HookInput $HookInput -Arguments @{ Gate = $safe; Affirmative = $Affirmative } -Mutate {
        param($doc, $identity, $opt)
        $entry = Find-GenerationEntry -Doc $doc -TaskId $identity.TaskId -Actor $identity.Actor
        if ($null -eq $entry) { $entry = Add-GenerationEntry -Doc $doc -Identity $identity -Evidence '' }
        $kept = @(@($entry.verdicts) | Where-Object { [string]$_.gate -cne $opt.Gate })
        if ($kept.Count -ge 64) { throw 'generation-verdict-capacity' }
        $entry.verdicts = @($kept + [pscustomobject][ordered]@{ gate = $opt.Gate; affirmative = $opt.Affirmative; at = [DateTime]::UtcNow.ToString('o') })
        return $opt.Gate
    }
    return [pscustomobject]@{ Ok = $result.Ok; State = $(if ($result.Ok) { 'ok' } else { $result.State }) }
}

function Test-GenerationReady {
    param([Parameter(Mandatory = $true)]$HookInput, [string[]]$Objections = @(), [AllowEmptyString()][string]$Evidence = '')
    $missing = New-Object System.Collections.ArrayList
    $entry = Get-GenerationRecord -HookInput $HookInput
    if ($null -eq $entry) { return [pscustomobject]@{ Ready = $false; Missing = @('generation-unknown'); Evidence = '' } }
    # An outstanding objection from any gate is a refusal. Its ABSENCE is the
    # affirmative this feature can observe - see the limitation at the top of
    # this file, which is also stated in the shipped documentation.
    foreach ($name in @($Objections)) {
        $safe = [System.Text.RegularExpressions.Regex]::Replace([string]$name, '[^A-Za-z0-9-]+', '')
        if ($safe -ne '') { [void]$missing.Add($safe) }
    }
    foreach ($verdict in @($entry.verdicts)) {
        if (-not [bool]$verdict.affirmative) { [void]$missing.Add([string]$verdict.gate) }
    }
    # Readiness is a claim about ONE state of the evidence. When that state
    # moves, the claim expires rather than latching - a latch that can be set
    # early and never rechecked is indistinguishable from having no barrier.
    if ($Evidence -ne '' -and ([string]$entry.evidence) -cne $Evidence) { [void]$missing.Add('evidence-moved') }
    $unique = @($missing | Sort-Object -Unique)
    return [pscustomobject]@{ Ready = ($unique.Count -eq 0); Missing = $unique; Evidence = [string]$entry.evidence }
}

function Publish-GenerationSummary {
    param([Parameter(Mandatory = $true)]$HookInput, [bool]$Ready, [string[]]$Missing = @())
    $result = Invoke-GenerationUpdate -HookInput $HookInput -Arguments @{ Ready = $Ready; Missing = $Missing } -Mutate {
        param($doc, $identity, $opt)
        if (Test-GenerationRetired -Doc $doc -TaskId $identity.TaskId -Actor $identity.Actor) { throw 'generation retired' }
        $entry = Find-GenerationEntry -Doc $doc -TaskId $identity.TaskId -Actor $identity.Actor
        if ($null -eq $entry) { $entry = Add-GenerationEntry -Doc $doc -Identity $identity -Evidence '' }
        # Exactly once per generation. A duplicate or delayed handler resolves
        # to the record the first one committed instead of writing a second,
        # which is what stops one generation producing two summaries.
        if ($null -ne $entry.publication) {
            return [pscustomobject]@{ Published = $false; AlreadyPublished = $true; Failure = '' }
        }
        $named = @(@($opt.Missing) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        $failureText = if ($named.Count -eq 0) { 'unknown-verdict' } else { ($named -join ', ') }
        $entry.publication = [pscustomobject][ordered]@{ at = [DateTime]::UtcNow.ToString('o'); ready = $opt.Ready; failure = $(if ($opt.Ready) { '' } else { $failureText }); reported = $false }
        if ($opt.Ready) {
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
            return [pscustomobject]@{ Collected = 0; Refused = $true; Reason = 'nothing terminal to collect' }
        }
        return [pscustomobject]@{ Collected = $collected; Refused = $false; Reason = '' }
    }
    if (-not $result.Ok) { return [pscustomobject]@{ Collected = 0; Refused = $true; Reason = $result.State } }
    return $result.Result
}
