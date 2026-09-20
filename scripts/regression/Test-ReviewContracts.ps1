param([string]$ResultPath = '', [string]$SourceRoot = '', [switch]$Baseline)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ($SourceRoot -eq '') { $SourceRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
. (Join-Path $SourceRoot 'scripts\_testlib.ps1')
$work = New-TestWorkspace -Prefix 'hookmaker-review-contracts'
$saved = @{}
foreach ($key in @('LOCALAPPDATA','USERPROFILE','HOME','HOOKMAKER_CLIENT','HOOKMAKER_STATE_DIR','CLAUDE_PROJECT_DIR','AI_SKILLS_DIR')) {
    $saved[$key] = [Environment]::GetEnvironmentVariable($key)
}
$cases = New-Object System.Collections.Generic.List[object]
. (Join-Path $PSScriptRoot '_reviewharness.ps1')

try {
    $env:LOCALAPPDATA = Join-Path $work 'local'
    $env:USERPROFILE = Join-Path $work 'home'; $env:HOME = $env:USERPROFILE
    $env:HOOKMAKER_CLIENT = 'codex'; $env:CLAUDE_PROJECT_DIR = ''
    $env:HOOKMAKER_STATE_DIR = Join-Path $work 'registry'; $env:AI_SKILLS_DIR = ''
    [void][IO.Directory]::CreateDirectory($env:USERPROFILE)
    . (Join-Path $SourceRoot 'hooks\_hooklib.ps1')
    . (Join-Path $SourceRoot 'scripts\_installinvoke.ps1')
    $transcript = Join-Path $work 'response.jsonl'
    $old = Assistant-Record @([pscustomobject]@{ type='text'; text='MCP used: Context7' })
    $current = Assistant-Record @([pscustomobject]@{ type='text'; text='the current answer' })
    $eventInput = [pscustomobject]@{ cwd=$work; session_id='evidence'; hook_event_name='Stop'; transcript_path=$transcript }
    Put-ReviewText $transcript $old
    Check-Contract 'E01 valid complete Claude fallback is readable' { (Get-ClosingAssistantText $eventInput).Text -ceq 'MCP used: Context7' }
    foreach ($value in @('', '   ', $null, [pscustomobject]@{ text='not a string' })) {
        Set-ObjectProperty $eventInput 'last_assistant_message' $value
        Check-Contract ('E02 explicit current non-text or empty message cannot resurrect old evidence: ' + $(if ($null -eq $value) { 'null' } else { $value.GetType().Name + ':' + [string]$value })) {
            -not (Get-ClosingAssistantText $eventInput).Known
        } $true
    }
    Set-ObjectProperty $eventInput 'last_assistant_message' 'current direct message'
    Put-ReviewText $transcript '{broken'
    Check-Contract 'E03 valid direct event text takes precedence over a broken transcript' { (Get-ClosingAssistantText $eventInput).Text -ceq 'current direct message' }
    $eventInput.PSObject.Properties.Remove('last_assistant_message')
    foreach ($boundary in @(
        '{"type":"user","message":{"content":"new task"}}',
        (Assistant-Record @()), '{"type":"assistant",',
        '{"type":"unknown-future-envelope"}',
        (Assistant-Record @([pscustomobject]@{type='tool_use';name='Edit'}))
    )) {
        Put-ReviewText $transcript ($old + "`n" + $boundary)
        Check-Contract ('E04 newer boundary prevents a stale closing claim: ' + $boundary.Substring(0,[Math]::Min(45,$boundary.Length))) {
            -not (Get-ClosingAssistantText $eventInput).Known
        } $true
    }
    Put-ReviewText $transcript ($old + "`n" + '{"type":"user","message":{"content":"new task"}}' + "`n" + $current)
    Check-Contract 'E05 a genuine current assistant after a new user is accepted' { (Get-ClosingAssistantText $eventInput).Text -ceq 'the current answer' }
    $eventInput.hook_event_name = 'SubagentStop'; Put-ReviewText $transcript $old
    Check-Contract 'E06 a child without child provenance cannot borrow its parent transcript' { -not (Get-ClosingAssistantText $eventInput).Known } $true
    $childPath = Join-Path $work 'child.jsonl'; Put-ReviewText $childPath $current
    Set-ObjectProperty $eventInput 'agent_transcript_path' $childPath
    Check-Contract 'E07 documented child path supplies the child response, not the parent' { (Get-ClosingAssistantText $eventInput).Text -ceq 'the current answer' }
    $eventInput.PSObject.Properties.Remove('agent_transcript_path'); $eventInput.hook_event_name = 'Stop'
    Put-ReviewText $transcript '{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"codex final"}]}}'
    Check-Contract 'E08 witnessed Codex response-item fallback is decoded explicitly' { (Get-ClosingAssistantText $eventInput).Text -ceq 'codex final' } $true
    Put-ReviewText $transcript '{"type":"event_msg","payload":{"type":"agent_message","message":"codex event"}}'
    Check-Contract 'E09 witnessed Codex agent-message fallback is decoded explicitly' { (Get-ClosingAssistantText $eventInput).Text -ceq 'codex event' } $true
    $unicode = 'current ' + [char]0x06CC + [char]0x062F
    Put-ReviewText $transcript (Assistant-Record @([pscustomobject]@{type='text';text=$unicode}))
    Check-Contract 'E10 valid UTF-8 is preserved' { (Get-ClosingAssistantText $eventInput).Text -ceq $unicode }
    $prefix = [Text.Encoding]::UTF8.GetBytes('{"type":"assistant","message":{"content":[{"type":"text","text":"')
    $suffix = [Text.Encoding]::UTF8.GetBytes('"}]}}')
    [IO.File]::WriteAllBytes($transcript, [byte[]]($prefix + [byte[]]@(255) + $suffix))
    Check-Contract 'E11 invalid UTF-8 cannot become accepted replacement-character evidence' { -not (Get-ClosingAssistantText $eventInput).Known } $true
    Check-Contract 'E12 one incomplete tail record is not treated as a complete message' { $null -eq (Get-LastAssistantTextFromJsonl -Tail $old -Truncated) } $true
    Put-ReviewText $transcript (([string][char]0xFEFF) + $current)
    Check-Contract 'E13 a full UTF-8 BOM transcript keeps its only complete record' { (Get-ClosingAssistantText $eventInput).Text -ceq 'the current answer' } $true
    Put-ReviewText $transcript (('x' * 300000) + "`n" + $current)
    Check-Contract 'E14 a bounded tail drops only its incomplete leading record' { (Get-ClosingAssistantText $eventInput).Text -ceq 'the current answer' }
    Put-ReviewText $transcript ''
    Check-Contract 'E15 an empty transcript remains unknown' { -not (Get-ClosingAssistantText $eventInput).Known }
    foreach ($sample in @(
        @{name='a real claim'; text='MCP used: Context7'; want=$true; red=$false},
        @{name='a quoted example'; text='> MCP used: Context7'; want=$false; red=$true},
        @{name='a tilde-fenced example'; text="~~~text`nMCP used: Context7`n~~~"; want=$false; red=$true},
        @{name='mismatched fence lengths'; text=('````' + "`n" + '```' + "`nMCP used: Context7`n" + '````'); want=$false; red=$true},
        @{name='an indented code example'; text='    MCP used: Context7'; want=$false; red=$true},
        @{name='none with a real reason'; text='MCP used: none - no connected source applies'; want=$true; red=$false},
        @{name='none with a placeholder reason'; text='MCP used: none - TBD'; want=$false; red=$true},
        @{name='claim after a closed example'; text=('~~~' + "`nMCP used: example`n~~~`nMCP used: Context7"); want=$true; red=$false}
    )) {
        Check-Contract ('E16 declaration distinguishes ' + $sample.name) { (Test-ClosingDeclaration -Text $sample.text -LabelPattern 'MCP used').Substantive -eq $sample.want } $sample.red
    }
    foreach ($json in @(
        '{"schema":1,"overall":"ok","components":[{"component":"claude","status":"ok"},{"component":"claude","status":"ok"}]}',
        '{"schema":1,"overall":"ok","components":[{"component":"claude","status":"ok"},{"component":"CLAUDE","status":"skipped"}]}',
        '{"schema":1,"overall":"ok","components":{"component":"claude","status":"ok"}}',
        '{"schema":[1],"overall":"ok","components":[{"component":"claude","status":"ok"}]}',
        '{"schema":1,"overall":["ok"],"components":[{"component":"claude","status":"ok"}]}',
        '{"schema":1,"overall":"ok","components":[{"component":["claude"],"status":"ok"}]}',
        '{"schema":1,"overall":"ok","components":[{"component":"claude","status":["ok"]}]}',
        '{"schema":1,"overall":"ok","components":[{"component":"claude","status":"ok"},{"component":"futureUnknown","status":"ok"}]}'
    )) {
        $doc = $json | ConvertFrom-Json
        Check-Contract ('I01 ambiguous result is rejected: ' + $json) { -not (Test-InstallResultDocument -Document $doc -RequiredComponents @('claude')).Ok } $true
    }
    $doc = '{"schema":1,"overall":"ok","components":[{"component":"claude","status":"ok"}]}' | ConvertFrom-Json
    Check-Contract 'I02 a canonical single-client array remains accepted' { (Test-InstallResultDocument $doc @('claude')).Ok }
    $stub = Join-Path $work 'result-only-installer.ps1'
    Put-ReviewText $stub 'param([string]$ResultPath) [IO.File]::Copy((Join-Path $PSScriptRoot "result-payload.json"), $ResultPath)'
    Put-ReviewText (Join-Path $work 'result-payload.json') '{"schema":1,"overall":"partial","components":[{"component":"claude","status":"ok","reason":"degraded"},{"component":"codex","status":"skipped","reason":"notInstalled"}]}'
    Check-Contract 'I03 degraded capability cannot hide an uninstalled requested client' { -not (Invoke-HookInstaller -InstallScript $stub -InstallArgs @{}).Ok } $true
    Put-ReviewText (Join-Path $work 'result-payload.json') '{"schema":1,"overall":"partial","components":[{"component":"claude","status":"ok","reason":"degraded"},{"component":"codex","status":"ok"},{"component":"nativeGit","status":"skipped","reason":"notApplicable"}]}'
    Check-Contract 'I04 genuine reduced capability with full requested coverage remains success' { (Invoke-HookInstaller -InstallScript $stub -InstallArgs @{}).Ok }
    $ledgerPath = Join-Path $work 'bounded-ledger.json'; $ledger = New-StopLedgerDocument
    foreach ($n in 1..4096) { Set-ObjectProperty $ledger.entries ('entry' + $n) ([pscustomobject]@{ fingerprint='retained' }) }
    Put-ReviewText $ledgerPath ($ledger | ConvertTo-Json -Depth 8 -Compress)
    $before = [IO.File]::ReadAllText($ledgerPath)
    $result = Invoke-StopLedgerUpdate $ledgerPath { param($state) Set-ObjectProperty $state.entries 'overflow' ([pscustomobject]@{fingerprint='extra'}); return 'claimed' }
    Check-Contract 'R01 exceeding the ledger map capacity refuses publication and preserves prior bytes' { -not $result.Ok -and [IO.File]::ReadAllText($ledgerPath) -ceq $before } $true
    Put-ReviewText $ledgerPath ((New-StopLedgerDocument) | ConvertTo-Json -Depth 8 -Compress); $before = [IO.File]::ReadAllText($ledgerPath)
    $result = Invoke-StopLedgerUpdate $ledgerPath { param($state) Set-ObjectProperty $state.entries 'oversized' ('x' * 2097152); return 'claimed' }
    Check-Contract 'R02 exceeding the ledger byte capacity cannot poison the next read' { -not $result.Ok -and [IO.File]::ReadAllText($ledgerPath) -ceq $before } $true
    $task = [pscustomobject]@{cwd=$work;session_id='capacity';hook_event_name='UserPromptSubmit';turn_id='c1';prompt='review capacity'}
    Register-UserTaskBoundary $task
    $scope = Get-TaskScope $task
    foreach ($n in 1..16) { $null = Register-TaskContinuation -HookInput $task -Reason ('receipt-' + $n) -AddHeader $false }
    $before = [IO.File]::ReadAllText($scope.Path)
    $overflow = Register-TaskContinuation -HookInput $task -Reason 'receipt-17' -AddHeader $false
    Check-Contract 'R03 a full pending-receipt collection refuses instead of evicting live receipts' { -not $overflow.Ok -and [IO.File]::ReadAllText($scope.Path) -ceq $before } $true
    $initial = (Get-CurrentUserTaskIdentity $task).TaskId
    $task.prompt = 'receipt-1'; $task.turn_id = 'c2'; Register-UserTaskBoundary $task
    Check-Contract 'R04 the oldest outstanding receipt still continues its original task' { (Get-CurrentUserTaskIdentity $task).TaskId -ceq $initial } $true
    $task.session_id = 'turn-capacity'; $task.turn_id='t1'; $task.prompt='start'; Register-UserTaskBoundary $task
    for ($n=2; $n -le 32; $n++) {
        $receipt = Register-TaskContinuation $task ('continue-' + $n)
        $task.turn_id = 't' + $n; $task.prompt = $receipt.Text; Register-UserTaskBoundary $task
    }
    $scope = Get-TaskScope $task; $initial = (Get-CurrentUserTaskIdentity $task).TaskId
    $receipt = Register-TaskContinuation $task 'over turn cap'; $before=[IO.File]::ReadAllText($scope.Path)
    $task.turn_id='t33'; $task.prompt=$receipt.Text; Register-UserTaskBoundary $task
    Check-Contract 'R05 turn-history capacity refuses without deleting an active dispatch' { [IO.File]::ReadAllText($scope.Path) -ceq $before } $true
    $task.turn_id='t1'; $task.prompt='start'; Register-UserTaskBoundary $task
    Check-Contract 'R06 replaying the first dispatch cannot refund a capacity-limited task' { (Get-CurrentUserTaskIdentity $task).TaskId -ceq $initial } $true
    $before=[IO.File]::ReadAllText($scope.Path)
    $mutation=Invoke-TaskIdentityUpdate $task { param($state,$scope) $state.turnIds=@('x' * 257); return $state }
    Check-Contract 'R07 invalid mutated task state is rejected before publication' { -not $mutation.Ok -and [IO.File]::ReadAllText($scope.Path) -ceq $before } $true

    # Real hook consumers, not only the shared extractor: raw fallback used to
    # turn UNKNOWN back into an accepted label from the old assistant response.
    $project = Join-Path $work 'consumer-project'; [void][IO.Directory]::CreateDirectory($project)
    Put-ReviewText (Join-Path $project '.codex\rules\review.md') 'Use evidence, not a placeholder.'
    Put-ReviewText (Join-Path $project '.agents\skills\review\SKILL.md') "---`nname: review`ndescription: review code`n---`nRead the source."
    $fullLabels = Assistant-Record @([pscustomobject]@{type='text';text="MCP used: Context7`nRules applied: review.md`nSkills used: review"})
    Put-ReviewText $transcript $fullLabels
    foreach ($name in @('Mcp-Usage-Check','Rules-Check','Skills-Check')) {
        $payload=[pscustomobject]@{cwd=$project;session_id=('consumer-'+$name);hook_event_name='UserPromptSubmit';prompt='Review the library API documentation'}
        $path=Join-Path $SourceRoot ('hooks\'+$name+'\'+$name+'.ps1')
        $null=Invoke-ReviewHook $path $payload
        $payload.hook_event_name='Stop'; Set-ObjectProperty $payload 'transcript_path' $transcript
        Set-ObjectProperty $payload 'last_assistant_message' ''
        $wire=Invoke-ReviewHook $path $payload
        Check-Contract ('E17 '+$name+' preserves UNKNOWN instead of accepting a raw old label') { $wire.Exit -eq 0 -and $wire.Err -eq '' -and $wire.Out -match 'NOT be verified' -and $wire.Out -notmatch '"decision":"block"' } $true
    }
    $summary=Join-Path $SourceRoot 'hooks\Session-Summary-Check\Session-Summary-Check.ps1'
    $payload=[pscustomobject]@{cwd=$project;session_id='shared-session';hook_event_name='SessionStart'}
    $wire=Invoke-ReviewHook $summary $payload 'claude'
    Check-Contract 'D01 a fresh SessionStart emits real summary policy' { $wire.Exit -eq 0 -and $wire.Err -eq '' -and $wire.Out -match 'CLOSING section' }
    $payload.hook_event_name='UserPromptSubmit'
    $wire=Invoke-ReviewHook $summary $payload 'codex'
    Check-Contract 'D02 identical session text under another client keeps its own reminder' { $wire.Exit -eq 0 -and $wire.Err -eq '' -and $wire.Out -match 'CLOSING section' } $true
    $wire=Invoke-ReviewHook $summary $payload 'claude'
    Check-Contract 'D03 the original client remains suppressed inside its own cooldown' { $wire.Exit -eq 0 -and $wire.Out -eq '' -and $wire.Err -eq '' }
    foreach ($n in 1..13) { $payload.session_id='intervening-'+$n; $null=Invoke-ReviewHook $summary $payload 'claude' }
    $payload.session_id='shared-session'; $wire=Invoke-ReviewHook $summary $payload 'claude'
    Check-Contract 'D04 thirteen other live sessions cannot evict an unexpired reservation' { $wire.Exit -eq 0 -and $wire.Err -eq '' -and $wire.Out -eq '' } $true
}
catch { $unexpectedError = $_.Exception.Message; Check-Contract 'HARNESS no unhandled exception' { throw $unexpectedError } }
finally {
    # Preserve the actual exception text in the normal case records; cleanup is
    # a separately required outcome, never suppressed by an expected red case.
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key]) }
    $clean = Remove-TestWorkspace -Path $work
    Check-Contract 'HARNESS all owned files removed' { $clean -and -not [IO.Directory]::Exists($work) }
}
$unexpected = @($cases | Where-Object { -not $_.matched }).Count
$failed = @($cases | Where-Object { -not $_.passed }).Count
if ($ResultPath -ne '') {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $ResultPath))
    $report=[ordered]@{schema=1;hostVersion=$PSVersionTable.PSVersion.ToString();baseline=[bool]$Baseline;cases=$cases.ToArray();failed=$failed;unexpected=$unexpected}
    [IO.File]::WriteAllText($ResultPath,($report | ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($false)))
}
Write-Host ('Cases: '+$cases.Count+'; actual failures: '+$failed+'; unexpected outcomes: '+$unexpected)
if ($unexpected -gt 0) { exit 1 }
exit 0
