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
        $receipt=Join-Path $caseRoot ($tag+'.json')
        $wrapper=Join-Path $caseRoot ($tag+'.ps1')
        if($failure){[IO.File]::AppendAllText($fixture,"`r`nexit 7`r`n",[Text.UTF8Encoding]::new($false))}
        $code="`$ErrorActionPreference='Stop'`r`n`$env:LOCALAPPDATA='"+$caseRoot.Replace("'","''")+"'`r`n& '"+$Runner.Replace("'","''")+"' -FilePath '"+$hostChild.Replace("'","''")+"' -Arguments "+$array+" -WorkingDirectory '"+$caseRoot.Replace("'","''")+"' -TimeoutSeconds 20 -IdleTimeoutSeconds 10 -HeartbeatSeconds 1 -MaxWorkers 1 -ResultPath '"+$receipt.Replace("'","''")+"' -Quiet`r`nexit `$LASTEXITCODE`r`n"
        [IO.File]::WriteAllText($wrapper,$code,[Text.UTF8Encoding]::new($true,$true))
        $program=if($runnerHost -eq 'pwsh'){$hostChild}else{$runnerHost}
        $null=Invoke-QuietCommand -FilePath $program -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$wrapper) -TimeoutSeconds 35
        $processExit=$LASTEXITCODE
        $doc=Read-JsonFile $receipt
        $expectedExit=if($failure){7}else{0}
        $expectedOverall=if($failure){'failed'}else{'ok'}
        Check ($runnerHost+': '+$tag+' result and real exit') ($null -ne $doc -and $doc.overall -eq $expectedOverall -and $doc.exitCode -eq $expectedExit -and $processExit -eq $expectedExit) ($doc|ConvertTo-Json -Compress)
        Check ($runnerHost+': '+$tag+' identity and cleanup') ($null -ne $doc -and $doc.commandFingerprint -eq (Get-CommandFingerprint -ExecutablePath $hostChild -ArgumentList $argv) -and @($doc.leakedProcessIds).Count -eq 0)
        $actual=if(Test-Path -LiteralPath $capture){[IO.File]::ReadAllText($capture,[Text.Encoding]::UTF8)}else{''}
        Check ($runnerHost+': '+$tag+' empty/quotes/backslash/Unicode argv round trip') ($actual -ceq (ConvertTo-Json -InputObject $hostArguments -Compress)) $actual
    }
}
