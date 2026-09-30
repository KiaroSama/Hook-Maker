param([string]$SourceRoot = '', [switch]$ExpectBaselineFailures, [string]$ResultPath = '',
    [string]$WorkerRoot = '', [int]$WorkerIndex = 0)
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
        $script:GateReceiptGlobalRoot = Join-Path $env:LOCALAPPDATA 'home'
        $payload = [IO.File]::ReadAllText((Join-Path $WorkerRoot 'input.json')) | ConvertFrom-Json
        $receipt = Start-StopGateReceipt $payload 'Git-Sync-Check'
        if ($null -eq $receipt) { throw 'worker could not reserve its receipt' }
        [IO.File]::WriteAllText((Join-Path $WorkerRoot "$WorkerIndex.ready"), 'ready', $utf8)
        $clock = [Diagnostics.Stopwatch]::StartNew()
        while (-not [IO.File]::Exists((Join-Path $WorkerRoot 'release'))) {
            if ($clock.Elapsed.TotalSeconds -gt 25) { throw 'worker barrier timeout' }
            Start-Sleep -Milliseconds 10
        }
        if ($WorkerIndex -eq 1) { $script:StopGateVerdict = 'block' }
        else { $script:StopGateVerdict = '' }
        Complete-StopGateReceipt $receipt
        [IO.File]::WriteAllText((Join-Path $WorkerRoot "$WorkerIndex.result"), 'complete', $utf8)
        exit 0
    }
    catch { [Console]::Error.WriteLine($_.Exception.Message); exit 2 }
}

