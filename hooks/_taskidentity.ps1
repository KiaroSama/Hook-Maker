# THE ORIGINATING USER TASK.
#
# User-task identity is scoped by project, client and session. A dispatch is
# not a task: Codex can replay a Stop refusal in a new turn. All mutations use
# one stable lock inode and publish an atomic, bounded document. No prompt text
# is persisted. Unknown provenance never adopts another session's identity.
#
# WHY IT IS MINTED AT A USER PROMPT AND NOWHERE ELSE. Event identity used to be
# a hash of the transcript's path, length and write time, and it failed in both
# directions. Two gates handling the SAME dispatch could observe different stats
# while the transcript was still flushing, so one event minted two chains and the
# pair could block each other for ever; and a genuinely NEW task could observe
# unchanged or lagging stats and be treated as the old one. Twelve deliveries
# with no new user request were admitted as twelve new chains in the replay that
# found this. Atomic reservation cannot repair a wrong identity - it only makes
# the wrong answer consistent.
#
# A task begins when the USER says something. That is an explicit lifecycle
# boundary the client already reports, and it is the only event that means "a new
# thing was asked for". So the id is minted THERE, once, into a durable record,
# and every later handler READS it. Transcript growth, hook text, tool output,
# elapsed time, a retry, compaction and a changed turn id all leave it untouched,
# because none of them is a user asking for something new. Nothing in this file
# may go back to deriving identity from a mutable statistic.
#
# CODEX REPLAYS A REFUSAL AS THE NEXT PROMPT. Rotating there would hand every
# refusal a fresh chain and a fresh allowance - the loop the allowance exists to
# bound. Each emitted block therefore registers an opaque receipt, and a prompt
# carrying that receipt is recognised as the continuation it is. An exact match
# is the whole rule: if a client ever wraps the text, the prompt does not match,
# a new task starts, and that is the SAFE direction - a fresh bounded chain.
#
# DEGRADATION IS VISIBLE, NEVER GUESSED. With no record, the caller is told the
# identity is degraded. Nothing here invents a task id.
$script:TaskIdentitySchema = 2
$script:TaskIdentityMaxBlockFingerprints = 16

function Get-TaskIdentityPath {
    param([AllowEmptyString()][string]$ProjectRoot = '', [string]$SessionId = '', [string]$Client = '')
    $stem = 'TaskIdentity-' + (Get-StopProjectKey -ProjectRoot $ProjectRoot)
    if ($SessionId -ne '' -and $Client -ne '') {
        $stem += '-' + (Get-ShortHash ($Client + '|' + $SessionId))
    }
    return (Join-Path (Join-Path $env:LOCALAPPDATA 'HookMaker\state') ($stem + '.json'))
}

function Get-TaskPromptFingerprint {
    param([AllowEmptyString()][string]$Prompt)
    # Preserve meaningful whitespace inside code, paths and quoted arguments.
    $text = ([string]$Prompt).TrimEnd([char[]]@([char]13, [char]10))
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-TaskScope {
    param($HookInput)
    $session = [string](Get-Field $HookInput 'session_id')
    $client = Get-HookClientId
    $root = [string](Get-Field $HookInput 'cwd')
    if ([string]::IsNullOrWhiteSpace($session) -or $client -eq 'unknown' -or [string]::IsNullOrWhiteSpace($root)) { return $null }
    return [pscustomobject]@{ Session = $session; Client = $client; Path = (Get-TaskIdentityPath -ProjectRoot $root -SessionId $session -Client $client) }
}

function Get-TaskIdentityState {
    param([string]$Path)
    try {
        if ([IO.Directory]::Exists($Path)) { return [pscustomobject]@{ State = 'corrupt'; Record = $null } }
        if (-not [IO.File]::Exists($Path)) { return [pscustomobject]@{ State = 'absent'; Record = $null } }
        if ((Get-Item -LiteralPath $Path -ErrorAction Stop).Length -gt 65536) { throw 'oversized task record' }
        $doc = Read-JsonFile -Path $Path
        if ($null -eq $doc -or $doc -isnot [System.Management.Automation.PSCustomObject]) { throw 'task shape' }
        $version = 0
        if (-not [int]::TryParse([string](Get-Field $doc 'schema'), [ref]$version)) { throw 'task version' }
        if ($version -ne $script:TaskIdentitySchema) { return [pscustomobject]@{ State = 'unsupported'; Record = $null } }
        foreach ($name in @('sessionId', 'client', 'taskId', 'promptFingerprint', 'dispatchId', 'phase', 'blockFingerprints', 'turnIds')) {
            if ($null -eq $doc.PSObject.Properties[$name]) { throw ('missing task field: ' + $name) }
        }
        if ([string]::IsNullOrWhiteSpace([string]$doc.sessionId) -or [string]::IsNullOrWhiteSpace([string]$doc.taskId)) { throw 'empty task identity' }
        if ($doc.client -notin @('claude', 'codex') -or $doc.phase -notin @('working', 'stopped')) { throw 'task vocabulary' }
        foreach ($field in @('blockFingerprints', 'turnIds')) {
            if ($doc.$field -isnot [System.Array] -or @($doc.$field).Count -gt 32) { throw 'unbounded task collection' }
            foreach ($value in @($doc.$field)) { if ($value -isnot [string] -or $value.Length -gt 256) { throw 'invalid task collection element' } }
        }
        return [pscustomobject]@{ State = 'valid'; Record = $doc }
    }
    catch { return [pscustomobject]@{ State = 'corrupt'; Record = $null } }
}

function Read-TaskIdentityRecord {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-TaskIdentityState -Path $Path).Record
}

