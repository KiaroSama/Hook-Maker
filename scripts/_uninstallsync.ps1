. (Join-Path $PSScriptRoot '_uninstallsyncstate.ps1')
. (Join-Path $PSScriptRoot '_uninstallsyncmanifest.ps1')
# Selected profile/project route retirement. No source-project knowledge is
# deleted, and peer-to-peer routes never depend on whether a member uninstalls.
function Test-UninstallRouteEndpoint {
    param($Endpoint,[string]$Root)
    foreach($value in @((Get-Field $Endpoint 'root'))+@((Get-Field $Endpoint 'aliases'))){
        if(-not[string]::IsNullOrWhiteSpace([string]$value)-and(Normalize-Path ([string]$value))-ieq$Root){return $true}
    }
    return $false
}

function ConvertTo-UninstallSyncConfig {
    param([string]$Raw,[string]$Profile,[string]$Root)
    $doc=$Raw|ConvertFrom-Json
    if($null-eq$doc-or$null-eq$doc.PSObject.Properties['profiles']-or$doc.profiles-isnot[Array]){throw 'Routing configuration has no profiles array.'}
    $ids=@{};foreach($entry in @($doc.profiles)){
        $id=[string](Get-Field $entry 'id')
        if($id-eq''-or$ids.ContainsKey($id)){throw 'Routing profile identity is missing or duplicated.'};$ids[$id]=$true
    }
    $removed=New-Object 'Collections.Generic.List[object]'
    foreach($entry in @($doc.profiles)){
        if([string](Get-Field $entry 'id')-ine$Profile){continue}
        if($null-eq$entry.PSObject.Properties['routes']-or$entry.routes-isnot[Array]){throw 'Selected routing profile has no routes array.'}
        $routeIds=@{}
        $kept=New-Object 'Collections.Generic.List[object]'
        foreach($route in @($entry.routes)){
            $routeId=[string](Get-Field $route 'id')
            if($routeId-eq''-or$routeIds.ContainsKey($routeId)){throw 'Routing route identity is missing or duplicated.'};$routeIds[$routeId]=$true
            foreach($end in @('source','destination')){
                $endpoint=Get-Field $route $end
                if([string]::IsNullOrWhiteSpace([string](Get-Field $endpoint 'root'))){throw 'Routing endpoint identity is missing.'}
            }
            if((Test-UninstallRouteEndpoint (Get-Field $route 'source') $Root)-or(Test-UninstallRouteEndpoint (Get-Field $route 'destination') $Root)){$removed.Add($route)}
            else{$kept.Add($route)}
        }
        $entry.routes=$kept.ToArray()
    }
    return [pscustomobject]@{Document=$doc;Removed=$removed.ToArray();Json=($doc|ConvertTo-Json -Depth 50)}
}

