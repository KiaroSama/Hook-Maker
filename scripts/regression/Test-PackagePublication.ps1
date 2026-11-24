param([string]$ResultPath = '')
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repo 'scripts\_testlib.ps1')
. (Join-Path $repo 'hooks\_hooklib.ps1')
$work = New-TestWorkspace -Prefix 'hookmaker-publication'
$utf8 = [Text.UTF8Encoding]::new($false)
$cases = New-Object 'System.Collections.Generic.List[object]'
function Check-Package {
    param([string]$Name, [bool]$Passed, [string]$Detail = '')
    [void]$cases.Add([pscustomobject]@{ name = $Name; passed = $Passed; detail = $Detail })
    Write-Host ('[' + [DateTime]::UtcNow.ToString('o') + '] [' + $(if ($Passed) { 'INFO' } else { 'ERROR' }) + '] ' + $Name + ' ' + $Detail)
}
try {
    $engineDir = Join-Path $repo 'hooks\Cross-Project-.ai-Knowledge-Sync'
    . (Join-Path $engineDir '_syncpaths.ps1')
    . (Join-Path $engineDir '_scanthrottle.ps1')
    $context = [pscustomobject]@{ destinationRoot = $work }
    $statePath = Join-Path $work '.ai\.cross-project-sync\state\route.json'
    $next = [pscustomobject]@{ pending = [pscustomobject]@{ kind = 'source-review-v1'; sourceContentFingerprint = 'second' } }
    Check-Package 'a contained state path can be created' (Test-SyncStatePath $context $statePath)
    Write-JsonFileAtomic -Value ([pscustomobject]@{ pending = 'first' }) -Path $statePath
    $original = [IO.File]::ReadAllText($statePath, $utf8)
    $hold = [IO.File]::Open($statePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $failed = $false
        try { Write-JsonFileAtomic -Value $next -Path $statePath } catch { $failed = $true }
        Check-Package 'a real file-sharing publication failure propagates' $failed
        Check-Package 'failed publication preserves the original pending state bytes' ([IO.File]::ReadAllText($statePath, $utf8) -ceq $original)
    }
    finally { $hold.Dispose() }
    $stateDirectory = Split-Path -Parent $statePath
    Check-Package 'failed publication removes only its own temporary file' (@(Get-ChildItem -LiteralPath $stateDirectory -File -Force).Count -eq 1)
    Write-JsonFileAtomic -Value $next -Path $statePath
    Check-Package 'retry publishes exactly one source review' ((Read-JsonFile $statePath).pending.sourceContentFingerprint -ceq 'second')
    Check-Package 'publishing state does not create an inbox' (-not (Test-Path -LiteralPath (Join-Path $work '.ai\.cross-project-sync\inbox')))
    $stamp = Get-ScanStampPath $statePath
    [void][IO.Directory]::CreateDirectory($stamp)
    Check-Package 'a directory cannot masquerade as a scan stamp' (-not (Test-SyncStatePath $context $statePath))
}
catch { Check-Package 'suite completes without an unexpected exception' $false ($_.Exception.Message + ' | ' + $_.ScriptStackTrace) }
finally { Check-Package 'all owned test artifacts are removed' (Remove-TestWorkspace $work) }

$failures = @($cases.ToArray() | Where-Object { -not $_.passed }).Count
if ($ResultPath -ne '') {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $ResultPath))
    [IO.File]::WriteAllText($ResultPath, (([ordered]@{ schema = 1; hostVersion = $PSVersionTable.PSVersion.ToString(); cases = $cases.ToArray(); failed = $failures }) | ConvertTo-Json -Depth 8), $utf8)
}
Write-Host ('Cases: ' + $cases.Count + '; failed: ' + $failures)
if ($failures -gt 0) { exit 1 }
exit 0
