# Complete removal retires owned operational markers, not historical evidence.
# Exact writer contracts only: a broad hook-name glob could delete another
# project's state or a failed-run receipt needed by a surviving completion gate.
function Get-UninstallStateLeaves {
    param([string]$Name,[string]$Root,[switch]$CheckSupport)
    $key=Get-ShortHash (Normalize-Path $Root).ToLowerInvariant()
    $map=@{
        # CI/incident records stay evidence; install-location markers are
        # session-only, never project-owned. Repository cooldowns resolve below.
        'Ci-Status-Check'=@("CiStatusCheck-Runner-$key.txt")
        'Dependabot-Check'=@()
        'Install-Location-Check'=@()
        'Test-Completion-Check'=@()
        'Cross-Project-.ai-Knowledge-Sync'=@()
        'Ai-Memory-Load'=@("AiMemoryLoad-$key.txt","AiMemoryLoad-dd-$key.txt")
        'Ai-Memory-Check'=@("AiMemoryCheck-$key.txt")
        'Cbm-Read-Check'=@("CbmReadCheck-$key.txt")
        'Cbm-Update-Check'=@("CbmUpdateCheck-$key.txt")
        'Graph-Read-Check'=@("GraphReadCheck-prompt-$key.txt")
        'Graph-Update-Check'=@("GraphUpdateCheck-$key.txt")
        'Dependency-Version-Check'=@("DependencyVersionCheck-$key.txt","DependencyVersionCheck-close-$key.txt")
        'Speckit-Check'=@("SpeckitCheck-$key.txt","SpeckitCheck-refresh-$key.txt")
        'Ignore-Rules-Check'=@("IgnoreRulesCheck-rules-$key.txt")
        'Secrets-Check'=@("Secrets-Check-$key.txt","Secrets-Check-Unused-$key.txt")
        'Git-Sync-Check'=@("GitSyncCheck-$key.txt")
        'Cloudflare-Deploy'=@("CloudflareDeploy-$key.txt")
        'Test-Plan-Check'=@("TestPlanCheck-$key.json")
        'Test-Temp-Cleanup'=@("TestTempCleanup-baseline-$key.json","TestTempCleanup-result-$key.json","TestTempCleanup-state-$key.json")
        'Docs-Freshness-Check'=@("DocsFreshnessCheck-baseline-$key.json","DocsFreshnessCheck-ack-$key.json","DocsFreshnessCheck-pushdeny-$key.txt","DocsFreshnessCheck-error-$key.txt")
        'Large-File-Check'=@("LargeFileCheckBaseline-$key.json")
        'Utf8-Encoding-Check'=@("Utf8EncodingCheck-$key.json")
        'Session-Summary-Check'=@("SessionSummary-$(Get-StopProjectKey $Root).txt","SessionSummary-$(Get-StopProjectKey $Root).txt.claims.json")
        'Feature-Request-Check'=@("FeatureRequestCheck-prompt-$key.txt","FeatureRequestCheck-gate-$key.txt")
        'Synapse-Rules-Check'=@("SynapseRulesCheck-seen-$key.json","SynapseRulesCheck-mid-$key.txt","SynapseRulesCheck-gate-$key.txt")
        'Mcp-Usage-Check'=@("McpUsageCheck-session-$key.json","McpUsageCheck-gate-$key.txt","McpUsageCheck-research-$key.txt")
        'Skills-Check'=@("SkillsCheck-index-$key.txt","SkillsCheck-close-$key.txt","SkillsCheck-deepdebug-$key.txt","SkillsCheck-prompt-$key.txt","SkillsCheck-drift-$key.txt.claims.json")
        'Github-Baseline-Check'=@("GithubBaselineCheck-badges-$key.txt","GithubBaselineCheck-selfhosted-$key.txt")
        'Test-Run-Guard'=@("TestRunGuard-report-$key.txt","TestRunGuard-config-$key.txt")
    }
    if($CheckSupport){return ($map.ContainsKey($Name)-or$Name-ceq'Rules-Check')}
    $leaves=New-Object 'Collections.Generic.List[string]'
    if(-not$map.ContainsKey($Name)-and$Name-cne'Rules-Check'){throw 'This hook has no declared complete-removal state contract; use ordinary removal and review external effects.'}
    if($map.ContainsKey($Name)){foreach($leaf in $map[$Name]){$leaves.Add($leaf)}}
    $safeName=[regex]::Replace($Name,'[^A-Za-z0-9]+','')
    $leaves.Add("StopBlock-$safeName-$key.txt")
    if($Name-eq'Rules-Check'){
        foreach($client in @('claude','codex')){
            foreach($prefix in @('RulesCheck','RulesCheck-close','RulesCheck-dd')){$leaves.Add("$prefix-$client-$key.txt")}
            $leaves.Add("RulesCheck-research-$client-$key.claims.json")
            foreach($category in @('migration','language','new-project','platform-boundary')){$leaves.Add("RulesCheck-language-$client-$category-$key.json")}
        }
    }
    # Delivery reservations suppress repeated notes; they are not test/CI proof.
    $claimMarkers=@{
        'Skills-Check'=@("SkillsCheck-close-$key.txt","SkillsCheck-deepdebug-$key.txt","SkillsCheck-prompt-$key.txt")
        'Mcp-Usage-Check'=@("McpUsageCheck-gate-$key.txt")
        'Rules-Check'=@("RulesCheck-close-claude-$key.txt","RulesCheck-close-codex-$key.txt")
    }
    if($claimMarkers.ContainsKey($Name)){foreach($marker in $claimMarkers[$Name]){$leaves.Add($marker+'.claims.json')}}
    if($Name-eq'Mcp-Usage-Check'){foreach($client in @('claude','codex')){$leaves.Add("McpUsageCheck-operation-$client-$key.claims.json")}}
    if($Name-eq'Skills-Check'){foreach($client in @('claude','codex')){$leaves.Add("SkillsCheck-research-$client-$key.claims.json")}}
    if($Name-in@('Dependabot-Check','Github-Baseline-Check','Ci-Status-Check')){
        $repository=Get-GitHubRepository -ProjectRoot $Root
        if($null-ne$repository){
            $repoKey=Get-ShortHash ($Root.ToLowerInvariant()+'|'+([string]$repository.Repository).ToLowerInvariant())
            if($Name-eq'Ci-Status-Check'){$leaves.Add('CiStatusCheck-Auth-'+$repoKey+'.json')}
            else{
                $prefix=if($Name-eq'Dependabot-Check'){'DependabotCheck-'}else{'GithubBaselineCheck-'}
                $leaves.Add($prefix+$repoKey+'.txt')
            }
        }
    }
    if($Name-eq'Large-File-Check'){
        $thresholds=@{800=$true}
        foreach($client in @(Get-InstalledClientNames $record)){
            $sub=Get-ClientSubrecord $record $client
            $config=Read-HookEnv (Join-Path (Split-Path -Parent ([string]$sub.runtimeScript)) '.env')
            $threshold=0
            if($config.ContainsKey('LINE_THRESHOLD')-and[int]::TryParse([string]$config['LINE_THRESHOLD'],[ref]$threshold)-and$threshold-ge50-and$threshold-le100000){$thresholds[$threshold]=$true}
        }
        foreach($threshold in $thresholds.Keys){$leaves.Add('LargeFileCheck-'+(Get-ShortHash ($Root.ToLowerInvariant()+'|'+$threshold))+'.txt')}
    }
    return $leaves.ToArray()
}

