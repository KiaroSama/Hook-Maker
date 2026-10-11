param([switch]$SmokeOnly)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_testlib.ps1')
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'hooks/_hooklib.ps1')
$script:Pass = 0; $script:Fail = 0
$saved = @{}
foreach ($name in @('HOOKMAKER_LOG_DIR','HOOKMAKER_STATE_DIR','HOOKMAKER_CALLER_ORIGIN','GIT_CEILING_DIRECTORIES')) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name)
}
$work = New-TestWorkspace -Prefix 'hookmaker-managementaudit'
$script:AuditTestIndex = 0
function Invoke-AuditCommand {
    param([string]$Script,[string[]]$Arguments = @(),[string[]]$Answers = @(),[string]$HostName = 'pwsh')
    $script:AuditTestIndex++
    $prefix = Join-Path $work ('run-' + $script:AuditTestIndex)
    Write-Utf8 ($prefix + '.in') (($Answers -join "`r`n") + "`r`n")
    $p = Start-BoundedProcess -FilePath $HostName -ArgumentList (@('-NoLogo','-NoProfile','-File',(Join-Path $tool ('scripts/' + $Script))) + $Arguments) -WorkingDirectory $work -Wait -NoNewWindow -TimeoutMs 60000 -RedirectStandardInput ($prefix + '.in') -RedirectStandardOutput ($prefix + '.out') -RedirectStandardError ($prefix + '.err')
    try { return @{ Exit = $p.ExitCode; Out = [IO.File]::ReadAllText(($prefix + '.out'),[Text.Encoding]::UTF8); Err = [IO.File]::ReadAllText(($prefix + '.err'),[Text.Encoding]::UTF8) } }
    finally { $p.Dispose() }
}
function Get-AuditEvents {
    param([string]$Pattern = '*.log')
    $events = @()
    foreach ($log in @(Get-ChildItem -LiteralPath $env:HOOKMAKER_LOG_DIR -Filter $Pattern -File -ErrorAction SilentlyContinue)) {
        foreach ($line in [IO.File]::ReadAllLines($log.FullName,[Text.UTF8Encoding]::new($false,$true))) {
            $marker = $line.IndexOf('[AUDIT] ')
            if ($marker -ge 0) { $events += ($line.Substring($marker + 8) | ConvertFrom-Json) }
        }
    }
    return $events
}
function Write-AuditGroupFixture {
    param([string]$Path,[string[]]$Roots)
    $profiles = @()
    foreach ($pair in @(@(0,1),@(2,3))) {
        $routes = @()
        foreach ($direction in @(@($pair[0],$pair[1]),@($pair[1],$pair[0]))) {
            $routes += @{ id = 'r-' + $direction[0] + '-' + $direction[1]; enabled = $true; source = @{name=('P'+$direction[0]);root=$Roots[$direction[0]];directory='.ai'}; destination = @{name=('P'+$direction[1]);root=$Roots[$direction[1]];directory='.ai'} }
        }
        $profiles += @{ id = $(if ($pair[0] -eq 0) {'sync-group-aaa'} else {'sync-group-bbb'}); name = 'Fixture'; enabled = $true; routes = $routes }
    }
    Write-Utf8 $Path (@{ version = 2; profiles = $profiles } | ConvertTo-Json -Depth 12)
}
try {
    $tool = New-ToolRootCopy -Destination (Join-Path $work 'tool')
    $env:HOOKMAKER_LOG_DIR = Join-Path $work 'logs'
    $env:HOOKMAKER_STATE_DIR = Join-Path $work 'state'
    $env:HOOKMAKER_CALLER_ORIGIN = 'claude'
    $config = Join-Path $work 'config.json'
    Write-Utf8 $config '{"version":2,"profiles":[]}'
    $r = Invoke-AuditCommand 'Setup-SyncGroup.ps1' @('-ConfigPath',$config,'-NoInstall') @('exit')
    $execution = @(Get-AuditEvents 'Setup-SyncGroup_*.log' | Where-Object event -eq 'execution')
    Check 'actual wizard logs execution identity without attributing a human' ($r.Exit -eq 0 -and $execution.Count -eq 1 -and $execution[0].runId -match '^[a-f0-9]{32}$' -and $execution[0].data.identity.accountState -in @('observed','unknown') -and $execution[0].data.identity.originTrust -eq 'unverified')
    if (-not $SmokeOnly) {
        Check 'observed account is independent of unverified origin claim' ($execution[0].data.identity.accountState -eq 'observed' -and $execution[0].data.identity.account -ne 'unknown' -and $execution[0].data.identity.processId -gt 0 -and $execution[0].data.identity.originClaim -eq 'claude' -and $execution[0].data.identity.origin -eq 'unknown')
        $env:HOOKMAKER_CALLER_ORIGIN = "credential-marker`r`nforged"
        $r = Invoke-AuditCommand 'Setup-SyncGroup.ps1' @('-ConfigPath',$config,'-NoInstall') @('credential-marker','exit') 'powershell.exe'
        $events = @(Get-AuditEvents 'Setup-SyncGroup_*.log' | Where-Object event -eq 'execution')
        $rawLogs = @(Get-ChildItem -LiteralPath $env:HOOKMAKER_LOG_DIR -File | ForEach-Object { [IO.File]::ReadAllText($_.FullName,[Text.Encoding]::UTF8) }) -join "`n"
        Check 'raw wizard input and invalid origin values never reach log files' ($rawLogs -notmatch 'credential-marker|forged')
        Check 'PS5.1 keeps invalid origin unknown and creates a distinct run' ($r.Exit -eq 0 -and $events.Count -eq 2 -and @($events | Select-Object -ExpandProperty runId -Unique).Count -eq 2 -and @($events | Where-Object {$_.data.identity.originClaim -eq 'unknown'}).Count -eq 1 -and ($events | ConvertTo-Json -Depth 12) -notmatch 'credential-marker|forged')
        $roots = @(0..3 | ForEach-Object { $path=Join-Path $work ('Member ' + $_);[void][IO.Directory]::CreateDirectory((Join-Path $path '.ai'));$path })
        Write-AuditGroupFixture $config $roots
        $r = Invoke-AuditCommand 'Setup-SyncGroup.ps1' @('-ConfigPath',$config,'-NoInstall') (@('1','1','2') + $roots + @('done','','1','','0'))
        $transitions = @(Get-AuditEvents 'Setup-SyncGroup_*.log' | Where-Object event -eq 'profile-transition')
        $commit = @($transitions | Where-Object {$_.data.phase -eq 'committed'})
        Check 'actual merge logs both original IDs and exact removed profile' ($r.Exit -eq 0 -and $commit.Count -eq 1 -and $commit[0].data.retainedProfileId -eq 'sync-group-aaa' -and @($commit[0].data.removedProfileIds).Count -eq 1 -and $commit[0].data.removedProfileIds[0] -eq 'sync-group-bbb' -and @($commit[0].data.before).Count -eq 2 -and @($commit[0].data.after.members).Count -eq 4)
        Check 'planned and committed merge share operation identity' ($transitions.Count -eq 2 -and $transitions[0].data.phase -eq 'planned' -and $transitions[0].data.operationId -eq $commit[0].data.operationId)
        $before = [IO.File]::ReadAllText($config,[Text.Encoding]::UTF8)
        $r = Invoke-AuditCommand 'Setup-SyncGroup.ps1' @('-ConfigPath',$config,'-NoInstall') (@('1','1','2') + $roots + @('done','1','n','0'))
        $cancel = @(Get-AuditEvents 'Setup-SyncGroup_*.log' | Where-Object {$_.event -eq 'profile-transition' -and $_.data.phase -eq 'canceled'})
        Check 'declined merge logs cancellation and preserves config' ($r.Exit -eq 0 -and $cancel.Count -eq 1 -and [IO.File]::ReadAllText($config,[Text.Encoding]::UTF8) -ceq $before)
        $missingConfig = Join-Path $work 'missing-profiles.json'
        Write-Utf8 $missingConfig '{"version":2}'
        $r = Invoke-AuditCommand 'Setup-SyncGroup.ps1' @('-ConfigPath',$missingConfig,'-NoInstall') @('1','1','2',$roots[0],$roots[1],'done','1','','0')
        Check 'audit preserves wizard recovery for a config without profiles' ($r.Exit -eq 0 -and @(([IO.File]::ReadAllText($missingConfig,[Text.Encoding]::UTF8) | ConvertFrom-Json).profiles).Count -eq 1)
        $partialConfig = Join-Path $work 'partial-profile.json'
        Write-AuditGroupFixture $partialConfig $roots
        $partialDoc = [IO.File]::ReadAllText($partialConfig,[Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($route in $partialDoc.profiles[0].routes) { $route.source.PSObject.Properties.Remove('name') }
        Write-Utf8 $partialConfig ($partialDoc | ConvertTo-Json -Depth 12)
        $r = Invoke-AuditCommand 'Setup-SyncGroup.ps1' @('-ConfigPath',$partialConfig,'-NoInstall') (@('1','1','2') + $roots + @('done','','1','','0'))
        $partial = @(Get-AuditEvents 'Setup-SyncGroup_*.log' | Where-Object {$_.event -eq 'profile-transition' -and $_.data.phase -eq 'committed'} | ForEach-Object {$_.data.before} | Where-Object {$_.id -eq 'sync-group-aaa' -and $_.state -eq 'partial'})
        Check 'partial member metadata retains observed profile IDs and roots' ($r.Exit -eq 0 -and $partial.Count -eq 1 -and @($partial[0].members).Count -eq 2)
        $target = Join-Path $work ('Target ' + [char]0x062f)
        [void][IO.Directory]::CreateDirectory($target)
        $hook = Join-Path $tool 'hooks/Ai-Memory-Load/Ai-Memory-Load.ps1'
        $result = Join-Path $work 'install.json'
        $r = Invoke-AuditCommand 'Install-Hook.ps1' @('-CustomHook',$hook,'-TargetProject',$target,'-ClaudeOnly','-ResultPath',$result)
        $doc = [IO.File]::ReadAllText($result,[Text.Encoding]::UTF8) | ConvertFrom-Json
        $targetEvents = @(Get-AuditEvents 'Install-Hook_*.log' | Where-Object event -eq 'install-target')
        Check 'real install keeps result schema and logs target/record identity' ($r.Exit -eq 0 -and $doc.schema -eq 1 -and $doc.overall -eq 'ok' -and $targetEvents.Count -eq 1 -and $targetEvents[0].data.target -eq $target -and $targetEvents[0].data.recordId -ne '')
        $recordId = [string]$targetEvents[0].data.recordId
        $registryPath = Join-Path $env:HOOKMAKER_STATE_DIR ('install-registry.d/' + $recordId + '.json')
        $record = [IO.File]::ReadAllText($registryPath,[Text.Encoding]::UTF8) | ConvertFrom-Json
        $record.PSObject.Properties.Remove('profile')
        Write-Utf8 $registryPath ($record | ConvertTo-Json -Depth 30)
        $r = Invoke-AuditCommand 'Update-Fleet.ps1' @('-OnlyProject',$target)
        $updates = @(Get-AuditEvents 'Update-Fleet_*.log' | Where-Object event -eq 'update-registration')
        Check 'actual fleet dry run logs record/client without changing installation' ($r.Exit -eq 0 -and $updates.Count -eq 1 -and $updates[0].data.recordId -eq $recordId -and -not $updates[0].data.apply)
        $r = Invoke-AuditCommand 'Uninstall-Hook.ps1' @('-RecordId',$recordId,'-ToolRoot',$tool,'-WhatIf') @() 'powershell.exe'
        $uninstall = @(Get-AuditEvents 'Uninstall-Hook_*.log' | Where-Object event -eq 'uninstall-outcome')
        Check 'PS5.1 actual dry uninstall keeps runtime and logs truthful outcome' ($r.Exit -eq 0 -and $uninstall.Count -eq 1 -and $uninstall[0].data.dryRun -and $uninstall[0].data.overall -eq 'ok' -and (Test-Path -LiteralPath (Join-Path $target '.claude/hooks/Hook-Maker/Ai-Memory-Load/Ai-Memory-Load.ps1')))
        $r = Invoke-AuditCommand 'Install-Hook.ps1' @('-CustomHook',$hook,'-TargetProject',$target,'-Clients','invalid')
        $outcomes = @(Get-AuditEvents 'Install-Hook_*.log' | Where-Object event -eq 'install-outcome')
        Check 'rejected install logs failure without requiring ResultPath' ($r.Exit -ne 0 -and @($outcomes | Where-Object {$_.data.overall -eq 'failed'}).Count -eq 1)
        $r = Invoke-AuditCommand 'Uninstall-DiscoveredHook.ps1' @('-RecordId','absent-discovered','-ToolRoot',$tool,'-WhatIf')
        $discovered = @(Get-AuditEvents 'Uninstall-DiscoveredHook_*.log' | Where-Object event -eq 'execution')
        Check 'discovered remover has its own qualified execution log' ($r.Exit -eq 0 -and $discovered.Count -eq 1 -and $discovered[0].data.tool -eq 'Uninstall-DiscoveredHook')
        $r = Invoke-AuditCommand 'Uninstall-Hook.ps1' @('-RecordId',$recordId,'-ToolRoot',$tool)
        $removed = @(Get-AuditEvents 'Uninstall-Hook_*.log' | Where-Object {$_.event -eq 'uninstall-outcome' -and -not $_.data.dryRun})
        Check 'real uninstall logs committed action outcome and removes only fixture runtime' ($r.Exit -eq 0 -and $removed.Count -eq 1 -and $removed[0].data.overall -eq 'ok' -and -not (Test-Path -LiteralPath (Join-Path $target '.claude/hooks/Hook-Maker/Ai-Memory-Load/Ai-Memory-Load.ps1')))
        $r = Invoke-AuditCommand 'Uninstall-Hook.ps1' @('-RecordId','password=credential-marker','-ToolRoot',$tool)
        $unsafeLogs = @(Get-ChildItem -LiteralPath $env:HOOKMAKER_LOG_DIR -Filter 'Uninstall-Hook_*.log' -File | ForEach-Object {[IO.File]::ReadAllText($_.FullName,[Text.Encoding]::UTF8)}) -join "`n"
        Check 'unsafe arbitrary record IDs never reach management logs' ($r.Exit -eq 0 -and $unsafeLogs -notmatch 'credential-marker')
        $concurrent = @()
        $concurrentStarts = @{}
        try {
            foreach ($index in 0..1) {
                $prefix = Join-Path $work ('concurrent-' + $index)
                $proc = Start-Process -FilePath pwsh -ArgumentList (ConvertTo-ProcessArgumentString @('-NoLogo','-NoProfile','-File',(Join-Path $tool 'scripts/Uninstall-Hook.ps1'),'-RecordId',('absent-' + $index),'-ToolRoot',$tool)) -NoNewWindow -PassThru -RedirectStandardOutput ($prefix + '.out') -RedirectStandardError ($prefix + '.err')
                $concurrent += $proc; $concurrentStarts[$proc.Id] = $proc.StartTime.ToUniversalTime(); $null = $proc.Handle
            }
            foreach ($proc in $concurrent) { if (-not $proc.WaitForExit(60000)) { throw 'Concurrent audit fixture timed out.' } }
            $runs = @(Get-AuditEvents 'Uninstall-Hook_*.log' | Where-Object event -eq 'execution')
            Check 'concurrent management runs allocate distinct logs and run identities' (@($concurrent | Where-Object ExitCode -ne 0).Count -eq 0 -and $runs.Count -eq 5 -and @($runs | Select-Object -ExpandProperty runId -Unique).Count -eq 5)
        }
        finally {
            foreach ($proc in $concurrent) {
                if (-not $proc.HasExited) { Stop-ProcessTree -ProcessId $proc.Id -RootCreated $concurrentStarts[$proc.Id] -TimeoutMilliseconds 2000 }
                $proc.Dispose()
            }
        }
        $logDirectory = $env:HOOKMAKER_LOG_DIR
        $badLog = Join-Path $work 'not-a-directory'
        Write-Utf8 $badLog 'fixture'
        $env:HOOKMAKER_LOG_DIR = $badLog
        $r = Invoke-AuditCommand 'Uninstall-Hook.ps1' @('-RecordId','absent','-ToolRoot',$tool)
        Check 'logging init failure warns and preserves original no-op outcome' ($r.Exit -eq 0 -and $r.Out -match 'audit logging is unavailable')
        $warningWrapper = Join-Path $tool 'scripts/audit-warning-fixture.ps1'
        Write-Utf8 $warningWrapper ("`$WarningPreference='Stop'`r`n& (Join-Path `$PSScriptRoot 'Uninstall-Hook.ps1') -RecordId absent -ToolRoot (Split-Path -Parent `$PSScriptRoot)")
        $r = Invoke-AuditCommand 'audit-warning-fixture.ps1'
        Check 'logging warning cannot become a management failure under WarningPreference Stop' ($r.Exit -eq 0 -and $r.Out -match 'audit logging is unavailable')
        $env:HOOKMAKER_LOG_DIR = $logDirectory
        $appendWrapper = Join-Path $tool 'scripts/audit-append-fixture.ps1'
        Write-Utf8 $appendWrapper ("`$WarningPreference='Stop'`r`n. (Join-Path `$PSScriptRoot '_managementaudit.ps1')`r`nStart-ManagementAudit -ToolRoot (Split-Path -Parent `$PSScriptRoot) -Name append-fixture -Path `$env:HOOKMAKER_LOG_DIR`r`nWrite-Output survived")
        $r = Invoke-AuditCommand 'audit-append-fixture.ps1'
        Check 'append failure has a nonthrowing single warning' ($r.Exit -eq 0 -and $r.Out -match 'survived' -and [regex]::Matches($r.Out,'audit logging is unavailable').Count -eq 1)
    }
}
finally {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name,$saved[$name]) }
    if (-not (Remove-TestWorkspace $work)) { throw 'Management audit fixture cleanup failed.' }
}
Write-Host ('ManagementAudit: ' + $script:Pass + ' passed, ' + $script:Fail + ' failed')
exit $script:Fail
