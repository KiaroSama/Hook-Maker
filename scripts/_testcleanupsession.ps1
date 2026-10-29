# Real lifecycle interleaving, shared by the existing cleanup suite and narrow seam.
function Invoke-CleanupSessionRegression {
    param([string]$HostExe='pwsh')
    $c=New-IsolatedHookCopy
    $p=New-Proj ('session-isolation-'+$HostExe)
    $null=Fire -HookPath $c.Script -Cwd $p -EventName SessionStart -SessionId 'session-A' -LocalAppData $c.LocalAppData -Exe $HostExe
    $state=Join-Path $c.LocalAppData 'HookMaker/state'
    $key=Get-ShortHash ((Normalize-Path $p).ToLowerInvariant())
    $aPath=Join-Path $state ('TestTempCleanup-baseline-'+$key+'-'+(Get-ShortHash 'session-A')+'.json')
    $oldPath=Join-Path $state ('TestTempCleanup-baseline-'+$key+'.json')
    $initialPath=if(Test-Path $aPath){$aPath}else{$oldPath}
    $initial=[IO.File]::ReadAllText($initialPath,[Text.Encoding]::UTF8)
    $null=New-Cache $p
    $null=Fire -HookPath $c.Script -Cwd $p -EventName SessionStart -SessionId 'session-B' -LocalAppData $c.LocalAppData -Exe $HostExe
    $a=Fire -HookPath $c.Script -Cwd $p -EventName Stop -SessionId 'session-A' -LocalAppData $c.LocalAppData -Exe $HostExe
    Check ($HostExe+': concurrent session cannot replace A baseline') ($a.Err-eq''-and$a.Out-match'at-session-start=no'-and$a.Out-match'during-session=appeared'-and$a.Out-notmatch'baseline-session-mismatch') $a.Out
    $b=Fire -HookPath $c.Script -Cwd $p -EventName Stop -SessionId 'session-B' -LocalAppData $c.LocalAppData -Exe $HostExe
    Check ($HostExe+': B retains its own preexisting classification') ($b.Err-eq''-and$b.Out-match'at-session-start=yes'-and$b.Out-notmatch'during-session=appeared') $b.Out
    $again=Fire -HookPath $c.Script -Cwd $p -EventName Stop -SessionId 'session-A' -LocalAppData $c.LocalAppData -Exe $HostExe
    Check ($HostExe+': another session cannot reset A reporting state') ($again.Out-eq''-and$again.Err-eq'') $again.Out
    $null=Fire -HookPath $c.Script -Cwd $p -EventName SessionStart -SessionId 'session-A' -LocalAppData $c.LocalAppData -Exe $HostExe
    Check ($HostExe+': repeated SessionStart preserves first baseline bytes') ((Test-Path $aPath)-and[IO.File]::ReadAllText($aPath,[Text.Encoding]::UTF8)-ceq$initial)
    $legacy=New-IsolatedHookCopy
    $lp=New-Proj ('session-legacy-'+$HostExe)
    $lk=Get-ShortHash ((Normalize-Path $lp).ToLowerInvariant())
    $ls=Join-Path $legacy.LocalAppData 'HookMaker/state'
    [void][IO.Directory]::CreateDirectory($ls)
    $legacyPath=Join-Path $ls ('TestTempCleanup-baseline-'+$lk+'.json')
    $legacyDoc=[ordered]@{sessionId='legacy-A';projectKey=$lk;scanComplete=$true;partialCauses=@();timestampUtc='2026-01-01T00:00:00Z';candidates=@()}
    Write-Utf8 $legacyPath ($legacyDoc|ConvertTo-Json -Depth 5)
    $legacyBytes=[IO.File]::ReadAllText($legacyPath,[Text.Encoding]::UTF8)
    $null=New-Cache $lp
    $r=Fire -HookPath $legacy.Script -Cwd $lp -EventName Stop -SessionId 'legacy-A' -LocalAppData $legacy.LocalAppData -Exe $HostExe
    Check ($HostExe+': matching legacy baseline retains appeared classification') ($r.Err-eq''-and$r.Out-match'at-session-start=no'-and$r.Out-notmatch'baseline-session-mismatch') $r.Out
    $r=Fire -HookPath $legacy.Script -Cwd $lp -EventName Stop -SessionId 'foreign-B' -LocalAppData $legacy.LocalAppData -Exe $HostExe
    Check ($HostExe+': foreign legacy baseline cannot prove absence') ($r.Err-eq''-and$r.Out-match'baseline-missing'-and$r.Out-notmatch'class=likely-disposable') $r.Out
    $null=Fire -HookPath $legacy.Script -Cwd $lp -EventName SessionStart -SessionId 'foreign-B' -LocalAppData $legacy.LocalAppData -Exe $HostExe
    Check ($HostExe+': foreign SessionStart leaves legacy original untouched') ([IO.File]::ReadAllText($legacyPath,[Text.Encoding]::UTF8)-ceq$legacyBytes)
    $scoped=Join-Path $ls ('TestTempCleanup-baseline-'+$lk+'-'+(Get-ShortHash 'legacy-A')+'.json')
    Write-Utf8 $scoped '{malformed'
    $r=Fire -HookPath $legacy.Script -Cwd $lp -EventName Stop -SessionId 'legacy-A' -LocalAppData $legacy.LocalAppData -Exe $HostExe
    Check ($HostExe+': malformed scoped evidence never falls back to clean legacy') ($r.Err-eq''-and$r.Out-match'baseline-missing'-and$r.Out-notmatch'class=likely-disposable') $r.Out
    $null=Fire -HookPath $legacy.Script -Cwd $lp -EventName SessionStart -SessionId 'legacy-A' -LocalAppData $legacy.LocalAppData -Exe $HostExe
    Check ($HostExe+': malformed initial evidence is retained, not replaced on resume') ([IO.File]::ReadAllText($scoped,[Text.Encoding]::UTF8)-ceq'{malformed')
    $r=Fire -HookPath $legacy.Script -Cwd $lp -EventName Stop -SessionId '' -LocalAppData $legacy.LocalAppData -Exe $HostExe
    Check ($HostExe+': empty session cannot borrow legacy evidence') ($r.Err-eq''-and$r.Out-match'baseline-session-mismatch'-and$r.Out-notmatch'class=likely-disposable') $r.Out
    $unicode='session-'+[char]0x06cc+[char]0x0627
    $null=Fire -HookPath $legacy.Script -Cwd $lp -EventName SessionStart -SessionId $unicode -LocalAppData $legacy.LocalAppData -Exe $HostExe
    $unicodePath=Join-Path $ls ('TestTempCleanup-baseline-'+$lk+'-'+(Get-ShortHash $unicode)+'.json')
    $unicodeDoc=Read-JsonFile $unicodePath
    Check ($HostExe+': UTF-8 session identity round trips through a fixed hash leaf') ([string](Get-Field $unicodeDoc 'sessionId')-ceq$unicode)
}

