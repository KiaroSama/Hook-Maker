# Execute a confirmed selection through each record kind's existing owner.
# Kept apart from the list/selection screen so outcome reporting stays shared.
function Invoke-UninstallSelection {
    param($Registry,$RecordIds,$Blocked)
    . (Join-Path $PSScriptRoot '_uninstallresidue.ps1')
    Write-PhaseHeader 'Removing' $C.Process '-'
    $removed=New-Object 'Collections.Generic.List[string]'
    $failed=New-Object 'Collections.Generic.List[string]'
    $manual=New-Object 'Collections.Generic.List[string]'
    $discoveredUninstallScript=Join-Path (Split-Path -Parent $UninstallScript) 'Uninstall-DiscoveredHook.ps1'
    foreach($id in $RecordIds){
        $record=@($Registry.installs|Where-Object{(Get-RecordDisplayField $_ 'id' '')-eq$id})[0]
        $discovered=(Get-RecordType $record)-eq'discovered'
        $executor=if($discovered){$discoveredUninstallScript}else{$UninstallScript}
        $options=@{}
        if(-not$discovered){
            if(-not(Test-InstallRecordValid $record).Ok){$options.ForgetUnreadableRecord=$true}
            elseif((Get-RecordDisplayField $record 'scope')-eq'project'){
                $name=Get-RecordDisplayField $record 'friendlyName' ''
                $source=Get-RecordDisplayField $record 'sourceScript' ''
                $canonical=Join-Path $ToolRoot ('hooks/'+$name+'/'+$name+'.ps1')
                $project=Get-RecordDisplayField $record 'targetProjectRoot' ''
                if($source-ne''-and(Normalize-Path $source)-ieq(Normalize-Path $canonical)-and(Get-UninstallStateLeaves $name $project -CheckSupport)){
                    if($name-cne'Cross-Project-.ai-Knowledge-Sync'-or(Get-RecordDisplayField $record 'hookType' '')-ceq'Engine'){$options.Complete=$true}
                }
            }
        }
        $resultPath=Join-Path ([IO.Path]::GetTempPath()) ('hookmaker-uninstall-'+[guid]::NewGuid().ToString('N')+'.json')
        $overall='failed';$doc=$null
        try{
            try{& $executor -RecordId $id -ToolRoot $ToolRoot -ResultPath $resultPath @options *> $null}catch{}
            if(Test-Path -LiteralPath $resultPath -PathType Leaf){
                try{$doc=[IO.File]::ReadAllText($resultPath,[Text.Encoding]::UTF8)|ConvertFrom-Json;$overall=[string](Get-Field $doc 'overall')}catch{}
            }
        }finally{if(Test-Path -LiteralPath $resultPath){Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue}}
        $name=Get-HookFriendlyName (Get-RecordDisplayField $record 'friendlyName' 'unknown-record')
        $where=Get-RecordLocationText $record
        switch($overall){
            'ok' {
                $removed.Add($id)
                Write-Host ('  '+(Get-Painted 'removed' $C.Green)+' '+$name)
            }
            'manualRepair' {
                $manual.Add($id)
                Write-Host ('  '+(Get-Painted 'manual repair needed' $C.Amber)+' '+$name)
                Write-Host ('      '+(Get-Painted $where $C.Gray))
                Write-Log 'WARNING' 'UNINSTALL' ('Manual repair needed: '+$name+' at '+$where+' (id '+$id+')')
            }
            'partial' {
                $manual.Add($id)
                Write-Host ('  '+(Get-Painted 'partially removed - needs attention' $C.Amber)+' '+$name)
                Write-Host ('      '+(Get-Painted $where $C.Gray))
                Write-Log 'WARNING' 'UNINSTALL' ('Partially removed: '+$name+' at '+$where+' (id '+$id+')')
            }
            default {
                $failed.Add($id)
                Write-Host ('  '+(Get-Painted 'failed' $C.Red)+' '+$name)
                Write-Host ('      '+(Get-Painted $where $C.Gray))
                Write-Log 'ERROR' 'UNINSTALL' ('Uninstall failed: '+$name+' at '+$where+' (id '+$id+')')
            }
        }
        if($overall-ne'ok'-and$null-ne$doc){
            foreach($component in @($doc.components|Where-Object{$_.status-in@('failed','manualRepair')})){
                Write-NoteLine ('    '+[string]$component.component+': '+[string]$component.message)
            }
        }
    }
    Write-Host ''
    Write-Field 'removed' ([string]$removed.Count)
    Write-Field 'needs manual repair' ([string]$manual.Count)
    Write-Field 'failed' ([string]$failed.Count)
    if($Blocked.Count-gt0){Write-Field 'skipped (manual repair)' ([string]$Blocked.Count)}
    if($manual.Count-gt0-or$failed.Count-gt0-or$Blocked.Count-gt0){Write-NoteLine '  Records that did not fully uninstall are KEPT in the registry so nothing is silently lost.'}
    Write-Log 'INFO' 'UNINSTALL' ('Uninstall finished: removed='+$removed.Count+' manual='+$manual.Count+' failed='+$failed.Count+' skipped='+$Blocked.Count)
    return 'done'
}
