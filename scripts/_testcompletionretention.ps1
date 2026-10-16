# One shared receipt fixture per case; aged recovery is historical, never current proof.
function Invoke-AgedRecoveryRegression {
    param([switch]$Codex,[string]$HostExe='pwsh',[switch]$PositiveOnly)
    $cases=if($PositiveOnly){@('same')}else{@('same','missing','different','older','terminated','leaking')}
    foreach($case in $cases) {
        $c=New-IsolatedHookCopy
        $p=New-GitRepo ('AgedRecovery-'+$Codex+'-'+$case)
        Write-GuardedResult $c $p -Overall failed -ExitCode 3 -RunId legacy -CommandFingerprint exact-command -ProjectFingerprint ' ' -AgeMinutes 5000
        $negative=Get-RunStateFile $c $p result legacy
        $originals=@($negative)
        if($case-ne'missing') {
            Write-GuardedResult $c $p -RunId recovery -CommandFingerprint $(if($case-eq'different'){'different-command'}else{'exact-command'}) -ProjectFingerprint prior-valid-state -AgeMinutes $(if($case-eq'older'){6000}else{2000}) -Overall $(if($case-eq'terminated'){'terminated'}else{'ok'}) -Leaked $(if($case-eq'leaking'){@(424242)}else{@()})
            $originals+=Get-RunStateFile $c $p result recovery
        }
        foreach($path in $originals){[IO.File]::SetLastWriteTimeUtc($path,[DateTime]::UtcNow.AddDays(-3))}
        $before=@($originals|ForEach-Object{[Convert]::ToBase64String([IO.File]::ReadAllBytes($_))})
        Write-ObservedRecord $c $p -RunId current -CommandFingerprint current-command
        Write-GuardedResult $c $p -RunId current -CommandFingerprint current-command
        $r=Fire -Copy $c -Cwd $p -Codex:$Codex -Exe $HostExe
        $blocked=$r.Out-match'"decision"\s*:\s*"block"'
        Check ('aged recovery '+$case+' retains exact supersession decision') ($r.Exit-eq0-and$r.Err-eq''-and$blocked-eq($case-ne'same')) ($r.Out+$r.Err)
        $after=@($originals|ForEach-Object{[Convert]::ToBase64String([IO.File]::ReadAllBytes($_))})
        Check ('aged recovery '+$case+' preserves original byte sequences') (($before-join'|')-ceq($after-join'|'))
        if($case-eq'same') {
            [IO.File]::Delete((Get-RunStateFile $c $p result current))
            # The outstanding current observation still requires its own result.
            $r=Fire -Copy $c -Cwd $p -Codex:$Codex -Exe $HostExe
            Check 'retired recovery cannot become fresh execution proof' ($r.Exit-eq0-and$r.Err-eq''-and$r.Out-match'"decision"\s*:\s*"block"') ($r.Out+$r.Err)
        }
    }
}