$work = New-TestWorkspace -Prefix 'hookmaker-receipt-isolation'
$savedLocal = $env:LOCALAPPDATA; $savedClient = $env:HOOKMAKER_CLIENT; $savedClaude = $env:CLAUDE_PROJECT_DIR
$env:LOCALAPPDATA = $work; $env:HOOKMAKER_CLIENT = 'claude'; $env:CLAUDE_PROJECT_DIR = ''
$script:GateReceiptGlobalRoot = Join-Path $work 'home'
$script:GateReceiptWaitMs = 10
$cases = New-Object 'System.Collections.Generic.List[object]'
function Check-Receipt {
    param([string]$Name, [scriptblock]$Test, [bool]$OldFailure = $false)
    $ok = $false; $exception = $false; $detail = ''
    try { $ok = [bool](& $Test) }
    catch { $exception = $true; $detail = $_.Exception.Message + ' | ' + $_.ScriptStackTrace }
    $expected = [bool]($ExpectBaselineFailures -and $OldFailure)
    $unexpected = $exception -or ($ok -eq $expected)
    [void]$cases.Add([pscustomobject]@{ name = $Name; passed = $ok; expectedFailure = $expected; exception = $exception; unexpected = $unexpected; detail = $detail })
    $level = if ($unexpected) { 'ERROR' } else { 'INFO' }
    Write-Host ('[' + [DateTime]::UtcNow.ToString('o') + '] [' + $level + '] ' + $Name + ' passed=' + $ok + ' expectedFailure=' + $expected + ' ' + $detail)
}
function New-Payload {
    param([string]$Name)
    $h = [pscustomobject]@{ cwd = $work; session_id = $Name; turn_id = 'turn-1'; hook_event_name = 'UserPromptSubmit'; prompt = 'Inspect the current task'; last_assistant_message = "DONE: implemented and checked`nREMAINING: none" }
    Register-UserTaskBoundary $h
    $h.hook_event_name = 'Stop'
    return $h
}
function Handler {
    param([string]$Name)
    return [pscustomobject]@{ type = 'command'; command = ('powershell.exe -File "C:\fixture\.claude\hooks\Hook-Maker\' + $Name + '\' + $Name + '.ps1"') }
}
function Put-Settings {
    param($Doc, [string]$Client = 'claude')
    $relative = if ($Client -eq 'codex') { '.codex\hooks.json' } else { '.claude\settings.local.json' }
    $path = Join-Path $work $relative
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
    [IO.File]::WriteAllText($path, ($Doc | ConvertTo-Json -Depth 12), $utf8)
}
function Registration {
    param([string]$Client = 'claude')
    Put-Settings ([pscustomobject]@{ hooks = [pscustomobject]@{ Stop = @([pscustomobject]@{ hooks = @((Handler 'Git-Sync-Check'), (Handler 'Session-Summary-Check')) }); SubagentStop = @([pscustomobject]@{ hooks = @((Handler 'Git-Sync-Check'), (Handler 'Session-Summary-Check')) }) } }) $Client
}
function Finish {
    param($Receipt, [string]$Verdict = 'pass')
    $script:StopGateVerdict = if ($Verdict -eq 'block') { 'block' } else { '' }
    if ($Verdict -eq 'error') { $Receipt.Crashed = $true }
    Complete-StopGateReceipt $Receipt
}
function Receipt-Value { param($InputDoc) return (Read-StopGateReceipt (Get-StopGateReceiptPath $InputDoc 'Git-Sync-Check')) }
function Generation-Path { param($InputDoc) return (Get-GenerationPath $work $InputDoc.session_id (Get-HookClientId)) }
function Read-RawJson {
    param([string]$Path)
    $raw = [IO.File]::ReadAllText($Path)
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { return ($raw | ConvertFrom-Json -DateKind String) }
    return ($raw | ConvertFrom-Json)
}

try {
    Registration
    $h = New-Payload 'scope'
    $p = Get-StopGateReceiptPath $h 'Git-Sync-Check'
    Check-Receipt 'S01 a supported current task has a usable receipt path' { $p -ne '' }
    foreach ($dimension in @('actor', 'turn', 'response', 'event')) {
        $other = $h.PSObject.Copy()
        switch ($dimension) {
            actor { Set-ObjectProperty $other 'agent_id' 'child-1' }
            turn { $other.turn_id = 'turn-2' }
            response { $other.last_assistant_message += ' changed' }
            event { $other.hook_event_name = 'SubagentStop'; Set-ObjectProperty $other 'agent_id' 'child-2' }
        }
        Check-Receipt ('S02 ' + $dimension + ' does not share receipt storage') { (Get-StopGateReceiptPath $other 'Git-Sync-Check') -ne $p } $true
    }
    $first = Start-StopGateReceipt $h 'Git-Sync-Check'; Finish $first
    $child = $h.PSObject.Copy(); $child.hook_event_name = 'SubagentStop'; Set-ObjectProperty $child 'agent_id' 'child-independent'
    Check-Receipt 'S03 a child cannot read its parents pass' { $null -eq (Receipt-Value $child) } $true
    $other = $h.PSObject.Copy(); $other.session_id = ''
    Check-Receipt 'S04 missing session remains unknown rather than adopting another record' { (Get-StopGateReceiptPath $other 'Git-Sync-Check') -eq '' }
    $other = $h.PSObject.Copy(); $other.last_assistant_message = ''
    Check-Receipt 'S05 unusable current answer cannot establish receipt provenance' { (Get-StopGateReceiptPath $other 'Git-Sync-Check') -eq '' } $true
    $hTask = $h.PSObject.Copy(); $hTask.hook_event_name = 'UserPromptSubmit'; $hTask.prompt = 'A new task'; $hTask.turn_id = 'new-turn'
    Register-UserTaskBoundary $hTask; $hTask.hook_event_name = 'Stop'
    Check-Receipt 'S06 a later user task in the same session cannot inherit the previous pass' { $null -eq (Receipt-Value $hTask) } $true

    $h = New-Payload 'interleave'; $a = Start-StopGateReceipt $h 'Git-Sync-Check'; $b = Start-StopGateReceipt $h 'Git-Sync-Check'
    Finish $a
    Check-Receipt 'A01 completing one attempt cannot conceal another running attempt' { (Receipt-Value $h).Verdict -ne 'pass' } $true
    Finish $b 'block'; Finish $a
    Check-Receipt 'A02 a delayed pass cannot replace another completed block' { (Receipt-Value $h).Verdict -eq 'block' } $true
    $path = Get-StopGateReceiptPath $h 'Git-Sync-Check'; $before = [IO.File]::ReadAllText($path)
    Finish $a
    Check-Receipt 'A03 duplicate terminal delivery is byte-idempotent' { [IO.File]::ReadAllText($path) -ceq $before } $true
    $h = New-Payload 'positive'; $a = Start-StopGateReceipt $h 'Git-Sync-Check'; Finish $a
    Check-Receipt 'A04 a genuinely completed sole attempt passes' { (Receipt-Value $h).Verdict -eq 'pass' }
    $h = New-Payload 'crash'; $a = Start-StopGateReceipt $h 'Git-Sync-Check'; Finish $a 'error'
    Check-Receipt 'A05 a crashed attempt is never a pass' { (Receipt-Value $h).Verdict -eq 'error' }
    $h = New-Payload 'held'; $a = Start-StopGateReceipt $h 'Git-Sync-Check'
    $path = Get-StopGateReceiptPath $h 'Git-Sync-Check'; $before = [IO.File]::ReadAllText($path)
    $held = [IO.File]::Open(($path + '.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try { Finish $a } finally { $held.Dispose() }
    Check-Receipt 'A06 a held receipt lock cannot silently authorize a pass' { [IO.File]::ReadAllText($path) -ceq $before -and (Receipt-Value $h).Verdict -eq 'running' } $true
    Finish $a
    Check-Receipt 'A07 a refused completion succeeds after its lock is available' { (Receipt-Value $h).Verdict -eq 'pass' }

    foreach ($damage in @('schema','gate','future','oversize')) {
        $h = New-Payload ('invalid-' + $damage); $a = Start-StopGateReceipt $h 'Git-Sync-Check'; Finish $a
        $path = Get-StopGateReceiptPath $h 'Git-Sync-Check'; $doc = Read-RawJson $path
        switch ($damage) {
            schema { $doc.schema = 999 }
            gate { $doc.gate = 'OtherGate' }
            future {
                $future = [DateTime]::UtcNow.AddDays(1).ToString('o')
                if ($null -ne $doc.PSObject.Properties['attempts']) { $doc.attempts[0].at = $future } else { $doc.at = $future }
            }
            oversize { Set-ObjectProperty $doc 'padding' ('x' * 70000) }
        }
        [IO.File]::WriteAllText($path, ($doc | ConvertTo-Json -Depth 6), $utf8)
        Check-Receipt ('V01 ' + $damage + ' receipt cannot prove completion') { $null -eq (Read-StopGateReceipt $path) } $true
    }

    $h = New-Payload 'settings'
    Put-Settings ([pscustomobject]@{ hooks = [pscustomobject]@{ Stop = @([pscustomobject]@{ hooks = @([pscustomobject]@{ type='command'; command='powershell.exe'; args=@('-File','C:\fixture\Hook-Maker\Git-Sync-Check\Git-Sync-Check.ps1') }, (Handler 'Session-Summary-Check')) }) } })
    $required = Get-RequiredStopGates $h
    Check-Receipt 'P01 managed script paths in argv are not silently skipped' { $required.Known -and $required.Gates -contains 'Git-Sync-Check' } $true
    Put-Settings ([pscustomobject]@{ hooks = $null })
    Check-Receipt 'P02 null hooks configuration is unknown, not no gates' { -not (Get-RequiredStopGates $h).Known } $true
    Put-Settings ([pscustomobject]@{ hooks = [pscustomobject]@{ UserPromptSubmit = @([pscustomobject]@{ hooks=@((Handler 'Session-Summary-Check')) }); Stop=@([pscustomobject]@{ hooks=@((Handler 'Git-Sync-Check')) }) } })
    Check-Receipt 'P03 an observer on another event is not registered for this Stop' { -not (Test-StopObserverRegistered $h) } $true
    $one = Handler 'Git-Sync-Check'; $two = Handler 'Git-Sync-Check'; $two.command += ' -DifferentBinding'
    Put-Settings ([pscustomobject]@{ hooks = [pscustomobject]@{ Stop = @([pscustomobject]@{ hooks=@($one,$two,(Handler 'Session-Summary-Check')) }) } })
    Check-Receipt 'P04 distinct same-name registrations cannot collapse into one proof' { -not (Get-RequiredStopGates $h).Known } $true
    $h.hook_event_name = 'SubagentStop'; Set-ObjectProperty $h 'agent_type' 'Explore'; Set-ObjectProperty $h 'agent_id' 'explorer'
    Put-Settings ([pscustomobject]@{ hooks = [pscustomobject]@{ SubagentStop = @([pscustomobject]@{ matcher='Plan'; hooks=@((Handler 'Git-Sync-Check')) }, [pscustomobject]@{ matcher='Explore'; hooks=@((Handler 'Session-Summary-Check')) }) } })
    $required = Get-RequiredStopGates $h
    Check-Receipt 'P05 a nonmatching child binding is not a required gate' { $required.Known -and $required.Gates.Count -eq 0 } $true
    $env:HOOKMAKER_CLIENT = 'codex'; $h = New-Payload 'windows-command'
    Put-Settings ([pscustomobject]@{ hooks = [pscustomobject]@{ Stop=@([pscustomobject]@{ hooks=@([pscustomobject]@{type='command'; command='pwsh -File /p/Hook-Maker/Git-Sync-Check/Git-Sync-Check.ps1'; commandWindows='powershell -File C:\p\Hook-Maker\Rules-Check\Rules-Check.ps1'},(Handler 'Session-Summary-Check')) }) } }) 'codex'
    $required = Get-RequiredStopGates $h
    Check-Receipt 'P06 Windows override selects one command rather than a union with Unix' { $required.Known -and $required.Gates -contains 'Rules-Check' -and $required.Gates -notcontains 'Git-Sync-Check' } $true
    $env:HOOKMAKER_CLIENT = 'claude'; Registration
    $h = New-Payload 'config-moved'; $a = Start-StopGateReceipt $h 'Git-Sync-Check'; Finish $a
    Put-Settings ([pscustomobject]@{ description='new policy revision'; hooks=[pscustomobject]@{ Stop=@([pscustomobject]@{hooks=@((Handler 'Git-Sync-Check'),(Handler 'Session-Summary-Check'))}) } })
    Check-Receipt 'P07 a configuration revision invalidates an old pass for identical answer text' { $null -eq (Receipt-Value $h) } $true
    $env:HOOKMAKER_CLIENT = 'codex'; $h = New-Payload 'codex-matcher'; $h.hook_event_name='SubagentStop'
    Set-ObjectProperty $h 'agent_id' 'review-child'; Set-ObjectProperty $h 'agent_type' 'SeniorExplore'
    Put-Settings ([pscustomobject]@{hooks=[pscustomobject]@{SubagentStop=@([pscustomobject]@{matcher='Explore';hooks=@((Handler 'Git-Sync-Check'))},[pscustomobject]@{hooks=@((Handler 'Session-Summary-Check'))})}}) 'codex'
    Check-Receipt 'P08 Codex literal regex matches within the child type' { $set=Get-RequiredStopGates $h; $set.Known -and $set.Gates -contains 'Git-Sync-Check' }
    $h.agent_type='Plan'
    Check-Receipt 'P09 Codex nonmatching regex is not required' { $set=Get-RequiredStopGates $h; $set.Known -and $set.Gates.Count -eq 0 } $true
    $env:HOOKMAKER_CLIENT='claude'; $h.agent_type='SeniorExplore'
    Put-Settings ([pscustomobject]@{hooks=[pscustomobject]@{SubagentStop=@([pscustomobject]@{matcher='Explore, Plan';hooks=@((Handler 'Git-Sync-Check'))},[pscustomobject]@{hooks=@((Handler 'Session-Summary-Check'))})}})
    Check-Receipt 'P10 Claude literal alternatives are exact rather than substring matches' { $set=Get-RequiredStopGates $h; $set.Known -and $set.Gates.Count -eq 0 } $true
    Put-Settings ([pscustomobject]@{hooks=[pscustomobject]@{SubagentStop=@([pscustomobject]@{matcher='code-reviewer';hooks=@((Handler 'Git-Sync-Check'))},[pscustomobject]@{hooks=@((Handler 'Session-Summary-Check'))})}})
    Check-Receipt 'P11 version-dependent Claude hyphen semantics are not guessed' { -not (Get-RequiredStopGates $h).Known } $true
    Registration

    # Test the actual subject's shared process wrapper, not a renamed local
    # copy, and keep historical host differences explicit. This fixes the
    # source of the existing generation suite's null-ExitCode false failures.
    foreach ($code in @(0,7)) {
        $reported = & {
            param($Subject, $ExitStatus)
            . (Join-Path $Subject 'scripts\_testlib.ps1')
            $exe = Join-Path $PSHOME $(if ($PSVersionTable.PSVersion.Major -le 5) { 'powershell.exe' } else { 'pwsh.exe' })
            $child = Start-BoundedProcess -FilePath $exe -ArgumentList @('-NoProfile','-Command',('Start-Sleep -Milliseconds 100; exit ' + $ExitStatus)) -TimeoutMs 15000
            try { return [pscustomobject]@{Code=$child.ExitCode; Gone=$child.HasExited} } finally {$child.Dispose()}
        } $SourceRoot $code
        Check-Receipt ('H01 real child exit ' + $code + ' survives the bounded wait') { $reported.Gone -and $reported.Code -eq $code } ($PSVersionTable.PSVersion.Major -le 5)
    }

    $h = New-Payload 'promotion'; $null = Set-GenerationState $h 'validating' 'old-proof'; $null = Publish-GenerationSummary $h $false @('Git-Sync-Check:no-receipt')
    $firstAt = (Get-GenerationRecord $h).publication.at
    $null = Set-GenerationState $h 'ready' 'new-proof'; $null = Register-GenerationVerdict $h 'Git-Sync-Check' $true
    $result = Publish-GenerationSummary $h $true; $record = Get-GenerationRecord $h
    Check-Receipt 'F01 later affirmative proof finalizes an already-observed same task' { $record.state -eq 'finalized' -and $record.publication.ready } $true
    Check-Receipt 'F02 finalizing evidence does not publish a second summary observation' { -not $result.Published -and $result.AlreadyPublished -and $record.publication.at -eq $firstAt }
    Check-Receipt 'F03 later verification preserves the original premature reason' { (Get-Field $record.publication 'firstFailure') -eq 'Git-Sync-Check:no-receipt' } $true
    $h = New-Payload 'still-blocked'; $null = Set-GenerationState $h 'ready' 'proof'; $null = Register-GenerationVerdict $h 'Git-Sync-Check' $false
    $null = Publish-GenerationSummary $h $false @('Git-Sync-Check:block'); $null = Publish-GenerationSummary $h $true
    Check-Receipt 'F04 a live negative verdict still prevents finalization' { -not (Get-GenerationRecord $h).publication.ready }

    $h = New-Payload 'wire-producer'; $since = [DateTime]::UtcNow.AddSeconds(-1)
    $null = Observe-GenerationSummary $h -Since $since
    $a = Start-StopGateReceipt $h 'Git-Sync-Check'; Finish $a
    $null = Observe-GenerationSummary $h -Since $since
    $record = Get-GenerationRecord $h
    Check-Receipt 'F05 the real observer can settle after its initially missing receipt arrives' { $record.state -eq 'finalized' -and $record.publication.ready } $true

    # Actual concurrent writers share a readiness barrier. Workers only update
    # isolated receipt files; they never launch arbitrary project commands.
    $h = New-Payload 'concurrent'; $dir = Join-Path $work 'workers'; [void][IO.Directory]::CreateDirectory($dir)
    [IO.File]::WriteAllText((Join-Path $dir 'input.json'), ($h | ConvertTo-Json), $utf8)
    $children = New-Object 'System.Collections.Generic.List[object]'
    try {
        $exe = Join-Path $PSHOME $(if ($PSVersionTable.PSVersion.Major -le 5) { 'powershell.exe' } else { 'pwsh.exe' })
        foreach ($n in 1..4) {
            $info = New-Object Diagnostics.ProcessStartInfo
            $info.FileName = $exe
            $info.Arguments = ConvertTo-ProcessArgumentString @('-NoProfile','-File',$PSCommandPath,'-SourceRoot',$SourceRoot,'-WorkerRoot',$dir,'-WorkerIndex',[string]$n)
            $info.UseShellExecute=$false; $info.CreateNoWindow=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
            $process = [Diagnostics.Process]::Start($info); $null = $process.Handle
            [void]$children.Add([pscustomobject]@{P=$process; Out=$process.StandardOutput.ReadToEndAsync(); Err=$process.StandardError.ReadToEndAsync()})
        }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        while (@(Get-ChildItem -LiteralPath $dir -Filter '*.ready' -File).Count -lt 4) {
            if ($clock.Elapsed.TotalSeconds -gt 25) { throw 'parent barrier timeout' }
            foreach ($child in $children) { if ($child.P.HasExited) { throw ('premature worker exit: ' + $child.Err.Result) } }
            Start-Sleep -Milliseconds 10
        }
        $pending = Receipt-Value $h
        Check-Receipt 'C01 all simultaneous starts remain visible as pending attempts' { (Get-Field $pending 'Attempts') -eq 4 -and $pending.Verdict -eq 'running' } $true
        [IO.File]::WriteAllText((Join-Path $dir 'release'),'release',$utf8)
        foreach ($child in $children) {
            if (-not $child.P.WaitForExit(10000)) { throw 'worker exit timeout' }
            if (-not $child.Err.Wait(2000) -or -not $child.Out.Wait(2000) -or $child.P.ExitCode -ne 0 -or $child.Err.Result -ne '') { throw 'worker failed or leaked a pipe' }
        }
        # The baseline race is nondeterministic after simultaneous completions.
        # Verify its failure deterministically above; here inspect retained tokens.
        $complete = Receipt-Value $h
        Check-Receipt 'C02 concurrent completions preserve four attempts including the block' { (Get-Field $complete 'Attempts') -eq 4 -and $complete.Verdict -eq 'block' } $true
    }
    finally {
        foreach ($child in $children) {
            if (-not $child.P.HasExited) { $child.P.Kill(); [void]$child.P.WaitForExit(5000) }
            $child.P.Dispose()
        }
    }
}
catch {
    $errorMessage = $_.Exception.Message + ' | ' + $_.ScriptStackTrace
    Check-Receipt 'HARNESS no infrastructure or unhandled product exception' { throw $errorMessage }
}
finally {
    $env:LOCALAPPDATA=$savedLocal; $env:HOOKMAKER_CLIENT=$savedClient; $env:CLAUDE_PROJECT_DIR=$savedClaude
    $cleaned = Remove-TestWorkspace -Path $work
    Check-Receipt 'C03 all owned test files are removed' { $cleaned -and -not [IO.Directory]::Exists($work) }
}
$failed=@($cases.ToArray() | Where-Object { -not $_.passed }).Count
$unexpected=@($cases.ToArray() | Where-Object unexpected).Count
$report=[ordered]@{host=$PSVersionTable.PSVersion.ToString(); baseline=[bool]$ExpectBaselineFailures; cases=$cases.ToArray(); failed=$failed; unexpected=$unexpected}
if ($ResultPath -ne '') {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $ResultPath))
    [IO.File]::WriteAllText($ResultPath,($report | ConvertTo-Json -Depth 8),$utf8)
}
Write-Host ('Cases='+$cases.Count+'; failed='+$failed+'; unexpected='+$unexpected)
if ($unexpected -gt 0) { exit 1 }
exit 0
