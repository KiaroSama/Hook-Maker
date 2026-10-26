# Retiring routing changes only its recorded hashes, never blesses other drift.
function Update-UninstallManifestHash {
    param($Entries,[string]$Path,[string]$Before,[string]$After)
    $entriesForPath=@($Entries|Where-Object{[string]$_.path-ieq$Path})
    if($entriesForPath.Count-ne1-or[string]$entriesForPath[0].hash-ine$Before){throw 'Routing manifest preimage is not proven.'}
    $entriesForPath[0].hash=$After
}

function Get-UninstallSyncMetadataTarget {
    param($Peer,$Sub,$ConfigTarget)
    $path=Join-Path $ConfigTarget.Directory '.hookmaker-runtime.json'
    $snapshot=Read-UninstallSnapshot $path
    $doc=$snapshot.Raw|ConvertFrom-Json
    $client=[string]$ConfigTarget.Client
    if([string]$doc.friendlyName-cne[string]$Peer.friendlyName-or[string]$doc.client-cne$client-or[string]$doc.scope-cne'project'-or
        [string]$doc.projectKey-cne(Get-RuntimeMetadataProjectKey -Scope 'project' -ProjectRoot ([string]$Peer.targetProjectRoot))){throw 'Peer runtime metadata ownership differs.'}
    $recorded=@($Sub.installedManifest|Where-Object{[string]$_.path-ieq([string]$Peer.friendlyName+'/.hookmaker-runtime.json')})
    if($recorded.Count-ne1-or[string]$recorded[0].hash-ine$snapshot.Hash){throw 'Peer runtime metadata has drifted.'}
    return [pscustomobject]@{Path=$path;Hash=$snapshot.Hash;Bytes=$snapshot.Bytes;Json='';Raw=$snapshot.Raw;Directory=$ConfigTarget.Directory;List='';ListBytes=$null;ListHash='';Metadata=$true;ConfigTarget=$ConfigTarget;RecordId=[string]$Peer.id;Client=$client;Friendly=[string]$Peer.friendlyName}
}

function Get-UninstallSyncMetadataBytes {
    param($Target)
    $ConfigTarget=$Target.ConfigTarget
    $doc=$Target.Raw|ConvertFrom-Json
    $raw=$Target.Raw
    foreach($change in @(
        [pscustomobject]@{Leaf='sync-hooks.json';Before=$ConfigTarget.Hash;After=$ConfigTarget.WrittenHash},
        [pscustomobject]@{Leaf='SYNC-PROJECTS.txt';Before=$ConfigTarget.ListHash;After=$ConfigTarget.WrittenListHash}
    )){
        if($change.Before-eq''-and$change.After-eq''){continue}
        $relative=[string]$Target.Friendly+'/'+$change.Leaf
        $entry=@($doc.runtimeManifest|Where-Object{[string]$_.path-ieq$relative})
        if($entry.Count-ne1-or[string]$entry[0].sha256-ine$change.Before){throw 'Peer metadata routing preimage differs.'}
        $old='    { "path": '+(ConvertTo-PlanJsonStringLiteral $relative)+', "sha256": '+(ConvertTo-PlanJsonStringLiteral $change.Before.ToLowerInvariant())+' }'
        $new='    { "path": '+(ConvertTo-PlanJsonStringLiteral $relative)+', "sha256": '+(ConvertTo-PlanJsonStringLiteral $change.After.ToLowerInvariant())+' }'
        if(-not$raw.Contains($old)){throw 'Peer metadata has unsupported serialization; refresh through the installer.'}
        $raw=$raw.Replace($old,$new)
    }
    return ,([Text.UTF8Encoding]::new($false).GetBytes($raw))
}