function Get-UninstallSyncPlan {
    param($Selected,$Registry)
    if([string]$Selected.hookType-cne'Engine'){return $null}
    $root=Normalize-Path ([string]$Selected.targetProjectRoot)
    foreach($other in @($Registry.installs)){
        if([string](Get-Field $other 'id')-ceq[string]$Selected.id){continue}
        if([string](Get-Field $other 'hookType')-cne'Engine'){
            foreach($client in @(Get-InstalledClientNames $other)){
                $own=Get-ClientSubrecord $Selected $client
                $shared=Get-ClientSubrecord $other $client
                if($null-ne$own-and(Normalize-Path ([string]$own.runtimeScript))-ieq(Normalize-Path ([string]$shared.runtimeScript))){throw 'A custom registration shares this sync runtime without a profile retirement contract; review its ownership first.'}
            }
            continue
        }
        $otherRoot=[string](Get-Field $other 'targetProjectRoot')
        if($otherRoot-ne''-and(Normalize-Path $otherRoot)-ieq$root-and[string]$other.profile-ieq[string]$Selected.profile-and@(Get-InstalledClientNames $other).Count-gt0){
            throw 'Another installation still owns this project/profile membership; remove its registrations before retiring shared routing.'
        }
    }
    $config=[string]$Selected.configPath
    if([string]::IsNullOrWhiteSpace($config)-or-not[IO.Path]::IsPathRooted($config)){throw 'Selected sync configuration identity is missing.'}
    Assert-UninstallRegularPath $config
    $sourceSnapshot=Read-UninstallSnapshot $config
    $raw=$sourceSnapshot.Raw
    $change=ConvertTo-UninstallSyncConfig $raw ([string]$Selected.profile) $root
    $targets=New-Object 'Collections.Generic.List[object]'
    $sourceLists=@{}
    $owners=@{}
    $seen=@{}
    if(@($Registry.installs).Count-gt5000){throw 'Routing ownership inventory exceeds 5000 records.'}
    $totalBytes=[int64]$sourceSnapshot.Bytes.Length
    $targets.Add([pscustomobject]@{Path=$config;Hash=$sourceSnapshot.Hash;Bytes=$sourceSnapshot.Bytes;Json=$change.Json;Directory='';List='';ListBytes=$null;ListHash='';WrittenHash=''})
    $seen[(Normalize-Path $config)]=$true
    foreach($peer in @($Registry.installs)){
        if([string](Get-Field $peer 'hookType')-cne'Engine'){continue}
        if((Normalize-Path ([string]$peer.configPath))-ine(Normalize-Path $config)){continue}
        $owners[[string]$peer.id]=$peer|ConvertTo-Json -Depth 50 -Compress
        $oldList=Get-SyncProjectListContentFor -RoutingConfig $config -ProfileId ([string]$peer.profile) -ProjectRoot ([string]$peer.targetProjectRoot)
        if($null-ne$oldList){$sourceLists[[string]$peer.id]=Get-PlanArtifactExpectedHash (New-PlanArtifact -RelativePath 'list' -Kind Generated -GeneratedContent $oldList)}
        foreach($client in @(Get-InstalledClientNames $peer)){
            $sub=Get-ClientSubrecord $peer $client
            $peerRoot=[string](Get-Field $peer 'targetProjectRoot')
            if([string]$peer.scope-cne'project'-or$peerRoot-eq''){throw 'A global sync owner requires separate scope review.'}
            $expectedRoot=Join-Path $peerRoot ('.'+$client+'/hooks/Hook-Maker')
            $expectedScript=Join-Path $expectedRoot ([string]$peer.friendlyName+'/'+[string]$peer.friendlyName+'.ps1')
            if((Normalize-Path ([string]$sub.runtimeScript))-ine(Normalize-Path $expectedScript)){throw 'Peer runtime does not match its project/client identity.'}
            if((Normalize-Path ([string]$peer.toolRoot))-ine(Normalize-Path $ToolRoot)){throw 'Peer sync installation belongs to another tool owner.'}
            $dir=Split-Path -Parent ([string]$sub.runtimeScript)
            $path=Join-Path $dir 'sync-hooks.json'
            if($seen.ContainsKey((Normalize-Path $path))){continue}
            $seen[(Normalize-Path $path)]=$true
            Assert-UninstallRegularPath $path
            if(-not(Test-Path -LiteralPath $path -PathType Leaf)){
                if([string]$peer.id-ceq[string]$Selected.id-and-not(Test-Path -LiteralPath $dir)){continue}
                throw 'A tracked sync runtime configuration is missing; repair it before complete removal.'
            }
            $manifest=@($sub.installedManifest|Where-Object{[string]$_.path-ieq([string]$peer.friendlyName+'/sync-hooks.json')})
            $copySnapshot=Read-UninstallSnapshot $path
            $totalBytes+=$copySnapshot.Bytes.Length
            if($totalBytes-gt67108864){throw 'Routing closure exceeds 64 MiB inspection bound.'}
            $copyHash=$copySnapshot.Hash
            if($manifest.Count-ne1-or$copyHash-ine[string]$manifest[0].hash){throw 'A managed sync configuration has drifted; no routing changed.'}
            $peerRaw=$copySnapshot.Raw
            $peerChange=ConvertTo-UninstallSyncConfig $peerRaw ([string]$Selected.profile) $root
            # Only copies containing the selected membership need a write.
            if($peerChange.Removed.Count-eq0){continue}
            $list=Join-Path $dir 'SYNC-PROJECTS.txt'
            $listBytes=$null;$listHash=''
            if(Test-Path -LiteralPath $list){Assert-UninstallRegularPath $list;$listSnapshot=Read-UninstallSnapshot $list;$listBytes=$listSnapshot.Bytes;$listHash=$listSnapshot.Hash}
            $listManifest=@($sub.installedManifest|Where-Object{[string]$_.path-ieq([string]$peer.friendlyName+'/SYNC-PROJECTS.txt')})
            if($listManifest.Count-ne1-or[string]$listManifest[0].hash-ine$listHash){throw 'Managed sync project list has drifted; no routing changed.'}
            $expected=@(Get-ManagedClientManifest -ToolRoot $ToolRoot -Client $client -HookScript ([string]$peer.sourceScript) -FriendlyName ([string]$peer.friendlyName) -RecordId ([string]$peer.id) -Scope project -ProjectRoot $peerRoot -ConfigPath $config -IncludeConfig -ProfileId ([string]$peer.profile) -TimeoutSeconds ([int]$sub.timeout))
            foreach($leaf in @( ([string]$peer.friendlyName+'.ps1'), '_routelifecycle.ps1' )){
                $installed=Join-Path $dir $leaf
                $expectedFile=@($expected|Where-Object{[string]$_.path-ieq([string]$peer.friendlyName+'/'+$leaf)})
                if($expectedFile.Count-ne1-or(Get-FileSha256 $installed)-ine[string]$expectedFile[0].hash){throw 'Refresh peer sync runtimes through the installer before complete removal; route revalidation is required.'}
            }
            $target=[pscustomobject]@{Path=$path;Hash=$copySnapshot.Hash;Bytes=$copySnapshot.Bytes;Json=$peerChange.Json;Directory=$dir;List=$list;ListBytes=$listBytes;ListHash=$listHash;Project=[string](Get-Field $peer 'targetProjectRoot');Profile=[string]$peer.profile;RecordId=[string]$peer.id;Client=$client;Friendly=[string]$peer.friendlyName}
            $targets.Add($target)
            $targets.Add((Get-UninstallSyncMetadataTarget $peer $sub $target))
        }
    }
    # Include routes found only in an older managed copy too. Otherwise a
    # previously edited canonical config could hide a live peer inbox/state.
    $removedRoutes=New-Object 'Collections.Generic.List[object]'
    foreach($route in @($change.Removed)){$removedRoutes.Add($route)}
    foreach($target in @($targets.ToArray()|Where-Object{$null-eq$_.PSObject.Properties['Metadata']})){
        $original=[Text.UTF8Encoding]::new($false,$true).GetString($target.Bytes).TrimStart([char]0xfeff)
        $copyChange=ConvertTo-UninstallSyncConfig $original ([string]$Selected.profile) $root
        foreach($route in @($copyChange.Removed)){$removedRoutes.Add($route)}
    }
    $states=@(Get-UninstallSyncStatePlan -Routes $removedRoutes.ToArray() -Profile ([string]$Selected.profile))
    return [pscustomobject]@{Targets=$targets.ToArray();States=$states;Routes=$removedRoutes.ToArray();Root=$root;Profile=[string]$Selected.profile;Config=$config;SourceLists=$sourceLists;Owners=$owners}
}