# Two synchronized writers exercise the exact production publication function,
# without two costly hook scans or extra external child processes.
function Invoke-CleanupPublicationRegression {
    $source=Join-Path $HooksRoot 'Test-Temp-Cleanup/_sessionstate.ps1'
    $ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$null,[ref]$null)
    $definition=$ast.Find({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-eq'Publish-CleanupBaseline'},$true).Extent.Text
    $path=Join-Path (New-Proj 'session-publication') 'baseline.json'
    $gate=[Threading.ManualResetEventSlim]::new($false)
    $workers=@();$pending=@()
    try {
        foreach($id in @('writer-A','writer-B')) {
            $worker=[PowerShell]::Create();$workers+=@($worker)
            [void]$worker.AddScript('param($definition,$gate,$path,$id);. ([scriptblock]::Create($definition));if(-not$gate.Wait(3000)){throw "Publication barrier timed out."};Publish-CleanupBaseline -Value @{sessionId=$id;timestampUtc="2026-01-01T00:00:00Z";candidates=@()} -Path $path').AddArgument($definition).AddArgument($gate).AddArgument($path).AddArgument($id)
            $pending+=@($worker.BeginInvoke())
        }
        $gate.Set()
        for($i=0;$i-lt$workers.Count;$i++) {
            if(-not$pending[$i].AsyncWaitHandle.WaitOne(5000)){throw 'Publication worker timed out.'}
            $null=$workers[$i].EndInvoke($pending[$i])
            if($workers[$i].HadErrors){throw 'Publication worker failed.'}
        }
        $doc=Read-JsonFile $path
        Check 'concurrent first publication admits exactly one complete snapshot' ([string]$doc.sessionId-in@('writer-A','writer-B')-and$doc.timestampUtc-and@(Get-ChildItem -LiteralPath (Split-Path -Parent $path) -Filter '*.tmp').Count-eq0)
        $original=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
        . ([scriptblock]::Create($definition))
        Publish-CleanupBaseline -Value @{sessionId='replacement'} -Path $path
        Check 'later publication cannot replace the concurrent winner bytes' ([IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)-ceq$original)
    }
    finally {
        $gate.Set()
        foreach($worker in $workers){$worker.Stop();$worker.Dispose()}
        foreach($operation in $pending){$operation.AsyncWaitHandle.Close()}
        $gate.Dispose()
    }
}