function Invoke-TaskIdentityUpdate {
    param($HookInput, [scriptblock]$Mutate)
    $scope = Get-TaskScope $HookInput
    if ($null -eq $scope) { return [pscustomobject]@{ Ok = $false; State = 'identity-unavailable'; Record = $null } }
    $handle = $null; $temp = ''
    try {
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $scope.Path))
        $deadline = [DateTime]::UtcNow.AddSeconds(2)
        do {
            try { $handle = [IO.File]::Open(($scope.Path + '.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
            catch { if ([DateTime]::UtcNow -ge $deadline) { throw 'task identity lock timeout' }; Start-Sleep -Milliseconds 20 }
        } while ($null -eq $handle)
        $state = Get-TaskIdentityState -Path $scope.Path
        if ($state.State -notin @('absent', 'valid')) { return [pscustomobject]@{ Ok = $false; State = $state.State; Record = $null } }
        $record = $state.Record
        if ($null -ne $record -and ($record.sessionId -cne $scope.Session -or $record.client -cne $scope.Client)) { throw 'task scope mismatch' }
        $before = if ($null -eq $record) { '' } else { $record | ConvertTo-Json -Depth 8 -Compress }
        $record = & $Mutate $record $scope
        if ($null -eq $record) { return [pscustomobject]@{ Ok = $true; State = 'unchanged'; Record = $null } }
        $after = $record | ConvertTo-Json -Depth 8 -Compress
        if ($before -cne $after) {
            $temp = $scope.Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
            [IO.File]::WriteAllText($temp, $after, (New-Object Text.UTF8Encoding($false)))
            if ((Get-TaskIdentityState -Path $temp).State -ne 'valid') {
                return [pscustomobject]@{ Ok = $false; State = 'mutation-invalid-or-capacity'; Record = $null }
            }
            if ([IO.File]::Exists($scope.Path)) { [IO.File]::Replace($temp, $scope.Path, [NullString]::Value) }
            else { [IO.File]::Move($temp, $scope.Path) }
        }
        return [pscustomobject]@{ Ok = $true; State = 'valid'; Record = $record }
    }
    catch {
        $failure = if ($_.Exception.Message -like 'task-*-capacity') { 'capacity' } else { 'persistence-failed' }
        return [pscustomobject]@{ Ok = $false; State = $failure; Record = $null }
    }
    finally {
        if ($temp -ne '' -and [IO.File]::Exists($temp)) { try { [IO.File]::Delete($temp) } catch { } }
        if ($null -ne $handle) { $handle.Dispose() }
        # Do not unlink a lock file after releasing it: another writer may own it.
    }
}

function Register-UserTaskBoundary {
    param([Parameter(Mandatory = $true)]$HookInput)
    $event = [string](Get-Field $HookInput 'hook_event_name')
    if ($event -notin @('UserPromptSubmit', 'Stop')) { return }
    if ($event -eq 'Stop') {
        $scope = Get-TaskScope $HookInput
        if ($null -eq $scope -or -not [IO.File]::Exists($scope.Path)) { return }
    }
    $prompt = [string](Get-Field $HookInput 'prompt')
    if ([string]::IsNullOrWhiteSpace($prompt)) { $prompt = [string](Get-Field $HookInput 'user_prompt') }
    $fingerprint = Get-TaskPromptFingerprint $prompt
    $turn = [string](Get-Field $HookInput 'turn_id')
    if ($turn.Length -gt 256) { return }
    if ($event -eq 'UserPromptSubmit' -and $fingerprint -eq '') { return }
    $result = Invoke-TaskIdentityUpdate -HookInput $HookInput -Mutate {
        param($record, $scope)
        if ($event -eq 'Stop') {
            if ($null -ne $record -and ($turn -eq '' -or $record.dispatchId -ceq $turn)) {
                $record.phase = 'stopped'
            }
            return $record
        }
        if ($null -ne $record) {
            # A known dispatch is a duplicate even if a delayed handler arrives.
            if ($turn -ne '' -and @($record.turnIds) -ccontains $turn) { return $record }
            $receiptKey = $fingerprint
            if ($prompt -match '^\[HOOKMAKER-CORRECTION:([a-f0-9]{32})\](?:\r?\n|$)') { $receiptKey = 'token:' + $Matches[1] }
            $continuation = @($record.blockFingerprints) -ccontains $receiptKey
            if ($continuation) {
                if ($turn -ne '' -and @($record.turnIds) -cnotcontains $turn -and @($record.turnIds).Count -ge 32) { throw 'task-turn-capacity' }
                # Consume a receipt once; duplicate handlers use dispatch identity.
                $record.blockFingerprints = @($record.blockFingerprints | Where-Object { $_ -cne $receiptKey })
                $record.dispatchId = $turn
                $record.promptFingerprint = $fingerprint
                $record.phase = 'working'
                if ($turn -ne '' -and @($record.turnIds) -cnotcontains $turn) { $record.turnIds = @(@($record.turnIds) + $turn) }
                return $record
            }
            # Claude has no documented turn_id. Co-delivered handlers are joined
            # while work is active; a main Stop ends that phase. No timer or
            # mutable transcript statistics are used as an invented task boundary.
            if ($turn -eq '' -and $record.phase -eq 'working' -and $record.promptFingerprint -ceq $fingerprint) { return $record }
        }
        return [pscustomobject][ordered]@{
            schema = $script:TaskIdentitySchema; sessionId = $scope.Session; client = $scope.Client
            taskId = [guid]::NewGuid().ToString('N'); startedUtc = [DateTime]::UtcNow.ToString('o')
            dispatchId = $turn; promptFingerprint = $fingerprint; phase = 'working'
            blockFingerprints = @(); turnIds = @(@($turn) | Where-Object { $_ -ne '' })
        }
    }
    if (-not $result.Ok) { Set-ObjectProperty -Object $HookInput -Name 'hookmaker_identity_error' -Value $result.State }
    # Read-HookInput depends on this function writing nothing to the pipeline.
}

function Get-CurrentUserTaskIdentity {
    param([Parameter(Mandatory = $true)]$HookInput)
    $unknown = [pscustomobject]@{ TaskId = ''; Degraded = $true }
    $scope = Get-TaskScope $HookInput
    if ($null -eq $scope) { return $unknown }
    $record = Read-TaskIdentityRecord -Path $scope.Path
    if ($null -eq $record -or $record.sessionId -cne $scope.Session -or $record.client -cne $scope.Client) { return $unknown }
    $turn = [string](Get-Field $HookInput 'turn_id')
    if ($turn -ne '' -and @($record.turnIds) -cnotcontains $turn) { return $unknown }
    return [pscustomobject]@{ TaskId = [string]$record.taskId; Degraded = $false }
}

function Register-TaskContinuation {
    param($HookInput, [AllowEmptyString()][string]$Reason, [bool]$AddHeader = $true)
    $text = $Reason
    $fingerprint = Get-TaskPromptFingerprint $Reason
    if ($AddHeader -and $fingerprint -ne '') {
        $token = [guid]::NewGuid().ToString('N')
        $fingerprint = 'token:' + $token
        $text = '[HOOKMAKER-CORRECTION:' + $token + "]`n" + $Reason
    }
    $identity = Get-CurrentUserTaskIdentity $HookInput
    if ($fingerprint -eq '' -or $identity.Degraded) { return [pscustomobject]@{ Ok = $false; State = 'identity-unavailable' } }
    $result = Invoke-TaskIdentityUpdate -HookInput $HookInput -Mutate {
        param($record, $scope)
        if ($null -eq $record -or $record.taskId -cne $identity.TaskId) { throw 'task changed before continuation registration' }
        if (@($record.blockFingerprints) -cnotcontains $fingerprint) {
            # An outstanding receipt may still arrive. Evicting it relabels its
            # delayed correction as a new human task and refunds the allowance.
            if (@($record.blockFingerprints).Count -ge $script:TaskIdentityMaxBlockFingerprints) { throw 'task-receipt-capacity' }
            $record.blockFingerprints = @(@($record.blockFingerprints) + $fingerprint)
        }
        return $record
    }
    return [pscustomobject]@{ Ok = $result.Ok; State = $result.State; Text = $text }
}

function Add-TaskBlockFingerprint {
    param([Parameter(Mandatory = $true)]$HookInput, [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Reason)
    $null = Register-TaskContinuation -HookInput $HookInput -Reason $Reason -AddHeader $false
}