function Save-UninstallSyncManifests {
    param($Plan,$Changed)
    Invoke-WithInstallRegistryLock -ToolRoot $ToolRoot -Action {
        $live=Read-InstallRegistryState $ToolRoot -NoCache
        if($live.State-ne'ok'){throw 'Registry unavailable during routing manifest commit.'}
        $before = (Read-InstallRegistryState $ToolRoot -NoCache).Registry
        $working = ConvertTo-InstallRegistryCurrent -Registry $live.Registry
        $currentOwners=@($working.installs|Where-Object{[string](Get-Field $_ 'hookType')-ceq'Engine'-and(Normalize-Path ([string]$_.configPath))-ieq(Normalize-Path $Plan.Config)})
        if($currentOwners.Count-ne$Plan.Owners.Count){throw 'Sync ownership set changed before manifest commit.'}
        foreach($owner in $currentOwners){
            if(-not$Plan.Owners.ContainsKey([string]$owner.id)){throw 'Sync ownership set changed before manifest commit.'}
        }
        foreach($peer in @($working.installs)){
            if([string]$peer.id-ceq$RecordId-or[string](Get-Field $peer 'hookType')-cne'Engine'){continue}
            if((Normalize-Path ([string]$peer.configPath))-ine(Normalize-Path $Plan.Config)){continue}
            if(-not$Plan.Owners.ContainsKey([string]$peer.id)-or($peer|ConvertTo-Json -Depth 50 -Compress)-cne$Plan.Owners[[string]$peer.id]){throw 'Sync owner changed during retirement; retry with a fresh plan.'}
            $sourceTarget=$Plan.Targets[0]
            $sourceEntry=@($peer.sourceManifest|Where-Object{[string]$_.path-ieq([string]$peer.friendlyName+'/sync-hooks.json')})
            if($sourceEntry.Count-eq1-and[string]$sourceEntry[0].hash-ieq$sourceTarget.Hash){
                $sourceEntry[0].hash=$sourceTarget.WrittenHash
                $listContent=Get-SyncProjectListContentFor -RoutingConfig $Plan.Config -ProfileId ([string]$peer.profile) -ProjectRoot ([string]$peer.targetProjectRoot)
                $oldList=$Plan.SourceLists[[string]$peer.id]
                if($null-ne$oldList-and$null-ne$listContent){
                    $newHash=Get-PlanArtifactExpectedHash (New-PlanArtifact -RelativePath 'list' -Kind Generated -GeneratedContent $listContent)
                    Update-UninstallManifestHash $peer.sourceManifest ([string]$peer.friendlyName+'/SYNC-PROJECTS.txt') ([string]$oldList) $newHash
                }
            }
            foreach($target in @($Changed|Where-Object{[string](Get-Field $_ 'Directory')-ne''})){
                $sub=Get-ClientSubrecord $peer ([string]$target.Client)
                if($null-eq$sub){continue}
                if((Normalize-Path (Split-Path -Parent ([string]$sub.runtimeScript)))-ine(Normalize-Path $target.Directory)){continue}
                foreach($path in @($target.Path,$target.List)){
                    if($path-eq''){continue}
                    $expectedHash=if($path-ceq$target.Path){$target.WrittenHash}else{$target.WrittenListHash}
                    if((Get-FileSha256 $path)-cne$expectedHash){throw 'Peer runtime changed before routing manifest commit.'}
                }
                $leaf=if($null-ne$target.PSObject.Properties['Metadata']){'.hookmaker-runtime.json'}else{'sync-hooks.json'}
                Update-UninstallManifestHash $sub.installedManifest ([string]$peer.friendlyName+'/'+$leaf) $target.Hash $target.WrittenHash
                if($target.List-ne''){
                    Update-UninstallManifestHash $sub.installedManifest ([string]$peer.friendlyName+'/SYNC-PROJECTS.txt') $target.ListHash $target.WrittenListHash
                }
            }
        }
        try {
            Save-InstallRegistry $ToolRoot $working
            $committed=Read-InstallRegistryState $ToolRoot -NoCache
            if($committed.State-ne'ok'-or($committed.Registry.installs|ConvertTo-Json -Depth 50 -Compress)-cne($working.installs|ConvertTo-Json -Depth 50 -Compress)){throw 'Routing manifest persistence did not verify.'}
        }
        catch {
            $failure = $_.Exception.Message
            try {
                Save-InstallRegistry $ToolRoot $before
                $verify = Read-InstallRegistryState $ToolRoot
                if ($verify.State -ne 'ok' -or ($verify.Registry.installs | ConvertTo-Json -Depth 50 -Compress) -cne ($before.installs | ConvertTo-Json -Depth 50 -Compress)) { throw 'Registry preimage verification failed.' }
            }
            catch { throw ('Routing manifest commit failed and registry recovery is incomplete: ' + $failure) }
            throw ('Routing manifest commit failed; original registry restored: ' + $failure)
        }
    }|Out-Null
}
