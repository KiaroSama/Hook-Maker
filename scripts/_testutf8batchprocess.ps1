# Real redirected-pipe fault controls; one boundary factory, production orchestration.
$factory = (Get-Command New-Utf8GitProcess).ScriptBlock
$initialize = (Get-Command Initialize-Utf8BatchReader).ScriptBlock
$fakeScript = Join-Path $Work 'batch-fault-child.ps1'
$pidPath = Join-Path $Work 'batch-fault-child.pid'
Write-Utf8 $fakeScript @'
param([string]$Mode,[string]$PidPath)
[IO.File]::WriteAllText($PidPath,[string]$PID,[Text.Encoding]::UTF8)
$oid=[Console]::In.ReadLine()
[Console]::Out.Write($oid+" blob 1`na`n")
if($Mode-eq'trailing-output'){[Console]::Out.Write('EXTRA')}
[Console]::Out.Flush()
if($Mode-eq'deadline'){[Threading.Thread]::Sleep([Threading.Timeout]::Infinite)}
if($Mode-eq'process-exit'){exit 7}
'@
try {
    function New-Utf8GitProcess {
        param([string]$Cwd)
        $proc=New-Object Diagnostics.Process
        $proc.StartInfo.FileName=(Get-Process -Id $PID).Path
        $proc.StartInfo.Arguments=ConvertTo-ProcessArgumentString @('-NoProfile','-NonInteractive','-File',$fakeScript,$mode,$pidPath)
        $proc.StartInfo.WorkingDirectory=$Cwd
        $proc.StartInfo.UseShellExecute=$false
        $proc.StartInfo.RedirectStandardInput=$true
        $proc.StartInfo.RedirectStandardOutput=$true
        $proc.StartInfo.RedirectStandardError=$true
        $proc.StartInfo.CreateNoWindow=$true
        return $proc
    }
    foreach($mode in @('trailing-output','process-exit','deadline')) {
        $script:HookDeadlineUtc=[DateTime]::UtcNow.AddSeconds(10)
        $reads=Read-GitBlobsBatch $Work @($oid) 8MB ([DateTime]::UtcNow.AddSeconds(3))
        $childPid=[int][IO.File]::ReadAllText($pidPath,[Text.Encoding]::UTF8)
        Check ('completed frames still refuse '+$mode+' and reap exact child') (
            $reads[$oid].Failed-and$reads[$oid].Failure-eq$mode-and
            $null-eq(Get-Process -Id $childPid -ErrorAction SilentlyContinue))
    }
    function Initialize-Utf8BatchReader { throw 'controlled unavailable compiler' }
    function New-Utf8GitProcess { throw 'factory must not run before reader initialization' }
    $script:HookDeadlineUtc=[DateTime]::UtcNow.AddSeconds(10)
    $reads=Read-GitBlobsBatch $Work @($oid) 8MB
    Check 'reader initialization failure stays nonclean and is not Git process-start' ($reads[$oid].Failed-and$reads[$oid].Failure-eq'reader-initialization')
} finally {
    Set-Item Function:New-Utf8GitProcess $factory
    Set-Item Function:Initialize-Utf8BatchReader $initialize
}
