# Offline test suite for the Session-Summary-Check generation store - the generation state store.
#
# Every scenario runs IN PROCESS against a fake LOCALAPPDATA inside the suite's
# own workspace, so nothing here can read or write the machine's real state.
#
# WHAT MAKES THESE ASSERTIONS LOAD-BEARING. Two of them assert an ABSENCE, and
# they are the point of the suite rather than an afterthought:
#
#   * "no correction is demanded" - the previous attempt at this feature failed
#     exactly here. It asked for a correction line, and that line then appeared
#     AFTER the summary, breaking the rule it was enforcing. An assertion that
#     only checked the failure was RECORDED would have passed on that code.
#   * "the allowance is unchanged" - withdrawing and re-establishing readiness
#     must not refill the task's correction budget. Without this, a blocking
#     sibling gate refunds the obligation it just imposed.
#
# Usage:  pwsh -NoLogo -NoProfile -File .\scripts\Test-Generation.ps1 [-KeepArtifacts]
# Exit code is the number of failed assertions (0 = all passed).

param([switch]$KeepArtifacts)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptRoot = $PSScriptRoot
$HooksRoot = Join-Path (Split-Path -Parent $ScriptRoot) 'hooks'
$HookLib = Join-Path $HooksRoot '_hooklib.ps1'
$Module = Join-Path $HooksRoot 'Session-Summary-Check\_generation.ps1'
foreach ($required in @($HookLib, $Module)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-Host "Required file not found: $required" -ForegroundColor Red
        exit 1
    }
}

$script:Pass = 0
$script:Fail = 0
$script:TestPreviewLength = 700
. (Join-Path $PSScriptRoot '_testlib.ps1')

$Work = New-TestWorkspace -Prefix 'hookmaker-generation'
Write-Host ("Workspace: $Work") -ForegroundColor DarkGray

$SavedLocalAppData = $env:LOCALAPPDATA
$SavedClaudeProjectDir = $env:CLAUDE_PROJECT_DIR
$SavedClient = $env:HOOKMAKER_CLIENT
$env:LOCALAPPDATA = $Work
$env:CLAUDE_PROJECT_DIR = ''
$env:HOOKMAKER_CLIENT = 'claude'

. $HookLib
. $Module

function New-GenInput {
    param([string]$Session = 's-gen-1', [string]$Event = 'UserPromptSubmit', [string]$Prompt = 'do the thing', [string]$Agent = '')
    $doc = [pscustomobject]@{ session_id = $Session; cwd = $Work; hook_event_name = $Event; prompt = $Prompt }
    if ($Agent -ne '') { Add-Member -InputObject $doc -MemberType NoteProperty -Name 'agent_id' -Value $Agent }
    return $doc
}

function Start-GenTask {
    param([string]$Session = 's-gen-1', [string]$Prompt = 'do the thing')
    $boundary = New-GenInput -Session $Session -Prompt $Prompt
    Register-UserTaskBoundary -HookInput $boundary
    return $boundary
}

function Get-GenDocPath {
    param($HookInput)
    return (Get-GenerationPath -ProjectRoot $Work -SessionId ([string](Get-Field $HookInput 'session_id')) -Client (Get-HookClientId))
}

