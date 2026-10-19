# Execute the generated wrapper against inert stages, not a live remote push.
function Invoke-NativeProgressRegression {
    $dir=Join-Path $Work 'native wrapper byte contract'
    [void][IO.Directory]::CreateDirectory($dir)
    $scripts=@()
    foreach($name in @('Ignore-Rules-Check','Secrets-Check','Utf8-Encoding-Check')){
        $stage=Join-Path $dir ($name+'.ps1')
        $body=@'
param([switch]$GitPrePush)
$ErrorActionPreference='Stop'
$inputStream=[Console]::OpenStandardInput()
$outputStream=[IO.File]::Create((Join-Path $PSScriptRoot ($env:HOOKMAKER_PHASE_CASE+'-'+[IO.Path]::GetFileNameWithoutExtension($PSCommandPath)+'.bin')))
try {$inputStream.CopyTo($outputStream)} finally {$outputStream.Dispose()}
if($env:HOOKMAKER_PHASE_CASE-eq'fail'-and[IO.Path]::GetFileNameWithoutExtension($PSCommandPath)-eq'Secrets-Check'){exit 23}
exit 0
'@
        Write-Utf8 $stage $body
        $scripts+=,$stage
    }
    $wrapper=Join-Path $dir 'pre-push'
    Write-Utf8 $wrapper (New-PrePushWrapperBody -ManagedScripts $scripts)
    Write-Utf8 ($wrapper+'.hookmaker-existing') ("#!/bin/sh`ncat > `""+$dir.Replace('\','/')+"/user-stdin.bin`"`nprintf '%s\n' `"`$@`" > `""+$dir.Replace('\','/')+"/user-args.txt`"`nexit 29`n")
    $previousHash=(Get-FileHash ($wrapper+'.hookmaker-existing')).Hash
    $input=Join-Path $dir 'refs.bin'
    $raw=[Text.Encoding]::UTF8.GetBytes("refs/heads/main "+('a'*40)+" refs/heads/main "+('b'*40)+"`nrefs/tags/v1 "+('c'*40)+" refs/tags/v1 "+('0'*40))
    [IO.File]::WriteAllBytes($input,$raw)
    $shell=@(Get-Command sh.exe -CommandType Application -ErrorAction Stop)[0].Source
    foreach($case in @('pass','fail')){
        if($case-eq'fail'){[IO.File]::Delete((Join-Path $dir 'user-stdin.bin'))}
        $out=Join-Path $dir ($case+'.out');$err=Join-Path $dir ($case+'.err')
        $savedCase=$env:HOOKMAKER_PHASE_CASE
        try {
            $env:HOOKMAKER_PHASE_CASE=$case
            $p=Start-BoundedProcess -FilePath $shell -ArgumentList @($wrapper,'origin','public-example') -WorkingDirectory $dir -RedirectStandardInput $input -RedirectStandardOutput $out -RedirectStandardError $err -TimeoutMs 45000
        } finally {$env:HOOKMAKER_PHASE_CASE=$savedCase}
        $stderr=[IO.File]::ReadAllText($err,[Text.Encoding]::UTF8)
        $labels=@($stderr-split'\r?\n'|Where-Object{$_})
        $expected=@('[Hook Maker] pre-push: Ignore','[Hook Maker] pre-push: Secrets')
        if($case-eq'pass'){$expected+='[Hook Maker] pre-push: UTF8'}
        Check ('native wrapper exact fixed stderr stage order '+$case) (($labels-join'|')-ceq($expected-join'|')) $stderr
        Check ('native wrapper keeps stdout clean '+$case) ((Get-Item $out).Length-eq0)
        Check ('native wrapper propagates exact stage/user exit '+$case) ($p.ExitCode-eq$(if($case-eq'pass'){29}else{23}))
        foreach($name in @('Ignore-Rules-Check','Secrets-Check','Utf8-Encoding-Check')){
            $captured=Join-Path $dir ($case+'-'+$name+'.bin')
            if($case-eq'fail'-and$name-eq'Utf8-Encoding-Check'){
                Check 'native wrapper short-circuits after failed Secrets' (-not(Test-Path -LiteralPath $captured))
            }else{
                Check ('native wrapper preserves exact ref bytes '+$case+' '+$name) ([IO.File]::Exists($captured)-and[Convert]::ToBase64String([IO.File]::ReadAllBytes($captured))-ceq[Convert]::ToBase64String($raw))
            }
        }
        if($case-eq'fail'){Check 'native wrapper never invokes previous hook after managed failure' (-not[IO.File]::Exists((Join-Path $dir 'user-stdin.bin')))}
        if($case-eq'pass'){
            Check 'native previous hook receives exact stdin' ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $dir 'user-stdin.bin')))-ceq[Convert]::ToBase64String($raw))
            Check 'native previous hook receives original arguments' (([IO.File]::ReadAllText((Join-Path $dir 'user-args.txt'),[Text.Encoding]::UTF8)-replace'\r\n',"`n")-ceq"origin`npublic-example`n")
        }
    }
    Check 'native progress generator preserves opaque user hook bytes' ((Get-FileHash ($wrapper+'.hookmaker-existing')).Hash-ceq$previousHash)
}
