param(
    [string]$SourceRoot = '', [switch]$ExpectBaselineFailures, [string]$ResultPath = '',
    [string]$WorkerRoot = '', [int]$WorkerIndex = 0
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$testRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if ($SourceRoot -eq '') { $SourceRoot = $testRoot }
. (Join-Path $testRoot 'scripts\_testlib.ps1')
. (Join-Path $SourceRoot 'hooks\_hooklib.ps1')
. (Join-Path $SourceRoot 'hooks\Session-Summary-Check\_generation.ps1')
$utf8 = New-Object Text.UTF8Encoding($false)

if ($WorkerRoot -ne '') {
    try {
        $inputDoc = [IO.File]::ReadAllText((Join-Path $WorkerRoot 'input.json')) | ConvertFrom-Json
        [IO.File]::WriteAllText((Join-Path $WorkerRoot "$WorkerIndex.ready"), 'ready', $utf8)
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while (-not [IO.File]::Exists((Join-Path $WorkerRoot 'release'))) {
            if ($watch.Elapsed.TotalSeconds -gt 25) { throw 'barrier timeout' }
            Start-Sleep -Milliseconds 10
        }
        $result = Publish-GenerationSummary -HookInput $inputDoc -Ready $true
        [IO.File]::WriteAllText((Join-Path $WorkerRoot "$WorkerIndex.json"), ($result | ConvertTo-Json -Compress), $utf8)
        exit 0
    }
    catch { [Console]::Error.WriteLine($_.Exception.Message); exit 2 }
}

$work = New-TestWorkspace -Prefix 'hookmaker-generation-safety'
$savedLocal = $env:LOCALAPPDATA; $savedClient = $env:HOOKMAKER_CLIENT; $savedClaude = $env:CLAUDE_PROJECT_DIR
$env:LOCALAPPDATA = $work; $env:HOOKMAKER_CLIENT = 'codex'; $env:CLAUDE_PROJECT_DIR = ''
$cases = New-Object 'System.Collections.Generic.List[object]'
function Case {
    param([string]$Name, [scriptblock]$Body, [bool]$OldFailure = $false)
    $passed = $false; $detail = ''; $exception = $false
    try { $passed = [bool](& $Body) }
    catch { $exception = $true; $detail = $_.Exception.Message + ' | ' + $_.ScriptStackTrace }
    $expectedFailure = $ExpectBaselineFailures -and $OldFailure
    $unexpected = $exception -or ($passed -eq $expectedFailure)
    [void]$cases.Add([pscustomobject]@{ name = $Name; passed = $passed; expectedFailure = [bool]$expectedFailure; exception = $exception; unexpected = [bool]$unexpected; detail = $detail })
    $level = if ($unexpected) { 'ERROR' } else { 'INFO' }
    Write-Host ('[' + [DateTime]::UtcNow.ToString('o') + '] [' + $level + '] ' + $Name + ' passed=' + $passed + ' expectedFailure=' + $expectedFailure + ' ' + $detail)
}
function New-Task {
    param([string]$Name)
    $inputDoc = [pscustomobject]@{ cwd = $work; session_id = $Name; hook_event_name = 'UserPromptSubmit'; prompt = 'Inspect this task'; turn_id = 'turn-1' }
    Register-UserTaskBoundary $inputDoc
    $inputDoc.hook_event_name = 'Stop'
    return $inputDoc
}
function Get-Path { param($InputDoc) return (Get-GenerationPath $work $InputDoc.session_id 'codex') }
function New-Doc {
    param($InputDoc)
    return [pscustomobject]@{ schema = 1; sessionId = $InputDoc.session_id; client = 'codex'; generations = @(); tombstones = @() }
}
function New-Entry {
    param([string]$Id, [string]$State = 'working', [string]$Actor = 'main')
    $terminal = $State -in @('finalized', 'unverified'); $at = [DateTime]::UtcNow.ToString('o')
    $pub = if ($State -eq 'finalized') { [pscustomobject]@{ at = $at; ready = $true; failure = ''; reported = $false } } else { $null }
    return [pscustomobject]@{ taskId = $Id; actor = $Actor; state = $State; evidence = 'evidence-a'; verdicts = @(); publication = $pub; endedAt = $(if ($terminal) { $at } else { $null }) }
}
function Put-Doc {
    param($InputDoc, $Doc)
    $path = Get-Path $InputDoc
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
    [IO.File]::WriteAllText($path, ($Doc | ConvertTo-Json -Depth 10), $utf8)
}
function New-Verdict { return [pscustomobject]@{ gate = 'PendingGate'; affirmative = $false; at = [DateTime]::UtcNow.ToString('o') } }
function Wire {
    param($InputDoc, [AllowNull()][object]$Answer, [switch]$OmitAnswer)
    $payload = $InputDoc.PSObject.Copy()
    if (-not $OmitAnswer) { Set-ObjectProperty -Object $payload -Name 'last_assistant_message' -Value $Answer }
    $ioRoot = Join-Path $work ([guid]::NewGuid().ToString('N')); [void][IO.Directory]::CreateDirectory($ioRoot)
    $inFile = Join-Path $ioRoot 'in.json'; $outFile = Join-Path $ioRoot 'out.txt'; $errFile = Join-Path $ioRoot 'err.txt'
    [IO.File]::WriteAllText($inFile, ($payload | ConvertTo-Json -Depth 8), $utf8)
    $exe = Join-Path $PSHOME $(if ($PSVersionTable.PSVersion.Major -le 5) { 'powershell.exe' } else { 'pwsh.exe' })
    # Start-Process on 5.1 can return an exited wrapper with no ExitCode.
    # Retain the child handle ourselves, as the concurrent workers do.
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $exe
    $start.Arguments = ConvertTo-ProcessArgumentString @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', (Join-Path $SourceRoot 'hooks\Session-Summary-Check\Session-Summary-Check.ps1'))
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    try {
        $null = $process.Handle
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write(($payload | ConvertTo-Json -Depth 8))
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(20000)) { throw 'hook process timeout' }
        if (-not $stdout.Wait(2000) -or -not $stderr.Wait(2000)) { throw 'hook pipe drain timeout' }
        $answer = [pscustomobject]@{ Exit = $process.ExitCode; Out = $stdout.Result; Err = $stderr.Result }
        if ($ResultPath -ne '') {
  $tracePath = Join-Path (Split-Path -Parent $ResultPath) 'wire.jsonl'
  [void][IO.Directory]::CreateDirectory((Split-Path -Parent $tracePath))
  [IO.File]::AppendAllText($tracePath, (([ordered]@{ session = $payload.session_id; event = $payload.hook_event_name; wire = $answer } | ConvertTo-Json -Depth 6 -Compress) + "`n"), $utf8)
        }
        return $answer
    }
    finally {
        if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(5000) }
        $process.Dispose()
    }
}
function Has-Publication { param($InputDoc) $entry = Get-GenerationRecord $InputDoc; return ($null -ne $entry -and $null -ne $entry.publication) }
function Concurrent-Publish {
    param($InputDoc)
    $dir = Join-Path $work 'concurrent'; [void][IO.Directory]::CreateDirectory($dir)
    [IO.File]::WriteAllText((Join-Path $dir 'input.json'), ($InputDoc | ConvertTo-Json), $utf8)
    $children = New-Object 'System.Collections.Generic.List[object]'
    try {
        $exe = Join-Path $PSHOME $(if ($PSVersionTable.PSVersion.Major -le 5) { 'powershell.exe' } else { 'pwsh.exe' })
        foreach ($n in 1..6) {
            $start = New-Object Diagnostics.ProcessStartInfo
            $start.FileName = $exe
            $start.Arguments = '-NoProfile -File "' + $PSCommandPath + '" -SourceRoot "' + $SourceRoot + '" -WorkerRoot "' + $dir + '" -WorkerIndex ' + $n
            $start.UseShellExecute = $false; $start.CreateNoWindow = $true
            $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
            $process = [Diagnostics.Process]::Start($start)
            [void]$children.Add([pscustomobject]@{ P = $process; Out = $process.StandardOutput.ReadToEndAsync(); Err = $process.StandardError.ReadToEndAsync() })
        }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        while (@(Get-ChildItem -LiteralPath $dir -Filter '*.ready' -File).Count -ne 6) {
            if ($clock.Elapsed.TotalSeconds -gt 25) { throw 'worker readiness timeout' }
            foreach ($child in $children) { if ($child.P.HasExited) { throw ('worker exited: ' + $child.Err.Result) } }
            Start-Sleep -Milliseconds 10
        }
        [IO.File]::WriteAllText((Join-Path $dir 'release'), 'release', $utf8)
        foreach ($child in $children) {
            if (-not $child.P.WaitForExit(10000)) { throw 'worker completion timeout' }
            if (-not $child.Err.Wait(1000) -or -not $child.Out.Wait(1000)) { throw 'worker pipe timeout' }
            if ($child.P.ExitCode -ne 0 -or $child.Err.Result -ne '') { throw ('worker failure: ' + $child.Err.Result) }
        }
        return @(1..6 | ForEach-Object { [IO.File]::ReadAllText((Join-Path $dir "$_.json")) | ConvertFrom-Json })
    }
    finally {
        foreach ($child in $children) {
            if (-not $child.P.HasExited) { $child.P.Kill(); [void]$child.P.WaitForExit(5000) }
            $child.P.Dispose()
        }
    }
}

