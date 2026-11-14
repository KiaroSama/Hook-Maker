# The runner itself, not only its observer, must preserve argv on both hosts.
. $HookLib
. (Join-Path $HooksRoot 'Test-Run-Guard\_commandanalysis.ps1')
$hostChild=(Get-Process -Id $PID).Path
$hostArguments=@('', 'space value', 'quote"value', 'C:\path with space\', ('unicode '+[char]0x0645), "line`nbreak", 'literal &|;')
foreach($runnerHost in @('pwsh','powershell.exe')) {
    $caseRoot=Join-Path $Work ('runner-host-'+$runnerHost)
    New-Item -ItemType Directory -Path $caseRoot -Force|Out-Null
    $fixture=Join-Path $caseRoot 'capture args.ps1'
    $capture=Join-Path $caseRoot 'argv.json'
    $fixtureText="[IO.File]::WriteAllText('"+$capture.Replace("'","''")+"',(ConvertTo-Json -InputObject @(`$args) -Compress),[Text.UTF8Encoding]::new(`$false))`r`nWrite-Output 'Argument capture complete'`r`n"
    [IO.File]::WriteAllText($fixture,$fixtureText,[Text.UTF8Encoding]::new($true,$true))
    $argv=@('-NoProfile','-File',$fixture)+$hostArguments
    $array='@('+((@($argv|ForEach-Object{"'"+$_.Replace("'","''")+"'"})) -join ',')+')'
    foreach($failure in @($false,$true)) {
        $tag=if($failure){'failed'}else{'clean'}
        # No case may reuse a capture emitted by the preceding run.
        if ([IO.File]::Exists($capture)) { [IO.File]::Delete($capture) }
        $receipt=Join-Path $caseRoot ($tag+'.json')
        $wrapper=Join-Path $caseRoot ($tag+'.ps1')
        if($failure){[IO.File]::AppendAllText($fixture,"`r`nexit 7`r`n",[Text.UTF8Encoding]::new($false))}
        $code="`$ErrorActionPreference='Stop'`r`n`$env:LOCALAPPDATA='"+$caseRoot.Replace("'","''")+"'`r`n& '"+$Runner.Replace("'","''")+"' -ProjectFingerprint standalone-host-fixture -FilePath '"+$hostChild.Replace("'","''")+"' -Arguments "+$array+" -WorkingDirectory '"+$caseRoot.Replace("'","''")+"' -TimeoutSeconds 20 -IdleTimeoutSeconds 10 -HeartbeatSeconds 1 -MaxWorkers 1 -ResultPath '"+$receipt.Replace("'","''")+"' -Quiet`r`nexit `$LASTEXITCODE`r`n"
        [IO.File]::WriteAllText($wrapper,$code,[Text.UTF8Encoding]::new($true,$true))
        $program=if($runnerHost -eq 'pwsh'){$hostChild}else{$runnerHost}
        $canaryClock = [Diagnostics.Stopwatch]::StartNew()
        $canaryOutput=Invoke-QuietCommand -FilePath $program -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$wrapper) -TimeoutSeconds 35
        $processExit=$LASTEXITCODE
        $doc=Read-JsonFile $receipt
        $canaryDiagnostic = [ordered]@{
            host = $runnerHost; case = $tag; processExit = $processExit
            elapsedSeconds = $canaryClock.Elapsed.TotalSeconds
            resultExists = [IO.File]::Exists($receipt); captureExists = [IO.File]::Exists($capture)
            result = $doc
        }
        Write-JsonFileAtomic -Path (Join-Path $caseRoot ($tag + '.diagnostics.json')) -Value $canaryDiagnostic
        $diagnosticText = $canaryDiagnostic | ConvertTo-Json -Depth 8 -Compress
        $expectedExit=if($failure){7}else{0}
        $expectedOverall=if($failure){'failed'}else{'ok'}
        Check ($runnerHost+': '+$tag+' result and real exit') ($null -ne $doc -and $doc.overall -eq $expectedOverall -and $doc.exitCode -eq $expectedExit -and $processExit -eq $expectedExit) $diagnosticText
        Check ($runnerHost+': '+$tag+' identity and cleanup') ($null -ne $doc -and $doc.commandFingerprint -eq (Get-CommandFingerprint -ExecutablePath $hostChild -ArgumentList $argv) -and @($doc.leakedProcessIds).Count -eq 0)
        $actual=if(Test-Path -LiteralPath $capture){[IO.File]::ReadAllText($capture,[Text.Encoding]::UTF8)}else{''}
        Check ($runnerHost+': '+$tag+' empty/quotes/backslash/Unicode argv round trip') ($actual -ceq (ConvertTo-Json -InputObject $hostArguments -Compress)) $actual
    }
    # Mutable caller output must not replace the append-only canonical receipts.
    $canonicalFiles = @(Get-ChildItem -LiteralPath $env:HOOKMAKER_STATE_DIR -Filter 'TestRunGuard-result-*.json' -File |
        Where-Object { (Read-JsonFile $_.FullName).workingDirectory -eq $caseRoot })
    Check ($runnerHost+': terminal receipts remain discoverable') ($canonicalFiles.Count -eq 2)
    $failedCanonical = @($canonicalFiles | Where-Object { (Read-JsonFile $_.FullName).exitCode -eq 7 })
    if ($failedCanonical.Count -ne 1) { throw 'Expected one failed canonical fixture receipt.' }
    $originalBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($failedCanonical[0].FullName))
    $originalRun = Read-JsonFile $failedCanonical[0].FullName
    Write-Utf8 $wrapper ($code.Replace(' -Quiet',(" -RunId '"+$originalRun.runId+"' -Quiet")))
    $collisionOutput = Invoke-QuietCommand -FilePath $program -ArgumentList @('-NoProfile','-File',$wrapper) -TimeoutSeconds 35 -CaptureOutput
    Check ($runnerHost+': duplicate run identity preserves original bytes') (
        $collisionOutput.ExitCode -eq 7 -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($failedCanonical[0].FullName)) -ceq $originalBytes -and
        $collisionOutput.ErrorOutput -match 'receipt publication failed') (
        'exit=' + $collisionOutput.ExitCode + '; originalBytesPreserved=' + ([Convert]::ToBase64String([IO.File]::ReadAllBytes($failedCanonical[0].FullName)) -ceq $originalBytes) +
        '; stderr=' + $collisionOutput.ErrorOutput)
    $blockedState = Join-Path $caseRoot 'blocked-state'
    Write-Utf8 $blockedState 'not a directory'
    $blockedWrapper = Join-Path $caseRoot 'blocked-publication.ps1'
    $blockedCode = "`$env:HOOKMAKER_STATE_DIR='"+$blockedState.Replace("'","''")+"'`r`n"+$code
    # Only persistence fails: retain the actual successful child's outcome.
    Write-Utf8 $fixture "Write-Output 'Receipt fixture complete'`r`n"
    Write-Utf8 $blockedWrapper $blockedCode
    $blockedOutput = Invoke-QuietCommand -FilePath $program -ArgumentList @('-NoProfile','-File',$blockedWrapper) -TimeoutSeconds 35 -CaptureOutput
    $blockedExit = $blockedOutput.ExitCode
    $fallback = Read-JsonFile $receipt
    Check ($runnerHost+': storage failure cannot return successful exit') (
        $blockedExit -eq 3 -and $fallback.overall -eq 'ok' -and $fallback.exitCode -eq 0 -and
        $blockedOutput.ErrorOutput -match 'receipt publication failed')
}