function Invoke-UninstallSyncRetirement {
    param($Plan)
    if($null-eq$Plan){return}
    $changed=New-Object 'Collections.Generic.List[object]'
    try{
        # Preflight the full closure before the first write, then re-read under
        # each resource lock. Concurrent changes stop rather than get overwritten.
        foreach($target in @($Plan.Targets)){
            if($target.Directory-ne''-and-not(Test-Path -LiteralPath $target.Directory)){
                $selectedDirs=@(Get-InstalledClientNames $record|ForEach-Object{Split-Path -Parent ([string](Get-ClientSubrecord $record $_).runtimeScript)})
                if($selectedDirs-contains$target.Directory){continue}
                throw 'A peer runtime disappeared during retirement; no complete result can be verified.'
            }
            Assert-UninstallRegularPath $target.Path
            if((Get-FileSha256 $target.Path)-cne$target.Hash){throw 'Routing preimage changed; retry after reviewing current configuration.'}
        }
        Save-UninstallSyncJournal $Plan
        foreach($target in @($Plan.Targets)){
            # The selected runtime may already have been removed by this run.
            if($target.Directory-ne''-and-not(Test-Path -LiteralPath $target.Directory)){
                $selectedDirs=@(Get-InstalledClientNames $record|ForEach-Object{Split-Path -Parent ([string](Get-ClientSubrecord $record $_).runtimeScript)})
                if($selectedDirs-contains$target.Directory){continue}
                throw 'A peer runtime disappeared during retirement; no complete result can be verified.'
            }
            $runtimeMutex=$null;$runtimeHeld=$false
            if($target.Directory-ne''){
                $runtimeMutex=New-ManagedRuntimeMutex $target.Directory
                try{$runtimeHeld=$runtimeMutex.WaitOne(5000)}catch [Threading.AbandonedMutexException]{$runtimeHeld=$true}
                if(-not$runtimeHeld){$runtimeMutex.Dispose();throw 'Peer runtime is busy; routing retirement stopped.'}
            }
            try {
            Invoke-WithResourceLock -ResourcePath $target.Path -Action {
                Assert-UninstallRegularPath $target.Path
                if((Get-FileSha256 $target.Path)-cne$target.Hash){throw 'Routing changed while uninstall was running.'}
                $metadata=$null-ne$target.PSObject.Properties['Metadata']
                if($metadata){Write-UninstallBytesAtomic $target.Path (Get-UninstallSyncMetadataBytes $target)}
                else{$doc=$target.Json|ConvertFrom-Json;Write-JsonFileAtomic -Value $doc -Path $target.Path}
                $changed.Add($target)
                $target|Add-Member -NotePropertyName WrittenHash -NotePropertyValue (Get-FileSha256 $target.Path) -Force
                if(-not$metadata){
                    $verifiedRaw=[IO.File]::ReadAllText($target.Path,[Text.UTF8Encoding]::new($false,$true))
                    if((ConvertTo-UninstallSyncConfig $verifiedRaw $Plan.Profile $Plan.Root).Removed.Count-ne0){throw 'Selected membership remains after routing write.'}
                }
            }|Out-Null
            if($target.List-ne''){
                Invoke-WithResourceLock -ResourcePath $target.List -Action {
                    if((Get-FileSha256 $target.List)-cne$target.ListHash){throw 'Generated sync project list changed concurrently.'}
                    $content=Get-SyncProjectListContentFor -RoutingConfig $target.Path -ProfileId $target.Profile -ProjectRoot $target.Project
                    if($null-ne$content){
                        Write-UninstallBytesAtomic $target.List ([Text.UTF8Encoding]::new($false).GetBytes($content))
                        $target|Add-Member -NotePropertyName WrittenListHash -NotePropertyValue (Get-FileSha256 $target.List) -Force
                    }
                }|Out-Null
            }
            } finally {if($runtimeHeld){$runtimeMutex.ReleaseMutex()};if($null-ne$runtimeMutex){$runtimeMutex.Dispose()}}
        }
        foreach($target in $changed.ToArray()){
            if((Get-FileSha256 $target.Path)-cne$target.WrittenHash){throw 'Routing changed before final retirement verification.'}
        }
        Save-UninstallSyncManifests $Plan $changed.ToArray()
        Set-ComponentResult -Component 'syncRouting' -Status 'ok' -ReasonCode 'selectedMembershipRetired' -Message 'Selected project/profile routes retired; peer routes, other profiles and unrelated manifest entries preserved.'
    }catch{
        $retirementFailure=$_.Exception.Message
        $rollback=$changed.ToArray();[Array]::Reverse($rollback)
        foreach($target in $rollback){
            if($null-eq$target){continue}
            $rollbackMutex=$null;$rollbackHeld=$false
            try{
                if($target.Directory-ne''){
                    $rollbackMutex=New-ManagedRuntimeMutex $target.Directory
                    try{$rollbackHeld=$rollbackMutex.WaitOne(5000)}catch [Threading.AbandonedMutexException]{$rollbackHeld=$true}
                    if(-not$rollbackHeld){throw 'Peer runtime is busy during rollback.'}
                }
                Invoke-WithResourceLock -ResourcePath $target.Path -Action {
                    if((Get-FileSha256 $target.Path)-cne$target.WrittenHash){throw 'Concurrent routing edit prevents rollback.'}
                    Write-UninstallBytesAtomic $target.Path $target.Bytes
                }|Out-Null
                if($null-ne$target.PSObject.Properties['WrittenListHash']){
                    Invoke-WithResourceLock -ResourcePath $target.List -Action {
                        if((Get-FileSha256 $target.List)-cne$target.WrittenListHash){throw 'Concurrent project-list edit prevents rollback.'}
                        if($null-eq$target.ListBytes){Remove-Item -LiteralPath $target.List -Force -ErrorAction Stop}
                        else{Write-UninstallBytesAtomic $target.List $target.ListBytes}
                    }|Out-Null
                }
            }catch{Write-ManagementAudit -Event 'sync-rollback-incomplete' -Data @{path=$target.Path}}
            finally{if($rollbackHeld){$rollbackMutex.ReleaseMutex()};if($null-ne$rollbackMutex){$rollbackMutex.Dispose()}}
        }
        throw ('Sync routing retirement incomplete; selected record retained for repair/retry. ' + $retirementFailure)
    }
}