try {
    # Retain the original wrapper behavior as a diagnostic, not as a
    # passing product assertion or an expected-failure substitute.
    $probeExe = Join-Path $PSHOME $(if ($PSVersionTable.PSVersion.Major -le 5) { 'powershell.exe' } else { 'pwsh.exe' })
    $legacy = Start-BoundedProcess -FilePath $probeExe -ArgumentList @('-NoProfile','-Command','exit 7') -TimeoutMs 15000
    try {
        $probe = [ordered]@{ requestedExit = 7; reportedExit = $legacy.ExitCode; hostVersion = $PSVersionTable.PSVersion.ToString() }
        if ($ResultPath -ne '') {
  [void][IO.Directory]::CreateDirectory((Split-Path -Parent $ResultPath))
  [IO.File]::WriteAllText((Join-Path (Split-Path -Parent $ResultPath) 'legacy-process-probe.json'), ($probe | ConvertTo-Json), $utf8)
        }
    }
    finally { $legacy.Dispose() }
    $h = New-Task 'wire-ordinary'; $w = Wire $h 'I am still checking.'
    Case 'G01 an ordinary Stop does not invent a published summary' { $w.Exit -eq 0 -and $w.Err -eq '' -and $w.Out -eq '' -and -not (Has-Publication $h) } $true
    $h = New-Task 'wire-empty'; $w = Wire $h ''
    Case 'G02 empty current text is not a publication' { $w.Exit -eq 0 -and $w.Out -eq '' -and -not (Has-Publication $h) } $true
    $h = New-Task 'wire-fence'; $w = Wire $h ('```text' + "`nDONE: example`nREMAINING: example`n" + '```')
    Case 'G03 fenced examples are not observed as the closing claim' { $w.Exit -eq 0 -and $w.Err -eq '' -and -not (Has-Publication $h) } $true
    $h = New-Task 'wire-quote'; $w = Wire $h "> DONE: example`n> REMAINING: example"
    Case 'G04 quoted examples are not publications' { $w.Exit -eq 0 -and -not (Has-Publication $h) } $true
    $h = New-Task 'wire-template'; $w = Wire $h "DONE: <work>`nREMAINING: <open items>"
    Case 'G05 empty templates are not publications' { $w.Exit -eq 0 -and -not (Has-Publication $h) } $true
    $h = New-Task 'wire-real'; $w = Wire $h "**DONE:** verified work`n**REMAINING:** none"
    Case 'G06 actual closing text is recorded silently and without readiness invented' {
        $e = Get-GenerationRecord $h
        $w.Exit -eq 0 -and $w.Out -eq '' -and $w.Err -eq '' -and $null -ne $e -and $null -ne $e.publication -and -not $e.publication.ready
    }
    # BYTES ALONE WERE NOT ENOUGH. The historical store rewrites the file on every
    # update, including a no-op, and whether the rewritten bytes match depends on
    # the host's JSON date handling - so this case passed on one runner PowerShell
    # version and failed on the next, with the same subject. "No physical write"
    # is what the fix actually guarantees, and it does not depend on the host.
    $beforeWrite = [IO.File]::GetLastWriteTimeUtc((Get-Path $h))
    $before = [IO.File]::ReadAllText((Get-Path $h)); $w = Wire $h "**DONE:** verified work`n**REMAINING:** none"
    Case 'G07 duplicate observation preserves the first record byte for byte, without rewriting it' {
        [IO.File]::ReadAllText((Get-Path $h)) -ceq $before -and [IO.File]::GetLastWriteTimeUtc((Get-Path $h)) -eq $beforeWrite -and $w.Out -eq ''
    } $true
    $h = New-Task 'wire-persian'
    $done = -join ([char[]]@(0x0686,0x06cc,0x20,0x0634,0x062f)); $left = -join ([char[]]@(0x0686,0x06cc,0x20,0x0645,0x0648,0x0646,0x062f))
    $w = Wire $h ([char]0x200f + $done + ": verified`n" + [char]0x200f + $left + ': none')
    Case 'G08 Persian labels and RTL controls preserve a genuine observation' { $w.Exit -eq 0 -and $w.Err -eq '' -and (Has-Publication $h) }
    $h = New-Task 'wire-child'; $h.hook_event_name = 'SubagentStop'
    Set-ObjectProperty $h 'agent_id' 'child-a'
    $parentPath = Join-Path $work 'parent.jsonl'
    [IO.File]::WriteAllText($parentPath, '{"type":"assistant","message":{"role":"assistant","content":"DONE: parent\nREMAINING: none"}}', $utf8)
    Set-ObjectProperty $h 'transcript_path' $parentPath
    $w = Wire $h $null -OmitAnswer
    Case 'G09 a child without its own closing evidence cannot publish the parent response' { $w.Exit -eq 0 -and -not (Has-Publication $h) } $true

    $h = New-Task 'working'; $null = Set-GenerationState $h 'working'
    Case 'G10 silence from unrun gates is not readiness' { -not (Test-GenerationReady $h).Ready } $true
    $null = Set-GenerationState $h 'validating' 'proof-a'
    Case 'G11 validating is not ready even with unchanged evidence' { -not (Test-GenerationReady $h -Evidence 'proof-a').Ready } $true
    $hEmpty = New-Task 'empty-proof'; $null = Set-GenerationState $hEmpty 'ready'
    Case 'G12 a ready label without evidence is not readiness' { -not (Test-GenerationReady $hEmpty).Ready } $true
    $null = Set-GenerationState $h 'ready' 'proof-a'
    Case 'G13 an explicit ready record with its evidence remains usable' { (Test-GenerationReady $h -Evidence 'proof-a').Ready }
    $snapshot = Test-GenerationReady $h
    $null = Register-GenerationVerdict $h 'LateGate' $false
    $publication = Publish-GenerationSummary $h $snapshot.Ready
    Case 'G14 publication rechecks a late refusal under its own lock' { $e = Get-GenerationRecord $h; -not $e.publication.ready -and $publication.Failure -match 'LateGate' } $true

    $hLegacy = New-Task 'legacy-finalized'
    $legacyDoc = New-Doc $hLegacy
    $legacyEntry = New-Entry (Get-CurrentUserTaskIdentity $hLegacy).TaskId 'finalized'
    $legacyEntry.publication = $null
    $legacyDoc.generations = @($legacyEntry)
    Put-Doc $hLegacy $legacyDoc
    Case 'G15 a legacy finalized label without publication is not readiness' {
        -not (Test-GenerationReady $hLegacy).Ready
    } $true
    $hFresh = New-Task 'forged-finalized'
    $forged = Set-GenerationState $hFresh 'finalized' 'a label is not a receipt'
    Case 'R10 a fresh task cannot be finalized without a verified publication' {
        -not $forged.Ok -and -not [IO.File]::Exists((Get-Path $hFresh))
    } $true

    $h = New-Task 'terminal'; $null = Set-GenerationState $h 'ready' 'proof'
    $null = Publish-GenerationSummary $h $true
    $bytes = [IO.File]::ReadAllText((Get-Path $h))
    $reopen = Set-GenerationState $h 'working'
    Case 'R01 a recorded terminal generation cannot become live again' { -not $reopen.Ok -and [IO.File]::ReadAllText((Get-Path $h)) -ceq $bytes } $true
    $h = New-Task 'retired'; $id = (Get-CurrentUserTaskIdentity $h).TaskId
    $doc = New-Doc $h; $doc.tombstones = @([pscustomobject]@{ taskId = $id; actor = 'main'; endedAt = [DateTime]::UtcNow.ToString('o') }); Put-Doc $h $doc
    $bytes = [IO.File]::ReadAllText((Get-Path $h)); $late = Register-GenerationVerdict $h 'LateGate' $true
    Case 'R02 a late verdict cannot recreate a retired generation' { -not $late.Ok -and [IO.File]::ReadAllText((Get-Path $h)) -ceq $bytes } $true
    $h = New-Task 'unresolved'; $doc = New-Doc $h; $entry = New-Entry 'protected' 'unverified'; $entry.verdicts = @(New-Verdict); $doc.generations = @($entry); Put-Doc $h $doc
    $bytes = [IO.File]::ReadAllText((Get-Path $h)); $gc = Invoke-GenerationCollection $h
    Case 'R03 terminal-labelled unresolved findings are retained' { $gc.Collected -eq 0 -and [IO.File]::ReadAllText((Get-Path $h)) -ceq $bytes } $true
    $entry.verdicts = @(); $entry.publication = [pscustomobject]@{ at = [DateTime]::UtcNow.ToString('o'); ready = $false; failure = 'ReviewPending'; reported = $false }; Put-Doc $h $doc
    $bytes = [IO.File]::ReadAllText((Get-Path $h)); $gc = Invoke-GenerationCollection $h
    Case 'R04 an unreported publication warning is not collected' { $gc.Collected -eq 0 -and [IO.File]::ReadAllText((Get-Path $h)) -ceq $bytes } $true
    $entry.state = 'finalized'; Put-Doc $h $doc; $gc = Invoke-GenerationCollection $h
    Case 'R05 a finalized label does not override an unverified publication' { $gc.Collected -eq 0 } $true
    $h = New-Task 'safe-collection'; $doc = New-Doc $h; $doc.generations = @((New-Entry 'done' 'finalized'), (New-Entry 'live')); Put-Doc $h $doc
    $gc = Invoke-GenerationCollection $h; $after = (Get-GenerationDocumentState (Get-Path $h)).Doc
    Case 'R06 verified terminal data compacts while live data survives' { $gc.Collected -eq 1 -and $after.generations.Count -eq 1 -and $after.generations[0].taskId -eq 'live' -and $after.tombstones.Count -eq 1 }
    $h = New-Task 'stones-full'; $doc = New-Doc $h
    $doc.tombstones = @(1..64 | ForEach-Object { [pscustomobject]@{ taskId = "retired-$_"; actor = 'main'; endedAt = [DateTime]::UtcNow.ToString('o') } })
    $doc.generations = @((New-Entry 'completed-new' 'finalized')); Put-Doc $h $doc
    $bytes = [IO.File]::ReadAllText((Get-Path $h)); $gc = Invoke-GenerationCollection $h
    Case 'R07 full tombstone capacity never evicts replay protection' { $gc.Collected -eq 0 -and $gc.Refused -and [IO.File]::ReadAllText((Get-Path $h)) -ceq $bytes } $true
    $h = New-Task 'actor'; $child = $h.PSObject.Copy(); Set-ObjectProperty $child 'agent_id' 'child-b'
    $null = Set-GenerationState $child 'validating' 'child-proof'; $null = Publish-GenerationSummary $child $false @('ChildPending')
    $parentNotice = Read-GenerationFailureOnce $h
    Case 'R08 a parent does not consume or misattribute a child warning' { $parentNotice -eq '' } $true
    $childNotice = Read-GenerationFailureOnce $child
    Case 'R09 the owning child can still consume its warning once' { $childNotice -eq 'ChildPending' -and (Read-GenerationFailureOnce $child) -eq '' } $true

    foreach ($kind in @('boolean', 'duplicate', 'tombstone', 'timestamp', 'publication')) {
        $h = New-Task ('shape-' + $kind); $doc = New-Doc $h; $entry = New-Entry (Get-CurrentUserTaskIdentity $h).TaskId 'ready'; $doc.generations = @($entry)
        switch ($kind) {
            boolean { $v = New-Verdict; $v.affirmative = 'false'; $entry.verdicts = @($v) }
            duplicate { $doc.generations = @($entry, $entry) }
            tombstone { $doc.tombstones = @([pscustomobject]@{ taskId = 'retired' }) }
            timestamp { $entry.state = 'unverified'; $entry.endedAt = 'not a timestamp' }
            publication { $entry.publication = [pscustomobject]@{} }
        }
        Put-Doc $h $doc
        Case ('V01 persisted ' + $kind + ' corruption is rejected') { (Get-GenerationDocumentState (Get-Path $h)).State -eq 'corrupt' } $true
    }
    $h = New-Task 'wrong-scope'; $doc = New-Doc $h; $doc.generations = @((New-Entry (Get-CurrentUserTaskIdentity $h).TaskId)); $doc.sessionId = 'another-session'; Put-Doc $h $doc
    Case 'V02 a read cannot borrow a record from a mismatching stored session' { $null -eq (Get-GenerationRecord $h) } $true
    $h = New-Task 'bad-mutation'; $null = Set-GenerationState $h 'ready' 'proof'; $bytes = [IO.File]::ReadAllText((Get-Path $h))
    $result = Invoke-GenerationUpdate $h -Mutate { param($doc, $identity) $entry = Find-GenerationEntry $doc $identity.TaskId $identity.Actor; $entry.publication = [pscustomobject]@{} }
    Case 'V03 invalid prospective publication never replaces valid bytes' { -not $result.Ok -and [IO.File]::ReadAllText((Get-Path $h)) -ceq $bytes } $true
    $h = New-Task 'concurrent'; $null = Set-GenerationState $h 'ready' 'proof'; $results = @(Concurrent-Publish $h)
    Case 'C01 six simultaneous publishers commit exactly one observation' { @($results | Where-Object Published).Count -eq 1 -and @($results | Where-Object AlreadyPublished).Count -eq 5 }
    $bytes = [IO.File]::ReadAllText((Get-Path $h)); $handle = [IO.File]::Open(((Get-Path $h) + '.lock'), 'Open', 'ReadWrite', 'None')
    try { $busy = Set-GenerationState $h 'working' }
    finally { $handle.Dispose() }
    Case 'C02 an unavailable lock refuses mutation and preserves state' { -not $busy.Ok -and $busy.State -eq 'busy' -and [IO.File]::ReadAllText((Get-Path $h)) -ceq $bytes }

    # Invoke the actual resolver and catalog, not a regex over its formatting.
    $events = @(& {
        . (Join-Path $SourceRoot 'scripts\Setup-SyncGroupPresentation.ps1')
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'scripts\Setup-SyncGroup.ps1'), [ref]$null, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) { throw 'wizard source cannot parse' }
        $resolver = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-HookRecommendedEvents' }, $true)
        . ([scriptblock]::Create($resolver.Extent.Text))
        Get-HookRecommendedEvents ([pscustomobject]@{ Name = 'Session-Summary-Check'; EnvPath = '' })
    })
    Case 'I01 shipped defaults actually register both silent observation events' { $events -contains 'Stop' -and $events -contains 'SubagentStop' -and $events -contains 'SessionStart' -and $events -contains 'UserPromptSubmit' } $true
    $migrations = @(& { . (Join-Path $SourceRoot 'scripts\_installeventmigration.ps1'); $script:InstalledEventMigrations })
    Case 'I02 the exact formerly shipped pre-task binding has a versioned migration' { @($migrations | Where-Object { $_.Hook -eq 'Session-Summary-Check' -and ($_.From -join '|') -eq 'SessionStart|UserPromptSubmit' }).Count -eq 1 } $true
}
catch { Case 'HARNESS suite completed without infrastructure exceptions' { throw $_.Exception.Message } }
finally {
    $env:LOCALAPPDATA = $savedLocal; $env:HOOKMAKER_CLIENT = $savedClient; $env:CLAUDE_PROJECT_DIR = $savedClaude
    $cleaned = Remove-TestWorkspace -Path $work
    Case 'C03 all owned workspace artifacts are removed' { $cleaned -and -not [IO.Directory]::Exists($work) }
}
$unexpected = @($cases.ToArray() | Where-Object unexpected).Count
$failed = @($cases.ToArray() | Where-Object { -not $_.passed }).Count
$report = [ordered]@{ hostVersion = $PSVersionTable.PSVersion.ToString(); baseline = [bool]$ExpectBaselineFailures; cases = $cases.ToArray(); failed = $failed; unexpected = $unexpected }
if ($ResultPath -ne '') { [void][IO.Directory]::CreateDirectory((Split-Path -Parent $ResultPath)); [IO.File]::WriteAllText($ResultPath, ($report | ConvertTo-Json -Depth 10), $utf8) }
Write-Host ('Cases=' + $cases.Count + '; failed=' + $failed + '; unexpected=' + $unexpected)
if ($unexpected -gt 0) { exit 1 }
exit 0
