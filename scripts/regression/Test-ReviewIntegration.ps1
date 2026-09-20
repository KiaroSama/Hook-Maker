param([string]$ResultPath = '', [string]$SourceRoot = '', [switch]$Baseline,
    [string]$WorkerRoot = '', [int]$Index = 0, [string]$Gate = '', [switch]$Distinct)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ($SourceRoot -eq '') { $SourceRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
. (Join-Path $SourceRoot 'hooks\_hooklib.ps1')
if ($WorkerRoot -ne '') {
    # Execute the real caller's function, not a second implementation of its
    # reservation algorithm. Workers have no child processes of their own.
    try {
        $hookInput = [pscustomobject]@{ cwd=$WorkerRoot; session_id=$(if ($Distinct) { 'actor-'+$Index } else { 'same-actor' }); hook_event_name='Stop' }
        $eventName='Stop'; $stateDir=$WorkerRoot; $gatePath=Join-Path $WorkerRoot 'delivery.txt'
        $functionName=if ($Gate -eq 'Mcp-Usage-Check') { 'Test-ShouldReport' } else { 'Test-ShouldReportClosing' }
        $errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot ('hooks\'+$Gate+'\'+$Gate+'.ps1')), [ref]$null, [ref]$errors)
        if ($errors.Count -gt 0) { throw 'caller parse failed' }
        $definitions=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName}, $true))
        if ($definitions.Count -ne 1) { throw 'caller function is not uniquely defined' }
        . ([scriptblock]::Create($definitions[0].Extent.Text))
        [IO.File]::WriteAllText((Join-Path $WorkerRoot ($Index.ToString()+'.ready')), 'ready')
        $clock=[Diagnostics.Stopwatch]::StartNew()
        while (-not [IO.File]::Exists((Join-Path $WorkerRoot 'release'))) {
            if ($clock.ElapsedMilliseconds -gt 20000) { throw 'worker barrier expired' }
            Start-Sleep -Milliseconds 10
        }
        $admitted = & $functionName 'unverified'
        [IO.File]::WriteAllText((Join-Path $WorkerRoot ($Index.ToString()+'.json')), (@{admitted=[bool]$admitted}|ConvertTo-Json -Compress))
        exit 0
    }
    catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
}
. (Join-Path $SourceRoot 'scripts\_testlib.ps1')
. (Join-Path $PSScriptRoot '_reviewharness.ps1')
$work=New-TestWorkspace -Prefix 'hookmaker-review-integration'
$cases=New-Object System.Collections.Generic.List[object]
$saved=@{}
foreach ($key in @('LOCALAPPDATA','USERPROFILE','HOME','HOOKMAKER_CLIENT','HOOKMAKER_STATE_DIR','CLAUDE_PROJECT_DIR','HOOKMAKER_REVIEW_FAULT')) { $saved[$key]=[Environment]::GetEnvironmentVariable($key) }
function Invoke-DeliveryWorkers {
    param([string]$Name, [string]$HookName, [switch]$DifferentActors)
    $dir=Join-Path $work $Name; [void][IO.Directory]::CreateDirectory($dir)
    $children=New-Object System.Collections.Generic.List[object]
    try {
        foreach ($n in 1..6) {
            $start=New-Object Diagnostics.ProcessStartInfo
            $start.FileName=(Get-Process -Id $PID).Path
            $start.Arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -SourceRoot "'+$SourceRoot+'" -WorkerRoot "'+$dir+'" -Gate '+$HookName+' -Index '+$n+$(if ($DifferentActors) { ' -Distinct' } else { '' })
            $start.UseShellExecute=$false; $start.CreateNoWindow=$true
            $start.RedirectStandardInput=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
            $process=[Diagnostics.Process]::Start($start); $process.StandardInput.Close()
            [void]$children.Add([pscustomobject]@{Process=$process;Out=$process.StandardOutput.ReadToEndAsync();Err=$process.StandardError.ReadToEndAsync()})
        }
        $deadline=[DateTime]::UtcNow.AddSeconds(30)
        while (@(Get-ChildItem -LiteralPath $dir -Filter '*.ready' -File).Count -lt 6) {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'worker readiness deadline exceeded' }
            foreach ($child in $children) { if ($child.Process.HasExited) { throw ('worker stopped before release: '+$child.Err.Result) } }
            Start-Sleep -Milliseconds 10
        }
        [IO.File]::WriteAllText((Join-Path $dir 'release'),'release')
        foreach ($child in $children) {
            $remaining=[int][Math]::Max(1,($deadline-[DateTime]::UtcNow).TotalMilliseconds)
            if (-not $child.Process.WaitForExit($remaining)) { throw 'worker exit deadline exceeded' }
            if (-not $child.Out.Wait(2000) -or -not $child.Err.Wait(2000)) { throw 'worker pipe deadline exceeded' }
            if ($child.Process.ExitCode -ne 0 -or $child.Err.Result.Trim() -ne '') { throw ('worker failed: '+$child.Err.Result) }
        }
        $result=@()
        foreach ($n in 1..6) { $result += ([IO.File]::ReadAllText((Join-Path $dir ($n.ToString()+'.json'))) | ConvertFrom-Json) }
        return $result
    }
    finally {
        foreach ($child in $children) {
            if (-not $child.Process.HasExited) { $child.Process.Kill(); if (-not $child.Process.WaitForExit(5000)) { throw 'owned worker cleanup not proven' } }
            $child.Process.Dispose()
        }
    }
}
function Invoke-InstallScenario {
    param([string]$Target,[string]$Hook,[string]$Fault='',[string[]]$Selected=@('claude'))
    $env:HOOKMAKER_REVIEW_FAULT=$Fault
    [void][IO.Directory]::CreateDirectory($Target)
    $receipt=Join-Path $Target 'install-result.json'; $caught=''
    try { $null = & (Join-Path $tool 'scripts\Install-Hook.ps1') -TargetProject $Target -CustomHook $Hook -Clients $Selected -ResultPath $receipt *>&1 }
    catch { $caught=$_.Exception.Message }
    $doc=$null
    if ([IO.File]::Exists($receipt)) { $doc=[IO.File]::ReadAllText($receipt)|ConvertFrom-Json }
    return [pscustomobject]@{Document=$doc;Error=$caught}
}
try {
    $env:LOCALAPPDATA=Join-Path $work 'local'; $env:USERPROFILE=Join-Path $work 'home'; $env:HOME=$env:USERPROFILE
    $env:HOOKMAKER_CLIENT='codex'; $env:CLAUDE_PROJECT_DIR=''; $env:HOOKMAKER_STATE_DIR=Join-Path $work 'state'
    [void][IO.Directory]::CreateDirectory($env:USERPROFILE)
    . (Join-Path $SourceRoot 'hooks\_hooklib.ps1')
    if (-not $Baseline) {
        foreach ($name in @('Mcp-Usage-Check','Rules-Check','Skills-Check')) {
            $same=@(Invoke-DeliveryWorkers -Name ($name+'-same') -HookName $name)
            Check-Contract ('D05 '+$name+' six concurrent same-identity callers reserve exactly once') { @($same|Where-Object admitted).Count -eq 1 }
            $different=@(Invoke-DeliveryWorkers -Name ($name+'-different') -HookName $name -DifferentActors)
            Check-Contract ('D06 '+$name+' six distinct concurrent actors all retain their reservation') { @($different|Where-Object admitted).Count -eq 6 }
            $path=Join-Path $work ($name+'-different\delivery.txt.claims.json')
            $stored=[IO.File]::ReadAllText($path)|ConvertFrom-Json
            Check-Contract ('D07 '+$name+' persisted map contains all six actors') { @($stored.entries.PSObject.Properties).Count -eq 6 }
        }
        $path=Join-Path $work 'claim-fault.json'
        $first=Invoke-DeliveryClaim -Path $path -Identity 'owned-actor' -Fingerprint 'old'
        Check-Contract 'D08 first persistent reservation succeeds' { $first.Ok -and $first.Admitted }
        $before=[IO.File]::ReadAllText($path)
        $lock=[IO.File]::Open(($path+'.lock'),'Open','ReadWrite','None')
        try {
            $blocked=Invoke-DeliveryClaim -Path $path -Identity 'owned-actor' -Fingerprint 'new'
            Check-Contract 'D09 held reservation lock refuses without claiming or changing state' { -not $blocked.Ok -and -not $blocked.Admitted -and $blocked.Reason -eq 'busy' -and [IO.File]::ReadAllText($path) -ceq $before }
        }
        finally { $lock.Dispose() }
        # Shared reading succeeds, but replacing this open file must fail: this
        # exercises the real publication failure, not only a lock/read failure.
        $held=[IO.File]::Open($path,'Open','Read','Read')
        try {
            $blocked=Invoke-DeliveryClaim -Path $path -Identity 'owned-actor' -Fingerprint 'new'
            Check-Contract 'D10 real replacement failure preserves prior bytes and refuses admission' { -not $blocked.Ok -and -not $blocked.Admitted -and [IO.File]::ReadAllText($path) -ceq $before }
        }
        finally { $held.Dispose() }
        Check-Contract 'D11 an unlocked retry reserves the changed evidence' { (Invoke-DeliveryClaim -Path $path -Identity 'owned-actor' -Fingerprint 'new').Admitted }
        Check-Contract 'D12 an unchanged retry is suppressed' { -not (Invoke-DeliveryClaim -Path $path -Identity 'owned-actor' -Fingerprint 'new').Admitted }
        Check-Contract 'D13 failed publication leaves no disposable temporary file' { @(Get-ChildItem -LiteralPath $work -Filter 'claim-fault.json.*.tmp').Count -eq 0 }
        $probe=[IO.File]::Open(($path+'.lock'),'Open','ReadWrite','None'); $probe.Dispose()
        Check-Contract 'D14 stable lock remains exclusively reacquirable' { $true }
        $document=[pscustomobject]@{schema=1;entries=[pscustomobject]@{}}
        $now=[string][DateTime]::UtcNow.Ticks
        foreach ($n in 1..1024) {
            Set-ObjectProperty $document.entries (Get-DeliveryHash ('actor-'+$n)) ([pscustomobject]@{fingerprint=(Get-DeliveryHash 'seed');reservedTicks=$now;expiresTicks='0'})
        }
        Put-ReviewText $path ($document|ConvertTo-Json -Depth 7 -Compress);$before=[IO.File]::ReadAllText($path)
        $full=Invoke-DeliveryClaim -Path $path -Identity 'another-actor' -Fingerprint 'new'
        Check-Contract 'D15 capacity refusal never evicts an unexpired persistent actor' { -not $full.Ok -and $full.Reason -eq 'capacity' -and [IO.File]::ReadAllText($path) -ceq $before }
        Check-Contract 'D16 an existing actor can update even at map capacity' { (Invoke-DeliveryClaim -Path $path -Identity 'actor-1' -Fingerprint 'changed').Admitted }
        Put-ReviewText $path '{"schema":99,"entries":{}}';$before=[IO.File]::ReadAllText($path)
        Check-Contract 'D17 future reservation state is preserved, never reset' { -not (Invoke-DeliveryClaim -Path $path -Identity 'actor' -Fingerprint 'x').Ok -and [IO.File]::ReadAllText($path) -ceq $before }
        Put-ReviewText $path '{broken';$before=[IO.File]::ReadAllText($path)
        Check-Contract 'D18 corrupt reservation state is preserved, never reset' { -not (Invoke-DeliveryClaim -Path $path -Identity 'actor' -Fingerprint 'x').Ok -and [IO.File]::ReadAllText($path) -ceq $before }
        $timePath=Join-Path $work 'timed-claim.json'
        $null=Invoke-DeliveryClaim -Path $timePath -Identity 'actor' -Fingerprint 'note' -CooldownMinutes 15
        Check-Contract 'D19 a timed note is suppressed within the window' { -not (Invoke-DeliveryClaim -Path $timePath -Identity 'actor' -Fingerprint 'note' -CooldownMinutes 15).Admitted }
        Check-Contract 'D20 explicit SessionStart force still reserves rebuilt context' { (Invoke-DeliveryClaim -Path $timePath -Identity 'actor' -Fingerprint 'note' -CooldownMinutes 15 -Force).Admitted }
        Check-Contract 'D21 cooldown zero really disables repeat suppression' { (Invoke-DeliveryClaim -Path $timePath -Identity 'actor' -Fingerprint 'note' -CooldownMinutes 0).Admitted }
        Check-Contract 'D22 absent identity refuses instead of sharing an anonymous actor slot' { -not (Invoke-DeliveryClaim -Path $timePath -Identity '' -Fingerprint 'note').Ok }
    }
    # Preserve the producer's real control flow. The injected fault exists only
    # in this owned checkout and makes its actual settings writer lie or changes
    # materialized bytes after staging, immediately before the readback boundary.
    $tool=Join-Path $work 'tool';[void][IO.Directory]::CreateDirectory($tool)
    Copy-Item -LiteralPath (Join-Path $SourceRoot 'hooks') -Destination $tool -Recurse
    Copy-Item -LiteralPath (Join-Path $SourceRoot 'scripts') -Destination $tool -Recurse
    $installer=Join-Path $tool 'scripts\Install-Hook.ps1'
    $source=[IO.File]::ReadAllText($installer)
    $needle=". (Join-Path `$PSScriptRoot '_installnativegit.ps1')"
    if (($source.Split(@($needle),[StringSplitOptions]::None)).Count -ne 2) { throw 'installer fault seam is not unique' }
    $seam=@'
$script:ReviewOriginalWriter = ${function:Write-JsonFile}
function Write-JsonFile {
    param($Value,[string]$Path)
    if ($env:HOOKMAKER_REVIEW_FAULT -eq 'missing-write') { return }
    & $script:ReviewOriginalWriter -Value $Value -Path $Path
    if ($env:HOOKMAKER_REVIEW_FAULT -eq 'corrupt-runtime') {
        $base=Join-Path (Split-Path -Parent $Path) 'hooks\Hook-Maker'
        $entry=@(Get-ChildItem -LiteralPath $base -Recurse -File -Filter '*.ps1' | Where-Object { $_.Name -notlike '_*' })[0]
        [IO.File]::WriteAllText($entry.FullName,'changed after staging')
    }
}
'@
    Put-ReviewText $installer ($source.Replace($needle,($needle+"`n"+$seam)))
    $probe=Join-Path $work 'SourceProbe.ps1';Put-ReviewText $probe '# A harmless standalone fixture.'
    $normal=Invoke-InstallScenario -Target (Join-Path $work 'normal') -Hook $probe -Selected @('claude','codex')
    Check-Contract 'I05 real two-client install remains fully successful' { $normal.Error -eq '' -and $null -ne $normal.Document -and $normal.Document.overall -eq 'ok' }
    foreach ($fault in @('missing-write','corrupt-runtime')) {
        $outcome=Invoke-InstallScenario -Target (Join-Path $work $fault) -Hook $probe -Fault $fault
        Check-Contract ('I06 real installer refuses false client success after '+$fault) {
            $null -ne $outcome.Document -and $outcome.Document.overall -ne 'ok' -and
            @($outcome.Document.components|Where-Object {$_.component -eq 'claude' -and $_.status -eq 'failed'}).Count -eq 1
        } $true
    }
    $env:HOOKMAKER_REVIEW_FAULT=''
    $nativeProject=Join-Path $work 'native-project';[void][IO.Directory]::CreateDirectory($nativeProject)
    $null=& git init $nativeProject 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'native fixture repository creation failed' }
    Put-ReviewText (Join-Path $nativeProject '.git\hooks\pre-push') "#!/bin/sh`nexit 0`n"
    $nativeHook=Join-Path $tool 'hooks\Ignore-Rules-Check\Ignore-Rules-Check.ps1'
    $installed=Invoke-InstallScenario -Target $nativeProject -Hook $nativeHook
    Check-Contract 'I07 genuine native chain passes readback' { $installed.Error -eq '' -and $installed.Document.overall -eq 'ok' }
    [IO.File]::Delete((Join-Path $nativeProject '.git\hooks\pre-push.hookmaker-existing'))
    $repaired=Invoke-InstallScenario -Target $nativeProject -Hook $nativeHook
    Check-Contract 'I08 missing preserved user hook is not reported as nativeGit success' {
        $null -ne $repaired.Document -and $repaired.Document.overall -ne 'ok' -and
        @($repaired.Document.components|Where-Object {$_.component -eq 'nativeGit' -and $_.status -eq 'failed'}).Count -eq 1
    } $true
    # Invoke the actual canonical result setter independently of the installer
    # entry point, so its uniqueness invariant has a positive and a replacement.
    $errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($installer,[ref]$null,[ref]$errors)
    $setter=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Set-ComponentResult'},$true))[0]
    . ([scriptblock]::Create($setter.Extent.Text))
    $script:ComponentResults=New-Object System.Collections.Generic.List[object]
    Set-ComponentResult -Component 'claude' -Status 'ok'
    Set-ComponentResult -Component 'CLAUDE' -Status 'failed' -ReasonCode 'verificationFailed'
    Check-Contract 'I09 producer replaces a component outcome rather than emitting duplicates' { $script:ComponentResults.Count -eq 1 -and $script:ComponentResults[0].status -eq 'failed' } $true
    if (-not $Baseline) {
        $summaryHook=Join-Path $tool 'hooks\Session-Summary-Check\Session-Summary-Check.ps1'
        $target=Join-Path $work 'installed-summary';$outcome=Invoke-InstallScenario -Target $target -Hook $summaryHook
        Check-Contract 'I10 the summary hook installs with its new shared dependency' { $outcome.Document.overall -eq 'ok' }
        $entry=Join-Path $target '.claude\hooks\Hook-Maker\Session-Summary-Check\Session-Summary-Check.ps1'
        $library=Join-Path (Split-Path -Parent $entry) '_deliverylib.ps1'
        Check-Contract 'I11 planned delivery library is byte-identical in installed runtime' { [IO.File]::Exists($library) -and (Get-FileHash $library).Hash -ceq (Get-FileHash (Join-Path $tool 'hooks\_deliverylib.ps1')).Hash }
        $payload=[pscustomobject]@{cwd=$target;session_id='installed';hook_event_name='UserPromptSubmit'}
        $wire=Invoke-ReviewHook $entry $payload 'claude'
        Check-Contract 'I12 installed runtime actually emits first reminder with no stderr' { $wire.Exit -eq 0 -and $wire.Err -eq '' -and $wire.Out -match 'CLOSING section' }
        $wire=Invoke-ReviewHook $entry $payload 'claude'
        Check-Contract 'I13 installed runtime suppresses the repeated reminder' { $wire.Exit -eq 0 -and $wire.Err -eq '' -and $wire.Out -eq '' }
    }
}
catch { $failure=$_.Exception.Message;Check-Contract 'HARNESS no unhandled integration exception' {throw $failure} }
finally {
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key,$saved[$key]) }
    $clean=Remove-TestWorkspace -Path $work
    Check-Contract 'HARNESS all integration files and workers released' {$clean -and -not [IO.Directory]::Exists($work)}
}
$unexpected=@($cases|Where-Object {-not $_.matched}).Count
$failed=@($cases|Where-Object {-not $_.passed}).Count
if ($ResultPath -ne '') {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $ResultPath))
    $report=[ordered]@{schema=1;hostVersion=$PSVersionTable.PSVersion.ToString();baseline=[bool]$Baseline;cases=$cases.ToArray();failed=$failed;unexpected=$unexpected}
    [IO.File]::WriteAllText($ResultPath,($report|ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($false)))
}
Write-Host ('Cases: '+$cases.Count+'; actual failures: '+$failed+'; unexpected outcomes: '+$unexpected)
if ($unexpected -gt 0) {exit 1};exit 0
