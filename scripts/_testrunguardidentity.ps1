# Identity parsing reads command text as data, including literals that would be
# executable if evaluated. Run each observer shape on both supported hosts.
. $HookLib
. (Join-Path (Split-Path -Parent $Hook) '_commandanalysis.ps1')
$unicodeArgument = 'path with space\' + [char]0x0645 + '\apply_approved.py'
$literalArray = "@('-B','-X','utf8','" + $unicodeArgument + "','--check')"
$marker = Join-Path $Work 'identity-must-not-execute.txt'
$dynamicArgument = "@((New-Item -ItemType File -Path '" + $marker.Replace("'", "''") + "'))"
$cases = @(
    @{Name='empty literal array'; Source='-Arguments @()'; Expected=@()},
    @{Name='single literal array'; Source="-Arguments @('-q')"; Expected=@('-q')},
    @{Name='original five-argument shape with Unicode'; Source=('-Arguments ' + $literalArray); Expected=@('-B','-X','utf8',$unicodeArgument,'--check')},
    @{Name='single scalar literal'; Source="-Arguments 'one argument'"; Expected=@('one argument')},
    @{Name='quotes and shell punctuation remain literal'; Source='-Arguments @(''quote''''arg'',''literal$()'',''semi;| &'')'; Expected=@("quote'arg",'literal$()','semi;| &')},
    @{Name='literal array statements'; Source="-Arguments @('one'; 'two')"; Expected=@('one','two')},
    @{Name='JSON single element'; Source='-ArgumentsJson ''["one"]'''; Expected=@('one')},
    @{Name='JSON empty array'; Source='-ArgumentsJson ''[]'''; Expected=@()},
    @{Name='JSON primitives'; Source='-ArgumentsJson ''[true,1,1.5,null,""]'''; Expected=@([string]$true,[string]1,[string]1.5,'','')},
    @{Name='JSON takes precedence'; Source='-Arguments @(''ignored'') -ArgumentsJson ''["kept"]'''; Expected=@('kept')},
    @{Name='empty JSON falls back to literal arguments'; Source='-Arguments @(''kept'') -ArgumentsJson '''''; Expected=@('kept')},
    @{Name='argument values cannot become runner parameters'; Source='-Arguments @(''-FilePath'',''wrong.exe'',''-RunId'',''wrong'')'; Expected=@('-FilePath','wrong.exe','-RunId','wrong')},
    @{Name='abbreviated JSON parameter has no fabricated argv'; Source='-ArgumentsJ ''["-m","pytest"]'''; Unknown=$true},
    @{Name='abbreviated argument array has no fabricated argv'; Source='-Argument @(''-m'',''pytest'')'; Unknown=$true},
    @{Name='dynamic array'; Source='-Arguments $values'; Unknown=$true},
    @{Name='nested multi-value arrays are not flattened into argv'; Source='-Arguments @(@(''a'',''b''),@(''c'',''d''))'; Unknown=$true},
    @{Name='interpolated string'; Source='-Arguments @("$value")'; Unknown=$true},
    @{Name='command expression is not evaluated'; Source=('-Arguments ' + $dynamicArgument); Unknown=$true},
    @{Name='malformed JSON does not become empty argv'; Source='-ArgumentsJson ''not-json'''; Unknown=$true},
    @{Name='JSON scalar is invalid'; Source='-ArgumentsJson ''"one"'''; Unknown=$true},
    @{Name='JSON object is invalid'; Source='-ArgumentsJson ''{"a":1}'''; Unknown=$true},
    @{Name='JSON object element is invalid'; Source='-ArgumentsJson ''[{"a":1}]'''; Unknown=$true},
    @{Name='dynamic JSON cannot fall back to arguments'; Source='-Arguments @(''ignored'') -ArgumentsJson $json'; Unknown=$true}
)
foreach ($observerHost in @('pwsh', 'powershell.exe')) {
    Write-Host ('--- literal invocation identity: ' + $observerHost + ' ---') -ForegroundColor Cyan
    foreach ($case in $cases) {
        $copy = New-IsolatedHookCopy
        $command = '& .\scripts\Run-Tests-Guarded.ps1 -FilePath python.exe ' + $case.Source + ' -RunId literal-case'
        $response = Fire -HookPath $copy.Script -Cwd $Proj -EventName 'PreToolUse' -Command $command -LocalAppData $copy.LocalAppData -Exe $observerHost
        $observed = Get-ObservedRecord $copy.LocalAppData
        if ($case.ContainsKey('Unknown')) {
            Check ($observerHost + ': ' + $case.Name) (
                $response.Exit -eq 0 -and $null -eq $observed -and (Get-Message $response.Out) -match 'identity') $response.Out
        }
        else {
            $expected = Get-CommandFingerprint -ExecutablePath 'python.exe' -ArgumentList @($case.Expected)
            Check ($observerHost + ': ' + $case.Name) (
                $response.Exit -eq 0 -and $null -ne $observed -and $observed.Document.commandFingerprint -eq $expected) $response.Err
        }
    }
    Check ($observerHost + ': parsing never executes the embedded command') (-not (Test-Path -LiteralPath $marker))

    # No literal run id or argv identity: an unrelated fresh result must never
    # be accepted through the legacy "newest result" fallback.
    $unknownCopy = New-IsolatedHookCopy
    $unknownCommand = '& .\scripts\Run-Tests-Guarded.ps1 -FilePath python.exe -Arguments $values'
    $null = Fire -HookPath $unknownCopy.Script -Cwd $Proj -EventName 'PreToolUse' -Command $unknownCommand -LocalAppData $unknownCopy.LocalAppData -Exe $observerHost
    $null = New-ResultDocument -LocalAppData $unknownCopy.LocalAppData -ProjectRoot $Proj -Fields @{
        commandFingerprint=(Get-CommandFingerprint -ExecutablePath 'python.exe' -ArgumentList @('unrelated')); overall='ok'; exitCode=0
    }
    $response = Fire -HookPath $unknownCopy.Script -Cwd $Proj -EventName 'PostToolUse' -Command $unknownCommand -LocalAppData $unknownCopy.LocalAppData -Exe $observerHost
    Check ($observerHost + ': dynamic identity cannot accept an unrelated fresh success') ((Get-Message $response.Out) -match 'NO evidence') $response.Out
}