function Write-GenDoc {
    param($HookInput, $Doc)
    $path = Get-GenDocPath $HookInput
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
    [IO.File]::WriteAllText($path, ($Doc | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
}

function New-GenEntry {
    param([string]$TaskId, [string]$State = 'working', [string]$Actor = 'main', [string]$Ended = '')
    $endedAt = $null
    if ($State -in @('finalized', 'unverified')) { $endedAt = $(if ($Ended -ne '') { $Ended } else { [DateTime]::UtcNow.ToString('o') }) }
    return [pscustomobject][ordered]@{
        taskId = $TaskId; actor = $Actor; state = $State; evidence = 'e0'
        verdicts = @(); publication = $(if ($State -eq 'finalized') { [pscustomobject]@{ at = $endedAt; ready = $true; failure = ''; reported = $false } } else { $null }); endedAt = $endedAt
    }
}

try {
    # --- US1: published once against settled evidence ------------------------
    $h = Start-GenTask
    $null = Set-GenerationState -HookInput $h -State 'ready' -Evidence 'commit-a'
    $first = Publish-GenerationSummary -HookInput $h -Ready $true
    Check 'T008 a first publication is recorded' ($first.Published -and -not $first.AlreadyPublished) ($first | ConvertTo-Json -Compress)

    $recordAfterFirst = (Get-GenerationRecord -HookInput $h) | ConvertTo-Json -Depth 8 -Compress
    $second = Publish-GenerationSummary -HookInput $h -Ready $true
    Check 'T009 a second publication resolves to the first' ((-not $second.Published) -and $second.AlreadyPublished) ($second | ConvertTo-Json -Compress)
    $recordAfterSecond = (Get-GenerationRecord -HookInput $h) | ConvertTo-Json -Depth 8 -Compress
    Check 'T009 the first record is left byte-identical' ($recordAfterFirst -ceq $recordAfterSecond) $recordAfterSecond

    $finalized = Get-GenerationRecord -HookInput $h
    Check 'T010 an unchanged event after finalization produces nothing new' (
        ([string]$finalized.state -ceq 'finalized') -and (-not [string]::IsNullOrWhiteSpace([string]$finalized.endedAt))
    ) ([string]$finalized.state)

    $moved = Test-GenerationReady -HookInput $h -Evidence 'commit-b'
    Check 'T011 changed evidence surfaces as a finding, not a second summary' (
        (-not $moved.Ready) -and (@($moved.Missing) -contains 'evidence-moved') -and $second.AlreadyPublished
    ) (@($moved.Missing) -join ',')

    # --- US2: a premature summary is recorded, not argued with ---------------
    $h2 = Start-GenTask -Session 's-gen-2'
    $null = Set-GenerationState -HookInput $h2 -State 'validating' -Evidence 'commit-a'
    $premature = Publish-GenerationSummary -HookInput $h2 -Ready $false -Missing @('CiStatusCheck')
    Check 'T014 a premature publication records one failure naming the verdict' (
        $premature.Published -and ([string]$premature.Failure -ceq 'CiStatusCheck')
    ) ($premature | ConvertTo-Json -Compress)

    # The assertion about an ABSENCE. The result may carry only these three
    # fields, and the failure text may name gates - never an instruction.
    $fields = @($premature.PSObject.Properties.Name | Sort-Object)
    $demandWords = 'correct|acknowledg|must add|please|re-?run|reply'
    Check 'T015 no correction is demanded' (
        (($fields -join ',') -ceq 'AlreadyPublished,Failure,Published') -and
        ([string]$premature.Failure -notmatch $demandWords)
    ) (($fields -join ',') + ' | ' + [string]$premature.Failure)

    $repeat = Publish-GenerationSummary -HookInput $h2 -Ready $false -Missing @('CiStatusCheck')
    Check 'T016 the same unchanged state repeats nothing' ((-not $repeat.Published) -and $repeat.AlreadyPublished) ($repeat | ConvertTo-Json -Compress)

    $prematureRecord = Get-GenerationRecord -HookInput $h2
    Check 'T014 a premature generation is published but not terminal' (
        ($null -ne $prematureRecord.publication) -and ([string]$prematureRecord.state -ceq 'validating')
    ) ([string]$prematureRecord.state)

    # The failure is named exactly once, however many handlers ask for it.
    $namedOnce = Read-GenerationFailureOnce -HookInput $h2
    $namedTwice = Read-GenerationFailureOnce -HookInput $h2
    Check 'T017 a premature failure is named once and then not again' (
        ([string]$namedOnce -ceq 'CiStatusCheck') -and ([string]$namedTwice -ceq '')
    ) ('[' + [string]$namedOnce + '][' + [string]$namedTwice + ']')

    # --- US3: evidence that moved invalidates readiness ----------------------
    $h3 = Start-GenTask -Session 's-gen-3'
    $null = Set-GenerationState -HookInput $h3 -State 'ready' -Evidence 'commit-a'
    $ready = Test-GenerationReady -HookInput $h3 -Evidence 'commit-a'
    Check 'T018 readiness holds while its evidence holds' ($ready.Ready) (@($ready.Missing) -join ',')
    $withdrawn = Test-GenerationReady -HookInput $h3 -Evidence 'commit-c'
    Check 'T018 readiness is withdrawn when the evidence moves' (-not $withdrawn.Ready) (@($withdrawn.Missing) -join ',')

    # The allowance lives in the TASK record, which this feature must not touch.
    $taskPath = Get-TaskIdentityPath -ProjectRoot $Work -SessionId 's-gen-3' -Client (Get-HookClientId)
    $allowanceBefore = [IO.File]::ReadAllText($taskPath)
    $null = Set-GenerationState -HookInput $h3 -State 'validating' -Evidence 'commit-c'
    $null = Set-GenerationState -HookInput $h3 -State 'ready' -Evidence 'commit-c'
    $allowanceAfter = [IO.File]::ReadAllText($taskPath)
    Check 'T019 re-validating does not refill the correction allowance' ($allowanceBefore -ceq $allowanceAfter) $allowanceAfter

    $objected = Test-GenerationReady -HookInput $h3 -Objections @('TestCompletionCheck') -Evidence 'commit-c'
    Check 'T020 an unresolved objection appears in Missing' (
        (-not $objected.Ready) -and (@($objected.Missing) -contains 'TestCompletionCheck')
    ) (@($objected.Missing) -join ',')

    $null = Register-GenerationVerdict -HookInput $h3 -Gate 'StaleGate' -Affirmative $false
    $stale = Test-GenerationReady -HookInput $h3 -Evidence 'commit-c'
    Check 'T020 a recorded non-affirmative verdict also appears in Missing' (@($stale.Missing) -contains 'StaleGate') (@($stale.Missing) -join ',')

    # A continuation carries the same task id, so it is the SAME generation.
    $continuationId = (Get-CurrentUserTaskIdentity -HookInput $h3).TaskId
    $continuation = New-GenInput -Session 's-gen-3' -Prompt 'follow-up in the same task'
    $sameTask = (Get-CurrentUserTaskIdentity -HookInput $continuation).TaskId
    Check 'T020a a later handler of the same task resolves to one generation' ($continuationId -ceq $sameTask) ($sameTask)

    # Parent and child differ only by actor and must end independently.
    $child = New-GenInput -Session 's-gen-3' -Event 'SubagentStop' -Agent 'child-1'
    $null = Set-GenerationState -HookInput $child -State 'ready' -Evidence 'child-proof'
    $null = Publish-GenerationSummary -HookInput $child -Ready $true
    $parentRecord = Get-GenerationRecord -HookInput $h3
    $childRecord = Get-GenerationRecord -HookInput $child
    Check 'T020b parent and child reach terminal state independently' (
        ([string]$parentRecord.state -ceq 'ready') -and ([string]$childRecord.state -ceq 'finalized') -and
        ([string]$parentRecord.actor -cne [string]$childRecord.actor)
    ) ([string]$parentRecord.state + '/' + [string]$childRecord.state)

    # --- US4: completed state is collected; live state never is --------------
    $h4 = Start-GenTask -Session 's-gen-4'
    $liveTask = (Get-CurrentUserTaskIdentity -HookInput $h4).TaskId
    $entries = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt 30; $i++) { [void]$entries.Add((New-GenEntry -TaskId ('done-' + $i) -State 'finalized')) }
    [void]$entries.Add((New-GenEntry -TaskId 'live-keep-1' -State 'working'))
    [void]$entries.Add((New-GenEntry -TaskId 'live-keep-2' -State 'validating'))
    Write-GenDoc -HookInput $h4 -Doc ([pscustomobject][ordered]@{
            schema = 1; sessionId = 's-gen-4'; client = (Get-HookClientId)
            generations = @($entries.ToArray()); tombstones = @()
        })
    $grow = Set-GenerationState -HookInput $h4 -State 'working' -Evidence 'commit-a'
    $after = (Get-GenerationDocumentState -Path (Get-GenDocPath $h4)).Doc
    $keptIds = @(@($after.generations) | ForEach-Object { [string]$_.taskId })
    Check 'T023 at capacity the live generations survive and the write succeeds' (
        $grow.Ok -and ($keptIds -contains 'live-keep-1') -and ($keptIds -contains 'live-keep-2') -and ($keptIds -contains $liveTask)
    ) ($keptIds -join ',')
    Check 'T023 only the terminal generations were collected' (@($after.generations).Count -eq 3) ([string]@($after.generations).Count)
    Check 'T024 a tombstone is left for each collected generation' (@($after.tombstones).Count -eq 30) ([string]@($after.tombstones).Count)

    # Age alone must never qualify: a live entry dated long ago still survives.
    $aged = New-Object System.Collections.ArrayList
    [void]$aged.Add((New-GenEntry -TaskId 'ancient-live' -State 'working'))
    [void]$aged.Add((New-GenEntry -TaskId 'ancient-done' -State 'finalized' -Ended '2000-01-01T00:00:00.0000000Z'))
    Write-GenDoc -HookInput $h4 -Doc ([pscustomobject][ordered]@{
            schema = 1; sessionId = 's-gen-4'; client = (Get-HookClientId)
            generations = @($aged.ToArray()); tombstones = @()
        })
    $collect = Invoke-GenerationCollection -HookInput $h4
    $afterAged = (Get-GenerationDocumentState -Path (Get-GenDocPath $h4)).Doc
    $agedIds = @(@($afterAged.generations) | ForEach-Object { [string]$_.taskId })
    Check 'T028 age alone never makes a live generation collectable' (
        ($collect.Collected -eq 1) -and ($agedIds -ceq @('ancient-live'))
    ) ($agedIds -join ',')

    # A late event for a collected generation is retired, never new work.
    $retiredDoc = [pscustomobject][ordered]@{
        schema = 1; sessionId = 's-gen-4'; client = (Get-HookClientId); generations = @()
        tombstones = @([pscustomobject][ordered]@{ taskId = $liveTask; actor = 'main'; endedAt = [DateTime]::UtcNow.ToString('o') })
    }
    Write-GenDoc -HookInput $h4 -Doc $retiredDoc
    $late = Set-GenerationState -HookInput $h4 -State 'working'
    Check 'T025 a late event from a collected generation is rejected as retired' (
        (-not $late.Ok) -and ([string]$late.State -ceq 'retired')
    ) ([string]$late.State)

    # Capacity with nothing terminal refuses explicitly.
    $allLive = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt 32; $i++) { [void]$allLive.Add((New-GenEntry -TaskId ('busy-' + $i) -State 'working')) }
    Write-GenDoc -HookInput $h4 -Doc ([pscustomobject][ordered]@{
            schema = 1; sessionId = 's-gen-4'; client = (Get-HookClientId)
            generations = @($allLive.ToArray()); tombstones = @()
        })
    $refused = Invoke-GenerationCollection -HookInput $h4
    Check 'T026 capacity with nothing collectable refuses explicitly' (
        $refused.Refused -and ($refused.Collected -eq 0) -and ([string]$refused.Reason -ne '')
    ) ($refused | ConvertTo-Json -Compress)
    $blocked = Set-GenerationState -HookInput $h4 -State 'working'
    Check 'T026 a write that cannot make room fails rather than evicting' (
        (-not $blocked.Ok) -and ([string]$blocked.State -ceq 'capacity')
    ) ([string]$blocked.State)
    $stillThere = (Get-GenerationDocumentState -Path (Get-GenDocPath $h4)).Doc
    Check 'T026 the refusal refills nothing and leaves every live entry' (@($stillThere.generations).Count -eq 32) ([string]@($stillThere.generations).Count)

    # An interrupted write leaves the previous document valid and readable.
    $h5 = Start-GenTask -Session 's-gen-5'
    $null = Set-GenerationState -HookInput $h5 -State 'ready' -Evidence 'commit-a'
    $before = [IO.File]::ReadAllText((Get-GenDocPath $h5))
    $bad = Invoke-GenerationUpdate -HookInput $h5 -Mutate {
        param($doc, $identity)
        # A mutation the validator must reject: terminality without an end time.
        $entry = Find-GenerationEntry -Doc $doc -TaskId $identity.TaskId -Actor $identity.Actor
        $entry.state = 'finalized'
        $entry.endedAt = $null
        return 'attempted'
    }
    $afterBad = [IO.File]::ReadAllText((Get-GenDocPath $h5))
    Check 'T027 an interrupted write leaves the previous bytes intact' (
        (-not $bad.Ok) -and ([string]$bad.State -ceq 'mutation-invalid-or-capacity') -and ($before -ceq $afterBad)
    ) ([string]$bad.State)
    Check 'T027 the surviving document still reads as valid' (
        ((Get-GenerationDocumentState -Path (Get-GenDocPath $h5)).State -ceq 'valid')
    ) ((Get-GenerationDocumentState -Path (Get-GenDocPath $h5)).State)

    # --- T032: the wiring, through the real hook process ---------------------
    # In-process assertions prove the store. This proves the HOOK actually calls
    # it: that Stop records silently, and that the next delivery names the
    # failure once. A store that works and a hook that never calls it is the
    # failure mode a unit-only suite cannot see.
    $hookScript = Join-Path $HooksRoot 'Session-Summary-Check\Session-Summary-Check.ps1'
    $ioDir = Join-Path $Work 'hookio'
    [void][IO.Directory]::CreateDirectory($ioDir)
    function Invoke-SummaryHook {
        param([string]$Event, [string]$Session, [string]$Prompt = 'next prompt', [string]$Answer = '')
        $inPath = Join-Path $ioDir 'in.json'
        $outPath = Join-Path $ioDir 'out.txt'
        $errPath = Join-Path $ioDir 'err.txt'
        $payload = [ordered]@{ session_id = $Session; cwd = $Work; hook_event_name = $Event; prompt = $Prompt; last_assistant_message = $Answer }
        [IO.File]::WriteAllText($inPath, ($payload | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
        $proc = Start-BoundedProcess -FilePath 'pwsh' -ArgumentList @('-NoLogo', '-NoProfile', '-File', $hookScript) `
            -RedirectStandardInput $inPath -RedirectStandardOutput $outPath -RedirectStandardError $errPath `
            -Environment @{ LOCALAPPDATA = $Work; HOOKMAKER_CLIENT = 'claude'; CLAUDE_PROJECT_DIR = '' } -TimeoutMs 60000
        $text = ''
        if (Test-Path -LiteralPath $outPath -PathType Leaf) { $text = [IO.File]::ReadAllText($outPath) }
        return [pscustomobject]@{ ExitCode = $proc.ExitCode; Text = $text }
    }

    $wireSession = 's-gen-wire'
    $null = Invoke-SummaryHook -Event 'UserPromptSubmit' -Session $wireSession -Prompt 'start the wiring task'
    $stopRun = Invoke-SummaryHook -Event 'Stop' -Session $wireSession
    Check 'T032 the Stop branch records and stays silent' (
        ($stopRun.ExitCode -eq 0) -and ([string]::IsNullOrWhiteSpace($stopRun.Text))
    ) ([string]$stopRun.ExitCode + '|' + $stopRun.Text)

    $wireInput = New-GenInput -Session $wireSession
    $wireRecord = Get-GenerationRecord -HookInput $wireInput
    Check 'T032 an empty Stop does not invent a publication' ($null -eq $wireRecord -or $null -eq $wireRecord.publication)
    $summaryRun = Invoke-SummaryHook -Event 'Stop' -Session $wireSession -Answer "DONE: verified work`nREMAINING: none"
    Check 'T032 a real summary observation remains silent' ($summaryRun.ExitCode -eq 0 -and $summaryRun.Text -eq '')
    $wireRecord = Get-GenerationRecord -HookInput $wireInput
    Check 'T032 the hook wrote a publication record only for observed summary text' ($null -ne $wireRecord -and $null -ne $wireRecord.publication) (
        $(if ($null -eq $wireRecord) { 'no record' } else { ($wireRecord | ConvertTo-Json -Depth 6 -Compress) }))

    # --- Polish: nothing written carries content -----------------------------
    $secretPrompt = 'export API_KEY=sk-live-0123456789 && rm -rf /tmp/thing'
    $h6 = Start-GenTask -Session 's-gen-6' -Prompt $secretPrompt
    $null = Set-GenerationState -HookInput $h6 -State 'ready' -Evidence 'commit-a'
    $null = Publish-GenerationSummary -HookInput $h6 -Ready $true
    $written = [IO.File]::ReadAllText((Get-GenDocPath $h6))
    Check 'T040 nothing written contains prompt, command or credential content' (
        ($written -notmatch 'sk-live') -and ($written -notmatch 'API_KEY') -and
        ($written -notmatch 'rm -rf') -and ($written -notmatch 'export ')
    ) $written
}
finally {
    $env:LOCALAPPDATA = $SavedLocalAppData
    $env:CLAUDE_PROJECT_DIR = $SavedClaudeProjectDir
    $env:HOOKMAKER_CLIENT = $SavedClient
    if (-not $KeepArtifacts) {
        if (-not (Remove-TestWorkspace $Work)) { $script:Fail++ }
    }
}

Write-Host ''
Write-Host ("Passed: $script:Pass  Failed: $script:Fail") -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
exit $script:Fail
