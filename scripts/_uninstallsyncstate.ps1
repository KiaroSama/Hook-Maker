# Retire route-local state without erasing pending review evidence. Archive
# beneath the same sync root, outside active state/inbox, so a same-volume move
# is recoverable and never copies private knowledge into management logs.
function Get-UninstallSyncStatePlan {
    param($Routes,[string]$Profile)
    $seen=@{}
    if(@($Routes).Count-gt10000){throw 'Selected routing closure exceeds 10000 routes.'}
    foreach($route in @($Routes)){
        foreach($field in @('id','source','destination')){if($null-eq$route.PSObject.Properties[$field]){throw 'Recovery route identity is incomplete.'}}
        $source=Normalize-Path ([string]$route.source.root)
        $destination=Normalize-Path ([string]$route.destination.root)
        $directory=[string](Get-Field $route.destination 'directory');if($directory-eq''){$directory='.ai'}
        $dest=Join-Path $destination $directory
        if(-not(Test-PathContainedIn $dest $destination)-or(Normalize-Path $dest)-ieq$destination){throw 'Sync destination is not a contained project directory.'}
        $text=$Profile+'|'+[string]$route.id+'|'+$source
        $safe=([regex]::Replace($text,'[^A-Za-z0-9._-]+','-')).Trim('-')
        if($safe.Length-gt48){$safe=$safe.Substring(0,48)};if($safe-eq''){$safe='item'}
        $key=$safe+'-'+(Get-RepositoryIdentityHash $text).Substring(0,10)
        $sync=Join-Path $dest '.cross-project-sync'
        $state=Join-Path $sync ('state/'+$key+'.json')
        $inbox=Join-Path $sync ('inbox/'+$key)
        if($seen.ContainsKey($state)){
            if($seen[$state]-cne$text){throw 'Sync state key collision; ownership is ambiguous.'}
            continue
        };$seen[$state]=$text
        foreach($path in @($sync,$state,$inbox)){Assert-UninstallRegularPath $path}
        Assert-UninstallTree $inbox
        if(Test-Path -LiteralPath $state){
            $doc=(Read-UninstallSnapshot $state).Raw|ConvertFrom-Json
            if([string](Get-Field $doc 'profileId')-cne$Profile-or[string](Get-Field $doc 'routeId')-cne[string]$route.id-or
                (Normalize-Path ([string](Get-Field $doc 'sourceRoot')))-ine$source){throw 'Sync state identity differs from selected route.'}
        }
        [pscustomobject]@{State=$state;Inbox=$inbox;SyncRoot=$sync;Profile=$Profile;Route=[string]$route.id;Source=$source}
    }
}

function Save-UninstallSyncJournal {
    param($Plan)
    if($null-eq$Plan-or$WhatIf){return}
    $directory=Join-Path (Get-InstallStateDirectory $ToolRoot) 'uninstall-pending'
    Assert-UninstallRegularPath $directory
    $path=Join-Path $directory ($RecordId+'.json')
    Assert-UninstallRegularPath $path
    Invoke-WithResourceLock -ResourcePath $path -Action {
    if(Test-Path -LiteralPath $path){
        $expected=[string](Get-Field $record 'uninstallJournalHash')
        if($expected-eq''-or(Get-FileSha256 $path)-cne$expected){throw 'Uninstall recovery journal preimage is unproven.'}
        $prior=(Read-UninstallSnapshot $path).Raw|ConvertFrom-Json
        if([string]$prior.recordId-cne$RecordId-or[string]$prior.root-cne$Plan.Root-or[string]$prior.profile-cne$Plan.Profile){throw 'Uninstall recovery journal identity changed.'}
        $routes=@($prior.routes)+@($Plan.Routes)
        foreach($route in $routes){
            if(-not(Test-UninstallRouteEndpoint $route.source $Plan.Root)-and-not(Test-UninstallRouteEndpoint $route.destination $Plan.Root)){throw 'Recovery route does not name the selected project.'}
        }
        $unique=@{}
        foreach($route in $routes){$signature=Get-RepositoryIdentityHash ($route|ConvertTo-Json -Depth 50 -Compress);$unique[$signature]=$route}
        $Plan.Routes=@($unique.Values)
        $Plan.States=@(Get-UninstallSyncStatePlan -Routes $Plan.Routes -Profile $Plan.Profile)
    }
    $priorBytes=$null
    if(Test-Path -LiteralPath $path){$priorBytes=[IO.File]::ReadAllBytes($path)}
    Write-JsonFileAtomic -Path $path -Value ([pscustomobject]@{schema=1;recordId=$RecordId;root=$Plan.Root;profile=$Plan.Profile;routes=@($Plan.Routes)})
    $journalHash=Get-FileSha256 $path
    try {
        Invoke-WithInstallRegistryLock -ToolRoot $ToolRoot -Action {
            $live=Read-InstallRegistryState $ToolRoot -NoCache
            if($live.State-ne'ok'){throw 'Registry unavailable before route retirement.'}
            $selected=@($live.Registry.installs|Where-Object{[string]$_.id-ceq$RecordId})
            if($selected.Count-ne1){throw 'Selected installation changed before route retirement.'}
            if(([string](Get-Field $selected[0] 'uninstallJournalHash'))-cne([string](Get-Field $record 'uninstallJournalHash'))){throw 'Selected recovery pin changed before route retirement.'}
            Set-ObjectProperty $selected[0] 'uninstallJournalHash' $journalHash
            Save-InstallRegistry $ToolRoot $live.Registry
        }|Out-Null
        Set-ObjectProperty $record 'uninstallJournalHash' $journalHash
    } catch {
        # A failed acknowledgement can follow a committed registry write. Never
        # erase its pinned journal, or guess that unreadable persistence failed.
        $failure=$_
        $check=Read-InstallRegistryState $ToolRoot -NoCache
        if($check.State-eq'ok'){
            $current=@($check.Registry.installs|Where-Object{[string]$_.id-ceq$RecordId})
            if($current.Count-eq1-and[string](Get-Field $current[0] 'uninstallJournalHash')-cne$journalHash-and(Get-FileSha256 $path)-ceq$journalHash){
                if($null-ne$priorBytes){Write-UninstallBytesAtomic $path $priorBytes}
                else{Remove-Item -LiteralPath $path -Force -ErrorAction Stop}
            }
        }
        throw $failure
    }
    }|Out-Null
}

