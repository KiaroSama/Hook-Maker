# Exercise the actual planned entry prefix, with only its packaged budget library.
function Invoke-CiInstalledDeadlineRegression {
    param([string]$ToolRoot,[string]$Work)
    . (Join-Path $ToolRoot 'scripts/_installplan.ps1')
    $source=Join-Path $ToolRoot 'hooks/Ci-Status-Check/Ci-Status-Check.ps1'
    $text=Get-PrivateLibraryScriptContent $source
    $start=$text.IndexOf('Set-StrictMode -Version 2.0')
    $end=$text.IndexOf('$pathsFilterPath =')
    if($start-lt0-or$end-le$start){throw 'CI initialization seam missing'}
    $directory=Join-Path $Work 'ci-deadline-runtime'
    [void][IO.Directory]::CreateDirectory($directory)
    Copy-Item -LiteralPath (Join-Path $ToolRoot 'hooks/_budgetlib.ps1') -Destination $directory
    Copy-Item -LiteralPath (Join-Path $ToolRoot 'hooks/_processlib.ps1') -Destination $directory
    # Empty hooklib proves the entry itself initializes the sibling deadline.
    foreach($name in @('_hooklib.ps1','_scope.ps1')){[IO.File]::WriteAllText((Join-Path $directory $name),'',[Text.UTF8Encoding]::new($false))}
    [IO.File]::WriteAllText((Join-Path $directory '.hookmaker-runtime.json'),'{"timeoutSeconds":17}',[Text.UTF8Encoding]::new($false))
    $entry=Join-Path $directory 'probe.ps1'
    $probe=$text.Substring($start,$end-$start)+@'

if($null-eq$script:HookDeadlineUtc){throw 'Installed sibling deadline was not initialized'}
$left=Get-HookRemainingSeconds
if($left-lt10-or$left-gt12){throw 'Registered timeout was not retained'}
$script:HookDeadlineUtc=[DateTime]::UtcNow.AddSeconds(-1)
if((Get-HookRemainingSeconds)-ne0){throw 'Expired deadline was refreshed'}
. (Join-Path $PSScriptRoot '_processlib.ps1')
$null=Invoke-QuietCommand -FilePath 'hookmaker-must-not-start-expired' -ArgumentList @('unused')
if($LASTEXITCODE-ne124){throw 'Shared command ignored the expired hook deadline'}
$script:HookDeadlineUtc=$null
$null=Invoke-QuietCommand -FilePath 'hookmaker-must-not-start-expired' -ArgumentList @('unused') -TimeoutSeconds 20
if($LASTEXITCODE-eq124){throw 'Unadopted caller inherited an expired deadline'}
Write-Output 'installed-deadline-ok'
'@
    [IO.File]::WriteAllText($entry,$probe,[Text.UTF8Encoding]::new($false))
    foreach($hostName in @('pwsh','powershell.exe')){
        $out=Join-Path $directory ($hostName+'.out');$err=Join-Path $directory ($hostName+'.err')
        $p=Start-BoundedProcess -FilePath $hostName -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-File',$entry) -RedirectStandardOutput $out -RedirectStandardError $err -TimeoutMs 20000
        Check ('planned installed deadline initializes on '+$hostName) ($p.ExitCode-eq0-and[IO.File]::ReadAllText($out,[Text.Encoding]::UTF8).Trim()-ceq'installed-deadline-ok') ([IO.File]::ReadAllText($err,[Text.Encoding]::UTF8))
        $p.Dispose()
    }
}