function Assert-UninstallRegularPath {
    param([string]$Path)
    $probe=[IO.Path]::GetFullPath($Path)
    while($probe){
        try{$attributes=[IO.File]::GetAttributes($probe)}
        catch [IO.FileNotFoundException]{$attributes=0}
        catch [IO.DirectoryNotFoundException]{$attributes=0}
        if(($attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'Removal target contains a reparse point.'}
        $parent=[IO.Directory]::GetParent($probe);if($null-eq$parent){break};$probe=$parent.FullName
    }
}

function Assert-UninstallTree {
    param([string]$Root)
    if(-not(Test-Path -LiteralPath $Root)){return}
    Assert-UninstallRegularPath $Root
    $stack=New-Object 'Collections.Generic.Stack[string]';$stack.Push($Root);$count=0
    while($stack.Count-gt0){
        foreach($item in @(Get-ChildItem -LiteralPath $stack.Pop() -Force -ErrorAction Stop)){
            if(++$count-gt20000){throw 'Removal tree exceeds its ownership inspection limit.'}
            if(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'Removal tree contains a redirected descendant.'}
            if($item.PSIsContainer){$stack.Push($item.FullName)}
        }
    }
}

function Read-UninstallSnapshot {
    param([string]$Path)
    Assert-UninstallRegularPath $Path
    $stream=[IO.File]::Open($Path,'Open','Read','Read')
    try{
        if($stream.Length-gt8388608){throw 'Removal configuration exceeds 8 MiB inspection bound.'}
        $memory=New-Object IO.MemoryStream
        try{$stream.CopyTo($memory);$bytes=$memory.ToArray()}finally{$memory.Dispose()}
    }finally{$stream.Dispose()}
    $hash=[Security.Cryptography.SHA256]::Create()
    try{$digest=([BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-','')}finally{$hash.Dispose()}
    return [pscustomobject]@{Bytes=$bytes;Hash=$digest;Raw=[Text.UTF8Encoding]::new($false,$true).GetString($bytes).TrimStart([char]0xfeff)}
}

function Write-UninstallBytesAtomic {
    param([string]$Path,[byte[]]$Bytes)
    Assert-UninstallRegularPath $Path
    $temp=$Path+'.uninstall-'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        [IO.File]::WriteAllBytes($temp,$Bytes)
        if([IO.File]::Exists($Path)){[IO.File]::Replace($temp,$Path,[NullString]::Value)}
        else{[IO.File]::Move($temp,$Path)}
    }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}

function Test-UninstallStateShared {
    param($Selected,$Registry)
    foreach($other in @($Registry.installs)){
        if([string](Get-Field $other 'id')-ceq[string]$Selected.id){continue}
        $otherRoot=[string](Get-Field $other 'targetProjectRoot')
        if([string](Get-Field $other 'scope')-eq'global'-and[string](Get-Field $other 'friendlyName')-ieq[string]$Selected.friendlyName-and@(Get-InstalledClientNames $other).Count-gt0){return $true}
        if([string]::IsNullOrWhiteSpace($otherRoot)){continue}
        $sameRoot=(Normalize-Path $otherRoot)-ieq(Normalize-Path ([string]$Selected.targetProjectRoot))
        if(-not$sameRoot){continue}
        if([string](Get-Field $other 'friendlyName')-ieq[string]$Selected.friendlyName-and@(Get-InstalledClientNames $other).Count-gt0){return $true}
        foreach($stage in @((Get-Field (Get-Field $other 'nativeGit') 'expectedStages'))){
            if([string]$stage-match('[/\\]'+[regex]::Escape([string]$Selected.friendlyName)+'[/\\]')){return $true}
        }
    }
    return $false
}

function Get-CompleteUninstallPlan {
    param($Selected,$Registry)
    if([string]$Selected.scope-cne'project'-or[string]::IsNullOrWhiteSpace([string]$Selected.targetProjectRoot)){throw 'Complete removal requires one managed project installation.'}
    $root=Get-RepositoryPhysicalRoot ([string]$Selected.targetProjectRoot)
    if([string]$Selected.friendlyName-ceq'Cross-Project-.ai-Knowledge-Sync'-and[string]$Selected.hookType-cne'Engine'){throw 'Complete sync removal requires a persisted engine profile; custom engine registration has no membership ownership contract.'}
    foreach($client in @(Get-InstalledClientNames $Selected)){
        $sub=Get-ClientSubrecord $Selected $client
        $identity=Test-ClientRecordIdentity -Subrecord $sub -ClientName $client
        if(-not$identity.Ok){throw $identity.Reason}
        foreach($path in @($identity.HookDir,$identity.CanonicalSettingsPath)){Assert-UninstallRegularPath $path}
        Assert-UninstallTree $identity.HookDir
        $scan=Get-ClientHandlerScan -SettingsPath $identity.CanonicalSettingsPath -Subrecord $sub -CanonicalRuntimeScript $identity.CanonicalRuntimeScript
        if($scan.NearMatch){throw $scan.NearMatchDetail}
    }
    $canonical=Join-Path $ToolRoot ('hooks/'+[string]$Selected.friendlyName+'/'+[string]$Selected.friendlyName+'.ps1')
    $isCanonical=(Normalize-Path ([string]$Selected.sourceScript))-ieq(Normalize-Path $canonical)
    if(-not$isCanonical){throw 'Custom hook external effects have no declared cleanup contract; use ordinary removal and review its external state separately.'}
    $native=Get-Field $Selected 'nativeGit'
    if($null-ne$native-and(Get-Field $native 'managed')-eq$true){
        $ownership=Resolve-OwnNativeStages -Native $native -OwnRuntimeRoot ([string]$native.runtimeRoot)
        if(-not$ownership.Ok){throw $ownership.Reason}
        foreach($other in @($Registry.installs)){
            if([string]$other.id-ceq[string]$Selected.id){continue}
            $otherNative=Get-Field $other 'nativeGit'
            if($null-eq$otherNative-or(Get-Field $otherNative 'managed')-ne$true){continue}
            foreach($stage in @(Get-Field $otherNative 'expectedStages')){
                if(@($ownership.Stages)-contains(Get-CanonicalPathOrNull ([string]$stage))){throw 'Another native chain owns a selected stage; review shared native ownership before complete removal.'}
            }
        }
    }
    $leaves=@(Get-UninstallStateLeaves ([string]$Selected.friendlyName) $root)
    $state=Join-Path $env:LOCALAPPDATA 'HookMaker/state'
    $paths=@($leaves|ForEach-Object{Join-Path $state $_})
    if([string]$Selected.friendlyName-ceq'Skills-Check'-and(Test-Path -LiteralPath $state -PathType Container)){
        $prefix='SkillsCheck-shortlist-'+(Get-ShortHash $root.ToLowerInvariant())+'-'
        $entries=@(Get-ChildItem -LiteralPath $state -File -Force -Filter ($prefix+'*.txt') -ErrorAction Stop)
        if($entries.Count-gt10000){throw 'Project skill shortlist inventory exceeds its inspection bound.'}
        foreach($entry in $entries){
            if($entry.Name-cmatch('^'+[regex]::Escape($prefix)+'[a-f0-9]{10}\.txt$')){$paths+=@($entry.FullName)}
        }
    }
    # Session-only markers without project identity cannot be attributed here.
    # CI/test/task/generation receipts and repository-common Git baselines are
    # shared evidence, not exclusive operational state of this installation.
    foreach($path in $paths){Assert-UninstallRegularPath $path;if(Test-Path -LiteralPath $path -PathType Container){throw 'Owned operational state path is a directory.'}}
    return [pscustomobject]@{Root=$root;StatePaths=$paths;Shared=(Test-UninstallStateShared $Selected $Registry);Canonical=$isCanonical}
}

# Cloudflare's installed-cleanup signal must not outlive its last owning
# installation. Canonicalize exactly as its writer does (including trailing /).
function Remove-CleanupCoordinationRecord {
    if ($FriendlyName -ne 'Test-Temp-Cleanup' -or [string]::IsNullOrWhiteSpace($RecordTargetProjectRoot)) { return }
    if(Test-UninstallStateShared $record $registry){return}
    $key=Get-ShortHash (Normalize-Path $RecordTargetProjectRoot).ToLowerInvariant()
    $path=Join-Path $env:LOCALAPPDATA ('HookMaker/state/TestTempCleanup-result-'+$key+'.json')
    Assert-UninstallRegularPath $path
    if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force -ErrorAction Stop}
    if(Test-Path -LiteralPath $path){throw 'Cleanup coordination record remains after removal.'}
}

function Remove-CompleteUninstallState {
    param($Plan)
    $live=Read-InstallRegistryState $ToolRoot
    if($live.State-ne'ok'){throw 'Registry unavailable before operational state retirement.'}
    Set-ComponentResult -Component 'retainedEvidence' -Status 'ok' -ReasonCode 'historyPreserved' -Message 'Original receipts, audit logs, review recovery, shared task/Stop ledgers and repository approvals are retained; they are not active installations.'
    if(Test-UninstallStateShared $record $live.Registry){Set-ComponentResult -Component 'operationalState' -Status 'ok' -ReasonCode 'sharedOwnerRetained' -Message 'Another live installation still owns this project state; only the selected installation is retired.';return}
    foreach($path in @($Plan.StatePaths)){
        Assert-UninstallRegularPath $path
        Invoke-WithResourceLock -ResourcePath $path -Action {
            Assert-UninstallRegularPath $path
            if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force -ErrorAction Stop}
            if(Test-Path -LiteralPath $path){throw 'Owned operational state remains after removal.'}
        }|Out-Null
    }
    Set-ComponentResult -Component 'operationalState' -Status 'ok' -ReasonCode 'ownedMarkersRemoved'
}