function Complete-UninstallSyncJournal {
    param($Plan)
    if($null-eq$Plan){return}
    $stateRoot=Get-InstallStateDirectory $ToolRoot
    $path=Join-Path $stateRoot ('uninstall-pending/'+$RecordId+'.json')
    Assert-UninstallRegularPath $path
    Invoke-WithResourceLock -ResourcePath $path -Action {
        if(-not(Test-Path -LiteralPath $path)){return}
        if((Get-FileSha256 $path)-cne[string](Get-Field $record 'uninstallJournalHash')){throw 'Completed uninstall journal changed; recovery retained.'}
        $history=Join-Path $stateRoot 'uninstall-recovery'
        Assert-UninstallRegularPath $history
        [void][IO.Directory]::CreateDirectory($history)
        Move-Item -LiteralPath $path -Destination (Join-Path $history ($RecordId+'-'+[guid]::NewGuid().ToString('N')+'.json')) -ErrorAction Stop
    }|Out-Null
}

function Move-UninstallSyncState {
    param($Plan)
    foreach($entry in @($Plan.States)){
        # Drain an existing writer even when it has not created its first file.
        # Hold one route lock across both moves; queued engines recheck routing.
        $mutexKey=Get-RepositoryIdentityHash (Normalize-Path $entry.State).ToUpperInvariant()
        $mutex=[Threading.Mutex]::new($false,('Global\HookMakerSync-'+$mutexKey));$held=$false
        try{
            try{$held=$mutex.WaitOne(5000)}catch [Threading.AbandonedMutexException]{$held=$true}
            if(-not$held){throw 'Sync route is busy; selected record retained.'}
            foreach($path in @($entry.State,$entry.Inbox)){
                Assert-UninstallRegularPath $path
                if(-not(Test-Path -LiteralPath $path)){continue}
                if(-not(Test-PathContainedIn $path $entry.SyncRoot)){throw 'Sync state recovery path escaped its root.'}
                if($path-ceq$entry.Inbox){Assert-UninstallTree $path}
                if($path-ceq$entry.State){
                    $current=Read-JsonFile $path
                    if([string](Get-Field $current 'profileId')-cne$entry.Profile-or[string](Get-Field $current 'routeId')-cne$entry.Route-or
                        (Normalize-Path ([string](Get-Field $current 'sourceRoot')))-ine$entry.Source){throw 'Sync state changed before retirement.'}
                }
                $retired=Join-Path $entry.SyncRoot ('retired/'+$RecordId)
                Assert-UninstallRegularPath $retired
                [void][IO.Directory]::CreateDirectory($retired)
                $target=Join-Path $retired ((Split-Path -Leaf $path)+'-'+[guid]::NewGuid().ToString('N'))
                Move-Item -LiteralPath $path -Destination $target -ErrorAction Stop
                if(Test-Path -LiteralPath $path){throw 'Active sync state remains after retirement.'}
                if(-not(Test-Path -LiteralPath $target)){throw 'Retired recovery target could not be verified.'}
            }
        }finally{if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
    }
    Set-ComponentResult -Component 'syncState' -Status 'ok' -ReasonCode 'retiredWithRecovery' -Message 'Selected route state and pending inbox moved out of active namespaces to route-local retired recovery; applied knowledge and unrelated routes were not deleted.'
}
