# Startup work is an explicit contract; real Git fixtures below protect its verdicts.
function Invoke-IgnoreProgressContract {
    param([string]$Root)
    $path=Join-Path $Root 'hooks/Ignore-Rules-Check/Ignore-Rules-Check.ps1'
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    $text=$ast.Extent.Text
    Check 'ignore acquisition uses one checked root query without duplicate worktree probe' ($text.Contains("'--show-toplevel'")-and-not$text.Contains("'--is-inside-work-tree'")-and-not$text.Contains('Resolve-HookProjectRoot $cwd'))
    $commands=@($ast.FindAll({param($n) $n-is[Management.Automation.Language.CommandAst]-and$n.GetCommandName()-eq'Invoke-QuietCommand'},$true))
    $staged=@($commands|Where-Object{$_.Extent.Text.Contains("'--cached'")})
    $lazy=$staged.Count-eq1
    if($lazy){
        $parent=$staged[0].Parent;$conditional=$false
        while($null-ne$parent){
            if($parent-is[Management.Automation.Language.IfStatementAst]-and$parent.Clauses[0].Item1.Extent.Text-match'\$tracked\.Count\s*-gt\s*0'){$conditional=$true;break}
            $parent=$parent.Parent
        }
        $lazy=$conditional
    }
    Check 'ignore staged diagnostic is queried only after a protected index match' $lazy
    Check 'ignore index and match protocol preserves literal quoted paths' ($text.Contains("'ls-files','-z'")-and$text.Contains("'core.quotePath=false','check-ignore','--no-index','-v'"))
    Check 'native ignore reports actual fixed phases only on stderr' ($text.Contains('[Hook Maker] Ignore: repository')-and$text.Contains('[Hook Maker] Ignore: index')-and$text.Contains('[Hook Maker] Ignore: batch')-and$text.Contains('if ($GitPrePush)'))
}

function Invoke-IgnoreProgressRegression {
    $repo=New-Repo 'native progress literal paths'
    $null=Fire -Cwd $repo -EventName SessionStart
    $before=[IO.File]::ReadAllBytes((Join-Path $repo '.gitignore'))
    $name='source ['+[char]0x03A9+'].txt'
    Write-Utf8 (Join-Path $repo $name) 'ordinary source'
    Write-Utf8 (Join-Path $repo '.env.example') 'PUBLIC=example'
    & git -C $repo add -- $name .env.example
    $nested=Join-Path $repo 'nested';[void][IO.Directory]::CreateDirectory($nested)
    function Invoke-NativeIgnore {
        param([string]$Cwd,[string]$Entry,[string]$HostExe,[hashtable]$Environment=@{})
        $token=[guid]::NewGuid().ToString('N')
        $out=Join-Path $Work ($token+'.out');$err=Join-Path $Work ($token+'.err')
        $saved=@{}
        try {
            foreach($key in $Environment.Keys){$saved[$key]=[Environment]::GetEnvironmentVariable($key);[Environment]::SetEnvironmentVariable($key,[string]$Environment[$key])}
            $p=Start-BoundedProcess -FilePath $HostExe -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-File',$Entry,'-GitPrePush') -WorkingDirectory $Cwd -RedirectStandardOutput $out -RedirectStandardError $err -TimeoutMs 30000
        } finally {foreach($key in $saved.Keys){[Environment]::SetEnvironmentVariable($key,$saved[$key])}}
        return [pscustomobject]@{Exit=$p.ExitCode;Out=[IO.File]::ReadAllText($out,[Text.Encoding]::UTF8);Err=[IO.File]::ReadAllText($err,[Text.Encoding]::UTF8)}
    }
    foreach($hostExe in @((Get-Process -Id $PID).Path,'powershell.exe')|Select-Object -Unique){
        $native=Invoke-NativeIgnore $nested $Hook $hostExe
        Check 'native clean index permits staged Unicode source and public template from nested cwd' ($native.Exit-eq0-and$native.Out-eq''-and$native.Err.Contains('[Hook Maker] Ignore: repository')-and$native.Err.Contains('[Hook Maker] Ignore: index')-and$native.Err.Contains('[Hook Maker] Ignore: batch complete')) $native.Err
        Check 'native progress contains no root or source path' (-not$native.Err.Contains($repo)-and-not$native.Err.Contains($name)) $native.Err
    }
    Check 'native clean path preserves root ignore bytes' ([Convert]::ToBase64String($before)-ceq[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $repo '.gitignore'))))
    [void][IO.Directory]::CreateDirectory((Join-Path $repo 'plans'))
    $private=Join-Path $repo ('plans/private ['+[char]0x03A9+'].txt')
    Write-Utf8 $private 'controlled private fixture'
    & git -C $repo add -f -- $private
    $blocked=Invoke-NativeIgnore $nested $Hook (Get-Process -Id $PID).Path
    Check 'native index includes forced staged protected Unicode path and keeps STAGED diagnostic' ($blocked.Exit-ne0-and$blocked.Out-eq''-and$blocked.Err-match'TRACKED'-and$blocked.Err-match'STAGED'-and$blocked.Err.Contains('private ['+[char]0x03A9+'].txt')) $blocked.Err
    Check 'native protected refusal preserves local file bytes' ([IO.File]::ReadAllText($private,[Text.Encoding]::UTF8)-ceq'controlled private fixture')
    $empty=New-Repo 'native empty index';$null=Fire -Cwd $empty -EventName SessionStart
    $native=Invoke-NativeIgnore $empty $Hook (Get-Process -Id $PID).Path
    Check 'native empty index has no invented batch progress' ($native.Exit-eq0-and$native.Out-eq''-and$native.Err.Contains('[Hook Maker] Ignore: index')-and-not$native.Err.Contains('[Hook Maker] Ignore: batch')) $native.Err
    $shim=Join-Path $Work 'ignore-error-shim';[void][IO.Directory]::CreateDirectory($shim)
    $realGit=@(Get-Command git.exe -CommandType Application)[0].Source
    Write-Utf8 (Join-Path $shim 'git.ps1') ("if (`$args -contains 'ls-files') { exit 128 }`r`n& '"+$realGit.Replace("'","''")+"' @args`r`nexit `$LASTEXITCODE")
    $withoutGit=@($env:PATH-split';'|Where-Object{$_-and-not(Test-Path -LiteralPath (Join-Path $_ 'git.exe'))})
    $native=Invoke-NativeIgnore $empty $Hook (Get-Process -Id $PID).Path @{PATH=(@($shim)+$withoutGit)-join';'}
    Check 'native Git inventory error is nonzero with no completion marker' ($native.Exit-ne0-and-not$native.Err.Contains('[Hook Maker] Ignore: batch complete')) $native.Err
}