Write-Host '--- literal argv: observer and real guarded runner agree end to end ---' -ForegroundColor Cyan
foreach ($observerHost in @('pwsh', 'powershell.exe')) {
    $copy = New-IsolatedHookCopy
    # Exercise both observer hosts against the pwsh runner; observer and
    # runner host compatibility are separate contracts.
    $hostExe = (Get-Process -Id $PID).Path
    $caseTag = if ($observerHost -eq 'pwsh') {'ps7'} else {'ps5'}
    $fixture = Join-Path $Work ('check ' + [char]0x0645 + '.ps1')
    Write-Utf8 $fixture "param([switch]`$Check)`nif (-not `$Check) { exit 3 }`nWrite-Output 'Passed: 1 Failed: 0'`n"
    $stateFp = Get-RepoStateFingerprint -ProjectRoot $Proj
    if ([string]::IsNullOrWhiteSpace($stateFp)) { $stateFp = Get-ShortHash $Proj.ToLowerInvariant() }
    $runId = 'literalarray' + $caseTag
    $projectKey = Get-ShortHash $Proj.ToLowerInvariant()
    $resultPath = Join-Path $copy.LocalAppData ('HookMaker\state\TestRunGuard-result-' + $projectKey + '-' + $runId + '.json')
    $inner = @('-NoLogo','-NoProfile','-File',$fixture,'-Check')
    $arrayText = '@(' + ((@($inner | ForEach-Object { "'" + $_.Replace("'", "''") + "'" })) -join ',') + ')'
    $command = "& '" + $Runner.Replace("'", "''") + "' -FilePath '" + $hostExe.Replace("'", "''") + "' -Arguments " + $arrayText +
        " -RunId " + $runId + " -ProjectFingerprint " + $stateFp + " -WorkingDirectory '" + $Proj.Replace("'", "''") +
        "' -TimeoutSeconds 20 -IdleTimeoutSeconds 10 -HeartbeatSeconds 1 -MaxWorkers 1 -ResultPath '" + $resultPath.Replace("'", "''") + "' -Quiet"
    $null = Fire -HookPath $copy.Script -Cwd $Proj -EventName 'PreToolUse' -Command $command -LocalAppData $copy.LocalAppData -Exe $observerHost
    $observed = Get-ObservedRecord $copy.LocalAppData
    $wrapper = Join-Path $Work ('run-literal-' + $caseTag + '.ps1')
    [System.IO.File]::WriteAllText($wrapper, ($command + "`nexit `$LASTEXITCODE`n"), [System.Text.UTF8Encoding]::new($true, $true))
    $savedLocal = $env:LOCALAPPDATA
    try {
        $env:LOCALAPPDATA = $copy.LocalAppData
        $null = Invoke-QuietCommand -FilePath $hostExe -ArgumentList @('-NoLogo','-NoProfile','-File',$wrapper) -TimeoutSeconds 40
        $runnerExit = $LASTEXITCODE
    }
    finally { $env:LOCALAPPDATA = $savedLocal }
    $actual = Read-JsonFile $resultPath
    Check ($observerHost + ' observer: pwsh runner completed with no leaked process') (
        $runnerExit -eq 0 -and $null -ne $actual -and $actual.overall -eq 'ok' -and @($actual.leakedProcessIds).Count -eq 0) (
        'wrapper exit=' + $runnerExit + '; result=' + ($actual | ConvertTo-Json -Depth 8 -Compress))
    Check ($observerHost + ': observer fingerprint equals the real five-argument runner fingerprint') (
        $null -ne $actual -and $null -ne $observed -and $observed.Document.commandFingerprint -eq $actual.commandFingerprint)
    $response = Fire -HookPath $copy.Script -Cwd $Proj -EventName 'PostToolUse' -Command $command -LocalAppData $copy.LocalAppData -Exe $observerHost
    Check ($observerHost + ': matching real result produces no identity advisory') ($response.Exit -eq 0 -and $response.Out -eq '') $response.Out

    foreach ($negative in @('failure','leak','stale','incomplete')) {
        $changed = $actual | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        if ($negative -eq 'failure') { $changed.overall='failed'; $changed.exitCode=7 }
        if ($negative -eq 'leak') { $changed.leakedProcessIds=@(424242) }
        if ($negative -eq 'incomplete') { $changed.PSObject.Properties.Remove('endedUtc') }
        Write-Utf8 $resultPath ($changed | ConvertTo-Json -Depth 8)
        if ($negative -eq 'stale') { [System.IO.File]::SetLastWriteTimeUtc($resultPath, [DateTime]::UtcNow.AddHours(-2)) }
        $response = Fire -HookPath $copy.Script -Cwd $Proj -EventName 'PostToolUse' -Command $command -LocalAppData $copy.LocalAppData -Exe $observerHost
        $expectedMessage = switch ($negative) {failure {'did NOT pass'} leak {'PROCESS LEAK'} default {'NO evidence'}}
        Check ($observerHost + ': literal argv still rejects ' + $negative + ' evidence') ((Get-Message $response.Out) -match $expectedMessage) $response.Out
    }
}
